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
pub const feature_mode_history_export: u32 = 1 << 20;
pub const feature_boot_phase_history_export: u32 = 1 << 21;
pub const feature_command_result_counters_export: u32 = 1 << 22;
pub const feature_scheduler_export: u32 = 1 << 23;
pub const feature_allocator_export: u32 = 1 << 24;
pub const feature_syscall_table_export: u32 = 1 << 25;
pub const feature_timer_export: u32 = 1 << 26;
pub const feature_wake_queue_export: u32 = 1 << 27;
pub const feature_syscall_abi_v2: u32 = 1 << 28;

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
pub const kernel_abi_mode_history: u32 = 1 << 17;
pub const kernel_abi_boot_phase_history: u32 = 1 << 18;
pub const kernel_abi_command_result_counters: u32 = 1 << 19;
pub const kernel_abi_scheduler: u32 = 1 << 20;
pub const kernel_abi_allocator: u32 = 1 << 21;
pub const kernel_abi_syscall_table: u32 = 1 << 22;
pub const kernel_abi_timer: u32 = 1 << 23;
pub const kernel_abi_wake_queue: u32 = 1 << 24;
pub const kernel_abi_syscall_abi_v2: u32 = 1 << 25;

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
pub const command_clear_mode_history: u16 = 21;
pub const command_clear_boot_phase_history: u16 = 22;
pub const command_reset_command_result_counters: u16 = 23;
pub const command_scheduler_enable: u16 = 24;
pub const command_scheduler_disable: u16 = 25;
pub const command_scheduler_reset: u16 = 26;
pub const command_task_create: u16 = 27;
pub const command_task_terminate: u16 = 28;
pub const command_scheduler_set_timeslice: u16 = 29;
pub const command_scheduler_set_default_budget: u16 = 30;
pub const command_allocator_reset: u16 = 31;
pub const command_allocator_alloc: u16 = 32;
pub const command_allocator_free: u16 = 33;
pub const command_syscall_register: u16 = 34;
pub const command_syscall_unregister: u16 = 35;
pub const command_syscall_invoke: u16 = 36;
pub const command_syscall_reset: u16 = 37;
pub const command_syscall_enable: u16 = 38;
pub const command_syscall_disable: u16 = 39;
pub const command_syscall_set_flags: u16 = 40;
pub const command_timer_reset: u16 = 41;
pub const command_timer_schedule: u16 = 42;
pub const command_timer_cancel: u16 = 43;
pub const command_wake_queue_clear: u16 = 44;
pub const command_scheduler_wake_task: u16 = 45;
pub const command_timer_enable: u16 = 46;
pub const command_timer_disable: u16 = 47;
pub const command_timer_set_quantum: u16 = 48;
pub const command_timer_schedule_periodic: u16 = 49;
pub const command_task_wait: u16 = 50;
pub const command_task_resume: u16 = 51;
pub const command_timer_cancel_task: u16 = 52;
pub const command_task_wait_for: u16 = 53;
pub const command_wake_queue_pop: u16 = 54;
pub const command_scheduler_set_policy: u16 = 55;
pub const command_task_set_priority: u16 = 56;
pub const command_task_wait_interrupt: u16 = 57;
pub const command_task_wait_interrupt_for: u16 = 58;
pub const command_wake_queue_pop_reason: u16 = 59;
pub const command_wake_queue_pop_vector: u16 = 60;

pub const mode_change_reason_boot: u8 = 0;
pub const mode_change_reason_command: u8 = 1;
pub const mode_change_reason_panic: u8 = 2;
pub const mode_change_reason_runtime_tick: u8 = 3;
pub const mode_change_reason_reset: u8 = 4;

pub const boot_phase_change_reason_boot: u8 = 0;
pub const boot_phase_change_reason_command: u8 = 1;
pub const boot_phase_change_reason_runtime_tick: u8 = 2;
pub const boot_phase_change_reason_panic: u8 = 3;
pub const boot_phase_change_reason_reset: u8 = 4;

