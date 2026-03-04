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

pub const RuntimeState = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(Session),
    pending_jobs: std.ArrayList(Job),
    pending_jobs_head: usize,
    next_job_id: u64,

    pub fn init(allocator: std.mem.Allocator) RuntimeState {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(Session).init(allocator),
            .pending_jobs = .empty,
            .pending_jobs_head = 0,
            .next_job_id = 1,
        };
    }

    pub fn deinit(self: *RuntimeState) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.last_message);
        }
        self.sessions.deinit();

        for (self.pending_jobs.items[self.pending_jobs_head..]) |job| {
            self.allocator.free(job.payload);
        }
        self.pending_jobs.deinit(self.allocator);
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
        return job_id;
    }

    pub fn dequeueJob(self: *RuntimeState) ?Job {
        if (self.pending_jobs_head >= self.pending_jobs.items.len) return null;
        const job = self.pending_jobs.items[self.pending_jobs_head];
        self.pending_jobs_head += 1;
        self.compactPendingJobs();
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
};

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
