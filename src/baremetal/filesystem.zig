const std = @import("std");
const abi = @import("abi.zig");
const storage_backend = @import("storage_backend.zig");
const tool_layout = @import("tool_layout.zig");

pub const max_entries: usize = 32;
pub const max_path_len: usize = 96;
pub const superblock_lba: u32 = tool_layout.slot_data_lba + @as(u32, tool_layout.slot_count * tool_layout.slot_block_capacity);
pub const entry_table_lba: u32 = superblock_lba + 1;

var state: abi.BaremetalFilesystemState = undefined;
var entries: [max_entries]abi.BaremetalFilesystemEntry = std.mem.zeroes([max_entries]abi.BaremetalFilesystemEntry);

const entry_table_bytes = @sizeOf(@TypeOf(entries));
comptime {
    if (entry_table_bytes % storage_backend.block_size != 0) {
        @compileError("filesystem entry table must be block aligned");
    }
}

pub const entry_table_block_count: u32 = @as(u32, entry_table_bytes / storage_backend.block_size);
pub const data_lba: u32 = entry_table_lba + entry_table_block_count;

const NormalizedPath = struct {
    buf: [max_path_len]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const @This()) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Error = storage_backend.Error || std.mem.Allocator.Error || error{
    InvalidPath,
    FileNotFound,
    FileTooBig,
    NotDirectory,
    IsDirectory,
    NoSpace,
    CorruptFilesystem,
};

pub fn resetForTest() void {
    state = .{
        .magic = abi.filesystem_magic,
        .api_version = abi.api_version,
        .max_entries = @as(u16, max_entries),
        .formatted = 0,
        .mounted = 0,
        .dirty = 0,
        .active_backend = abi.storage_backend_ram_disk,
        .superblock_lba = superblock_lba,
        .entry_table_lba = entry_table_lba,
        .entry_table_block_count = entry_table_block_count,
        .data_lba = data_lba,
        .used_entries = 0,
        .dir_entries = 0,
        .file_entries = 0,
        .reserved0 = 0,
        .format_count = 0,
        .create_dir_count = 0,
        .write_count = 0,
        .read_count = 0,
        .stat_count = 0,
        .last_entry_id = 0,
        .last_data_lba = data_lba,
        .reserved1 = 0,
        .last_modified_tick = 0,
    };
    @memset(&entries, std.mem.zeroes(abi.BaremetalFilesystemEntry));
}

pub fn init() Error!void {
    storage_backend.init();
    if (try loadExisting()) return;
    try format();
}

pub fn statePtr() *const abi.BaremetalFilesystemState {
    return &state;
}

pub fn entry(index: u32) abi.BaremetalFilesystemEntry {
    if (index >= max_entries) return std.mem.zeroes(abi.BaremetalFilesystemEntry);
    return entries[@as(usize, @intCast(index))];
}

pub fn createDirPath(path: []const u8) Error!void {
    try init();
    const normalized = try normalizePath(path);
    if (normalized.len == 1) return;

    const full = normalized.slice();
    var index: usize = 1;
    while (index <= full.len) : (index += 1) {
        const at_end = index == full.len;
        if (!at_end and full[index] != '/') continue;

        const prefix_len = if (at_end) index else index;
        const prefix = full[0..prefix_len];
        if (prefix.len == 0 or (prefix.len == 1 and prefix[0] == '/')) continue;

        const existing = findEntryIndex(prefix);
        if (existing) |entry_index| {
            if (entries[entry_index].kind != abi.filesystem_kind_directory) return error.NotDirectory;
            continue;
        }
        const free_index = try findFreeEntryIndex();
        entries[free_index] = makeEntry(prefix, abi.filesystem_kind_directory, 0, 0, 0, 0, 0);
        state.create_dir_count +%= 1;
        state.dirty = 1;
    }

    recountState();
    try persistAll();
}

