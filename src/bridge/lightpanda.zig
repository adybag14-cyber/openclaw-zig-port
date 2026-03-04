const std = @import("std");
const time_util = @import("../util/time.zig");

pub const BridgeError = error{
    UnsupportedEngine,
    UnsupportedProvider,
};

pub const BrowserCompletion = struct {
    ok: bool,
    engine: []const u8,
    provider: []const u8,
    model: []const u8,
    status: []const u8,
    authMode: []const u8,
    guestBypassSupported: bool,
    popupBypassAction: []const u8,
    message: []const u8,
};

pub const BridgeProbe = struct {
    ok: bool,
    endpoint: []u8,
    probeUrl: []u8,
    statusCode: u16,
    latencyMs: i64,
    errorText: []u8,

    pub fn deinit(self: BridgeProbe, allocator: std.mem.Allocator) void {
        allocator.free(self.endpoint);
        allocator.free(self.probeUrl);
        allocator.free(self.errorText);
    }
};

pub const CompletionMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const BridgeCompletionExecution = struct {
    requested: bool,
    ok: bool,
    provider: []u8,
    endpoint: []u8,
    requestUrl: []u8,
    requestTimeoutMs: u32,
    statusCode: u16,
    model: []u8,
    assistantText: []u8,
    latencyMs: i64,
    errorText: []u8,

    pub fn deinit(self: BridgeCompletionExecution, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.endpoint);
        allocator.free(self.requestUrl);
        allocator.free(self.model);
        allocator.free(self.assistantText);
        allocator.free(self.errorText);
    }
};

pub fn normalizeEngine(raw: []const u8) BridgeError![]const u8 {
    const engine = std.mem.trim(u8, raw, " \t\r\n");
    if (engine.len == 0) return "lightpanda";
    if (std.ascii.eqlIgnoreCase(engine, "lightpanda")) return "lightpanda";
    if (std.ascii.eqlIgnoreCase(engine, "playwright")) return error.UnsupportedEngine;
    if (std.ascii.eqlIgnoreCase(engine, "puppeteer")) return error.UnsupportedEngine;
    return error.UnsupportedEngine;
}

