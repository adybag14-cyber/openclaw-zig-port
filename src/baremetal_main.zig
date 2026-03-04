const std = @import("std");
const builtin = @import("builtin");
const abi = @import("baremetal/abi.zig");
const x86_bootstrap = @import("baremetal/x86_bootstrap.zig");
const BaremetalStatus = abi.BaremetalStatus;
const BaremetalCommand = abi.BaremetalCommand;
const BaremetalKernelInfo = abi.BaremetalKernelInfo;
const BaremetalBootDiagnostics = abi.BaremetalBootDiagnostics;
const BaremetalCommandEvent = abi.BaremetalCommandEvent;
const BaremetalHealthEvent = abi.BaremetalHealthEvent;
const BaremetalModeEvent = abi.BaremetalModeEvent;
const BaremetalBootPhaseEvent = abi.BaremetalBootPhaseEvent;

const multiboot2_magic: u32 = 0xE85250D6;
const multiboot2_architecture_i386: u32 = 0;
const qemu_debug_exit_port: u16 = 0xF4;
const qemu_boot_ok_code: u8 = 0x2A;
const qemu_smoke_enabled: bool = if (builtin.is_test) false else @import("build_options").qemu_smoke;

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
    .magic = abi.status_magic,
    .api_version = abi.api_version,
    .mode = abi.mode_booting,
    .reserved0 = 0,
    .ticks = 0,
    .last_health_code = 0,
    .reserved1 = 0,
    .feature_flags = abi.defaultFeatureFlags(),
    .panic_count = 0,
    .command_seq_ack = 0,
    .last_command_opcode = abi.command_nop,
    .last_command_result = abi.result_ok,
    .tick_batch_hint = 1,
};

var command_mailbox: BaremetalCommand = .{
    .magic = abi.command_magic,
    .api_version = abi.api_version,
    .opcode = abi.command_nop,
    .seq = 0,
    .arg0 = 0,
    .arg1 = 0,
};

pub export var kernel_info: BaremetalKernelInfo = .{
    .magic = abi.kernel_info_magic,
    .api_version = abi.api_version,
    .pointer_width_bytes = @sizeOf(usize),
    .endianness = 1,
    .abi_flags = abi.defaultAbiFlags(),
    .status_size = @sizeOf(BaremetalStatus),
    .command_size = @sizeOf(BaremetalCommand),
};

var boot_diagnostics: BaremetalBootDiagnostics = .{
    .magic = abi.boot_diag_magic,
    .api_version = abi.api_version,
    .phase = abi.boot_phase_preinit,
    .reserved0 = 0,
    .boot_seq = 0,
    .last_command_seq = 0,
    .last_command_tick = 0,
    .last_tick_observed = 0,
    .stack_pointer_snapshot = 0,
    .phase_changes = 0,
    .reserved1 = 0,
};

const command_history_capacity: usize = 32;
var command_history: [command_history_capacity]BaremetalCommandEvent = std.mem.zeroes([command_history_capacity]BaremetalCommandEvent);
var command_history_count: u32 = 0;
var command_history_head: u32 = 0;
var command_history_overflow: u32 = 0;

const health_history_capacity: usize = 64;
var health_history: [health_history_capacity]BaremetalHealthEvent = std.mem.zeroes([health_history_capacity]BaremetalHealthEvent);
var health_history_count: u32 = 0;
var health_history_head: u32 = 0;
var health_history_overflow: u32 = 0;
var health_history_seq: u32 = 0;

const mode_history_capacity: usize = 64;
var mode_history: [mode_history_capacity]BaremetalModeEvent = std.mem.zeroes([mode_history_capacity]BaremetalModeEvent);
var mode_history_count: u32 = 0;
var mode_history_head: u32 = 0;
var mode_history_overflow: u32 = 0;
var mode_history_seq: u32 = 0;

const boot_phase_history_capacity: usize = 64;
var boot_phase_history: [boot_phase_history_capacity]BaremetalBootPhaseEvent = std.mem.zeroes([boot_phase_history_capacity]BaremetalBootPhaseEvent);
var boot_phase_history_count: u32 = 0;
var boot_phase_history_head: u32 = 0;
var boot_phase_history_overflow: u32 = 0;
var boot_phase_history_seq: u32 = 0;

pub export fn oc_status_ptr() *const abi.BaremetalStatus {
    return &status;
}

