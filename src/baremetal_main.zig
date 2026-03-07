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
const BaremetalCommandResultCounters = abi.BaremetalCommandResultCounters;
const BaremetalSchedulerState = abi.BaremetalSchedulerState;
const BaremetalTask = abi.BaremetalTask;
const BaremetalAllocatorState = abi.BaremetalAllocatorState;
const BaremetalAllocationRecord = abi.BaremetalAllocationRecord;
const BaremetalSyscallState = abi.BaremetalSyscallState;
const BaremetalSyscallEntry = abi.BaremetalSyscallEntry;
const BaremetalTimerState = abi.BaremetalTimerState;
const BaremetalTimerEntry = abi.BaremetalTimerEntry;
const BaremetalWakeEvent = abi.BaremetalWakeEvent;
const BaremetalWakeQueueSummary = abi.BaremetalWakeQueueSummary;
const BaremetalWakeQueueAgeBuckets = abi.BaremetalWakeQueueAgeBuckets;

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

var command_result_counters: BaremetalCommandResultCounters = .{
    .ok_count = 0,
    .invalid_argument_count = 0,
    .not_supported_count = 0,
    .other_error_count = 0,
    .total_count = 0,
    .reserved0 = 0,
    .last_result = abi.result_ok,
    .reserved1 = 0,
    .last_opcode = abi.command_nop,
    .reserved2 = 0,
    .last_seq = 0,
};

const scheduler_task_capacity: usize = 16;
const scheduler_no_slot: u8 = 255;
const wait_condition_none: u8 = 0;
const wait_condition_manual: u8 = 1;
const wait_condition_timer: u8 = 2;
const wait_condition_interrupt_any: u8 = 3;
const wait_condition_interrupt_vector: u8 = 4;
var scheduler_tasks: [scheduler_task_capacity]BaremetalTask = std.mem.zeroes([scheduler_task_capacity]BaremetalTask);
var scheduler_wait_kind: [scheduler_task_capacity]u8 = [_]u8{wait_condition_none} ** scheduler_task_capacity;
var scheduler_wait_interrupt_vector: [scheduler_task_capacity]u8 = [_]u8{0} ** scheduler_task_capacity;
var scheduler_wait_timeout_tick: [scheduler_task_capacity]u64 = [_]u64{0} ** scheduler_task_capacity;
var scheduler_state: BaremetalSchedulerState = .{
    .enabled = abi.scheduler_state_disabled,
    .task_count = 0,
    .running_slot = scheduler_no_slot,
    .reserved0 = 0,
    .next_task_id = 1,
    .dispatch_count = 0,
    .last_dispatch_tick = 0,
    .timeslice_ticks = 1,
    .default_budget_ticks = 8,
    .ready_scans = 0,
    .reserved1 = 0,
};
var scheduler_rr_cursor: u8 = 0;
var scheduler_policy: u8 = abi.scheduler_policy_round_robin;

const allocator_page_capacity: usize = 256;
const allocator_record_capacity: usize = 64;
const allocator_default_page_size: u32 = 4096;
const allocator_default_heap_base: u64 = 0x0010_0000;
var allocator_page_bitmap: [allocator_page_capacity]u8 = std.mem.zeroes([allocator_page_capacity]u8);
var allocator_records: [allocator_record_capacity]BaremetalAllocationRecord = std.mem.zeroes([allocator_record_capacity]BaremetalAllocationRecord);
var allocator_state: BaremetalAllocatorState = .{
    .heap_base = allocator_default_heap_base,
    .heap_size = @as(u64, allocator_page_capacity) * allocator_default_page_size,
    .page_size = allocator_default_page_size,
    .total_pages = @as(u32, allocator_page_capacity),
    .free_pages = @as(u32, allocator_page_capacity),
    .allocation_count = 0,
    .alloc_ops = 0,
    .free_ops = 0,
    .bytes_in_use = 0,
    .peak_bytes_in_use = 0,
    .last_alloc_ptr = 0,
    .last_alloc_size = 0,
    .last_free_ptr = 0,
    .last_free_size = 0,
};

const syscall_entry_capacity: usize = 64;
var syscall_entries: [syscall_entry_capacity]BaremetalSyscallEntry = std.mem.zeroes([syscall_entry_capacity]BaremetalSyscallEntry);
var syscall_state: BaremetalSyscallState = .{
    .enabled = abi.syscall_state_enabled,
    .entry_count = 0,
    .reserved0 = 0,
    .last_syscall_id = 0,
    .dispatch_count = 0,
    .last_invoke_tick = 0,
    .last_result = 0,
};

const timer_capacity: usize = 32;
const wake_queue_capacity: usize = 64;
var timer_entries: [timer_capacity]BaremetalTimerEntry = std.mem.zeroes([timer_capacity]BaremetalTimerEntry);
var timer_state: BaremetalTimerState = .{
    .enabled = abi.timer_state_enabled,
    .timer_count = 0,
    .pending_wake_count = 0,
    .next_timer_id = 1,
    .dispatch_count = 0,
    .last_dispatch_tick = 0,
    .last_interrupt_count = 0,
    .last_wake_tick = 0,
    .tick_quantum = 1,
    .reserved0 = 0,
};
var wake_queue: [wake_queue_capacity]BaremetalWakeEvent = std.mem.zeroes([wake_queue_capacity]BaremetalWakeEvent);
var wake_queue_count: u32 = 0;
var wake_queue_head: u32 = 0;
var wake_queue_tail: u32 = 0;
var wake_queue_overflow: u32 = 0;
var wake_queue_seq: u32 = 0;
var wake_queue_summary_snapshot: BaremetalWakeQueueSummary = std.mem.zeroes(BaremetalWakeQueueSummary);
var wake_queue_age_buckets_snapshot: BaremetalWakeQueueAgeBuckets = std.mem.zeroes(BaremetalWakeQueueAgeBuckets);

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

pub export fn oc_command_result_counters_ptr() *const BaremetalCommandResultCounters {
    return &command_result_counters;
}

pub export fn oc_command_result_total_count() u32 {
    return command_result_counters.total_count;
}

pub export fn oc_command_result_count_ok() u32 {
    return command_result_counters.ok_count;
}

pub export fn oc_command_result_count_invalid_argument() u32 {
    return command_result_counters.invalid_argument_count;
}

pub export fn oc_command_result_count_not_supported() u32 {
    return command_result_counters.not_supported_count;
}

pub export fn oc_command_result_count_other_error() u32 {
    return command_result_counters.other_error_count;
}

pub export fn oc_command_result_counters_clear() void {
    command_result_counters = .{
        .ok_count = 0,
        .invalid_argument_count = 0,
        .not_supported_count = 0,
        .other_error_count = 0,
        .total_count = 0,
        .reserved0 = 0,
        .last_result = abi.result_ok,
        .reserved1 = 0,
        .last_opcode = abi.command_nop,
        .reserved2 = 0,
        .last_seq = 0,
    };
}

pub export fn oc_scheduler_state_ptr() *const BaremetalSchedulerState {
    return &scheduler_state;
}

pub export fn oc_scheduler_enabled() bool {
    return scheduler_state.enabled == abi.scheduler_state_enabled;
}

pub export fn oc_scheduler_task_capacity() u32 {
    return @as(u32, scheduler_task_capacity);
}

pub export fn oc_scheduler_policy() u8 {
    return scheduler_policy;
}

pub export fn oc_scheduler_task_count() u32 {
    return scheduler_state.task_count;
}

pub export fn oc_scheduler_waiting_count() u32 {
    var count: u32 = 0;
    for (scheduler_tasks) |task| {
        if (task.state == abi.task_state_waiting and task.task_id != 0) count +%= 1;
    }
    return count;
}

pub export fn oc_scheduler_wait_interrupt_count() u32 {
    var count: u32 = 0;
    for (scheduler_wait_kind, 0..) |kind, idx| {
        if (scheduler_tasks[idx].state != abi.task_state_waiting) continue;
        if (kind == wait_condition_interrupt_any or kind == wait_condition_interrupt_vector) count +%= 1;
    }
    return count;
}

pub export fn oc_scheduler_wait_timeout_count() u32 {
    var count: u32 = 0;
    for (scheduler_wait_timeout_tick, 0..) |deadline, idx| {
        if (scheduler_tasks[idx].state != abi.task_state_waiting) continue;
        if (deadline != 0) count +%= 1;
    }
    return count;
}

pub export fn oc_scheduler_task(index: u32) BaremetalTask {
    if (index >= @as(u32, scheduler_task_capacity)) return std.mem.zeroes(BaremetalTask);
    return scheduler_tasks[@as(usize, @intCast(index))];
}

pub export fn oc_scheduler_tasks_ptr() *const [scheduler_task_capacity]BaremetalTask {
    return &scheduler_tasks;
}

pub export fn oc_scheduler_reset() void {
    @memset(&scheduler_tasks, std.mem.zeroes(BaremetalTask));
    @memset(&scheduler_wait_kind, wait_condition_none);
    @memset(&scheduler_wait_interrupt_vector, 0);
    @memset(&scheduler_wait_timeout_tick, 0);
    scheduler_state = .{
        .enabled = abi.scheduler_state_disabled,
        .task_count = 0,
        .running_slot = scheduler_no_slot,
        .reserved0 = 0,
        .next_task_id = 1,
        .dispatch_count = 0,
        .last_dispatch_tick = status.ticks,
        .timeslice_ticks = 1,
        .default_budget_ticks = 8,
        .ready_scans = 0,
        .reserved1 = 0,
    };
    scheduler_rr_cursor = 0;
    scheduler_policy = abi.scheduler_policy_round_robin;
}

pub export fn oc_allocator_state_ptr() *const BaremetalAllocatorState {
    return &allocator_state;
}

pub export fn oc_allocator_page_count() u32 {
    return allocator_state.total_pages;
}

pub export fn oc_allocator_page_bitmap_ptr() *const [allocator_page_capacity]u8 {
    return &allocator_page_bitmap;
}

pub export fn oc_allocator_allocation_capacity() u32 {
    return @as(u32, allocator_record_capacity);
}

pub export fn oc_allocator_allocation_count() u32 {
    return allocator_state.allocation_count;
}

pub export fn oc_allocator_allocation(index: u32) BaremetalAllocationRecord {
    if (index >= @as(u32, allocator_record_capacity)) return std.mem.zeroes(BaremetalAllocationRecord);
    return allocator_records[@as(usize, @intCast(index))];
}

pub export fn oc_allocator_allocations_ptr() *const [allocator_record_capacity]BaremetalAllocationRecord {
    return &allocator_records;
}

pub export fn oc_allocator_reset() void {
    @memset(&allocator_page_bitmap, 0);
    @memset(&allocator_records, std.mem.zeroes(BaremetalAllocationRecord));
    allocator_state = .{
        .heap_base = allocator_default_heap_base,
        .heap_size = @as(u64, allocator_page_capacity) * allocator_default_page_size,
        .page_size = allocator_default_page_size,
        .total_pages = @as(u32, allocator_page_capacity),
        .free_pages = @as(u32, allocator_page_capacity),
        .allocation_count = 0,
        .alloc_ops = 0,
        .free_ops = 0,
        .bytes_in_use = 0,
        .peak_bytes_in_use = 0,
        .last_alloc_ptr = 0,
        .last_alloc_size = 0,
        .last_free_ptr = 0,
        .last_free_size = 0,
    };
}

pub export fn oc_syscall_state_ptr() *const BaremetalSyscallState {
    return &syscall_state;
}

pub export fn oc_syscall_entry_capacity() u32 {
    return @as(u32, syscall_entry_capacity);
}

pub export fn oc_syscall_entry_count() u32 {
    return syscall_state.entry_count;
}

pub export fn oc_syscall_entry(index: u32) BaremetalSyscallEntry {
    if (index >= @as(u32, syscall_entry_capacity)) return std.mem.zeroes(BaremetalSyscallEntry);
    return syscall_entries[@as(usize, @intCast(index))];
}

pub export fn oc_syscall_entries_ptr() *const [syscall_entry_capacity]BaremetalSyscallEntry {
    return &syscall_entries;
}

pub export fn oc_syscall_enabled() bool {
    return syscall_state.enabled == abi.syscall_state_enabled;
}

pub export fn oc_syscall_reset() void {
    @memset(&syscall_entries, std.mem.zeroes(BaremetalSyscallEntry));
    syscall_state = .{
        .enabled = abi.syscall_state_enabled,
        .entry_count = 0,
        .reserved0 = 0,
        .last_syscall_id = 0,
        .dispatch_count = 0,
        .last_invoke_tick = 0,
        .last_result = 0,
    };
}

pub export fn oc_timer_state_ptr() *const BaremetalTimerState {
    return &timer_state;
}

pub export fn oc_timer_enabled() bool {
    return timer_state.enabled == abi.timer_state_enabled;
}

pub export fn oc_timer_quantum() u32 {
    return timer_state.tick_quantum;
}