pub fn writeFile(path: []const u8, data: []const u8, tick: u64) Error!void {
    try init();
    const normalized = try normalizePath(path);
    if (normalized.len == 1) return error.InvalidPath;

    const full = normalized.slice();
    const parent = parentSlice(full);
    if (parent.len > 1) {
        const parent_index = findEntryIndex(parent) orelse return error.FileNotFound;
        if (entries[parent_index].kind != abi.filesystem_kind_directory) return error.NotDirectory;
    }

    const block_count_needed = blockCountForBytes(data.len);
    const existing_index = findEntryIndex(full);

    if (existing_index) |entry_index| {
        if (entries[entry_index].kind != abi.filesystem_kind_file) return error.IsDirectory;
        try updateFileEntry(entry_index, data, block_count_needed, tick);
    } else {
        const free_index = try findFreeEntryIndex();
        const start_lba = try allocateExtent(block_count_needed, null);
        try writeExtent(start_lba, block_count_needed, data);
        entries[free_index] = makeEntry(full, abi.filesystem_kind_file, start_lba, @as(u32, @intCast(block_count_needed)), @as(u32, @intCast(data.len)), checksumBytes(data), tick);
    }

    state.write_count +%= 1;
    state.last_modified_tick = tick;
    state.dirty = 1;
    recountState();
    try persistAll();
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) Error![]u8 {
    try init();
    const normalized = try normalizePath(path);
    const full = normalized.slice();
    const entry_index = findEntryIndex(full) orelse return error.FileNotFound;
    const record = entries[entry_index];
    if (record.kind != abi.filesystem_kind_file) return error.IsDirectory;
    if (record.byte_len > max_bytes) return error.FileTooBig;

    const byte_len = @as(usize, record.byte_len);
    const buffer = try allocator.alloc(u8, byte_len);
    errdefer allocator.free(buffer);
    if (byte_len == 0) return buffer;

    var scratch = [_]u8{0} ** storage_backend.block_size;
    var remaining = byte_len;
    var out_offset: usize = 0;
    var block_index: u32 = 0;
    while (remaining > 0) : (block_index += 1) {
        try storage_backend.readBlocks(record.start_lba + block_index, scratch[0..]);
        const copy_len = @min(remaining, storage_backend.block_size);
        @memcpy(buffer[out_offset .. out_offset + copy_len], scratch[0..copy_len]);
        out_offset += copy_len;
        remaining -= copy_len;
    }

    state.read_count +%= 1;
    return buffer;
}

pub const SimpleStat = struct {
    kind: std.Io.File.Kind,
    size: u64,
    modified_tick: u64,
    entry_id: u64,
};

fn dirStatInode(value: u64) @TypeOf(@as(std.Io.Dir.Stat, undefined).inode) {
    const T = @TypeOf(@as(std.Io.Dir.Stat, undefined).inode);
    if (T == void) return {};
    return @as(T, @intCast(value));
}

fn dirStatNlink(value: u64) @TypeOf(@as(std.Io.Dir.Stat, undefined).nlink) {
    const T = @TypeOf(@as(std.Io.Dir.Stat, undefined).nlink);
    if (T == void) return {};
    return @as(T, @intCast(value));
}

fn dirStatBlockSize(value: u32) @TypeOf(@as(std.Io.Dir.Stat, undefined).block_size) {
    const T = @TypeOf(@as(std.Io.Dir.Stat, undefined).block_size);
    if (T == void) return {};
    return @as(T, @intCast(value));
}

pub fn statNoFollow(path: []const u8) Error!std.Io.Dir.Stat {
    const summary = try statSummary(path);
    return .{
        .inode = dirStatInode(summary.entry_id),
        .nlink = dirStatNlink(1),
        .size = summary.size,
        .permissions = if (summary.kind == .directory) .default_dir else .default_file,
        .kind = summary.kind,
        .atime = null,
        .mtime = std.Io.Timestamp.fromNanoseconds(@as(i96, @intCast(summary.modified_tick))),
        .ctime = std.Io.Timestamp.fromNanoseconds(@as(i96, @intCast(summary.modified_tick))),
        .block_size = dirStatBlockSize(storage_backend.block_size),
    };
}

