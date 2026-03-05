const std = @import("std");
const pal = @import("../pal/mod.zig");

pub const IncomingUpdate = struct {
    update_id: i64,
    chat_id: i64,
    message_id: ?i64,
    from_id: ?i64,
    text: []u8,
    source: []u8,

    pub fn deinit(self: *IncomingUpdate, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.source);
    }
};

pub const BotDeliveryResult = struct {
    attempted: bool,
    ok: bool,
    statusCode: u16,
    requestUrl: []u8,
    errorText: []u8,
    messageId: ?i64,
    responseBytes: usize,
    latencyMs: i64,
    requestTimeoutMs: u32,

    pub fn deinit(self: *BotDeliveryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.requestUrl);
        allocator.free(self.errorText);
    }
};

pub fn parseIncomingUpdateFromValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !?IncomingUpdate {
    if (value != .object) return null;
    const root = value.object;
    const update_id = intFromMap(root, "update_id") orelse 0;

    if (root.get("message")) |message_value| {
        if (message_value == .object) {
            return parseMessageLike(allocator, update_id, message_value.object, "message");
        }
    }

    if (root.get("edited_message")) |message_value| {
        if (message_value == .object) {
            return parseMessageLike(allocator, update_id, message_value.object, "edited_message");
        }
    }

    if (root.get("callback_query")) |callback_value| {
        if (callback_value == .object) {
            return parseCallbackQuery(allocator, update_id, callback_value.object);
        }
    }

    return null;
}

pub fn buildRuntimeSendFrameAlloc(
    allocator: std.mem.Allocator,
    rpc_id: []const u8,
    target: []const u8,
    session_id: []const u8,
    message: []const u8,
) ![]u8 {
    const Frame = struct {
        id: []const u8,
        method: []const u8,
        params: struct {
            channel: []const u8,
            to: []const u8,
            sessionId: []const u8,
            message: []const u8,
        },
    };

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try std.json.Stringify.value(Frame{
        .id = rpc_id,
        .method = "send",
        .params = .{
            .channel = "telegram",
            .to = target,
            .sessionId = session_id,
            .message = message,
        },
    }, .{ .emit_null_optional_fields = false }, &writer.writer);
    return writer.toOwnedSlice();
}

