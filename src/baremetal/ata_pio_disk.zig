const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");

pub const block_size: usize = 512;

pub const Error = error{
    NotMounted,
    OutOfRange,
    UnalignedLength,
    NoDevice,
    BusyTimeout,
    DeviceFault,
    ProtocolError,
};

const io_base_primary: u16 = 0x1F0;
const io_data: u16 = io_base_primary + 0;
const io_error_features: u16 = io_base_primary + 1;
const io_sector_count: u16 = io_base_primary + 2;
const io_lba_low: u16 = io_base_primary + 3;
const io_lba_mid: u16 = io_base_primary + 4;
const io_lba_high: u16 = io_base_primary + 5;
const io_drive_head: u16 = io_base_primary + 6;
const io_status_command: u16 = io_base_primary + 7;
const io_alt_status_device_control: u16 = 0x3F6;

const command_identify: u8 = 0xEC;
const command_read_sectors: u8 = 0x20;
const command_write_sectors: u8 = 0x30;
const command_cache_flush: u8 = 0xE7;

const status_err: u8 = 1 << 0;
const status_drq: u8 = 1 << 3;
const status_df: u8 = 1 << 5;
const status_drdy: u8 = 1 << 6;
const status_bsy: u8 = 1 << 7;

const drive_master_lba: u8 = 0xE0;
const poll_limit: usize = 100_000;
const mock_block_capacity: usize = 16384;
const mbr_partition_table_offset: usize = 446;
const mbr_partition_entry_len: usize = 16;
const mbr_partition_count: usize = 4;
const mbr_signature_offset: usize = 510;
const mbr_signature_low: u8 = 0x55;
const mbr_signature_high: u8 = 0xAA;
const mbr_partition_type_protective_gpt: u8 = 0xEE;
const gpt_header_lba: u32 = 1;
const gpt_signature = [_]u8{ 'E', 'F', 'I', ' ', 'P', 'A', 'R', 'T' };
const gpt_header_min_size: u32 = 92;
const gpt_partition_entry_min_size: u32 = 128;

var state: abi.BaremetalStorageState = undefined;
var probe_completed: bool = false;
var probe_saw_device: bool = false;
var raw_block_count: u32 = 0;
var mounted_lba_base: u32 = 0;

const MockDevice = struct {
    enabled: bool = false,
    sector_count: u32 = 0,
    data: [mock_block_capacity * block_size]u8 = [_]u8{0} ** (mock_block_capacity * block_size),
};

var mock_device = MockDevice{};

pub fn resetForTest() void {
    resetState();
    probe_completed = false;
    probe_saw_device = false;
    if (builtin.is_test) {
        mock_device.enabled = false;
        mock_device.sector_count = 0;
        @memset(&mock_device.data, 0);
    }
}

pub fn init() void {
    if (state.magic == abi.storage_magic and state.backend == abi.storage_backend_ata_pio and state.mounted != 0) return;
    if (probe_completed and !probe_saw_device) return;

    resetState();
    if (mockAvailable()) {
        mountMock();
        probe_completed = true;
        probe_saw_device = true;
        return;
    }
    if (!hardwareBacked()) {
        probe_completed = true;
        probe_saw_device = false;
        return;
    }

    probe_saw_device = detectHardwareDevice();
    probe_completed = true;
}

pub fn statePtr() *const abi.BaremetalStorageState {
    return &state;
}

pub fn logicalBaseLba() u32 {
    return mounted_lba_base;
}

pub fn readBlocks(lba: u32, out: []u8) Error!void {
    if (state.mounted == 0) return error.NotMounted;
    if (out.len % block_size != 0) return error.UnalignedLength;
    const blocks: usize = out.len / block_size;
    if (@as(u64, lba) + blocks > state.block_count) return error.OutOfRange;

    const physical_lba = translateLba(lba);
    if (mockAvailable() and state.mounted != 0) {
        const start = @as(usize, physical_lba) * block_size;
        const end = start + out.len;
        @memcpy(out, mock_device.data[start..end]);
    } else {
        var block_index: usize = 0;
        while (block_index < blocks) : (block_index += 1) {
            try readSectorHardware(physical_lba + @as(u32, @intCast(block_index)), out[block_index * block_size ..][0..block_size]);
        }
    }

    state.read_ops +%= 1;
    state.last_lba = lba;
    state.last_block_count = @as(u32, @intCast(blocks));
    state.bytes_read +%= @as(u64, @intCast(out.len));
}

