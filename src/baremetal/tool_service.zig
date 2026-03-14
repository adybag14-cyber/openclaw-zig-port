const std = @import("std");
const filesystem = @import("filesystem.zig");
const package_store = @import("package_store.zig");
const tool_exec = @import("tool_exec.zig");

pub const Error = tool_exec.Error || package_store.Error || std.mem.Allocator.Error || error{
    EmptyRequest,
    InvalidFrame,
    ResponseTooLarge,
};

pub const FramedCommandRequest = struct {
    request_id: u32,
    command: []const u8,
};

pub const RequestOp = enum {
    command,
    get,
    put,
    stat,
    package_install,
    package_list,
    package_run,
};

pub const PutRequest = struct {
    path: []const u8,
    body: []const u8,
};

pub const FramedRequest = struct {
    request_id: u32,
    operation: union(RequestOp) {
        command: []const u8,
        get: []const u8,
        put: PutRequest,
        stat: []const u8,
        package_install: PutRequest,
        package_list: void,
        package_run: []const u8,
    },
};

const ConsumedRequest = struct {
    framed: FramedRequest,
    consumed_len: usize,
};

pub fn handleCommandRequest(
    allocator: std.mem.Allocator,
    request: []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
    response_limit: usize,
) Error![]u8 {
    const trimmed = std.mem.trim(u8, request, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyRequest;

    var result = try tool_exec.runCapture(allocator, trimmed, stdout_limit, stderr_limit);
    defer result.deinit(allocator);

    if (result.exit_code == 0 and result.stderr.len == 0) {
        if (result.stdout.len > response_limit) return error.ResponseTooLarge;
        return allocator.dupe(u8, result.stdout);
    }

    const detail = if (result.stderr.len != 0) result.stderr else result.stdout;
    const response = try std.fmt.allocPrint(allocator, "ERR exit={d}\n{s}", .{ result.exit_code, detail });
    errdefer allocator.free(response);
    if (response.len > response_limit) return error.ResponseTooLarge;
    return response;
}

pub fn parseFramedCommandRequest(request: []const u8) Error!FramedCommandRequest {
    const framed = try parseFramedRequest(request);
    return switch (framed.operation) {
        .command => |command| .{ .request_id = framed.request_id, .command = command },
        else => error.InvalidFrame,
    };
}

pub fn parseFramedRequest(request: []const u8) Error!FramedRequest {
    const consumed = try parseFramedRequestPrefix(request);
    if (trimLeftWhitespace(request[consumed.consumed_len..]).len != 0) return error.InvalidFrame;
    return consumed.framed;
}

pub fn handleFramedCommandRequest(
    allocator: std.mem.Allocator,
    request: []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
    response_limit: usize,
) Error![]u8 {
    const framed = try parseFramedCommandRequest(request);
    const payload_limit = payloadLimitForResponse(response_limit);
    const payload = try handleCommandRequest(allocator, framed.command, stdout_limit, stderr_limit, payload_limit);
    defer allocator.free(payload);

    return formatFramedResponse(allocator, framed.request_id, payload, response_limit);
}

pub fn handleFramedRequest(
    allocator: std.mem.Allocator,
    request: []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
    response_limit: usize,
) Error![]u8 {
    const framed = try parseFramedRequest(request);
    return handleFramedResponse(allocator, framed, stdout_limit, stderr_limit, response_limit);
}

pub fn handleFramedRequestBatch(
    allocator: std.mem.Allocator,
    request: []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
    response_limit: usize,
) Error![]u8 {
    var response: std.ArrayList(u8) = .empty;
    errdefer response.deinit(allocator);

    var remaining = request;
    var saw_frame = false;
    while (true) {
        const trimmed = trimLeftWhitespace(remaining);
        if (trimmed.len == 0) break;

        const consumed = try parseFramedRequestPrefix(remaining);
        saw_frame = true;
        remaining = remaining[consumed.consumed_len..];

        const response_remaining = response_limit -| response.items.len;
        if (response_remaining == 0) return error.ResponseTooLarge;

        const frame_response = try handleFramedResponse(
            allocator,
            consumed.framed,
            stdout_limit,
            stderr_limit,
            response_remaining,
        );
        defer allocator.free(frame_response);

        if (response.items.len + frame_response.len > response_limit) return error.ResponseTooLarge;
        try response.appendSlice(allocator, frame_response);
    }

    if (!saw_frame) return error.EmptyRequest;
    return response.toOwnedSlice(allocator);
}

fn handleFramedResponse(
    allocator: std.mem.Allocator,
    framed: FramedRequest,
    stdout_limit: usize,
    stderr_limit: usize,
    response_limit: usize,
) Error![]u8 {
    const payload_limit = payloadLimitForResponse(response_limit);
    const payload = try handleFramedPayload(allocator, framed, stdout_limit, stderr_limit, payload_limit);
    defer allocator.free(payload);

    return formatFramedResponse(allocator, framed.request_id, payload, response_limit);
}

const TokenSplit = struct {
    token: []const u8,
    rest: []const u8,
};

fn payloadLimitForResponse(response_limit: usize) usize {
    return if (response_limit > 32) response_limit - 32 else response_limit;
}

fn parseFramedRequestPrefix(request: []const u8) Error!ConsumedRequest {
    const trimmed = trimLeftWhitespace(request);
    if (trimmed.len == 0) return error.EmptyRequest;

    const prefix_len = request.len - trimmed.len;
    const newline_index = std.mem.indexOfScalar(u8, trimmed, '\n');
    const header_len = newline_index orelse trimmed.len;
    const header = std.mem.trim(u8, trimmed[0..header_len], " \t\r\n");
    if (header.len == 0) return error.EmptyRequest;
    if (!std.mem.startsWith(u8, header, "REQ ")) return error.InvalidFrame;

    const body = trimLeftWhitespace(header["REQ ".len..]);
    if (body.len == 0) return error.InvalidFrame;

    const request_id_part = try splitFirstToken(body);
    const request_id = std.fmt.parseUnsigned(u32, request_id_part.token, 10) catch return error.InvalidFrame;
    const remainder = request_id_part.rest;
    if (remainder.len == 0) return error.InvalidFrame;

    const op_part = splitFirstToken(remainder) catch {
        const consumed_len = if (newline_index) |idx| prefix_len + idx + 1 else request.len;
        return .{
            .framed = .{
                .request_id = request_id,
                .operation = .{ .command = remainder },
            },
            .consumed_len = consumed_len,
        };
    };

    if (std.ascii.eqlIgnoreCase(op_part.token, "CMD")) {
        if (op_part.rest.len == 0) return error.InvalidFrame;
        if (newline_index != null) {
            const consumed_len = prefix_len + newline_index.? + 1;
            return .{
                .framed = .{ .request_id = request_id, .operation = .{ .command = op_part.rest } },
                .consumed_len = consumed_len,
            };
        }
        return .{
            .framed = .{ .request_id = request_id, .operation = .{ .command = op_part.rest } },
            .consumed_len = request.len,
        };
    }

    if (std.ascii.eqlIgnoreCase(op_part.token, "GET")) {
        if (op_part.rest.len == 0) return error.InvalidFrame;
        if (newline_index != null) {
            const consumed_len = prefix_len + newline_index.? + 1;
            return .{
                .framed = .{ .request_id = request_id, .operation = .{ .get = op_part.rest } },
                .consumed_len = consumed_len,
            };
        }
        return .{
            .framed = .{ .request_id = request_id, .operation = .{ .get = op_part.rest } },
            .consumed_len = request.len,
        };
    }

    if (std.ascii.eqlIgnoreCase(op_part.token, "STAT")) {
        if (op_part.rest.len == 0) return error.InvalidFrame;
        if (newline_index != null) {
            const consumed_len = prefix_len + newline_index.? + 1;
            return .{
                .framed = .{ .request_id = request_id, .operation = .{ .stat = op_part.rest } },
                .consumed_len = consumed_len,
            };
        }
        return .{
            .framed = .{ .request_id = request_id, .operation = .{ .stat = op_part.rest } },
            .consumed_len = request.len,
        };
    }

    if (std.ascii.eqlIgnoreCase(op_part.token, "PKGLIST")) {
        if (op_part.rest.len != 0) return error.InvalidFrame;
        if (newline_index != null) {
            return .{
                .framed = .{ .request_id = request_id, .operation = .{ .package_list = {} } },
                .consumed_len = prefix_len + newline_index.? + 1,
            };
        }
        return .{
            .framed = .{ .request_id = request_id, .operation = .{ .package_list = {} } },
            .consumed_len = request.len,
        };
    }

    if (std.ascii.eqlIgnoreCase(op_part.token, "PKGRUN")) {
        if (op_part.rest.len == 0) return error.InvalidFrame;
        if (newline_index != null) {
            return .{
                .framed = .{ .request_id = request_id, .operation = .{ .package_run = op_part.rest } },
                .consumed_len = prefix_len + newline_index.? + 1,
            };
        }
        return .{
            .framed = .{ .request_id = request_id, .operation = .{ .package_run = op_part.rest } },
            .consumed_len = request.len,
        };
    }

    if (std.ascii.eqlIgnoreCase(op_part.token, "PUT") or std.ascii.eqlIgnoreCase(op_part.token, "PKG")) {
        const path_part = try splitFirstToken(op_part.rest);
        const length_part = try splitFirstToken(path_part.rest);
        if (length_part.rest.len != 0) return error.InvalidFrame;
        const body_len = std.fmt.parseUnsigned(usize, length_part.token, 10) catch return error.InvalidFrame;
        const body_start = newline_index orelse return error.InvalidFrame;
        const payload_start = body_start + 1;
        if (trimmed.len < payload_start + body_len) return error.InvalidFrame;
        const body_payload = trimmed[payload_start .. payload_start + body_len];
        const consumed_len = prefix_len + payload_start + body_len;
        if (std.ascii.eqlIgnoreCase(op_part.token, "PUT")) {
            return .{
                .framed = .{
                    .request_id = request_id,
                    .operation = .{ .put = .{ .path = path_part.token, .body = body_payload } },
                },
                .consumed_len = consumed_len,
            };
        }
        return .{
            .framed = .{
                .request_id = request_id,
                .operation = .{ .package_install = .{ .path = path_part.token, .body = body_payload } },
            },
            .consumed_len = consumed_len,
        };
    }

    if (newline_index != null) {
        return .{
            .framed = .{ .request_id = request_id, .operation = .{ .command = remainder } },
            .consumed_len = prefix_len + newline_index.? + 1,
        };
    }
    return .{
        .framed = .{ .request_id = request_id, .operation = .{ .command = remainder } },
        .consumed_len = request.len,
    };
}

fn handleFramedPayload(
    allocator: std.mem.Allocator,
    framed: FramedRequest,
    stdout_limit: usize,
    stderr_limit: usize,
    payload_limit: usize,
) Error![]u8 {
    return switch (framed.operation) {
        .command => |command| try handleCommandRequest(allocator, command, stdout_limit, stderr_limit, payload_limit),
        .get => |path| try handleGetRequest(allocator, path, payload_limit),
        .put => |put_request| try handlePutRequest(allocator, put_request.path, put_request.body, payload_limit),
        .stat => |path| try handleStatRequest(allocator, path, payload_limit),
        .package_install => |package_request| try handlePackageInstallRequest(allocator, package_request.path, package_request.body, payload_limit),
        .package_list => try handlePackageListRequest(allocator, payload_limit),
        .package_run => |package_name| try handlePackageRunRequest(allocator, package_name, stdout_limit, stderr_limit, payload_limit),
    };
}

fn splitFirstToken(text: []const u8) Error!TokenSplit {
    const trimmed = trimLeftWhitespace(text);
    if (trimmed.len == 0) return error.InvalidFrame;

    var idx: usize = 0;
    while (idx < trimmed.len and !std.ascii.isWhitespace(trimmed[idx])) : (idx += 1) {}
    return .{
        .token = trimmed[0..idx],
        .rest = trimLeftWhitespace(trimmed[idx..]),
    };
}

fn formatFramedResponse(
    allocator: std.mem.Allocator,
    request_id: u32,
    payload: []const u8,
    response_limit: usize,
) Error![]u8 {
    const response = try std.fmt.allocPrint(allocator, "RESP {d} {d}\n{s}", .{ request_id, payload.len, payload });
    errdefer allocator.free(response);
    if (response.len > response_limit) return error.ResponseTooLarge;
    return response;
}

fn handleGetRequest(allocator: std.mem.Allocator, path: []const u8, payload_limit: usize) Error![]u8 {
    return filesystem.readFileAlloc(allocator, path, payload_limit) catch |err| {
        return formatOperationError(allocator, "GET", err, payload_limit);
    };
}

fn handlePutRequest(allocator: std.mem.Allocator, path: []const u8, body: []const u8, payload_limit: usize) Error![]u8 {
    ensureParentDirectory(path) catch |err| {
        return formatOperationError(allocator, "PUT", err, payload_limit);
    };
    filesystem.writeFile(path, body, 0) catch |err| {
        return formatOperationError(allocator, "PUT", err, payload_limit);
    };

    const response = try std.fmt.allocPrint(allocator, "WROTE {d} bytes to {s}\n", .{ body.len, path });
    errdefer allocator.free(response);
    if (response.len > payload_limit) return error.ResponseTooLarge;
    return response;
}

fn handleStatRequest(allocator: std.mem.Allocator, path: []const u8, payload_limit: usize) Error![]u8 {
    const stat = filesystem.statSummary(path) catch |err| {
        return formatOperationError(allocator, "STAT", err, payload_limit);
    };
    const kind = switch (stat.kind) {
        .directory => "directory",
        .file => "file",
        else => "unknown",
    };
    const response = try std.fmt.allocPrint(allocator, "path={s} kind={s} size={d}\n", .{ path, kind, stat.size });
    errdefer allocator.free(response);
    if (response.len > payload_limit) return error.ResponseTooLarge;
    return response;
}

fn handlePackageInstallRequest(
    allocator: std.mem.Allocator,
    package_name: []const u8,
    body: []const u8,
    payload_limit: usize,
) Error![]u8 {
    package_store.installScriptPackage(package_name, body, 0) catch |err| {
        return formatOperationError(allocator, "PKG", err, payload_limit);
    };

    var entrypoint_buf: [filesystem.max_path_len]u8 = undefined;
    const entrypoint = package_store.entrypointPath(package_name, &entrypoint_buf) catch |err| {
        return formatOperationError(allocator, "PKG", err, payload_limit);
    };
    const response = try std.fmt.allocPrint(allocator, "INSTALLED {s} -> {s}\n", .{ package_name, entrypoint });
    errdefer allocator.free(response);
    if (response.len > payload_limit) return error.ResponseTooLarge;
    return response;
}

fn handlePackageListRequest(allocator: std.mem.Allocator, payload_limit: usize) Error![]u8 {
    return package_store.listPackagesAlloc(allocator, payload_limit) catch |err| {
        return formatOperationError(allocator, "PKGLIST", err, payload_limit);
    };
}

fn handlePackageRunRequest(
    allocator: std.mem.Allocator,
    package_name: []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
    payload_limit: usize,
) Error![]u8 {
    var command_buf: [96]u8 = undefined;
    const command = std.fmt.bufPrint(&command_buf, "run-package {s}", .{package_name}) catch return error.InvalidFrame;
    return handleCommandRequest(allocator, command, stdout_limit, stderr_limit, payload_limit);
}

fn formatOperationError(
    allocator: std.mem.Allocator,
    operation: []const u8,
    err: anyerror,
    payload_limit: usize,
) Error![]u8 {
    const response = try std.fmt.allocPrint(allocator, "ERR {s}: {s}\n", .{ operation, @errorName(err) });
    errdefer allocator.free(response);
    if (response.len > payload_limit) return error.ResponseTooLarge;
    return response;
}

fn trimLeftWhitespace(text: []const u8) []const u8 {
    var index: usize = 0;
    while (index < text.len and std.ascii.isWhitespace(text[index])) : (index += 1) {}
    return text[index..];
}

fn ensureParentDirectory(path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, "/")) return;
    try filesystem.createDirPath(parent);
}

