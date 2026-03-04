const std = @import("std");

pub const gdt_entries_count: usize = 8;
pub const idt_entries_count: usize = 256;
pub const interrupt_vector_table_size: usize = 256;
pub const exception_vector_table_size: usize = 32;

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
    last_exception_vector: u8,
    reserved1: [7]u8,
    exception_count: u64,
    last_exception_code: u64,
    exception_history_len: u32,
    exception_history_overflow: u32,
    interrupt_history_len: u32,
    interrupt_history_overflow: u32,
};

pub const ExceptionEvent = extern struct {
    seq: u32,
    vector: u8,
    reserved0: [3]u8,
    code: u64,
    interrupt_count: u64,
    exception_count: u64,
};

pub const InterruptEvent = extern struct {
    seq: u32,
    vector: u8,
    is_exception: u8,
    reserved0: [2]u8,
    code: u64,
    interrupt_count: u64,
    exception_count: u64,
};

var gdt: [gdt_entries_count]GdtEntry = undefined;
var idt: [idt_entries_count]IdtEntry = undefined;
var gdtr: DescriptorPointer = .{ .limit = 0, .base = 0 };
var idtr: DescriptorPointer = .{ .limit = 0, .base = 0 };

var descriptor_tables_ready: bool = false;
var descriptor_tables_loaded: bool = false;
var last_interrupt_vector: u8 = 0;
var interrupt_counter: u64 = 0;
var interrupt_vector_counts: [interrupt_vector_table_size]u64 = std.mem.zeroes([interrupt_vector_table_size]u64);
var last_exception_vector: u8 = 0;
var exception_counter: u64 = 0;
var last_exception_code: u64 = 0;
var exception_vector_counts: [exception_vector_table_size]u64 = std.mem.zeroes([exception_vector_table_size]u64);
var descriptor_init_counter: u32 = 0;
var descriptor_load_attempts: u32 = 0;
var descriptor_load_successes: u32 = 0;
const exception_history_capacity: usize = 16;
var exception_history: [exception_history_capacity]ExceptionEvent = undefined;
var exception_history_count: u32 = 0;
var exception_history_head: u32 = 0;
var exception_history_seq: u32 = 0;
var exception_history_overflow: u32 = 0;
const interrupt_history_capacity: usize = 32;
var interrupt_history: [interrupt_history_capacity]InterruptEvent = undefined;
var interrupt_history_count: u32 = 0;
var interrupt_history_head: u32 = 0;
var interrupt_history_seq: u32 = 0;
var interrupt_history_overflow: u32 = 0;
var interrupt_state: InterruptState = .{
    .descriptor_tables_ready = 0,
    .descriptor_tables_loaded = 0,
    .last_interrupt_vector = 0,
    .reserved0 = 0,
    .load_attempts = 0,
    .load_successes = 0,
    .descriptor_init_count = 0,
    .interrupt_count = 0,
    .last_exception_vector = 0,
    .reserved1 = std.mem.zeroes([7]u8),
    .exception_count = 0,
    .last_exception_code = 0,
    .exception_history_len = 0,
    .exception_history_overflow = 0,
    .interrupt_history_len = 0,
    .interrupt_history_overflow = 0,
};

const default_selector: u16 = 0x08;
const default_interrupt_type_attr: u8 = 0x8E;
const exception_vector_limit: u8 = 32;