pub fn normalizeProvider(raw: []const u8) BridgeError![]const u8 {
    const provider = std.mem.trim(u8, raw, " \t\r\n");
    if (provider.len == 0) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(provider, "openai") or std.ascii.eqlIgnoreCase(provider, "openai-chatgpt") or std.ascii.eqlIgnoreCase(provider, "chatgpt-web") or std.ascii.eqlIgnoreCase(provider, "chatgpt.com")) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(provider, "openai-codex") or std.ascii.eqlIgnoreCase(provider, "codex-cli") or std.ascii.eqlIgnoreCase(provider, "openai-codex-cli")) return "codex";
    if (std.ascii.eqlIgnoreCase(provider, "anthropic") or std.ascii.eqlIgnoreCase(provider, "claude-cli") or std.ascii.eqlIgnoreCase(provider, "claude-code") or std.ascii.eqlIgnoreCase(provider, "claude-desktop")) return "claude";
    if (std.ascii.eqlIgnoreCase(provider, "google") or std.ascii.eqlIgnoreCase(provider, "google-gemini") or std.ascii.eqlIgnoreCase(provider, "google-gemini-cli") or std.ascii.eqlIgnoreCase(provider, "gemini-cli")) return "gemini";
    if (std.ascii.eqlIgnoreCase(provider, "qwen-portal") or std.ascii.eqlIgnoreCase(provider, "qwen-cli") or std.ascii.eqlIgnoreCase(provider, "qwen-chat") or std.ascii.eqlIgnoreCase(provider, "qwen35") or std.ascii.eqlIgnoreCase(provider, "qwen3.5") or std.ascii.eqlIgnoreCase(provider, "qwen-3.5") or std.ascii.eqlIgnoreCase(provider, "copaw") or std.ascii.eqlIgnoreCase(provider, "qwen-copaw") or std.ascii.eqlIgnoreCase(provider, "qwen-agent")) return "qwen";
    if (std.ascii.eqlIgnoreCase(provider, "minimax-portal") or std.ascii.eqlIgnoreCase(provider, "minimax-cli")) return "minimax";
    if (std.ascii.eqlIgnoreCase(provider, "kimi-code") or std.ascii.eqlIgnoreCase(provider, "kimi-coding") or std.ascii.eqlIgnoreCase(provider, "kimi-for-coding")) return "kimi";
    if (std.ascii.eqlIgnoreCase(provider, "opencode-zen") or std.ascii.eqlIgnoreCase(provider, "opencode-ai") or std.ascii.eqlIgnoreCase(provider, "opencode-go") or std.ascii.eqlIgnoreCase(provider, "opencode_free") or std.ascii.eqlIgnoreCase(provider, "opencodefree")) return "opencode";
    if (std.ascii.eqlIgnoreCase(provider, "zhipu") or std.ascii.eqlIgnoreCase(provider, "zhipu-ai") or std.ascii.eqlIgnoreCase(provider, "bigmodel") or std.ascii.eqlIgnoreCase(provider, "bigmodel-cn") or std.ascii.eqlIgnoreCase(provider, "zhipuai-coding") or std.ascii.eqlIgnoreCase(provider, "zhipu-coding")) return "zhipuai";
    if (std.ascii.eqlIgnoreCase(provider, "z.ai") or std.ascii.eqlIgnoreCase(provider, "z-ai") or std.ascii.eqlIgnoreCase(provider, "zaiweb") or std.ascii.eqlIgnoreCase(provider, "zai-web") or std.ascii.eqlIgnoreCase(provider, "glm") or std.ascii.eqlIgnoreCase(provider, "glm5") or std.ascii.eqlIgnoreCase(provider, "glm-5")) return "zai";
    if (std.ascii.eqlIgnoreCase(provider, "inception-labs") or std.ascii.eqlIgnoreCase(provider, "inceptionlabs") or std.ascii.eqlIgnoreCase(provider, "mercury") or std.ascii.eqlIgnoreCase(provider, "mercury2") or std.ascii.eqlIgnoreCase(provider, "mercury-2")) return "inception";
    if (std.ascii.eqlIgnoreCase(provider, "chatgpt") or std.ascii.eqlIgnoreCase(provider, "codex") or std.ascii.eqlIgnoreCase(provider, "claude") or std.ascii.eqlIgnoreCase(provider, "gemini") or std.ascii.eqlIgnoreCase(provider, "qwen") or std.ascii.eqlIgnoreCase(provider, "minimax") or std.ascii.eqlIgnoreCase(provider, "kimi") or std.ascii.eqlIgnoreCase(provider, "openrouter") or std.ascii.eqlIgnoreCase(provider, "opencode") or std.ascii.eqlIgnoreCase(provider, "zhipuai") or std.ascii.eqlIgnoreCase(provider, "zai") or std.ascii.eqlIgnoreCase(provider, "inception")) return provider;
    return error.UnsupportedProvider;
}

pub fn defaultModelForProvider(provider_raw: []const u8) []const u8 {
    const provider = normalizeProvider(provider_raw) catch "chatgpt";
    if (std.ascii.eqlIgnoreCase(provider, "codex")) return "gpt-5.2";
    if (std.ascii.eqlIgnoreCase(provider, "claude")) return "claude-opus-4";
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) return "gemini-2.5-pro";
    if (std.ascii.eqlIgnoreCase(provider, "qwen")) return "qwen-max";
    if (std.ascii.eqlIgnoreCase(provider, "minimax")) return "minimax-m2.5";
    if (std.ascii.eqlIgnoreCase(provider, "kimi")) return "kimi-k2.5";
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) return "openrouter/auto";
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) return "opencode/default";
    if (std.ascii.eqlIgnoreCase(provider, "zhipuai")) return "glm-4.6";
    if (std.ascii.eqlIgnoreCase(provider, "zai")) return "glm-5";
    if (std.ascii.eqlIgnoreCase(provider, "inception")) return "mercury-2";
    return "gpt-5.2";
}

pub fn supportsGuestBypass(provider_raw: []const u8) bool {
    const provider = normalizeProvider(provider_raw) catch return false;
    return std.ascii.eqlIgnoreCase(provider, "qwen") or
        std.ascii.eqlIgnoreCase(provider, "zai") or
        std.ascii.eqlIgnoreCase(provider, "inception");
}

pub fn popupBypassAction(provider_raw: []const u8) []const u8 {
    return if (supportsGuestBypass(provider_raw)) "stay_logged_out" else "not_applicable";
}

