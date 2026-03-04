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
            try serveRequest(allocator, cfg, &rate_limiter, &request, &should_shutdown);
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
    if (method == .GET and std.mem.eql(u8, target, "/health")) {
        return .{
            .status = .ok,
            .content_type = "application/json",
            .body = try protocol.encodeResult(allocator, "health", .{
                .status = "ok",
                .service = "openclaw-zig",
                .bridge = "lightpanda",
            }),
        };
    }

    if (std.mem.eql(u8, target, "/rpc")) {
        if (method != .POST) {
            return .{
                .status = .method_not_allowed,
                .content_type = "application/json",
                .body = try encodeJson(allocator, .{ .@"error" = "method_not_allowed", .allowed = "POST /rpc" }),
            };
        }

        if (cfg.gateway.require_token and !context.rpc_authorized) {
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

        return .{
            .status = .ok,
            .content_type = "application/json",
            .body = try dispatcher.dispatch(allocator, body),
        };
    }

    return .{
        .status = .not_found,
        .content_type = "application/json",
        .body = try encodeJson(allocator, .{ .@"error" = "not_found", .path = target }),
    };
}

fn serveRequest(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    rate_limiter: *RateLimiter,
    request: *std.http.Server.Request,
    should_shutdown: *bool,
) !void {
    const method = request.head.method;
    const target = try allocator.dupe(u8, request.head.target);
    defer allocator.free(target);

    var route_context: RouteContext = .{};
    if (method == .POST and std.mem.eql(u8, target, "/rpc")) {
        route_context.rpc_authorized = !cfg.gateway.require_token or requestHasGatewayToken(request, cfg.gateway.auth_token);
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
