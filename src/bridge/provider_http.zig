const std = @import("std");
const lightpanda = @import("lightpanda.zig");
const time_util = @import("../util/time.zig");

const direct_openai_url = "https://api.openai.com/v1/chat/completions";
const direct_gemini_url = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
const direct_openrouter_url = "https://openrouter.ai/api/v1/chat/completions";
const direct_opencode_url = "https://api.opencode.ai/v1/chat/completions";
const direct_anthropic_url = "https://api.anthropic.com/v1/messages";
const anthropic_version = "2023-06-01";

pub fn executeCompletion(
    allocator: std.mem.Allocator,
    provider_raw: []const u8,
    model_raw: []const u8,
    messages: []const lightpanda.CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    api_key_raw: []const u8,
    request_timeout_ms: u32,
    stream_requested: bool,
    endpoint_override_raw: []const u8,
) !lightpanda.BridgeCompletionExecution {
    const normalized_provider = lightpanda.normalizeProvider(provider_raw) catch "";
    if (!isSupportedDirectProvider(normalized_provider)) {
        return .{
            .requested = true,
            .ok = false,
            .provider = try allocator.dupe(u8, if (normalized_provider.len > 0) normalized_provider else std.mem.trim(u8, provider_raw, " \t\r\n")),
            .endpoint = try allocator.dupe(u8, ""),
            .requestUrl = try allocator.dupe(u8, ""),
            .requestTimeoutMs = request_timeout_ms,
            .statusCode = 0,
            .model = try allocator.dupe(u8, normalizedModel(normalized_provider, model_raw)),
            .assistantText = try allocator.dupe(u8, ""),
            .latencyMs = 0,
            .errorText = try allocator.dupe(u8, "unsupported direct provider; supported providers: chatgpt, codex, claude, gemini, openrouter, opencode"),
        };
    }

    const api_key = std.mem.trim(u8, api_key_raw, " \t\r\n");
    if (api_key.len == 0) {
        const model = normalizedModel(normalized_provider, model_raw);
        const direct_endpoint = try resolveDirectEndpointAlloc(
            allocator,
            normalized_provider,
            endpoint_override_raw,
            directEndpointForProvider(normalized_provider),
            directRequestUrlForProvider(normalized_provider),
        );
        errdefer {
            allocator.free(direct_endpoint.endpoint);
            allocator.free(direct_endpoint.request_url);
        }
        return .{
            .requested = true,
            .ok = false,
            .provider = try allocator.dupe(u8, normalized_provider),
            .endpoint = direct_endpoint.endpoint,
            .requestUrl = direct_endpoint.request_url,
            .requestTimeoutMs = request_timeout_ms,
            .statusCode = 0,
            .model = try allocator.dupe(u8, model),
            .assistantText = try allocator.dupe(u8, ""),
            .latencyMs = 0,
            .errorText = try allocator.dupe(u8, "missing API key for direct provider request"),
        };
    }

    if (std.ascii.eqlIgnoreCase(normalized_provider, "claude")) {
        return executeAnthropicCompletion(
            allocator,
            normalized_provider,
            model_raw,
            messages,
            temperature,
            max_tokens,
            api_key,
            request_timeout_ms,
            stream_requested,
            endpoint_override_raw,
        );
    }
    if (std.ascii.eqlIgnoreCase(normalized_provider, "gemini")) {
        return executeGeminiCompletion(
            allocator,
            normalized_provider,
            model_raw,
            messages,
            temperature,
            max_tokens,
            api_key,
            request_timeout_ms,
            stream_requested,
            endpoint_override_raw,
        );
    }
    if (std.ascii.eqlIgnoreCase(normalized_provider, "openrouter")) {
        return executeOpenRouterCompletion(
            allocator,
            normalized_provider,
            model_raw,
            messages,
            temperature,
            max_tokens,
            api_key,
            request_timeout_ms,
            stream_requested,
            endpoint_override_raw,
        );
    }
    if (std.ascii.eqlIgnoreCase(normalized_provider, "opencode")) {
        return executeOpenCodeCompletion(
            allocator,
            normalized_provider,
            model_raw,
            messages,
            temperature,
            max_tokens,
            api_key,
            request_timeout_ms,
            stream_requested,
            endpoint_override_raw,
        );
    }
    return executeOpenAICompletion(
        allocator,
        normalized_provider,
        model_raw,
        messages,
        temperature,
        max_tokens,
        api_key,
        request_timeout_ms,
        stream_requested,
        endpoint_override_raw,
    );
}

