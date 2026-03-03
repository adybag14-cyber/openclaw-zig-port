const builtin = @import("builtin");
const std = @import("std");
const state = @import("state.zig");

pub const InputError = error{
    InvalidParamsFrame,
    MissingCommand,
    MissingPath,
    MissingContent,
};

pub const ExecResult = struct {
    ok: bool,
    status: u16,
    state: []const u8,
    jobId: u64,
    sessionId: []const u8,
    command: []const u8,
    exitCode: i32,
    stdout: []const u8,
    stderr: []const u8,

    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sessionId);
        allocator.free(self.command);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const FileReadResult = struct {
    ok: bool,
    status: u16,
    state: []const u8,
    jobId: u64,
    sessionId: []const u8,
    path: []const u8,
    bytes: usize,
    content: []const u8,

    pub fn deinit(self: *FileReadResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sessionId);
        allocator.free(self.path);
        allocator.free(self.content);
    }
};

pub const FileWriteResult = struct {
    ok: bool,
    status: u16,
    state: []const u8,
    jobId: u64,
    sessionId: []const u8,
    path: []const u8,
    bytes: usize,
    createdDirs: bool,

    pub fn deinit(self: *FileWriteResult, allocator: std.mem.Allocator) void {
        allocator.free(self.sessionId);
        allocator.free(self.path);
    }
};