test "baremetal tool service returns stdout for successful commands" {
    const response = try handleCommandRequest(std.testing.allocator, "echo tcp-service-ok", 256, 256, 256);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("tcp-service-ok\n", response);
}

test "baremetal tool service wraps failing command responses" {
    const response = try handleCommandRequest(std.testing.allocator, "missing-command", 256, 256, 256);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.startsWith(u8, response, "ERR exit=127\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "unknown command") != null);
}

test "baremetal tool service parses framed command requests" {
    const framed = try parseFramedCommandRequest("REQ 7 echo tcp-service-ok");
    try std.testing.expectEqual(@as(u32, 7), framed.request_id);
    try std.testing.expectEqualStrings("echo tcp-service-ok", framed.command);

    const explicit = try parseFramedCommandRequest("REQ 8 CMD echo tcp-service-ok");
    try std.testing.expectEqual(@as(u32, 8), explicit.request_id);
    try std.testing.expectEqualStrings("echo tcp-service-ok", explicit.command);
}

test "baremetal tool service parses typed framed requests" {
    const put = try parseFramedRequest("REQ 11 PUT /tools/cache/tool.txt 4\nedge");
    try std.testing.expectEqual(@as(u32, 11), put.request_id);
    switch (put.operation) {
        .put => |payload| {
            try std.testing.expectEqualStrings("/tools/cache/tool.txt", payload.path);
            try std.testing.expectEqualStrings("edge", payload.body);
        },
        else => return error.InvalidFrame,
    }

    const get = try parseFramedRequest("REQ 12 GET /tools/cache/tool.txt");
    switch (get.operation) {
        .get => |path| try std.testing.expectEqualStrings("/tools/cache/tool.txt", path),
        else => return error.InvalidFrame,
    }

    const stat = try parseFramedRequest("REQ 13 STAT /tools/cache/tool.txt");
    switch (stat.operation) {
        .stat => |path| try std.testing.expectEqualStrings("/tools/cache/tool.txt", path),
        else => return error.InvalidFrame,
    }

    const pkg = try parseFramedRequest("REQ 14 PKG demo 4\nedge");
    switch (pkg.operation) {
        .package_install => |payload| {
            try std.testing.expectEqualStrings("demo", payload.path);
            try std.testing.expectEqualStrings("edge", payload.body);
        },
        else => return error.InvalidFrame,
    }

    const pkg_list = try parseFramedRequest("REQ 15 PKGLIST");
    switch (pkg_list.operation) {
        .package_list => {},
        else => return error.InvalidFrame,
    }

    const pkg_run = try parseFramedRequest("REQ 16 PKGRUN demo");
    switch (pkg_run.operation) {
        .package_run => |package_name| try std.testing.expectEqualStrings("demo", package_name),
        else => return error.InvalidFrame,
    }
}

test "baremetal tool service parses framed request prefixes for batches" {
    const batched = "REQ 11 GET /tools/cache/tool.txt\nREQ 12 STAT /tools/cache/tool.txt";
    const first = try parseFramedRequestPrefix(batched);
    try std.testing.expectEqual(@as(usize, "REQ 11 GET /tools/cache/tool.txt\n".len), first.consumed_len);
    switch (first.framed.operation) {
        .get => |path| try std.testing.expectEqualStrings("/tools/cache/tool.txt", path),
        else => return error.InvalidFrame,
    }

    const second = try parseFramedRequestPrefix(batched[first.consumed_len..]);
    switch (second.framed.operation) {
        .stat => |path| try std.testing.expectEqualStrings("/tools/cache/tool.txt", path),
        else => return error.InvalidFrame,
    }
}

test "baremetal tool service rejects invalid framed requests" {
    try std.testing.expectError(error.InvalidFrame, parseFramedCommandRequest("echo tcp-service-ok"));
    try std.testing.expectError(error.InvalidFrame, parseFramedCommandRequest("REQ nope echo tcp-service-ok"));
    try std.testing.expectError(error.InvalidFrame, parseFramedCommandRequest("REQ 7"));
    try std.testing.expectError(error.InvalidFrame, parseFramedRequest("REQ 11 PUT /tools/cache/tool.txt nope\nedge"));
    try std.testing.expectError(error.InvalidFrame, parseFramedRequest("REQ 11 PUT /tools/cache/tool.txt 5\nedge"));
}

test "baremetal tool service returns framed responses for successful commands" {
    const response = try handleFramedCommandRequest(std.testing.allocator, "REQ 7 echo tcp-service-ok", 256, 256, 256);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("RESP 7 15\ntcp-service-ok\n", response);
}

test "baremetal tool service returns framed responses for failing commands" {
    const response = try handleFramedCommandRequest(std.testing.allocator, "REQ 9 missing-command", 256, 256, 256);
    defer std.testing.allocator.free(response);

    try std.testing.expect(std.mem.startsWith(u8, response, "RESP 9 "));
    try std.testing.expect(std.mem.indexOf(u8, response, "ERR exit=127\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "unknown command") != null);
}

test "baremetal tool service handles framed filesystem requests" {
    filesystem.resetForTest();

    const put_response = try handleFramedRequest(std.testing.allocator, "REQ 11 PUT /tools/cache/tool.txt 4\nedge", 256, 256, 256);
    defer std.testing.allocator.free(put_response);
    try std.testing.expectEqualStrings("RESP 11 39\nWROTE 4 bytes to /tools/cache/tool.txt\n", put_response);

    const get_response = try handleFramedRequest(std.testing.allocator, "REQ 12 GET /tools/cache/tool.txt", 256, 256, 256);
    defer std.testing.allocator.free(get_response);
    try std.testing.expectEqualStrings("RESP 12 4\nedge", get_response);

    const stat_response = try handleFramedRequest(std.testing.allocator, "REQ 13 STAT /tools/cache/tool.txt", 256, 256, 256);
    defer std.testing.allocator.free(stat_response);
    try std.testing.expectEqualStrings("RESP 13 44\npath=/tools/cache/tool.txt kind=file size=4\n", stat_response);
}

test "baremetal tool service uploads and runs persisted scripts" {
    filesystem.resetForTest();

    const script = "write-file /tools/out/data.txt tcp-service-persisted";
    const put_script_request = try std.fmt.allocPrint(std.testing.allocator, "REQ 21 PUT /tools/scripts/net.oc {d}\n{s}", .{ script.len, script });
    defer std.testing.allocator.free(put_script_request);
    const put_script_response = try handleFramedRequest(std.testing.allocator, put_script_request, 512, 256, 512);
    defer std.testing.allocator.free(put_script_response);
    try std.testing.expectEqualStrings("RESP 21 40\nWROTE 52 bytes to /tools/scripts/net.oc\n", put_script_response);

    const run_script_response = try handleFramedRequest(std.testing.allocator, "REQ 22 CMD run-script /tools/scripts/net.oc", 512, 256, 512);
    defer std.testing.allocator.free(run_script_response);
    try std.testing.expectEqualStrings("RESP 22 38\nwrote 21 bytes to /tools/out/data.txt\n", run_script_response);

    const read_output_response = try handleFramedRequest(std.testing.allocator, "REQ 23 GET /tools/out/data.txt", 512, 256, 512);
    defer std.testing.allocator.free(read_output_response);
    try std.testing.expectEqualStrings("RESP 23 21\ntcp-service-persisted", read_output_response);

    const readback = try filesystem.readFileAlloc(std.testing.allocator, "/tools/out/data.txt", 64);
    defer std.testing.allocator.free(readback);
    try std.testing.expectEqualStrings("tcp-service-persisted", readback);
}

test "baremetal tool service installs lists and runs persisted packages" {
    filesystem.resetForTest();

    const script = "mkdir /pkg/out\nwrite-file /pkg/out/result.txt pkg-service-data\necho pkg-service-ok";
    const install_request = try std.fmt.allocPrint(std.testing.allocator, "REQ 31 PKG demo {d}\n{s}", .{ script.len, script });
    defer std.testing.allocator.free(install_request);

    const install_response = try handleFramedRequest(std.testing.allocator, install_request, 512, 256, 512);
    defer std.testing.allocator.free(install_response);
    try std.testing.expect(std.mem.startsWith(u8, install_response, "RESP 31 "));
    try std.testing.expect(std.mem.indexOf(u8, install_response, "INSTALLED demo -> /packages/demo/bin/main.oc\n") != null);

    const list_response = try handleFramedRequest(std.testing.allocator, "REQ 32 PKGLIST", 512, 256, 512);
    defer std.testing.allocator.free(list_response);
    try std.testing.expectEqualStrings("RESP 32 5\ndemo\n", list_response);

    const run_response = try handleFramedRequest(std.testing.allocator, "REQ 33 PKGRUN demo", 512, 256, 512);
    defer std.testing.allocator.free(run_response);
    try std.testing.expect(std.mem.startsWith(u8, run_response, "RESP 33 "));
    try std.testing.expect(std.mem.indexOf(u8, run_response, "pkg-service-ok\n") != null);

    const readback = try filesystem.readFileAlloc(std.testing.allocator, "/pkg/out/result.txt", 64);
    defer std.testing.allocator.free(readback);
    try std.testing.expectEqualStrings("pkg-service-data", readback);
}

test "baremetal tool service handles batched filesystem requests" {
    filesystem.resetForTest();

    const batch_request = "REQ 11 PUT /tools/cache/tool.txt 4\nedge\nREQ 12 GET /tools/cache/tool.txt\nREQ 13 STAT /tools/cache/tool.txt";
    const batch_response = try handleFramedRequestBatch(std.testing.allocator, batch_request, 256, 256, 512);
    defer std.testing.allocator.free(batch_response);

    const expected_put = try handleFramedRequest(std.testing.allocator, "REQ 11 PUT /tools/cache/tool.txt 4\nedge", 256, 256, 256);
    defer std.testing.allocator.free(expected_put);
    const expected_get = try handleFramedRequest(std.testing.allocator, "REQ 12 GET /tools/cache/tool.txt", 256, 256, 256);
    defer std.testing.allocator.free(expected_get);
    const expected_stat = try handleFramedRequest(std.testing.allocator, "REQ 13 STAT /tools/cache/tool.txt", 256, 256, 256);
    defer std.testing.allocator.free(expected_stat);
    const expected = try std.mem.concat(std.testing.allocator, u8, &.{ expected_put, expected_get, expected_stat });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, batch_response);
}

test "baremetal tool service handles batched package requests" {
    filesystem.resetForTest();

    const script = "mkdir /pkg/out\nwrite-file /pkg/out/result.txt pkg-service-data\necho pkg-service-ok";
    const install_request = try std.fmt.allocPrint(std.testing.allocator, "REQ 31 PKG demo {d}\n{s}", .{ script.len, script });
    defer std.testing.allocator.free(install_request);
    const batch_request = try std.mem.concat(std.testing.allocator, u8, &.{
        install_request,
        "\nREQ 32 PKGLIST\nREQ 33 PKGRUN demo",
    });
    defer std.testing.allocator.free(batch_request);
    const batch_response = try handleFramedRequestBatch(std.testing.allocator, batch_request, 512, 256, 512);
    defer std.testing.allocator.free(batch_response);

    const expected_install = try handleFramedRequest(std.testing.allocator, install_request, 512, 256, 512);
    defer std.testing.allocator.free(expected_install);
    const expected_list = try handleFramedRequest(std.testing.allocator, "REQ 32 PKGLIST", 512, 256, 512);
    defer std.testing.allocator.free(expected_list);
    const expected_run = try handleFramedRequest(std.testing.allocator, "REQ 33 PKGRUN demo", 512, 256, 512);
    defer std.testing.allocator.free(expected_run);
    const expected = try std.mem.concat(std.testing.allocator, u8, &.{ expected_install, expected_list, expected_run });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, batch_response);
}

test "baremetal tool service rejects invalid mid-batch frames" {
    filesystem.resetForTest();
    try filesystem.writeFile("/tools/cache/tool.txt", "edge", 0);

    try std.testing.expectError(
        error.InvalidFrame,
        handleFramedRequestBatch(
            std.testing.allocator,
            "REQ 11 GET /tools/cache/tool.txt\nREQ nope GET /tools/cache/tool.txt",
            256,
            256,
            512,
        ),
    );
}