pub fn writeBlocks(lba: u32, input: []const u8) Error!void {
    if (state.mounted == 0) return error.NotMounted;
    if (input.len % block_size != 0) return error.UnalignedLength;
    const blocks: usize = input.len / block_size;
    if (@as(u64, lba) + blocks > state.block_count) return error.OutOfRange;

    const physical_lba = translateLba(lba);
    if (mockAvailable() and state.mounted != 0) {
        const start = @as(usize, physical_lba) * block_size;
        const end = start + input.len;
        @memcpy(mock_device.data[start..end], input);
    } else {
        var block_index: usize = 0;
        while (block_index < blocks) : (block_index += 1) {
            try writeSectorHardware(physical_lba + @as(u32, @intCast(block_index)), input[block_index * block_size ..][0..block_size]);
        }
    }

    state.write_ops +%= 1;
    state.last_lba = lba;
    state.last_block_count = @as(u32, @intCast(blocks));
    state.bytes_written +%= @as(u64, @intCast(input.len));
    state.dirty = 1;
}

pub fn flush() Error!void {
    if (state.mounted == 0) return error.NotMounted;
    if (!(mockAvailable() and state.mounted != 0)) {
        try flushHardware();
    }
    state.flush_ops +%= 1;
    state.dirty = 0;
}

pub fn readByte(lba: u32, offset: u32) u8 {
    if (state.mounted == 0) return 0;
    if (lba >= state.block_count or offset >= state.block_size) return 0;
    const physical_lba = translateLba(lba);
    if (mockAvailable() and state.mounted != 0) {
        const index = (@as(usize, physical_lba) * block_size) + @as(usize, offset);
        return mock_device.data[index];
    }

    var scratch = [_]u8{0} ** block_size;
    readSectorHardware(physical_lba, scratch[0..]) catch return 0;
    return scratch[offset];
}

pub fn testEnableMockDevice(sector_count: u32) void {
    if (!builtin.is_test) return;
    std.debug.assert(sector_count > 0 and sector_count <= mock_block_capacity);
    resetForTest();
    mock_device.enabled = true;
    mock_device.sector_count = sector_count;
}

pub fn testDisableMockDevice() void {
    if (!builtin.is_test) return;
    resetForTest();
}

pub fn testInstallMockMbrPartition(start_lba: u32, sector_count: u32, partition_type: u8) void {
    if (!builtin.is_test or !mock_device.enabled) return;
    std.debug.assert(start_lba > 0);
    std.debug.assert(sector_count > 0);
    std.debug.assert(@as(u64, start_lba) + sector_count <= mock_device.sector_count);

    @memset(mock_device.data[0..block_size], 0);
    const entry = mock_device.data[mbr_partition_table_offset .. mbr_partition_table_offset + mbr_partition_entry_len];
    entry[4] = partition_type;
    writeLeU32(entry[8..12], start_lba);
    writeLeU32(entry[12..16], sector_count);
    mock_device.data[mbr_signature_offset] = mbr_signature_low;
    mock_device.data[mbr_signature_offset + 1] = mbr_signature_high;
}

