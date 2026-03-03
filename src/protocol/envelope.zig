const std = @import("std");

pub const RpcRequest = struct {
    id: []const u8,
    method: []const u8,

    pub fn deinit(self: *RpcRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.method);
    }
};

pub const RpcError = struct {
    code: i64,
    message: []const u8,
};

pub const ParseError = error{
    InvalidFrame,
    InvalidMethod,
    InvalidId,
};

pub fn parseRequest(allocator: std.mem.Allocator, body: []const u8) !RpcRequest {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return ParseError.InvalidFrame;
    const obj = parsed.value.object;

    const id_value = obj.get("id") orelse return ParseError.InvalidId;
    const method_value = obj.get("method") orelse return ParseError.InvalidMethod;
    if (method_value != .string or method_value.string.len == 0) return ParseError.InvalidMethod;

    const id_text = switch (id_value) {
        .string => |text| try allocator.dupe(u8, text),
        .integer => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        else => return ParseError.InvalidId,
    };

    return .{
        .id = id_text,
        .method = try allocator.dupe(u8, method_value.string),
    };
}

pub fn encodeResult(allocator: std.mem.Allocator, id: []const u8, result: anytype) ![]u8 {
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = result,
    });
}

pub fn encodeError(allocator: std.mem.Allocator, id: []const u8, rpc_error: RpcError) ![]u8 {
    return stringifyAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{
            .code = rpc_error.code,
            .message = rpc_error.message,
        },
    });
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "parseRequest extracts id and method" {
    const allocator = std.testing.allocator;
    var req = try parseRequest(allocator, "{\"id\":\"1\",\"method\":\"health\",\"params\":{}}");
    defer req.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, req.id, "1"));
    try std.testing.expect(std.mem.eql(u8, req.method, "health"));
}