pub export fn oc_command_ptr() *const abi.BaremetalCommand {
    return &command_mailbox;
}

pub export fn oc_kernel_info_ptr() *const abi.BaremetalKernelInfo {
    return &kernel_info;
}

pub export fn oc_boot_diag_ptr() *const abi.BaremetalBootDiagnostics {
    return &boot_diagnostics;
}

pub export fn oc_boot_diag_capture_stack() u64 {
    const snapshot = captureStackPointer();
    boot_diagnostics.stack_pointer_snapshot = snapshot;
    return snapshot;
}

pub export fn oc_command_history_capacity() u32 {
    return @as(u32, command_history_capacity);
}

pub export fn oc_command_history_len() u32 {
    return command_history_count;
}

pub export fn oc_command_history_head_index() u32 {
    return command_history_head;
}

pub export fn oc_command_history_overflow_count() u32 {
    return command_history_overflow;
}

pub export fn oc_command_history_ptr() *const [command_history_capacity]BaremetalCommandEvent {
    return &command_history;
}

pub export fn oc_command_history_event(index: u32) BaremetalCommandEvent {
    if (index >= command_history_count) {
        return std.mem.zeroes(BaremetalCommandEvent);
    }
    const cap_u32: u32 = @as(u32, command_history_capacity);
    const oldest = if (command_history_count == cap_u32) command_history_head else 0;
    const pos = @mod(oldest + index, cap_u32);
    return command_history[pos];
}

pub export fn oc_command_history_clear() void {
    @memset(&command_history, std.mem.zeroes(BaremetalCommandEvent));
    command_history_count = 0;
    command_history_head = 0;
    command_history_overflow = 0;
}

pub export fn oc_health_history_capacity() u32 {
    return @as(u32, health_history_capacity);
}

pub export fn oc_health_history_len() u32 {
    return health_history_count;
}

pub export fn oc_health_history_head_index() u32 {
    return health_history_head;
}

pub export fn oc_health_history_overflow_count() u32 {
    return health_history_overflow;
}

pub export fn oc_health_history_ptr() *const [health_history_capacity]BaremetalHealthEvent {
    return &health_history;
}

pub export fn oc_health_history_event(index: u32) BaremetalHealthEvent {
    if (index >= health_history_count) {
        return std.mem.zeroes(BaremetalHealthEvent);
    }
    const cap_u32: u32 = @as(u32, health_history_capacity);
    const oldest = if (health_history_count == cap_u32) health_history_head else 0;
    const pos = @mod(oldest + index, cap_u32);
    return health_history[pos];
}

pub export fn oc_health_history_clear() void {
    @memset(&health_history, std.mem.zeroes(BaremetalHealthEvent));
    health_history_count = 0;
    health_history_head = 0;
    health_history_overflow = 0;
    health_history_seq = 0;
}

pub export fn oc_mode_history_capacity() u32 {
    return @as(u32, mode_history_capacity);
}

pub export fn oc_mode_history_len() u32 {
    return mode_history_count;
}

pub export fn oc_mode_history_head_index() u32 {
    return mode_history_head;
}

pub export fn oc_mode_history_overflow_count() u32 {
    return mode_history_overflow;
}

pub export fn oc_mode_history_ptr() *const [mode_history_capacity]BaremetalModeEvent {
    return &mode_history;
}

pub export fn oc_mode_history_event(index: u32) BaremetalModeEvent {
    if (index >= mode_history_count) {
        return std.mem.zeroes(BaremetalModeEvent);
    }
    const cap_u32: u32 = @as(u32, mode_history_capacity);
    const oldest = if (mode_history_count == cap_u32) mode_history_head else 0;
    const pos = @mod(oldest + index, cap_u32);
    return mode_history[pos];
}

pub export fn oc_mode_history_clear() void {
    @memset(&mode_history, std.mem.zeroes(BaremetalModeEvent));
    mode_history_count = 0;
    mode_history_head = 0;
    mode_history_overflow = 0;
    mode_history_seq = 0;
}

pub export fn oc_boot_phase_history_capacity() u32 {
    return @as(u32, boot_phase_history_capacity);
}

pub export fn oc_boot_phase_history_len() u32 {
    return boot_phase_history_count;
}

pub export fn oc_boot_phase_history_head_index() u32 {
    return boot_phase_history_head;
}

