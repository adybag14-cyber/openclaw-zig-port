const std = @import("std");
const config = @import("../config.zig");
const protocol = @import("../protocol/envelope.zig");
const dispatcher = @import("dispatcher.zig");
const time_util = @import("../util/time.zig");

pub const ServeOptions = struct {
    max_connections: ?usize = null,
};

pub const RouteResponse = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []u8,
};

pub const RouteContext = struct {
    rpc_authorized: bool = true,
    rpc_rate_limited: bool = false,
};

const RateLimiter = struct {
    enabled: bool,
    window_ms: i64,
    max_requests: usize,
    window_start_ms: i64,
    used_in_window: usize,

    fn init(gateway: config.GatewayConfig) RateLimiter {
        const valid_window = if (gateway.rate_limit_window_ms == 0) @as(i64, 60_000) else @as(i64, @intCast(gateway.rate_limit_window_ms));
        const valid_max = if (gateway.rate_limit_max_requests == 0) @as(usize, 1) else @as(usize, @intCast(gateway.rate_limit_max_requests));
        return .{
            .enabled = gateway.rate_limit_enabled,
            .window_ms = valid_window,
            .max_requests = valid_max,
            .window_start_ms = 0,
            .used_in_window = 0,
        };
    }

    fn allow(self: *RateLimiter, now_ms: i64) bool {
        if (!self.enabled) return true;
        if (self.window_start_ms == 0 or (now_ms - self.window_start_ms) >= self.window_ms) {
            self.window_start_ms = now_ms;
            self.used_in_window = 0;
        }
        if (self.used_in_window >= self.max_requests) return false;
        self.used_in_window += 1;
        return true;
    }
};

const max_rpc_body_bytes: usize = 1024 * 1024;
const ws_stream_chunk_min_bytes: usize = 256;
const ws_stream_chunk_default_fallback_bytes: usize = 4096;
const ws_stream_chunk_max_fallback_bytes: usize = 64 * 1024;

const WebSocketStreamOptions = struct {
    enabled: bool = false,
    chunk_bytes: usize,
};

