const std = @import("std");

pub const Session = struct {
    created_unix_ms: i64,
    updated_unix_ms: i64,
    last_message: []u8,
};

pub const SessionSnapshot = struct {
    id: []const u8,
    created_unix_ms: i64,
    updated_unix_ms: i64,
    last_message: []const u8,
};

pub const JobKind = enum {
    exec,
    file_read,
    file_write,
};

pub const Job = struct {
    id: u64,
    kind: JobKind,
    payload: []u8,
};

const PersistedSession = struct {
    id: []const u8,
    createdAtMs: i64,
    updatedAtMs: i64,
    lastMessage: []const u8,
};

const PersistedJob = struct {
    id: u64,
    kind: []const u8,
    payload: []const u8,
};

const PersistedState = struct {
    nextJobId: u64 = 1,
    sessions: []PersistedSession = &.{},
    pendingJobs: []PersistedJob = &.{},
};

pub const RuntimeState = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(Session),
    pending_jobs: std.ArrayList(Job),
    pending_jobs_head: usize,
    next_job_id: u64,
    state_path: ?[]u8,
    persistent: bool,

    pub fn init(allocator: std.mem.Allocator) RuntimeState {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(Session).init(allocator),
            .pending_jobs = .empty,
            .pending_jobs_head = 0,
            .next_job_id = 1,
            .state_path = null,
            .persistent = false,
        };
    }

    pub fn deinit(self: *RuntimeState) void {
        self.clearState();
        self.sessions.deinit();
        self.pending_jobs.deinit(self.allocator);
        if (self.state_path) |path| {
            self.allocator.free(path);
        }
        self.state_path = null;
        self.persistent = false;
    }

    pub fn configurePersistence(self: *RuntimeState, state_root: []const u8) !void {
        const resolved = try resolveStatePath(self.allocator, state_root);
        if (self.state_path) |existing| self.allocator.free(existing);
        self.state_path = resolved;
        self.persistent = shouldPersist(resolved);
        if (!self.persistent) return;

        // Persistence configuration is expected during runtime bootstrap.
        // If state already exists in memory, keep it untouched.
        if (self.sessions.count() == 0 and self.queueDepth() == 0 and self.next_job_id == 1) {
            try self.load();
        }
    }

    pub fn upsertSession(
        self: *RuntimeState,
        session_id: []const u8,
        message: []const u8,
        now_unix_ms: i64,
    ) !void {
        if (self.sessions.getPtr(session_id)) |existing| {
            self.allocator.free(existing.last_message);
            existing.last_message = try self.allocator.dupe(u8, message);
            existing.updated_unix_ms = now_unix_ms;
            if (self.persistent) try self.persist();
            return;
        }

        const owned_key = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(owned_key);
        const owned_message = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned_message);

        try self.sessions.put(owned_key, .{
            .created_unix_ms = now_unix_ms,
            .updated_unix_ms = now_unix_ms,
            .last_message = owned_message,
        });
        if (self.persistent) try self.persist();
    }

    pub fn getSession(self: *RuntimeState, session_id: []const u8) ?SessionSnapshot {
        const value = self.sessions.get(session_id) orelse return null;
        return .{
            .id = session_id,
            .created_unix_ms = value.created_unix_ms,
            .updated_unix_ms = value.updated_unix_ms,
            .last_message = value.last_message,
        };
    }

    pub fn enqueueJob(self: *RuntimeState, kind: JobKind, payload: []const u8) !u64 {
        const owned_payload = try self.allocator.dupe(u8, payload);
        const job_id = self.next_job_id;
        self.next_job_id += 1;
        try self.pending_jobs.append(self.allocator, .{
            .id = job_id,
            .kind = kind,
            .payload = owned_payload,
        });
        if (self.persistent) try self.persist();
        return job_id;
    }

    pub fn dequeueJob(self: *RuntimeState) ?Job {
        if (self.pending_jobs_head >= self.pending_jobs.items.len) return null;
        const job = self.pending_jobs.items[self.pending_jobs_head];
        self.pending_jobs_head += 1;
        self.compactPendingJobs();
        if (self.persistent) self.persist() catch {};
        return job;
    }

    pub fn releaseJob(self: *RuntimeState, job: Job) void {
        self.allocator.free(job.payload);
    }

    pub fn queueDepth(self: *const RuntimeState) usize {
        return self.pending_jobs.items.len - self.pending_jobs_head;
    }

    pub fn sessionCount(self: *const RuntimeState) usize {
        return self.sessions.count();
    }

    fn compactPendingJobs(self: *RuntimeState) void {
        const len = self.pending_jobs.items.len;
        const head = self.pending_jobs_head;
        if (head == 0) return;
        if (head < 32 and head * 2 < len) return;

        const remaining = len - head;
        if (remaining > 0) {
            std.mem.copyForwards(Job, self.pending_jobs.items[0..remaining], self.pending_jobs.items[head..]);
        }
        self.pending_jobs.items.len = remaining;
        self.pending_jobs_head = 0;
    }

    fn clearState(self: *RuntimeState) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.last_message);
        }
        self.sessions.clearRetainingCapacity();

        for (self.pending_jobs.items[self.pending_jobs_head..]) |job| {
            self.allocator.free(job.payload);
        }
        self.pending_jobs.clearRetainingCapacity();
        self.pending_jobs_head = 0;
        self.next_job_id = 1;
    }

    fn load(self: *RuntimeState) !void {
        const path = self.state_path orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(raw);

        var parsed = try std.json.parseFromSlice(PersistedState, self.allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        self.clearState();
        var max_job_id: u64 = 0;

        for (parsed.value.sessions) |entry| {
            const key = try self.allocator.dupe(u8, std.mem.trim(u8, entry.id, " \t\r\n"));
            errdefer self.allocator.free(key);
            const message = try self.allocator.dupe(u8, entry.lastMessage);
            errdefer self.allocator.free(message);
            try self.sessions.put(key, .{
                .created_unix_ms = entry.createdAtMs,
                .updated_unix_ms = entry.updatedAtMs,
                .last_message = message,
            });
        }

        for (parsed.value.pendingJobs) |entry| {
            const kind = parseJobKind(entry.kind) orelse continue;
            const payload = try self.allocator.dupe(u8, entry.payload);
            errdefer self.allocator.free(payload);
            try self.pending_jobs.append(self.allocator, .{
                .id = entry.id,
                .kind = kind,
                .payload = payload,
            });
            if (entry.id > max_job_id) max_job_id = entry.id;
        }
        self.pending_jobs_head = 0;
        self.next_job_id = parsed.value.nextJobId;
        if (self.next_job_id <= max_job_id) self.next_job_id = max_job_id + 1;
    }

    fn persist(self: *RuntimeState) !void {
        if (!self.persistent) return;
        const path = self.state_path orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();

        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        var persisted_sessions = try self.allocator.alloc(PersistedSession, self.sessions.count());
        defer self.allocator.free(persisted_sessions);
        var session_index: usize = 0;
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr.*;
            persisted_sessions[session_index] = .{
                .id = entry.key_ptr.*,
                .createdAtMs = session.created_unix_ms,
                .updatedAtMs = session.updated_unix_ms,
                .lastMessage = session.last_message,
            };
            session_index += 1;
        }

        const pending_count = self.pending_jobs.items.len - self.pending_jobs_head;
        var persisted_jobs = try self.allocator.alloc(PersistedJob, pending_count);
        defer self.allocator.free(persisted_jobs);
        for (self.pending_jobs.items[self.pending_jobs_head..], 0..) |job, idx| {
            persisted_jobs[idx] = .{
                .id = job.id,
                .kind = formatJobKind(job.kind),
                .payload = job.payload,
            };
        }

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .nextJobId = self.next_job_id,
            .sessions = persisted_sessions,
            .pendingJobs = persisted_jobs,
        }, .{}, &out.writer);
        const payload = try out.toOwnedSlice();
        defer self.allocator.free(payload);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = payload,
        });
    }
};

