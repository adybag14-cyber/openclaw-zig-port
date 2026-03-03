const std = @import("std");

pub const TriggerResult = struct {
    triggered: bool,
    hits: usize,
};

pub const Snapshot = struct {
    enabled: bool,
    windowMs: i64,
    maxHits: usize,
};

pub const LoopGuard = struct {
    allocator: std.mem.Allocator,
    enabled: bool,
    window_ms: i64,
    max_hits: usize,
    history: std.StringHashMap(std.ArrayList(i64)),

    pub fn init(
        allocator: std.mem.Allocator,
        enabled: bool,
        window_ms: u32,
        max_hits: u16,
    ) LoopGuard {
        return .{
            .allocator = allocator,
            .enabled = enabled,
            .window_ms = if (window_ms == 0) 5_000 else @as(i64, @intCast(window_ms)),
            .max_hits = if (max_hits == 0) 8 else @as(usize, @intCast(max_hits)),
            .history = std.StringHashMap(std.ArrayList(i64)).init(allocator),
        };
    }

    pub fn deinit(self: *LoopGuard) void {
        var it = self.history.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.history.deinit();
    }

    pub fn register(
        self: *LoopGuard,
        method: []const u8,
        session_id: []const u8,
    ) !TriggerResult {
        if (!self.enabled) return .{ .triggered = false, .hits = 0 };

        const key = try std.fmt.allocPrint(self.allocator, "{s}|{s}", .{
            if (session_id.len == 0) "global" else session_id,
            method,
        });
        defer self.allocator.free(key);

        const now = std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
        const threshold = now - self.window_ms;

        var list_ptr: *std.ArrayList(i64) = blk: {
            if (self.history.getPtr(key)) |existing| break :blk existing;
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            const list: std.ArrayList(i64) = .empty;
            try self.history.put(owned_key, list);
            break :blk self.history.getPtr(owned_key).?;
        };

        var write_index: usize = 0;
        for (list_ptr.items) |hit| {
            if (hit >= threshold) {
                list_ptr.items[write_index] = hit;
                write_index += 1;
            }
        }
        list_ptr.items.len = write_index;
        try list_ptr.append(self.allocator, now);

        const count = list_ptr.items.len;
        return .{
            .triggered = count > self.max_hits,
            .hits = count,
        };
    }

    pub fn snapshot(self: *const LoopGuard) Snapshot {
        return .{
            .enabled = self.enabled,
            .windowMs = self.window_ms,
            .maxHits = self.max_hits,
        };
    }
};

test "loop guard triggers after threshold in same session" {
    var guard = LoopGuard.init(std.testing.allocator, true, 5_000, 2);
    defer guard.deinit();

    const first = try guard.register("file.read", "sess-a");
    try std.testing.expect(!first.triggered);

    const second = try guard.register("file.read", "sess-a");
    try std.testing.expect(!second.triggered);

    const third = try guard.register("file.read", "sess-a");
    try std.testing.expect(third.triggered);
}
