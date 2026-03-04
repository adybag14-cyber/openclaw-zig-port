const std = @import("std");
const time_util = @import("../util/time.zig");

pub const MessageView = struct {
    id: []const u8,
    sessionId: []const u8,
    channel: []const u8,
    method: []const u8,
    role: []const u8,
    text: []const u8,
    createdAtMs: i64,
};

pub const HistoryResult = struct {
    count: usize,
    items: []MessageView,

    pub fn deinit(self: *HistoryResult, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }
};

pub const StatsView = struct {
    entries: usize,
    maxEntries: usize,
    persistent: bool,
    statePath: []const u8,
};

const MessageEntry = struct {
    id: []u8,
    session_id: []u8,
    channel: []u8,
    method: []u8,
    role: []u8,
    text: []u8,
    created_at_ms: i64,

    fn deinit(self: *MessageEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.channel);
        allocator.free(self.method);
        allocator.free(self.role);
        allocator.free(self.text);
    }

    fn view(self: *const MessageEntry) MessageView {
        return .{
            .id = self.id,
            .sessionId = self.session_id,
            .channel = self.channel,
            .method = self.method,
            .role = self.role,
            .text = self.text,
            .createdAtMs = self.created_at_ms,
        };
    }
};

const PersistedEntry = struct {
    id: []const u8,
    sessionId: []const u8,
    channel: []const u8,
    method: []const u8,
    role: []const u8,
    text: []const u8,
    createdAtMs: i64,
};

const PersistedState = struct {
    nextId: u64 = 1,
    entries: []PersistedEntry = &.{},
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    state_path: []u8,
    persistent: bool,
    max_entries: usize,
    next_id: u64,
    entries: std.ArrayList(MessageEntry),

    pub fn init(allocator: std.mem.Allocator, state_root: []const u8, max_entries: usize) !Store {
        const resolved = try resolveStatePath(allocator, state_root);
        var out = Store{
            .allocator = allocator,
            .state_path = resolved,
            .persistent = shouldPersist(resolved),
            .max_entries = if (max_entries == 0) 5000 else max_entries,
            .next_id = 1,
            .entries = .empty,
        };
        if (out.persistent) try out.load();
        return out;
    }

    pub fn deinit(self: *Store) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.state_path);
    }

    pub fn append(
        self: *Store,
        session_id: []const u8,
        channel: []const u8,
        method: []const u8,
        role: []const u8,
        text: []const u8,
    ) !void {
        const id = try std.fmt.allocPrint(self.allocator, "msg-{d}", .{self.next_id});
        self.next_id += 1;
        try self.entries.append(self.allocator, .{
            .id = id,
            .session_id = try self.allocator.dupe(u8, std.mem.trim(u8, session_id, " \t\r\n")),
            .channel = try self.allocator.dupe(u8, std.mem.trim(u8, channel, " \t\r\n")),
            .method = try self.allocator.dupe(u8, std.mem.trim(u8, method, " \t\r\n")),
            .role = try self.allocator.dupe(u8, std.mem.trim(u8, role, " \t\r\n")),
            .text = try self.allocator.dupe(u8, std.mem.trim(u8, text, " \t\r\n")),
            .created_at_ms = nowMs(),
        });

        if (self.entries.items.len > self.max_entries) {
            _ = self.removeFrontEntries(self.entries.items.len - self.max_entries);
        }
        if (self.persistent) try self.persist();
    }

    pub fn historyBySession(self: *Store, allocator: std.mem.Allocator, session_id: []const u8, limit: usize) !HistoryResult {
        return self.historyByKey(allocator, "session", session_id, limit);
    }

    pub fn historyByChannel(self: *Store, allocator: std.mem.Allocator, channel: []const u8, limit: usize) !HistoryResult {
        return self.historyByKey(allocator, "channel", channel, limit);
    }

    pub fn stats(self: *Store) StatsView {
        return .{
            .entries = self.entries.items.len,
            .maxEntries = self.max_entries,
            .persistent = self.persistent,
            .statePath = self.state_path,
        };
    }

    pub fn count(self: *const Store) usize {
        return self.entries.items.len;
    }

    pub fn removeSession(self: *Store, session_id: []const u8) !usize {
        const needle = std.mem.trim(u8, session_id, " \t\r\n");
        if (needle.len == 0) return 0;

        var removed: usize = 0;
        var write_idx: usize = 0;
        var read_idx: usize = 0;
        while (read_idx < self.entries.items.len) : (read_idx += 1) {
            if (std.mem.eql(u8, self.entries.items[read_idx].session_id, needle)) {
                var entry = self.entries.items[read_idx];
                entry.deinit(self.allocator);
                removed += 1;
            } else {
                if (write_idx != read_idx) {
                    self.entries.items[write_idx] = self.entries.items[read_idx];
                }
                write_idx += 1;
            }
        }
        self.entries.items.len = write_idx;

        if (removed > 0 and self.persistent) try self.persist();
        return removed;
    }

    pub fn trim(self: *Store, limit: usize) !usize {
        if (self.entries.items.len <= limit) return 0;
        const removed = self.removeFrontEntries(self.entries.items.len - limit);
        if (removed > 0 and self.persistent) try self.persist();
        return removed;
    }

    fn removeFrontEntries(self: *Store, remove_count: usize) usize {
        if (remove_count == 0 or self.entries.items.len == 0) return 0;
        const to_remove = @min(remove_count, self.entries.items.len);
        for (self.entries.items[0..to_remove]) |*entry| entry.deinit(self.allocator);
        const remain = self.entries.items.len - to_remove;
        if (remain > 0) {
            std.mem.copyForwards(MessageEntry, self.entries.items[0..remain], self.entries.items[to_remove..]);
        }
        self.entries.items.len = remain;
        return to_remove;
    }

    fn historyByKey(self: *Store, allocator: std.mem.Allocator, key: []const u8, value: []const u8, limit: usize) !HistoryResult {
        const cap = if (limit == 0) 50 else limit;
        const max_matches = @min(cap, self.entries.items.len);
        var views = try allocator.alloc(MessageView, max_matches);
        var matched: usize = 0;
        const needle = std.mem.trim(u8, value, " \t\r\n");
        var index = self.entries.items.len;
        while (index > 0 and matched < views.len) : (index -= 1) {
            const entry = self.entries.items[index - 1];
            if (needle.len > 0) {
                if (std.ascii.eqlIgnoreCase(key, "session") and !std.mem.eql(u8, entry.session_id, needle)) continue;
                if (std.ascii.eqlIgnoreCase(key, "channel") and !std.ascii.eqlIgnoreCase(entry.channel, needle)) continue;
            }
            views[matched] = entry.view();
            matched += 1;
        }
        std.mem.reverse(MessageView, views[0..matched]);
        const result_items = try allocator.alloc(MessageView, matched);
        @memcpy(result_items, views[0..matched]);
        allocator.free(views);
        return .{
            .count = matched,
            .items = result_items,
        };
    }

    fn load(self: *Store) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const raw = std.Io.Dir.cwd().readFileAlloc(io, self.state_path, self.allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(raw);

        var parsed = try std.json.parseFromSlice(PersistedState, self.allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        for (parsed.value.entries) |entry| {
            try self.entries.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, entry.id),
                .session_id = try self.allocator.dupe(u8, entry.sessionId),
                .channel = try self.allocator.dupe(u8, entry.channel),
                .method = try self.allocator.dupe(u8, entry.method),
                .role = try self.allocator.dupe(u8, entry.role),
                .text = try self.allocator.dupe(u8, entry.text),
                .created_at_ms = entry.createdAtMs,
            });
        }
        if (parsed.value.nextId > self.next_id) self.next_id = parsed.value.nextId;
    }

    fn persist(self: *Store) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        if (std.fs.path.dirname(self.state_path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        var out_entries = try self.allocator.alloc(PersistedEntry, self.entries.items.len);
        defer self.allocator.free(out_entries);
        for (self.entries.items, 0..) |entry, idx| {
            out_entries[idx] = .{
                .id = entry.id,
                .sessionId = entry.session_id,
                .channel = entry.channel,
                .method = entry.method,
                .role = entry.role,
                .text = entry.text,
                .createdAtMs = entry.created_at_ms,
            };
        }

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .nextId = self.next_id,
            .entries = out_entries,
        }, .{}, &out.writer);
        const payload = try out.toOwnedSlice();
        defer self.allocator.free(payload);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = self.state_path,
            .data = payload,
        });
    }
};