pub fn testInstallMockProtectiveGptPartition(start_lba: u32, sector_count: u32) void {
    if (!builtin.is_test or !mock_device.enabled) return;
    std.debug.assert(start_lba >= 34);
    std.debug.assert(sector_count > 0);
    std.debug.assert(@as(u64, start_lba) + sector_count <= mock_device.sector_count);

    @memset(mock_device.data[0 .. 3 * block_size], 0);

    const protective_sector_count = mock_device.sector_count - 1;
    const entry = mock_device.data[mbr_partition_table_offset .. mbr_partition_table_offset + mbr_partition_entry_len];
    entry[4] = mbr_partition_type_protective_gpt;
    writeLeU32(entry[8..12], 1);
    writeLeU32(entry[12..16], protective_sector_count);
    mock_device.data[mbr_signature_offset] = mbr_signature_low;
    mock_device.data[mbr_signature_offset + 1] = mbr_signature_high;

    const header = mock_device.data[block_size .. 2 * block_size];
    @memcpy(header[0..gpt_signature.len], gpt_signature[0..]);
    writeLeU32(header[8..12], 0x0001_0000);
    writeLeU32(header[12..16], gpt_header_min_size);
    writeLeU64(header[24..32], gpt_header_lba);
    writeLeU64(header[32..40], @as(u64, mock_device.sector_count - 1));
    writeLeU64(header[40..48], 34);
    writeLeU64(header[48..56], @as(u64, mock_device.sector_count - 34));
    writeLeU64(header[72..80], 2);
    writeLeU32(header[80..84], 4);
    writeLeU32(header[84..88], gpt_partition_entry_min_size);

    const partition_entry = mock_device.data[2 * block_size .. 2 * block_size + gpt_partition_entry_min_size];
    const type_guid = [_]u8{ 0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 };
    const unique_guid = [_]u8{ 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0xFE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    @memcpy(partition_entry[0..16], type_guid[0..]);
    @memcpy(partition_entry[16..32], unique_guid[0..]);
    writeLeU64(partition_entry[32..40], start_lba);
    writeLeU64(partition_entry[40..48], @as(u64, start_lba) + sector_count - 1);
}

pub fn testReadMockByteRaw(lba: u32, offset: u32) u8 {
    if (!builtin.is_test or !mock_device.enabled) return 0;
    if (lba >= mock_device.sector_count or offset >= block_size) return 0;
    const index = (@as(usize, lba) * block_size) + @as(usize, offset);
    return mock_device.data[index];
}

fn resetState() void {
    state = .{
        .magic = abi.storage_magic,
        .api_version = abi.api_version,
        .backend = abi.storage_backend_ata_pio,
        .mounted = 0,
        .block_size = @as(u32, block_size),
        .block_count = 0,
        .read_ops = 0,
        .write_ops = 0,
        .flush_ops = 0,
        .last_lba = 0,
        .last_block_count = 0,
        .dirty = 0,
        .reserved0 = .{ 0, 0, 0 },
        .bytes_read = 0,
        .bytes_written = 0,
    };
    raw_block_count = 0;
    mounted_lba_base = 0;
}

fn hardwareBacked() bool {
    return builtin.os.tag == .freestanding and builtin.cpu.arch == .x86_64;
}

fn mockAvailable() bool {
    return builtin.is_test and mock_device.enabled and mock_device.sector_count != 0;
}

fn mountMock() void {
    var sector0 = [_]u8{0} ** block_size;
    @memcpy(sector0[0..], mock_device.data[0..block_size]);
    mountPartitionedView(sector0[0..], mock_device.sector_count);
}

fn detectHardwareDevice() bool {
    selectDrive(0);
    writePort8(io_sector_count, 0);
    writePort8(io_lba_low, 0);
    writePort8(io_lba_mid, 0);
    writePort8(io_lba_high, 0);
    writePort8(io_status_command, command_identify);

    const initial_status = readPort8(io_status_command);
    if (initial_status == 0) return false;
    if (!waitWhileBusy()) return false;

    const signature_mid = readPort8(io_lba_mid);
    const signature_high = readPort8(io_lba_high);
    if (signature_mid != 0 or signature_high != 0) return false;

    const status_value = waitForDrqOrError() catch return false;
    if ((status_value & (status_err | status_df)) != 0) return false;

    var identify_words = [_]u16{0} ** 256;
    for (&identify_words) |*word| {
        word.* = readPort16(io_data);
    }
    mountFromIdentifyWords(identify_words[0..]) catch return false;
    return state.mounted != 0;
}

fn mountFromIdentifyWords(words: []const u16) Error!void {
    if (words.len < 256) return error.ProtocolError;
    const sector_count = (@as(u32, words[61]) << 16) | @as(u32, words[60]);
    if (sector_count == 0) return error.ProtocolError;

    var sector0 = [_]u8{0} ** block_size;
    if (readSectorHardware(0, sector0[0..])) |_| {
        mountPartitionedView(sector0[0..], sector_count);
    } else |_| {
        mountWholeDisk(sector_count);
    }
}

fn translateLba(logical_lba: u32) u32 {
    return mounted_lba_base + logical_lba;
}

fn mountWholeDisk(block_count_value: u32) void {
    raw_block_count = block_count_value;
    mounted_lba_base = 0;
    state.block_count = block_count_value;
    state.mounted = 1;
}

fn mountPartitionedView(sector0: []const u8, block_count_value: u32) void {
    raw_block_count = block_count_value;
    if (mountFirstMbrPartition(sector0, block_count_value)) return;
    if (hasProtectiveMbrPartition(sector0) and mountFirstGptPartition(block_count_value)) return;
    mountWholeDisk(block_count_value);
}

fn mountFirstMbrPartition(sector0: []const u8, block_count_value: u32) bool {
    if (sector0.len < block_size) return false;
    if (sector0[mbr_signature_offset] != mbr_signature_low or sector0[mbr_signature_offset + 1] != mbr_signature_high) {
        return false;
    }

    var entry_index: usize = 0;
    while (entry_index < mbr_partition_count) : (entry_index += 1) {
        const offset = mbr_partition_table_offset + (entry_index * mbr_partition_entry_len);
        const entry = sector0[offset .. offset + mbr_partition_entry_len];
        const partition_type = entry[4];
        const start_lba = readLeU32(entry[8..12]);
        const sector_count = readLeU32(entry[12..16]);
        if (partition_type == 0 or partition_type == mbr_partition_type_protective_gpt) continue;
        if (start_lba == 0 or sector_count == 0) continue;
        if (@as(u64, start_lba) + sector_count > block_count_value) continue;

        mounted_lba_base = start_lba;
        state.block_count = sector_count;
        state.mounted = 1;
        return true;
    }
    return false;
}

fn hasProtectiveMbrPartition(sector0: []const u8) bool {
    if (sector0.len < block_size) return false;
    if (sector0[mbr_signature_offset] != mbr_signature_low or sector0[mbr_signature_offset + 1] != mbr_signature_high) return false;

    var entry_index: usize = 0;
    while (entry_index < mbr_partition_count) : (entry_index += 1) {
        const offset = mbr_partition_table_offset + (entry_index * mbr_partition_entry_len);
        if (sector0[offset + 4] == mbr_partition_type_protective_gpt) return true;
    }
    return false;
}

fn mountFirstGptPartition(block_count_value: u32) bool {
    var header_block = [_]u8{0} ** block_size;
    readPhysicalSector(gpt_header_lba, header_block[0..]) catch return false;
    if (!std.mem.eql(u8, header_block[0..gpt_signature.len], gpt_signature[0..])) return false;

    const header_size = readLeU32(header_block[12..16]);
    if (header_size < gpt_header_min_size or header_size > block_size) return false;
    if (readLeU64(header_block[24..32]) != gpt_header_lba) return false;

    const first_usable_lba = readLeU64(header_block[40..48]);
    const last_usable_lba = readLeU64(header_block[48..56]);
    const partition_entry_lba = readLeU64(header_block[72..80]);
    const partition_entry_count = readLeU32(header_block[80..84]);
    const partition_entry_size = readLeU32(header_block[84..88]);
    if (partition_entry_count == 0 or partition_entry_size < gpt_partition_entry_min_size or partition_entry_size > block_size) return false;
    if (partition_entry_lba == 0 or partition_entry_lba >= block_count_value) return false;

    var entry_block = [_]u8{0} ** block_size;
    var loaded_lba: u64 = std.math.maxInt(u64);
    var entry_index: u32 = 0;
    while (entry_index < partition_entry_count) : (entry_index += 1) {
        const byte_offset = @as(u64, entry_index) * partition_entry_size;
        const entry_lba = partition_entry_lba + (byte_offset / block_size);
        const offset_in_block = @as(usize, @intCast(byte_offset % block_size));
        if (offset_in_block + partition_entry_size > block_size) return false;
        if (entry_lba >= block_count_value) return false;

        if (entry_lba != loaded_lba) {
            readPhysicalSector(@as(u32, @intCast(entry_lba)), entry_block[0..]) catch return false;
            loaded_lba = entry_lba;
        }

        const entry = entry_block[offset_in_block .. offset_in_block + partition_entry_size];
        if (std.mem.allEqual(u8, entry[0..16], 0)) continue;

        const start_lba = readLeU64(entry[32..40]);
        const end_lba = readLeU64(entry[40..48]);
        if (start_lba == 0 or end_lba < start_lba) continue;
        if (start_lba < first_usable_lba or end_lba > last_usable_lba or end_lba >= block_count_value) continue;

        const sector_count = (end_lba - start_lba) + 1;
        if (start_lba > std.math.maxInt(u32) or sector_count > std.math.maxInt(u32)) continue;

        mounted_lba_base = @as(u32, @intCast(start_lba));
        state.block_count = @as(u32, @intCast(sector_count));
        state.mounted = 1;
        return true;
    }

    return false;
}

fn readLeU32(bytes: []const u8) u32 {
    std.debug.assert(bytes.len >= 4);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readLeU64(bytes: []const u8) u64 {
    std.debug.assert(bytes.len >= 8);
    return @as(u64, bytes[0]) |
        (@as(u64, bytes[1]) << 8) |
        (@as(u64, bytes[2]) << 16) |
        (@as(u64, bytes[3]) << 24) |
        (@as(u64, bytes[4]) << 32) |
        (@as(u64, bytes[5]) << 40) |
        (@as(u64, bytes[6]) << 48) |
        (@as(u64, bytes[7]) << 56);
}

fn writeLeU32(bytes: []u8, value: u32) void {
    std.debug.assert(bytes.len >= 4);
    bytes[0] = @as(u8, @truncate(value));
    bytes[1] = @as(u8, @truncate(value >> 8));
    bytes[2] = @as(u8, @truncate(value >> 16));
    bytes[3] = @as(u8, @truncate(value >> 24));
}

fn writeLeU64(bytes: []u8, value: u64) void {
    std.debug.assert(bytes.len >= 8);
    bytes[0] = @as(u8, @truncate(value));
    bytes[1] = @as(u8, @truncate(value >> 8));
    bytes[2] = @as(u8, @truncate(value >> 16));
    bytes[3] = @as(u8, @truncate(value >> 24));
    bytes[4] = @as(u8, @truncate(value >> 32));
    bytes[5] = @as(u8, @truncate(value >> 40));
    bytes[6] = @as(u8, @truncate(value >> 48));
    bytes[7] = @as(u8, @truncate(value >> 56));
}

fn readPhysicalSector(lba: u32, out: []u8) Error!void {
    if (out.len != block_size) return error.UnalignedLength;
    if (mockAvailable()) {
        if (lba >= mock_device.sector_count) return error.OutOfRange;
        const start = @as(usize, lba) * block_size;
        const end = start + block_size;
        @memcpy(out, mock_device.data[start..end]);
        return;
    }
    try readSectorHardware(lba, out);
}

fn readSectorHardware(lba: u32, out: []u8) Error!void {
    if (out.len != block_size) return error.UnalignedLength;
    selectDrive(lba);
    writePort8(io_sector_count, 1);
    writePort8(io_lba_low, @as(u8, @intCast(lba & 0xFF)));
    writePort8(io_lba_mid, @as(u8, @intCast((lba >> 8) & 0xFF)));
    writePort8(io_lba_high, @as(u8, @intCast((lba >> 16) & 0xFF)));
    writePort8(io_status_command, command_read_sectors);
    const status_value = try waitForDrqOrError();
    if ((status_value & (status_err | status_df)) != 0) return error.DeviceFault;
    var index: usize = 0;
    while (index < block_size) : (index += 2) {
        const word = readPort16(io_data);
        out[index] = @as(u8, @intCast(word & 0xFF));
        out[index + 1] = @as(u8, @intCast((word >> 8) & 0xFF));
    }
    try waitForReady();
}

fn writeSectorHardware(lba: u32, input: []const u8) Error!void {
    if (input.len != block_size) return error.UnalignedLength;
    selectDrive(lba);
    writePort8(io_sector_count, 1);
    writePort8(io_lba_low, @as(u8, @intCast(lba & 0xFF)));
    writePort8(io_lba_mid, @as(u8, @intCast((lba >> 8) & 0xFF)));
    writePort8(io_lba_high, @as(u8, @intCast((lba >> 16) & 0xFF)));
    writePort8(io_status_command, command_write_sectors);
    const status_value = try waitForDrqOrError();
    if ((status_value & (status_err | status_df)) != 0) return error.DeviceFault;
    var index: usize = 0;
    while (index < block_size) : (index += 2) {
        const word = @as(u16, input[index]) | (@as(u16, input[index + 1]) << 8);
        writePort16(io_data, word);
    }
    try waitForReady();
}

fn flushHardware() Error!void {
    selectDrive(0);
    writePort8(io_status_command, command_cache_flush);
    try waitForReady();
}

fn selectDrive(lba: u32) void {
    writePort8(io_drive_head, drive_master_lba | @as(u8, @intCast((lba >> 24) & 0x0F)));
}

fn waitWhileBusy() bool {
    var attempt: usize = 0;
    while (attempt < poll_limit) : (attempt += 1) {
        const status_value = readPort8(io_status_command);
        if ((status_value & status_bsy) == 0) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

fn waitForReady() Error!void {
    var attempt: usize = 0;
    while (attempt < poll_limit) : (attempt += 1) {
        const status_value = readPort8(io_status_command);
        if ((status_value & status_bsy) != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        if ((status_value & (status_err | status_df)) != 0) return error.DeviceFault;
        if ((status_value & status_drdy) != 0 or status_value == 0) return;
        std.atomic.spinLoopHint();
    }
    return error.BusyTimeout;
}

fn waitForDrqOrError() Error!u8 {
    var attempt: usize = 0;
    while (attempt < poll_limit) : (attempt += 1) {
        const status_value = readPort8(io_status_command);
        if ((status_value & status_bsy) != 0) {
            std.atomic.spinLoopHint();
            continue;
        }
        if ((status_value & (status_err | status_df)) != 0) return status_value;
        if ((status_value & status_drq) != 0) return status_value;
        std.atomic.spinLoopHint();
    }
    return error.BusyTimeout;
}

fn readPort8(port: u16) u8 {
    if (!hardwareBacked()) return 0;
    return asm volatile ("inb %[dx], %[al]"
        : [al] "={al}" (-> u8),
        : [dx] "{dx}" (port),
        : "memory");
}

fn writePort8(port: u16, value: u8) void {
    if (!hardwareBacked()) return;
    asm volatile ("outb %[al], %[dx]"
        :
        : [dx] "{dx}" (port),
          [al] "{al}" (value),
        : "memory");
}

fn readPort16(port: u16) u16 {
    if (!hardwareBacked()) return 0;
    return asm volatile ("inw %[dx], %[ax]"
        : [ax] "={ax}" (-> u16),
        : [dx] "{dx}" (port),
        : "memory");
}

fn writePort16(port: u16, value: u16) void {
    if (!hardwareBacked()) return;
    asm volatile ("outw %[ax], %[dx]"
        :
        : [dx] "{dx}" (port),
          [ax] "{ax}" (value),
        : "memory");
}

test "ata pio mock device mounts and exposes identify-backed capacity" {
    testEnableMockDevice(4096);
    defer testDisableMockDevice();

    init();

    const storage = statePtr();
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ata_pio), storage.backend);
    try std.testing.expectEqual(@as(u8, 1), storage.mounted);
    try std.testing.expectEqual(@as(u32, 4096), storage.block_count);
    try std.testing.expectEqual(@as(u32, block_size), storage.block_size);
}

test "ata pio mock device read write and flush update storage state" {
    testEnableMockDevice(4096);
    defer testDisableMockDevice();

    init();

    var payload = [_]u8{0} ** block_size;
    for (&payload, 0..) |*byte, idx| {
        byte.* = @as(u8, @truncate(0x40 + idx));
    }
    try writeBlocks(7, payload[0..]);

    const storage = statePtr();
    try std.testing.expectEqual(@as(u32, 1), storage.write_ops);
    try std.testing.expectEqual(@as(u8, 1), storage.dirty);
    try std.testing.expectEqual(@as(u8, payload[0]), readByte(7, 0));
    try std.testing.expectEqual(@as(u8, payload[1]), readByte(7, 1));

    var out = [_]u8{0} ** block_size;
    try readBlocks(7, out[0..]);
    try std.testing.expectEqualSlices(u8, payload[0..], out[0..]);
    try std.testing.expectEqual(@as(u32, 1), storage.read_ops);

    try flush();
    try std.testing.expectEqual(@as(u32, 1), storage.flush_ops);
    try std.testing.expectEqual(@as(u8, 0), storage.dirty);
}

test "ata pio mock device mounts first MBR partition as logical disk" {
    testEnableMockDevice(8192);
    defer testDisableMockDevice();
    testInstallMockMbrPartition(2048, 4096, 0x83);

    init();

    const storage = statePtr();
    try std.testing.expectEqual(@as(u8, 1), storage.mounted);
    try std.testing.expectEqual(@as(u32, 4096), storage.block_count);
    try std.testing.expectEqual(@as(u32, 2048), logicalBaseLba());

    var payload = [_]u8{0} ** block_size;
    for (&payload, 0..) |*byte, idx| {
        byte.* = @as(u8, @truncate(0x60 + idx));
    }
    try writeBlocks(6, payload[0..]);
    try std.testing.expectEqual(@as(u8, payload[0]), readByte(6, 0));
    try std.testing.expectEqual(@as(u8, payload[1]), readByte(6, 1));
    try std.testing.expectEqual(@as(u8, 0), testReadMockByteRaw(6, 0));
    try std.testing.expectEqual(@as(u8, payload[0]), testReadMockByteRaw(2054, 0));
    try std.testing.expectEqual(@as(u8, payload[1]), testReadMockByteRaw(2054, 1));
}

test "ata pio mock device mounts first GPT partition as logical disk" {
    testEnableMockDevice(16384);
    defer testDisableMockDevice();
    testInstallMockProtectiveGptPartition(2048, 8192);

    init();

    const storage = statePtr();
    try std.testing.expectEqual(@as(u8, 1), storage.mounted);
    try std.testing.expectEqual(@as(u32, 8192), storage.block_count);
    try std.testing.expectEqual(@as(u32, 2048), logicalBaseLba());

    var payload = [_]u8{0} ** block_size;
    for (&payload, 0..) |*byte, idx| {
        byte.* = @as(u8, @truncate(0x70 + idx));
    }
    try writeBlocks(8, payload[0..]);
    try std.testing.expectEqual(@as(u8, payload[0]), readByte(8, 0));
    try std.testing.expectEqual(@as(u8, payload[1]), readByte(8, 1));
    try std.testing.expectEqual(@as(u8, 0), testReadMockByteRaw(8, 0));
    try std.testing.expectEqual(@as(u8, payload[0]), testReadMockByteRaw(2056, 0));
    try std.testing.expectEqual(@as(u8, payload[1]), testReadMockByteRaw(2056, 1));
}