pub fn statSummary(path: []const u8) Error!SimpleStat {
    try init();
    const normalized = try normalizePath(path);
    const full = normalized.slice();
    state.stat_count +%= 1;

    if (full.len == 1) {
        return .{
            .size = 0,
            .kind = .directory,
            .modified_tick = 0,
            .entry_id = 0,
        };
    }

    const entry_index = findEntryIndex(full) orelse return error.FileNotFound;
    const record = entries[entry_index];
    return .{
        .size = record.byte_len,
        .kind = if (record.kind == abi.filesystem_kind_directory) .directory else .file,
        .modified_tick = record.modified_tick,
        .entry_id = record.entry_id,
    };
}

fn updateFileEntry(entry_index: usize, data: []const u8, block_count_needed: usize, tick: u64) Error!void {
    const record = entries[entry_index];
    if (record.block_count > 0 and (block_count_needed == 0 or block_count_needed > record.block_count)) {
        try zeroExtent(record.start_lba, record.block_count);
    }

    var start_lba: u32 = 0;
    if (block_count_needed == 0) {
        start_lba = 0;
    } else if (record.block_count >= block_count_needed and record.start_lba != 0) {
        start_lba = record.start_lba;
        try writeExtent(start_lba, block_count_needed, data);
        if (record.block_count > block_count_needed) {
            try zeroExtent(start_lba + @as(u32, @intCast(block_count_needed)), record.block_count - @as(u32, @intCast(block_count_needed)));
        }
    } else {
        start_lba = try allocateExtent(block_count_needed, entry_index);
        try writeExtent(start_lba, block_count_needed, data);
    }

    entries[entry_index] = makeEntry(record.path[0..record.path_len], abi.filesystem_kind_file, start_lba, @as(u32, @intCast(block_count_needed)), @as(u32, @intCast(data.len)), checksumBytes(data), tick);
    entries[entry_index].entry_id = record.entry_id;
}

fn format() Error!void {
    resetForTest();
    state.format_count +%= 1;
    state.formatted = 1;
    state.mounted = 1;
    state.active_backend = storage_backend.activeBackend();
    recountState();
    try persistAll();
}

fn loadExisting() Error!bool {
    var header_block = [_]u8{0} ** storage_backend.block_size;
    try storage_backend.readBlocks(superblock_lba, header_block[0..]);

    var persisted: abi.BaremetalFilesystemState = undefined;
    @memcpy(std.mem.asBytes(&persisted), header_block[0..@sizeOf(abi.BaremetalFilesystemState)]);
    if (persisted.magic != abi.filesystem_magic) return false;
    if (persisted.api_version != abi.api_version or
        persisted.max_entries != max_entries or
        persisted.superblock_lba != superblock_lba or
        persisted.entry_table_lba != entry_table_lba or
        persisted.entry_table_block_count != entry_table_block_count or
        persisted.data_lba != data_lba)
    {
        return error.CorruptFilesystem;
    }

    var entry_bytes = [_]u8{0} ** entry_table_bytes;
    var block_index: u32 = 0;
    while (block_index < entry_table_block_count) : (block_index += 1) {
        const offset = @as(usize, @intCast(block_index)) * storage_backend.block_size;
        try storage_backend.readBlocks(entry_table_lba + block_index, entry_bytes[offset .. offset + storage_backend.block_size]);
    }

    state = persisted;
    @memcpy(std.mem.sliceAsBytes(entries[0..]), entry_bytes[0..entry_table_bytes]);
    state.formatted = 1;
    state.mounted = 1;
    state.active_backend = storage_backend.activeBackend();
    state.dirty = 0;
    recountState();
    return true;
}

fn persistAll() Error!void {
    state.formatted = 1;
    state.mounted = 1;
    state.active_backend = storage_backend.activeBackend();
    state.dirty = 0;
    try persistState();
    try persistEntries();
    try storage_backend.flush();
}

fn persistState() Error!void {
    var block = [_]u8{0} ** storage_backend.block_size;
    @memcpy(block[0..@sizeOf(abi.BaremetalFilesystemState)], std.mem.asBytes(&state));
    try storage_backend.writeBlocks(superblock_lba, block[0..]);
}

