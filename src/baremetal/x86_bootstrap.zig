const std = @import("std");

pub const gdt_entries_count: usize = 8;
pub const idt_entries_count: usize = 256;

pub const GdtEntry = extern struct {
    limit_low: u16,
    base_low: u16,
    base_middle: u8,
    access: u8,
    granularity: u8,
    base_high: u8,
};

pub const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    zero: u32,
};

pub const DescriptorPointer = extern struct {
    limit: u16,
    base: u64,
};

pub const InterruptState = extern struct {
    descriptor_tables_ready: u8,
    descriptor_tables_loaded: u8,
    last_interrupt_vector: u8,
    reserved0: u8,
    load_attempts: u32,
    load_successes: u32,
    descriptor_init_count: u32,
    interrupt_count: u64,
};

var gdt: [gdt_entries_count]GdtEntry = undefined;
var idt: [idt_entries_count]IdtEntry = undefined;
var gdtr: DescriptorPointer = .{ .limit = 0, .base = 0 };
var idtr: DescriptorPointer = .{ .limit = 0, .base = 0 };

var descriptor_tables_ready: bool = false;
var descriptor_tables_loaded: bool = false;
var last_interrupt_vector: u8 = 0;
var interrupt_counter: u64 = 0;
var descriptor_init_counter: u32 = 0;
var descriptor_load_attempts: u32 = 0;
var descriptor_load_successes: u32 = 0;
var interrupt_state: InterruptState = .{
    .descriptor_tables_ready = 0,
    .descriptor_tables_loaded = 0,
    .last_interrupt_vector = 0,
    .reserved0 = 0,
    .load_attempts = 0,
    .load_successes = 0,
    .descriptor_init_count = 0,
    .interrupt_count = 0,
};

const default_selector: u16 = 0x08;
const default_interrupt_type_attr: u8 = 0x8E;

pub fn init() void {
    @memset(&gdt, std.mem.zeroes(GdtEntry));
    @memset(&idt, std.mem.zeroes(IdtEntry));

    gdt[1] = makeGdtEntry(0, 0xFFFFF, 0x9A, 0xA0);
    gdt[2] = makeGdtEntry(0, 0xFFFFF, 0x92, 0xA0);

    const stub_addr = @intFromPtr(&oc_interrupt_stub);
    var vector: usize = 0;
    while (vector < idt_entries_count) : (vector += 1) {
        idt[vector] = makeIdtEntry(stub_addr, default_selector, default_interrupt_type_attr);
    }

    gdtr = .{
        .limit = @as(u16, @intCast(@sizeOf(GdtEntry) * gdt_entries_count - 1)),
        .base = @as(u64, @intFromPtr(&gdt)),
    };
    idtr = .{
        .limit = @as(u16, @intCast(@sizeOf(IdtEntry) * idt_entries_count - 1)),
        .base = @as(u64, @intFromPtr(&idt)),
    };

    descriptor_init_counter +%= 1;
    descriptor_tables_ready = true;
    refreshInterruptState();
}

fn ensureInit() void {
    if (!descriptor_tables_ready) init();
}

fn makeGdtEntry(base: u32, limit: u32, access: u8, granularity_high: u8) GdtEntry {
    const limit_low: u16 = @as(u16, @intCast(limit & 0xFFFF));
    const base_low: u16 = @as(u16, @intCast(base & 0xFFFF));
    const base_middle: u8 = @as(u8, @intCast((base >> 16) & 0xFF));
    const base_high: u8 = @as(u8, @intCast((base >> 24) & 0xFF));
    const granularity: u8 = @as(u8, @intCast((limit >> 16) & 0x0F)) | (granularity_high & 0xF0);
    return .{
        .limit_low = limit_low,
        .base_low = base_low,
        .base_middle = base_middle,
        .access = access,
        .granularity = granularity,
        .base_high = base_high,
    };
}

fn makeIdtEntry(handler_addr: u64, selector: u16, type_attr: u8) IdtEntry {
    return .{
        .offset_low = @as(u16, @intCast(handler_addr & 0xFFFF)),
        .selector = selector,
        .ist = 0,
        .type_attr = type_attr,
        .offset_mid = @as(u16, @intCast((handler_addr >> 16) & 0xFFFF)),
        .offset_high = @as(u32, @intCast((handler_addr >> 32) & 0xFFFFFFFF)),
        .zero = 0,
    };
}

pub export fn oc_gdtr_ptr() *const DescriptorPointer {
    ensureInit();
    return &gdtr;
}

pub export fn oc_idtr_ptr() *const DescriptorPointer {
    ensureInit();
    return &idtr;
}