pub const result_ok: i16 = 0;
pub const result_invalid_argument: i16 = -22;
pub const result_not_supported: i16 = -38;
pub const result_no_space: i16 = -28;
pub const result_not_found: i16 = -2;
pub const result_conflict: i16 = -17;

pub const scheduler_state_disabled: u8 = 0;
pub const scheduler_state_enabled: u8 = 1;
pub const scheduler_policy_round_robin: u8 = 0;
pub const scheduler_policy_priority: u8 = 1;

pub const task_state_unused: u8 = 0;
pub const task_state_ready: u8 = 1;
pub const task_state_running: u8 = 2;
pub const task_state_completed: u8 = 3;
pub const task_state_terminated: u8 = 4;
pub const task_state_faulted: u8 = 5;
pub const task_state_waiting: u8 = 6;

pub const allocation_state_unused: u8 = 0;
pub const allocation_state_active: u8 = 1;

pub const syscall_state_disabled: u8 = 0;
pub const syscall_state_enabled: u8 = 1;

pub const syscall_entry_state_unused: u8 = 0;
pub const syscall_entry_state_registered: u8 = 1;
pub const syscall_entry_flag_blocked: u8 = 1 << 0;

pub const timer_state_disabled: u8 = 0;
pub const timer_state_enabled: u8 = 1;

pub const timer_entry_state_unused: u8 = 0;
pub const timer_entry_state_armed: u8 = 1;
pub const timer_entry_state_fired: u8 = 2;
pub const timer_entry_state_canceled: u8 = 3;
pub const timer_entry_flag_periodic: u16 = 1 << 0;

pub const wake_reason_timer: u8 = 1;
pub const wake_reason_interrupt: u8 = 2;
pub const wake_reason_manual: u8 = 3;

pub const wait_interrupt_any_vector: u16 = 0xFFFF;

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

pub const BaremetalModeEvent = extern struct {
    seq: u32,
    previous_mode: u8,
    new_mode: u8,
    reason: u8,
    reserved0: u8,
    tick: u64,
    command_seq_ack: u32,
    reserved1: u32,
};

pub const BaremetalBootPhaseEvent = extern struct {
    seq: u32,
    previous_phase: u8,
    new_phase: u8,
    reason: u8,
    reserved0: u8,
    tick: u64,
    command_seq_ack: u32,
    reserved1: u32,
};

pub const BaremetalCommandResultCounters = extern struct {
    ok_count: u32,
    invalid_argument_count: u32,
    not_supported_count: u32,
    other_error_count: u32,
    total_count: u32,
    reserved0: u32,
    last_result: i16,
    reserved1: u16,
    last_opcode: u16,
    reserved2: u16,
    last_seq: u32,
};

pub const BaremetalSchedulerState = extern struct {
    enabled: u8,
    task_count: u8,
    running_slot: u8,
    reserved0: u8,
    next_task_id: u32,
    dispatch_count: u64,
    last_dispatch_tick: u64,
    timeslice_ticks: u32,
    default_budget_ticks: u32,
    ready_scans: u32,
    reserved1: u32,
};

pub const BaremetalTask = extern struct {
    task_id: u32,
    state: u8,
    priority: u8,
    reserved0: u16,
    run_count: u32,
    budget_ticks: u32,
    budget_remaining: u32,
    created_tick: u64,
    last_run_tick: u64,
};

pub const BaremetalAllocatorState = extern struct {
    heap_base: u64,
    heap_size: u64,
    page_size: u32,
    total_pages: u32,
    free_pages: u32,
    allocation_count: u32,
    alloc_ops: u32,
    free_ops: u32,
    bytes_in_use: u64,
    peak_bytes_in_use: u64,
    last_alloc_ptr: u64,
    last_alloc_size: u64,
    last_free_ptr: u64,
    last_free_size: u64,
};