fn isSupportedDirectProvider(provider: []const u8) bool {
    return std.ascii.eqlIgnoreCase(provider, "chatgpt") or
        std.ascii.eqlIgnoreCase(provider, "codex") or
        std.ascii.eqlIgnoreCase(provider, "claude") or
        std.ascii.eqlIgnoreCase(provider, "gemini") or
        std.ascii.eqlIgnoreCase(provider, "openrouter") or
        std.ascii.eqlIgnoreCase(provider, "opencode");
}

fn directRequestUrlForProvider(provider: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "claude")) return direct_anthropic_url;
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) return direct_gemini_url;
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) return direct_openrouter_url;
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) return direct_opencode_url;
    return direct_openai_url;
}

fn directEndpointForProvider(provider: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "claude")) return "https://api.anthropic.com";
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) return "https://generativelanguage.googleapis.com";
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) return "https://openrouter.ai";
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) return "https://api.opencode.ai";
    return "https://api.openai.com";
}

fn directRequestPathForProvider(provider: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "claude")) return "/v1/messages";
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) return "/v1beta/openai/chat/completions";
    return "/v1/chat/completions";
}

const DirectEndpoint = struct {
    endpoint: []u8,
    request_url: []u8,
};

fn resolveDirectEndpointAlloc(
    allocator: std.mem.Allocator,
    provider: []const u8,
    endpoint_override_raw: []const u8,
    default_endpoint_url: []const u8,
    default_request_url_value: []const u8,
) !DirectEndpoint {
    const trimmed_override = std.mem.trim(u8, endpoint_override_raw, " \t\r\n");
    if (trimmed_override.len == 0) {
        return .{
            .endpoint = try allocator.dupe(u8, default_endpoint_url),
            .request_url = try allocator.dupe(u8, default_request_url_value),
        };
    }

    var trimmed_override_no_slash = trimmed_override;
    while (trimmed_override_no_slash.len > 0 and trimmed_override_no_slash[trimmed_override_no_slash.len - 1] == '/') {
        trimmed_override_no_slash = trimmed_override_no_slash[0 .. trimmed_override_no_slash.len - 1];
    }
    const request_path = directRequestPathForProvider(provider);
    if (std.mem.endsWith(u8, trimmed_override_no_slash, request_path)) {
        const base = trimmed_override_no_slash[0 .. trimmed_override_no_slash.len - request_path.len];
        const endpoint = if (base.len > 0)
            try allocator.dupe(u8, base)
        else
            try allocator.dupe(u8, trimmed_override_no_slash);
        errdefer allocator.free(endpoint);
        return .{
            .endpoint = endpoint,
            .request_url = try allocator.dupe(u8, trimmed_override_no_slash),
        };
    }

    const endpoint = try allocator.dupe(u8, trimmed_override_no_slash);
    errdefer allocator.free(endpoint);
    return .{
        .endpoint = endpoint,
        .request_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed_override_no_slash, request_path }),
    };
}

fn executeOpenAICompletion(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model_raw: []const u8,
    messages: []const lightpanda.CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    api_key: []const u8,
    request_timeout_ms: u32,
    stream_requested: bool,
    endpoint_override_raw: []const u8,
) !lightpanda.BridgeCompletionExecution {
    return executeOpenAICompatibleCompletion(
        allocator,
        provider,
        model_raw,
        messages,
        temperature,
        max_tokens,
        api_key,
        request_timeout_ms,
        stream_requested,
        "https://api.openai.com",
        direct_openai_url,
        endpoint_override_raw,
    );
}

