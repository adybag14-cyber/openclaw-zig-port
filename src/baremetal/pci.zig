const std = @import("std");
const builtin = @import("builtin");

const config_address_port: u16 = 0xCF8;
const config_data_port: u16 = 0xCFC;
const max_bus_count: usize = 256;
const max_device_count: usize = 32;
const max_function_count: usize = 8;

pub const DeviceLocation = struct {
    bus: u8,
    device: u8,
    function: u8,
};

const MockEntry = struct {
    bus: u8,
    device: u8,
    function: u8,
    regs: [16]u32 = [_]u32{0xFFFF_FFFF} ** 16,
};

const mock_entry_capacity: usize = 16;
var mock_entries: [mock_entry_capacity]MockEntry = undefined;
var mock_entry_count: usize = 0;
var mock_enabled: bool = false;

fn hardwareBacked() bool {
    return builtin.os.tag == .freestanding and builtin.cpu.arch == .x86_64;
}

fn readPort32(port: u16) u32 {
    if (!hardwareBacked() and !(builtin.is_test and mock_enabled)) return 0xFFFF_FFFF;
    return asm volatile ("inl %[dx], %[eax]"
        : [eax] "={eax}" (-> u32),
        : [dx] "{dx}" (port),
        : "memory");
}

fn writePort32(port: u16, value: u32) void {
    if (!hardwareBacked() and !(builtin.is_test and mock_enabled)) return;
    asm volatile ("outl %[eax], %[dx]"
        :
        : [dx] "{dx}" (port),
          [eax] "{eax}" (value),
        : "memory");
}

fn configAddress(bus: u8, device: u8, function: u8, offset: u8) u32 {
    return 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, function) << 8) |
        @as(u32, offset & 0xFC);
}

fn mockEntry(bus: u8, device: u8, function: u8) ?*MockEntry {
    if (!builtin.is_test or !mock_enabled) return null;
    var index: usize = 0;
    while (index < mock_entry_count) : (index += 1) {
        const entry = &mock_entries[index];
        if (entry.bus == bus and entry.device == device and entry.function == function) {
            return entry;
        }
    }
    return null;
}

fn ensureMockEntry(bus: u8, device: u8, function: u8) *MockEntry {
    if (mockEntry(bus, device, function)) |entry| return entry;
    std.debug.assert(mock_entry_count < mock_entry_capacity);
    const entry = &mock_entries[mock_entry_count];
    mock_entry_count += 1;
    entry.* = .{
        .bus = bus,
        .device = device,
        .function = function,
    };
    return entry;
}

fn readConfig32(bus: u8, device: u8, function: u8, offset: u8) u32 {
    if (builtin.is_test and mock_enabled) {
        if (mockEntry(bus, device, function)) |entry| {
            return entry.regs[offset / 4];
        }
        return 0xFFFF_FFFF;
    }
    if (!hardwareBacked()) return 0xFFFF_FFFF;
    writePort32(config_address_port, configAddress(bus, device, function, offset));
    return readPort32(config_data_port);
}

fn writeConfig32(bus: u8, device: u8, function: u8, offset: u8, value: u32) void {
    if (builtin.is_test and mock_enabled) {
        const entry = ensureMockEntry(bus, device, function);
        entry.regs[offset / 4] = value;
        return;
    }
    if (!hardwareBacked()) return;
    writePort32(config_address_port, configAddress(bus, device, function, offset));
    writePort32(config_data_port, value);
}

fn readConfig16(bus: u8, device: u8, function: u8, offset: u8) u16 {
    const value = readConfig32(bus, device, function, offset);
    const shift: u5 = @intCast((offset & 0x2) * 8);
    return @as(u16, @truncate(value >> shift));
}

fn writeConfig16(bus: u8, device: u8, function: u8, offset: u8, value: u16) void {
    const aligned = offset & 0xFC;
    const current = readConfig32(bus, device, function, aligned);
    const shift: u5 = @intCast((offset & 0x2) * 8);
    const mask = ~(@as(u32, 0xFFFF) << shift);
    const updated = (current & mask) | (@as(u32, value) << shift);
    writeConfig32(bus, device, function, aligned, updated);
}

fn vendorId(bus: u8, device: u8, function: u8) u16 {
    return @as(u16, @truncate(readConfig32(bus, device, function, 0x00)));
}

fn deviceId(bus: u8, device: u8, function: u8) u16 {
    return @as(u16, @truncate(readConfig32(bus, device, function, 0x00) >> 16));
}