pub export fn oc_timer_entry_capacity() u32 {
    return @as(u32, timer_capacity);
}

pub export fn oc_timer_entry_count() u32 {
    return timer_state.timer_count;
}

pub export fn oc_timer_fire_total_count() u64 {
    var total: u64 = 0;
    for (timer_entries) |entry| {
        total +%= entry.fire_count;
    }
    return total;
}

pub export fn oc_timer_entry(index: u32) BaremetalTimerEntry {
    if (index >= @as(u32, timer_capacity)) return std.mem.zeroes(BaremetalTimerEntry);
    return timer_entries[@as(usize, @intCast(index))];
}

pub export fn oc_timer_entries_ptr() *const [timer_capacity]BaremetalTimerEntry {
    return &timer_entries;
}

pub export fn oc_wake_queue_capacity() u32 {
    return @as(u32, wake_queue_capacity);
}

pub export fn oc_wake_queue_len() u32 {
    return wake_queue_count;
}

pub export fn oc_wake_queue_head_index() u32 {
    return wake_queue_head;
}

pub export fn oc_wake_queue_tail_index() u32 {
    return wake_queue_tail;
}

pub export fn oc_wake_queue_overflow_count() u32 {
    return wake_queue_overflow;
}

pub export fn oc_wake_queue_ptr() *const [wake_queue_capacity]BaremetalWakeEvent {
    return &wake_queue;
}

pub export fn oc_wake_queue_event(index: u32) BaremetalWakeEvent {
    if (index >= wake_queue_count) {
        return std.mem.zeroes(BaremetalWakeEvent);
    }
    const cap_u32: u32 = @as(u32, wake_queue_capacity);
    const pos = @mod(wake_queue_tail + index, cap_u32);
    return wake_queue[pos];
}

pub export fn oc_wake_queue_reason_count(reason: u8) u32 {
    if (!abi.wakeReasonIsValid(reason)) return 0;
    var count: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.reason == reason) count +%= 1;
    }
    return count;
}

pub export fn oc_wake_queue_vector_count(vector: u8) u32 {
    var count: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.vector == vector) count +%= 1;
    }
    return count;
}

pub export fn oc_wake_queue_before_tick_count(max_tick: u64) u32 {
    var count: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.tick <= max_tick) count +%= 1;
    }
    return count;
}

pub export fn oc_wake_queue_reason_vector_count(reason: u8, vector: u8) u32 {
    if (!abi.wakeReasonIsValid(reason)) return 0;
    var count: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.reason == reason and event.vector == vector) count +%= 1;
    }
    return count;
}

pub export fn oc_wake_queue_summary() BaremetalWakeQueueSummary {
    var summary: BaremetalWakeQueueSummary = .{
        .len = wake_queue_count,
        .overflow_count = wake_queue_overflow,
        .reason_timer_count = 0,
        .reason_interrupt_count = 0,
        .reason_manual_count = 0,
        .nonzero_vector_count = 0,
        .stale_count = 0,
        .reserved0 = 0,
        .oldest_tick = 0,
        .newest_tick = 0,
    };
    if (wake_queue_count == 0) return summary;

    summary.oldest_tick = oc_wake_queue_event(0).tick;
    summary.newest_tick = summary.oldest_tick;

    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        switch (event.reason) {
            abi.wake_reason_timer => summary.reason_timer_count +%= 1,
            abi.wake_reason_interrupt => summary.reason_interrupt_count +%= 1,
            abi.wake_reason_manual => summary.reason_manual_count +%= 1,
            else => {},
        }
        if (event.vector != 0) summary.nonzero_vector_count +%= 1;
        if (event.tick <= status.ticks) summary.stale_count +%= 1;
        if (event.tick < summary.oldest_tick) summary.oldest_tick = event.tick;
        if (event.tick > summary.newest_tick) summary.newest_tick = event.tick;
    }
    return summary;
}

pub export fn oc_wake_queue_age_buckets(quantum_ticks: u64) BaremetalWakeQueueAgeBuckets {
    const current_tick = status.ticks;
    const threshold_tick = if (quantum_ticks > current_tick) @as(u64, 0) else current_tick - quantum_ticks;
    var buckets: BaremetalWakeQueueAgeBuckets = .{
        .current_tick = current_tick,
        .quantum_ticks = quantum_ticks,
        .stale_count = 0,
        .stale_older_than_quantum_count = 0,
        .future_count = 0,
        .reserved0 = 0,
    };
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.tick <= current_tick) {
            buckets.stale_count +%= 1;
            if (event.tick <= threshold_tick) buckets.stale_older_than_quantum_count +%= 1;
        } else {
            buckets.future_count +%= 1;
        }
    }
    return buckets;
}

pub export fn oc_wake_queue_summary_ptr() *const BaremetalWakeQueueSummary {
    wake_queue_summary_snapshot = oc_wake_queue_summary();
    return &wake_queue_summary_snapshot;
}

pub export fn oc_wake_queue_age_buckets_ptr(quantum_ticks: u64) *const BaremetalWakeQueueAgeBuckets {
    wake_queue_age_buckets_snapshot = oc_wake_queue_age_buckets(quantum_ticks);
    return &wake_queue_age_buckets_snapshot;
}

pub export fn oc_wake_queue_age_buckets_ptr_quantum_2() *const BaremetalWakeQueueAgeBuckets {
    return oc_wake_queue_age_buckets_ptr(2);
}

pub export fn oc_wake_queue_pop() BaremetalWakeEvent {
    return wakeQueuePopOne() orelse std.mem.zeroes(BaremetalWakeEvent);
}

pub export fn oc_wake_queue_clear() void {
    @memset(&wake_queue, std.mem.zeroes(BaremetalWakeEvent));
    wake_queue_count = 0;
    wake_queue_head = 0;
    wake_queue_tail = 0;
    wake_queue_overflow = 0;
    wake_queue_seq = 0;
    timer_state.pending_wake_count = 0;
}

