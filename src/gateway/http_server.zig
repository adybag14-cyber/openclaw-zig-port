const std = @import("std");
const config = @import("../config.zig");
const protocol = @import("../protocol/envelope.zig");
const dispatcher = @import("dispatcher.zig");

pub const ServeOptions = struct {
    max_connections: ?usize = null,
};

pub const RouteResponse = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []u8,
};

const max_rpc_body_bytes: usize = 1024 * 1024;

pub fn serve(allocator: std.mem.Allocator, cfg: config.Config, options: ServeOptions) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address = try std.Io.net.IpAddress.resolve(io, cfg.http_bind, cfg.http_port);
    var net_server = try address.listen(io, .{ .reuse_address = true });
    defer net_server.deinit(io);

    var accepted: usize = 0;
    var should_shutdown = false;

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
            try serveRequest(allocator, &request, &should_shutdown);
        }
    }
}

pub fn routeRequest(
    allocator: std.mem.Allocator,
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
    request: *std.http.Server.Request,
    should_shutdown: *bool,
) !void {
    const method = request.head.method;
    const target = try allocator.dupe(u8, request.head.target);
    defer allocator.free(target);

    var owned_body: ?[]u8 = null;
    defer if (owned_body) |body| allocator.free(body);

    const body = if (method == .POST and std.mem.eql(u8, target, "/rpc")) blk: {
        const rpc_body = try readRequestBody(allocator, request);
        owned_body = rpc_body;
        break :blk rpc_body;
    } else "";

    const routed = try routeRequest(
        allocator,
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

test "routeRequest health returns a successful payload" {
    const allocator = std.testing.allocator;
    var should_shutdown = false;
    const result = try routeRequest(allocator, .GET, "/health", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    try std.testing.expect(!should_shutdown);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "\"status\":\"ok\"") != null);
}

test "routeRequest toggles shutdown on shutdown rpc method" {
    const allocator = std.testing.allocator;
    var should_shutdown = false;
    const result = try routeRequest(
        allocator,
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
    var should_shutdown = false;
    const result = try routeRequest(allocator, .GET, "/rpc", "", &should_shutdown);
    defer allocator.free(result.body);
    try std.testing.expectEqual(std.http.Status.method_not_allowed, result.status);
    try std.testing.expect(std.mem.indexOf(u8, result.body, "method_not_allowed") != null);
}

test "routeRequest rpc lifecycle file.write then file.read returns expected payload" {
    const allocator = std.testing.allocator;
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

    const write_result = try routeRequest(allocator, .POST, "/rpc", write_body, &should_shutdown);
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

    const read_result = try routeRequest(allocator, .POST, "/rpc", read_body, &should_shutdown);
    defer allocator.free(read_result.body);
    try std.testing.expectEqual(std.http.Status.ok, read_result.status);
    try std.testing.expect(std.mem.indexOf(u8, read_result.body, "route-phase3") != null);
}