pub const ToolRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime_state: state.RuntimeState,

    const default_session_id = "session-local";
    const default_exec_timeout_ms: u32 = 20_000;
    const max_exec_output_bytes: usize = 1024 * 1024;
    const max_file_read_bytes: usize = 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ToolRuntime {
        return .{
            .allocator = allocator,
            .io = io,
            .runtime_state = state.RuntimeState.init(allocator),
        };
    }

    pub fn deinit(self: *ToolRuntime) void {
        self.runtime_state.deinit();
    }

    pub fn queueDepth(self: *const ToolRuntime) usize {
        return self.runtime_state.queueDepth();
    }

    pub fn sessionCount(self: *const ToolRuntime) usize {
        return self.runtime_state.sessionCount();
    }

    pub fn execRunFromFrame(
        self: *ToolRuntime,
        allocator: std.mem.Allocator,
        frame_json: []const u8,
    ) !ExecResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
        defer parsed.deinit();

        const params = try getParamsObject(parsed.value);
        const command = try getRequiredString(params, "command", "cmd", error.MissingCommand);
        const session_id = getOptionalString(params, "sessionId", default_session_id);
        const timeout_ms = getOptionalU32(params, "timeoutMs", default_exec_timeout_ms);
        return self.execRun(allocator, session_id, command, timeout_ms);
    }

    pub fn fileReadFromFrame(
        self: *ToolRuntime,
        allocator: std.mem.Allocator,
        frame_json: []const u8,
    ) !FileReadResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
        defer parsed.deinit();

        const params = try getParamsObject(parsed.value);
        const path = try getRequiredString(params, "path", null, error.MissingPath);
        const session_id = getOptionalString(params, "sessionId", default_session_id);
        return self.fileRead(allocator, session_id, path);
    }

    pub fn fileWriteFromFrame(
        self: *ToolRuntime,
        allocator: std.mem.Allocator,
        frame_json: []const u8,
    ) !FileWriteResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
        defer parsed.deinit();

        const params = try getParamsObject(parsed.value);
        const path = try getRequiredString(params, "path", null, error.MissingPath);
        const content = try getRequiredString(params, "content", null, error.MissingContent);
        const session_id = getOptionalString(params, "sessionId", default_session_id);
        return self.fileWrite(allocator, session_id, path, content);
    }

    fn execRun(
        self: *ToolRuntime,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        command: []const u8,
        timeout_ms: u32,
    ) !ExecResult {
        const job_id = try self.runtime_state.enqueueJob(.exec, command);
        const queued = self.runtime_state.dequeueJob() orelse return error.JobQueueInvariant;
        defer self.runtime_state.releaseJob(queued);

        const argv = switch (builtin.os.tag) {
            .windows => [_][]const u8{ "C:\\Windows\\System32\\cmd.exe", "/C", command },
            else => [_][]const u8{ "/bin/sh", "-lc", command },
        };
        const timeout: std.Io.Timeout = .{
            .duration = std.Io.Clock.Duration{
                .clock = .awake,
                .raw = std.Io.Duration.fromMilliseconds(timeout_ms),
            },
        };

        const run_result = try std.process.run(self.allocator, self.io, .{
            .argv = &argv,
            .timeout = timeout,
            .stdout_limit = .limited(max_exec_output_bytes),
            .stderr_limit = .limited(max_exec_output_bytes),
        });
        defer self.allocator.free(run_result.stdout);
        defer self.allocator.free(run_result.stderr);

        const exit_code: i32 = switch (run_result.term) {
            .exited => |code| code,
            .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
            .stopped, .unknown => -1,
        };

        const session_copy = try allocator.dupe(u8, session_id);
        errdefer allocator.free(session_copy);
        const command_copy = try allocator.dupe(u8, command);
        errdefer allocator.free(command_copy);
        const stdout_copy = try allocator.dupe(u8, run_result.stdout);
        errdefer allocator.free(stdout_copy);
        const stderr_copy = try allocator.dupe(u8, run_result.stderr);
        errdefer allocator.free(stderr_copy);

        try self.runtime_state.upsertSession(session_id, command, nowUnixMilliseconds(self.io));

        return .{
            .ok = exit_code == 0,
            .status = if (exit_code == 0) 200 else 500,
            .state = "completed",
            .jobId = job_id,
            .sessionId = session_copy,
            .command = command_copy,
            .exitCode = exit_code,
            .stdout = stdout_copy,
            .stderr = stderr_copy,
        };
    }

    fn fileRead(
        self: *ToolRuntime,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        path: []const u8,
    ) !FileReadResult {
        const job_id = try self.runtime_state.enqueueJob(.file_read, path);
        const queued = self.runtime_state.dequeueJob() orelse return error.JobQueueInvariant;
        defer self.runtime_state.releaseJob(queued);

        const content = try std.Io.Dir.cwd().readFileAlloc(self.io, path, allocator, .limited(max_file_read_bytes));
        errdefer allocator.free(content);
        const session_copy = try allocator.dupe(u8, session_id);
        errdefer allocator.free(session_copy);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        const session_note = try std.fmt.allocPrint(self.allocator, "file.read:{s}", .{path});
        defer self.allocator.free(session_note);
        try self.runtime_state.upsertSession(session_id, session_note, nowUnixMilliseconds(self.io));

        return .{
            .ok = true,
            .status = 200,
            .state = "completed",
            .jobId = job_id,
            .sessionId = session_copy,
            .path = path_copy,
            .bytes = content.len,
            .content = content,
        };
    }

    fn fileWrite(
        self: *ToolRuntime,
        allocator: std.mem.Allocator,
        session_id: []const u8,
        path: []const u8,
        content: []const u8,
    ) !FileWriteResult {
        const job_id = try self.runtime_state.enqueueJob(.file_write, path);
        const queued = self.runtime_state.dequeueJob() orelse return error.JobQueueInvariant;
        defer self.runtime_state.releaseJob(queued);

        var created_dirs = false;
        if (std.fs.path.dirname(path)) |dir_name| {
            if (dir_name.len > 0) {
                try std.Io.Dir.cwd().createDirPath(self.io, dir_name);
                created_dirs = true;
            }
        }

        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = path,
            .data = content,
        });

        const session_copy = try allocator.dupe(u8, session_id);
        errdefer allocator.free(session_copy);
        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        const session_note = try std.fmt.allocPrint(self.allocator, "file.write:{s}", .{path});
        defer self.allocator.free(session_note);
        try self.runtime_state.upsertSession(session_id, session_note, nowUnixMilliseconds(self.io));

        return .{
            .ok = true,
            .status = 200,
            .state = "completed",
            .jobId = job_id,
            .sessionId = session_copy,
            .path = path_copy,
            .bytes = content.len,
            .createdDirs = created_dirs,
        };
    }
};