pub export fn oc_timer_reset() void {
    @memset(&timer_entries, std.mem.zeroes(BaremetalTimerEntry));
    timer_state = .{
        .enabled = abi.timer_state_enabled,
        .timer_count = 0,
        .pending_wake_count = 0,
        .next_timer_id = 1,
        .dispatch_count = 0,
        .last_dispatch_tick = status.ticks,
        .last_interrupt_count = x86_bootstrap.oc_interrupt_count(),
        .last_wake_tick = 0,
        .tick_quantum = 1,
        .reserved0 = 0,
    };
    oc_wake_queue_clear();
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
    timerTick(status.ticks);
    schedulerTick(status.ticks);
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

fn baremetalStart() callconv(.c) noreturn {
    if (qemu_smoke_enabled) {
        qemuExit(qemu_boot_ok_code);
    }
    setBootPhase(abi.boot_phase_init, abi.boot_phase_change_reason_boot);
    x86_bootstrap.init();
    _ = x86_bootstrap.oc_try_load_descriptor_tables();
    const previous_mode = status.mode;
    status.mode = abi.mode_running;
    recordMode(previous_mode, status.mode, abi.mode_change_reason_boot, status.ticks, status.command_seq_ack);
    setBootPhase(abi.boot_phase_runtime, abi.boot_phase_change_reason_boot);
    while (true) {
        oc_tick();
        spinPause(100_000);
    }
}

comptime {
    if (!builtin.is_test) {
        @export(&baremetalStart, .{ .name = "_start" });
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
    recordCommandResult(status.command_seq_ack, command_mailbox.opcode, status.last_command_result);
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
            oc_command_result_counters_clear();
            oc_scheduler_reset();
            oc_allocator_reset();
            oc_syscall_reset();
            oc_timer_reset();
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
        abi.command_reset_command_result_counters => {
            oc_command_result_counters_clear();
            return abi.result_ok;
        },
        abi.command_scheduler_enable => {
            scheduler_state.enabled = abi.scheduler_state_enabled;
            if (scheduler_state.running_slot == scheduler_no_slot) {
                scheduler_state.running_slot = scheduler_rr_cursor;
            }
            return abi.result_ok;
        },
        abi.command_scheduler_disable => {
            scheduler_state.enabled = abi.scheduler_state_disabled;
            scheduler_state.running_slot = scheduler_no_slot;
            return abi.result_ok;
        },
        abi.command_scheduler_reset => {
            oc_scheduler_reset();
            return abi.result_ok;
        },
        abi.command_task_create => {
            const budget = if (arg0 == 0) scheduler_state.default_budget_ticks else blk: {
                if (arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
                break :blk @as(u32, @truncate(arg0));
            };
            if (budget == 0) return abi.result_invalid_argument;
            const priority = if (arg1 > std.math.maxInt(u8)) @as(u8, 0) else @as(u8, @truncate(arg1));
            if (!schedulerCreateTask(budget, priority, status.ticks)) return abi.result_no_space;
            return abi.result_ok;
        },
        abi.command_task_terminate => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            const task_id: u32 = @as(u32, @truncate(arg0));
            if (!schedulerTerminateTask(task_id)) return abi.result_not_found;
            return abi.result_ok;
        },
        abi.command_task_wait => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            if (!schedulerSetTaskWaiting(@as(u32, @truncate(arg0)))) return abi.result_not_found;
            return abi.result_ok;
        },
        abi.command_task_wait_interrupt => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32) or arg1 > abi.wait_interrupt_any_vector) {
                return abi.result_invalid_argument;
            }
            if (arg1 == abi.wait_interrupt_any_vector) {
                if (!schedulerSetTaskWaitingInterrupt(@as(u32, @truncate(arg0)), null)) return abi.result_not_found;
            } else {
                if (!schedulerSetTaskWaitingInterrupt(@as(u32, @truncate(arg0)), @as(u8, @truncate(arg1)))) {
                    return abi.result_not_found;
                }
            }
            return abi.result_ok;
        },
        abi.command_task_wait_interrupt_for => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32) or arg1 == 0 or arg1 > std.math.maxInt(u32)) {
                return abi.result_invalid_argument;
            }
            if (!schedulerSetTaskWaitingInterruptFor(@as(u32, @truncate(arg0)), @as(u32, @truncate(arg1)), status.ticks)) {
                return abi.result_not_found;
            }
            return abi.result_ok;
        },
        abi.command_task_wait_for => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32) or arg1 == 0 or arg1 > std.math.maxInt(u32)) {
                return abi.result_invalid_argument;
            }
            return timerScheduleTask(@as(u32, @truncate(arg0)), @as(u32, @truncate(arg1)), 0, status.ticks);
        },
        abi.command_task_resume => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            if (!schedulerWakeTask(@as(u32, @truncate(arg0)), abi.wake_reason_manual, 0, 0, status.ticks)) {
                return abi.result_not_found;
            }
            return abi.result_ok;
        },
        abi.command_scheduler_set_timeslice => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            scheduler_state.timeslice_ticks = @as(u32, @truncate(arg0));
            return abi.result_ok;
        },
        abi.command_scheduler_set_default_budget => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            scheduler_state.default_budget_ticks = @as(u32, @truncate(arg0));
            return abi.result_ok;
        },
        abi.command_scheduler_set_policy => {
            if (arg0 > std.math.maxInt(u8)) return abi.result_invalid_argument;
            const policy: u8 = @as(u8, @truncate(arg0));
            if (!abi.schedulerPolicyIsValid(policy)) return abi.result_invalid_argument;
            scheduler_policy = policy;
            return abi.result_ok;
        },
        abi.command_task_set_priority => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32) or arg1 > std.math.maxInt(u8)) return abi.result_invalid_argument;
            if (!schedulerSetTaskPriority(@as(u32, @truncate(arg0)), @as(u8, @truncate(arg1)))) {
                return abi.result_not_found;
            }
            return abi.result_ok;
        },
        abi.command_allocator_reset => {
            oc_allocator_reset();
            return abi.result_ok;
        },
        abi.command_allocator_alloc => {
            if (arg0 == 0) return abi.result_invalid_argument;
            const size_bytes: u64 = arg0;
            const alignment: u64 = if (arg1 == 0) allocator_state.page_size else arg1;
            if (!std.math.isPowerOfTwo(alignment)) return abi.result_invalid_argument;
            const ptr = allocatorAlloc(size_bytes, alignment, status.ticks) orelse return abi.result_no_space;
            allocator_state.last_alloc_ptr = ptr;
            allocator_state.last_alloc_size = size_bytes;
            return abi.result_ok;
        },
        abi.command_allocator_free => {
            if (arg0 == 0) return abi.result_invalid_argument;
            const free_result = allocatorFree(arg0, arg1, status.ticks);
            if (free_result == abi.result_ok) {
                allocator_state.last_free_ptr = arg0;
                allocator_state.last_free_size = if (arg1 == 0) allocator_state.last_free_size else arg1;
            }
            return free_result;
        },
        abi.command_syscall_register => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            return syscallRegister(@as(u32, @truncate(arg0)), arg1);
        },
        abi.command_syscall_unregister => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            return syscallUnregister(@as(u32, @truncate(arg0)));
        },
        abi.command_syscall_invoke => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            return syscallInvoke(@as(u32, @truncate(arg0)), arg1, status.ticks);
        },
        abi.command_syscall_reset => {
            oc_syscall_reset();
            return abi.result_ok;
        },
        abi.command_syscall_enable => {
            syscall_state.enabled = abi.syscall_state_enabled;
            return abi.result_ok;
        },
        abi.command_syscall_disable => {
            syscall_state.enabled = abi.syscall_state_disabled;
            return abi.result_ok;
        },
        abi.command_syscall_set_flags => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32) or arg1 > std.math.maxInt(u8)) {
                return abi.result_invalid_argument;
            }
            return syscallSetFlags(@as(u32, @truncate(arg0)), @as(u8, @truncate(arg1)));
        },
        abi.command_timer_reset => {
            oc_timer_reset();
            return abi.result_ok;
        },
        abi.command_timer_schedule => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32) or arg1 == 0 or arg1 > std.math.maxInt(u32)) {
                return abi.result_invalid_argument;
            }
            return timerScheduleTask(@as(u32, @truncate(arg0)), @as(u32, @truncate(arg1)), 0, status.ticks);
        },
        abi.command_timer_schedule_periodic => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32) or arg1 == 0 or arg1 > std.math.maxInt(u32)) {
                return abi.result_invalid_argument;
            }
            return timerScheduleTask(@as(u32, @truncate(arg0)), @as(u32, @truncate(arg1)), @as(u32, @truncate(arg1)), status.ticks);
        },
        abi.command_timer_cancel => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            return timerCancel(@as(u32, @truncate(arg0)));
        },
        abi.command_timer_cancel_task => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            return timerCancelTask(@as(u32, @truncate(arg0)));
        },
        abi.command_timer_enable => {
            timer_state.enabled = abi.timer_state_enabled;
            timer_state.last_interrupt_count = x86_bootstrap.oc_interrupt_count();
            return abi.result_ok;
        },
        abi.command_timer_disable => {
            timer_state.enabled = abi.timer_state_disabled;
            return abi.result_ok;
        },
        abi.command_timer_set_quantum => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            timer_state.tick_quantum = @as(u32, @truncate(arg0));
            return abi.result_ok;
        },
        abi.command_wake_queue_clear => {
            oc_wake_queue_clear();
            return abi.result_ok;
        },
        abi.command_wake_queue_pop => {
            if (arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            if (!wakeQueuePopMany(@as(u32, @truncate(arg0)))) return abi.result_not_found;
            return abi.result_ok;
        },
        abi.command_wake_queue_pop_reason => {
            if (arg0 > std.math.maxInt(u8) or arg1 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            const reason: u8 = @as(u8, @truncate(arg0));
            if (!abi.wakeReasonIsValid(reason)) return abi.result_invalid_argument;
            if (!wakeQueuePopReason(reason, @as(u32, @truncate(arg1)))) return abi.result_not_found;
            return abi.result_ok;
        },
        abi.command_wake_queue_pop_vector => {
            if (arg0 > std.math.maxInt(u8) or arg1 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            const vector: u8 = @as(u8, @truncate(arg0));
            if (!wakeQueuePopVector(vector, @as(u32, @truncate(arg1)))) return abi.result_not_found;
            return abi.result_ok;
        },
        abi.command_wake_queue_pop_before_tick => {
            if (arg1 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            if (!wakeQueuePopBeforeTick(arg0, @as(u32, @truncate(arg1)))) return abi.result_not_found;
            return abi.result_ok;
        },
        abi.command_wake_queue_pop_reason_vector => {
            if (arg0 > 0xFFFF or arg1 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            const reason: u8 = @as(u8, @truncate(arg0 & 0xFF));
            const vector: u8 = @as(u8, @truncate((arg0 >> 8) & 0xFF));
            if (!abi.wakeReasonIsValid(reason)) return abi.result_invalid_argument;
            if (!wakeQueuePopReasonVector(reason, vector, @as(u32, @truncate(arg1)))) return abi.result_not_found;
            return abi.result_ok;
        },
        abi.command_interrupt_mask_set => {
            if (arg0 > std.math.maxInt(u8) or arg1 > 1) return abi.result_invalid_argument;
            x86_bootstrap.oc_interrupt_mask_set(@as(u8, @truncate(arg0)), arg1 == 1);
            return abi.result_ok;
        },
        abi.command_interrupt_mask_clear_all => {
            x86_bootstrap.oc_interrupt_mask_clear_all();
            return abi.result_ok;
        },
        abi.command_interrupt_mask_reset_ignored_counts => {
            if (arg0 != 0 or arg1 != 0) return abi.result_invalid_argument;
            x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();
            return abi.result_ok;
        },
        abi.command_interrupt_mask_apply_profile => {
            if (arg0 > std.math.maxInt(u8) or arg1 != 0) return abi.result_invalid_argument;
            if (!x86_bootstrap.oc_interrupt_mask_apply_profile(@as(u8, @truncate(arg0)))) {
                return abi.result_invalid_argument;
            }
            return abi.result_ok;
        },
        abi.command_scheduler_wake_task => {
            if (arg0 == 0 or arg0 > std.math.maxInt(u32)) return abi.result_invalid_argument;
            if (!schedulerWakeTask(@as(u32, @truncate(arg0)), abi.wake_reason_manual, 0, 0, status.ticks)) {
                return abi.result_not_found;
            }
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

fn recordCommandResult(seq: u32, opcode: u16, result: i16) void {
    command_result_counters.total_count +%= 1;
    command_result_counters.last_result = result;
    command_result_counters.last_opcode = opcode;
    command_result_counters.last_seq = seq;
    switch (result) {
        abi.result_ok => command_result_counters.ok_count +%= 1,
        abi.result_invalid_argument => command_result_counters.invalid_argument_count +%= 1,
        abi.result_not_supported => command_result_counters.not_supported_count +%= 1,
        else => command_result_counters.other_error_count +%= 1,
    }
}

fn timerTick(current_tick: u64) void {
    if (timer_state.enabled != abi.timer_state_enabled) return;

    const interrupt_count = x86_bootstrap.oc_interrupt_count();
    if (interrupt_count > timer_state.last_interrupt_count) {
        const interrupt_vector = x86_bootstrap.oc_last_interrupt_vector();
        var remaining = interrupt_count - timer_state.last_interrupt_count;
        while (remaining > 0) : (remaining -= 1) {
            if (!schedulerWakeNextWaiting(abi.wake_reason_interrupt, 0, interrupt_vector, current_tick, interrupt_count)) {
                break;
            }
        }
    }
    timer_state.last_interrupt_count = interrupt_count;

    var slot_idx: usize = 0;
    while (slot_idx < scheduler_task_capacity) : (slot_idx += 1) {
        if (scheduler_tasks[slot_idx].state != abi.task_state_waiting) continue;
        const kind = scheduler_wait_kind[slot_idx];
        if (kind != wait_condition_interrupt_any and kind != wait_condition_interrupt_vector) continue;
        const deadline = scheduler_wait_timeout_tick[slot_idx];
        if (deadline == 0 or deadline > current_tick) continue;
        _ = schedulerWakeTask(scheduler_tasks[slot_idx].task_id, abi.wake_reason_timer, 0, 0, current_tick);
    }

    const quantum = if (timer_state.tick_quantum == 0) @as(u32, 1) else timer_state.tick_quantum;
    if (@mod(current_tick, @as(u64, quantum)) != 0) {
        timerRecountEntries();
        return;
    }

    for (&timer_entries) |*entry| {
        if (entry.state != abi.timer_entry_state_armed) continue;
        if (entry.next_fire_tick > current_tick) continue;
        const periodic = entry.period_ticks > 0;
        if (periodic) {
            entry.flags |= abi.timer_entry_flag_periodic;
        } else {
            entry.flags &= ~abi.timer_entry_flag_periodic;
        }
        entry.fire_count +%= 1;
        entry.last_fire_tick = current_tick;
        timer_state.dispatch_count +%= 1;
        timer_state.last_dispatch_tick = current_tick;
        const woke = schedulerWakeTask(entry.task_id, abi.wake_reason_timer, entry.timer_id, 0, current_tick);
        if (periodic and woke) {
            entry.next_fire_tick = advancePeriodicTickSaturating(entry.next_fire_tick, entry.period_ticks, current_tick);
            entry.state = abi.timer_entry_state_armed;
        } else if (periodic and !woke) {
            entry.state = abi.timer_entry_state_canceled;
        } else {
            entry.state = abi.timer_entry_state_fired;
        }
    }
    timerRecountEntries();
}

fn timerRecountEntries() void {
    var count: u8 = 0;
    for (timer_entries) |entry| {
        if (entry.state == abi.timer_entry_state_armed) count +%= 1;
    }
    timer_state.timer_count = count;
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
}

fn timerScheduleTask(task_id: u32, delay_ticks: u32, period_ticks: u32, current_tick: u64) i16 {
    if (timer_state.enabled != abi.timer_state_enabled) return abi.result_not_supported;
    const slot = schedulerFindTaskSlot(task_id) orelse return abi.result_not_found;
    if (scheduler_tasks[slot].state == abi.task_state_terminated or scheduler_tasks[slot].state == abi.task_state_completed) {
        return abi.result_invalid_argument;
    }
    if (period_ticks > 0 and period_ticks < delay_ticks) return abi.result_invalid_argument;

    for (&timer_entries) |*entry| {
        if (entry.state == abi.timer_entry_state_armed and entry.task_id == task_id) {
            entry.next_fire_tick = current_tick + delay_ticks;
            entry.period_ticks = period_ticks;
            if (period_ticks > 0) {
                entry.flags |= abi.timer_entry_flag_periodic;
            } else {
                entry.flags &= ~abi.timer_entry_flag_periodic;
            }
            scheduler_tasks[slot].state = abi.task_state_waiting;
            schedulerSetWaitCondition(slot, wait_condition_timer, 0);
            schedulerRecountTasks();
            return abi.result_ok;
        }
    }

    for (&timer_entries) |*entry| {
        if (entry.state != abi.timer_entry_state_unused and entry.state != abi.timer_entry_state_fired and entry.state != abi.timer_entry_state_canceled) {
            continue;
        }
        entry.* = .{
            .timer_id = timer_state.next_timer_id,
            .task_id = task_id,
            .state = abi.timer_entry_state_armed,
            .reason = abi.wake_reason_timer,
            .flags = if (period_ticks > 0) abi.timer_entry_flag_periodic else 0,
            .period_ticks = period_ticks,
            .next_fire_tick = addTicksSaturating(current_tick, delay_ticks),
            .fire_count = 0,
            .last_fire_tick = 0,
        };
        timer_state.next_timer_id +%= 1;
        scheduler_tasks[slot].state = abi.task_state_waiting;
        schedulerSetWaitCondition(slot, wait_condition_timer, 0);
        schedulerRecountTasks();
        timerRecountEntries();
        return abi.result_ok;
    }
    return abi.result_no_space;
}

fn timerCancel(timer_id: u32) i16 {
    for (&timer_entries) |*entry| {
        if (entry.state == abi.timer_entry_state_armed and entry.timer_id == timer_id) {
            const task_id = entry.task_id;
            entry.state = abi.timer_entry_state_canceled;
            if (!timerTaskHasArmedEntries(task_id)) {
                if (schedulerFindTaskSlot(task_id)) |slot| {
                    if (scheduler_tasks[slot].state == abi.task_state_waiting and scheduler_wait_kind[slot] == wait_condition_timer) {
                        schedulerSetWaitCondition(slot, wait_condition_manual, 0);
                    }
                }
            }
            timerRecountEntries();
            return abi.result_ok;
        }
    }
    return abi.result_not_found;
}

fn timerCancelTask(task_id: u32) i16 {
    var canceled_any = false;
    for (&timer_entries) |*entry| {
        if (entry.state == abi.timer_entry_state_armed and entry.task_id == task_id) {
            entry.state = abi.timer_entry_state_canceled;
            canceled_any = true;
        }
    }
    if (!canceled_any) return abi.result_not_found;
    if (schedulerFindTaskSlot(task_id)) |slot| {
        if (scheduler_tasks[slot].state == abi.task_state_waiting and scheduler_wait_kind[slot] == wait_condition_timer) {
            schedulerSetWaitCondition(slot, wait_condition_manual, 0);
        }
    }
    timerRecountEntries();
    return abi.result_ok;
}

fn timerTaskHasArmedEntries(task_id: u32) bool {
    for (timer_entries) |entry| {
        if (entry.state == abi.timer_entry_state_armed and entry.task_id == task_id) return true;
    }
    return false;
}

fn wakeQueuePush(task_id: u32, timer_id: u32, reason: u8, vector: u8, tick: u64, interrupt_count: u64) void {
    const cap_u32: u32 = @as(u32, wake_queue_capacity);
    const write_index = wake_queue_head;
    wake_queue_seq +%= 1;
    wake_queue[write_index] = .{
        .seq = wake_queue_seq,
        .task_id = task_id,
        .timer_id = timer_id,
        .reason = reason,
        .vector = vector,
        .reserved0 = 0,
        .tick = tick,
        .interrupt_count = interrupt_count,
    };
    wake_queue_head = @mod(wake_queue_head + 1, cap_u32);
    if (wake_queue_count < cap_u32) {
        wake_queue_count += 1;
    } else {
        wake_queue_tail = @mod(wake_queue_tail + 1, cap_u32);
        wake_queue_overflow +%= 1;
    }
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
}

fn wakeQueuePopOne() ?BaremetalWakeEvent {
    if (wake_queue_count == 0) return null;
    const cap_u32: u32 = @as(u32, wake_queue_capacity);
    const read_index = wake_queue_tail;
    const event = wake_queue[read_index];
    wake_queue[read_index] = std.mem.zeroes(BaremetalWakeEvent);
    wake_queue_tail = @mod(wake_queue_tail + 1, cap_u32);
    wake_queue_count -= 1;
    if (wake_queue_count == 0) {
        wake_queue_head = wake_queue_tail;
    }
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
    return event;
}

fn wakeQueuePopMany(requested: u32) bool {
    if (wake_queue_count == 0) return false;
    var to_pop = if (requested == 0) @as(u32, 1) else requested;
    if (to_pop > wake_queue_count) to_pop = wake_queue_count;
    while (to_pop > 0) : (to_pop -= 1) {
        _ = wakeQueuePopOne();
    }
    return true;
}

fn wakeQueuePopReason(reason: u8, requested: u32) bool {
    if (wake_queue_count == 0) return false;

    const available = oc_wake_queue_reason_count(reason);
    if (available == 0) return false;

    var to_pop = if (requested == 0) @as(u32, 1) else requested;
    if (to_pop > available) to_pop = available;

    var kept: [wake_queue_capacity]BaremetalWakeEvent = std.mem.zeroes([wake_queue_capacity]BaremetalWakeEvent);
    var kept_count: u32 = 0;
    var removed: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.reason == reason and removed < to_pop) {
            removed += 1;
            continue;
        }
        kept[kept_count] = event;
        kept_count += 1;
    }
    if (removed == 0) return false;

    @memset(&wake_queue, std.mem.zeroes(BaremetalWakeEvent));
    var write_idx: u32 = 0;
    while (write_idx < kept_count) : (write_idx += 1) {
        wake_queue[@as(usize, @intCast(write_idx))] = kept[write_idx];
    }
    wake_queue_tail = 0;
    wake_queue_count = kept_count;
    wake_queue_head = if (kept_count == 0) 0 else @mod(kept_count, @as(u32, wake_queue_capacity));
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
    return true;
}

fn wakeQueuePopVector(vector: u8, requested: u32) bool {
    if (wake_queue_count == 0) return false;

    const available = oc_wake_queue_vector_count(vector);
    if (available == 0) return false;

    var to_pop = if (requested == 0) @as(u32, 1) else requested;
    if (to_pop > available) to_pop = available;

    var kept: [wake_queue_capacity]BaremetalWakeEvent = std.mem.zeroes([wake_queue_capacity]BaremetalWakeEvent);
    var kept_count: u32 = 0;
    var removed: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.vector == vector and removed < to_pop) {
            removed += 1;
            continue;
        }
        kept[kept_count] = event;
        kept_count += 1;
    }
    if (removed == 0) return false;

    @memset(&wake_queue, std.mem.zeroes(BaremetalWakeEvent));
    var write_idx: u32 = 0;
    while (write_idx < kept_count) : (write_idx += 1) {
        wake_queue[@as(usize, @intCast(write_idx))] = kept[write_idx];
    }
    wake_queue_tail = 0;
    wake_queue_count = kept_count;
    wake_queue_head = if (kept_count == 0) 0 else @mod(kept_count, @as(u32, wake_queue_capacity));
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
    return true;
}

fn wakeQueuePopBeforeTick(max_tick: u64, requested: u32) bool {
    if (wake_queue_count == 0) return false;

    const available = oc_wake_queue_before_tick_count(max_tick);
    if (available == 0) return false;

    var to_pop = if (requested == 0) @as(u32, 1) else requested;
    if (to_pop > available) to_pop = available;

    var kept: [wake_queue_capacity]BaremetalWakeEvent = std.mem.zeroes([wake_queue_capacity]BaremetalWakeEvent);
    var kept_count: u32 = 0;
    var removed: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.tick <= max_tick and removed < to_pop) {
            removed += 1;
            continue;
        }
        kept[kept_count] = event;
        kept_count += 1;
    }
    if (removed == 0) return false;

    @memset(&wake_queue, std.mem.zeroes(BaremetalWakeEvent));
    var write_idx: u32 = 0;
    while (write_idx < kept_count) : (write_idx += 1) {
        wake_queue[@as(usize, @intCast(write_idx))] = kept[write_idx];
    }
    wake_queue_tail = 0;
    wake_queue_count = kept_count;
    wake_queue_head = if (kept_count == 0) 0 else @mod(kept_count, @as(u32, wake_queue_capacity));
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
    return true;
}

