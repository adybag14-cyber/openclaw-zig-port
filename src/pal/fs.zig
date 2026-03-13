const std = @import("std");
const builtin = @import("builtin");
const baremetal_filesystem = @import("../baremetal/filesystem.zig");

fn readFileAllocHosted(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_bytes));
}

fn readFileAllocBaremetal(
    _: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) ![]u8 {
    return baremetal_filesystem.readFileAlloc(allocator, path, max_bytes);
}

pub const readFileAlloc = if (builtin.os.tag == .freestanding) readFileAllocBaremetal else readFileAllocHosted;

fn writeFileHosted(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = data,
    });
}

fn writeFileBaremetal(_: std.Io, path: []const u8, data: []const u8) !void {
    try baremetal_filesystem.writeFile(path, data, 0);
}

pub const writeFile = if (builtin.os.tag == .freestanding) writeFileBaremetal else writeFileHosted;

fn createDirPathHosted(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn createDirPathBaremetal(_: std.Io, path: []const u8) !void {
    try baremetal_filesystem.createDirPath(path);
}

pub const createDirPath = if (builtin.os.tag == .freestanding) createDirPathBaremetal else createDirPathHosted;

fn statNoFollowHosted(io: std.Io, path: []const u8) !std.Io.Dir.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false });
}

fn statNoFollowBaremetal(_: std.Io, path: []const u8) !std.Io.Dir.Stat {
    return baremetal_filesystem.statNoFollow(path);
}

pub const statNoFollow = if (builtin.os.tag == .freestanding) statNoFollowBaremetal else statNoFollowHosted;