pub fn init() void {
    @memset(&gdt, std.mem.zeroes(GdtEntry));
    @memset(&idt, std.mem.zeroes(IdtEntry));
    @memset(&exception_history, std.mem.zeroes(ExceptionEvent));
    @memset(&interrupt_history, std.mem.zeroes(InterruptEvent));

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

pub export fn oc_interrupt_vector_counts_ptr() *const [interrupt_vector_table_size]u64 {
    return &interrupt_vector_counts;
}

pub export fn oc_interrupt_vector_count(vector: u8) u64 {
    return interrupt_vector_counts[vector];
}

pub export fn oc_last_exception_vector() u8 {
    return last_exception_vector;
}

pub export fn oc_exception_count() u64 {
    return exception_counter;
}

pub export fn oc_exception_vector_counts_ptr() *const [exception_vector_table_size]u64 {
    return &exception_vector_counts;
}

pub export fn oc_exception_vector_count(vector: u8) u64 {
    if (vector >= exception_vector_table_size) return 0;
    return exception_vector_counts[vector];
}

pub export fn oc_last_exception_code() u64 {
    return last_exception_code;
}

pub export fn oc_exception_history_capacity() u32 {
    return @as(u32, exception_history_capacity);
}

pub export fn oc_exception_history_len() u32 {
    return exception_history_count;
}

pub export fn oc_exception_history_head_index() u32 {
    return exception_history_head;
}

pub export fn oc_exception_history_overflow_count() u32 {
    return exception_history_overflow;
}

pub export fn oc_exception_history_ptr() *const [exception_history_capacity]ExceptionEvent {
    return &exception_history;
}

pub export fn oc_exception_history_event(index: u32) ExceptionEvent {
    if (index >= exception_history_count) {
        return std.mem.zeroes(ExceptionEvent);
    }
    const cap_u32: u32 = @as(u32, exception_history_capacity);
    const oldest = if (exception_history_count == cap_u32) exception_history_head else 0;
    const pos = @mod(oldest + index, cap_u32);
    return exception_history[pos];
}

pub export fn oc_interrupt_history_capacity() u32 {
    return @as(u32, interrupt_history_capacity);
}

pub export fn oc_interrupt_history_len() u32 {
    return interrupt_history_count;
}

pub export fn oc_interrupt_history_head_index() u32 {
    return interrupt_history_head;
}

pub export fn oc_interrupt_history_overflow_count() u32 {
    return interrupt_history_overflow;
}

pub export fn oc_interrupt_history_ptr() *const [interrupt_history_capacity]InterruptEvent {
    return &interrupt_history;
}

pub export fn oc_interrupt_history_event(index: u32) InterruptEvent {
    if (index >= interrupt_history_count) {
        return std.mem.zeroes(InterruptEvent);
    }
    const cap_u32: u32 = @as(u32, interrupt_history_capacity);
    const oldest = if (interrupt_history_count == cap_u32) interrupt_history_head else 0;
    const pos = @mod(oldest + index, cap_u32);
    return interrupt_history[pos];
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

pub export fn oc_reset_exception_counters() void {
    last_exception_vector = 0;
    exception_counter = 0;
    last_exception_code = 0;
    refreshInterruptState();
}

pub export fn oc_reset_vector_counters() void {
    @memset(&interrupt_vector_counts, 0);
    @memset(&exception_vector_counts, 0);
    refreshInterruptState();
}

pub export fn oc_exception_history_clear() void {
    @memset(&exception_history, std.mem.zeroes(ExceptionEvent));
    exception_history_count = 0;
    exception_history_head = 0;
    exception_history_seq = 0;
    exception_history_overflow = 0;
    refreshInterruptState();
}

pub export fn oc_interrupt_history_clear() void {
    @memset(&interrupt_history, std.mem.zeroes(InterruptEvent));
    interrupt_history_count = 0;
    interrupt_history_head = 0;
    interrupt_history_seq = 0;
    interrupt_history_overflow = 0;
    refreshInterruptState();
}

pub export fn oc_trigger_interrupt(vector: u8) void {
    oc_interrupt_stub(vector);
}

pub export fn oc_trigger_exception(vector: u8, code: u64) void {
    oc_exception_stub(vector, code);
}

pub export fn oc_exception_stub(vector: u8, code: u64) void {
    if (vector >= exception_vector_limit) {
        oc_interrupt_stub(vector);
        return;
    }
    last_interrupt_vector = vector;
    interrupt_counter +%= 1;
    interrupt_vector_counts[vector] +%= 1;
    last_exception_vector = vector;
    last_exception_code = code;
    exception_counter +%= 1;
    exception_vector_counts[vector] +%= 1;
    recordInterrupt(vector, true, code);
    recordException(vector, code);
    refreshInterruptState();
}

pub export fn oc_interrupt_stub(vector: u8) void {
    last_interrupt_vector = vector;
    interrupt_counter +%= 1;
    interrupt_vector_counts[vector] +%= 1;
    if (vector < exception_vector_limit) {
        last_exception_vector = vector;
        last_exception_code = 0;
        exception_counter +%= 1;
        exception_vector_counts[vector] +%= 1;
        recordInterrupt(vector, true, 0);
        recordException(vector, 0);
    } else {
        recordInterrupt(vector, false, 0);
    }
    refreshInterruptState();
}

fn recordInterrupt(vector: u8, is_exception: bool, code: u64) void {
    const cap_u32: u32 = @as(u32, interrupt_history_capacity);
    const write_index = interrupt_history_head;
    interrupt_history_seq +%= 1;
    interrupt_history[write_index] = .{
        .seq = interrupt_history_seq,
        .vector = vector,
        .is_exception = if (is_exception) 1 else 0,
        .reserved0 = std.mem.zeroes([2]u8),
        .code = code,
        .interrupt_count = interrupt_counter,
        .exception_count = exception_counter,
    };
    interrupt_history_head = @mod(interrupt_history_head + 1, cap_u32);
    if (interrupt_history_count < cap_u32) {
        interrupt_history_count += 1;
    } else {
        interrupt_history_overflow +%= 1;
    }
}

fn recordException(vector: u8, code: u64) void {
    const cap_u32: u32 = @as(u32, exception_history_capacity);
    const write_index = exception_history_head;
    exception_history_seq +%= 1;
    exception_history[write_index] = .{
        .seq = exception_history_seq,
        .vector = vector,
        .reserved0 = std.mem.zeroes([3]u8),
        .code = code,
        .interrupt_count = interrupt_counter,
        .exception_count = exception_counter,
    };
    exception_history_head = @mod(exception_history_head + 1, cap_u32);
    if (exception_history_count < cap_u32) {
        exception_history_count += 1;
    } else {
        exception_history_overflow +%= 1;
    }
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
        .last_exception_vector = last_exception_vector,
        .reserved1 = std.mem.zeroes([7]u8),
        .exception_count = exception_counter,
        .last_exception_code = last_exception_code,
        .exception_history_len = exception_history_count,
        .exception_history_overflow = exception_history_overflow,
        .interrupt_history_len = interrupt_history_count,
        .interrupt_history_overflow = interrupt_history_overflow,
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

test "x86 bootstrap exception telemetry tracks exception vectors only" {
    init();
    oc_exception_history_clear();
    oc_reset_exception_counters();
    const before = oc_exception_count();
    oc_trigger_exception(14, 0xDEAD_BEEF);
    oc_trigger_interrupt(200);
    const state = oc_interrupt_state_ptr().*;
    try std.testing.expectEqual(before + 1, oc_exception_count());
    try std.testing.expectEqual(@as(u8, 14), oc_last_exception_vector());
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF), oc_last_exception_code());
    try std.testing.expectEqual(before + 1, state.exception_count);
    try std.testing.expectEqual(@as(u8, 14), state.last_exception_vector);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF), state.last_exception_code);
}