fn wakeQueuePopReasonVector(reason: u8, vector: u8, requested: u32) bool {
    if (wake_queue_count == 0) return false;

    const available = oc_wake_queue_reason_vector_count(reason, vector);
    if (available == 0) return false;

    var to_pop = if (requested == 0) @as(u32, 1) else requested;
    if (to_pop > available) to_pop = available;

    var kept: [wake_queue_capacity]BaremetalWakeEvent = std.mem.zeroes([wake_queue_capacity]BaremetalWakeEvent);
    var kept_count: u32 = 0;
    var removed: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.reason == reason and event.vector == vector and removed < to_pop) {
            removed += 1;
            continue;
        }
        kept[kept_count] = event;
        kept_count += 1;
    }
    if (removed == 0) return false;

    @memset(&wake_queue, std.mem.zeroes(BaremetalWakeEvent));
    var write_idx: u32 = 0;
    while (write_idx < kept_count) : (write_idx += 1) {
        wake_queue[@as(usize, @intCast(write_idx))] = kept[write_idx];
    }
    wake_queue_tail = 0;
    wake_queue_count = kept_count;
    wake_queue_head = if (kept_count == 0) 0 else @mod(kept_count, @as(u32, wake_queue_capacity));
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
    return true;
}

fn schedulerFindTaskSlot(task_id: u32) ?usize {
    var slot: usize = 0;
    while (slot < scheduler_task_capacity) : (slot += 1) {
        if (scheduler_tasks[slot].task_id == task_id and scheduler_tasks[slot].state != abi.task_state_unused) {
            return slot;
        }
    }
    return null;
}

fn schedulerSetWaitCondition(slot: usize, kind: u8, vector: u8) void {
    scheduler_wait_kind[slot] = kind;
    scheduler_wait_interrupt_vector[slot] = vector;
    scheduler_wait_timeout_tick[slot] = 0;
}

fn schedulerSetWaitConditionWithTimeout(slot: usize, kind: u8, vector: u8, deadline_tick: u64) void {
    scheduler_wait_kind[slot] = kind;
    scheduler_wait_interrupt_vector[slot] = vector;
    scheduler_wait_timeout_tick[slot] = deadline_tick;
}

fn schedulerSetTaskWaiting(task_id: u32) bool {
    const slot = schedulerFindTaskSlot(task_id) orelse return false;
    var task = &scheduler_tasks[slot];
    if (task.state == abi.task_state_unused or task.state == abi.task_state_terminated or task.state == abi.task_state_completed) {
        return false;
    }
    task.state = abi.task_state_waiting;
    schedulerSetWaitCondition(slot, wait_condition_manual, 0);
    schedulerRecountTasks();
    return true;
}

fn schedulerSetTaskWaitingInterrupt(task_id: u32, vector: ?u8) bool {
    const slot = schedulerFindTaskSlot(task_id) orelse return false;
    var task = &scheduler_tasks[slot];
    if (task.state == abi.task_state_unused or task.state == abi.task_state_terminated or task.state == abi.task_state_completed) {
        return false;
    }
    task.state = abi.task_state_waiting;
    if (vector) |v| {
        schedulerSetWaitCondition(slot, wait_condition_interrupt_vector, v);
    } else {
        schedulerSetWaitCondition(slot, wait_condition_interrupt_any, 0);
    }
    schedulerRecountTasks();
    return true;
}

fn schedulerSetTaskWaitingInterruptFor(task_id: u32, timeout_ticks: u32, current_tick: u64) bool {
    const slot = schedulerFindTaskSlot(task_id) orelse return false;
    var task = &scheduler_tasks[slot];
    if (task.state == abi.task_state_unused or task.state == abi.task_state_terminated or task.state == abi.task_state_completed) {
        return false;
    }
    task.state = abi.task_state_waiting;
    schedulerSetWaitConditionWithTimeout(slot, wait_condition_interrupt_any, 0, addTicksSaturating(current_tick, timeout_ticks));
    schedulerRecountTasks();
    return true;
}

fn addTicksSaturating(base_tick: u64, ticks: u32) u64 {
    const delta = @as(u64, ticks);
    const max_tick = std.math.maxInt(u64);
    if (delta > max_tick - base_tick) return max_tick;
    return base_tick + delta;
}

fn advancePeriodicTickSaturating(next_fire_tick: u64, period_ticks: u32, current_tick: u64) u64 {
    if (period_ticks == 0 or next_fire_tick > current_tick) return next_fire_tick;

    const period = @as(u64, period_ticks);
    const elapsed = current_tick - next_fire_tick;
    const periods = elapsed / period + 1;
    const max_tick = std.math.maxInt(u64);
    if (periods > (max_tick - next_fire_tick) / period) return max_tick;
    return next_fire_tick + periods * period;
}

fn schedulerSetTaskPriority(task_id: u32, priority: u8) bool {
    const slot = schedulerFindTaskSlot(task_id) orelse return false;
    var task = &scheduler_tasks[slot];
    if (task.state == abi.task_state_unused or task.state == abi.task_state_terminated or task.state == abi.task_state_completed) {
        return false;
    }
    task.priority = priority;
    return true;
}

fn schedulerWakeTask(task_id: u32, reason: u8, timer_id: u32, vector: u8, tick: u64) bool {
    const slot = schedulerFindTaskSlot(task_id) orelse return false;
    var task = &scheduler_tasks[slot];
    if (task.state == abi.task_state_terminated or task.state == abi.task_state_completed or task.state == abi.task_state_unused) {
        return false;
    }
    if (task.budget_remaining == 0) {
        task.budget_remaining = if (task.budget_ticks == 0) scheduler_state.default_budget_ticks else task.budget_ticks;
    }
    task.state = abi.task_state_ready;
    schedulerSetWaitCondition(slot, wait_condition_none, 0);
    timer_state.last_wake_tick = tick;
    wakeQueuePush(task.task_id, timer_id, reason, vector, tick, x86_bootstrap.oc_interrupt_count());
    schedulerRecountTasks();
    return true;
}

fn schedulerWakeNextWaiting(reason: u8, timer_id: u32, vector: u8, tick: u64, interrupt_count: u64) bool {
    var slot: usize = 0;
    while (slot < scheduler_task_capacity) : (slot += 1) {
        const task = &scheduler_tasks[slot];
        if (task.state != abi.task_state_waiting) continue;
        if (reason == abi.wake_reason_interrupt) {
            const kind = scheduler_wait_kind[slot];
            const allowed = kind == wait_condition_interrupt_any or
                (kind == wait_condition_interrupt_vector and scheduler_wait_interrupt_vector[slot] == vector);
            if (!allowed) continue;
        }
        if (task.budget_remaining == 0) {
            task.budget_remaining = if (task.budget_ticks == 0) scheduler_state.default_budget_ticks else task.budget_ticks;
        }
        task.state = abi.task_state_ready;
        schedulerSetWaitCondition(slot, wait_condition_none, 0);
        timer_state.last_wake_tick = tick;
        wakeQueuePush(task.task_id, timer_id, reason, vector, tick, interrupt_count);
        schedulerRecountTasks();
        return true;
    }
    return false;
}