pub export fn oc_boot_phase_history_overflow_count() u32 {
    return boot_phase_history_overflow;
}

pub export fn oc_boot_phase_history_ptr() *const [boot_phase_history_capacity]BaremetalBootPhaseEvent {
    return &boot_phase_history;
}

pub export fn oc_boot_phase_history_event(index: u32) BaremetalBootPhaseEvent {
    if (index >= boot_phase_history_count) {
        return std.mem.zeroes(BaremetalBootPhaseEvent);
    }
    const cap_u32: u32 = @as(u32, boot_phase_history_capacity);
    const oldest = if (boot_phase_history_count == cap_u32) boot_phase_history_head else 0;
    const pos = @mod(oldest + index, cap_u32);
    return boot_phase_history[pos];
}

pub export fn oc_boot_phase_history_clear() void {
    @memset(&boot_phase_history, std.mem.zeroes(BaremetalBootPhaseEvent));
    boot_phase_history_count = 0;
    boot_phase_history_head = 0;
    boot_phase_history_overflow = 0;
    boot_phase_history_seq = 0;
}

pub export fn oc_submit_command(opcode: u16, arg0: u64, arg1: u64) u32 {
    const next_seq = command_mailbox.seq +% 1;
    command_mailbox.opcode = opcode;
    command_mailbox.arg0 = arg0;
    command_mailbox.arg1 = arg1;
    command_mailbox.seq = next_seq;
    return next_seq;
}

pub export fn oc_tick() void {
    if (!x86_bootstrap.oc_descriptor_tables_ready()) {
        setBootPhase(abi.boot_phase_init, abi.boot_phase_change_reason_boot);
        x86_bootstrap.init();
    }
    processPendingCommand();
    if (status.mode == abi.mode_booting) {
        const previous_mode = status.mode;
        status.mode = abi.mode_running;
        recordMode(previous_mode, status.mode, abi.mode_change_reason_runtime_tick, status.ticks, status.command_seq_ack);
        setBootPhase(abi.boot_phase_runtime, abi.boot_phase_change_reason_runtime_tick);
    }
    if (status.mode != abi.mode_panicked) {
        status.last_health_code = 200;
    }
    const batch = if (status.tick_batch_hint == 0) @as(u32, 1) else status.tick_batch_hint;
    status.ticks +%= @as(u64, batch);
    boot_diagnostics.last_tick_observed = status.ticks;
    recordHealth(status.last_health_code, status.mode, status.ticks, status.command_seq_ack);
}

pub export fn oc_tick_n(iterations: u32) void {
    var remaining = iterations;
    while (remaining > 0) : (remaining -= 1) {
        oc_tick();
    }
}

pub export fn _start() noreturn {
    setBootPhase(abi.boot_phase_init, abi.boot_phase_change_reason_boot);
    x86_bootstrap.init();
    _ = x86_bootstrap.oc_try_load_descriptor_tables();
    const previous_mode = status.mode;
    status.mode = abi.mode_running;
    recordMode(previous_mode, status.mode, abi.mode_change_reason_boot, status.ticks, status.command_seq_ack);
    setBootPhase(abi.boot_phase_runtime, abi.boot_phase_change_reason_boot);
    if (qemu_smoke_enabled) {
        qemuExit(qemu_boot_ok_code);
    }
    while (true) {
        oc_tick();
        spinPause(100_000);
    }
}

fn processPendingCommand() void {
    if (command_mailbox.seq == status.command_seq_ack) return;

    status.last_command_opcode = command_mailbox.opcode;
    status.last_command_result = executeCommand(command_mailbox.opcode, command_mailbox.arg0, command_mailbox.arg1);
    status.command_seq_ack = command_mailbox.seq;
    boot_diagnostics.last_command_seq = status.command_seq_ack;
    boot_diagnostics.last_command_tick = status.ticks;
    recordCommand(
        status.command_seq_ack,
        command_mailbox.opcode,
        command_mailbox.arg0,
        command_mailbox.arg1,
        status.last_command_result,
        status.ticks,
    );
}