fn normalizeAuthMode(provider: []const u8, raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        return if (supportsGuestBypass(provider)) "guest_or_code" else "device_code";
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "guest") or
        std.ascii.eqlIgnoreCase(trimmed, "guest_bypass") or
        std.ascii.eqlIgnoreCase(trimmed, "stay_logged_out") or
        std.ascii.eqlIgnoreCase(trimmed, "stay-logged-out") or
        std.ascii.eqlIgnoreCase(trimmed, "continue_as_guest"))
    {
        return "guest";
    }
    if (std.ascii.eqlIgnoreCase(trimmed, "device_code") or
        std.ascii.eqlIgnoreCase(trimmed, "oauth_code") or
        std.ascii.eqlIgnoreCase(trimmed, "code"))
    {
        return "device_code";
    }
    return trimmed;
}

pub fn complete(engine_raw: []const u8, provider_raw: []const u8, model_raw: []const u8, auth_mode_raw: []const u8) BridgeError!BrowserCompletion {
    const engine = try normalizeEngine(engine_raw);
    const provider = try normalizeProvider(provider_raw);
    const model_trimmed = std.mem.trim(u8, model_raw, " \t\r\n");
    const model = if (model_trimmed.len > 0) model_trimmed else defaultModelForProvider(provider);
    const guest_bypass = supportsGuestBypass(provider);
    const auth_mode = normalizeAuthMode(provider, auth_mode_raw);
    const message = if (guest_bypass)
        "Lightpanda bridge ready; if popup appears choose 'Stay logged out' and continue as guest."
    else
        "Lightpanda browser bridge ready";
    return .{
        .ok = true,
        .engine = engine,
        .provider = provider,
        .model = model,
        .status = "completed",
        .authMode = auth_mode,
        .guestBypassSupported = guest_bypass,
        .popupBypassAction = popupBypassAction(provider),
        .message = message,
    };
}

pub fn probeEndpoint(allocator: std.mem.Allocator, endpoint_raw: []const u8) !BridgeProbe {
    const endpoint = try normalizeEndpointForProbe(allocator, endpoint_raw);
    errdefer allocator.free(endpoint);

    const probe_url = try std.fmt.allocPrint(allocator, "{s}/json/version", .{endpoint});
    errdefer allocator.free(probe_url);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    const started_ms = time_util.nowMs();
    const fetch_result = client.fetch(.{
        .location = .{ .url = probe_url },
        .method = .GET,
        .keep_alive = false,
    }) catch |err| {
        return .{
            .ok = false,
            .endpoint = endpoint,
            .probeUrl = probe_url,
            .statusCode = 0,
            .latencyMs = time_util.nowMs() - started_ms,
            .errorText = try std.fmt.allocPrint(allocator, "probe failed: {s}", .{@errorName(err)}),
        };
    };

    const status_code: u16 = @intCast(@intFromEnum(fetch_result.status));
    const ok = status_code >= 200 and status_code < 400;

    return .{
        .ok = ok,
        .endpoint = endpoint,
        .probeUrl = probe_url,
        .statusCode = status_code,
        .latencyMs = time_util.nowMs() - started_ms,
        .errorText = if (ok) try allocator.dupe(u8, "") else try std.fmt.allocPrint(allocator, "unexpected status {d}", .{status_code}),
    };
}