fn executeOpenRouterCompletion(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model_raw: []const u8,
    messages: []const lightpanda.CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    api_key: []const u8,
    request_timeout_ms: u32,
    stream_requested: bool,
    endpoint_override_raw: []const u8,
) !lightpanda.BridgeCompletionExecution {
    return executeOpenAICompatibleCompletion(
        allocator,
        provider,
        model_raw,
        messages,
        temperature,
        max_tokens,
        api_key,
        request_timeout_ms,
        stream_requested,
        "https://openrouter.ai",
        direct_openrouter_url,
        endpoint_override_raw,
    );
}

fn executeGeminiCompletion(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model_raw: []const u8,
    messages: []const lightpanda.CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    api_key: []const u8,
    request_timeout_ms: u32,
    stream_requested: bool,
    endpoint_override_raw: []const u8,
) !lightpanda.BridgeCompletionExecution {
    return executeOpenAICompatibleCompletion(
        allocator,
        provider,
        model_raw,
        messages,
        temperature,
        max_tokens,
        api_key,
        request_timeout_ms,
        stream_requested,
        "https://generativelanguage.googleapis.com",
        direct_gemini_url,
        endpoint_override_raw,
    );
}

fn executeOpenCodeCompletion(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model_raw: []const u8,
    messages: []const lightpanda.CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    api_key: []const u8,
    request_timeout_ms: u32,
    stream_requested: bool,
    endpoint_override_raw: []const u8,
) !lightpanda.BridgeCompletionExecution {
    return executeOpenAICompatibleCompletion(
        allocator,
        provider,
        model_raw,
        messages,
        temperature,
        max_tokens,
        api_key,
        request_timeout_ms,
        stream_requested,
        "https://api.opencode.ai",
        direct_opencode_url,
        endpoint_override_raw,
    );
}

fn executeOpenAICompatibleCompletion(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model_raw: []const u8,
    messages: []const lightpanda.CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    api_key: []const u8,
    request_timeout_ms: u32,
    stream_requested: bool,
    endpoint_url: []const u8,
    request_url_value: []const u8,
    endpoint_override_raw: []const u8,
) !lightpanda.BridgeCompletionExecution {
    const model = normalizedModel(provider, model_raw);
    const direct_endpoint = try resolveDirectEndpointAlloc(
        allocator,
        provider,
        endpoint_override_raw,
        endpoint_url,
        request_url_value,
    );
    errdefer {
        allocator.free(direct_endpoint.endpoint);
        allocator.free(direct_endpoint.request_url);
    }
    const endpoint = direct_endpoint.endpoint;
    const request_url = direct_endpoint.request_url;

    const Payload = struct {
        model: []const u8,
        messages: []const lightpanda.CompletionMessage,
        temperature: ?f64 = null,
        max_tokens: ?u32 = null,
        stream: bool = false,
    };

    const payload = Payload{
        .model = model,
        .messages = messages,
        .temperature = temperature,
        .max_tokens = max_tokens,
        .stream = stream_requested,
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

    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(authorization);
    var headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = authorization },
        .{ .name = "accept", .value = "text/event-stream" },
    };
    const extra_headers = if (stream_requested) headers[0..3] else headers[0..2];

    const started_ms = time_util.nowMs();
    const fetch_result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .POST,
        .payload = request_payload,
        .keep_alive = false,
        .extra_headers = extra_headers,
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
            .errorText = try std.fmt.allocPrint(allocator, "direct provider request failed: {s}", .{@errorName(err)}),
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

    const assistant_text = if (stream_requested)
        try extractOpenAIStreamTextAlloc(allocator, response_json)
    else
        try extractOpenAIAssistantTextAlloc(allocator, response_json);

    var parsed_model = try allocator.dupe(u8, model);
    if (!stream_requested) {
        const maybe_model = try extractModelFromJsonAlloc(allocator, response_json);
        if (maybe_model) |resolved| {
            allocator.free(parsed_model);
            parsed_model = resolved;
        }
    }

    return .{
        .requested = true,
        .ok = true,
        .provider = try allocator.dupe(u8, provider),
        .endpoint = endpoint,
        .requestUrl = request_url,
        .requestTimeoutMs = request_timeout_ms,
        .statusCode = response_status,
        .model = parsed_model,
        .assistantText = assistant_text,
        .latencyMs = time_util.nowMs() - started_ms,
        .errorText = try allocator.dupe(u8, ""),
    };
}

