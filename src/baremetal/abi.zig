const std = @import("std");

pub const status_magic: u32 = 0x4f43424d; // "OCBM"
pub const command_magic: u32 = 0x4f43434d; // "OCCM"
pub const kernel_info_magic: u32 = 0x4f434b49; // "OCKI"
pub const boot_diag_magic: u32 = 0x4f434244; // "OCBD"

pub const api_version: u16 = 2;

pub const mode_booting: u8 = 0;
pub const mode_running: u8 = 1;
pub const mode_panicked: u8 = 255;

pub const boot_phase_preinit: u8 = 0;
pub const boot_phase_init: u8 = 1;
pub const boot_phase_runtime: u8 = 2;
pub const boot_phase_panicked: u8 = 255;

pub const feature_os_hosted_runtime: u32 = 1 << 0;
pub const feature_baremetal_runtime: u32 = 1 << 1;
pub const feature_lightpanda_bridge_policy: u32 = 1 << 2;
pub const feature_memory_edge_contracts: u32 = 1 << 3;
pub const feature_command_mailbox: u32 = 1 << 4;
pub const feature_multiboot2_header: u32 = 1 << 5;
pub const feature_kernel_info_export: u32 = 1 << 6;
pub const feature_descriptor_tables_export: u32 = 1 << 7;
pub const feature_interrupt_stub_export: u32 = 1 << 8;
pub const feature_interrupt_mailbox_control: u32 = 1 << 9;
pub const feature_interrupt_state_export: u32 = 1 << 10;
pub const feature_descriptor_load_export: u32 = 1 << 11;
pub const feature_exception_telemetry_export: u32 = 1 << 12;
pub const feature_exception_code_payload_export: u32 = 1 << 13;
pub const feature_exception_history_export: u32 = 1 << 14;
pub const feature_interrupt_history_export: u32 = 1 << 15;
pub const feature_vector_counters_export: u32 = 1 << 16;
pub const feature_boot_diagnostics_export: u32 = 1 << 17;
pub const feature_command_history_export: u32 = 1 << 18;
pub const feature_health_history_export: u32 = 1 << 19;

pub const kernel_abi_multiboot2: u32 = 1 << 0;
pub const kernel_abi_command_mailbox: u32 = 1 << 1;
pub const kernel_abi_panic_counter: u32 = 1 << 2;
pub const kernel_abi_tick_batch: u32 = 1 << 3;
pub const kernel_abi_descriptor_tables: u32 = 1 << 4;
pub const kernel_abi_interrupt_stub: u32 = 1 << 5;
pub const kernel_abi_interrupt_mailbox: u32 = 1 << 6;
pub const kernel_abi_interrupt_state: u32 = 1 << 7;
pub const kernel_abi_descriptor_load: u32 = 1 << 8;
pub const kernel_abi_exception_telemetry: u32 = 1 << 9;
pub const kernel_abi_exception_payload: u32 = 1 << 10;
pub const kernel_abi_exception_history: u32 = 1 << 11;
pub const kernel_abi_interrupt_history: u32 = 1 << 12;
pub const kernel_abi_vector_counters: u32 = 1 << 13;
pub const kernel_abi_boot_diagnostics: u32 = 1 << 14;
pub const kernel_abi_command_history: u32 = 1 << 15;
pub const kernel_abi_health_history: u32 = 1 << 16;

pub const command_nop: u16 = 0;
pub const command_set_health_code: u16 = 1;
pub const command_set_feature_flags: u16 = 2;
pub const command_reset_counters: u16 = 3;
pub const command_set_mode: u16 = 4;
pub const command_trigger_panic_flag: u16 = 5;
pub const command_set_tick_batch_hint: u16 = 6;
pub const command_trigger_interrupt: u16 = 7;
pub const command_reset_interrupt_counters: u16 = 8;
pub const command_reinit_descriptor_tables: u16 = 9;
pub const command_load_descriptor_tables: u16 = 10;
pub const command_reset_exception_counters: u16 = 11;
pub const command_trigger_exception: u16 = 12;
pub const command_clear_exception_history: u16 = 13;
pub const command_clear_interrupt_history: u16 = 14;
pub const command_reset_vector_counters: u16 = 15;
pub const command_set_boot_phase: u16 = 16;
pub const command_reset_boot_diagnostics: u16 = 17;
pub const command_capture_stack_pointer: u16 = 18;
pub const command_clear_command_history: u16 = 19;
pub const command_clear_health_history: u16 = 20;

pub const result_ok: i16 = 0;
pub const result_invalid_argument: i16 = -22;
pub const result_not_supported: i16 = -38;

pub const BaremetalStatus = extern struct {
    magic: u32,
    api_version: u16,
    mode: u8,
    reserved0: u8,
    ticks: u64,
    last_health_code: u16,
    reserved1: u16,
    feature_flags: u32,
    panic_count: u32,
    command_seq_ack: u32,
    last_command_opcode: u16,
    last_command_result: i16,
    tick_batch_hint: u32,
};