test "x86 bootstrap exception history ring buffer records, overflows, and clears" {
    init();
    oc_exception_history_clear();
    oc_reset_exception_counters();

    const cap = oc_exception_history_capacity();
    var idx: u32 = 0;
    while (idx < cap + 3) : (idx += 1) {
        oc_trigger_exception(13, @as(u64, idx + 100));
    }

    try std.testing.expectEqual(cap, oc_exception_history_len());
    try std.testing.expectEqual(@as(u32, 3), oc_exception_history_overflow_count());

    const first = oc_exception_history_event(0);
    try std.testing.expectEqual(@as(u8, 13), first.vector);
    try std.testing.expectEqual(@as(u64, 103), first.code);

    const last = oc_exception_history_event(cap - 1);
    try std.testing.expectEqual(@as(u64, (cap + 3 - 1) + 100), last.code);

    oc_exception_history_clear();
    try std.testing.expectEqual(@as(u32, 0), oc_exception_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_exception_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), oc_exception_history_head_index());
}

test "x86 bootstrap interrupt history ring buffer records vectors and exception flag" {
    init();
    oc_interrupt_history_clear();
    oc_exception_history_clear();
    oc_reset_interrupt_counters();
    oc_reset_exception_counters();

    oc_trigger_interrupt(200);
    oc_trigger_exception(13, 0xCAFE);

    try std.testing.expectEqual(@as(u32, 2), oc_interrupt_history_len());
    const e0 = oc_interrupt_history_event(0);
    try std.testing.expectEqual(@as(u8, 200), e0.vector);
    try std.testing.expectEqual(@as(u8, 0), e0.is_exception);
    try std.testing.expectEqual(@as(u64, 0), e0.code);

    const e1 = oc_interrupt_history_event(1);
    try std.testing.expectEqual(@as(u8, 13), e1.vector);
    try std.testing.expectEqual(@as(u8, 1), e1.is_exception);
    try std.testing.expectEqual(@as(u64, 0xCAFE), e1.code);

    oc_interrupt_history_clear();
    try std.testing.expectEqual(@as(u32, 0), oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_interrupt_history_overflow_count());
}

test "x86 bootstrap vector counters track per-vector hits and reset" {
    init();
    oc_reset_interrupt_counters();
    oc_reset_exception_counters();
    oc_reset_vector_counters();

    oc_trigger_interrupt(10);
    oc_trigger_interrupt(10);
    oc_trigger_interrupt(200);
    oc_trigger_exception(14, 0xABCD);

    try std.testing.expectEqual(@as(u64, 2), oc_interrupt_vector_count(10));
    try std.testing.expectEqual(@as(u64, 1), oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 1), oc_interrupt_vector_count(14));
    try std.testing.expectEqual(@as(u64, 1), oc_exception_vector_count(14));
    try std.testing.expectEqual(@as(u64, 2), oc_exception_vector_count(10));
    try std.testing.expectEqual(@as(u64, 0), oc_exception_vector_count(200));

    oc_reset_vector_counters();
    try std.testing.expectEqual(@as(u64, 0), oc_interrupt_vector_count(10));
    try std.testing.expectEqual(@as(u64, 0), oc_interrupt_vector_count(14));
    try std.testing.expectEqual(@as(u64, 0), oc_exception_vector_count(10));
    try std.testing.expectEqual(@as(u64, 0), oc_exception_vector_count(14));
}