pub fn executeCompletion(
    allocator: std.mem.Allocator,
    endpoint_raw: []const u8,
    request_timeout_ms: u32,
    provider_raw: []const u8,
    model_raw: []const u8,
    messages: []const CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    login_session_id_raw: []const u8,
    api_key_raw: []const u8,
) !BridgeCompletionExecution {
    const endpoint = try normalizeEndpointForProbe(allocator, endpoint_raw);
    errdefer allocator.free(endpoint);

    const request_url = try std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{endpoint});
    errdefer allocator.free(request_url);

    const provider = normalizeProvider(provider_raw) catch "chatgpt";
    const model_trimmed = std.mem.trim(u8, model_raw, " \t\r\n");
    const model = if (model_trimmed.len > 0) model_trimmed else defaultModelForProvider(provider);
    const login_session_id = std.mem.trim(u8, login_session_id_raw, " \t\r\n");
    const api_key = std.mem.trim(u8, api_key_raw, " \t\r\n");

    const Payload = struct {
        provider: []const u8,
        model: []const u8,
        messages: []const CompletionMessage,
        temperature: ?f64 = null,
        max_tokens: ?u32 = null,
        loginSessionId: ?[]const u8 = null,
        apiKey: ?[]const u8 = null,
        api_key: ?[]const u8 = null,
    };

    const payload = Payload{
        .provider = provider,
        .model = model,
        .messages = messages,
        .temperature = temperature,
        .max_tokens = max_tokens,
        .loginSessionId = if (login_session_id.len > 0) login_session_id else null,
        .apiKey = if (api_key.len > 0) api_key else null,
        .api_key = if (api_key.len > 0) api_key else null,
    };

    var request_body: std.Io.Writer.Allocating = .init(allocator);
    defer request_body.deinit();
    try std.json.Stringify.value(payload, .{ .emit_null_optional_fields = false }, &request_body.writer);
    const request_payload = try request_body.toOwnedSlice();
    defer allocator.free(request_payload);

    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const started_ms = time_util.nowMs();
    const fetch_result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .POST,
        .payload = request_payload,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
        .response_writer = &response_body.writer,
    }) catch |err| {
        return .{
            .requested = true,
            .ok = false,
            .provider = try allocator.dupe(u8, provider),
            .endpoint = endpoint,
            .requestUrl = request_url,
            .requestTimeoutMs = request_timeout_ms,
            .statusCode = 0,
            .model = try allocator.dupe(u8, model),
            .assistantText = try allocator.dupe(u8, ""),
            .latencyMs = time_util.nowMs() - started_ms,
            .errorText = try std.fmt.allocPrint(allocator, "completion request failed: {s}", .{@errorName(err)}),
        };
    };

    const response_status: u16 = @intCast(@intFromEnum(fetch_result.status));
    const response_json = try response_body.toOwnedSlice();
    defer allocator.free(response_json);

    if (response_status < 200 or response_status >= 300) {
        return .{
            .requested = true,
            .ok = false,
            .provider = try allocator.dupe(u8, provider),
            .endpoint = endpoint,
            .requestUrl = request_url,
            .requestTimeoutMs = request_timeout_ms,
            .statusCode = response_status,
            .model = try allocator.dupe(u8, model),
            .assistantText = try allocator.dupe(u8, ""),
            .latencyMs = time_util.nowMs() - started_ms,
            .errorText = try allocErrorSnippet(allocator, response_json, response_status),
        };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_json, .{}) catch |err| {
        return .{
            .requested = true,
            .ok = false,
            .provider = try allocator.dupe(u8, provider),
            .endpoint = endpoint,
            .requestUrl = request_url,
            .requestTimeoutMs = request_timeout_ms,
            .statusCode = response_status,
            .model = try allocator.dupe(u8, model),
            .assistantText = try allocator.dupe(u8, ""),
            .latencyMs = time_util.nowMs() - started_ms,
            .errorText = try std.fmt.allocPrint(allocator, "invalid bridge JSON: {s}", .{@errorName(err)}),
        };
    };
    defer parsed.deinit();

    const resolved_model = extractModelFromResponse(parsed.value, model);
    const assistant_text = extractAssistantTextFromResponse(parsed.value);

    return .{
        .requested = true,
        .ok = true,
        .provider = try allocator.dupe(u8, provider),
        .endpoint = endpoint,
        .requestUrl = request_url,
        .requestTimeoutMs = request_timeout_ms,
        .statusCode = response_status,
        .model = try allocator.dupe(u8, resolved_model),
        .assistantText = try allocator.dupe(u8, assistant_text),
        .latencyMs = time_util.nowMs() - started_ms,
        .errorText = try allocator.dupe(u8, ""),
    };
}

fn allocErrorSnippet(allocator: std.mem.Allocator, body: []const u8, status_code: u16) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        return std.fmt.allocPrint(allocator, "bridge returned status {d} (empty body)", .{status_code});
    }
    const max_len: usize = 200;
    const prefix = if (trimmed.len > max_len) trimmed[0..max_len] else trimmed;
    if (trimmed.len > max_len) {
        return std.fmt.allocPrint(allocator, "bridge returned status {d}: {s}...", .{ status_code, prefix });
    }
    return std.fmt.allocPrint(allocator, "bridge returned status {d}: {s}", .{ status_code, prefix });
}