fn schedulerTick(current_tick: u64) void {
    if (status.mode == abi.mode_panicked) {
        scheduler_state.running_slot = scheduler_no_slot;
        return;
    }
    if (scheduler_state.enabled != abi.scheduler_state_enabled) {
        scheduler_state.running_slot = scheduler_no_slot;
        return;
    }
    const selected_slot = schedulerSelectReadySlot() orelse {
        scheduler_state.running_slot = scheduler_no_slot;
        return;
    };
    scheduler_state.running_slot = selected_slot;
    scheduler_state.dispatch_count +%= 1;
    scheduler_state.last_dispatch_tick = current_tick;

    var task = &scheduler_tasks[selected_slot];
    task.state = abi.task_state_running;
    task.run_count +%= 1;
    task.last_run_tick = current_tick;

    const consume = if (scheduler_state.timeslice_ticks == 0) @as(u32, 1) else scheduler_state.timeslice_ticks;
    if (task.budget_remaining <= consume) {
        task.budget_remaining = 0;
        task.state = abi.task_state_completed;
    } else {
        task.budget_remaining -= consume;
        task.state = abi.task_state_ready;
    }
    schedulerRecountTasks();
}

fn schedulerSelectReadySlot() ?u8 {
    if (scheduler_state.task_count == 0) return null;
    const cap_u8: u8 = @as(u8, scheduler_task_capacity);
    if (scheduler_policy == abi.scheduler_policy_priority) {
        var scans_priority: u8 = 0;
        var best_slot: ?u8 = null;
        var best_priority: u8 = 0;
        while (scans_priority < cap_u8) : (scans_priority += 1) {
            const slot = @mod(scheduler_rr_cursor + scans_priority, cap_u8);
            scheduler_state.ready_scans +%= 1;
            const task = scheduler_tasks[slot];
            if (task.state != abi.task_state_ready or task.task_id == 0 or task.budget_remaining == 0) continue;
            if (best_slot == null or task.priority > best_priority) {
                best_slot = slot;
                best_priority = task.priority;
            }
        }
        if (best_slot) |slot| {
            scheduler_rr_cursor = @mod(slot + 1, cap_u8);
            return slot;
        }
        return null;
    }
    var scans: u8 = 0;
    while (scans < cap_u8) : (scans += 1) {
        const slot = @mod(scheduler_rr_cursor + scans, cap_u8);
        scheduler_state.ready_scans +%= 1;
        const task = scheduler_tasks[slot];
        if (task.state == abi.task_state_ready and task.task_id != 0 and task.budget_remaining > 0) {
            scheduler_rr_cursor = @mod(slot + 1, cap_u8);
            return slot;
        }
    }
    return null;
}

fn schedulerCreateTask(budget_ticks: u32, priority: u8, created_tick: u64) bool {
    var slot: usize = 0;
    while (slot < scheduler_task_capacity) : (slot += 1) {
        if (scheduler_tasks[slot].state == abi.task_state_unused or
            scheduler_tasks[slot].state == abi.task_state_completed or
            scheduler_tasks[slot].state == abi.task_state_terminated)
        {
            scheduler_tasks[slot] = .{
                .task_id = scheduler_state.next_task_id,
                .state = abi.task_state_ready,
                .priority = priority,
                .reserved0 = 0,
                .run_count = 0,
                .budget_ticks = budget_ticks,
                .budget_remaining = budget_ticks,
                .created_tick = created_tick,
                .last_run_tick = 0,
            };
            schedulerSetWaitCondition(slot, wait_condition_none, 0);
            scheduler_state.next_task_id +%= 1;
            schedulerRecountTasks();
            return true;
        }
    }
    return false;
}

fn schedulerTerminateTask(task_id: u32) bool {
    var slot: usize = 0;
    while (slot < scheduler_task_capacity) : (slot += 1) {
        var task = &scheduler_tasks[slot];
        if (task.task_id == task_id and task.state != abi.task_state_unused) {
            task.state = abi.task_state_terminated;
            task.budget_remaining = 0;
            schedulerSetWaitCondition(slot, wait_condition_none, 0);
            for (&timer_entries) |*entry| {
                if (entry.task_id == task_id and entry.state == abi.timer_entry_state_armed) {
                    entry.state = abi.timer_entry_state_canceled;
                }
            }
            timerRecountEntries();
            schedulerRecountTasks();
            return true;
        }
    }
    return false;
}

fn schedulerRecountTasks() void {
    var count: u8 = 0;
    for (scheduler_tasks) |task| {
        if (task.state == abi.task_state_ready or task.state == abi.task_state_running) {
            count +%= 1;
        }
    }
    scheduler_state.task_count = count;
    if (count == 0) {
        scheduler_state.running_slot = scheduler_no_slot;
    }
}

fn allocatorRequiredPages(size_bytes: u64) u32 {
    const page = @as(u64, allocator_state.page_size);
    return @as(u32, @intCast((size_bytes + page - 1) / page));
}

fn allocatorAlloc(size_bytes: u64, alignment: u64, tick: u64) ?u64 {
    const required_pages = allocatorRequiredPages(size_bytes);
    if (required_pages == 0) return null;
    if (required_pages > allocator_state.free_pages) return null;

    const required_len: usize = @as(usize, @intCast(required_pages));
    var start: usize = 0;
    while (start + required_len <= allocator_page_capacity) : (start += 1) {
        const ptr = allocator_state.heap_base + @as(u64, start) * allocator_state.page_size;
        if ((ptr & (alignment - 1)) != 0) continue;

        var fit = true;
        var off: usize = 0;
        while (off < required_len) : (off += 1) {
            if (allocator_page_bitmap[start + off] != 0) {
                fit = false;
                break;
            }
        }
        if (!fit) continue;

        var record_slot: ?usize = null;
        for (allocator_records, 0..) |record, idx| {
            if (record.state == abi.allocation_state_unused) {
                record_slot = idx;
                break;
            }
        }
        const slot = record_slot orelse return null;

        off = 0;
        while (off < required_len) : (off += 1) {
            allocator_page_bitmap[start + off] = 1;
        }

        allocator_records[slot] = .{
            .ptr = ptr,
            .size_bytes = size_bytes,
            .page_start = @as(u32, @intCast(start)),
            .page_len = required_pages,
            .state = abi.allocation_state_active,
            .reserved0 = std.mem.zeroes([7]u8),
            .created_tick = tick,
            .last_used_tick = tick,
        };

        allocator_state.free_pages -= required_pages;
        allocator_state.allocation_count +%= 1;
        allocator_state.alloc_ops +%= 1;
        allocator_state.bytes_in_use +%= size_bytes;
        if (allocator_state.bytes_in_use > allocator_state.peak_bytes_in_use) {
            allocator_state.peak_bytes_in_use = allocator_state.bytes_in_use;
        }
        return ptr;
    }
    return null;
}

fn allocatorFree(ptr: u64, expected_size: u64, tick: u64) i16 {
    for (&allocator_records) |*record| {
        if (record.state != abi.allocation_state_active) continue;
        if (record.ptr != ptr) continue;
        if (expected_size != 0 and expected_size != record.size_bytes) return abi.result_invalid_argument;

        const start: usize = @as(usize, @intCast(record.page_start));
        const len: usize = @as(usize, @intCast(record.page_len));
        var off: usize = 0;
        while (off < len) : (off += 1) {
            allocator_page_bitmap[start + off] = 0;
        }

        const freed_size = record.size_bytes;
        record.last_used_tick = tick;
        record.state = abi.allocation_state_unused;
        record.ptr = 0;
        record.size_bytes = 0;
        record.page_start = 0;
        record.page_len = 0;
        record.created_tick = 0;

        allocator_state.free_pages +%= @as(u32, @intCast(len));
        if (allocator_state.allocation_count > 0) allocator_state.allocation_count -= 1;
        allocator_state.free_ops +%= 1;
        if (allocator_state.bytes_in_use >= freed_size) {
            allocator_state.bytes_in_use -= freed_size;
        } else {
            allocator_state.bytes_in_use = 0;
        }
        allocator_state.last_free_size = freed_size;
        return abi.result_ok;
    }
    return abi.result_not_found;
}

fn syscallRecountEntries() void {
    var count: u8 = 0;
    for (syscall_entries) |entry| {
        if (entry.state == abi.syscall_entry_state_registered) count +%= 1;
    }
    syscall_state.entry_count = count;
}

fn syscallRegister(syscall_id: u32, handler_token: u64) i16 {
    if (handler_token == 0) return abi.result_invalid_argument;
    for (&syscall_entries) |*entry| {
        if (entry.state == abi.syscall_entry_state_registered and entry.syscall_id == syscall_id) {
            entry.handler_token = handler_token;
            return abi.result_ok;
        }
    }
    for (&syscall_entries) |*entry| {
        if (entry.state == abi.syscall_entry_state_unused) {
            entry.* = .{
                .syscall_id = syscall_id,
                .state = abi.syscall_entry_state_registered,
                .flags = 0,
                .reserved0 = 0,
                .handler_token = handler_token,
                .invoke_count = 0,
                .last_arg = 0,
                .last_result = 0,
            };
            syscallRecountEntries();
            return abi.result_ok;
        }
    }
    return abi.result_no_space;
}

fn syscallUnregister(syscall_id: u32) i16 {
    for (&syscall_entries) |*entry| {
        if (entry.state == abi.syscall_entry_state_registered and entry.syscall_id == syscall_id) {
            entry.* = std.mem.zeroes(BaremetalSyscallEntry);
            syscallRecountEntries();
            return abi.result_ok;
        }
    }
    return abi.result_not_found;
}

fn syscallSetFlags(syscall_id: u32, flags: u8) i16 {
    for (&syscall_entries) |*entry| {
        if (entry.state == abi.syscall_entry_state_registered and entry.syscall_id == syscall_id) {
            entry.flags = flags;
            return abi.result_ok;
        }
    }
    return abi.result_not_found;
}

fn syscallInvoke(syscall_id: u32, arg: u64, tick: u64) i16 {
    if (syscall_state.enabled != abi.syscall_state_enabled) return abi.result_not_supported;
    for (&syscall_entries) |*entry| {
        if (entry.state != abi.syscall_entry_state_registered or entry.syscall_id != syscall_id) continue;
        if ((entry.flags & abi.syscall_entry_flag_blocked) != 0) {
            return abi.result_conflict;
        }
        const id_u64: u64 = syscall_id;
        const result_u64 = entry.handler_token ^ arg ^ id_u64;
        const result_i64: i64 = @as(i64, @bitCast(result_u64));
        entry.invoke_count +%= 1;
        entry.last_arg = arg;
        entry.last_result = result_i64;
        syscall_state.last_syscall_id = syscall_id;
        syscall_state.dispatch_count +%= 1;
        syscall_state.last_invoke_tick = tick;
        syscall_state.last_result = result_i64;
        return abi.result_ok;
    }
    return abi.result_not_found;
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

fn resetBaremetalRuntimeForTest() void {
    status = .{
        .magic = abi.status_magic,
        .api_version = abi.api_version,
        .mode = abi.mode_running,
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
    command_mailbox = .{
        .magic = abi.command_magic,
        .api_version = abi.api_version,
        .opcode = abi.command_nop,
        .seq = 0,
        .arg0 = 0,
        .arg1 = 0,
    };
    resetBootDiagnostics();
    x86_bootstrap.oc_interrupt_mask_clear_all();
    x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_reset_exception_counters();
    x86_bootstrap.oc_reset_vector_counters();
    x86_bootstrap.oc_exception_history_clear();
    x86_bootstrap.oc_interrupt_history_clear();
    oc_command_history_clear();
    oc_health_history_clear();
    oc_mode_history_clear();
    oc_boot_phase_history_clear();
    oc_command_result_counters_clear();
    oc_scheduler_reset();
    oc_allocator_reset();
    oc_syscall_reset();
    oc_timer_reset();
    oc_wake_queue_clear();
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
    asm volatile ("outb %[al], %[dx]"
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
    oc_command_result_counters_clear();
    oc_scheduler_reset();

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
    oc_command_result_counters_clear();
    oc_scheduler_reset();

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
    oc_command_result_counters_clear();
    oc_scheduler_reset();

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
    oc_command_result_counters_clear();
    oc_scheduler_reset();

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
    oc_command_result_counters_clear();
    oc_scheduler_reset();

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

test "baremetal command result counters track categories and reset flow" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_command_result_counters_clear();
    oc_command_history_clear();
    oc_mode_history_clear();
    oc_boot_phase_history_clear();
    oc_health_history_clear();
    oc_scheduler_reset();

    _ = oc_submit_command(abi.command_set_health_code, 123, 0); // ok
    oc_tick();
    _ = oc_submit_command(abi.command_set_mode, 77, 0); // invalid argument
    oc_tick();
    _ = oc_submit_command(65535, 0, 0); // not supported
    oc_tick();

    try std.testing.expectEqual(@as(u32, 3), oc_command_result_total_count());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_ok());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_invalid_argument());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_not_supported());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_other_error());
    const counters = oc_command_result_counters_ptr().*;
    try std.testing.expectEqual(@as(i16, abi.result_not_supported), counters.last_result);
    try std.testing.expectEqual(@as(u16, 65535), counters.last_opcode);
    try std.testing.expectEqual(status.command_seq_ack, counters.last_seq);

    _ = oc_submit_command(abi.command_reset_command_result_counters, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_total_count());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_ok());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_invalid_argument());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_not_supported());
    const reset_counters = oc_command_result_counters_ptr().*;
    try std.testing.expectEqual(@as(u16, abi.command_reset_command_result_counters), reset_counters.last_opcode);
}