pub const BaremetalAllocationRecord = extern struct {
    ptr: u64,
    size_bytes: u64,
    page_start: u32,
    page_len: u32,
    state: u8,
    reserved0: [7]u8,
    created_tick: u64,
    last_used_tick: u64,
};

pub const BaremetalSyscallState = extern struct {
    enabled: u8,
    entry_count: u8,
    reserved0: u16,
    last_syscall_id: u32,
    dispatch_count: u64,
    last_invoke_tick: u64,
    last_result: i64,
};

pub const BaremetalSyscallEntry = extern struct {
    syscall_id: u32,
    state: u8,
    flags: u8,
    reserved0: u16,
    handler_token: u64,
    invoke_count: u64,
    last_arg: u64,
    last_result: i64,
};

pub const BaremetalTimerState = extern struct {
    enabled: u8,
    timer_count: u8,
    pending_wake_count: u16,
    next_timer_id: u32,
    dispatch_count: u64,
    last_dispatch_tick: u64,
    last_interrupt_count: u64,
    last_wake_tick: u64,
    tick_quantum: u32,
    reserved0: u32,
};

pub const BaremetalTimerEntry = extern struct {
    timer_id: u32,
    task_id: u32,
    state: u8,
    reason: u8,
    flags: u16,
    period_ticks: u32,
    next_fire_tick: u64,
    fire_count: u64,
    last_fire_tick: u64,
};

pub const BaremetalWakeEvent = extern struct {
    seq: u32,
    task_id: u32,
    timer_id: u32,
    reason: u8,
    vector: u8,
    reserved0: u16,
    tick: u64,
    interrupt_count: u64,
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
        feature_health_history_export |
        feature_mode_history_export |
        feature_boot_phase_history_export |
        feature_command_result_counters_export |
        feature_scheduler_export |
        feature_allocator_export |
        feature_syscall_table_export |
        feature_timer_export |
        feature_wake_queue_export |
        feature_syscall_abi_v2;
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
        kernel_abi_health_history |
        kernel_abi_mode_history |
        kernel_abi_boot_phase_history |
        kernel_abi_command_result_counters |
        kernel_abi_scheduler |
        kernel_abi_allocator |
        kernel_abi_syscall_table |
        kernel_abi_timer |
        kernel_abi_wake_queue |
        kernel_abi_syscall_abi_v2;
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

pub fn schedulerPolicyIsValid(policy: u8) bool {
    return policy == scheduler_policy_round_robin or policy == scheduler_policy_priority;
}

pub fn wakeReasonIsValid(reason: u8) bool {
    return reason == wake_reason_timer or reason == wake_reason_interrupt or reason == wake_reason_manual;
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
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(BaremetalModeEvent));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(BaremetalBootPhaseEvent));
    try std.testing.expectEqual(@as(usize, 36), @sizeOf(BaremetalCommandResultCounters));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BaremetalSchedulerState));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BaremetalTask));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(BaremetalAllocatorState));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(BaremetalAllocationRecord));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BaremetalSyscallState));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BaremetalSyscallEntry));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(BaremetalTimerState));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(BaremetalTimerEntry));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(BaremetalWakeEvent));
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

test "baremetal scheduler policy helper validates supported policies" {
    try std.testing.expect(schedulerPolicyIsValid(scheduler_policy_round_robin));
    try std.testing.expect(schedulerPolicyIsValid(scheduler_policy_priority));
    try std.testing.expect(!schedulerPolicyIsValid(2));
}

test "baremetal wake reason helper validates supported reasons" {
    try std.testing.expect(wakeReasonIsValid(wake_reason_timer));
    try std.testing.expect(wakeReasonIsValid(wake_reason_interrupt));
    try std.testing.expect(wakeReasonIsValid(wake_reason_manual));
    try std.testing.expect(!wakeReasonIsValid(0));
    try std.testing.expect(!wakeReasonIsValid(4));
}