const control_ui_html =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8" />
    \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
    \\  <title>OpenClaw Zig Control UI</title>
    \\  <style>
    \\    :root { color-scheme: dark; }
    \\    body { margin: 0; font-family: "Segoe UI", sans-serif; background: #0f172a; color: #e2e8f0; }
    \\    main { max-width: 920px; margin: 24px auto; padding: 0 16px 24px; }
    \\    h1 { margin: 0 0 8px; font-size: 1.6rem; }
    \\    p { margin: 0 0 16px; color: #cbd5e1; }
    \\    .row { display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 12px; }
    \\    input, button { border-radius: 8px; border: 1px solid #334155; background: #111827; color: #f8fafc; padding: 8px 10px; }
    \\    input { min-width: 220px; }
    \\    button { cursor: pointer; }
    \\    button:hover { background: #1f2937; }
    \\    pre { background: #020617; border: 1px solid #1e293b; border-radius: 10px; padding: 12px; min-height: 260px; overflow: auto; }
    \\    code { color: #93c5fd; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <main>
    \\    <h1>OpenClaw Zig Control UI</h1>
    \\    <p>Bootstrap controls for <code>status</code>, <code>doctor</code>, <code>logs.tail</code>, and <code>node.pair.list</code>.</p>
    \\    <div class="row">
    \\      <input id="token" type="password" placeholder="Gateway token (if required)" />
    \\      <input id="logsLimit" type="number" min="1" value="25" />
    \\    </div>
    \\    <div class="row">
    \\      <button onclick="runRpc('status', {})">Status</button>
    \\      <button onclick="runRpc('doctor', {})">Doctor</button>
    \\      <button onclick="runLogs()">Logs</button>
    \\      <button onclick="runRpc('node.pair.list', {})">Node Pairs</button>
    \\    </div>
    \\    <pre id="output">Ready.</pre>
    \\  </main>
    \\  <script>
    \\    const output = document.getElementById('output');
    \\    const tokenInput = document.getElementById('token');
    \\    const logsLimitInput = document.getElementById('logsLimit');
    \\
    \\    async function runRpc(method, params) {
    \\      const headers = { 'content-type': 'application/json' };
    \\      const token = tokenInput.value.trim();
    \\      if (token) headers.authorization = 'Bearer ' + token;
    \\      const frame = {
    \\        jsonrpc: '2.0',
    \\        id: 'ui-' + Date.now(),
    \\        method: method,
    \\        params: params
    \\      };
    \\      try {
    \\        const res = await fetch('/rpc', {
    \\          method: 'POST',
    \\          headers: headers,
    \\          body: JSON.stringify(frame)
    \\        });
    \\        const text = await res.text();
    \\        try {
    \\          output.textContent = JSON.stringify(JSON.parse(text), null, 2);
    \\        } catch (_err) {
    \\          output.textContent = text;
    \\        }
    \\      } catch (err) {
    \\        output.textContent = 'request failed: ' + err;
    \\      }
    \\    }
    \\
    \\    async function runLogs() {
    \\      const parsed = Number.parseInt(logsLimitInput.value || '25', 10);
    \\      const limit = Number.isFinite(parsed) && parsed > 0 ? parsed : 25;
    \\      await runRpc('logs.tail', { limit: limit });
    \\    }
    \\
    \\    window.runRpc = runRpc;
    \\    window.runLogs = runLogs;
    \\  </script>
    \\</body>
    \\</html>
;

pub fn serve(allocator: std.mem.Allocator, cfg: config.Config, options: ServeOptions) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address = try std.Io.net.IpAddress.resolve(io, cfg.http_bind, cfg.http_port);
    var net_server = try address.listen(io, .{ .reuse_address = true });
    defer net_server.deinit(io);

    var accepted: usize = 0;
    var should_shutdown = false;
    var rate_limiter = RateLimiter.init(cfg.gateway);

    while (!should_shutdown) {
        if (options.max_connections) |max_connections| {
            if (accepted >= max_connections) break;
        }

        var stream = net_server.accept(io) catch |err| switch (err) {
            error.SocketNotListening => break,
            else => |e| return e,
        };
        defer stream.close(io);
        accepted += 1;

        var recv_buffer: [16 * 1024]u8 = undefined;
        var send_buffer: [16 * 1024]u8 = undefined;
        var connection_br = stream.reader(io, &recv_buffer);
        var connection_bw = stream.writer(io, &send_buffer);
        var http_server = std.http.Server.init(&connection_br.interface, &connection_bw.interface);

        while (!should_shutdown and http_server.reader.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => break,
                else => |e| return e,
            };
            const upgraded = try serveRequest(allocator, cfg, &rate_limiter, &request, &should_shutdown);
            if (upgraded) break;
        }
    }
}

pub fn routeRequest(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    context: RouteContext,
    method: std.http.Method,
    target: []const u8,
    body: []const u8,
    should_shutdown: *bool,
) !RouteResponse {
    const target_path = pathFromTarget(target);

    if (method == .GET and std.mem.eql(u8, target_path, "/health")) {
        return .{
            .status = .ok,
            .content_type = "application/json",
            .body = try protocol.encodeResult(allocator, "health", .{
                .status = "ok",
                .service = "openclaw-zig",
                .bridge = "lightpanda",
                .configHash = config.fingerprintHex(cfg),
            }),
        };
    }

    if (method == .GET and (std.mem.eql(u8, target_path, "/ui") or std.mem.eql(u8, target_path, "/ui/"))) {
        return .{
            .status = .ok,
            .content_type = "text/html; charset=utf-8",
            .body = try allocator.dupe(u8, control_ui_html),
        };
    }

    if (std.mem.eql(u8, target_path, "/rpc")) {
        const token_required = bindRequiresGatewayToken(cfg);
        if (method != .POST) {
            return .{
                .status = .method_not_allowed,
                .content_type = "application/json",
                .body = try encodeJson(allocator, .{ .@"error" = "method_not_allowed", .allowed = "POST /rpc" }),
            };
        }

        if (token_required and !gatewayTokenConfigured(cfg)) {
            return .{
                .status = .forbidden,
                .content_type = "application/json",
                .body = try encodeJson(allocator, .{
                    .@"error" = "gateway_token_unconfigured",
                    .detail = "non-loopback bind requires OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN",
                }),
            };
        }

        if (token_required and !context.rpc_authorized) {
            return .{
                .status = .unauthorized,
                .content_type = "application/json",
                .body = try encodeJson(allocator, .{ .@"error" = "unauthorized", .detail = "missing or invalid gateway token" }),
            };
        }

        if (context.rpc_rate_limited) {
            return .{
                .status = .too_many_requests,
                .content_type = "application/json",
                .body = try encodeJson(allocator, .{ .@"error" = "rate_limited", .detail = "gateway rpc rate limit exceeded" }),
            };
        }

        var parsed = protocol.parseRequest(allocator, body) catch null;
        defer if (parsed) |*req| req.deinit(allocator);
        if (parsed) |req| {
            if (std.ascii.eqlIgnoreCase(req.method, "shutdown")) {
                should_shutdown.* = true;
            }
        }
        const stream_options = parseWebSocketStreamOptions(allocator, cfg, body);
        const dispatch_body = try dispatcher.dispatch(allocator, body);
        if (stream_options.enabled) {
            defer allocator.free(dispatch_body);
            const rpc_id = if (parsed) |req| req.id else "unknown";
            return .{
                .status = .ok,
                .content_type = "application/json",
                .body = try encodeHttpStreamEnvelope(allocator, rpc_id, dispatch_body, stream_options.chunk_bytes),
            };
        }

        return .{
            .status = .ok,
            .content_type = "application/json",
            .body = dispatch_body,
        };
    }

    if (isWebSocketPath(target_path)) {
        if (method != .GET) {
            return .{
                .status = .method_not_allowed,
                .content_type = "application/json",
                .body = try encodeJson(allocator, .{ .@"error" = "method_not_allowed", .allowed = "GET /ws or / (websocket upgrade)" }),
            };
        }
        return .{
            .status = .upgrade_required,
            .content_type = "application/json",
            .body = try encodeJson(allocator, .{
                .@"error" = "upgrade_required",
                .detail = "use websocket upgrade for /ws endpoint",
            }),
        };
    }

    return .{
        .status = .not_found,
        .content_type = "application/json",
        .body = try encodeJson(allocator, .{ .@"error" = "not_found", .path = target_path }),
    };
}

fn serveRequest(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    rate_limiter: *RateLimiter,
    request: *std.http.Server.Request,
    should_shutdown: *bool,
) !bool {
    const method = request.head.method;
    const raw_target = try allocator.dupe(u8, request.head.target);
    defer allocator.free(raw_target);
    const target = pathFromTarget(raw_target);

    if (isWebSocketPath(target)) {
        return try serveWebSocket(allocator, cfg, rate_limiter, request, should_shutdown);
    }

    var route_context: RouteContext = .{};
    if (method == .POST and std.mem.eql(u8, target, "/rpc")) {
        const token_required = bindRequiresGatewayToken(cfg);
        route_context.rpc_authorized = !token_required or requestHasGatewayToken(request, cfg.gateway.auth_token);
        route_context.rpc_rate_limited = !rate_limiter.allow(time_util.nowMs());
    }

    var owned_body: ?[]u8 = null;
    defer if (owned_body) |body| allocator.free(body);

    const body = if (method == .POST and std.mem.eql(u8, target, "/rpc")) blk: {
        const rpc_body = try readRequestBody(allocator, request);
        owned_body = rpc_body;
        break :blk rpc_body;
    } else "";

    const routed = try routeRequest(
        allocator,
        cfg,
        route_context,
        method,
        target,
        body,
        should_shutdown,
    );
    defer allocator.free(routed.body);

    try request.respond(routed.body, .{
        .status = routed.status,
        .keep_alive = !should_shutdown.*,
        .extra_headers = &.{
            .{ .name = "content-type", .value = routed.content_type },
        },
    });
    return false;
}

fn serveWebSocket(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    rate_limiter: *RateLimiter,
    request: *std.http.Server.Request,
    should_shutdown: *bool,
) !bool {
    if (request.head.method != .GET) {
        const body = try encodeJson(allocator, .{ .@"error" = "method_not_allowed", .allowed = "GET /ws or / (websocket upgrade)" });
        defer allocator.free(body);
        try request.respond(body, .{
            .status = .method_not_allowed,
            .keep_alive = !should_shutdown.*,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return false;
    }

    const upgrade = request.upgradeRequested();
    const ws_key = switch (upgrade) {
        .websocket => |key| key orelse {
            const body = try encodeJson(allocator, .{ .@"error" = "bad_request", .detail = "missing sec-websocket-key header" });
            defer allocator.free(body);
            try request.respond(body, .{
                .status = .bad_request,
                .keep_alive = !should_shutdown.*,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
            return false;
        },
        .other, .none => {
            const body = try encodeJson(allocator, .{
                .@"error" = "upgrade_required",
                .detail = "websocket upgrade required for /ws endpoint",
            });
            defer allocator.free(body);
            try request.respond(body, .{
                .status = .upgrade_required,
                .keep_alive = !should_shutdown.*,
                .extra_headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
            });
            return false;
        },
    };

    const token_required = bindRequiresGatewayToken(cfg);
    if (token_required and !gatewayTokenConfigured(cfg)) {
        const body = try encodeJson(allocator, .{
            .@"error" = "gateway_token_unconfigured",
            .detail = "non-loopback bind requires OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN",
        });
        defer allocator.free(body);
        try request.respond(body, .{
            .status = .forbidden,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return false;
    }

    if (token_required and !requestHasGatewayToken(request, cfg.gateway.auth_token)) {
        const body = try encodeJson(allocator, .{ .@"error" = "unauthorized", .detail = "missing or invalid gateway token" });
        defer allocator.free(body);
        try request.respond(body, .{
            .status = .unauthorized,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return false;
    }

    if (!rate_limiter.allow(time_util.nowMs())) {
        const body = try encodeJson(allocator, .{ .@"error" = "rate_limited", .detail = "gateway websocket rate limit exceeded" });
        defer allocator.free(body);
        try request.respond(body, .{
            .status = .too_many_requests,
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
            },
        });
        return false;
    }

    var ws = try request.respondWebSocket(.{ .key = ws_key });
    try ws.flush();

    while (!should_shutdown.*) {
        if (!rate_limiter.allow(time_util.nowMs())) {
            const over = try encodeJson(allocator, .{ .@"error" = "rate_limited", .detail = "gateway websocket rate limit exceeded" });
            defer allocator.free(over);
            ws.writeMessage(over, .text) catch break;
            break;
        }

        const message = ws.readSmallMessage() catch |err| switch (err) {
            error.ConnectionClose => break,
            error.EndOfStream => break,
            error.ReadFailed => break,
            else => {
                const parse_error = try encodeJson(allocator, .{
                    .@"error" = "invalid_websocket_frame",
                    .detail = @errorName(err),
                });
                defer allocator.free(parse_error);
                ws.writeMessage(parse_error, .text) catch break;
                continue;
            },
        };

        switch (message.opcode) {
            .ping => {
                ws.writeMessage(message.data, .pong) catch break;
                continue;
            },
            .text, .binary => {},
            else => continue,
        }

        const frame = std.mem.trim(u8, message.data, " \t\r\n");
        if (frame.len == 0) {
            const empty = try encodeJson(allocator, .{ .@"error" = "invalid_request", .detail = "empty websocket rpc frame" });
            defer allocator.free(empty);
            ws.writeMessage(empty, .text) catch break;
            continue;
        }

        const stream_options = parseWebSocketStreamOptions(allocator, cfg, frame);
        var parsed = protocol.parseRequest(allocator, frame) catch null;
        defer if (parsed) |*req| req.deinit(allocator);
        if (parsed) |req| {
            if (std.ascii.eqlIgnoreCase(req.method, "shutdown")) {
                should_shutdown.* = true;
            }
        }

        const response = dispatcher.dispatch(allocator, frame) catch |err| blk: {
            break :blk try encodeJson(allocator, .{
                .@"error" = "dispatch_failed",
                .detail = @errorName(err),
            });
        };
        defer allocator.free(response);
        if (shouldStreamPayload(stream_options, response.len)) {
            const rpc_id = if (parsed) |req| req.id else "unknown";
            writeWebSocketStreamChunks(allocator, &ws, rpc_id, response, stream_options.chunk_bytes) catch break;
            continue;
        }
        ws.writeMessage(response, .text) catch break;
    }
    return true;
}

fn isWebSocketPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/ws") or std.mem.eql(u8, target, "/");
}

fn pathFromTarget(target: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    return target[0..end];
}

fn readRequestBody(allocator: std.mem.Allocator, request: *std.http.Server.Request) ![]u8 {
    var body_reader = try request.readerExpectContinue(&.{});
    return body_reader.allocRemaining(allocator, .limited(max_rpc_body_bytes));
}

fn encodeJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn requestHasGatewayToken(request: *const std.http.Server.Request, expected_token: []const u8) bool {
    const expected = std.mem.trim(u8, expected_token, " \t\r\n");
    if (expected.len == 0) return false;
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            if (headerTokenMatches(header.value, expected)) return true;
        } else if (std.ascii.eqlIgnoreCase(header.name, "x-openclaw-token") or std.ascii.eqlIgnoreCase(header.name, "x-api-key")) {
            if (headerTokenMatches(header.value, expected)) return true;
        }
    }
    return false;
}

fn headerTokenMatches(raw_value: []const u8, expected_token: []const u8) bool {
    const expected = std.mem.trim(u8, expected_token, " \t\r\n");
    if (expected.len == 0) return false;

    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    if (trimmed.len == 0) return false;

    if (startsWithIgnoreCase(trimmed, "bearer ")) {
        const bearer_value = std.mem.trim(u8, trimmed["bearer ".len..], " \t\r\n");
        return std.mem.eql(u8, bearer_value, expected);
    }
    return std.mem.eql(u8, trimmed, expected);
}

fn parseWebSocketStreamOptions(allocator: std.mem.Allocator, cfg: config.Config, frame: []const u8) WebSocketStreamOptions {
    var out: WebSocketStreamOptions = .{
        .chunk_bytes = effectiveWebSocketStreamChunkDefaultBytes(cfg.gateway),
    };
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{}) catch return out;
    defer parsed.deinit();

    if (parsed.value != .object) return out;
    const params = parsed.value.object.get("params") orelse return out;
    if (params != .object) return out;

    if (params.object.get("stream")) |value| {
        out.enabled = boolFromJson(value, false);
    }
    if (params.object.get("streamChunkBytes")) |value| {
        const requested = parsePositiveU64FromJson(value) orelse return out;
        out.chunk_bytes = normalizeWebSocketStreamChunkBytes(cfg.gateway, requested);
    }
    return out;
}

fn shouldStreamPayload(options: WebSocketStreamOptions, payload_len: usize) bool {
    return options.enabled and payload_len > options.chunk_bytes;
}

fn effectiveWebSocketStreamChunkMaxBytes(gateway: config.GatewayConfig) usize {
    const configured_max = @as(usize, @intCast(gateway.stream_chunk_max_bytes));
    if (configured_max == 0) return ws_stream_chunk_max_fallback_bytes;
    return @max(ws_stream_chunk_min_bytes, configured_max);
}

fn effectiveWebSocketStreamChunkDefaultBytes(gateway: config.GatewayConfig) usize {
    const max_chunk_bytes = effectiveWebSocketStreamChunkMaxBytes(gateway);
    const configured_default = @as(usize, @intCast(gateway.stream_chunk_default_bytes));
    const raw_default = if (configured_default == 0) ws_stream_chunk_default_fallback_bytes else configured_default;
    return @min(@max(ws_stream_chunk_min_bytes, raw_default), max_chunk_bytes);
}

fn normalizeWebSocketStreamChunkBytes(gateway: config.GatewayConfig, requested: u64) usize {
    const max_chunk_bytes = effectiveWebSocketStreamChunkMaxBytes(gateway);
    const clamped = std.math.clamp(
        requested,
        @as(u64, ws_stream_chunk_min_bytes),
        @as(u64, @intCast(max_chunk_bytes)),
    );
    return @as(usize, @intCast(clamped));
}

fn streamChunkCount(payload_len: usize, chunk_bytes: usize) usize {
    if (payload_len == 0) return 0;
    return (payload_len + chunk_bytes - 1) / chunk_bytes;
}

fn writeWebSocketStreamChunks(
    allocator: std.mem.Allocator,
    ws: *std.http.Server.WebSocket,
    rpc_id: []const u8,
    payload: []const u8,
    chunk_bytes: usize,
) !void {
    const chunk_count = streamChunkCount(payload.len, chunk_bytes);
    var chunk_index: usize = 0;
    var offset: usize = 0;
    while (offset < payload.len) : (chunk_index += 1) {
        const remaining = payload.len - offset;
        const take = @min(chunk_bytes, remaining);
        const next_offset = offset + take;
        const chunk = payload[offset..next_offset];
        offset = next_offset;

        const envelope = try encodeJson(allocator, .{
            .jsonrpc = "2.0",
            .id = rpc_id,
            .stream = .{
                .enabled = true,
                .chunkIndex = chunk_index,
                .chunkCount = chunk_count,
                .done = chunk_index + 1 == chunk_count,
                .chunkBytes = chunk.len,
                .totalBytes = payload.len,
            },
            .chunk = chunk,
        });
        defer allocator.free(envelope);
        try ws.writeMessage(envelope, .text);
    }
}

fn encodeHttpStreamEnvelope(
    allocator: std.mem.Allocator,
    rpc_id: []const u8,
    payload: []const u8,
    chunk_bytes: usize,
) ![]u8 {
    const chunk_count = streamChunkCount(payload.len, chunk_bytes);
    const Chunk = struct {
        chunkIndex: usize,
        chunkCount: usize,
        done: bool,
        chunkBytes: usize,
        totalBytes: usize,
        chunk: []const u8,
    };
    var chunks = std.ArrayList(Chunk).empty;
    defer chunks.deinit(allocator);

    var chunk_index: usize = 0;
    var offset: usize = 0;
    while (offset < payload.len) : (chunk_index += 1) {
        const remaining = payload.len - offset;
        const take = @min(chunk_bytes, remaining);
        const next_offset = offset + take;
        const chunk = payload[offset..next_offset];
        offset = next_offset;
        try chunks.append(allocator, .{
            .chunkIndex = chunk_index,
            .chunkCount = chunk_count,
            .done = chunk_index + 1 == chunk_count,
            .chunkBytes = chunk.len,
            .totalBytes = payload.len,
            .chunk = chunk,
        });
    }

    return encodeJson(allocator, .{
        .jsonrpc = "2.0",
        .id = rpc_id,
        .stream = .{
            .enabled = true,
            .transport = "http",
            .chunkCount = chunk_count,
            .chunkBytes = chunk_bytes,
            .totalBytes = payload.len,
            .done = true,
        },
        .chunks = chunks.items,
    });
}

fn boolFromJson(value: std.json.Value, fallback: bool) bool {
    return switch (value) {
        .bool => |b| b,
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) break :blk fallback;
            if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.mem.eql(u8, trimmed, "1") or std.ascii.eqlIgnoreCase(trimmed, "yes") or std.ascii.eqlIgnoreCase(trimmed, "on")) break :blk true;
            if (std.ascii.eqlIgnoreCase(trimmed, "false") or std.mem.eql(u8, trimmed, "0") or std.ascii.eqlIgnoreCase(trimmed, "no") or std.ascii.eqlIgnoreCase(trimmed, "off")) break :blk false;
            break :blk fallback;
        },
        .integer => |i| i != 0,
        else => fallback,
    };
}

fn parsePositiveU64FromJson(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i > 0) @as(u64, @intCast(i)) else null,
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) break :blk null;
            const parsed = std.fmt.parseInt(u64, trimmed, 10) catch break :blk null;
            if (parsed == 0) break :blk null;
            break :blk parsed;
        },
        else => null,
    };
}

