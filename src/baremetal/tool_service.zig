const std = @import("std");
const tool_exec = @import("tool_exec.zig");

pub const Error = tool_exec.Error || std.mem.Allocator.Error || error{
    EmptyRequest,
    ResponseTooLarge,
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