fn resolveStatePath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, state_root, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "memory://openclaw-zig");
    if (isMemoryScheme(trimmed)) return allocator.dupe(u8, trimmed);
    if (std.mem.endsWith(u8, trimmed, ".json")) return allocator.dupe(u8, trimmed);
    return std.fs.path.join(allocator, &.{ trimmed, "memory.json" });
}

fn shouldPersist(path: []const u8) bool {
    return !isMemoryScheme(path);
}

fn isMemoryScheme(path: []const u8) bool {
    const prefix = "memory://";
    if (path.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
}

fn nowMs() i64 {
    return time_util.nowMs();
}

test "store append/history and persistence roundtrip" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var store = try Store.init(allocator, root, 200);
    defer store.deinit();
    try store.append("s1", "telegram", "send", "user", "hello");
    try store.append("s1", "telegram", "send", "assistant", "hi");

    var history = try store.historyBySession(allocator, "s1", 10);
    defer history.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), history.count);
    try std.testing.expect(std.mem.eql(u8, history.items[0].text, "hello"));
    try std.testing.expect(std.mem.eql(u8, history.items[1].text, "hi"));

    var loaded = try Store.init(allocator, root, 200);
    defer loaded.deinit();
    var loaded_history = try loaded.historyBySession(allocator, "s1", 10);
    defer loaded_history.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), loaded_history.count);
}

test "store removeSession and trim keep ordering with linear compaction" {
    const allocator = std.testing.allocator;
    var store = try Store.init(allocator, "memory://opt-test", 32);
    defer store.deinit();

    try store.append("s1", "telegram", "send", "user", "a1");
    try store.append("s2", "telegram", "send", "user", "b1");
    try store.append("s1", "telegram", "send", "assistant", "a2");
    try store.append("s3", "telegram", "send", "user", "c1");

    const removed_s1 = try store.removeSession("s1");
    try std.testing.expectEqual(@as(usize, 2), removed_s1);
    try std.testing.expectEqual(@as(usize, 2), store.count());

    var s2_history = try store.historyBySession(allocator, "s2", 10);
    defer s2_history.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), s2_history.count);
    try std.testing.expect(std.mem.eql(u8, s2_history.items[0].text, "b1"));

    var all_before_trim = try store.historyBySession(allocator, "", 10);
    defer all_before_trim.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), all_before_trim.count);
    try std.testing.expect(std.mem.eql(u8, all_before_trim.items[0].text, "b1"));
    try std.testing.expect(std.mem.eql(u8, all_before_trim.items[1].text, "c1"));

    const trimmed = try store.trim(1);
    try std.testing.expectEqual(@as(usize, 1), trimmed);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    var all_after_trim = try store.historyBySession(allocator, "", 10);
    defer all_after_trim.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), all_after_trim.count);
    try std.testing.expect(std.mem.eql(u8, all_after_trim.items[0].text, "c1"));
}
