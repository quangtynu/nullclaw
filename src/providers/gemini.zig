const std = @import("std");
const root = @import("root.zig");

const Provider = root.Provider;
const ChatRequest = root.ChatRequest;
const ChatResponse = root.ChatResponse;

/// Authentication method for Gemini.
pub const GeminiAuth = union(enum) {
    /// Explicit API key from config: sent as `?key=` query parameter.
    explicit_key: []const u8,
    /// API key from `GEMINI_API_KEY` env var.
    env_gemini_key: []const u8,
    /// API key from `GOOGLE_API_KEY` env var.
    env_google_key: []const u8,
    /// OAuth access token from Gemini CLI: sent as `Authorization: Bearer`.
    oauth_token: []const u8,

    pub fn isApiKey(self: GeminiAuth) bool {
        return switch (self) {
            .explicit_key, .env_gemini_key, .env_google_key => true,
            .oauth_token => false,
        };
    }

    pub fn credential(self: GeminiAuth) []const u8 {
        return switch (self) {
            .explicit_key => |v| v,
            .env_gemini_key => |v| v,
            .env_google_key => |v| v,
            .oauth_token => |v| v,
        };
    }

    pub fn source(self: GeminiAuth) []const u8 {
        return switch (self) {
            .explicit_key => "config",
            .env_gemini_key => "GEMINI_API_KEY env var",
            .env_google_key => "GOOGLE_API_KEY env var",
            .oauth_token => "Gemini CLI OAuth",
        };
    }
};