fn bindRequiresGatewayToken(cfg: config.Config) bool {
    return cfg.gateway.require_token or !isLoopbackBind(cfg.http_bind);
}

fn gatewayTokenConfigured(cfg: config.Config) bool {
    return std.mem.trim(u8, cfg.gateway.auth_token, " \t\r\n").len > 0;
}

fn isLoopbackBind(bind: []const u8) bool {
    const trimmed = std.mem.trim(u8, bind, " \t\r\n");
    if (trimmed.len == 0) return false;
    return std.ascii.eqlIgnoreCase(trimmed, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(trimmed, "::1") or
        std.ascii.eqlIgnoreCase(trimmed, "localhost");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (prefix, 0..) |ch, idx| {
        if (std.ascii.toLower(value[idx]) != std.ascii.toLower(ch)) return false;
    }
    return true;
}

test "routeRequest health returns a successful payload" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/health", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"configHash\":\"") != null);
}

test "routeRequest serves control ui bootstrap html" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/ui", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.content_type, "text/html") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "OpenClaw Zig Control UI") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "logs.tail") != null);
}

test "routeRequest handles query-bearing ui path" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/ui?panel=doctor", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "node.pair.list") != null);
}

test "routeRequest toggles shutdown on shutdown rpc method" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(
        allocator,
        cfg,
        .{},
        .POST,
        "/rpc",
        "{\"id\":\"s1\",\"method\":\"shutdown\",\"params\":{}}",
        &should_shutdown,
    );
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"shutting_down\"") != null);
}