fn executeAnthropicCompletion(
    allocator: std.mem.Allocator,
    provider: []const u8,
    model_raw: []const u8,
    messages: []const lightpanda.CompletionMessage,
    temperature: ?f64,
    max_tokens: ?u32,
    api_key: []const u8,
    request_timeout_ms: u32,
    stream_requested: bool,
    endpoint_override_raw: []const u8,
) !lightpanda.BridgeCompletionExecution {
    const model = normalizedModel(provider, model_raw);
    const direct_endpoint = try resolveDirectEndpointAlloc(
        allocator,
        provider,
        endpoint_override_raw,
        "https://api.anthropic.com",
        direct_anthropic_url,
    );
    errdefer {
        allocator.free(direct_endpoint.endpoint);
        allocator.free(direct_endpoint.request_url);
    }
    const endpoint = direct_endpoint.endpoint;
    const request_url = direct_endpoint.request_url;

    const Payload = struct {
        model: []const u8,
        max_tokens: u32,
        messages: []const lightpanda.CompletionMessage,
        temperature: ?f64 = null,
        stream: bool = false,
    };

    const payload = Payload{
        .model = model,
        .max_tokens = max_tokens orelse 1024,
        .messages = messages,
        .temperature = temperature,
        .stream = stream_requested,
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

    var headers = [_]std.http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "x-api-key", .value = api_key },
        .{ .name = "anthropic-version", .value = anthropic_version },
        .{ .name = "accept", .value = "text/event-stream" },
    };
    const extra_headers = if (stream_requested) headers[0..4] else headers[0..3];

    const started_ms = time_util.nowMs();
    const fetch_result = client.fetch(.{
        .location = .{ .url = request_url },
        .method = .POST,
        .payload = request_payload,
        .keep_alive = false,
        .extra_headers = extra_headers,
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
            .errorText = try std.fmt.allocPrint(allocator, "direct provider request failed: {s}", .{@errorName(err)}),
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

    const assistant_text = if (stream_requested)
        try extractAnthropicStreamTextAlloc(allocator, response_json)
    else
        try extractAnthropicAssistantTextAlloc(allocator, response_json);

    return .{
        .requested = true,
        .ok = true,
        .provider = try allocator.dupe(u8, provider),
        .endpoint = endpoint,
        .requestUrl = request_url,
        .requestTimeoutMs = request_timeout_ms,
        .statusCode = response_status,
        .model = try allocator.dupe(u8, model),
        .assistantText = assistant_text,
        .latencyMs = time_util.nowMs() - started_ms,
        .errorText = try allocator.dupe(u8, ""),
    };
}

fn normalizedModel(provider: []const u8, model_raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, model_raw, " \t\r\n");
    if (trimmed.len > 0) return trimmed;
    if (std.ascii.eqlIgnoreCase(provider, "claude")) return "claude-opus-4";
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) return "gemini-2.5-pro";
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) return "openai/gpt-5.2-mini";
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) return "opencode/default";
    return "gpt-5.2";
}

fn allocErrorSnippet(allocator: std.mem.Allocator, body: []const u8, status_code: u16) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        return std.fmt.allocPrint(allocator, "direct provider returned status {d} (empty body)", .{status_code});
    }
    const max_len: usize = 200;
    const prefix = if (trimmed.len > max_len) trimmed[0..max_len] else trimmed;
    if (trimmed.len > max_len) {
        return std.fmt.allocPrint(allocator, "direct provider returned status {d}: {s}...", .{ status_code, prefix });
    }
    return std.fmt.allocPrint(allocator, "direct provider returned status {d}: {s}", .{ status_code, prefix });
}

fn extractModelFromJsonAlloc(allocator: std.mem.Allocator, payload: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (parsed.value.object.get("model")) |value| {
        if (value == .string) {
            const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
            if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
        }
    }
    return null;
}

fn extractOpenAIAssistantTextAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        return allocator.dupe(u8, "");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "");
    if (parsed.value.object.get("choices")) |choices| {
        if (choices == .array) {
            for (choices.array.items) |choice| {
                if (choice != .object) continue;
                if (choice.object.get("message")) |message| {
                    if (message != .object) continue;
                    if (message.object.get("content")) |content| {
                        if (content == .string) {
                            return allocator.dupe(u8, std.mem.trim(u8, content.string, " \t\r\n"));
                        }
                    }
                }
            }
        }
    }
    return allocator.dupe(u8, "");
}

fn extractAnthropicAssistantTextAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        return allocator.dupe(u8, "");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "");
    if (parsed.value.object.get("content")) |content| {
        if (content == .array) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            for (content.array.items) |item| {
                if (item != .object) continue;
                const kind = item.object.get("type") orelse continue;
                if (kind != .string or !std.ascii.eqlIgnoreCase(std.mem.trim(u8, kind.string, " \t\r\n"), "text")) continue;
                const text = item.object.get("text") orelse continue;
                if (text != .string) continue;
                const trimmed = std.mem.trim(u8, text.string, " \t\r\n");
                if (trimmed.len == 0) continue;
                if (out.items.len > 0) try out.append(allocator, '\n');
                try out.appendSlice(allocator, trimmed);
            }
            return out.toOwnedSlice(allocator);
        }
    }
    return allocator.dupe(u8, "");
}

fn extractOpenAIStreamTextAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " \t\r\n");
        if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const choices = parsed.value.object.get("choices") orelse continue;
        if (choices != .array) continue;
        for (choices.array.items) |choice| {
            if (choice != .object) continue;
            const delta = choice.object.get("delta") orelse continue;
            if (delta != .object) continue;
            const content = delta.object.get("content") orelse continue;
            if (content != .string) continue;
            const text = std.mem.trim(u8, content.string, " \t\r\n");
            if (text.len == 0) continue;
            if (out.items.len > 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, text);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn extractAnthropicStreamTextAlloc(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const data = std.mem.trim(u8, line["data:".len..], " \t\r\n");
        if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event_type = parsed.value.object.get("type") orelse continue;
        if (event_type != .string) continue;
        const event_name = std.mem.trim(u8, event_type.string, " \t\r\n");

        if (std.ascii.eqlIgnoreCase(event_name, "content_block_delta")) {
            const delta = parsed.value.object.get("delta") orelse continue;
            if (delta != .object) continue;
            const text = delta.object.get("text") orelse continue;
            if (text != .string) continue;
            const trimmed = std.mem.trim(u8, text.string, " \t\r\n");
            if (trimmed.len == 0) continue;
            if (out.items.len > 0) try out.append(allocator, ' ');
            try out.appendSlice(allocator, trimmed);
        }
    }
    return out.toOwnedSlice(allocator);
}

test "direct provider completion rejects unsupported providers deterministically" {
    const allocator = std.testing.allocator;
    const messages = [_]lightpanda.CompletionMessage{
        .{ .role = "user", .content = "hello" },
    };
    var execution = try executeCompletion(allocator, "qwen", "", messages[0..], null, null, "test-key", 1500, false, "");
    defer execution.deinit(allocator);
    try std.testing.expect(execution.requested);
    try std.testing.expect(!execution.ok);
    try std.testing.expect(std.mem.indexOf(u8, execution.errorText, "unsupported direct provider") != null);
}

test "direct provider completion requires api key" {
    const allocator = std.testing.allocator;
    const messages = [_]lightpanda.CompletionMessage{
        .{ .role = "user", .content = "hello" },
    };
    var execution = try executeCompletion(allocator, "chatgpt", "gpt-5.2", messages[0..], null, null, "", 1500, false, "");
    defer execution.deinit(allocator);
    try std.testing.expect(execution.requested);
    try std.testing.expect(!execution.ok);
    try std.testing.expect(std.mem.indexOf(u8, execution.errorText, "missing API key") != null);
}