test "baremetal reset counters clears representative runtime subsystems" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.last_health_code = 0;
    status.panic_count = 0;
    status.command_seq_ack = 0;
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
    x86_bootstrap.init();
    x86_bootstrap.oc_interrupt_mask_clear_all();
    x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_reset_exception_counters();
    x86_bootstrap.oc_reset_vector_counters();
    x86_bootstrap.oc_exception_history_clear();
    x86_bootstrap.oc_interrupt_history_clear();
    oc_command_history_clear();
    oc_health_history_clear();
    oc_mode_history_clear();
    oc_boot_phase_history_clear();
    oc_command_result_counters_clear();
    oc_scheduler_reset();
    oc_allocator_reset();
    oc_syscall_reset();
    oc_timer_reset();

    _ = oc_submit_command(abi.command_set_health_code, 123, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_panic_flag, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_mode, abi.mode_running, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_runtime, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 8, 2);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);
    _ = oc_submit_command(abi.command_allocator_alloc, 4096, 4096);
    oc_tick();
    _ = oc_submit_command(abi.command_syscall_register, 9, 0xBEEF);
    oc_tick();
    _ = oc_submit_command(abi.command_timer_set_quantum, 3, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_timer_schedule, task_id, 20);
    oc_tick();
    _ = oc_submit_command(abi.command_task_wait_interrupt, task_id, 200);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_exception, 13, 0xCAFE);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 1), status.panic_count);
    try std.testing.expect(x86_bootstrap.oc_interrupt_count() > 0);
    try std.testing.expect(x86_bootstrap.oc_exception_count() > 0);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_vector_count(13));
    try std.testing.expect(x86_bootstrap.oc_interrupt_history_len() >= 2);
    try std.testing.expect(x86_bootstrap.oc_exception_history_len() >= 1);
    try std.testing.expect(oc_command_history_len() > 0);
    try std.testing.expect(oc_health_history_len() > 0);
    try std.testing.expect(oc_mode_history_len() > 0);
    try std.testing.expect(oc_boot_phase_history_len() > 0);
    try std.testing.expect(oc_command_result_total_count() > 0);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_allocator_allocation_count());
    try std.testing.expectEqual(@as(u32, 1), oc_syscall_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 3), oc_timer_quantum());

    _ = oc_submit_command(abi.command_reset_counters, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u64, 1), status.ticks);
    try std.testing.expectEqual(@as(u32, 0), status.panic_count);
    try std.testing.expectEqual(@as(u16, 200), status.last_health_code);
    try std.testing.expectEqual(@as(u16, abi.command_reset_counters), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_exception_vector_count(13));
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_exception_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_len());
    try std.testing.expectEqual(@as(u16, abi.command_reset_counters), oc_command_history_event(0).opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_len());
    try std.testing.expectEqual(@as(u16, 200), oc_health_history_event(0).health_code);
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_total_count());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_ok());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_invalid_argument());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_not_supported());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_other_error());
    try std.testing.expectEqual(@as(u16, abi.command_reset_counters), oc_command_result_counters_ptr().last_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expect(!oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_allocator_allocation_count());
    try std.testing.expectEqual(@as(u64, 0), oc_allocator_state_ptr().bytes_in_use);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_entry_count());
    try std.testing.expect(oc_syscall_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_quantum());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
}

test "baremetal feature flags and tick batch hint commands update status" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.last_health_code = 200;
    status.feature_flags = abi.defaultFeatureFlags();
    status.panic_count = 0;
    status.command_seq_ack = 0;
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
    oc_command_result_counters_clear();

    _ = oc_submit_command(abi.command_set_feature_flags, 0xA55AA55A, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_feature_flags), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0xA55AA55A), status.feature_flags);
    try std.testing.expectEqual(@as(u64, 1), status.ticks);

    _ = oc_submit_command(abi.command_set_tick_batch_hint, 4, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 4), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u64, 5), status.ticks);

    _ = oc_submit_command(abi.command_set_tick_batch_hint, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 4), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u64, 9), status.ticks);

    try std.testing.expectEqual(@as(u32, 3), oc_command_result_total_count());
    try std.testing.expectEqual(@as(u32, 2), oc_command_result_count_ok());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_invalid_argument());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_not_supported());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_other_error());
}

test "baremetal scheduler command flow creates dispatches and completes tasks" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_command_result_counters_clear();

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_scheduler_enabled());

    _ = oc_submit_command(abi.command_task_create, 3, 2);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    var task = oc_scheduler_task(0);
    try std.testing.expect(task.task_id != 0);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
    try std.testing.expectEqual(@as(u8, 2), task.priority);
    try std.testing.expectEqual(@as(u32, 3), task.budget_ticks);
    const created_task_id = task.task_id;

    // Consume full budget and verify completion.
    oc_tick();
    oc_tick();
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(created_task_id, task.task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_completed), task.state);
    try std.testing.expectEqual(@as(u32, 0), task.budget_remaining);
    const sched_state = oc_scheduler_state_ptr().*;
    try std.testing.expect(sched_state.dispatch_count >= 3);
    try std.testing.expect(sched_state.ready_scans > 0);

    _ = oc_submit_command(abi.command_task_terminate, created_task_id + 100, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);

    _ = oc_submit_command(abi.command_task_create, 0, 0); // uses default budget
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    _ = oc_submit_command(abi.command_task_terminate, oc_scheduler_task(0).task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
}

test "baremetal scheduler task table saturates and reuses terminated slots" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_command_result_counters_clear();

    const capacity = oc_scheduler_task_capacity();
    const reuse_slot: u32 = 5;
    var last_task_id: u32 = 0;
    var reused_slot_previous_id: u32 = 0;

    var idx: u32 = 0;
    while (idx < capacity) : (idx += 1) {
        _ = oc_submit_command(abi.command_task_create, 2, idx + 1);
        oc_tick();
        try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
        const task = oc_scheduler_task(idx);
        try std.testing.expect(task.task_id != 0);
        try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
        if (idx == reuse_slot) reused_slot_previous_id = task.task_id;
        last_task_id = task.task_id;
    }

    try std.testing.expectEqual(capacity, oc_scheduler_task_count());
    try std.testing.expect(reused_slot_previous_id != 0);

    _ = oc_submit_command(abi.command_task_create, 3, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_no_space), status.last_command_result);
    try std.testing.expectEqual(capacity, oc_scheduler_task_count());

    _ = oc_submit_command(abi.command_task_terminate, reused_slot_previous_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(capacity - 1, oc_scheduler_task_count());
    const terminated = oc_scheduler_task(reuse_slot);
    try std.testing.expectEqual(reused_slot_previous_id, terminated.task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), terminated.state);

    _ = oc_submit_command(abi.command_task_create, 7, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(capacity, oc_scheduler_task_count());
    const reused = oc_scheduler_task(reuse_slot);
    try std.testing.expect(reused.task_id > last_task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), reused.state);
    try std.testing.expectEqual(@as(u8, 99), reused.priority);
    try std.testing.expectEqual(@as(u32, 7), reused.budget_ticks);

    try std.testing.expectEqual(@as(u32, capacity + 3), oc_command_result_total_count());
    try std.testing.expectEqual(capacity + 2, oc_command_result_count_ok());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_invalid_argument());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_not_supported());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_other_error());
}

test "baremetal allocator command flow allocates and frees mapped pages" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_allocator_reset();
    oc_command_result_counters_clear();
    oc_scheduler_reset();

    const initial_free = oc_allocator_state_ptr().free_pages;
    _ = oc_submit_command(abi.command_allocator_alloc, 8192, 4096);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const state_after_alloc = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), state_after_alloc.allocation_count);
    try std.testing.expectEqual(initial_free - 2, state_after_alloc.free_pages);
    try std.testing.expect(state_after_alloc.last_alloc_ptr != 0);
    try std.testing.expectEqual(@as(u64, 8192), state_after_alloc.last_alloc_size);
    const alloc0 = oc_allocator_allocation(0);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), alloc0.state);
    try std.testing.expectEqual(@as(u32, 2), alloc0.page_len);
    try std.testing.expectEqual(state_after_alloc.last_alloc_ptr, alloc0.ptr);

    _ = oc_submit_command(abi.command_allocator_free, alloc0.ptr + 4096, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);

    _ = oc_submit_command(abi.command_allocator_free, alloc0.ptr, 8192);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const state_after_free = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 0), state_after_free.allocation_count);
    try std.testing.expectEqual(initial_free, state_after_free.free_pages);
    try std.testing.expectEqual(alloc0.ptr, state_after_free.last_free_ptr);

    _ = oc_submit_command(abi.command_allocator_alloc, state_after_free.heap_size + 4096, 4096);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_no_space), status.last_command_result);
}

test "baremetal syscall command flow registers invokes and unregisters entries" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_syscall_reset();
    oc_command_result_counters_clear();
    oc_scheduler_reset();
    oc_allocator_reset();

    _ = oc_submit_command(abi.command_syscall_register, 7, 0xAA55);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_syscall_entry_count());
    const entry0 = oc_syscall_entry(0);
    try std.testing.expectEqual(@as(u32, 7), entry0.syscall_id);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), entry0.state);

    _ = oc_submit_command(abi.command_syscall_invoke, 7, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const syscall_state_after_invoke = oc_syscall_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 7), syscall_state_after_invoke.last_syscall_id);
    try std.testing.expect(syscall_state_after_invoke.dispatch_count > 0);
    try std.testing.expect(syscall_state_after_invoke.last_invoke_tick > 0);

    _ = oc_submit_command(abi.command_syscall_unregister, 7, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_entry_count());

    _ = oc_submit_command(abi.command_syscall_invoke, 7, 0x9999);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal timer scheduler wake flow handles timer and interrupt wakeups" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_allocator_reset();
    oc_syscall_reset();
    oc_timer_reset();
    x86_bootstrap.oc_reset_interrupt_counters();

    // Create task while scheduler is disabled to avoid pre-schedule dispatch.
    _ = oc_submit_command(abi.command_task_create, 5, 1);
    oc_tick();
    const task1_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task1_id != 0);

    _ = oc_submit_command(abi.command_timer_schedule, task1_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    const timer_entry = oc_timer_entry(0);
    try std.testing.expectEqual(task1_id, timer_entry.task_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), timer_entry.state);

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    // No timer fire yet.
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    // Timer should fire and enqueue wake event; scheduler can dispatch task in same tick.
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const wake0 = oc_wake_queue_event(0);
    try std.testing.expectEqual(task1_id, wake0.task_id);
    try std.testing.expectEqual(timer_entry.timer_id, wake0.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), wake0.reason);
    try std.testing.expect(oc_scheduler_task(0).state == abi.task_state_ready or oc_scheduler_task(0).state == abi.task_state_running);

    // Create second task and wait specifically for interrupt wake path.
    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 4, 0);
    oc_tick();
    const task2_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(task2_id != 0);
    _ = oc_submit_command(abi.command_task_wait_interrupt, task2_id, abi.wait_interrupt_any_vector);
    oc_tick();
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();

    try std.testing.expect(oc_wake_queue_len() >= 2);
    const wake_last = oc_wake_queue_event(oc_wake_queue_len() - 1);
    try std.testing.expectEqual(task2_id, wake_last.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), wake_last.reason);
    try std.testing.expectEqual(@as(u8, 200), wake_last.vector);
    try std.testing.expect(oc_scheduler_task(1).state == abi.task_state_ready or oc_scheduler_task(1).state == abi.task_state_running);

    _ = oc_submit_command(abi.command_wake_queue_clear, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
}

test "baremetal syscall abi v2 supports enable disable and entry flags" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_syscall_reset();
    oc_timer_reset();
    oc_scheduler_reset();

    _ = oc_submit_command(abi.command_syscall_register, 9, 0xBEEF);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_syscall_set_flags, 9, abi.syscall_entry_flag_blocked);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.syscall_entry_flag_blocked, oc_syscall_entry(0).flags);

    _ = oc_submit_command(abi.command_syscall_invoke, 9, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_conflict), status.last_command_result);

    _ = oc_submit_command(abi.command_syscall_disable, 0, 0);
    oc_tick();
    try std.testing.expect(!oc_syscall_enabled());
    _ = oc_submit_command(abi.command_syscall_invoke, 9, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_supported), status.last_command_result);

    _ = oc_submit_command(abi.command_syscall_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_syscall_enabled());
    _ = oc_submit_command(abi.command_syscall_set_flags, 9, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_syscall_invoke, 9, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
}