pub const BaremetalCommand = extern struct {
    magic: u32,
    api_version: u16,
    opcode: u16,
    seq: u32,
    arg0: u64,
    arg1: u64,
};

pub const BaremetalKernelInfo = extern struct {
    magic: u32,
    api_version: u16,
    pointer_width_bytes: u8,
    endianness: u8, // 1 = little endian
    abi_flags: u32,
    status_size: u32,
    command_size: u32,
};

pub const BaremetalBootDiagnostics = extern struct {
    magic: u32,
    api_version: u16,
    phase: u8,
    reserved0: u8,
    boot_seq: u32,
    last_command_seq: u32,
    last_command_tick: u64,
    last_tick_observed: u64,
    stack_pointer_snapshot: u64,
    phase_changes: u32,
    reserved1: u32,
};

pub const BaremetalCommandEvent = extern struct {
    seq: u32,
    opcode: u16,
    result: i16,
    tick: u64,
    arg0: u64,
    arg1: u64,
};

pub const BaremetalHealthEvent = extern struct {
    seq: u32,
    health_code: u16,
    mode: u8,
    reserved0: u8,
    tick: u64,
    command_seq_ack: u32,
    reserved1: u32,
};

pub fn defaultFeatureFlags() u32 {
    return feature_os_hosted_runtime |
        feature_baremetal_runtime |
        feature_lightpanda_bridge_policy |
        feature_memory_edge_contracts |
        feature_command_mailbox |
        feature_multiboot2_header |
        feature_kernel_info_export |
        feature_descriptor_tables_export |
        feature_interrupt_stub_export |
        feature_interrupt_mailbox_control |
        feature_interrupt_state_export |
        feature_descriptor_load_export |
        feature_exception_telemetry_export |
        feature_exception_code_payload_export |
        feature_exception_history_export |
        feature_interrupt_history_export |
        feature_vector_counters_export |
        feature_boot_diagnostics_export |
        feature_command_history_export |
        feature_health_history_export;
}

pub fn defaultAbiFlags() u32 {
    return kernel_abi_multiboot2 |
        kernel_abi_command_mailbox |
        kernel_abi_panic_counter |
        kernel_abi_tick_batch |
        kernel_abi_descriptor_tables |
        kernel_abi_interrupt_stub |
        kernel_abi_interrupt_mailbox |
        kernel_abi_interrupt_state |
        kernel_abi_descriptor_load |
        kernel_abi_exception_telemetry |
        kernel_abi_exception_payload |
        kernel_abi_exception_history |
        kernel_abi_interrupt_history |
        kernel_abi_vector_counters |
        kernel_abi_boot_diagnostics |
        kernel_abi_command_history |
        kernel_abi_health_history;
}

pub fn modeIsValid(mode: u8) bool {
    return mode == mode_booting or mode == mode_running or mode == mode_panicked;
}

pub fn bootPhaseIsValid(phase: u8) bool {
    return phase == boot_phase_preinit or
        phase == boot_phase_init or
        phase == boot_phase_runtime or
        phase == boot_phase_panicked;
}

test "baremetal abi layout contract stays stable" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(BaremetalStatus, "magic"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(BaremetalStatus, "api_version"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(BaremetalStatus, "ticks"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(BaremetalStatus, "last_health_code"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(BaremetalStatus, "feature_flags"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(BaremetalStatus, "panic_count"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(BaremetalStatus, "command_seq_ack"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(BaremetalStatus, "last_command_opcode"));
    try std.testing.expectEqual(@as(usize, 34), @offsetOf(BaremetalStatus, "last_command_result"));
    try std.testing.expectEqual(@as(usize, 36), @offsetOf(BaremetalStatus, "tick_batch_hint"));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BaremetalStatus));
}

test "baremetal kernel info size contract stays stable" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(BaremetalKernelInfo));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BaremetalCommand));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(BaremetalBootDiagnostics));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BaremetalCommandEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(BaremetalHealthEvent));
}

test "baremetal mode helper validates supported modes" {
    try std.testing.expect(modeIsValid(mode_booting));
    try std.testing.expect(modeIsValid(mode_running));
    try std.testing.expect(modeIsValid(mode_panicked));
    try std.testing.expect(!modeIsValid(2));
}

test "baremetal boot phase helper validates supported phases" {
    try std.testing.expect(bootPhaseIsValid(boot_phase_preinit));
    try std.testing.expect(bootPhaseIsValid(boot_phase_init));
    try std.testing.expect(bootPhaseIsValid(boot_phase_runtime));
    try std.testing.expect(bootPhaseIsValid(boot_phase_panicked));
    try std.testing.expect(!bootPhaseIsValid(3));
}