pub fn sendMessage(
    allocator: std.mem.Allocator,
    bot_token_raw: []const u8,
    chat_id: i64,
    text_raw: []const u8,
    reply_to_message_id: ?i64,
    request_timeout_ms: u32,
) !BotDeliveryResult {
    const bot_token = std.mem.trim(u8, bot_token_raw, " \t\r\n");
    const text = std.mem.trim(u8, text_raw, " \t\r\n");

    if (bot_token.len == 0) {
        return .{
            .attempted = false,
            .ok = false,
            .statusCode = 0,
            .requestUrl = try allocator.dupe(u8, ""),
            .errorText = try allocator.dupe(u8, "missing bot token"),
            .messageId = null,
            .responseBytes = 0,
            .latencyMs = 0,
            .requestTimeoutMs = request_timeout_ms,
        };
    }
    if (text.len == 0) {
        return .{
            .attempted = false,
            .ok = false,
            .statusCode = 0,
            .requestUrl = try allocator.dupe(u8, ""),
            .errorText = try allocator.dupe(u8, "missing text"),
            .messageId = null,
            .responseBytes = 0,
            .latencyMs = 0,
            .requestTimeoutMs = request_timeout_ms,
        };
    }

    const request_url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendMessage", .{bot_token});
    errdefer allocator.free(request_url);

    const Payload = struct {
        chat_id: i64,
        text: []const u8,
        reply_to_message_id: ?i64 = null,
        allow_sending_without_reply: bool = true,
    };

    const payload = Payload{
        .chat_id = chat_id,
        .text = text,
        .reply_to_message_id = reply_to_message_id,
        .allow_sending_without_reply = true,
    };

    var request_body: std.Io.Writer.Allocating = .init(allocator);
    defer request_body.deinit();
    try std.json.Stringify.value(payload, .{ .emit_null_optional_fields = false }, &request_body.writer);
    const request_payload = try request_body.toOwnedSlice();
    defer allocator.free(request_payload);

    var fetch_response = pal.net.post(
        allocator,
        request_url,
        request_payload,
        &.{.{ .name = "content-type", .value = "application/json" }},
    ) catch |err| {
        return .{
            .attempted = true,
            .ok = false,
            .statusCode = 0,
            .requestUrl = request_url,
            .errorText = try std.fmt.allocPrint(allocator, "telegram sendMessage request failed: {s}", .{@errorName(err)}),
            .messageId = null,
            .responseBytes = 0,
            .latencyMs = 0,
            .requestTimeoutMs = request_timeout_ms,
        };
    };
    defer fetch_response.deinit(allocator);

    const status_code = fetch_response.status_code;
    const response_payload = fetch_response.body;

    if (status_code < 200 or status_code >= 300) {
        return .{
            .attempted = true,
            .ok = false,
            .statusCode = status_code,
            .requestUrl = request_url,
            .errorText = try allocErrorSnippet(allocator, response_payload, status_code),
            .messageId = null,
            .responseBytes = response_payload.len,
            .latencyMs = fetch_response.latency_ms,
            .requestTimeoutMs = request_timeout_ms,
        };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_payload, .{}) catch |err| {
        return .{
            .attempted = true,
            .ok = false,
            .statusCode = status_code,
            .requestUrl = request_url,
            .errorText = try std.fmt.allocPrint(allocator, "invalid telegram sendMessage JSON: {s}", .{@errorName(err)}),
            .messageId = null,
            .responseBytes = response_payload.len,
            .latencyMs = fetch_response.latency_ms,
            .requestTimeoutMs = request_timeout_ms,
        };
    };
    defer parsed.deinit();

    const ok = boolFromMap(parsed.value, "ok") orelse false;
    const message_id = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("result")) |result_value| {
                break :blk intFromNested(result_value, "message_id");
            }
        }
        break :blk null;
    };
    const error_text = if (!ok)
        (stringFromMap(parsed.value, "description") orelse "telegram sendMessage returned ok=false")
    else
        "";

    return .{
        .attempted = true,
        .ok = ok,
        .statusCode = status_code,
        .requestUrl = request_url,
        .errorText = try allocator.dupe(u8, error_text),
        .messageId = message_id,
        .responseBytes = response_payload.len,
        .latencyMs = fetch_response.latency_ms,
        .requestTimeoutMs = request_timeout_ms,
    };
}