test "routeRequest rejects non-POST /rpc" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/rpc", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.method_not_allowed, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "method_not_allowed") != null);
}

test "routeRequest /ws requires websocket upgrade" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/ws", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.upgrade_required, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "upgrade_required") != null);
}

test "routeRequest root path requires websocket upgrade compatibility" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.upgrade_required, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "upgrade_required") != null);
}

test "routeRequest handles query-bearing health path" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/health?probe=1", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"configHash\":\"") != null);
}

test "routeRequest handles query-bearing websocket path" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(allocator, cfg, .{}, .GET, "/ws?mode=compat", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.upgrade_required, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "upgrade_required") != null);
}

test "routeRequest rpc lifecycle file.write then file.read returns expected payload" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    const io = std.Io.Threaded.global_single_threaded.io();
    var should_shutdown = false;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base_path);
    const file_path = try std.fs.path.join(allocator, &.{ base_path, "route-lifecycle.txt" });
    defer allocator.free(file_path);

    const write_body = try encodeJson(allocator, .{
        .id = "route-write",
        .method = "file.write",
        .params = .{
            .sessionId = "route-session",
            .path = file_path,
            .content = "route-phase3",
        },
    });
    defer allocator.free(write_body);

    const write_result = try routeRequest(allocator, cfg, .{}, .POST, "/rpc", write_body, &should_shutdown);
    defer allocator.free(write_result.body);
    try std.testing.expectEqual(std.http.Status.ok, write_result.status);
    try std.testing.expect(std.mem.indexOf(u8, write_result.body, "\"ok\":true") != null);

    const read_body = try encodeJson(allocator, .{
        .id = "route-read",
        .method = "file.read",
        .params = .{
            .sessionId = "route-session",
            .path = file_path,
        },
    });
    defer allocator.free(read_body);

    const read_result = try routeRequest(allocator, cfg, .{}, .POST, "/rpc", read_body, &should_shutdown);
    defer allocator.free(read_result.body);
    try std.testing.expectEqual(std.http.Status.ok, read_result.status);
    try std.testing.expect(std.mem.indexOf(u8, read_result.body, "route-phase3") != null);
}

