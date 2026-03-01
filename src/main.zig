const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("openclaw-zig bootstrap ready\n", .{});
}

test "bootstrap string is non-empty" {
    const value = "openclaw-zig bootstrap ready";
    try std.testing.expect(value.len > 0);
}
