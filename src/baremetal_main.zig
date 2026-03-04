const std = @import("std");

pub const BaremetalStatus = extern struct {
    magic: u32,
    api_version: u16,
    mode: u8,
    reserved0: u8,
    ticks: u64,
    last_health_code: u16,
    reserved1: u16,
    feature_flags: u32,
};

const mode_booting: u8 = 0;
const mode_running: u8 = 1;
const mode_panicked: u8 = 255;

const feature_os_hosted_runtime: u32 = 1 << 0;
const feature_baremetal_runtime: u32 = 1 << 1;
const feature_lightpanda_bridge_policy: u32 = 1 << 2;
const feature_memory_edge_contracts: u32 = 1 << 3;

const multiboot2_magic: u32 = 0xE85250D6;
const multiboot2_architecture_i386: u32 = 0;

const Multiboot2Header = extern struct {
    magic: u32,
    architecture: u32,
    header_length: u32,
    checksum: u32,
    end_tag_type: u16,
    end_tag_flags: u16,
    end_tag_size: u32,
};

const multiboot2_header_length: u32 = @sizeOf(Multiboot2Header);
const multiboot2_checksum: u32 = @as(u32, 0) -%
    (multiboot2_magic +% multiboot2_architecture_i386 +% multiboot2_header_length);

pub export const multiboot2_header align(8) linksection(".multiboot") = Multiboot2Header{
    .magic = multiboot2_magic,
    .architecture = multiboot2_architecture_i386,
    .header_length = multiboot2_header_length,
    .checksum = multiboot2_checksum,
    .end_tag_type = 0,
    .end_tag_flags = 0,
    .end_tag_size = 8,
};

var status: BaremetalStatus = .{
    .magic = 0x4f43424d, // "OCBM"
    .api_version = 1,
    .mode = mode_booting,
    .reserved0 = 0,
    .ticks = 0,
    .last_health_code = 0,
    .reserved1 = 0,
    .feature_flags = feature_os_hosted_runtime |
        feature_baremetal_runtime |
        feature_lightpanda_bridge_policy |
        feature_memory_edge_contracts,
};

pub export fn oc_status_ptr() *const BaremetalStatus {
    return &status;
}

pub export fn oc_tick() void {
    status.mode = mode_running;
    status.ticks +%= 1;
    status.last_health_code = 200;
}

pub export fn _start() noreturn {
    status.mode = mode_running;
    while (true) {
        oc_tick();
        spinPause(100_000);
    }
}

fn spinPause(iterations: usize) void {
    var idx: usize = 0;
    while (idx < iterations) : (idx += 1) {
        asm volatile ("" ::: "memory");
    }
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    status.mode = mode_panicked;
    while (true) {
        asm volatile ("" ::: "memory");
    }
}