test "routeRequest rejects unauthorized rpc when gateway token is required" {
    const allocator = std.testing.allocator;
    var cfg = config.defaults();
    cfg.gateway.require_token = true;
    cfg.gateway.auth_token = "secret-token";
    var should_shutdown = false;
    const result = try routeRequest(
        allocator,
        cfg,
        .{ .rpc_authorized = false },
        .POST,
        "/rpc",
        "{\"id\":\"s1\",\"method\":\"health\",\"params\":{}}",
        &should_shutdown,
    );
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.unauthorized, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "unauthorized") != null);
}

test "routeRequest enforces token auth on non-loopback bind even when require_token is false" {
    const allocator = std.testing.allocator;
    var cfg = config.defaults();
    cfg.http_bind = "0.0.0.0";
    cfg.gateway.require_token = false;
    cfg.gateway.auth_token = "edge-token";
    var should_shutdown = false;
    const result = try routeRequest(
        allocator,
        cfg,
        .{ .rpc_authorized = false },
        .POST,
        "/rpc",
        "{\"id\":\"s1\",\"method\":\"health\",\"params\":{}}",
        &should_shutdown,
    );
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.unauthorized, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "unauthorized") != null);
}

test "routeRequest rejects non-loopback rpc when bind policy token is not configured" {
    const allocator = std.testing.allocator;
    var cfg = config.defaults();
    cfg.http_bind = "0.0.0.0";
    cfg.gateway.require_token = false;
    cfg.gateway.auth_token = "";
    var should_shutdown = false;
    const result = try routeRequest(
        allocator,
        cfg,
        .{},
        .POST,
        "/rpc",
        "{\"id\":\"s1\",\"method\":\"health\",\"params\":{}}",
        &should_shutdown,
    );
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.forbidden, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "gateway_token_unconfigured") != null);
}