fn persistEntries() Error!void {
    const bytes = std.mem.sliceAsBytes(entries[0..]);
    var block_index: u32 = 0;
    while (block_index < entry_table_block_count) : (block_index += 1) {
        const offset = @as(usize, @intCast(block_index)) * storage_backend.block_size;
        try storage_backend.writeBlocks(entry_table_lba + block_index, bytes[offset .. offset + storage_backend.block_size]);
    }
}

fn normalizePath(path: []const u8) Error!NormalizedPath {
    if (path.len == 0) return error.InvalidPath;
    var normalized: NormalizedPath = .{};
    normalized.buf[0] = '/';
    normalized.len = 1;

    var index: usize = 0;
    while (index < path.len and path[index] == '/') : (index += 1) {}
    if (index == path.len) return normalized;

    while (index < path.len) {
        const start = index;
        while (index < path.len and path[index] != '/') : (index += 1) {}
        const segment = path[start..index];
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;

        if (normalized.len != 1) {
            if (normalized.len >= max_path_len) return error.InvalidPath;
            normalized.buf[normalized.len] = '/';
            normalized.len += 1;
        }
        if (normalized.len + segment.len > max_path_len) return error.InvalidPath;
        @memcpy(normalized.buf[normalized.len .. normalized.len + segment.len], segment);
        normalized.len += segment.len;

        while (index < path.len and path[index] == '/') : (index += 1) {}
    }

    return normalized;
}

fn findEntryIndex(path: []const u8) ?usize {
    for (entries, 0..) |record, index| {
        if (record.kind == 0 or record.path_len != path.len) continue;
        if (std.mem.eql(u8, record.path[0..record.path_len], path)) return index;
    }
    return null;
}

fn findFreeEntryIndex() Error!usize {
    for (entries, 0..) |record, index| {
        if (record.kind == 0) return index;
    }
    return error.NoSpace;
}

fn makeEntry(path: []const u8, kind: u8, start_lba: u32, block_count_value: u32, byte_len: u32, checksum: u32, tick: u64) abi.BaremetalFilesystemEntry {
    var record = std.mem.zeroes(abi.BaremetalFilesystemEntry);
    state.last_entry_id +%= 1;
    record.entry_id = state.last_entry_id;
    record.path_len = @as(u16, @intCast(path.len));
    record.kind = kind;
    record.flags = 0;
    record.start_lba = start_lba;
    record.block_count = block_count_value;
    record.byte_len = byte_len;
    record.checksum = checksum;
    record.modified_tick = tick;
    @memcpy(record.path[0..path.len], path);
    return record;
}

fn recountState() void {
    var used_entries: u16 = 0;
    var dir_entries: u16 = 0;
    var file_entries: u16 = 0;
    var last_lba = data_lba;

    for (entries) |record| {
        if (record.kind == 0) continue;
        used_entries += 1;
        if (record.kind == abi.filesystem_kind_directory) {
            dir_entries += 1;
            continue;
        }
        file_entries += 1;
        if (record.block_count > 0) {
            const record_last = record.start_lba + record.block_count - 1;
            if (record_last > last_lba) last_lba = record_last;
        }
    }

    state.used_entries = used_entries;
    state.dir_entries = dir_entries;
    state.file_entries = file_entries;
    state.last_data_lba = last_lba;
}

fn blockCountForBytes(byte_len: usize) usize {
    if (byte_len == 0) return 0;
    return ((byte_len - 1) / storage_backend.block_size) + 1;
}

fn allocateExtent(blocks_needed: usize, skip_index: ?usize) Error!u32 {
    if (blocks_needed == 0) return 0;
    const total_blocks = @as(u32, @intCast(storage_backend.block_count));
    const needed_u32 = @as(u32, @intCast(blocks_needed));
    if (total_blocks <= data_lba or total_blocks - data_lba < needed_u32) return error.NoSpace;

    var candidate = data_lba;
    const final_start = total_blocks - needed_u32;
    while (candidate <= final_start) : (candidate += 1) {
        var overlaps = false;
        for (entries, 0..) |record, index| {
            if (skip_index != null and index == skip_index.?) continue;
            if (record.kind != abi.filesystem_kind_file or record.block_count == 0) continue;
            const other_start = record.start_lba;
            const other_end = record.start_lba + record.block_count;
            const candidate_end = candidate + needed_u32;
            if (candidate < other_end and candidate_end > other_start) {
                overlaps = true;
                break;
            }
        }
        if (!overlaps) return candidate;
    }
    return error.NoSpace;
}