pub export fn oc_gdt_ptr() *const [gdt_entries_count]GdtEntry {
    ensureInit();
    return &gdt;
}

pub export fn oc_idt_ptr() *const [idt_entries_count]IdtEntry {
    ensureInit();
    return &idt;
}

pub export fn oc_descriptor_tables_ready() bool {
    return descriptor_tables_ready;
}

pub export fn oc_last_interrupt_vector() u8 {
    return last_interrupt_vector;
}

pub export fn oc_interrupt_count() u64 {
    return interrupt_counter;
}

pub export fn oc_descriptor_init_count() u32 {
    return descriptor_init_counter;
}

pub export fn oc_descriptor_tables_loaded() bool {
    return descriptor_tables_loaded;
}

pub export fn oc_descriptor_load_attempt_count() u32 {
    return descriptor_load_attempts;
}

pub export fn oc_descriptor_load_success_count() u32 {
    return descriptor_load_successes;
}

pub export fn oc_try_load_descriptor_tables() bool {
    ensureInit();
    descriptor_load_attempts +%= 1;
    if (@import("builtin").cpu.arch != .x86_64) {
        refreshInterruptState();
        return false;
    }

    // The freestanding runtime performs actual low-level load sequencing.
    // This export records successful load-state transitions for mailbox/ABI telemetry.
    descriptor_tables_loaded = true;
    descriptor_load_successes +%= 1;
    refreshInterruptState();
    return true;
}

pub export fn oc_interrupt_state_ptr() *const InterruptState {
    refreshInterruptState();
    return &interrupt_state;
}

pub export fn oc_reset_interrupt_counters() void {
    last_interrupt_vector = 0;
    interrupt_counter = 0;
    refreshInterruptState();
}

pub export fn oc_trigger_interrupt(vector: u8) void {
    oc_interrupt_stub(vector);
}

pub export fn oc_interrupt_stub(vector: u8) void {
    last_interrupt_vector = vector;
    interrupt_counter +%= 1;
    refreshInterruptState();
}

fn refreshInterruptState() void {
    interrupt_state = .{
        .descriptor_tables_ready = if (descriptor_tables_ready) 1 else 0,
        .descriptor_tables_loaded = if (descriptor_tables_loaded) 1 else 0,
        .last_interrupt_vector = last_interrupt_vector,
        .reserved0 = 0,
        .load_attempts = descriptor_load_attempts,
        .load_successes = descriptor_load_successes,
        .descriptor_init_count = descriptor_init_counter,
        .interrupt_count = interrupt_counter,
    };
}

test "x86 bootstrap init builds descriptor pointers and interrupt defaults" {
    init();
    try std.testing.expect(descriptor_tables_ready);
    try std.testing.expectEqual(@as(u16, @intCast(@sizeOf(GdtEntry) * gdt_entries_count - 1)), gdtr.limit);
    try std.testing.expectEqual(@as(u16, @intCast(@sizeOf(IdtEntry) * idt_entries_count - 1)), idtr.limit);
    try std.testing.expect(idt[0].type_attr == default_interrupt_type_attr);
    try std.testing.expect(idt[255].type_attr == default_interrupt_type_attr);
    try std.testing.expect(descriptor_init_counter > 0);
}

test "x86 bootstrap interrupt tracking updates counters" {
    init();
    const before = interrupt_counter;
    const init_before = descriptor_init_counter;
    oc_trigger_interrupt(42);
    try std.testing.expectEqual(@as(u8, 42), last_interrupt_vector);
    try std.testing.expect(interrupt_counter == before + 1);
    const state = oc_interrupt_state_ptr().*;
    try std.testing.expectEqual(@as(u8, 42), state.last_interrupt_vector);
    try std.testing.expectEqual(before + 1, state.interrupt_count);
    try std.testing.expectEqual(init_before, state.descriptor_init_count);
    oc_reset_interrupt_counters();
    try std.testing.expectEqual(@as(u8, 0), last_interrupt_vector);
    try std.testing.expectEqual(@as(u64, 0), interrupt_counter);
}

test "x86 bootstrap descriptor load telemetry updates attempts and successes" {
    init();
    const attempts_before = oc_descriptor_load_attempt_count();
    const success_before = oc_descriptor_load_success_count();
    const ok = oc_try_load_descriptor_tables();
    const state = oc_interrupt_state_ptr().*;
    try std.testing.expect(ok);
    try std.testing.expect(oc_descriptor_tables_loaded());
    try std.testing.expectEqual(attempts_before + 1, oc_descriptor_load_attempt_count());
    try std.testing.expectEqual(success_before + 1, oc_descriptor_load_success_count());
    try std.testing.expectEqual(@as(u8, 1), state.descriptor_tables_loaded);
}
