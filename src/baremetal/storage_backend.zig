const std = @import("std");
const abi = @import("abi.zig");
const ata_pio_disk = @import("ata_pio_disk.zig");
const ram_disk = @import("ram_disk.zig");

pub const block_size: usize = ram_disk.block_size;
pub const block_count: usize = ram_disk.block_count;
pub const capacity_bytes: usize = block_size * block_count;

pub const Error = ram_disk.Error || ata_pio_disk.Error;

const Backend = enum {
    ram_disk,
    ata_pio,
};

var active_backend: Backend = .ram_disk;

pub fn resetForTest() void {
    ram_disk.resetForTest();
    ata_pio_disk.resetForTest();
    active_backend = .ram_disk;
}

pub fn init() void {
    ata_pio_disk.init();
    if (ata_pio_disk.statePtr().mounted != 0) {
        active_backend = .ata_pio;
        return;
    }
    ram_disk.init();
    active_backend = .ram_disk;
}

pub fn statePtr() *const abi.BaremetalStorageState {
    return switch (active_backend) {
        .ram_disk => ram_disk.statePtr(),
        .ata_pio => ata_pio_disk.statePtr(),
    };
}

pub fn activeBackend() u8 {
    return statePtr().backend;
}

pub fn readBlocks(lba: u32, out: []u8) Error!void {
    switch (active_backend) {
        .ram_disk => try ram_disk.readBlocks(lba, out),
        .ata_pio => try ata_pio_disk.readBlocks(lba, out),
    }
}

pub fn writeBlocks(lba: u32, input: []const u8) Error!void {
    switch (active_backend) {
        .ram_disk => try ram_disk.writeBlocks(lba, input),
        .ata_pio => try ata_pio_disk.writeBlocks(lba, input),
    }
}

pub fn flush() Error!void {
    switch (active_backend) {
        .ram_disk => try ram_disk.flush(),
        .ata_pio => try ata_pio_disk.flush(),
    }
}

pub fn readByte(lba: u32, offset: u32) u8 {
    return switch (active_backend) {
        .ram_disk => ram_disk.readByte(lba, offset),
        .ata_pio => ata_pio_disk.readByte(lba, offset),
    };
}

test "storage backend facade exposes ram-disk baseline semantics" {
    resetForTest();
    init();

    const storage = statePtr();
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ram_disk), activeBackend());
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ram_disk), storage.backend);
    try std.testing.expectEqual(@as(u32, block_size), storage.block_size);
    try std.testing.expectEqual(@as(u32, block_count), storage.block_count);

    var payload = [_]u8{0} ** block_size;
    for (&payload, 0..) |*byte, idx| {
        byte.* = @as(u8, @truncate(idx));
    }
    try writeBlocks(3, payload[0..]);
    try std.testing.expectEqual(@as(u8, 1), storage.dirty);
    try std.testing.expectEqual(@as(u8, 0), readByte(3, 0));
    try std.testing.expectEqual(@as(u8, 1), readByte(3, 1));

    var out = [_]u8{0} ** block_size;
    try readBlocks(3, out[0..]);
    try std.testing.expectEqualSlices(u8, payload[0..], out[0..]);
    try flush();
    try std.testing.expectEqual(@as(u8, 0), storage.dirty);
}

test "storage backend facade prefers ata pio backend when a device is available" {
    resetForTest();
    ata_pio_disk.testEnableMockDevice(8192);
    ata_pio_disk.testInstallMockMbrPartition(2048, 4096, 0x83);
    defer ata_pio_disk.testDisableMockDevice();

    init();

    const storage = statePtr();
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ata_pio), activeBackend());
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ata_pio), storage.backend);
    try std.testing.expectEqual(@as(u8, 1), storage.mounted);
    try std.testing.expectEqual(@as(u32, 4096), storage.block_count);
    try std.testing.expectEqual(@as(u32, 2048), ata_pio_disk.logicalBaseLba());

    var payload = [_]u8{0} ** block_size;
    for (&payload, 0..) |*byte, idx| {
        byte.* = @as(u8, @truncate(0x20 + idx));
    }
    try writeBlocks(9, payload[0..]);
    try std.testing.expectEqual(@as(u8, 0x20), readByte(9, 0));
    try std.testing.expectEqual(@as(u8, 0x21), readByte(9, 1));
    try std.testing.expectEqual(@as(u8, 0), ata_pio_disk.testReadMockByteRaw(9, 0));
    try std.testing.expectEqual(@as(u8, 0x20), ata_pio_disk.testReadMockByteRaw(2048 + 9, 0));
    try std.testing.expectEqual(@as(u8, 0x21), ata_pio_disk.testReadMockByteRaw(2048 + 9, 1));
}