test "direct provider openrouter requires api key and reports openrouter endpoint" {
    const allocator = std.testing.allocator;
    const messages = [_]lightpanda.CompletionMessage{
        .{ .role = "user", .content = "hello" },
    };
    var execution = try executeCompletion(allocator, "openrouter", "", messages[0..], null, null, "", 1500, false, "");
    defer execution.deinit(allocator);
    try std.testing.expect(execution.requested);
    try std.testing.expect(!execution.ok);
    try std.testing.expect(std.mem.eql(u8, execution.provider, "openrouter"));
    try std.testing.expect(std.mem.indexOf(u8, execution.requestUrl, "openrouter.ai/api/v1/chat/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.errorText, "missing API key") != null);
}

test "direct provider gemini requires api key and reports gemini endpoint" {
    const allocator = std.testing.allocator;
    const messages = [_]lightpanda.CompletionMessage{
        .{ .role = "user", .content = "hello" },
    };
    var execution = try executeCompletion(allocator, "gemini", "", messages[0..], null, null, "", 1500, false, "");
    defer execution.deinit(allocator);
    try std.testing.expect(execution.requested);
    try std.testing.expect(!execution.ok);
    try std.testing.expect(std.mem.eql(u8, execution.provider, "gemini"));
    try std.testing.expect(std.mem.indexOf(u8, execution.requestUrl, "generativelanguage.googleapis.com/v1beta/openai/chat/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.errorText, "missing API key") != null);
    try std.testing.expect(std.mem.eql(u8, execution.model, "gemini-2.5-pro"));
}

test "direct provider opencode requires api key and reports opencode endpoint" {
    const allocator = std.testing.allocator;
    const messages = [_]lightpanda.CompletionMessage{
        .{ .role = "user", .content = "hello" },
    };
    var execution = try executeCompletion(allocator, "opencode", "", messages[0..], null, null, "", 1500, false, "");
    defer execution.deinit(allocator);
    try std.testing.expect(execution.requested);
    try std.testing.expect(!execution.ok);
    try std.testing.expect(std.mem.eql(u8, execution.provider, "opencode"));
    try std.testing.expect(std.mem.indexOf(u8, execution.requestUrl, "api.opencode.ai/v1/chat/completions") != null);
    try std.testing.expect(std.mem.indexOf(u8, execution.errorText, "missing API key") != null);
}

test "direct provider missing key honors explicit endpoint override" {
    const allocator = std.testing.allocator;
    const messages = [_]lightpanda.CompletionMessage{
        .{ .role = "user", .content = "hello" },
    };
    var execution = try executeCompletion(
        allocator,
        "chatgpt",
        "gpt-5.2",
        messages[0..],
        null,
        null,
        "",
        1500,
        false,
        "http://127.0.0.1:4010",
    );
    defer execution.deinit(allocator);
    try std.testing.expect(execution.requested);
    try std.testing.expect(!execution.ok);
    try std.testing.expect(std.mem.eql(u8, execution.endpoint, "http://127.0.0.1:4010"));
    try std.testing.expect(std.mem.eql(u8, execution.requestUrl, "http://127.0.0.1:4010/v1/chat/completions"));
    try std.testing.expect(std.mem.indexOf(u8, execution.errorText, "missing API key") != null);
}

test "openai stream parser extracts assistant text from sse chunks" {
    const allocator = std.testing.allocator;
    const sse =
        \\event: message
        \\data: {"choices":[{"delta":{"content":"hello"}}]}
        \\
        \\data: {"choices":[{"delta":{"content":"world"}}]}
        \\data: [DONE]
    ;
    const text = try extractOpenAIStreamTextAlloc(allocator, sse);
    defer allocator.free(text);
    try std.testing.expect(std.mem.eql(u8, text, "hello world"));
}

test "anthropic stream parser extracts assistant text from sse chunks" {
    const allocator = std.testing.allocator;
    const sse =
        \\event: content_block_delta
        \\data: {"type":"content_block_delta","delta":{"text":"alpha"}}
        \\
        \\data: {"type":"content_block_delta","delta":{"text":"beta"}}
    ;
    const text = try extractAnthropicStreamTextAlloc(allocator, sse);
    defer allocator.free(text);
    try std.testing.expect(std.mem.eql(u8, text, "alpha beta"));
}