test "baremetal timer periodic flow rearms and honors enable disable controls" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_allocator_reset();
    oc_syscall_reset();
    oc_timer_reset();
    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 8, 1);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_timer_schedule_periodic, task_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    var entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u16, abi.timer_entry_flag_periodic), entry.flags & abi.timer_entry_flag_periodic);
    try std.testing.expectEqual(@as(u32, 2), entry.period_ticks);

    oc_tick(); // current_tick=3 (no fire yet)
    oc_tick(); // current_tick=4 (first periodic fire)
    entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), entry.state);
    try std.testing.expectEqual(@as(u64, 1), entry.fire_count);
    try std.testing.expect(oc_wake_queue_len() >= 1);

    _ = oc_submit_command(abi.command_timer_disable, 0, 0);
    oc_tick();
    const wakes_before_pause = oc_wake_queue_len();
    oc_tick();
    oc_tick();
    try std.testing.expectEqual(wakes_before_pause, oc_wake_queue_len());
    try std.testing.expect(!oc_timer_enabled());

    _ = oc_submit_command(abi.command_timer_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_timer_enabled());
    oc_tick();
    entry = oc_timer_entry(0);
    try std.testing.expect(entry.fire_count >= 2);
}

test "baremetal timer quantum delays one shot dispatch until quantum boundary" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_timer_set_quantum, 3, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 3), oc_timer_quantum());

    _ = oc_submit_command(abi.command_timer_schedule, task_id, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    // current tick has advanced to 4 here; next timer scan boundary is 6
    oc_tick(); // current_tick=4
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    oc_tick(); // current_tick=5
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    oc_tick(); // current_tick=6
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
}

test "baremetal task wait and resume commands control runnable state and wake queue" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());

    _ = oc_submit_command(abi.command_task_wait, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());

    _ = oc_submit_command(abi.command_task_resume, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
}

test "baremetal timer cancel task command cancels armed task timers" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 7, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_timer_schedule, task_id, 10);
    oc_tick();
    _ = oc_submit_command(abi.command_timer_schedule_periodic, task_id, 20);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), oc_timer_entry(0).state);

    _ = oc_submit_command(abi.command_timer_cancel_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), oc_timer_entry(0).state);

    _ = oc_submit_command(abi.command_timer_cancel_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal task wait for command arms deadline and wakes on timer fire" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 6, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_for, task_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());

    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), evt.reason);
}

test "baremetal wake queue pop command removes oldest entries in order" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait, task_id, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_resume, task_id, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_wait, task_id, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_resume, task_id, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    const first_before = oc_wake_queue_event(0);
    const second_before = oc_wake_queue_event(1);
    try std.testing.expect(second_before.seq > first_before.seq);

    _ = oc_submit_command(abi.command_wake_queue_pop, 1, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const first_after = oc_wake_queue_event(0);
    try std.testing.expectEqual(second_before.seq, first_after.seq);

    _ = oc_submit_command(abi.command_wake_queue_pop, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_wake_queue_pop, 1, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal wake queue ring keeps newest manual wakes after overflow" {
    resetBaremetalRuntimeForTest();

    const cap = oc_wake_queue_capacity();
    var idx: u32 = 0;
    while (idx < cap + 2) : (idx += 1) {
        wakeQueuePush(5000 + idx, 0, abi.wake_reason_manual, 0, 100 + idx, 0);
    }

    try std.testing.expectEqual(cap, oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());

    const summary = oc_wake_queue_summary();
    try std.testing.expectEqual(cap, summary.len);
    try std.testing.expectEqual(@as(u32, 2), summary.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), summary.reason_timer_count);
    try std.testing.expectEqual(@as(u32, 0), summary.reason_interrupt_count);
    try std.testing.expectEqual(cap, summary.reason_manual_count);
    try std.testing.expectEqual(@as(u32, 0), summary.nonzero_vector_count);
    try std.testing.expectEqual(@as(u64, 102), summary.oldest_tick);
    try std.testing.expectEqual(@as(u64, 165), summary.newest_tick);

    const first = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 3), first.seq);
    try std.testing.expectEqual(@as(u32, 5002), first.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), first.reason);
    try std.testing.expectEqual(@as(u64, 102), first.tick);

    const last = oc_wake_queue_event(cap - 1);
    try std.testing.expectEqual(@as(u32, 66), last.seq);
    try std.testing.expectEqual(@as(u32, 5065), last.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), last.reason);
    try std.testing.expectEqual(@as(u64, 165), last.tick);
}

test "baremetal wake queue batch pop recovers correctly after overflow" {
    resetBaremetalRuntimeForTest();

    const cap = oc_wake_queue_capacity();
    var idx: u32 = 0;
    while (idx < cap + 2) : (idx += 1) {
        wakeQueuePush(6000 + idx, 0, abi.wake_reason_manual, 0, 200 + idx, 0);
    }

    try std.testing.expectEqual(cap, oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());

    _ = oc_submit_command(abi.command_wake_queue_pop, cap - 2, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    const survivor0 = oc_wake_queue_event(0);
    const survivor1 = oc_wake_queue_event(1);
    try std.testing.expectEqual(@as(u32, 65), survivor0.seq);
    try std.testing.expectEqual(@as(u32, 6064), survivor0.task_id);
    try std.testing.expectEqual(@as(u64, 264), survivor0.tick);
    try std.testing.expectEqual(@as(u32, 66), survivor1.seq);
    try std.testing.expectEqual(@as(u32, 6065), survivor1.task_id);
    try std.testing.expectEqual(@as(u64, 265), survivor1.tick);

    _ = oc_submit_command(abi.command_wake_queue_pop, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_tail_index());
    const final_survivor = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 66), final_survivor.seq);
    try std.testing.expectEqual(@as(u32, 6065), final_survivor.task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());

    wakeQueuePush(7000, 0, abi.wake_reason_manual, 0, 300, 0);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    const reused = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 67), reused.seq);
    try std.testing.expectEqual(@as(u32, 7000), reused.task_id);
    try std.testing.expectEqual(@as(u64, 300), reused.tick);
}

test "baremetal wake queue selective pop preserves order after overflow" {
    resetBaremetalRuntimeForTest();

    const cap = oc_wake_queue_capacity();
    var idx: u32 = 0;
    while (idx < cap + 2) : (idx += 1) {
        const vector: u8 = if (@mod(idx, 2) == 0) 13 else 31;
        wakeQueuePush(8000 + idx, 0, abi.wake_reason_interrupt, vector, 400 + idx, idx + 1);
    }

    try std.testing.expectEqual(cap, oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_vector_count(31));

    _ = oc_submit_command(abi.command_wake_queue_pop_vector, 13, 31);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_vector_count(31));
    const first_after_vector = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 4), first_after_vector.seq);
    try std.testing.expectEqual(@as(u32, 8003), first_after_vector.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), first_after_vector.reason);
    try std.testing.expectEqual(@as(u8, 31), first_after_vector.vector);
    const retained_vector = oc_wake_queue_event(31);
    try std.testing.expectEqual(@as(u32, 65), retained_vector.seq);
    try std.testing.expectEqual(@as(u32, 8064), retained_vector.task_id);
    try std.testing.expectEqual(@as(u8, 13), retained_vector.vector);
    const last_after_vector = oc_wake_queue_event(32);
    try std.testing.expectEqual(@as(u32, 66), last_after_vector.seq);
    try std.testing.expectEqual(@as(u32, 8065), last_after_vector.task_id);
    try std.testing.expectEqual(@as(u8, 31), last_after_vector.vector);

    const pair_interrupt_13: u64 = @as(u64, abi.wake_reason_interrupt) | (@as(u64, 13) << 8);
    _ = oc_submit_command(abi.command_wake_queue_pop_reason_vector, pair_interrupt_13, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_vector_count(31));
    const first_after_reason_vector = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 4), first_after_reason_vector.seq);
    try std.testing.expectEqual(@as(u32, 8003), first_after_reason_vector.task_id);
    try std.testing.expectEqual(@as(u8, 31), first_after_reason_vector.vector);
    const last_after_reason_vector = oc_wake_queue_event(31);
    try std.testing.expectEqual(@as(u32, 66), last_after_reason_vector.seq);
    try std.testing.expectEqual(@as(u32, 8065), last_after_reason_vector.task_id);
    try std.testing.expectEqual(@as(u8, 31), last_after_reason_vector.vector);
}

test "baremetal wake queue reason pop preserves order after overflow" {
    resetBaremetalRuntimeForTest();

    const cap = oc_wake_queue_capacity();
    var idx: u32 = 0;
    while (idx < cap + 2) : (idx += 1) {
        const reason: u8 = if (@mod(idx, 2) == 0) abi.wake_reason_manual else abi.wake_reason_interrupt;
        const vector: u8 = if (reason == abi.wake_reason_interrupt) 13 else 0;
        wakeQueuePush(8500 + idx, 0, reason, vector, 450 + idx, idx + 1);
    }

    try std.testing.expectEqual(cap, oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_count(abi.wake_reason_manual));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_count(abi.wake_reason_interrupt));

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_manual, 31);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_count(abi.wake_reason_manual));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_count(abi.wake_reason_interrupt));
    const first_after_reason = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 4), first_after_reason.seq);
    try std.testing.expectEqual(@as(u32, 8503), first_after_reason.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), first_after_reason.reason);
    const retained_reason = oc_wake_queue_event(31);
    try std.testing.expectEqual(@as(u32, 65), retained_reason.seq);
    try std.testing.expectEqual(@as(u32, 8564), retained_reason.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), retained_reason.reason);
    const last_after_reason = oc_wake_queue_event(32);
    try std.testing.expectEqual(@as(u32, 66), last_after_reason.seq);
    try std.testing.expectEqual(@as(u32, 8565), last_after_reason.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), last_after_reason.reason);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_manual, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_count(abi.wake_reason_manual));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_count(abi.wake_reason_interrupt));
    const first_after_second_reason = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 4), first_after_second_reason.seq);
    try std.testing.expectEqual(@as(u32, 8503), first_after_second_reason.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), first_after_second_reason.reason);
    const last_after_second_reason = oc_wake_queue_event(31);
    try std.testing.expectEqual(@as(u32, 66), last_after_second_reason.seq);
    try std.testing.expectEqual(@as(u32, 8565), last_after_second_reason.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), last_after_second_reason.reason);
}