fn executeCommand(opcode: u16, arg0: u64, arg1: u64) i16 {
    switch (opcode) {
        abi.command_nop => return abi.result_ok,
        abi.command_set_health_code => {
            if (arg0 > std.math.maxInt(u16)) return abi.result_invalid_argument;
            status.last_health_code = @as(u16, @truncate(arg0));
            recordHealth(status.last_health_code, status.mode, status.ticks, status.command_seq_ack);
            return abi.result_ok;
        },
        abi.command_set_feature_flags => {
            status.feature_flags = @as(u32, @truncate(arg0));
            return abi.result_ok;
        },
        abi.command_reset_counters => {
            status.ticks = 0;
            status.panic_count = 0;
            x86_bootstrap.oc_reset_interrupt_counters();
            x86_bootstrap.oc_reset_exception_counters();
            x86_bootstrap.oc_reset_vector_counters();
            x86_bootstrap.oc_exception_history_clear();
            x86_bootstrap.oc_interrupt_history_clear();
            oc_command_history_clear();
            oc_health_history_clear();
            oc_mode_history_clear();
            oc_boot_phase_history_clear();
            return abi.result_ok;
        },
        abi.command_set_mode => {
            if (arg0 > std.math.maxInt(u8)) return abi.result_invalid_argument;
            const mode: u8 = @as(u8, @truncate(arg0));
            if (!abi.modeIsValid(mode)) return abi.result_invalid_argument;
            const previous_mode = status.mode;
            status.mode = mode;
            if (previous_mode != status.mode) {
                recordMode(previous_mode, status.mode, abi.mode_change_reason_command, status.ticks, status.command_seq_ack);
            }
            return abi.result_ok;
        },
        abi.command_trigger_panic_flag => {
            const previous_mode = status.mode;
            status.mode = abi.mode_panicked;
            status.panic_count +%= 1;
            setBootPhase(abi.boot_phase_panicked, abi.boot_phase_change_reason_panic);
            if (previous_mode != status.mode) {
                recordMode(previous_mode, status.mode, abi.mode_change_reason_panic, status.ticks, status.command_seq_ack);
            }
            recordHealth(status.last_health_code, status.mode, status.ticks, status.command_seq_ack);
            return abi.result_ok;
        },
        abi.command_set_tick_batch_hint => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            status.tick_batch_hint = @as(u32, @truncate(arg0));
            return abi.result_ok;
        },
        abi.command_trigger_interrupt => {
            if (arg0 > std.math.maxInt(u8)) return abi.result_invalid_argument;
            x86_bootstrap.oc_trigger_interrupt(@as(u8, @truncate(arg0)));
            return abi.result_ok;
        },
        abi.command_reset_interrupt_counters => {
            x86_bootstrap.oc_reset_interrupt_counters();
            return abi.result_ok;
        },
        abi.command_reinit_descriptor_tables => {
            x86_bootstrap.init();
            return abi.result_ok;
        },
        abi.command_load_descriptor_tables => {
            if (x86_bootstrap.oc_try_load_descriptor_tables()) return abi.result_ok;
            return abi.result_not_supported;
        },
        abi.command_reset_exception_counters => {
            x86_bootstrap.oc_reset_exception_counters();
            return abi.result_ok;
        },
        abi.command_trigger_exception => {
            if (arg0 > std.math.maxInt(u8)) return abi.result_invalid_argument;
            const vector: u8 = @as(u8, @truncate(arg0));
            if (vector >= 32) return abi.result_invalid_argument;
            x86_bootstrap.oc_trigger_exception(vector, arg1);
            return abi.result_ok;
        },
        abi.command_clear_exception_history => {
            x86_bootstrap.oc_exception_history_clear();
            return abi.result_ok;
        },
        abi.command_clear_interrupt_history => {
            x86_bootstrap.oc_interrupt_history_clear();
            return abi.result_ok;
        },
        abi.command_reset_vector_counters => {
            x86_bootstrap.oc_reset_vector_counters();
            return abi.result_ok;
        },
        abi.command_set_boot_phase => {
            if (arg0 > std.math.maxInt(u8)) return abi.result_invalid_argument;
            const phase: u8 = @as(u8, @truncate(arg0));
            if (!abi.bootPhaseIsValid(phase)) return abi.result_invalid_argument;
            setBootPhase(phase, abi.boot_phase_change_reason_command);
            return abi.result_ok;
        },
        abi.command_reset_boot_diagnostics => {
            resetBootDiagnostics();
            return abi.result_ok;
        },
        abi.command_capture_stack_pointer => {
            _ = oc_boot_diag_capture_stack();
            return abi.result_ok;
        },
        abi.command_clear_command_history => {
            oc_command_history_clear();
            return abi.result_ok;
        },
        abi.command_clear_health_history => {
            oc_health_history_clear();
            return abi.result_ok;
        },
        abi.command_clear_mode_history => {
            oc_mode_history_clear();
            return abi.result_ok;
        },
        abi.command_clear_boot_phase_history => {
            oc_boot_phase_history_clear();
            return abi.result_ok;
        },
        else => return abi.result_not_supported,
    }
}

