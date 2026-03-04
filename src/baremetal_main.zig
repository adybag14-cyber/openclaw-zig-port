const std = @import("std");
const abi = @import("baremetal/abi.zig");
const x86_bootstrap = @import("baremetal/x86_bootstrap.zig");
const build_options = @import("build_options");
const BaremetalStatus = abi.BaremetalStatus;
const BaremetalCommand = abi.BaremetalCommand;
const BaremetalKernelInfo = abi.BaremetalKernelInfo;
const BaremetalBootDiagnostics = abi.BaremetalBootDiagnostics;

const multiboot2_magic: u32 = 0xE85250D6;
const multiboot2_architecture_i386: u32 = 0;
const qemu_debug_exit_port: u16 = 0xF4;
const qemu_boot_ok_code: u8 = 0x2A;
const qemu_smoke_enabled: bool = build_options.qemu_smoke;

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
        setBootPhase(abi.boot_phase_init);
        x86_bootstrap.init();
    }
    processPendingCommand();
    if (status.mode == abi.mode_booting) {
        status.mode = abi.mode_running;
        setBootPhase(abi.boot_phase_runtime);
    }
    if (status.mode != abi.mode_panicked) {
        status.last_health_code = 200;
    }
    const batch = if (status.tick_batch_hint == 0) @as(u32, 1) else status.tick_batch_hint;
    status.ticks +%= @as(u64, batch);
    boot_diagnostics.last_tick_observed = status.ticks;
}

pub export fn oc_tick_n(iterations: u32) void {
    var remaining = iterations;
    while (remaining > 0) : (remaining -= 1) {
        oc_tick();
    }
}

pub export fn _start() noreturn {
    setBootPhase(abi.boot_phase_init);
    x86_bootstrap.init();
    _ = x86_bootstrap.oc_try_load_descriptor_tables();
    status.mode = abi.mode_running;
    setBootPhase(abi.boot_phase_runtime);
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
}

fn executeCommand(opcode: u16, arg0: u64, arg1: u64) i16 {
    switch (opcode) {
        abi.command_nop => return abi.result_ok,
        abi.command_set_health_code => {
            if (arg0 > std.math.maxInt(u16)) return abi.result_invalid_argument;
            status.last_health_code = @as(u16, @truncate(arg0));
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
            return abi.result_ok;
        },
        abi.command_set_mode => {
            if (arg0 > std.math.maxInt(u8)) return abi.result_invalid_argument;
            const mode: u8 = @as(u8, @truncate(arg0));
            if (!abi.modeIsValid(mode)) return abi.result_invalid_argument;
            status.mode = mode;
            return abi.result_ok;
        },
        abi.command_trigger_panic_flag => {
            status.mode = abi.mode_panicked;
            status.panic_count +%= 1;
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
            setBootPhase(phase);
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
        else => return abi.result_not_supported,
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

fn setBootPhase(new_phase: u8) void {
    if (!abi.bootPhaseIsValid(new_phase)) return;
    if (boot_diagnostics.phase != new_phase) {
        boot_diagnostics.phase_changes +%= 1;
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
    status.mode = abi.mode_panicked;
    status.panic_count +%= 1;
    setBootPhase(abi.boot_phase_panicked);
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
    try std.testing.expectEqual(@as(u64, 0), boot_diagnostics.last_command_seq);
    try std.testing.expect(boot_diagnostics.boot_seq > 0);
}