fn extractModelFromResponse(value: std.json.Value, fallback: []const u8) []const u8 {
    if (value != .object) return fallback;
    if (value.object.get("model")) |model_value| {
        if (model_value == .string) {
            const trimmed = std.mem.trim(u8, model_value.string, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
    }
    return fallback;
}

fn extractAssistantTextFromResponse(value: std.json.Value) []const u8 {
    if (value != .object) return "";

    if (value.object.get("output_text")) |output_text| {
        if (output_text == .string) {
            const trimmed = std.mem.trim(u8, output_text.string, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
    }

    if (value.object.get("output")) |output_value| {
        if (output_value == .array) {
            for (output_value.array.items) |output_item| {
                const text = extractAssistantTextFromOutputItem(output_item);
                if (text.len > 0) return text;
            }
        }
    }

    if (value.object.get("choices")) |choices_value| {
        if (choices_value == .array) {
            for (choices_value.array.items) |choice| {
                const text = extractAssistantTextFromChoice(choice);
                if (text.len > 0) return text;
            }
        }
    }

    return "";
}

fn extractAssistantTextFromChoice(choice: std.json.Value) []const u8 {
    if (choice != .object) return "";

    if (choice.object.get("message")) |message_value| {
        const text = extractAssistantTextFromMessageValue(message_value);
        if (text.len > 0) return text;
    }

    if (choice.object.get("delta")) |delta_value| {
        const text = extractAssistantTextFromMessageValue(delta_value);
        if (text.len > 0) return text;
    }

    if (choice.object.get("text")) |text_value| {
        if (text_value == .string) {
            const trimmed = std.mem.trim(u8, text_value.string, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
    }

    return "";
}

fn extractAssistantTextFromOutputItem(item: std.json.Value) []const u8 {
    if (item != .object) return "";
    if (item.object.get("content")) |content_value| {
        const text = extractAssistantTextFromMessageContent(content_value);
        if (text.len > 0) return text;
    }
    return "";
}

fn extractAssistantTextFromMessageValue(value: std.json.Value) []const u8 {
    if (value != .object) return "";
    if (value.object.get("content")) |content_value| {
        return extractAssistantTextFromMessageContent(content_value);
    }
    return "";
}

fn extractAssistantTextFromMessageContent(value: std.json.Value) []const u8 {
    switch (value) {
        .string => |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        },
        .array => |arr| {
            for (arr.items) |part| {
                const text = extractAssistantTextFromContentPart(part);
                if (text.len > 0) return text;
            }
        },
        else => {},
    }
    return "";
}

fn extractAssistantTextFromContentPart(value: std.json.Value) []const u8 {
    switch (value) {
        .string => |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        },
        .object => |obj| {
            if (obj.get("text")) |text_value| {
                if (text_value == .string) {
                    const trimmed = std.mem.trim(u8, text_value.string, " \t\r\n");
                    if (trimmed.len > 0) return trimmed;
                }
            }
            if (obj.get("content")) |content_value| {
                if (content_value == .string) {
                    const trimmed = std.mem.trim(u8, content_value.string, " \t\r\n");
                    if (trimmed.len > 0) return trimmed;
                }
            }
        },
        else => {},
    }
    return "";
}

fn normalizeEndpointForProbe(allocator: std.mem.Allocator, endpoint_raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, endpoint_raw, " \t\r\n");
    const endpoint = if (trimmed.len == 0) "http://127.0.0.1:9222" else trimmed;

    const scheme_normalized = blk: {
        if (startsWithIgnoreCase(endpoint, "ws://")) {
            break :blk try std.fmt.allocPrint(allocator, "http://{s}", .{endpoint[5..]});
        }
        if (startsWithIgnoreCase(endpoint, "wss://")) {
            break :blk try std.fmt.allocPrint(allocator, "https://{s}", .{endpoint[6..]});
        }
        if (std.mem.indexOf(u8, endpoint, "://") == null) {
            break :blk try std.fmt.allocPrint(allocator, "http://{s}", .{endpoint});
        }
        break :blk try allocator.dupe(u8, endpoint);
    };
    defer allocator.free(scheme_normalized);

    return allocator.dupe(u8, std.mem.trimEnd(u8, scheme_normalized, "/"));
}

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

test "lightpanda is the only browser provider" {
    try std.testing.expectError(error.UnsupportedEngine, normalizeEngine("playwright"));
    try std.testing.expectError(error.UnsupportedEngine, normalizeEngine("puppeteer"));
    const engine = try normalizeEngine("lightpanda");
    try std.testing.expect(std.mem.eql(u8, engine, "lightpanda"));
}

test "provider aliases normalize to canonical bridge providers" {
    try std.testing.expect(std.mem.eql(u8, try normalizeProvider("copaw"), "qwen"));
    try std.testing.expect(std.mem.eql(u8, try normalizeProvider("glm-5"), "zai"));
    try std.testing.expect(std.mem.eql(u8, try normalizeProvider("mercury2"), "inception"));
}

test "qwen profile exposes guest bypass metadata" {
    const completion = try complete("lightpanda", "qwen", "qwen3.5-plus", "");
    try std.testing.expect(std.mem.eql(u8, completion.engine, "lightpanda"));
    try std.testing.expect(std.mem.eql(u8, completion.provider, "qwen"));
    try std.testing.expect(std.mem.eql(u8, completion.authMode, "guest_or_code"));
    try std.testing.expect(completion.guestBypassSupported);
    try std.testing.expect(std.mem.eql(u8, completion.popupBypassAction, "stay_logged_out"));
}

test "chatgpt profile keeps code auth mode by default" {
    const completion = try complete("lightpanda", "chatgpt", "", "");
    try std.testing.expect(std.mem.eql(u8, completion.provider, "chatgpt"));
    try std.testing.expect(std.mem.eql(u8, completion.model, "gpt-5.2"));
    try std.testing.expect(std.mem.eql(u8, completion.authMode, "device_code"));
    try std.testing.expect(!completion.guestBypassSupported);
}

test "normalize endpoint for probe rewrites ws scheme and strips trailing slash" {
    const allocator = std.testing.allocator;
    const endpoint = try normalizeEndpointForProbe(allocator, "ws://127.0.0.1:9222/");
    defer allocator.free(endpoint);
    try std.testing.expect(std.mem.eql(u8, endpoint, "http://127.0.0.1:9222"));
}

test "probe endpoint returns structured failure for unreachable bridge" {
    const allocator = std.testing.allocator;
    var probe = try probeEndpoint(allocator, "http://127.0.0.1:1");
    defer probe.deinit(allocator);
    try std.testing.expect(!probe.ok);
    try std.testing.expect(probe.statusCode == 0 or probe.statusCode >= 400);
    try std.testing.expect(probe.errorText.len > 0);
}

test "execute completion returns failure telemetry for unreachable endpoint" {
    const allocator = std.testing.allocator;
    const messages = [_]CompletionMessage{
        .{ .role = "user", .content = "hello" },
    };
    var execution = try executeCompletion(
        allocator,
        "http://127.0.0.1:1",
        1500,
        "chatgpt",
        "gpt-5.2",
        messages[0..],
        null,
        null,
        "",
        "",
    );
    defer execution.deinit(allocator);

    try std.testing.expect(execution.requested);
    try std.testing.expect(!execution.ok);
    try std.testing.expect(std.mem.eql(u8, execution.provider, "chatgpt"));
    try std.testing.expect(std.mem.eql(u8, execution.requestUrl, "http://127.0.0.1:1/v1/chat/completions"));
    try std.testing.expect(execution.errorText.len > 0);
}

test "extract assistant text supports output_text and message content arrays" {
    const allocator = std.testing.allocator;
    const output_payload =
        \\{"model":"gpt-5.2","output_text":"from-output-text"}
    ;
    var parsed_output = try std.json.parseFromSlice(std.json.Value, allocator, output_payload, .{});
    defer parsed_output.deinit();
    try std.testing.expect(std.mem.eql(u8, extractAssistantTextFromResponse(parsed_output.value), "from-output-text"));
    try std.testing.expect(std.mem.eql(u8, extractModelFromResponse(parsed_output.value, "fallback"), "gpt-5.2"));

    const array_payload =
        \\{"choices":[{"message":{"content":[{"type":"output_text","text":"from-array"}]}}]}
    ;
    var parsed_array = try std.json.parseFromSlice(std.json.Value, allocator, array_payload, .{});
    defer parsed_array.deinit();
    try std.testing.expect(std.mem.eql(u8, extractAssistantTextFromResponse(parsed_array.value), "from-array"));
}