fn resolveStatePath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, state_root, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "memory://runtime-state");
    if (isMemoryScheme(trimmed)) return allocator.dupe(u8, trimmed);
    if (std.mem.endsWith(u8, trimmed, ".json")) return allocator.dupe(u8, trimmed);
    return std.fs.path.join(allocator, &.{ trimmed, "runtime-state.json" });
}

fn shouldPersist(path: []const u8) bool {
    return !isMemoryScheme(path);
}

fn isMemoryScheme(path: []const u8) bool {
    const prefix = "memory://";
    if (path.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
}

fn formatJobKind(kind: JobKind) []const u8 {
    return switch (kind) {
        .exec => "exec",
        .file_read => "file_read",
        .file_write => "file_write",
    };
}

fn parseJobKind(value: []const u8) ?JobKind {
    if (std.ascii.eqlIgnoreCase(value, "exec")) return .exec;
    if (std.ascii.eqlIgnoreCase(value, "file_read")) return .file_read;
    if (std.ascii.eqlIgnoreCase(value, "file_write")) return .file_write;
    return null;
}

test "runtime state stores and updates sessions" {
    const allocator = std.testing.allocator;
    var state = RuntimeState.init(allocator);
    defer state.deinit();

    try state.upsertSession("session-a", "hello", 1000);
    var snap = state.getSession("session-a").?;
    try std.testing.expectEqual(@as(i64, 1000), snap.created_unix_ms);
    try std.testing.expect(std.mem.eql(u8, snap.last_message, "hello"));

    try state.upsertSession("session-a", "updated", 1500);
    snap = state.getSession("session-a").?;
    try std.testing.expectEqual(@as(i64, 1000), snap.created_unix_ms);
    try std.testing.expectEqual(@as(i64, 1500), snap.updated_unix_ms);
    try std.testing.expect(std.mem.eql(u8, snap.last_message, "updated"));
}

test "runtime state queue preserves order" {
    const allocator = std.testing.allocator;
    var state = RuntimeState.init(allocator);
    defer state.deinit();

    _ = try state.enqueueJob(.exec, "{\"cmd\":\"echo hi\"}");
    _ = try state.enqueueJob(.file_read, "{\"path\":\"README.md\"}");
    try std.testing.expectEqual(@as(usize, 2), state.queueDepth());

    const first = state.dequeueJob().?;
    defer state.releaseJob(first);
    try std.testing.expectEqual(@as(u64, 1), first.id);
    try std.testing.expectEqual(JobKind.exec, first.kind);

    const second = state.dequeueJob().?;
    defer state.releaseJob(second);
    try std.testing.expectEqual(@as(u64, 2), second.id);
    try std.testing.expectEqual(JobKind.file_read, second.kind);

    try std.testing.expect(state.dequeueJob() == null);
}

test "runtime state queue depth stays correct across compaction cycles" {
    const allocator = std.testing.allocator;
    var state = RuntimeState.init(allocator);
    defer state.deinit();

    var idx: usize = 0;
    while (idx < 96) : (idx += 1) {
        _ = try state.enqueueJob(.exec, "{\"cmd\":\"echo hi\"}");
    }
    try std.testing.expectEqual(@as(usize, 96), state.queueDepth());

    idx = 0;
    while (idx < 80) : (idx += 1) {
        const job = state.dequeueJob().?;
        state.releaseJob(job);
    }
    try std.testing.expectEqual(@as(usize, 16), state.queueDepth());

    idx = 0;
    while (idx < 20) : (idx += 1) {
        _ = try state.enqueueJob(.file_read, "{\"path\":\"README.md\"}");
    }
    try std.testing.expectEqual(@as(usize, 36), state.queueDepth());

    var expected_id: u64 = 81;
    while (state.dequeueJob()) |job| {
        defer state.releaseJob(job);
        try std.testing.expectEqual(expected_id, job.id);
        expected_id += 1;
    }
    try std.testing.expectEqual(@as(u64, 117), expected_id);
    try std.testing.expectEqual(@as(usize, 0), state.queueDepth());
}

test "runtime state persistence roundtrip restores session and pending queue" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    {
        var state = RuntimeState.init(allocator);
        defer state.deinit();
        try state.configurePersistence(root);
        try state.upsertSession("persist-s1", "hello runtime", 1_000);
        _ = try state.enqueueJob(.file_read, "{\"path\":\"README.md\"}");
        _ = try state.enqueueJob(.exec, "{\"cmd\":\"echo hi\"}");
        const consumed = state.dequeueJob().?;
        state.releaseJob(consumed);
    }

    {
        var restored = RuntimeState.init(allocator);
        defer restored.deinit();
        try restored.configurePersistence(root);
        const snap = restored.getSession("persist-s1").?;
        try std.testing.expectEqual(@as(i64, 1_000), snap.created_unix_ms);
        try std.testing.expect(std.mem.eql(u8, snap.last_message, "hello runtime"));
        try std.testing.expectEqual(@as(usize, 1), restored.queueDepth());
        const queued = restored.dequeueJob().?;
        defer restored.releaseJob(queued);
        try std.testing.expectEqual(@as(u64, 2), queued.id);
        try std.testing.expectEqual(JobKind.exec, queued.kind);
        try std.testing.expectEqual(@as(usize, 0), restored.queueDepth());
    }
}
