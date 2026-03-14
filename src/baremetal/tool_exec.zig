const std = @import("std");
const filesystem = @import("filesystem.zig");
const package_store = @import("package_store.zig");
const vga_text_console = @import("vga_text_console.zig");
const storage_backend = @import("storage_backend.zig");

pub const Error = filesystem.Error || std.mem.Allocator.Error || error{
    MissingCommand,
    MissingPath,
    StreamTooLong,
    InvalidQuotedArgument,
    ScriptDepthExceeded,
};

const max_script_depth: usize = 4;

pub const Result = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

const OutputBuffer = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8),
    limit: usize,
    mirror: bool,

    fn init(allocator: std.mem.Allocator, limit: usize, mirror: bool) OutputBuffer {
        return .{
            .allocator = allocator,
            .list = .empty,
            .limit = limit,
            .mirror = mirror,
        };
    }

    fn deinit(self: *OutputBuffer) void {
        self.list.deinit(self.allocator);
    }

    fn appendSlice(self: *OutputBuffer, bytes: []const u8) !void {
        if (self.list.items.len + bytes.len > self.limit) return error.StreamTooLong;
        try self.list.appendSlice(self.allocator, bytes);
        if (self.mirror and bytes.len > 0) vga_text_console.write(bytes);
    }

    fn appendByte(self: *OutputBuffer, byte: u8) !void {
        var single = [1]u8{byte};
        try self.appendSlice(single[0..]);
    }

    fn appendLine(self: *OutputBuffer, line: []const u8) !void {
        try self.appendSlice(line);
        try self.appendByte('\n');
    }

    fn appendFmt(self: *OutputBuffer, comptime fmt: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(rendered);
        try self.appendSlice(rendered);
    }

    fn toOwnedSlice(self: *OutputBuffer) ![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }
};

const ParsedCommand = struct {
    name: []const u8,
    rest: []const u8,
};

const ParsedArg = struct {
    arg: []const u8,
    rest: []const u8,
};

pub fn runCapture(
    allocator: std.mem.Allocator,
    command: []const u8,
    stdout_limit: usize,
    stderr_limit: usize,
) Error!Result {
    var stdout_buffer = OutputBuffer.init(allocator, stdout_limit, true);
    errdefer stdout_buffer.deinit();
    var stderr_buffer = OutputBuffer.init(allocator, stderr_limit, true);
    errdefer stderr_buffer.deinit();

    var exit_code: u8 = 0;
    try filesystem.init();

    const parsed = parseCommand(command) catch |err| {
        exit_code = 2;
        try writeCommandError(&stderr_buffer, err, "command");
        return .{
            .exit_code = exit_code,
            .stdout = try stdout_buffer.toOwnedSlice(),
            .stderr = try stderr_buffer.toOwnedSlice(),
        };
    };

    execute(parsed, &stdout_buffer, &stderr_buffer, &exit_code, allocator, 0) catch |err| {
        exit_code = 1;
        try stderr_buffer.appendFmt("{s}\n", .{@errorName(err)});
    };

    return .{
        .exit_code = exit_code,
        .stdout = try stdout_buffer.toOwnedSlice(),
        .stderr = try stderr_buffer.toOwnedSlice(),
    };
}