fn writeExtent(start_lba: u32, block_count_value: usize, data: []const u8) Error!void {
    if (block_count_value == 0) return;
    var scratch = [_]u8{0} ** storage_backend.block_size;
    var remaining = data.len;
    var input_offset: usize = 0;
    var block_index: usize = 0;
    while (block_index < block_count_value) : (block_index += 1) {
        @memset(scratch[0..], 0);
        const copy_len = @min(remaining, storage_backend.block_size);
        if (copy_len > 0) {
            @memcpy(scratch[0..copy_len], data[input_offset .. input_offset + copy_len]);
            remaining -= copy_len;
            input_offset += copy_len;
        }
        try storage_backend.writeBlocks(start_lba + @as(u32, @intCast(block_index)), scratch[0..]);
    }
}

fn zeroExtent(start_lba: u32, block_count_value: u32) Error!void {
    if (block_count_value == 0) return;
    var zero_block = [_]u8{0} ** storage_backend.block_size;
    var block_index: u32 = 0;
    while (block_index < block_count_value) : (block_index += 1) {
        try storage_backend.writeBlocks(start_lba + block_index, zero_block[0..]);
    }
}

fn checksumBytes(bytes: []const u8) u32 {
    var total: u32 = 0;
    for (bytes) |byte| total +%= byte;
    return total;
}

fn parentSlice(path: []const u8) []const u8 {
    if (path.len <= 1) return "/";
    if (std.mem.lastIndexOfScalar(u8, path[1..], '/')) |relative_index| {
        return path[0 .. relative_index + 1];
    }
    return "/";
}

test "filesystem persists path-based files on the ram disk" {
    storage_backend.resetForTest();
    resetForTest();
    try init();

    try createDirPath("/runtime/state");
    try writeFile("/runtime/state/agent.json", "{\"ok\":true}", 77);
    const stat = try statNoFollow("/runtime/state/agent.json");
    try std.testing.expectEqual(@as(std.Io.File.Kind, .file), stat.kind);
    try std.testing.expectEqual(@as(u64, 11), stat.size);
    try std.testing.expectEqual(@as(u16, 2), state.dir_entries);
    try std.testing.expectEqual(@as(u16, 1), state.file_entries);

    const content = try readFileAlloc(std.testing.allocator, "/runtime/state/agent.json", 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("{\"ok\":true}", content);

    resetForTest();
    try init();
    const reloaded = try readFileAlloc(std.testing.allocator, "/runtime/state/agent.json", 64);
    defer std.testing.allocator.free(reloaded);
    try std.testing.expectEqualStrings("{\"ok\":true}", reloaded);
}

test "filesystem persists path-based files on the ata backend" {
    storage_backend.resetForTest();
    resetForTest();
    @import("ata_pio_disk.zig").testEnableMockDevice(8192);
    @import("ata_pio_disk.zig").testInstallMockMbrPartition(2048, 4096, 0x83);
    defer @import("ata_pio_disk.zig").testDisableMockDevice();

    try init();
    try createDirPath("/tools/cache");
    try writeFile("/tools/cache/tool.txt", "edge", 99);
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ata_pio), state.active_backend);
    try std.testing.expectEqual(@as(u32, 2048), @import("ata_pio_disk.zig").logicalBaseLba());

    const content = try readFileAlloc(std.testing.allocator, "/tools/cache/tool.txt", 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("edge", content);

    resetForTest();
    try init();
    const stat = try statNoFollow("/tools/cache/tool.txt");
    try std.testing.expectEqual(@as(std.Io.File.Kind, .file), stat.kind);
    try std.testing.expectEqual(@as(u64, 4), stat.size);
}