fn recordCommand(seq: u32, opcode: u16, arg0: u64, arg1: u64, result: i16, tick: u64) void {
    const cap_u32: u32 = @as(u32, command_history_capacity);
    const write_index = command_history_head;
    command_history[write_index] = .{
        .seq = seq,
        .opcode = opcode,
        .result = result,
        .tick = tick,
        .arg0 = arg0,
        .arg1 = arg1,
    };
    command_history_head = @mod(command_history_head + 1, cap_u32);
    if (command_history_count < cap_u32) {
        command_history_count += 1;
    } else {
        command_history_overflow +%= 1;
    }
}

fn recordHealth(health_code: u16, mode: u8, tick: u64, command_seq_ack: u32) void {
    const cap_u32: u32 = @as(u32, health_history_capacity);
    const write_index = health_history_head;
    health_history_seq +%= 1;
    health_history[write_index] = .{
        .seq = health_history_seq,
        .health_code = health_code,
        .mode = mode,
        .reserved0 = 0,
        .tick = tick,
        .command_seq_ack = command_seq_ack,
        .reserved1 = 0,
    };
    health_history_head = @mod(health_history_head + 1, cap_u32);
    if (health_history_count < cap_u32) {
        health_history_count += 1;
    } else {
        health_history_overflow +%= 1;
    }
}

fn recordMode(previous_mode: u8, new_mode: u8, reason: u8, tick: u64, command_seq_ack: u32) void {
    const cap_u32: u32 = @as(u32, mode_history_capacity);
    const write_index = mode_history_head;
    mode_history_seq +%= 1;
    mode_history[write_index] = .{
        .seq = mode_history_seq,
        .previous_mode = previous_mode,
        .new_mode = new_mode,
        .reason = reason,
        .reserved0 = 0,
        .tick = tick,
        .command_seq_ack = command_seq_ack,
        .reserved1 = 0,
    };
    mode_history_head = @mod(mode_history_head + 1, cap_u32);
    if (mode_history_count < cap_u32) {
        mode_history_count += 1;
    } else {
        mode_history_overflow +%= 1;
    }
}

fn recordBootPhase(previous_phase: u8, new_phase: u8, reason: u8, tick: u64, command_seq_ack: u32) void {
    const cap_u32: u32 = @as(u32, boot_phase_history_capacity);
    const write_index = boot_phase_history_head;
    boot_phase_history_seq +%= 1;
    boot_phase_history[write_index] = .{
        .seq = boot_phase_history_seq,
        .previous_phase = previous_phase,
        .new_phase = new_phase,
        .reason = reason,
        .reserved0 = 0,
        .tick = tick,
        .command_seq_ack = command_seq_ack,
        .reserved1 = 0,
    };
    boot_phase_history_head = @mod(boot_phase_history_head + 1, cap_u32);
    if (boot_phase_history_count < cap_u32) {
        boot_phase_history_count += 1;
    } else {
        boot_phase_history_overflow +%= 1;
    }
}

fn resetBootDiagnostics() void {
    const phase = defaultBootPhaseForMode(status.mode);
    boot_diagnostics = .{
        .magic = abi.boot_diag_magic,
        .api_version = abi.api_version,
        .phase = phase,
        .reserved0 = 0,
        .boot_seq = boot_diagnostics.boot_seq +% 1,
        .last_command_seq = 0,
        .last_command_tick = 0,
        .last_tick_observed = status.ticks,
        .stack_pointer_snapshot = 0,
        .phase_changes = 0,
        .reserved1 = 0,
    };
}

fn setBootPhase(new_phase: u8, reason: u8) void {
    if (!abi.bootPhaseIsValid(new_phase)) return;
    const previous_phase = boot_diagnostics.phase;
    if (previous_phase != new_phase) {
        boot_diagnostics.phase_changes +%= 1;
        recordBootPhase(previous_phase, new_phase, reason, status.ticks, status.command_seq_ack);
    }
    boot_diagnostics.phase = new_phase;
}