fn execute(
    parsed: ParsedCommand,
    stdout_buffer: *OutputBuffer,
    stderr_buffer: *OutputBuffer,
    exit_code: *u8,
    allocator: std.mem.Allocator,
    depth: usize,
) Error!void {
    if (depth > max_script_depth) return error.ScriptDepthExceeded;

    if (std.ascii.eqlIgnoreCase(parsed.name, "help")) {
        try stdout_buffer.appendLine("OpenClaw bare-metal builtins: help, echo, cat, write-file, mkdir, stat, run-script, run-package");
        return;
    }

    if (std.ascii.eqlIgnoreCase(parsed.name, "echo")) {
        try stdout_buffer.appendLine(parsed.rest);
        return;
    }

    if (std.ascii.eqlIgnoreCase(parsed.name, "mkdir")) {
        const arg = parseFirstArg(parsed.rest) catch |err| {
            exit_code.* = 2;
            try writeCommandError(stderr_buffer, err, "mkdir <path>");
            return;
        };
        if (arg.rest.len != 0) {
            exit_code.* = 2;
            try stderr_buffer.appendLine("usage: mkdir <path>");
            return;
        }
        filesystem.createDirPath(arg.arg) catch |err| {
            exit_code.* = 1;
            try stderr_buffer.appendFmt("mkdir failed: {s}\n", .{@errorName(err)});
            return;
        };
        try stdout_buffer.appendFmt("created {s}\n", .{arg.arg});
        return;
    }

    if (std.ascii.eqlIgnoreCase(parsed.name, "cat")) {
        const arg = parseFirstArg(parsed.rest) catch |err| {
            exit_code.* = 2;
            try writeCommandError(stderr_buffer, err, "cat <path>");
            return;
        };
        if (arg.rest.len != 0) {
            exit_code.* = 2;
            try stderr_buffer.appendLine("usage: cat <path>");
            return;
        }
        const content = filesystem.readFileAlloc(allocator, arg.arg, stdout_buffer.limit) catch |err| {
            exit_code.* = 1;
            try stderr_buffer.appendFmt("cat failed: {s}\n", .{@errorName(err)});
            return;
        };
        defer allocator.free(content);
        try stdout_buffer.appendSlice(content);
        return;
    }

    if (std.ascii.eqlIgnoreCase(parsed.name, "write-file")) {
        const arg = parseFirstArg(parsed.rest) catch |err| {
            exit_code.* = 2;
            try writeCommandError(stderr_buffer, err, "write-file <path> <content>");
            return;
        };
        const content = arg.rest;
        if (content.len == 0) {
            exit_code.* = 2;
            try stderr_buffer.appendLine("usage: write-file <path> <content>");
            return;
        }
        ensureParentDirectory(arg.arg) catch |err| {
            exit_code.* = 1;
            try stderr_buffer.appendFmt("write-file failed: {s}\n", .{@errorName(err)});
            return;
        };
        filesystem.writeFile(arg.arg, content, 0) catch |err| {
            exit_code.* = 1;
            try stderr_buffer.appendFmt("write-file failed: {s}\n", .{@errorName(err)});
            return;
        };
        try stdout_buffer.appendFmt("wrote {d} bytes to {s}\n", .{ content.len, arg.arg });
        return;
    }

    if (std.ascii.eqlIgnoreCase(parsed.name, "stat")) {
        const arg = parseFirstArg(parsed.rest) catch |err| {
            exit_code.* = 2;
            try writeCommandError(stderr_buffer, err, "stat <path>");
            return;
        };
        if (arg.rest.len != 0) {
            exit_code.* = 2;
            try stderr_buffer.appendLine("usage: stat <path>");
            return;
        }
        const stat = filesystem.statSummary(arg.arg) catch |err| {
            exit_code.* = 1;
            try stderr_buffer.appendFmt("stat failed: {s}\n", .{@errorName(err)});
            return;
        };
        const kind = switch (stat.kind) {
            .directory => "directory",
            .file => "file",
            else => "unknown",
        };
        try stdout_buffer.appendFmt("path={s} kind={s} size={d}\n", .{ arg.arg, kind, stat.size });
        return;
    }

    if (std.ascii.eqlIgnoreCase(parsed.name, "run-script")) {
        const arg = parseFirstArg(parsed.rest) catch |err| {
            exit_code.* = 2;
            try writeCommandError(stderr_buffer, err, "run-script <path>");
            return;
        };
        if (arg.rest.len != 0) {
            exit_code.* = 2;
            try stderr_buffer.appendLine("usage: run-script <path>");
            return;
        }
        try executeScriptPath(arg.arg, "run-script", stdout_buffer, stderr_buffer, exit_code, allocator, depth);
        return;
    }

    if (std.ascii.eqlIgnoreCase(parsed.name, "run-package")) {
        const arg = parseFirstArg(parsed.rest) catch |err| {
            exit_code.* = 2;
            try writeCommandError(stderr_buffer, err, "run-package <name>");
            return;
        };
        if (arg.rest.len != 0) {
            exit_code.* = 2;
            try stderr_buffer.appendLine("usage: run-package <name>");
            return;
        }

        var entrypoint_buf: [filesystem.max_path_len]u8 = undefined;
        const entrypoint = package_store.entrypointPath(arg.arg, &entrypoint_buf) catch |err| {
            exit_code.* = 1;
            try stderr_buffer.appendFmt("run-package failed: {s}\n", .{@errorName(err)});
            return;
        };
        try executeScriptPath(entrypoint, "run-package", stdout_buffer, stderr_buffer, exit_code, allocator, depth);
        return;
    }

    exit_code.* = 127;
    try stderr_buffer.appendFmt("unknown command: {s}\n", .{parsed.name});
}

fn parseCommand(command: []const u8) Error!ParsedCommand {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return error.MissingCommand;

    const name = try parseFirstArg(trimmed);
    return .{
        .name = name.arg,
        .rest = name.rest,
    };
}