test "routeRequest enforces rpc rate limiting context" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(
        allocator,
        cfg,
        .{ .rpc_rate_limited = true },
        .POST,
        "/rpc",
        "{\"id\":\"s1\",\"method\":\"health\",\"params\":{}}",
        &should_shutdown,
    );
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.too_many_requests, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "rate_limited") != null);
}

test "routeRequest rpc stream envelope returns chunk metadata for http transport" {
    const allocator = std.testing.allocator;
    const cfg = config.defaults();
    var should_shutdown = false;
    const result = try routeRequest(
        allocator,
        cfg,
        .{},
        .POST,
        "/rpc",
        "{\"id\":\"stream-http-1\",\"method\":\"config.get\",\"params\":{\"stream\":true,\"streamChunkBytes\":256}}",
        &should_shutdown,
    );
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"stream\":{\"enabled\":true,\"transport\":\"http\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"chunks\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"chunkIndex\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"chunkCount\":") != null);
}

test "header token matcher accepts bearer and raw token headers" {
    try std.testing.expect(headerTokenMatches("Bearer abc123", "abc123"));
    try std.testing.expect(headerTokenMatches(" abc123 ", "abc123"));
    try std.testing.expect(!headerTokenMatches("Bearer abc123", "wrong"));
    try std.testing.expect(!headerTokenMatches("", "abc123"));
}