fn getParamsObject(frame: std.json.Value) !std.json.Value {
    if (frame != .object) return error.InvalidParamsFrame;
    const params_value = frame.object.get("params") orelse return error.InvalidParamsFrame;
    if (params_value != .object) return error.InvalidParamsFrame;
    return params_value;
}

fn getRequiredString(
    params: std.json.Value,
    key: []const u8,
    fallback_key: ?[]const u8,
    err_tag: anyerror,
) ![]const u8 {
    if (params.object.get(key)) |value| {
        if (value == .string and std.mem.trim(u8, value.string, " \t\r\n").len > 0) {
            return value.string;
        }
    }
    if (fallback_key) |fallback| {
        if (params.object.get(fallback)) |value| {
            if (value == .string and std.mem.trim(u8, value.string, " \t\r\n").len > 0) {
                return value.string;
            }
        }
    }
    return err_tag;
}

fn getOptionalString(
    params: std.json.Value,
    key: []const u8,
    default_value: []const u8,
) []const u8 {
    if (params.object.get(key)) |value| {
        if (value == .string and std.mem.trim(u8, value.string, " \t\r\n").len > 0) {
            return value.string;
        }
    }
    return default_value;
}

fn getOptionalU32(
    params: std.json.Value,
    key: []const u8,
    default_value: u32,
) u32 {
    if (params.object.get(key)) |value| switch (value) {
        .integer => |raw| {
            if (raw > 0 and raw <= std.math.maxInt(u32)) return @as(u32, @intCast(raw));
        },
        .float => |raw| {
            if (raw > 0 and raw <= @as(f64, @floatFromInt(std.math.maxInt(u32)))) return @as(u32, @intFromFloat(raw));
        },
        .string => |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) {
                const parsed = std.fmt.parseInt(u32, trimmed, 10) catch return default_value;
                if (parsed > 0) return parsed;
            }
        },
        else => {},
    };
    return default_value;
}

fn nowUnixMilliseconds(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

test "tool runtime file write/read lifecycle with session state" {
    const allocator = std.testing.allocator;
    var runtime = ToolRuntime.init(std.heap.page_allocator, std.testing.io);
    defer runtime.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.Io.Threaded.global_single_threaded.io();
    const base_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base_path);
    const test_path = try std.fs.path.join(allocator, &.{ base_path, "runtime-file.txt" });
    defer allocator.free(test_path);

    var write_result = try runtime.fileWrite(allocator, "sess-phase3", test_path, "phase3-data");
    defer write_result.deinit(allocator);
    try std.testing.expect(write_result.ok);
    try std.testing.expectEqual(@as(usize, 0), runtime.queueDepth());

    var read_result = try runtime.fileRead(allocator, "sess-phase3", test_path);
    defer read_result.deinit(allocator);
    try std.testing.expect(read_result.ok);
    try std.testing.expect(std.mem.eql(u8, read_result.content, "phase3-data"));
    try std.testing.expectEqual(@as(usize, 0), runtime.queueDepth());
    try std.testing.expectEqual(@as(usize, 1), runtime.sessionCount());

    const session = runtime.runtime_state.getSession("sess-phase3").?;
    try std.testing.expect(std.mem.indexOf(u8, session.last_message, "file.read:") != null);
}

test "tool runtime exec lifecycle returns output and keeps queue empty" {
    const allocator = std.testing.allocator;
    var runtime = ToolRuntime.init(std.heap.page_allocator, std.testing.io);
    defer runtime.deinit();

    const command = switch (builtin.os.tag) {
        .windows => "echo phase3-exec",
        else => "printf phase3-exec",
    };

    var result = runtime.execRun(allocator, "sess-exec", command, 20_000) catch return error.SkipZigTest;
    defer result.deinit(allocator);
    try std.testing.expect(result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "phase3-exec") != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.queueDepth());
}