test "baremetal wake queue before-tick pop preserves order after overflow" {
    resetBaremetalRuntimeForTest();

    const cap = oc_wake_queue_capacity();
    var idx: u32 = 0;
    while (idx < cap + 2) : (idx += 1) {
        wakeQueuePush(9000 + idx, 0, abi.wake_reason_manual, 0, 500 + idx, 0);
    }

    try std.testing.expectEqual(cap, oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_before_tick_count(533));
    try std.testing.expectEqual(@as(u32, 63), oc_wake_queue_before_tick_count(564));
    try std.testing.expectEqual(@as(u32, 64), oc_wake_queue_before_tick_count(565));

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 533, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_before_tick_count(533));
    try std.testing.expectEqual(@as(u32, 31), oc_wake_queue_before_tick_count(564));
    const first_after_before_tick = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 35), first_after_before_tick.seq);
    try std.testing.expectEqual(@as(u32, 9034), first_after_before_tick.task_id);
    try std.testing.expectEqual(@as(u64, 534), first_after_before_tick.tick);
    const last_after_before_tick = oc_wake_queue_event(31);
    try std.testing.expectEqual(@as(u32, 66), last_after_before_tick.seq);
    try std.testing.expectEqual(@as(u32, 9065), last_after_before_tick.task_id);
    try std.testing.expectEqual(@as(u64, 565), last_after_before_tick.tick);

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 564, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_before_tick_count(564));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_before_tick_count(565));
    const retained_after_second_before_tick = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 66), retained_after_second_before_tick.seq);
    try std.testing.expectEqual(@as(u32, 9065), retained_after_second_before_tick.task_id);
    try std.testing.expectEqual(@as(u64, 565), retained_after_second_before_tick.tick);

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 565, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_before_tick_count(565));

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 565, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal wake queue reason pop command removes only matching reasons" {
    resetBaremetalRuntimeForTest();

    wakeQueuePush(1001, 11, abi.wake_reason_timer, 0, 1, 0);
    wakeQueuePush(1002, 12, abi.wake_reason_interrupt, 31, 2, 10);
    wakeQueuePush(1003, 13, abi.wake_reason_interrupt, 44, 3, 11);
    wakeQueuePush(1004, 14, abi.wake_reason_manual, 0, 4, 11);

    try std.testing.expectEqual(@as(u32, 4), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_count(abi.wake_reason_timer));
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_reason_count(abi.wake_reason_interrupt));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_count(abi.wake_reason_manual));
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_count(99));

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_interrupt, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_count(abi.wake_reason_interrupt));
    try std.testing.expectEqual(@as(u32, abi.wake_reason_interrupt), oc_wake_queue_event(1).reason);
    try std.testing.expectEqual(@as(u32, 1003), oc_wake_queue_event(1).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_interrupt, 8);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_count(abi.wake_reason_interrupt));
    try std.testing.expectEqual(@as(u32, 1001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 1004), oc_wake_queue_event(1).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, 9, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_interrupt, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal wake queue vector pop command removes only matching vectors" {
    resetBaremetalRuntimeForTest();

    wakeQueuePush(2001, 21, abi.wake_reason_timer, 0, 1, 0);
    wakeQueuePush(2002, 22, abi.wake_reason_interrupt, 13, 2, 10);
    wakeQueuePush(2003, 23, abi.wake_reason_interrupt, 13, 3, 11);
    wakeQueuePush(2004, 24, abi.wake_reason_interrupt, 31, 4, 12);

    try std.testing.expectEqual(@as(u32, 4), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_vector_count(0));
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_vector_count(31));
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_vector_count(99));

    _ = oc_submit_command(abi.command_wake_queue_pop_vector, 13, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u32, 2003), oc_wake_queue_event(1).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_vector, 13, 9);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u32, 2001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 2004), oc_wake_queue_event(1).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_vector, 255, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal wake queue before-tick pop command removes stale entries" {
    resetBaremetalRuntimeForTest();

    wakeQueuePush(3001, 31, abi.wake_reason_timer, 0, 10, 0);
    wakeQueuePush(3002, 32, abi.wake_reason_interrupt, 4, 20, 5);
    wakeQueuePush(3003, 33, abi.wake_reason_interrupt, 4, 30, 6);
    wakeQueuePush(3004, 34, abi.wake_reason_manual, 0, 40, 6);

    try std.testing.expectEqual(@as(u32, 4), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_before_tick_count(20));
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_before_tick_count(30));
    try std.testing.expectEqual(@as(u32, 4), oc_wake_queue_before_tick_count(40));

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 20, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_before_tick_count(20));
    try std.testing.expectEqual(@as(u32, 3002), oc_wake_queue_event(0).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 30, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_before_tick_count(30));
    try std.testing.expectEqual(@as(u32, 3004), oc_wake_queue_event(0).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 30, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal wake queue reason-vector pop command removes only exact pairs" {
    resetBaremetalRuntimeForTest();

    wakeQueuePush(4001, 41, abi.wake_reason_interrupt, 13, 10, 1);
    wakeQueuePush(4002, 42, abi.wake_reason_interrupt, 13, 11, 2);
    wakeQueuePush(4003, 43, abi.wake_reason_interrupt, 19, 12, 3);
    wakeQueuePush(4004, 44, abi.wake_reason_timer, 13, 13, 3);

    status.ticks = 12;
    try std.testing.expectEqual(@as(u32, 4), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 19));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_vector_count(abi.wake_reason_timer, 13));
    const summary_before = oc_wake_queue_summary();
    try std.testing.expectEqual(@as(u32, 4), summary_before.len);
    try std.testing.expectEqual(@as(u32, 3), summary_before.reason_interrupt_count);
    try std.testing.expectEqual(@as(u32, 1), summary_before.reason_timer_count);
    try std.testing.expectEqual(@as(u32, 0), summary_before.reason_manual_count);
    try std.testing.expectEqual(@as(u32, 4), summary_before.nonzero_vector_count);
    try std.testing.expectEqual(@as(u32, 3), summary_before.stale_count);
    try std.testing.expectEqual(@as(u64, 10), summary_before.oldest_tick);
    try std.testing.expectEqual(@as(u64, 13), summary_before.newest_tick);
    const buckets_before = oc_wake_queue_age_buckets(2);
    try std.testing.expectEqual(@as(u64, 12), buckets_before.current_tick);
    try std.testing.expectEqual(@as(u64, 2), buckets_before.quantum_ticks);
    try std.testing.expectEqual(@as(u32, 3), buckets_before.stale_count);
    try std.testing.expectEqual(@as(u32, 1), buckets_before.stale_older_than_quantum_count);
    try std.testing.expectEqual(@as(u32, 1), buckets_before.future_count);
    const summary_snapshot = oc_wake_queue_summary_ptr().*;
    try std.testing.expectEqual(summary_before, summary_snapshot);
    const age_bucket_snapshot = oc_wake_queue_age_buckets_ptr(2).*;
    try std.testing.expectEqual(buckets_before, age_bucket_snapshot);
    const age_bucket_snapshot_quantum_2 = oc_wake_queue_age_buckets_ptr_quantum_2().*;
    try std.testing.expectEqual(buckets_before, age_bucket_snapshot_quantum_2);

    const pair_interrupt_13: u64 = @as(u64, abi.wake_reason_interrupt) | (@as(u64, 13) << 8);
    _ = oc_submit_command(abi.command_wake_queue_pop_reason_vector, pair_interrupt_13, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
    try std.testing.expectEqual(@as(u32, 4002), oc_wake_queue_event(0).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason_vector, pair_interrupt_13, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
    try std.testing.expectEqual(@as(u32, 4003), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 4004), oc_wake_queue_event(1).task_id);
    const summary_after = oc_wake_queue_summary();
    try std.testing.expectEqual(@as(u32, 2), summary_after.len);
    try std.testing.expectEqual(@as(u32, 1), summary_after.reason_interrupt_count);
    try std.testing.expectEqual(@as(u32, 1), summary_after.reason_timer_count);
    const summary_snapshot_after = oc_wake_queue_summary_ptr().*;
    try std.testing.expectEqual(summary_after, summary_snapshot_after);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason_vector, 0, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
}

test "baremetal scheduler priority policy favors highest priority and supports updates" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 6, 1); // low
    oc_tick();
    const low_id = oc_scheduler_task(0).task_id;
    _ = oc_submit_command(abi.command_task_create, 6, 9); // high
    oc_tick();
    const high_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(low_id != 0 and high_id != 0);

    _ = oc_submit_command(abi.command_scheduler_set_policy, abi.scheduler_policy_priority, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_priority), oc_scheduler_policy());

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    var low_task = oc_scheduler_task(0);
    var high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 0), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 1), high_task.run_count);

    _ = oc_submit_command(abi.command_task_set_priority, low_id, 15);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expect(low_task.run_count >= 1);
    try std.testing.expectEqual(@as(u8, 15), low_task.priority);

    _ = oc_submit_command(abi.command_scheduler_set_policy, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);

    _ = oc_submit_command(abi.command_task_set_priority, 99999, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal scheduler default round robin dispatch remains stable" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();

    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_round_robin), oc_scheduler_policy());
    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 4, 1);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 4, 9);
    oc_tick();

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    const first = oc_scheduler_task(0);
    const second = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 1), first.run_count);
    try std.testing.expectEqual(@as(u32, 0), second.run_count);
}

test "baremetal task wait interrupt command honors vector filters and any mode" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_any_id = oc_scheduler_task(0).task_id;

    _ = oc_submit_command(abi.command_task_wait_interrupt, task_any_id, abi.wait_interrupt_any_vector);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(task_any_id, oc_wake_queue_event(0).task_id);

    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_vec_id = oc_scheduler_task(1).task_id;
    _ = oc_submit_command(abi.command_task_wait_interrupt, task_vec_id, 13);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_trigger_interrupt, 13, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const vec_evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_vec_id, vec_evt.task_id);
    try std.testing.expectEqual(@as(u8, 13), vec_evt.vector);

    _ = oc_submit_command(abi.command_task_wait_interrupt, task_vec_id, @as(u64, abi.wait_interrupt_any_vector) + 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
}

test "baremetal interrupt and exception history clear commands preserve counters" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_reset_interrupt_counters, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_clear_interrupt_history, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_reset_exception_counters, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_clear_exception_history, 0, 0);
    oc_tick();

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_exception, 13, 0xCAFE);
    oc_tick();

    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u32, 2), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());
    const interrupt0 = x86_bootstrap.oc_interrupt_history_event(0);
    try std.testing.expectEqual(@as(u8, 200), interrupt0.vector);
    try std.testing.expectEqual(@as(u8, 0), interrupt0.is_exception);
    try std.testing.expectEqual(@as(u64, 0), interrupt0.code);
    const interrupt1 = x86_bootstrap.oc_interrupt_history_event(1);
    try std.testing.expectEqual(@as(u8, 13), interrupt1.vector);
    try std.testing.expectEqual(@as(u8, 1), interrupt1.is_exception);
    try std.testing.expectEqual(@as(u64, 0xCAFE), interrupt1.code);
    const exception0 = x86_bootstrap.oc_exception_history_event(0);
    try std.testing.expectEqual(@as(u8, 13), exception0.vector);
    try std.testing.expectEqual(@as(u64, 0xCAFE), exception0.code);

    _ = oc_submit_command(abi.command_clear_interrupt_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_history_overflow_count());
    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());

    _ = oc_submit_command(abi.command_clear_exception_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_exception_history_len());
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_exception_history_overflow_count());
    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
}

test "baremetal interrupt mask commands gate non-exception interrupt wakeups" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_interrupt_mask_clear_all();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;

    _ = oc_submit_command(abi.command_task_wait_interrupt, task_id, abi.wait_interrupt_any_vector);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_interrupt_mask_apply_profile, abi.interrupt_mask_profile_external_all, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(x86_bootstrap.oc_interrupt_mask_is_set(200));
    try std.testing.expectEqual(abi.interrupt_mask_profile_external_all, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 224), x86_bootstrap.oc_interrupt_masked_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_vector_count(200));
    try std.testing.expectEqual(@as(u8, 200), x86_bootstrap.oc_interrupt_last_masked_vector());

    _ = oc_submit_command(abi.command_trigger_interrupt, 13, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(task_id, oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u8, 13), oc_wake_queue_event(0).vector);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());

    _ = oc_submit_command(abi.command_interrupt_mask_set, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(200));
    try std.testing.expectEqual(abi.interrupt_mask_profile_custom, x86_bootstrap.oc_interrupt_mask_profile());

    _ = oc_submit_command(abi.command_interrupt_mask_set, 300, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);

    _ = oc_submit_command(abi.command_interrupt_mask_set, 200, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);

    _ = oc_submit_command(abi.command_interrupt_mask_set, 201, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 223), x86_bootstrap.oc_interrupt_masked_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 201, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_vector_count(200));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_vector_count(201));
    try std.testing.expectEqual(@as(u8, 201), x86_bootstrap.oc_interrupt_last_masked_vector());

    _ = oc_submit_command(abi.command_interrupt_mask_reset_ignored_counts, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_mask_ignored_vector_count(200));
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_mask_ignored_vector_count(201));
    try std.testing.expectEqual(@as(u8, 0), x86_bootstrap.oc_interrupt_last_masked_vector());

    _ = oc_submit_command(abi.command_interrupt_mask_reset_ignored_counts, 1, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);

    _ = oc_submit_command(abi.command_interrupt_mask_apply_profile, abi.interrupt_mask_profile_external_high, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.interrupt_mask_profile_external_high, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 192), x86_bootstrap.oc_interrupt_masked_count());
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(63));
    try std.testing.expect(x86_bootstrap.oc_interrupt_mask_is_set(64));

    _ = oc_submit_command(abi.command_interrupt_mask_apply_profile, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(abi.interrupt_mask_profile_external_high, x86_bootstrap.oc_interrupt_mask_profile());

    _ = oc_submit_command(abi.command_interrupt_mask_apply_profile, abi.interrupt_mask_profile_none, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.interrupt_mask_profile_none, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_masked_count());

    _ = oc_submit_command(abi.command_interrupt_mask_clear_all, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_masked_count());
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(201));
    try std.testing.expectEqual(abi.interrupt_mask_profile_none, x86_bootstrap.oc_interrupt_mask_profile());
}

test "baremetal interrupt wait with timeout wakes on timer when no interrupt arrives" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());

    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), evt.reason);
}

test "baremetal interrupt wait with timeout wakes on interrupt before deadline" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 5);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 31, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), evt.reason);
    try std.testing.expectEqual(@as(u8, 31), evt.vector);

    oc_tick_n(8);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
}

test "baremetal manual wait does not wake on interrupt path" {
    status.mode = abi.mode_running;
    status.ticks = 0;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    _ = oc_submit_command(abi.command_task_wait, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 44, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
}

test "baremetal saturating tick helpers clamp overflow" {
    try std.testing.expectEqual(@as(u64, 15), addTicksSaturating(10, 5));
    try std.testing.expectEqual(std.math.maxInt(u64), addTicksSaturating(std.math.maxInt(u64) - 2, 5));
    try std.testing.expectEqual(@as(u64, 120), advancePeriodicTickSaturating(100, 10, 119));
    try std.testing.expectEqual(std.math.maxInt(u64), advancePeriodicTickSaturating(std.math.maxInt(u64) - 4, 10, std.math.maxInt(u64) - 1));
}

test "baremetal interrupt wait timeout clamps near max tick without wraparound" {
    status.mode = abi.mode_running;
    status.ticks = std.math.maxInt(u64) - 3;
    status.command_seq_ack = 0;
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
    oc_scheduler_reset();
    oc_timer_reset();
    oc_wake_queue_clear();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 4, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 5);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), oc_wake_queue_event(0).reason);
}