test "rate limiter enforces max requests within window" {
    var limiter = RateLimiter.init(.{
        .require_token = false,
        .auth_token = "",
        .rate_limit_enabled = true,
        .rate_limit_window_ms = 1000,
        .rate_limit_max_requests = 2,
    });

    try std.testing.expect(limiter.allow(1_000));
    try std.testing.expect(limiter.allow(1_100));
    try std.testing.expect(!limiter.allow(1_200));
    try std.testing.expect(limiter.allow(2_200));
}

test "websocket stream chunk size normalization clamps bounds" {
    const cfg = config.defaults();
    try std.testing.expectEqual(@as(usize, ws_stream_chunk_min_bytes), normalizeWebSocketStreamChunkBytes(cfg.gateway, 1));
    try std.testing.expectEqual(@as(usize, 4096), normalizeWebSocketStreamChunkBytes(cfg.gateway, 4096));
    try std.testing.expectEqual(@as(usize, 64 * 1024), normalizeWebSocketStreamChunkBytes(cfg.gateway, 2 * 64 * 1024));
}

test "websocket stream options parse stream flag and bounded chunk bytes" {
    const allocator = std.testing.allocator;
    var cfg = config.defaults();
    cfg.gateway.stream_chunk_default_bytes = 1024;
    cfg.gateway.stream_chunk_max_bytes = 8192;

    const options = parseWebSocketStreamOptions(
        allocator,
        cfg,
        "{\"id\":\"ws1\",\"method\":\"chat.send\",\"params\":{\"stream\":true,\"streamChunkBytes\":128}}",
    );
    try std.testing.expect(options.enabled);
    try std.testing.expectEqual(@as(usize, ws_stream_chunk_min_bytes), options.chunk_bytes);

    const disabled = parseWebSocketStreamOptions(
        allocator,
        cfg,
        "{\"id\":\"ws2\",\"method\":\"chat.send\",\"params\":{\"stream\":false,\"streamChunkBytes\":8192}}",
    );
    try std.testing.expect(!disabled.enabled);
    try std.testing.expectEqual(@as(usize, 8192), disabled.chunk_bytes);

    const defaulted = parseWebSocketStreamOptions(
        allocator,
        cfg,
        "{\"id\":\"ws3\",\"method\":\"chat.send\",\"params\":{\"stream\":true}}",
    );
    try std.testing.expect(defaulted.enabled);
    try std.testing.expectEqual(@as(usize, 1024), defaulted.chunk_bytes);
}

