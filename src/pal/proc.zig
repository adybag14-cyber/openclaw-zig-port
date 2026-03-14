const builtin = @import("builtin");
const std = @import("std");
const baremetal_tool_exec = @import("../baremetal/tool_exec.zig");

pub const RunCapture = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *RunCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn timeoutFromMs(timeout_ms: u32) std.Io.Timeout {
    return switch (builtin.os.tag) {
        .windows => .none,
        else => .{
            .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            },
        },
    };
}

fn runCaptureHosted(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: u32,
    stdout_limit: usize,
    stderr_limit: usize,
) !RunCapture {
    const run_result = try std.process.run(allocator, io, .{
        .argv = argv,
        .timeout = timeoutFromMs(timeout_ms),
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(stderr_limit),
    });
    return .{
        .term = run_result.term,
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
    };
}

fn resolveFreestandingCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (argv.len == 0) return error.MissingCommand;
    if (argv.len == 1) return allocator.dupe(u8, argv[0]);
    if (argv.len >= 3 and (std.mem.eql(u8, argv[1], "/C") or std.mem.eql(u8, argv[1], "-lc"))) {
        return allocator.dupe(u8, argv[2]);
    }
    return std.mem.join(allocator, " ", argv);
}

pub fn runCaptureFreestanding(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    timeout_ms: u32,
    stdout_limit: usize,
    stderr_limit: usize,
) !RunCapture {
    _ = io;
    _ = timeout_ms;

    const command = try resolveFreestandingCommand(allocator, argv);
    defer allocator.free(command);

    var result = try baremetal_tool_exec.runCapture(allocator, command, stdout_limit, stderr_limit);
    errdefer result.deinit(allocator);

    return .{
        .term = .{ .exited = @intCast(result.exit_code) },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub const runCapture = if (builtin.os.tag == .freestanding) runCaptureFreestanding else runCaptureHosted;

pub fn termExitCode(term: std.process.Child.Term) i32 {
    if (builtin.os.tag == .freestanding) {
        return switch (term) {
            .exited => |code| code,
            else => -1,
        };
    }

    return switch (term) {
        .exited => |code| code,
        .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
        .stopped, .unknown => -1,
    };
}

pub fn isCommandAllowed(command: []const u8, allowlist_csv: []const u8) bool {
    const trimmed_command = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed_command.len == 0) return false;
    const trimmed_allowlist = std.mem.trim(u8, allowlist_csv, " \t\r\n");
    if (trimmed_allowlist.len == 0) return true;

    var it = std.mem.tokenizeAny(u8, trimmed_allowlist, ",;");
    while (it.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t\r\n");
        if (entry.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(trimmed_command, entry)) return true;
    }
    return false;
}

test "isCommandAllowed supports empty and prefixed allowlists" {
    try std.testing.expect(isCommandAllowed("printf hello", ""));
    try std.testing.expect(isCommandAllowed("printf hello", "printf"));
    try std.testing.expect(!isCommandAllowed("uname -a", "printf,echo"));
}