pub fn sendChatAction(
    allocator: std.mem.Allocator,
    bot_token_raw: []const u8,
    chat_id: i64,
    action_raw: []const u8,
    request_timeout_ms: u32,
) !BotDeliveryResult {
    const bot_token = std.mem.trim(u8, bot_token_raw, " \t\r\n");
    const action = std.mem.trim(u8, action_raw, " \t\r\n");

    if (bot_token.len == 0) {
        return .{
            .attempted = false,
            .ok = false,
            .statusCode = 0,
            .requestUrl = try allocator.dupe(u8, ""),
            .errorText = try allocator.dupe(u8, "missing bot token"),
            .messageId = null,
            .responseBytes = 0,
            .latencyMs = 0,
            .requestTimeoutMs = request_timeout_ms,
        };
    }
    if (action.len == 0) {
        return .{
            .attempted = false,
            .ok = false,
            .statusCode = 0,
            .requestUrl = try allocator.dupe(u8, ""),
            .errorText = try allocator.dupe(u8, "missing action"),
            .messageId = null,
            .responseBytes = 0,
            .latencyMs = 0,
            .requestTimeoutMs = request_timeout_ms,
        };
    }

    const request_url = try std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/sendChatAction", .{bot_token});
    errdefer allocator.free(request_url);

    const Payload = struct {
        chat_id: i64,
        action: []const u8,
    };

    var request_body: std.Io.Writer.Allocating = .init(allocator);
    defer request_body.deinit();
    try std.json.Stringify.value(Payload{ .chat_id = chat_id, .action = action }, .{}, &request_body.writer);
    const request_payload = try request_body.toOwnedSlice();
    defer allocator.free(request_payload);

    var fetch_response = pal.net.post(
        allocator,
        request_url,
        request_payload,
        &.{.{ .name = "content-type", .value = "application/json" }},
    ) catch |err| {
        return .{
            .attempted = true,
            .ok = false,
            .statusCode = 0,
            .requestUrl = request_url,
            .errorText = try std.fmt.allocPrint(allocator, "telegram sendChatAction request failed: {s}", .{@errorName(err)}),
            .messageId = null,
            .responseBytes = 0,
            .latencyMs = 0,
            .requestTimeoutMs = request_timeout_ms,
        };
    };
    defer fetch_response.deinit(allocator);

    const status_code = fetch_response.status_code;
    const response_payload = fetch_response.body;

    if (status_code < 200 or status_code >= 300) {
        return .{
            .attempted = true,
            .ok = false,
            .statusCode = status_code,
            .requestUrl = request_url,
            .errorText = try allocErrorSnippet(allocator, response_payload, status_code),
            .messageId = null,
            .responseBytes = response_payload.len,
            .latencyMs = fetch_response.latency_ms,
            .requestTimeoutMs = request_timeout_ms,
        };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_payload, .{}) catch |err| {
        return .{
            .attempted = true,
            .ok = false,
            .statusCode = status_code,
            .requestUrl = request_url,
            .errorText = try std.fmt.allocPrint(allocator, "invalid telegram sendChatAction JSON: {s}", .{@errorName(err)}),
            .messageId = null,
            .responseBytes = response_payload.len,
            .latencyMs = fetch_response.latency_ms,
            .requestTimeoutMs = request_timeout_ms,
        };
    };
    defer parsed.deinit();

    const ok = boolFromMap(parsed.value, "ok") orelse false;
    const error_text = if (!ok)
        (stringFromMap(parsed.value, "description") orelse "telegram sendChatAction returned ok=false")
    else
        "";

    return .{
        .attempted = true,
        .ok = ok,
        .statusCode = status_code,
        .requestUrl = request_url,
        .errorText = try allocator.dupe(u8, error_text),
        .messageId = null,
        .responseBytes = response_payload.len,
        .latencyMs = fetch_response.latency_ms,
        .requestTimeoutMs = request_timeout_ms,
    };
}

fn parseMessageLike(
    allocator: std.mem.Allocator,
    update_id: i64,
    message: std.json.ObjectMap,
    source: []const u8,
) !?IncomingUpdate {
    const chat_id = if (message.get("chat")) |chat_value|
        intFromNested(chat_value, "id")
    else
        null;
    const text = if (message.get("text")) |value|
        stringFromValue(value)
    else if (message.get("caption")) |value|
        stringFromValue(value)
    else
        null;

    if (chat_id == null or text == null) return null;
    return .{
        .update_id = update_id,
        .chat_id = chat_id.?,
        .message_id = intFromMap(message, "message_id"),
        .from_id = if (message.get("from")) |from_value| intFromNested(from_value, "id") else null,
        .text = try allocator.dupe(u8, text.?),
        .source = try allocator.dupe(u8, source),
    };
}

fn parseCallbackQuery(
    allocator: std.mem.Allocator,
    update_id: i64,
    callback_query: std.json.ObjectMap,
) !?IncomingUpdate {
    const message_value = callback_query.get("message") orelse return null;
    if (message_value != .object) return null;

    const chat_id = if (message_value.object.get("chat")) |chat_value|
        intFromNested(chat_value, "id")
    else
        null;
    const text = if (callback_query.get("data")) |value|
        stringFromValue(value)
    else if (message_value.object.get("text")) |value|
        stringFromValue(value)
    else
        null;

    if (chat_id == null or text == null) return null;
    return .{
        .update_id = update_id,
        .chat_id = chat_id.?,
        .message_id = intFromMap(message_value.object, "message_id"),
        .from_id = if (callback_query.get("from")) |from_value| intFromNested(from_value, "id") else null,
        .text = try allocator.dupe(u8, text.?),
        .source = try allocator.dupe(u8, "callback_query"),
    };
}