test "websocket stream options clamp defaults using configured max and fallbacks" {
    const allocator = std.testing.allocator;
    var cfg = config.defaults();
    cfg.gateway.stream_chunk_default_bytes = 32 * 1024;
    cfg.gateway.stream_chunk_max_bytes = 8 * 1024;

    const configured = parseWebSocketStreamOptions(
        allocator,
        cfg,
        "{\"id\":\"ws4\",\"method\":\"chat.send\",\"params\":{\"stream\":true}}",
    );
    try std.testing.expectEqual(@as(usize, 8 * 1024), configured.chunk_bytes);

    cfg.gateway.stream_chunk_default_bytes = 0;
    cfg.gateway.stream_chunk_max_bytes = 0;
    const fallback = parseWebSocketStreamOptions(
        allocator,
        cfg,
        "{\"id\":\"ws5\",\"method\":\"chat.send\",\"params\":{\"stream\":true}}",
    );
    try std.testing.expectEqual(@as(usize, ws_stream_chunk_default_fallback_bytes), fallback.chunk_bytes);
}

test "stream chunk count computes expected fragment count" {
    try std.testing.expectEqual(@as(usize, 0), streamChunkCount(0, 1024));
    try std.testing.expectEqual(@as(usize, 1), streamChunkCount(1, 1024));
    try std.testing.expectEqual(@as(usize, 3), streamChunkCount(2049, 1024));
}