fn defaultBootPhaseForMode(mode: u8) u8 {
    return switch (mode) {
        abi.mode_booting => abi.boot_phase_init,
        abi.mode_running => abi.boot_phase_runtime,
        abi.mode_panicked => abi.boot_phase_panicked,
        else => abi.boot_phase_preinit,
    };
}

fn captureStackPointer() u64 {
    const fp = @frameAddress();
    return @as(u64, @intCast(fp));
}

fn spinPause(iterations: usize) void {
    var idx: usize = 0;
    while (idx < iterations) : (idx += 1) {
        if (@import("builtin").cpu.arch == .x86_64) {
            asm volatile ("pause" ::: "memory");
        } else if (@import("builtin").cpu.arch == .aarch64) {
            asm volatile ("yield" ::: "memory");
        } else {
            asm volatile ("" ::: "memory");
        }
    }
}

fn qemuExit(code: u8) noreturn {
    out8(qemu_debug_exit_port, code);
    while (true) {
        asm volatile ("hlt");
    }
}

fn out8(port: u16, value: u8) void {
    asm volatile ("out dx, al"
        :
        : [dx] "{dx}" (port),
          [al] "{al}" (value),
        : "memory");
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    const previous_mode = status.mode;
    status.mode = abi.mode_panicked;
    status.panic_count +%= 1;
    setBootPhase(abi.boot_phase_panicked, abi.boot_phase_change_reason_panic);
    if (previous_mode != status.mode) {
        recordMode(previous_mode, status.mode, abi.mode_change_reason_panic, status.ticks, status.command_seq_ack);
    }
    recordHealth(status.last_health_code, status.mode, status.ticks, status.command_seq_ack);
    while (true) {
        asm volatile ("" ::: "memory");
    }
}

test "baremetal diagnostics command flow updates phase and stack snapshot" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
    status.last_command_opcode = abi.command_nop;
    status.last_command_result = abi.result_ok;
    command_mailbox = .{
        .magic = abi.command_magic,
        .api_version = abi.api_version,
        .opcode = abi.command_nop,
        .seq = 0,
        .arg0 = 0,
        .arg1 = 0,
    };
    resetBootDiagnostics();
    oc_command_history_clear();
    oc_health_history_clear();
    oc_mode_history_clear();
    oc_boot_phase_history_clear();

    var seq = oc_submit_command(abi.command_capture_stack_pointer, 0, 0);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(seq, boot_diagnostics.last_command_seq);
    try std.testing.expect(boot_diagnostics.stack_pointer_snapshot != 0);
    try std.testing.expect(boot_diagnostics.last_tick_observed >= boot_diagnostics.last_command_tick);

    seq = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);

    seq = oc_submit_command(abi.command_set_boot_phase, 99, 0);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);

    seq = oc_submit_command(abi.command_reset_boot_diagnostics, 0, 0);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(u64, seq), boot_diagnostics.last_command_seq);
    try std.testing.expect(boot_diagnostics.boot_seq > 0);
    try std.testing.expectEqual(@as(u32, 4), oc_command_history_len());
    const history_last = oc_command_history_event(oc_command_history_len() - 1);
    try std.testing.expectEqual(@as(u16, abi.command_reset_boot_diagnostics), history_last.opcode);

    seq = oc_submit_command(abi.command_clear_command_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_len());
    const clear_event = oc_command_history_event(0);
    try std.testing.expectEqual(@as(u16, abi.command_clear_command_history), clear_event.opcode);

    oc_command_history_clear();
    try std.testing.expectEqual(@as(u32, 0), oc_command_history_len());
}

test "baremetal command history ring keeps newest mailbox entries" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
    status.last_command_opcode = abi.command_nop;
    status.last_command_result = abi.result_ok;
    command_mailbox = .{
        .magic = abi.command_magic,
        .api_version = abi.api_version,
        .opcode = abi.command_nop,
        .seq = 0,
        .arg0 = 0,
        .arg1 = 0,
    };
    oc_command_history_clear();
    oc_mode_history_clear();
    oc_boot_phase_history_clear();

    const cap = oc_command_history_capacity();
    var idx: u32 = 0;
    while (idx < cap + 3) : (idx += 1) {
        _ = oc_submit_command(abi.command_set_health_code, 100 + idx, 0);
        oc_tick();
    }

    try std.testing.expectEqual(cap, oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 3), oc_command_history_overflow_count());

    const first = oc_command_history_event(0);
    try std.testing.expectEqual(@as(u32, 4), first.seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_health_code), first.opcode);

    const last = oc_command_history_event(cap - 1);
    try std.testing.expectEqual(cap + 3, last.seq);
    try std.testing.expectEqual(@as(u64, 100 + (cap + 2)), last.arg0);
}