/// Google Gemini provider with support for:
/// - Direct API key (`GEMINI_API_KEY` env var or config)
/// - Gemini CLI OAuth tokens (reuse existing ~/.gemini/ authentication)
/// - Google Cloud ADC (`GOOGLE_APPLICATION_CREDENTIALS`)
pub const GeminiProvider = struct {
    auth: ?GeminiAuth,
    allocator: std.mem.Allocator,

    const BASE_URL = "https://generativelanguage.googleapis.com/v1beta";
    const DEFAULT_MAX_OUTPUT_TOKENS: u32 = 8192;

    pub fn init(allocator: std.mem.Allocator, api_key: ?[]const u8) GeminiProvider {
        var auth: ?GeminiAuth = null;

        // 1. Explicit key
        if (api_key) |key| {
            const trimmed = std.mem.trim(u8, key, " \t\r\n");
            if (trimmed.len > 0) {
                auth = .{ .explicit_key = trimmed };
            }
        }

        // 2. Environment variables (only if no explicit key)
        if (auth == null) {
            if (loadNonEmptyEnv(allocator, "GEMINI_API_KEY")) |value| {
                _ = value;
                auth = .{ .env_gemini_key = "env" };
            }
        }

        if (auth == null) {
            if (loadNonEmptyEnv(allocator, "GOOGLE_API_KEY")) |value| {
                _ = value;
                auth = .{ .env_google_key = "env" };
            }
        }

        return .{
            .auth = auth,
            .allocator = allocator,
        };
    }

    fn loadNonEmptyEnv(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
        if (std.process.getEnvVarOwned(allocator, name)) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) {
                return value;
            }
            allocator.free(value);
            return null;
        } else |_| {
            return null;
        }
    }

    /// Get authentication source description for diagnostics.
    pub fn authSource(self: GeminiProvider) []const u8 {
        if (self.auth) |auth| {
            return auth.source();
        }
        return "none";
    }

    /// Format a model name, prepending "models/" if not already present.
    pub fn formatModelName(model: []const u8) FormatModelResult {
        if (std.mem.startsWith(u8, model, "models/")) {
            return .{ .formatted = model, .needs_free = false };
        }
        return .{ .formatted = model, .needs_free = false, .needs_prefix = true };
    }

    pub const FormatModelResult = struct {
        formatted: []const u8,
        needs_free: bool,
        needs_prefix: bool = false,
    };

    /// Build the generateContent URL.
    pub fn buildUrl(allocator: std.mem.Allocator, model: []const u8, auth: GeminiAuth) ![]const u8 {
        const model_name = if (std.mem.startsWith(u8, model, "models/"))
            model
        else
            try std.fmt.allocPrint(allocator, "models/{s}", .{model});

        if (auth.isApiKey()) {
            const url = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}:generateContent?key={s}",
                .{ BASE_URL, model_name, auth.credential() },
            );
            if (!std.mem.startsWith(u8, model, "models/")) {
                allocator.free(@constCast(model_name));
            }
            return url;
        } else {
            const url = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}:generateContent",
                .{ BASE_URL, model_name },
            );
            if (!std.mem.startsWith(u8, model, "models/")) {
                allocator.free(@constCast(model_name));
            }
            return url;
        }
    }

    /// Build a Gemini generateContent request body.
    pub fn buildRequestBody(
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        temperature: f64,
    ) ![]const u8 {
        if (system_prompt) |sys| {
            return std.fmt.allocPrint(allocator,
                \\{{"contents":[{{"role":"user","parts":[{{"text":"{s}"}}]}}],"system_instruction":{{"parts":[{{"text":"{s}"}}]}},"generationConfig":{{"temperature":{d:.2},"maxOutputTokens":{d}}}}}
            , .{ message, sys, temperature, DEFAULT_MAX_OUTPUT_TOKENS });
        } else {
            return std.fmt.allocPrint(allocator,
                \\{{"contents":[{{"role":"user","parts":[{{"text":"{s}"}}]}}],"generationConfig":{{"temperature":{d:.2},"maxOutputTokens":{d}}}}}
            , .{ message, temperature, DEFAULT_MAX_OUTPUT_TOKENS });
        }
    }

    /// Parse text content from a Gemini generateContent response.
    pub fn parseResponse(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        const root_obj = parsed.value.object;

        // Check for error first
        if (root_obj.get("error")) |err_obj| {
            if (err_obj.object.get("message")) |msg| {
                if (msg == .string) {
                    const err_msg = try std.fmt.allocPrint(allocator, "Gemini API error: {s}", .{msg.string});
                    defer allocator.free(err_msg);
                    return error.ApiError;
                }
            }
            return error.ApiError;
        }

        // Extract text from candidates
        if (root_obj.get("candidates")) |candidates| {
            if (candidates.array.items.len > 0) {
                const candidate = candidates.array.items[0].object;
                if (candidate.get("content")) |content| {
                    if (content.object.get("parts")) |parts| {
                        if (parts.array.items.len > 0) {
                            const part = parts.array.items[0].object;
                            if (part.get("text")) |text| {
                                if (text == .string) {
                                    return try allocator.dupe(u8, text.string);
                                }
                            }
                        }
                    }
                }
            }
        }

        return error.NoResponseContent;
    }

    /// Create a Provider interface from this GeminiProvider.
    pub fn provider(self: *GeminiProvider) Provider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Provider.VTable{
        .chatWithSystem = chatWithSystemImpl,
        .chat = chatImpl,
        .supportsNativeTools = supportsNativeToolsImpl,
        .getName = getNameImpl,
        .deinit = deinitImpl,
    };

    fn chatWithSystemImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        system_prompt: ?[]const u8,
        message: []const u8,
        model: []const u8,
        temperature: f64,
    ) anyerror![]const u8 {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        const auth = self.auth orelse return error.CredentialsNotSet;

        const url = try buildUrl(allocator, model, auth);
        defer allocator.free(url);

        const body = try buildRequestBody(allocator, system_prompt, message, temperature);
        defer allocator.free(body);

        const resp_body = if (auth.isApiKey())
            curlPost(allocator, url, body, null) catch return error.GeminiApiError
        else
            curlPost(allocator, url, body, auth.credential()) catch return error.GeminiApiError;
        defer allocator.free(resp_body);

        return parseResponse(allocator, resp_body);
    }

    fn chatImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        request: ChatRequest,
        model: []const u8,
        temperature: f64,
    ) anyerror!ChatResponse {
        const self: *GeminiProvider = @ptrCast(@alignCast(ptr));
        const auth = self.auth orelse return error.CredentialsNotSet;

        const url = try buildUrl(allocator, model, auth);
        defer allocator.free(url);

        const body = try buildChatRequestBody(allocator, request, temperature);
        defer allocator.free(body);

        const resp_body = if (auth.isApiKey())
            curlPost(allocator, url, body, null) catch return error.GeminiApiError
        else
            curlPost(allocator, url, body, auth.credential()) catch return error.GeminiApiError;
        defer allocator.free(resp_body);

        const text = try parseResponse(allocator, resp_body);
        return ChatResponse{ .content = text };
    }

    fn supportsNativeToolsImpl(_: *anyopaque) bool {
        return false;
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "Gemini";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

/// Build a full chat request JSON body from a ChatRequest (Gemini format).
/// Gemini uses "contents" array with roles "user"/"model", system goes in "system_instruction".
fn buildChatRequestBody(
    allocator: std.mem.Allocator,
    request: ChatRequest,
    temperature: f64,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Extract system prompt
    var system_prompt: ?[]const u8 = null;
    for (request.messages) |msg| {
        if (msg.role == .system) {
            system_prompt = msg.content;
            break;
        }
    }

    try buf.appendSlice(allocator, "{\"contents\":[");
    var count: usize = 0;
    for (request.messages) |msg| {
        if (msg.role == .system) continue;
        if (count > 0) try buf.append(allocator, ',');
        count += 1;
        // Gemini uses "user" and "model" (not "assistant")
        const role_str: []const u8 = switch (msg.role) {
            .user, .tool => "user",
            .assistant => "model",
            .system => unreachable,
        };
        try buf.appendSlice(allocator, "{\"role\":\"");
        try buf.appendSlice(allocator, role_str);
        try buf.appendSlice(allocator, "\",\"parts\":[{\"text\":");
        try appendJsonString(&buf, allocator, msg.content);
        try buf.appendSlice(allocator, "}]}");
    }
    try buf.append(allocator, ']');

    if (system_prompt) |sys| {
        try buf.appendSlice(allocator, ",\"system_instruction\":{\"parts\":[{\"text\":");
        try appendJsonString(&buf, allocator, sys);
        try buf.appendSlice(allocator, "}]}");
    }

    try buf.appendSlice(allocator, ",\"generationConfig\":{\"temperature\":");
    var temp_buf: [16]u8 = undefined;
    const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.2}", .{temperature}) catch return error.GeminiApiError;
    try buf.appendSlice(allocator, temp_str);
    try buf.appendSlice(allocator, ",\"maxOutputTokens\":");
    var max_buf: [16]u8 = undefined;
    const max_str = std.fmt.bufPrint(&max_buf, "{d}", .{GeminiProvider.DEFAULT_MAX_OUTPUT_TOKENS}) catch return error.GeminiApiError;
    try buf.appendSlice(allocator, max_str);
    try buf.appendSlice(allocator, "}}");

    return try buf.toOwnedSlice(allocator);
}