fn intFromMap(map: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = map.get(key) orelse return null;
    return intFromValue(value);
}

fn intFromNested(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    return intFromMap(value.object, key);
}

fn intFromValue(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |raw| raw,
        .float => |raw| @as(i64, @intFromFloat(raw)),
        .string => |raw| blk: {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len == 0) break :blk null;
            break :blk std.fmt.parseInt(i64, trimmed, 10) catch null;
        },
        else => null,
    };
}

fn stringFromMap(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const child = value.object.get(key) orelse return null;
    return stringFromValue(child);
}

fn stringFromValue(value: std.json.Value) ?[]const u8 {
    if (value != .string) return null;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0) return null;
    return trimmed;
}

fn boolFromMap(value: std.json.Value, key: []const u8) ?bool {
    if (value != .object) return null;
    const child = value.object.get(key) orelse return null;
    if (child != .bool) return null;
    return child.bool;
}

fn allocErrorSnippet(allocator: std.mem.Allocator, body: []const u8, status_code: u16) ![]u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return std.fmt.allocPrint(allocator, "telegram sendMessage status {d} (empty body)", .{status_code});
    const max_len: usize = 200;
    const prefix = if (trimmed.len > max_len) trimmed[0..max_len] else trimmed;
    if (trimmed.len > max_len) {
        return std.fmt.allocPrint(allocator, "telegram sendMessage status {d}: {s}...", .{ status_code, prefix });
    }
    return std.fmt.allocPrint(allocator, "telegram sendMessage status {d}: {s}", .{ status_code, prefix });
}

test "parse incoming update handles message payload" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"update_id":1,"message":{"message_id":77,"from":{"id":11},"chat":{"id":12345,"type":"private"},"text":"hello bot"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    var incoming = (try parseIncomingUpdateFromValue(allocator, parsed.value)).?;
    defer incoming.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1), incoming.update_id);
    try std.testing.expectEqual(@as(i64, 12345), incoming.chat_id);
    try std.testing.expectEqual(@as(?i64, 77), incoming.message_id);
    try std.testing.expectEqual(@as(?i64, 11), incoming.from_id);
    try std.testing.expect(std.mem.eql(u8, incoming.text, "hello bot"));
    try std.testing.expect(std.mem.eql(u8, incoming.source, "message"));
}

test "parse incoming update handles callback query payload" {
    const allocator = std.testing.allocator;
    const payload =
        \\{"update_id":2,"callback_query":{"id":"cbq-1","from":{"id":99},"data":"btn_yes","message":{"message_id":88,"chat":{"id":-123456}}}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();

    var incoming = (try parseIncomingUpdateFromValue(allocator, parsed.value)).?;
    defer incoming.deinit(allocator);
    try std.testing.expectEqual(@as(i64, -123456), incoming.chat_id);
    try std.testing.expect(std.mem.eql(u8, incoming.text, "btn_yes"));
    try std.testing.expect(std.mem.eql(u8, incoming.source, "callback_query"));
}

test "build runtime send frame produces send method payload" {
    const allocator = std.testing.allocator;
    const frame = try buildRuntimeSendFrameAlloc(allocator, "tg-webhook-1", "12345", "tg-chat-12345", "hello");
    defer allocator.free(frame);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"method\":\"send\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"channel\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\"sessionId\":\"tg-chat-12345\"") != null);
}

test "sendMessage returns deterministic error when bot token missing" {
    const allocator = std.testing.allocator;
    var result = try sendMessage(allocator, "", 12345, "hello", null, 3000);
    defer result.deinit(allocator);
    try std.testing.expect(!result.attempted);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.errorText, "missing bot token") != null);
}

test "sendChatAction returns deterministic error when bot token missing" {
    const allocator = std.testing.allocator;
    var result = try sendChatAction(allocator, "", 12345, "typing", 3000);
    defer result.deinit(allocator);
    try std.testing.expect(!result.attempted);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.errorText, "missing bot token") != null);
}