test "baremetal health history captures tick health and clear control" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.last_health_code = 0;
    status.command_seq_ack = 0;
    status.tick_batch_hint = 1;
    command_mailbox = .{
        .magic = abi.command_magic,
        .api_version = abi.api_version,
        .opcode = abi.command_nop,
        .seq = 0,
        .arg0 = 0,
        .arg1 = 0,
    };
    oc_health_history_clear();
    oc_mode_history_clear();
    oc_boot_phase_history_clear();

    oc_tick();
    oc_tick();
    try std.testing.expectEqual(@as(u32, 2), oc_health_history_len());
    const first = oc_health_history_event(0);
    try std.testing.expectEqual(@as(u16, 200), first.health_code);
    try std.testing.expectEqual(@as(u8, abi.mode_running), first.mode);

    _ = oc_submit_command(abi.command_set_health_code, 418, 0);
    oc_tick();
    try std.testing.expect(oc_health_history_len() >= 4);
    const pre_tick = oc_health_history_event(oc_health_history_len() - 2);
    try std.testing.expectEqual(@as(u16, 418), pre_tick.health_code);
    const latest = oc_health_history_event(oc_health_history_len() - 1);
    try std.testing.expectEqual(@as(u16, 200), latest.health_code);

    _ = oc_submit_command(abi.command_clear_health_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_len());
    const clear_latest = oc_health_history_event(0);
    try std.testing.expectEqual(@as(u16, 200), clear_latest.health_code);
}

test "baremetal mode history captures command and panic transitions and clear control" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
    status.panic_count = 0;
    status.last_command_opcode = abi.command_nop;
    status.last_command_result = abi.result_ok;
    status.tick_batch_hint = 1;
    command_mailbox = .{
        .magic = abi.command_magic,
        .api_version = abi.api_version,
        .opcode = abi.command_nop,
        .seq = 0,
        .arg0 = 0,
        .arg1 = 0,
    };
    oc_mode_history_clear();
    oc_boot_phase_history_clear();

    _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_len());
    const m0 = oc_mode_history_event(0);
    try std.testing.expectEqual(@as(u8, abi.mode_running), m0.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), m0.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_command), m0.reason);

    // Same tick transitions booting -> running after command processing.
    const m1 = oc_mode_history_event(1);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), m1.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_running), m1.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_runtime_tick), m1.reason);

    _ = oc_submit_command(abi.command_trigger_panic_flag, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 3), oc_mode_history_len());
    const m2 = oc_mode_history_event(2);
    try std.testing.expectEqual(@as(u8, abi.mode_running), m2.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_panicked), m2.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_panic), m2.reason);

    _ = oc_submit_command(abi.command_clear_mode_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_len());
}

test "baremetal boot phase history captures command runtime and panic transitions" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
    status.panic_count = 0;
    status.tick_batch_hint = 1;
    status.last_command_opcode = abi.command_nop;
    status.last_command_result = abi.result_ok;
    command_mailbox = .{
        .magic = abi.command_magic,
        .api_version = abi.api_version,
        .opcode = abi.command_nop,
        .seq = 0,
        .arg0 = 0,
        .arg1 = 0,
    };
    resetBootDiagnostics();
    oc_boot_phase_history_clear();

    // Runtime -> init via command.
    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());
    const p0 = oc_boot_phase_history_event(0);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), p0.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), p0.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), p0.reason);

    // Tick-driven mode booting -> running should emit init -> runtime.
    _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 2), oc_boot_phase_history_len());
    const p1 = oc_boot_phase_history_event(1);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), p1.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), p1.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_runtime_tick), p1.reason);

    // Panic command emits runtime -> panicked transition.
    _ = oc_submit_command(abi.command_trigger_panic_flag, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 3), oc_boot_phase_history_len());
    const p2 = oc_boot_phase_history_event(2);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), p2.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_panicked), p2.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_panic), p2.reason);

    _ = oc_submit_command(abi.command_clear_boot_phase_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_len());
}