/// Append a JSON-escaped string (with enclosing quotes) to the buffer.
fn appendJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    var escape_buf: [6]u8 = undefined;
                    const escape = std.fmt.bufPrint(&escape_buf, "\\u{x:0>4}", .{c}) catch unreachable;
                    try buf.appendSlice(allocator, escape);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

/// HTTP POST via curl subprocess.
/// If `bearer_token` is non-null, sends Authorization: Bearer header (for OAuth).
/// For API key auth, the key is already in the URL query param, so pass null.
fn curlPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8, bearer_token: ?[]const u8) ![]u8 {
    if (bearer_token) |token| {
        var auth_hdr_buf: [512]u8 = undefined;
        const auth_hdr = std.fmt.bufPrint(&auth_hdr_buf, "Authorization: Bearer {s}", .{token}) catch return error.CurlBufferError;

        var child = std.process.Child.init(&.{
            "curl", "-s",                             "-X", "POST",
            "-H",   "Content-Type: application/json", "-H", auth_hdr,
            "-d",   body,                             url,
        }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch return error.CurlReadError;

        const term = child.wait() catch return error.CurlWaitError;
        if (term != .Exited or term.Exited != 0) return error.CurlFailed;

        return stdout;
    } else {
        var child = std.process.Child.init(&.{
            "curl", "-s",                             "-X", "POST",
            "-H",   "Content-Type: application/json", "-d", body,
            url,
        }, allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch return error.CurlReadError;

        const term = child.wait() catch return error.CurlWaitError;
        if (term != .Exited or term.Exited != 0) return error.CurlFailed;

        return stdout;
    }
}

// ════════════════════════════════════════════════════════════════════════════
// Tests
// ════════════════════════════════════════════════════════════════════════════

test "provider creates without key" {
    const p = GeminiProvider.init(std.testing.allocator, null);
    _ = p.authSource();
}

test "provider creates with key" {
    const p = GeminiProvider.init(std.testing.allocator, "test-api-key");
    try std.testing.expect(p.auth != null);
    try std.testing.expectEqualStrings("config", p.authSource());
}

test "provider rejects empty key" {
    const p = GeminiProvider.init(std.testing.allocator, "");
    try std.testing.expectEqualStrings("none", p.authSource());
}

test "api key url includes key query param" {
    const auth = GeminiAuth{ .explicit_key = "api-key-123" };
    const url = try GeminiProvider.buildUrl(std.testing.allocator, "gemini-2.0-flash", auth);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, ":generateContent?key=api-key-123") != null);
}