fn classCode(bus: u8, device: u8, function: u8) u8 {
    return @as(u8, @truncate(readConfig32(bus, device, function, 0x08) >> 24));
}

fn subclass(bus: u8, device: u8, function: u8) u8 {
    return @as(u8, @truncate(readConfig32(bus, device, function, 0x08) >> 16));
}

fn headerType(bus: u8, device: u8, function: u8) u8 {
    return @as(u8, @truncate(readConfig32(bus, device, function, 0x0C) >> 16));
}

fn firstFramebufferMemoryBar(bus: u8, device: u8, function: u8) ?u64 {
    var bar_index: u8 = 0;
    while (bar_index < 6) : (bar_index += 1) {
        const offset: u8 = 0x10 + (bar_index * 4);
        const low = readConfig32(bus, device, function, offset);
        if (low == 0 or low == 0xFFFF_FFFF) continue;
        if ((low & 0x1) != 0) continue;

        const mem_type = (low >> 1) & 0x3;
        if (mem_type == 0x2 and bar_index + 1 < 6) {
            const high = readConfig32(bus, device, function, offset + 4);
            const addr = (@as(u64, high) << 32) | @as(u64, low & 0xFFFF_FFF0);
            if (addr != 0) return addr;
            bar_index += 1;
            continue;
        }

        const addr = @as(u64, low & 0xFFFF_FFF0);
        if (addr != 0) return addr;
    }
    return null;
}

fn enableMemoryAndIoDecode(location: DeviceLocation) void {
    const command = readConfig16(location.bus, location.device, location.function, 0x04);
    const wanted = command | 0x3;
    if (wanted != command) {
        writeConfig16(location.bus, location.device, location.function, 0x04, wanted);
    }
}

pub fn discoverDisplayFramebufferBar() ?u64 {
    if (!hardwareBacked() and !(builtin.is_test and mock_enabled)) return null;

    var preferred: ?u64 = null;
    var fallback: ?u64 = null;

    var bus: usize = 0;
    while (bus < max_bus_count) : (bus += 1) {
        var device: usize = 0;
        while (device < max_device_count) : (device += 1) {
            const bus_id: u8 = @intCast(bus);
            const device_id0: u8 = @intCast(device);
            const first_vendor = vendorId(bus_id, device_id0, 0);
            if (first_vendor == 0xFFFF) continue;

            const function_limit: usize = if ((headerType(bus_id, device_id0, 0) & 0x80) != 0) max_function_count else 1;
            var function: usize = 0;
            while (function < function_limit) : (function += 1) {
                const function_id: u8 = @intCast(function);
                const vendor = vendorId(bus_id, device_id0, function_id);
                if (vendor == 0xFFFF) continue;
                if (classCode(bus_id, device_id0, function_id) != 0x03) continue;

                const location: DeviceLocation = .{
                    .bus = bus_id,
                    .device = device_id0,
                    .function = function_id,
                };
                enableMemoryAndIoDecode(location);

                const bar = firstFramebufferMemoryBar(bus_id, device_id0, function_id) orelse continue;
                const device_word = deviceId(bus_id, device_id0, function_id);
                const sub = subclass(bus_id, device_id0, function_id);

                if (vendor == 0x1234 and (device_word == 0x1111 or device_word == 0x1110)) {
                    return bar;
                }
                if (preferred == null and sub == 0x00) preferred = bar;
                if (fallback == null) fallback = bar;
            }
        }
    }

    return preferred orelse fallback;
}

pub fn testResetForTest() void {
    if (!builtin.is_test) return;
    mock_enabled = false;
    mock_entry_count = 0;
}

pub fn testSetConfig32(bus: u8, device: u8, function: u8, offset: u8, value: u32) void {
    if (!builtin.is_test) return;
    mock_enabled = true;
    const entry = ensureMockEntry(bus, device, function);
    entry.regs[offset / 4] = value;
}

test "pci display scan finds bochs-style framebuffer bar and enables decode" {
    testResetForTest();
    defer testResetForTest();

    testSetConfig32(0, 1, 0, 0x00, 0x1111_1234);
    testSetConfig32(0, 1, 0, 0x04, 0x0000_0000);
    testSetConfig32(0, 1, 0, 0x08, 0x0300_0000);
    testSetConfig32(0, 1, 0, 0x0C, 0x0000_0000);
    testSetConfig32(0, 1, 0, 0x10, 0xFD00_0000);

    const bar = discoverDisplayFramebufferBar() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0xFD00_0000), bar);
    try std.testing.expectEqual(@as(u16, 0x3), readConfig16(0, 1, 0, 0x04) & 0x3);
}