fn parseFirstArg(text: []const u8) Error!ParsedArg {
    const trimmed = trimLeftWhitespace(text);
    if (trimmed.len == 0) return error.MissingPath;

    const quote = trimmed[0];
    if (quote == '"' or quote == '\'') {
        const end_index = std.mem.indexOfScalarPos(u8, trimmed, 1, quote) orelse return error.InvalidQuotedArgument;
        const arg = trimmed[1..end_index];
        const rest = trimLeftWhitespace(trimmed[end_index + 1 ..]);
        return .{ .arg = arg, .rest = rest };
    }

    var idx: usize = 0;
    while (idx < trimmed.len and !std.ascii.isWhitespace(trimmed[idx])) : (idx += 1) {}
    return .{
        .arg = trimmed[0..idx],
        .rest = trimLeftWhitespace(trimmed[idx..]),
    };
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

fn executeScriptPath(
    path: []const u8,
    operation: []const u8,
    stdout_buffer: *OutputBuffer,
    stderr_buffer: *OutputBuffer,
    exit_code: *u8,
    allocator: std.mem.Allocator,
    depth: usize,
) Error!void {
    if (depth >= max_script_depth) {
        exit_code.* = 1;
        try stderr_buffer.appendFmt("{s} failed: ScriptDepthExceeded\n", .{operation});
        return;
    }

    const script = filesystem.readFileAlloc(allocator, path, 4096) catch |err| {
        exit_code.* = 1;
        try stderr_buffer.appendFmt("{s} failed: {s}\n", .{ operation, @errorName(err) });
        return;
    };
    defer allocator.free(script);

    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const nested = parseCommand(line) catch |err| {
            exit_code.* = 2;
            try writeCommandError(stderr_buffer, err, operation);
            return;
        };
        try execute(nested, stdout_buffer, stderr_buffer, exit_code, allocator, depth + 1);
        if (exit_code.* != 0) return;
    }
}

fn writeCommandError(stderr_buffer: *OutputBuffer, err: anyerror, usage: []const u8) Error!void {
    switch (err) {
        error.MissingCommand, error.MissingPath, error.InvalidQuotedArgument => {
            try stderr_buffer.appendFmt("usage: {s}\n", .{usage});
        },
        else => try stderr_buffer.appendFmt("{s}\n", .{@errorName(err)}),
    }
}

test "baremetal tool exec echoes to stdout and console" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    vga_text_console.resetForTest();

    var result = try runCapture(std.testing.allocator, "echo tool-exec-ok", 256, 256);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("tool-exec-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);
    try std.testing.expectEqual(@as(u16, (@as(u16, 0x07) << 8) | 't'), vga_text_console.cell(0));
}

test "baremetal tool exec writes cats and stats files through baremetal filesystem" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    vga_text_console.resetForTest();

    var mkdir_result = try runCapture(std.testing.allocator, "mkdir /tools/tmp", 256, 256);
    defer mkdir_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), mkdir_result.exit_code);

    var write_result = try runCapture(std.testing.allocator, "write-file /tools/tmp/tool.txt baremetal-tool", 256, 256);
    defer write_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), write_result.exit_code);

    var cat_result = try runCapture(std.testing.allocator, "cat /tools/tmp/tool.txt", 256, 256);
    defer cat_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), cat_result.exit_code);
    try std.testing.expectEqualStrings("baremetal-tool", cat_result.stdout);

    var stat_result = try runCapture(std.testing.allocator, "stat /tools/tmp/tool.txt", 256, 256);
    defer stat_result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), stat_result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stat_result.stdout, "kind=file") != null);
    try std.testing.expect(std.mem.indexOf(u8, stat_result.stdout, "size=14") != null);
}

test "baremetal tool exec reports unknown commands on stderr" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    vga_text_console.resetForTest();

    var result = try runCapture(std.testing.allocator, "missing-command", 256, 256);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 127), result.exit_code);
    try std.testing.expectEqualStrings("", result.stdout);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "unknown command") != null);
}

test "baremetal tool exec runs persisted scripts through the baremetal filesystem" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    vga_text_console.resetForTest();

    try filesystem.init();
    try filesystem.createDirPath("/tools/scripts");
    try filesystem.writeFile(
        "/tools/scripts/bootstrap.oc",
        "# setup\nmkdir /tools/out\nwrite-file /tools/out/data.txt script-data\nstat /tools/out/data.txt\necho script-ok\n",
        0,
    );

    var result = try runCapture(std.testing.allocator, "run-script /tools/scripts/bootstrap.oc", 512, 256);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings(
        "created /tools/out\nwrote 11 bytes to /tools/out/data.txt\npath=/tools/out/data.txt kind=file size=11\nscript-ok\n",
        result.stdout,
    );
    try std.testing.expectEqualStrings("", result.stderr);

    const content = try filesystem.readFileAlloc(std.testing.allocator, "/tools/out/data.txt", 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("script-data", content);
}

test "baremetal tool exec runs packages from the canonical package layout" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    vga_text_console.resetForTest();

    try package_store.installScriptPackage("demo", "mkdir /pkg/out\nwrite-file /pkg/out/data.txt package-data\necho package-ok\n", 0);

    var result = try runCapture(std.testing.allocator, "run-package demo", 512, 256);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("created /pkg/out\nwrote 12 bytes to /pkg/out/data.txt\npackage-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    const content = try filesystem.readFileAlloc(std.testing.allocator, "/pkg/out/data.txt", 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("package-data", content);
}