test "oauth url omits key query param" {
    const auth = GeminiAuth{ .oauth_token = "ya29.test-token" };
    const url = try GeminiProvider.buildUrl(std.testing.allocator, "gemini-2.0-flash", auth);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.endsWith(u8, url, ":generateContent"));
    try std.testing.expect(std.mem.indexOf(u8, url, "?key=") == null);
}

test "model name formatting" {
    const auth = GeminiAuth{ .explicit_key = "key" };

    const url1 = try GeminiProvider.buildUrl(std.testing.allocator, "gemini-2.0-flash", auth);
    defer std.testing.allocator.free(url1);
    try std.testing.expect(std.mem.indexOf(u8, url1, "models/gemini-2.0-flash") != null);

    const url2 = try GeminiProvider.buildUrl(std.testing.allocator, "models/gemini-1.5-pro", auth);
    defer std.testing.allocator.free(url2);
    try std.testing.expect(std.mem.indexOf(u8, url2, "models/gemini-1.5-pro") != null);
    // Ensure no double "models/" prefix
    try std.testing.expect(std.mem.indexOf(u8, url2, "models/models/") == null);
}

test "buildRequestBody with system" {
    const body = try GeminiProvider.buildRequestBody(std.testing.allocator, "Be helpful", "Hello", 0.7);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "system_instruction") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "maxOutputTokens") != null);
}

test "buildRequestBody without system" {
    const body = try GeminiProvider.buildRequestBody(std.testing.allocator, null, "Hello", 0.7);
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "system_instruction") == null);
}

test "parseResponse extracts text" {
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"Hello there!"}]}}]}
    ;
    const result = try GeminiProvider.parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Hello there!", result);
}

test "parseResponse error response" {
    const body =
        \\{"error":{"message":"Invalid API key"}}
    ;
    try std.testing.expectError(error.ApiError, GeminiProvider.parseResponse(std.testing.allocator, body));
}

test "GeminiAuth isApiKey" {
    const key = GeminiAuth{ .explicit_key = "key" };
    try std.testing.expect(key.isApiKey());

    const oauth = GeminiAuth{ .oauth_token = "ya29.token" };
    try std.testing.expect(!oauth.isApiKey());
}

test "GeminiAuth credential returns raw value" {
    const key = GeminiAuth{ .explicit_key = "my-api-key" };
    try std.testing.expectEqualStrings("my-api-key", key.credential());

    const oauth = GeminiAuth{ .oauth_token = "ya29.token" };
    try std.testing.expectEqualStrings("ya29.token", oauth.credential());
}

test "GeminiAuth source labels" {
    try std.testing.expectEqualStrings("config", (GeminiAuth{ .explicit_key = "k" }).source());
    try std.testing.expectEqualStrings("GEMINI_API_KEY env var", (GeminiAuth{ .env_gemini_key = "k" }).source());
    try std.testing.expectEqualStrings("GOOGLE_API_KEY env var", (GeminiAuth{ .env_google_key = "k" }).source());
    try std.testing.expectEqualStrings("Gemini CLI OAuth", (GeminiAuth{ .oauth_token = "t" }).source());
}

test "parseResponse empty candidates fails" {
    const body =
        \\{"candidates":[]}
    ;
    try std.testing.expectError(error.NoResponseContent, GeminiProvider.parseResponse(std.testing.allocator, body));
}

test "parseResponse no text field fails" {
    const body =
        \\{"candidates":[{"content":{"parts":[{}]}}]}
    ;
    try std.testing.expectError(error.NoResponseContent, GeminiProvider.parseResponse(std.testing.allocator, body));
}

test "parseResponse multiple parts returns first text" {
    const body =
        \\{"candidates":[{"content":{"parts":[{"text":"First"},{"text":"Second"}]}}]}
    ;
    const result = try GeminiProvider.parseResponse(std.testing.allocator, body);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("First", result);
}

test "provider rejects whitespace key" {
    const p = GeminiProvider.init(std.testing.allocator, "   ");
    try std.testing.expectEqualStrings("none", p.authSource());
}

test "provider getName returns Gemini" {
    var p = GeminiProvider.init(std.testing.allocator, "key");
    const prov = p.provider();
    try std.testing.expectEqualStrings("Gemini", prov.getName());
}

test "buildUrl with models prefix does not double prefix" {
    const auth = GeminiAuth{ .explicit_key = "key" };
    const url = try GeminiProvider.buildUrl(std.testing.allocator, "models/gemini-1.5-pro", auth);
    defer std.testing.allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "models/models/") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "models/gemini-1.5-pro") != null);
}
