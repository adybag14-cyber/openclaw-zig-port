const std = @import("std");
const builtin = @import("builtin");
const abi = @import("baremetal/abi.zig");
const ata_pio_disk = @import("baremetal/ata_pio_disk.zig");
const x86_bootstrap = @import("baremetal/x86_bootstrap.zig");
const framebuffer_console = @import("baremetal/framebuffer_console.zig");
const vga_text_console = @import("baremetal/vga_text_console.zig");
const rtl8139 = @import("baremetal/rtl8139.zig");
const storage_backend = @import("baremetal/storage_backend.zig");
const filesystem = @import("baremetal/filesystem.zig");
const ps2_input = @import("baremetal/ps2_input.zig");
const tool_layout = @import("baremetal/tool_layout.zig");
const pal_fs = @import("pal/fs.zig");
const pal_net = @import("pal/net.zig");
const pal_proc = @import("pal/proc.zig");
const arp_protocol = @import("protocol/arp.zig");
const dhcp_protocol = @import("protocol/dhcp.zig");
const dns_protocol = @import("protocol/dns.zig");
const ethernet_protocol = @import("protocol/ethernet.zig");
const ipv4_protocol = @import("protocol/ipv4.zig");
const tcp_protocol = @import("protocol/tcp.zig");
const udp_protocol = @import("protocol/udp.zig");
const BaremetalStatus = abi.BaremetalStatus;
const BaremetalCommand = abi.BaremetalCommand;
const BaremetalKernelInfo = abi.BaremetalKernelInfo;
const BaremetalBootDiagnostics = abi.BaremetalBootDiagnostics;
const BaremetalConsoleState = abi.BaremetalConsoleState;
const BaremetalFramebufferState = abi.BaremetalFramebufferState;
const BaremetalEthernetState = abi.BaremetalEthernetState;
const BaremetalStorageState = abi.BaremetalStorageState;
const BaremetalToolLayoutState = abi.BaremetalToolLayoutState;
const BaremetalToolSlot = abi.BaremetalToolSlot;
const BaremetalFilesystemState = abi.BaremetalFilesystemState;
const BaremetalFilesystemEntry = abi.BaremetalFilesystemEntry;
const BaremetalKeyboardState = abi.BaremetalKeyboardState;
const BaremetalKeyboardEvent = abi.BaremetalKeyboardEvent;
const BaremetalMouseState = abi.BaremetalMouseState;
const BaremetalMousePacket = abi.BaremetalMousePacket;
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
const BaremetalWakeQueueCountQuery = extern struct {
    vector: u8,
    reason: u8,
    reserved0: u16,
    reserved1: u32,
    max_tick: u64,
};
const BaremetalWakeQueueCountSnapshot = extern struct {
    vector_count: u32,
    before_tick_count: u32,
    reason_vector_count: u32,
    reserved0: u32,
};

const multiboot2_magic: u32 = 0xE85250D6;
const multiboot2_architecture_i386: u32 = 0;
const qemu_debug_exit_port: u16 = 0xF4;
const qemu_boot_ok_code: u8 = 0x2A;
const qemu_ata_storage_probe_ok_code: u8 = 0x34;
const qemu_rtl8139_probe_ok_code: u8 = 0x36;
const qemu_rtl8139_arp_probe_ok_code: u8 = 0x37;
const qemu_rtl8139_ipv4_probe_ok_code: u8 = 0x38;
const qemu_rtl8139_udp_probe_ok_code: u8 = 0x39;
const qemu_rtl8139_tcp_probe_ok_code: u8 = 0x3A;
const qemu_rtl8139_dhcp_probe_ok_code: u8 = 0x3B;
const qemu_rtl8139_dns_probe_ok_code: u8 = 0x3C;
const qemu_tool_exec_probe_ok_code: u8 = 0x3D;
const qemu_rtl8139_gateway_probe_ok_code: u8 = 0x3E;
const build_options = if (builtin.is_test)
    struct {
        pub const qemu_smoke: bool = false;
        pub const console_probe_banner: bool = false;
        pub const framebuffer_probe_banner: bool = false;
        pub const ata_storage_probe: bool = false;
        pub const rtl8139_probe: bool = false;
        pub const rtl8139_arp_probe: bool = false;
        pub const rtl8139_ipv4_probe: bool = false;
        pub const rtl8139_udp_probe: bool = false;
        pub const rtl8139_tcp_probe: bool = false;
        pub const rtl8139_dhcp_probe: bool = false;
        pub const rtl8139_dns_probe: bool = false;
        pub const tool_exec_probe: bool = false;
        pub const rtl8139_gateway_probe: bool = false;
    }
else
    @import("build_options");
const qemu_smoke_enabled: bool = build_options.qemu_smoke;
const console_probe_banner_enabled: bool = build_options.console_probe_banner;
const framebuffer_probe_banner_enabled: bool = build_options.framebuffer_probe_banner;
const ata_storage_probe_enabled: bool = build_options.ata_storage_probe;
const rtl8139_probe_enabled: bool = build_options.rtl8139_probe;
const rtl8139_arp_probe_enabled: bool = build_options.rtl8139_arp_probe;
const rtl8139_ipv4_probe_enabled: bool = build_options.rtl8139_ipv4_probe;
const rtl8139_udp_probe_enabled: bool = build_options.rtl8139_udp_probe;
const rtl8139_tcp_probe_enabled: bool = build_options.rtl8139_tcp_probe;
const rtl8139_dhcp_probe_enabled: bool = build_options.rtl8139_dhcp_probe;
const rtl8139_dns_probe_enabled: bool = build_options.rtl8139_dns_probe;
const tool_exec_probe_enabled: bool = build_options.tool_exec_probe;
const rtl8139_gateway_probe_enabled: bool = build_options.rtl8139_gateway_probe;

const ata_probe_raw_lba: u32 = 300;
const ata_probe_raw_block_count: u32 = 2;
const ata_probe_raw_seed: u8 = 0x41;
const ata_probe_tool_slot_id: u32 = 1;
const ata_probe_tool_slot_byte_len: u32 = 600;
const ata_probe_tool_slot_seed: u8 = 0x30;
const ata_probe_tool_slot_expected_lba: u32 = tool_layout.slot_data_lba + (@as(u32, ata_probe_tool_slot_id) * @as(u32, tool_layout.slot_block_capacity));
const ata_probe_filesystem_dir = "/runtime/state";
const ata_probe_filesystem_path = "/runtime/state/ata.json";
const ata_probe_filesystem_payload = "{\"disk\":\"ata\"}";

const AtaStorageProbeError = error{
    AtaBackendUnavailable,
    AtaCapacityTooSmall,
    RawPatternWriteFailed,
    RawPatternFlushFailed,
    RawPatternReadbackFailed,
    ToolLayoutInitFailed,
    ToolLayoutWriteFailed,
    ToolLayoutReadbackFailed,
    ToolLayoutReloadFailed,
    FilesystemInitFailed,
    FilesystemDirCreateFailed,
    FilesystemWriteFailed,
    FilesystemReadbackFailed,
    FilesystemReloadFailed,
};

const Rtl8139ProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    TxFailed,
    DataPathDropped,
    TxCompletedNoRxInterrupt,
    TxCompletedNoRxProgress,
    RxProducerStalled,
    RxProducerAdvancedNoFrame,
    RxLengthMismatch,
    RxPatternMismatch,
    CounterMismatch,
};

const Rtl8139ArpProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    TxFailed,
    RxTimedOut,
    PacketMissing,
    PacketDestinationMismatch,
    PacketSourceMismatch,
    PacketOperationMismatch,
    PacketSenderMismatch,
    PacketTargetMismatch,
    CounterMismatch,
};

const Rtl8139GatewayProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    RouteUnconfigured,
    UnexpectedGatewayBypass,
    UnexpectedGatewayUse,
    AddressUnresolved,
    ArpRequestMissing,
    ArpRequestTargetMismatch,
    ArpRequestSenderMismatch,
    ArpReplySendFailed,
    ArpReplyMissing,
    ArpReplyOperationMismatch,
    ArpReplyTargetMismatch,
    ArpLearnFailed,
    PacketMissing,
    PacketDestinationMismatch,
    PacketSourceMismatch,
    PacketProtocolMismatch,
    PacketSenderMismatch,
    PacketTargetMismatch,
    PacketPortsMismatch,
    PayloadMismatch,
    FrameLengthMismatch,
    CounterMismatch,
};

const Rtl8139Ipv4ProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    TxFailed,
    RxTimedOut,
    LastFrameTooShort,
    LastFrameNotIpv4,
    LastIpv4DecodeFailed,
    DataPathDropped,
    TxCompletedNoRxInterrupt,
    TxCompletedNoRxProgress,
    RxProducerStalled,
    RxProducerAdvancedNoFrame,
    PacketMissing,
    PacketDestinationMismatch,
    PacketSourceMismatch,
    PacketProtocolMismatch,
    PacketSenderMismatch,
    PacketTargetMismatch,
    PayloadMismatch,
    FrameLengthMismatch,
    CounterMismatch,
};

const Rtl8139UdpProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    TxFailed,
    RxTimedOut,
    LastFrameTooShort,
    LastFrameNotIpv4,
    LastIpv4DecodeFailed,
    LastPacketNotUdp,
    LastUdpDecodeFailed,
    DataPathDropped,
    TxCompletedNoRxInterrupt,
    TxCompletedNoRxProgress,
    RxProducerStalled,
    RxProducerAdvancedNoFrame,
    PacketMissing,
    PacketDestinationMismatch,
    PacketSourceMismatch,
    PacketProtocolMismatch,
    PacketSenderMismatch,
    PacketTargetMismatch,
    PacketPortsMismatch,
    ChecksumMissing,
    PayloadMismatch,
    FrameLengthMismatch,
    CounterMismatch,
};

const Rtl8139TcpProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    TxFailed,
    RxTimedOut,
    LastFrameTooShort,
    LastFrameNotIpv4,
    LastIpv4DecodeFailed,
    LastPacketNotTcp,
    LastTcpDecodeFailed,
    DataPathDropped,
    TxCompletedNoRxInterrupt,
    TxCompletedNoRxProgress,
    RxProducerStalled,
    RxProducerAdvancedNoFrame,
    PacketMissing,
    PacketDestinationMismatch,
    PacketSourceMismatch,
    PacketProtocolMismatch,
    PacketSenderMismatch,
    PacketTargetMismatch,
    PacketPortsMismatch,
    PacketSequenceMismatch,
    PacketAcknowledgmentMismatch,
    PacketFlagsMismatch,
    WindowSizeMismatch,
    PayloadMismatch,
    FrameLengthMismatch,
    CounterMismatch,
    SessionStateMismatch,
    RetransmitTooEarly,
    RetransmitMissing,
    RetransmitShapeMismatch,
    RetransmitNotCleared,
};

const Rtl8139DhcpProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    TxFailed,
    RxTimedOut,
    LastFrameTooShort,
    LastFrameNotIpv4,
    LastIpv4DecodeFailed,
    LastPacketNotUdp,
    LastUdpDecodeFailed,
    LastPacketNotDhcp,
    LastDhcpDecodeFailed,
    DataPathDropped,
    TxCompletedNoRxInterrupt,
    TxCompletedNoRxProgress,
    RxProducerStalled,
    RxProducerAdvancedNoFrame,
    PacketMissing,
    PacketDestinationMismatch,
    PacketSourceMismatch,
    PacketProtocolMismatch,
    PacketSenderMismatch,
    PacketTargetMismatch,
    PacketPortsMismatch,
    PacketOperationMismatch,
    TransactionIdMismatch,
    MessageTypeMismatch,
    PacketClientMacMismatch,
    ParameterRequestListMismatch,
    FlagsMismatch,
    MaxMessageSizeMismatch,
    ChecksumMissing,
    FrameLengthMismatch,
    CounterMismatch,
};

const Rtl8139DnsProbeError = error{
    UnsupportedPlatform,
    DeviceNotFound,
    ResetTimeout,
    BufferProgramFailed,
    MacReadFailed,
    DataPathEnableFailed,
    StateMagicMismatch,
    BackendMismatch,
    InitFlagMismatch,
    HardwareBackedMismatch,
    IoBaseMismatch,
    TxFailed,
    RxTimedOut,
    LastFrameTooShort,
    LastFrameNotIpv4,
    LastIpv4DecodeFailed,
    LastPacketNotUdp,
    LastUdpDecodeFailed,
    LastPacketNotDns,
    LastDnsDecodeFailed,
    DataPathDropped,
    TxCompletedNoRxInterrupt,
    TxCompletedNoRxProgress,
    RxProducerStalled,
    RxProducerAdvancedNoFrame,
    PacketMissing,
    PacketDestinationMismatch,
    PacketSourceMismatch,
    PacketProtocolMismatch,
    PacketSenderMismatch,
    PacketTargetMismatch,
    PacketPortsMismatch,
    TransactionIdMismatch,
    FlagsMismatch,
    QuestionCountMismatch,
    QuestionNameMismatch,
    QuestionTypeMismatch,
    QuestionClassMismatch,
    AnswerCountMismatch,
    AnswerNameMismatch,
    AnswerTypeMismatch,
    AnswerClassMismatch,
    AnswerTtlMismatch,
    AnswerDataMismatch,
    ChecksumMissing,
    FrameLengthMismatch,
    CounterMismatch,
};

const ToolExecProbeError = error{
    AllocatorExhausted,
    HelpRunFailed,
    HelpExitCodeFailed,
    HelpMissingBuiltin,
    MkdirRunFailed,
    MkdirExitCodeFailed,
    MkdirOutputMismatch,
    WriteRunFailed,
    WriteExitCodeFailed,
    WriteOutputMismatch,
    CatRunFailed,
    CatExitCodeFailed,
    CatMismatch,
    StatRunFailed,
    StatExitCodeFailed,
    StatMismatch,
    EchoRunFailed,
    EchoExitCodeFailed,
    EchoOutputMismatch,
    UnexpectedStderr,
    FilesystemReadbackFailed,
    FilesystemReadbackMismatch,
};

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
var wake_queue_count_query: BaremetalWakeQueueCountQuery = .{
    .vector = 0,
    .reason = 0,
    .reserved0 = 0,
    .reserved1 = 0,
    .max_tick = 0,
};
var wake_queue_count_snapshot: BaremetalWakeQueueCountSnapshot = std.mem.zeroes(BaremetalWakeQueueCountSnapshot);
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

pub export fn oc_console_state_ptr() *const BaremetalConsoleState {
    return vga_text_console.statePtr();
}

pub export fn oc_console_init() void {
    vga_text_console.init();
}

pub export fn oc_console_clear() void {
    vga_text_console.clear();
}

pub export fn oc_console_putc(byte: u8) void {
    vga_text_console.putByte(byte);
}

pub export fn oc_console_cell(index: u32) u16 {
    return vga_text_console.cell(index);
}

pub export fn oc_framebuffer_state_ptr() *const BaremetalFramebufferState {
    return framebuffer_console.statePtr();
}

pub export fn oc_framebuffer_init() u8 {
    return if (framebuffer_console.init()) 1 else 0;
}

pub export fn oc_framebuffer_clear() void {
    framebuffer_console.clear();
}

pub export fn oc_framebuffer_putc(byte: u8) void {
    framebuffer_console.putByte(byte);
}

pub export fn oc_framebuffer_pixel(index: u32) u32 {
    return framebuffer_console.pixel(index);
}

pub export fn oc_framebuffer_pixel_at(x: u32, y: u32) u32 {
    return framebuffer_console.pixelAt(x, y);
}

pub export fn oc_keyboard_state_ptr() *const BaremetalKeyboardState {
    return ps2_input.keyboardStatePtr();
}

pub export fn oc_keyboard_event(index: u32) BaremetalKeyboardEvent {
    return ps2_input.keyboardEvent(index);
}

pub export fn oc_keyboard_inject_scancode(scancode: u8) void {
    ps2_input.injectKeyboardScancode(scancode);
}

pub export fn oc_mouse_state_ptr() *const BaremetalMouseState {
    return ps2_input.mouseStatePtr();
}

pub export fn oc_mouse_packet(index: u32) BaremetalMousePacket {
    return ps2_input.mousePacket(index);
}

pub export fn oc_mouse_inject_packet(buttons: u8, dx: i16, dy: i16) void {
    ps2_input.injectMousePacket(buttons, dx, dy);
}

pub export fn oc_ethernet_state_ptr() *const BaremetalEthernetState {
    return rtl8139.statePtr();
}

pub export fn oc_ethernet_init() u8 {
    return if (rtl8139.init()) 1 else 0;
}

pub export fn oc_ethernet_reset() u8 {
    rtl8139.resetForTest();
    return if (rtl8139.init()) 1 else 0;
}

pub export fn oc_ethernet_mac_byte(index: u32) u8 {
    return rtl8139.macByte(index);
}

pub export fn oc_ethernet_send_pattern(byte_len: u32, seed: u8) i16 {
    _ = rtl8139.sendPattern(byte_len, seed) catch return abi.result_not_supported;
    return abi.result_ok;
}

pub export fn oc_ethernet_poll() u32 {
    return rtl8139.pollReceive() catch 0;
}

pub export fn oc_ethernet_rx_byte(index: u32) u8 {
    return rtl8139.rxByte(index);
}

pub export fn oc_ethernet_rx_len() u32 {
    return rtl8139.statePtr().last_rx_len;
}

pub export fn oc_storage_state_ptr() *const BaremetalStorageState {
    return storage_backend.statePtr();
}

pub export fn oc_storage_init() void {
    storage_backend.init();
}

pub export fn oc_storage_reset() void {
    storage_backend.resetForTest();
    storage_backend.init();
}

pub export fn oc_storage_read_byte(lba: u32, offset: u32) u8 {
    return storage_backend.readByte(lba, offset);
}

pub export fn oc_storage_flush() i16 {
    storage_backend.flush() catch |err| return mapStorageError(err);
    return abi.result_ok;
}

pub export fn oc_storage_write_pattern(lba: u32, block_count: u32, seed: u8) i16 {
    storage_backend.init();
    var scratch = [_]u8{0} ** storage_backend.block_size;
    var block_idx: u32 = 0;
    while (block_idx < block_count) : (block_idx += 1) {
        for (&scratch, 0..) |*byte, offset| {
            const global_offset = (@as(usize, block_idx) * storage_backend.block_size) + offset;
            byte.* = seed +% @as(u8, @truncate(global_offset));
        }
        storage_backend.writeBlocks(lba + block_idx, scratch[0..]) catch |err| return mapStorageError(err);
    }
    return abi.result_ok;
}

pub export fn oc_tool_layout_state_ptr() *const BaremetalToolLayoutState {
    return tool_layout.statePtr();
}

pub export fn oc_tool_layout_init() i16 {
    tool_layout.init() catch |err| return mapStorageError(err);
    return abi.result_ok;
}

pub export fn oc_tool_layout_slot(slot_id: u32) BaremetalToolSlot {
    return tool_layout.slot(slot_id);
}

pub export fn oc_tool_slot_write_pattern(slot_id: u32, byte_len: u32, seed: u8) i16 {
    tool_layout.init() catch |err| return mapStorageError(err);
    tool_layout.writePattern(slot_id, byte_len, seed, status.ticks) catch |err| return mapStorageError(err);
    return abi.result_ok;
}

pub export fn oc_tool_slot_clear(slot_id: u32) i16 {
    tool_layout.init() catch |err| return mapStorageError(err);
    tool_layout.clearSlot(slot_id, status.ticks) catch |err| return mapStorageError(err);
    return abi.result_ok;
}

pub export fn oc_tool_slot_byte(slot_id: u32, offset: u32) u8 {
    return tool_layout.readToolByte(slot_id, offset);
}

pub export fn oc_filesystem_state_ptr() *const BaremetalFilesystemState {
    return filesystem.statePtr();
}

pub export fn oc_filesystem_entry(index: u32) BaremetalFilesystemEntry {
    return filesystem.entry(index);
}

pub export fn oc_filesystem_init() i16 {
    filesystem.init() catch |err| return mapStorageError(err);
    return abi.result_ok;
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

fn timerClearEntriesPreserveState() void {
    @memset(&timer_entries, std.mem.zeroes(BaremetalTimerEntry));
    timer_state.timer_count = 0;
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
}

pub export fn oc_scheduler_reset() void {
    @memset(&scheduler_tasks, std.mem.zeroes(BaremetalTask));
    @memset(&scheduler_wait_kind, wait_condition_none);
    @memset(&scheduler_wait_interrupt_vector, 0);
    @memset(&scheduler_wait_timeout_tick, 0);
    oc_wake_queue_clear();
    timerClearEntriesPreserveState();
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

pub export fn oc_wake_queue_count_query_ptr() *BaremetalWakeQueueCountQuery {
    return &wake_queue_count_query;
}

pub export fn oc_wake_queue_count_snapshot_ptr() *const BaremetalWakeQueueCountSnapshot {
    wake_queue_count_snapshot.vector_count = oc_wake_queue_vector_count(wake_queue_count_query.vector);
    wake_queue_count_snapshot.before_tick_count = oc_wake_queue_before_tick_count(wake_queue_count_query.max_tick);
    wake_queue_count_snapshot.reason_vector_count = oc_wake_queue_reason_vector_count(
        wake_queue_count_query.reason,
        wake_queue_count_query.vector,
    );
    wake_queue_count_snapshot.reserved0 = 0;
    return &wake_queue_count_snapshot;
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
    var slot: usize = 0;
    while (slot < scheduler_task_capacity) : (slot += 1) {
        if (scheduler_tasks[slot].state != abi.task_state_waiting) continue;
        const kind = scheduler_wait_kind[slot];
        if (kind == wait_condition_timer) {
            schedulerSetWaitCondition(slot, wait_condition_manual, 0);
            continue;
        }
        if ((kind == wait_condition_interrupt_any or kind == wait_condition_interrupt_vector) and
            scheduler_wait_timeout_tick[slot] != 0)
        {
            schedulerSetWaitCondition(slot, kind, scheduler_wait_interrupt_vector[slot]);
        }
    }
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
    ps2_input.processInterruptHistory(status.ticks);
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
    vga_text_console.init();
    if (framebuffer_probe_banner_enabled) {
        _ = framebuffer_console.initForProbe();
    } else {
        _ = framebuffer_console.init();
    }
    storage_backend.init();
    if (ata_storage_probe_enabled) {
        runAtaStorageProbe() catch |err| qemuExit(ataStorageProbeFailureCode(err));
        qemuExit(qemu_ata_storage_probe_ok_code);
    }
    if (rtl8139_probe_enabled) {
        runRtl8139Probe() catch |err| qemuExit(rtl8139ProbeFailureCode(err));
        qemuExit(qemu_rtl8139_probe_ok_code);
    }
    if (rtl8139_arp_probe_enabled) {
        runRtl8139ArpProbe() catch |err| qemuExit(rtl8139ArpProbeFailureCode(err));
        qemuExit(qemu_rtl8139_arp_probe_ok_code);
    }
    if (rtl8139_ipv4_probe_enabled) {
        runRtl8139Ipv4Probe() catch |err| qemuExit(rtl8139Ipv4ProbeFailureCode(err));
        qemuExit(qemu_rtl8139_ipv4_probe_ok_code);
    }
    if (rtl8139_udp_probe_enabled) {
        runRtl8139UdpProbe() catch |err| qemuExit(rtl8139UdpProbeFailureCode(err));
        qemuExit(qemu_rtl8139_udp_probe_ok_code);
    }
    if (rtl8139_tcp_probe_enabled) {
        runRtl8139TcpProbe() catch |err| qemuExit(rtl8139TcpProbeFailureCode(err));
        qemuExit(qemu_rtl8139_tcp_probe_ok_code);
    }
    if (rtl8139_dhcp_probe_enabled) {
        runRtl8139DhcpProbe() catch |err| qemuExit(rtl8139DhcpProbeFailureCode(err));
        qemuExit(qemu_rtl8139_dhcp_probe_ok_code);
    }
    if (rtl8139_dns_probe_enabled) {
        runRtl8139DnsProbe() catch |err| qemuExit(rtl8139DnsProbeFailureCode(err));
        qemuExit(qemu_rtl8139_dns_probe_ok_code);
    }
    if (tool_exec_probe_enabled) {
        runToolExecProbe() catch |err| qemuExit(toolExecProbeFailureCode(err));
        qemuExit(qemu_tool_exec_probe_ok_code);
    }
    if (rtl8139_gateway_probe_enabled) {
        runRtl8139GatewayProbe() catch |err| qemuExit(rtl8139GatewayProbeFailureCode(err));
        qemuExit(qemu_rtl8139_gateway_probe_ok_code);
    }
    ps2_input.init();
    tool_layout.init() catch unreachable;
    if (console_probe_banner_enabled) {
        vga_text_console.clear();
        vga_text_console.write("OK");
    }
    if (framebuffer_probe_banner_enabled) {
        framebuffer_console.write("OK");
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

fn runAtaStorageProbe() AtaStorageProbeError!void {
    storage_backend.init();
    const storage = storage_backend.statePtr();
    if (storage.backend != abi.storage_backend_ata_pio or storage.mounted == 0) {
        return error.AtaBackendUnavailable;
    }
    if (storage.block_count <= ata_probe_raw_lba + ata_probe_raw_block_count) {
        return error.AtaCapacityTooSmall;
    }

    if (oc_storage_write_pattern(ata_probe_raw_lba, ata_probe_raw_block_count, ata_probe_raw_seed) != abi.result_ok) {
        return error.RawPatternWriteFailed;
    }
    if (oc_storage_flush() != abi.result_ok) {
        return error.RawPatternFlushFailed;
    }
    if (oc_storage_read_byte(ata_probe_raw_lba, 0) != ata_probe_raw_seed or
        oc_storage_read_byte(ata_probe_raw_lba, 1) != ata_probe_raw_seed +% 1 or
        oc_storage_read_byte(ata_probe_raw_lba + 1, 0) != ata_probe_raw_seed)
    {
        return error.RawPatternReadbackFailed;
    }

    tool_layout.resetForTest();
    tool_layout.init() catch return error.ToolLayoutInitFailed;
    tool_layout.writePattern(ata_probe_tool_slot_id, ata_probe_tool_slot_byte_len, ata_probe_tool_slot_seed, status.ticks) catch return error.ToolLayoutWriteFailed;
    const slot = tool_layout.slot(ata_probe_tool_slot_id);
    if (slot.start_lba != ata_probe_tool_slot_expected_lba or
        tool_layout.readToolByte(ata_probe_tool_slot_id, 0) != ata_probe_tool_slot_seed or
        tool_layout.readToolByte(ata_probe_tool_slot_id, 1) != ata_probe_tool_slot_seed +% 1 or
        tool_layout.readToolByte(ata_probe_tool_slot_id, 512) != ata_probe_tool_slot_seed or
        storage_backend.readByte(slot.start_lba, 0) != ata_probe_tool_slot_seed)
    {
        return error.ToolLayoutReadbackFailed;
    }

    tool_layout.resetForTest();
    tool_layout.init() catch return error.ToolLayoutReloadFailed;
    if (tool_layout.readToolByte(ata_probe_tool_slot_id, 0) != ata_probe_tool_slot_seed or
        tool_layout.readToolByte(ata_probe_tool_slot_id, 512) != ata_probe_tool_slot_seed)
    {
        return error.ToolLayoutReloadFailed;
    }

    filesystem.resetForTest();
    filesystem.init() catch return error.FilesystemInitFailed;
    if (filesystem.statePtr().active_backend != abi.storage_backend_ata_pio) {
        return error.FilesystemInitFailed;
    }
    filesystem.createDirPath(ata_probe_filesystem_dir) catch return error.FilesystemDirCreateFailed;
    filesystem.writeFile(ata_probe_filesystem_path, ata_probe_filesystem_payload, status.ticks) catch return error.FilesystemWriteFailed;
    if (!probeFilesystemContent(ata_probe_filesystem_path, ata_probe_filesystem_payload)) {
        return error.FilesystemReadbackFailed;
    }

    filesystem.resetForTest();
    filesystem.init() catch return error.FilesystemReloadFailed;
    if (filesystem.statePtr().active_backend != abi.storage_backend_ata_pio or
        !probeFilesystemContent(ata_probe_filesystem_path, ata_probe_filesystem_payload))
    {
        return error.FilesystemReloadFailed;
    }
}

fn runRtl8139Probe() Rtl8139ProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };
    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;
    if (macBytesAreZero()) return error.MacReadFailed;

    const expected_len: u32 = 96;
    if (oc_ethernet_send_pattern(expected_len, 0x41) != abi.result_ok) return error.TxFailed;

    var attempts: usize = 0;
    var observed_len: u32 = 0;
    while (attempts < 20_000) : (attempts += 1) {
        observed_len = oc_ethernet_poll();
        if (observed_len != 0) break;
        spinPause(1);
    }
    if (observed_len == 0) {
        const producer = rtl8139.debugProducerOffset();
        const consumer: u16 = @intCast(eth.rx_consumer_offset & 0xFFFF);
        const cr = rtl8139.debugCommandRegister();
        const isr = rtl8139.debugInterruptStatus();
        const tx_status = rtl8139.debugLastTxStatus();
        if ((cr & 0x0C) != 0x0C) return error.DataPathDropped;
        if ((tx_status & 0x0000_8000) != 0 and (isr & 0x0004) != 0 and (isr & 0x0001) == 0) {
            return if (producer == consumer) error.TxCompletedNoRxInterrupt else error.RxProducerAdvancedNoFrame;
        }
        if ((tx_status & 0x0000_8000) != 0 and producer == consumer) return error.TxCompletedNoRxProgress;
        return if (producer == consumer) error.RxProducerStalled else error.RxProducerAdvancedNoFrame;
    }
    if (observed_len != expected_len) return error.RxLengthMismatch;

    var index: u32 = 0;
    while (index < 6) : (index += 1) {
        if (oc_ethernet_rx_byte(index) != oc_ethernet_mac_byte(index)) return error.RxPatternMismatch;
        if (oc_ethernet_rx_byte(6 + index) != oc_ethernet_mac_byte(index)) return error.RxPatternMismatch;
    }
    if (oc_ethernet_rx_byte(12) != 0x88 or oc_ethernet_rx_byte(13) != 0xB5) return error.RxPatternMismatch;

    index = 14;
    while (index < expected_len) : (index += 1) {
        const expected = 0x41 +% @as(u8, @truncate(index - 14));
        if (oc_ethernet_rx_byte(index) != expected) return error.RxPatternMismatch;
    }

    if (eth.tx_packets == 0 or eth.rx_packets == 0 or eth.last_rx_len != expected_len) return error.CounterMismatch;
}

fn macBytesAreZero() bool {
    var index: u32 = 0;
    while (index < 6) : (index += 1) {
        if (oc_ethernet_mac_byte(index) != 0) return false;
    }
    return true;
}

fn rtl8139ProbeFailureCode(err: Rtl8139ProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0x60,
        error.DeviceNotFound => 0x61,
        error.ResetTimeout => 0x62,
        error.BufferProgramFailed => 0x63,
        error.MacReadFailed => 0x64,
        error.StateMagicMismatch => 0x65,
        error.BackendMismatch => 0x66,
        error.InitFlagMismatch => 0x67,
        error.HardwareBackedMismatch => 0x68,
        error.IoBaseMismatch => 0x69,
        error.TxFailed => 0x6A,
        error.RxProducerStalled => 0x6B,
        error.RxProducerAdvancedNoFrame => 0x6C,
        error.RxLengthMismatch => 0x6D,
        error.RxPatternMismatch => 0x6E,
        error.CounterMismatch => 0x6F,
        error.DataPathDropped => 0x70,
        error.TxCompletedNoRxInterrupt => 0x71,
        error.TxCompletedNoRxProgress => 0x72,
        error.DataPathEnableFailed => 0x73,
    };
}

fn runRtl8139ArpProbe() Rtl8139ArpProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };

    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;

    const sender_ip = [4]u8{ 192, 168, 56, 10 };
    const target_ip = [4]u8{ 192, 168, 56, 1 };
    if ((pal_net.sendArpRequest(sender_ip, target_ip) catch return error.TxFailed) != arp_protocol.frame_len) {
        return error.TxFailed;
    }

    var attempts: usize = 0;
    var packet_opt: ?pal_net.ArpPacket = null;
    while (attempts < 20_000) : (attempts += 1) {
        packet_opt = pal_net.pollArpPacket() catch return error.PacketMissing;
        if (packet_opt != null) break;
        spinPause(1);
    }
    const packet = packet_opt orelse return error.RxTimedOut;

    if (!std.mem.eql(u8, ethernet_protocol.broadcast_mac[0..], packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
    if (!std.mem.eql(u8, eth.mac[0..], packet.ethernet_source[0..])) return error.PacketSourceMismatch;
    if (packet.operation != arp_protocol.operation_request) return error.PacketOperationMismatch;
    if (!std.mem.eql(u8, eth.mac[0..], packet.sender_mac[0..]) or !std.mem.eql(u8, sender_ip[0..], packet.sender_ip[0..])) {
        return error.PacketSenderMismatch;
    }
    if (!std.mem.eql(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, packet.target_mac[0..]) or !std.mem.eql(u8, target_ip[0..], packet.target_ip[0..])) {
        return error.PacketTargetMismatch;
    }
    if (eth.tx_packets == 0 or eth.rx_packets == 0 or eth.last_rx_len < arp_protocol.frame_len) return error.CounterMismatch;
}

fn rtl8139ArpProbeFailureCode(err: Rtl8139ArpProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0x74,
        error.DeviceNotFound => 0x75,
        error.ResetTimeout => 0x76,
        error.BufferProgramFailed => 0x77,
        error.MacReadFailed => 0x78,
        error.DataPathEnableFailed => 0x79,
        error.StateMagicMismatch => 0x7A,
        error.BackendMismatch => 0x7B,
        error.InitFlagMismatch => 0x7C,
        error.HardwareBackedMismatch => 0x7D,
        error.IoBaseMismatch => 0x7E,
        error.TxFailed => 0x7F,
        error.RxTimedOut => 0x80,
        error.PacketMissing => 0x81,
        error.PacketDestinationMismatch => 0x82,
        error.PacketSourceMismatch => 0x83,
        error.PacketOperationMismatch => 0x84,
        error.PacketSenderMismatch => 0x85,
        error.PacketTargetMismatch => 0x86,
        error.CounterMismatch => 0x87,
    };
}

fn runRtl8139GatewayProbe() Rtl8139GatewayProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };

    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;

    pal_net.clearRouteState();
    const local_ip = [4]u8{ 192, 168, 56, 10 };
    const gateway_ip = [4]u8{ 192, 168, 56, 1 };
    const remote_ip = [4]u8{ 1, 1, 1, 1 };
    const local_peer_ip = [4]u8{ 192, 168, 56, 77 };
    const gateway_mac = [6]u8{ 0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0x01 };
    const local_peer_mac = [6]u8{ 0x02, 0x10, 0x20, 0x30, 0x40, 0x50 };
    const remote_payload = "ROUTED-UDP";
    const local_payload = "DIRECT-UDP";
    pal_net.configureIpv4Route(local_ip, .{ 255, 255, 255, 0 }, gateway_ip);
    if (!pal_net.routeStatePtr().configured) return error.RouteUnconfigured;

    const remote_route = pal_net.resolveNextHop(remote_ip) catch return error.RouteUnconfigured;
    if (!remote_route.used_gateway) return error.UnexpectedGatewayBypass;
    if (!std.mem.eql(u8, gateway_ip[0..], remote_route.next_hop_ip[0..])) return error.UnexpectedGatewayBypass;

    _ = pal_net.sendUdpPacketRouted(remote_ip, 54000, 53, remote_payload) catch |err| switch (err) {
        error.AddressUnresolved => {},
        error.RouteUnconfigured => return error.RouteUnconfigured,
        else => return error.AddressUnresolved,
    };

    var attempts: usize = 0;
    var arp_packet_opt: ?pal_net.ArpPacket = null;
    while (attempts < 20_000) : (attempts += 1) {
        arp_packet_opt = pal_net.pollArpPacket() catch return error.ArpRequestMissing;
        if (arp_packet_opt != null) break;
        spinPause(1);
    }
    const request_packet = arp_packet_opt orelse return error.ArpRequestMissing;
    if (!std.mem.eql(u8, gateway_ip[0..], request_packet.target_ip[0..])) return error.ArpRequestTargetMismatch;
    if (!std.mem.eql(u8, local_ip[0..], request_packet.sender_ip[0..])) return error.ArpRequestSenderMismatch;
    if (pal_net.learnArpPacket(request_packet)) return error.ArpLearnFailed;

    var reply_frame: [arp_protocol.frame_len]u8 = undefined;
    const reply_len = arp_protocol.encodeReplyFrame(reply_frame[0..], gateway_mac, gateway_ip, eth.mac, local_ip) catch return error.ArpReplySendFailed;
    pal_net.sendFrame(reply_frame[0..reply_len]) catch return error.ArpReplySendFailed;
    attempts = 0;
    arp_packet_opt = null;
    while (attempts < 20_000) : (attempts += 1) {
        arp_packet_opt = pal_net.pollArpPacket() catch return error.ArpReplyMissing;
        if (arp_packet_opt != null) break;
        spinPause(1);
    }
    const reply_packet = arp_packet_opt orelse return error.ArpReplyMissing;
    if (reply_packet.operation != arp_protocol.operation_reply) return error.ArpReplyOperationMismatch;
    if (!std.mem.eql(u8, local_ip[0..], reply_packet.target_ip[0..])) return error.ArpReplyTargetMismatch;
    if (!pal_net.learnArpPacket(reply_packet)) return error.ArpLearnFailed;

    const expected_remote_wire_len: u32 = ethernet_protocol.header_len + ipv4_protocol.header_len + udp_protocol.header_len + remote_payload.len;
    const expected_remote_frame_len: u32 = @max(expected_remote_wire_len, 60);
    if ((pal_net.sendUdpPacketRouted(remote_ip, 54000, 53, remote_payload) catch return error.AddressUnresolved) != expected_remote_wire_len) {
        return error.AddressUnresolved;
    }

    var packet_received = false;
    var routed_packet_storage: pal_net.UdpPacket = undefined;
    attempts = 0;
    while (attempts < 20_000) : (attempts += 1) {
        packet_received = pal_net.pollUdpPacketStrictInto(&routed_packet_storage) catch return error.PacketMissing;
        if (packet_received) break;
        spinPause(1);
    }
    if (!packet_received) return error.PacketMissing;
    const routed_packet = &routed_packet_storage;
    if (!std.mem.eql(u8, gateway_mac[0..], routed_packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
    if (!std.mem.eql(u8, eth.mac[0..], routed_packet.ethernet_source[0..])) return error.PacketSourceMismatch;
    if (routed_packet.ipv4_header.protocol != ipv4_protocol.protocol_udp) return error.PacketProtocolMismatch;
    if (!std.mem.eql(u8, local_ip[0..], routed_packet.ipv4_header.source_ip[0..])) return error.PacketSenderMismatch;
    if (!std.mem.eql(u8, remote_ip[0..], routed_packet.ipv4_header.destination_ip[0..])) return error.PacketTargetMismatch;
    if (routed_packet.source_port != 54000 or routed_packet.destination_port != 53) return error.PacketPortsMismatch;
    if (!std.mem.eql(u8, remote_payload, routed_packet.payload[0..routed_packet.payload_len])) return error.PayloadMismatch;
    if (eth.last_rx_len != expected_remote_frame_len) return error.FrameLengthMismatch;
    if (!pal_net.routeStatePtr().last_used_gateway or !pal_net.routeStatePtr().last_cache_hit) return error.UnexpectedGatewayBypass;

    var local_reply_frame: [arp_protocol.frame_len]u8 = undefined;
    const local_reply_len = arp_protocol.encodeReplyFrame(local_reply_frame[0..], local_peer_mac, local_peer_ip, eth.mac, local_ip) catch return error.ArpReplySendFailed;
    pal_net.sendFrame(local_reply_frame[0..local_reply_len]) catch return error.ArpReplySendFailed;
    attempts = 0;
    arp_packet_opt = null;
    while (attempts < 20_000) : (attempts += 1) {
        arp_packet_opt = pal_net.pollArpPacket() catch return error.ArpReplyMissing;
        if (arp_packet_opt != null) break;
        spinPause(1);
    }
    const local_reply_packet = arp_packet_opt orelse return error.ArpReplyMissing;
    if (!pal_net.learnArpPacket(local_reply_packet)) return error.ArpLearnFailed;

    const local_route = pal_net.resolveNextHop(local_peer_ip) catch return error.RouteUnconfigured;
    if (local_route.used_gateway) return error.UnexpectedGatewayUse;

    const expected_local_wire_len: u32 = ethernet_protocol.header_len + ipv4_protocol.header_len + udp_protocol.header_len + local_payload.len;
    const expected_local_frame_len: u32 = @max(expected_local_wire_len, 60);
    if ((pal_net.sendUdpPacketRouted(local_peer_ip, 54001, 9001, local_payload) catch return error.AddressUnresolved) != expected_local_wire_len) {
        return error.AddressUnresolved;
    }

    packet_received = false;
    attempts = 0;
    while (attempts < 20_000) : (attempts += 1) {
        packet_received = pal_net.pollUdpPacketStrictInto(&routed_packet_storage) catch return error.PacketMissing;
        if (packet_received) break;
        spinPause(1);
    }
    if (!packet_received) return error.PacketMissing;
    if (!std.mem.eql(u8, local_peer_mac[0..], routed_packet_storage.ethernet_destination[0..])) return error.PacketDestinationMismatch;
    if (!std.mem.eql(u8, local_ip[0..], routed_packet_storage.ipv4_header.source_ip[0..])) return error.PacketSenderMismatch;
    if (!std.mem.eql(u8, local_peer_ip[0..], routed_packet_storage.ipv4_header.destination_ip[0..])) return error.PacketTargetMismatch;
    if (routed_packet_storage.source_port != 54001 or routed_packet_storage.destination_port != 9001) return error.PacketPortsMismatch;
    if (!std.mem.eql(u8, local_payload, routed_packet_storage.payload[0..routed_packet_storage.payload_len])) return error.PayloadMismatch;
    if (eth.last_rx_len != expected_local_frame_len) return error.FrameLengthMismatch;
    if (pal_net.routeStatePtr().last_used_gateway or !pal_net.routeStatePtr().last_cache_hit) return error.UnexpectedGatewayUse;
    if (eth.tx_packets < 5 or eth.rx_packets < 5) return error.CounterMismatch;
}

fn rtl8139GatewayProbeFailureCode(err: Rtl8139GatewayProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0x91,
        error.DeviceNotFound => 0x92,
        error.ResetTimeout => 0x93,
        error.BufferProgramFailed => 0x94,
        error.MacReadFailed => 0x95,
        error.DataPathEnableFailed => 0x96,
        error.StateMagicMismatch => 0x97,
        error.BackendMismatch => 0x98,
        error.InitFlagMismatch => 0x99,
        error.HardwareBackedMismatch => 0x9A,
        error.IoBaseMismatch => 0x9B,
        error.RouteUnconfigured => 0x9C,
        error.UnexpectedGatewayBypass => 0x9D,
        error.UnexpectedGatewayUse => 0x9E,
        error.AddressUnresolved => 0x9F,
        error.ArpRequestMissing => 0xA0,
        error.ArpRequestTargetMismatch => 0xA1,
        error.ArpRequestSenderMismatch => 0xA2,
        error.ArpReplySendFailed => 0xA3,
        error.ArpReplyMissing => 0xA4,
        error.ArpReplyOperationMismatch => 0xA5,
        error.ArpReplyTargetMismatch => 0xA6,
        error.ArpLearnFailed => 0xA7,
        error.PacketMissing => 0xA8,
        error.PacketDestinationMismatch => 0xA9,
        error.PacketSourceMismatch => 0xAA,
        error.PacketProtocolMismatch => 0xAB,
        error.PacketSenderMismatch => 0xAC,
        error.PacketTargetMismatch => 0xAD,
        error.PacketPortsMismatch => 0xAE,
        error.PayloadMismatch => 0xAF,
        error.FrameLengthMismatch => 0xB0,
        error.CounterMismatch => 0xB1,
    };
}

const Rtl8139DataPathTimeout = enum {
    DataPathDropped,
    TxCompletedNoRxInterrupt,
    TxCompletedNoRxProgress,
    RxProducerStalled,
    RxProducerAdvancedNoFrame,
};

fn copyLastEthernetFrame(buffer: []u8) usize {
    const copy_len = @min(buffer.len, @as(usize, @intCast(oc_ethernet_state_ptr().last_rx_len)));
    var index: usize = 0;
    while (index < copy_len) : (index += 1) {
        buffer[index] = oc_ethernet_rx_byte(@as(u32, @intCast(index)));
    }
    return copy_len;
}

fn classifyRtl8139DataPathTimeout(eth: *const BaremetalEthernetState) Rtl8139DataPathTimeout {
    const producer = rtl8139.debugProducerOffset();
    const consumer: u16 = @intCast(eth.rx_consumer_offset & 0xFFFF);
    const cr = rtl8139.debugCommandRegister();
    const isr = rtl8139.debugInterruptStatus();
    const tx_status = rtl8139.debugLastTxStatus();

    if ((cr & 0x0C) != 0x0C) return .DataPathDropped;
    if ((tx_status & 0x0000_8000) != 0 and (isr & 0x0004) != 0 and (isr & 0x0001) == 0) {
        return if (producer == consumer) .TxCompletedNoRxInterrupt else .RxProducerAdvancedNoFrame;
    }
    if ((tx_status & 0x0000_8000) != 0 and producer == consumer) return .TxCompletedNoRxProgress;
    return if (producer == consumer) .RxProducerStalled else .RxProducerAdvancedNoFrame;
}

fn classifyIpv4ProbeTimeout(eth: *const BaremetalEthernetState) Rtl8139Ipv4ProbeError {
    if (eth.last_rx_len != 0) {
        var frame: [pal_net.max_frame_len]u8 = undefined;
        const copy_len = copyLastEthernetFrame(frame[0..]);
        if (copy_len < ethernet_protocol.header_len) return error.LastFrameTooShort;
        const eth_header = ethernet_protocol.Header.decode(frame[0..copy_len]) catch return error.LastFrameTooShort;
        if (eth_header.ether_type != ethernet_protocol.ethertype_ipv4) return error.LastFrameNotIpv4;
        _ = ipv4_protocol.decode(frame[ethernet_protocol.header_len..copy_len]) catch return error.LastIpv4DecodeFailed;
    }

    const timeout_class = classifyRtl8139DataPathTimeout(eth);
    return switch (timeout_class) {
        .DataPathDropped => error.DataPathDropped,
        .TxCompletedNoRxInterrupt => error.TxCompletedNoRxInterrupt,
        .TxCompletedNoRxProgress => error.TxCompletedNoRxProgress,
        .RxProducerStalled => error.RxProducerStalled,
        .RxProducerAdvancedNoFrame => error.RxProducerAdvancedNoFrame,
    };
}

fn classifyUdpProbeTimeout(eth: *const BaremetalEthernetState) Rtl8139UdpProbeError {
    if (eth.last_rx_len != 0) {
        var frame: [pal_net.max_frame_len]u8 = undefined;
        const copy_len = copyLastEthernetFrame(frame[0..]);
        if (copy_len < ethernet_protocol.header_len) return error.LastFrameTooShort;
        const eth_header = ethernet_protocol.Header.decode(frame[0..copy_len]) catch return error.LastFrameTooShort;
        if (eth_header.ether_type != ethernet_protocol.ethertype_ipv4) return error.LastFrameNotIpv4;
        const ipv4_packet = ipv4_protocol.decode(frame[ethernet_protocol.header_len..copy_len]) catch return error.LastIpv4DecodeFailed;
        if (ipv4_packet.header.protocol != ipv4_protocol.protocol_udp) return error.LastPacketNotUdp;
        _ = udp_protocol.decode(ipv4_packet.payload, ipv4_packet.header.source_ip, ipv4_packet.header.destination_ip) catch return error.LastUdpDecodeFailed;
    }

    const timeout_class = classifyRtl8139DataPathTimeout(eth);
    return switch (timeout_class) {
        .DataPathDropped => error.DataPathDropped,
        .TxCompletedNoRxInterrupt => error.TxCompletedNoRxInterrupt,
        .TxCompletedNoRxProgress => error.TxCompletedNoRxProgress,
        .RxProducerStalled => error.RxProducerStalled,
        .RxProducerAdvancedNoFrame => error.RxProducerAdvancedNoFrame,
    };
}

fn classifyTcpProbeTimeout(eth: *const BaremetalEthernetState) Rtl8139TcpProbeError {
    if (eth.last_rx_len != 0) {
        var frame: [pal_net.max_frame_len]u8 = undefined;
        const copy_len = copyLastEthernetFrame(frame[0..]);
        if (copy_len < ethernet_protocol.header_len) return error.LastFrameTooShort;
        const eth_header = ethernet_protocol.Header.decode(frame[0..copy_len]) catch return error.LastFrameTooShort;
        if (eth_header.ether_type != ethernet_protocol.ethertype_ipv4) return error.LastFrameNotIpv4;
        const ipv4_packet = ipv4_protocol.decode(frame[ethernet_protocol.header_len..copy_len]) catch return error.LastIpv4DecodeFailed;
        if (ipv4_packet.header.protocol != ipv4_protocol.protocol_tcp) return error.LastPacketNotTcp;
        _ = tcp_protocol.decode(ipv4_packet.payload, ipv4_packet.header.source_ip, ipv4_packet.header.destination_ip) catch return error.LastTcpDecodeFailed;
    }

    const timeout_class = classifyRtl8139DataPathTimeout(eth);
    return switch (timeout_class) {
        .DataPathDropped => error.DataPathDropped,
        .TxCompletedNoRxInterrupt => error.TxCompletedNoRxInterrupt,
        .TxCompletedNoRxProgress => error.TxCompletedNoRxProgress,
        .RxProducerStalled => error.RxProducerStalled,
        .RxProducerAdvancedNoFrame => error.RxProducerAdvancedNoFrame,
    };
}

fn classifyDhcpProbeTimeout(eth: *const BaremetalEthernetState) Rtl8139DhcpProbeError {
    if (eth.last_rx_len != 0) {
        var frame: [pal_net.max_frame_len]u8 = undefined;
        const copy_len = copyLastEthernetFrame(frame[0..]);
        if (copy_len < ethernet_protocol.header_len) return error.LastFrameTooShort;
        const eth_header = ethernet_protocol.Header.decode(frame[0..copy_len]) catch return error.LastFrameTooShort;
        if (eth_header.ether_type != ethernet_protocol.ethertype_ipv4) return error.LastFrameNotIpv4;
        const ipv4_packet = ipv4_protocol.decode(frame[ethernet_protocol.header_len..copy_len]) catch return error.LastIpv4DecodeFailed;
        if (ipv4_packet.header.protocol != ipv4_protocol.protocol_udp) return error.LastPacketNotUdp;
        const udp_packet = udp_protocol.decode(ipv4_packet.payload, ipv4_packet.header.source_ip, ipv4_packet.header.destination_ip) catch return error.LastUdpDecodeFailed;
        if (!((udp_packet.source_port == dhcp_protocol.client_port and udp_packet.destination_port == dhcp_protocol.server_port) or
            (udp_packet.source_port == dhcp_protocol.server_port and udp_packet.destination_port == dhcp_protocol.client_port)))
        {
            return error.LastPacketNotDhcp;
        }
        _ = dhcp_protocol.decode(udp_packet.payload) catch return error.LastDhcpDecodeFailed;
    }

    const timeout_class = classifyRtl8139DataPathTimeout(eth);
    return switch (timeout_class) {
        .DataPathDropped => error.DataPathDropped,
        .TxCompletedNoRxInterrupt => error.TxCompletedNoRxInterrupt,
        .TxCompletedNoRxProgress => error.TxCompletedNoRxProgress,
        .RxProducerStalled => error.RxProducerStalled,
        .RxProducerAdvancedNoFrame => error.RxProducerAdvancedNoFrame,
    };
}

fn classifyDnsProbeTimeout(eth: *const BaremetalEthernetState) Rtl8139DnsProbeError {
    if (eth.last_rx_len != 0) {
        var frame: [pal_net.max_frame_len]u8 = undefined;
        const copy_len = copyLastEthernetFrame(frame[0..]);
        if (copy_len < ethernet_protocol.header_len) return error.LastFrameTooShort;
        const eth_header = ethernet_protocol.Header.decode(frame[0..copy_len]) catch return error.LastFrameTooShort;
        if (eth_header.ether_type != ethernet_protocol.ethertype_ipv4) return error.LastFrameNotIpv4;
        const ipv4_packet = ipv4_protocol.decode(frame[ethernet_protocol.header_len..copy_len]) catch return error.LastIpv4DecodeFailed;
        if (ipv4_packet.header.protocol != ipv4_protocol.protocol_udp) return error.LastPacketNotUdp;
        const udp_packet = udp_protocol.decode(ipv4_packet.payload, ipv4_packet.header.source_ip, ipv4_packet.header.destination_ip) catch return error.LastUdpDecodeFailed;
        if (!(udp_packet.source_port == dns_protocol.default_port or udp_packet.destination_port == dns_protocol.default_port)) {
            return error.LastPacketNotDns;
        }
        _ = dns_protocol.decode(udp_packet.payload) catch return error.LastDnsDecodeFailed;
    }

    const timeout_class = classifyRtl8139DataPathTimeout(eth);
    return switch (timeout_class) {
        .DataPathDropped => error.DataPathDropped,
        .TxCompletedNoRxInterrupt => error.TxCompletedNoRxInterrupt,
        .TxCompletedNoRxProgress => error.TxCompletedNoRxProgress,
        .RxProducerStalled => error.RxProducerStalled,
        .RxProducerAdvancedNoFrame => error.RxProducerAdvancedNoFrame,
    };
}

fn runRtl8139Ipv4Probe() Rtl8139Ipv4ProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };

    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "PING";
    const expected_wire_len: u32 = ethernet_protocol.header_len + ipv4_protocol.header_len + payload.len;
    const expected_frame_len: u32 = @max(expected_wire_len, 60);
    if ((pal_net.sendIpv4Frame(ethernet_protocol.broadcast_mac, source_ip, destination_ip, ipv4_protocol.protocol_udp, payload) catch return error.TxFailed) != expected_wire_len) {
        return error.TxFailed;
    }
    var attempts: usize = 0;
    var packet_opt: ?pal_net.Ipv4Packet = null;
    while (attempts < 20_000) : (attempts += 1) {
        packet_opt = pal_net.pollIpv4PacketStrict() catch |err| return switch (err) {
            error.NotIpv4 => error.LastFrameNotIpv4,
            error.FrameTooShort, error.PacketTooShort => error.LastFrameTooShort,
            error.InvalidVersion, error.UnsupportedOptions, error.InvalidTotalLength, error.HeaderChecksumMismatch => error.LastIpv4DecodeFailed,
            else => error.PacketMissing,
        };
        if (packet_opt != null) break;
        spinPause(1);
    }
    if (packet_opt) |*packet| {
        if (!std.mem.eql(u8, ethernet_protocol.broadcast_mac[0..], packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
        if (!std.mem.eql(u8, eth.mac[0..], packet.ethernet_source[0..])) return error.PacketSourceMismatch;
        if (packet.header.protocol != ipv4_protocol.protocol_udp) return error.PacketProtocolMismatch;
        if (!std.mem.eql(u8, source_ip[0..], packet.header.source_ip[0..])) return error.PacketSenderMismatch;
        if (!std.mem.eql(u8, destination_ip[0..], packet.header.destination_ip[0..])) return error.PacketTargetMismatch;
        if (!std.mem.eql(u8, payload, packet.payload[0..packet.payload_len])) return error.PayloadMismatch;
        if (eth.last_rx_len != expected_frame_len) return error.FrameLengthMismatch;
        if (eth.tx_packets == 0 or eth.rx_packets == 0) return error.CounterMismatch;
    } else {
        return classifyIpv4ProbeTimeout(eth);
    }
}

fn rtl8139Ipv4ProbeFailureCode(err: Rtl8139Ipv4ProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0x88,
        error.DeviceNotFound => 0x89,
        error.ResetTimeout => 0x8A,
        error.BufferProgramFailed => 0x8B,
        error.MacReadFailed => 0x8C,
        error.DataPathEnableFailed => 0x8D,
        error.StateMagicMismatch => 0x8E,
        error.BackendMismatch => 0x8F,
        error.InitFlagMismatch => 0x90,
        error.HardwareBackedMismatch => 0x91,
        error.IoBaseMismatch => 0x92,
        error.TxFailed => 0x93,
        error.RxTimedOut => 0x94,
        error.PacketMissing => 0x95,
        error.PacketDestinationMismatch => 0x96,
        error.PacketSourceMismatch => 0x97,
        error.PacketProtocolMismatch => 0x98,
        error.PacketSenderMismatch => 0x99,
        error.PacketTargetMismatch => 0x9A,
        error.PayloadMismatch => 0x9B,
        error.FrameLengthMismatch => 0x9C,
        error.CounterMismatch => 0x9D,
        error.LastFrameTooShort => 0xB6,
        error.LastFrameNotIpv4 => 0xB7,
        error.LastIpv4DecodeFailed => 0xB8,
        error.DataPathDropped => 0xB9,
        error.TxCompletedNoRxInterrupt => 0xBA,
        error.TxCompletedNoRxProgress => 0xBB,
        error.RxProducerStalled => 0xBC,
        error.RxProducerAdvancedNoFrame => 0xBD,
    };
}

fn runRtl8139UdpProbe() Rtl8139UdpProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };

    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const source_port: u16 = 4321;
    const destination_port: u16 = 9001;
    const payload = "OPENCLAW-UDP";
    const expected_wire_len: u32 = ethernet_protocol.header_len + ipv4_protocol.header_len + udp_protocol.header_len + payload.len;
    const expected_frame_len: u32 = @max(expected_wire_len, 60);
    if ((pal_net.sendUdpPacket(ethernet_protocol.broadcast_mac, source_ip, destination_ip, source_port, destination_port, payload) catch return error.TxFailed) != expected_wire_len) {
        return error.TxFailed;
    }
    var attempts: usize = 0;
    var packet_received = false;
    var packet_storage: pal_net.UdpPacket = undefined;
    while (attempts < 20_000) : (attempts += 1) {
        packet_received = pal_net.pollUdpPacketStrictInto(&packet_storage) catch |err| return switch (err) {
            error.NotIpv4 => error.LastFrameNotIpv4,
            error.NotUdp => error.LastPacketNotUdp,
            error.FrameTooShort, error.PacketTooShort => error.LastFrameTooShort,
            error.InvalidVersion, error.UnsupportedOptions, error.InvalidTotalLength, error.HeaderChecksumMismatch => error.LastIpv4DecodeFailed,
            error.InvalidLength, error.ChecksumMismatch => error.LastUdpDecodeFailed,
            else => error.PacketMissing,
        };
        if (packet_received) {
            break;
        }
        spinPause(1);
    }
    if (packet_received) {
        const packet = &packet_storage;
        if (!std.mem.eql(u8, ethernet_protocol.broadcast_mac[0..], packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
        if (!std.mem.eql(u8, eth.mac[0..], packet.ethernet_source[0..])) return error.PacketSourceMismatch;
        if (packet.ipv4_header.protocol != ipv4_protocol.protocol_udp) return error.PacketProtocolMismatch;
        if (!std.mem.eql(u8, source_ip[0..], packet.ipv4_header.source_ip[0..])) return error.PacketSenderMismatch;
        if (!std.mem.eql(u8, destination_ip[0..], packet.ipv4_header.destination_ip[0..])) return error.PacketTargetMismatch;
        if (packet.source_port != source_port or packet.destination_port != destination_port) return error.PacketPortsMismatch;
        if (packet.checksum_value == 0) return error.ChecksumMissing;
        if (!std.mem.eql(u8, payload, packet.payload[0..packet.payload_len])) return error.PayloadMismatch;
        if (eth.last_rx_len != expected_frame_len) return error.FrameLengthMismatch;
        if (eth.tx_packets == 0 or eth.rx_packets == 0) return error.CounterMismatch;
    } else {
        return classifyUdpProbeTimeout(eth);
    }
}

fn rtl8139UdpProbeFailureCode(err: Rtl8139UdpProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0x9E,
        error.DeviceNotFound => 0x9F,
        error.ResetTimeout => 0xA0,
        error.BufferProgramFailed => 0xA1,
        error.MacReadFailed => 0xA2,
        error.DataPathEnableFailed => 0xA3,
        error.StateMagicMismatch => 0xA4,
        error.BackendMismatch => 0xA5,
        error.InitFlagMismatch => 0xA6,
        error.HardwareBackedMismatch => 0xA7,
        error.IoBaseMismatch => 0xA8,
        error.TxFailed => 0xA9,
        error.RxTimedOut => 0xAA,
        error.PacketMissing => 0xAB,
        error.PacketDestinationMismatch => 0xAC,
        error.PacketSourceMismatch => 0xAD,
        error.PacketProtocolMismatch => 0xAE,
        error.PacketSenderMismatch => 0xAF,
        error.PacketTargetMismatch => 0xB0,
        error.PacketPortsMismatch => 0xB1,
        error.ChecksumMissing => 0xB2,
        error.PayloadMismatch => 0xB3,
        error.FrameLengthMismatch => 0xB4,
        error.CounterMismatch => 0xB5,
        error.LastFrameTooShort => 0xBE,
        error.LastFrameNotIpv4 => 0xBF,
        error.LastIpv4DecodeFailed => 0xC0,
        error.LastPacketNotUdp => 0xC1,
        error.LastUdpDecodeFailed => 0xC2,
        error.DataPathDropped => 0xC3,
        error.TxCompletedNoRxInterrupt => 0xC4,
        error.TxCompletedNoRxProgress => 0xC5,
        error.RxProducerStalled => 0xC6,
        error.RxProducerAdvancedNoFrame => 0xC7,
    };
}

fn mapTcpSessionProbeError(err: tcp_protocol.Error) Rtl8139TcpProbeError {
    return switch (err) {
        error.InvalidState => error.SessionStateMismatch,
        error.UnexpectedFlags => error.PacketFlagsMismatch,
        error.PortMismatch => error.PacketPortsMismatch,
        error.SequenceMismatch => error.PacketSequenceMismatch,
        error.AcknowledgmentMismatch => error.PacketAcknowledgmentMismatch,
        error.EmptyPayload => error.PayloadMismatch,
        else => error.LastTcpDecodeFailed,
    };
}

fn tcpPacketView(packet: *const pal_net.TcpPacket) tcp_protocol.Packet {
    return .{
        .source_port = packet.source_port,
        .destination_port = packet.destination_port,
        .sequence_number = packet.sequence_number,
        .acknowledgment_number = packet.acknowledgment_number,
        .data_offset_bytes = tcp_protocol.header_len,
        .flags = packet.flags,
        .window_size = packet.window_size,
        .checksum_value = packet.checksum_value,
        .urgent_pointer = packet.urgent_pointer,
        .payload = packet.payload[0..packet.payload_len],
    };
}

fn pollTcpProbePacket(eth: *const BaremetalEthernetState, result: *pal_net.TcpPacket) Rtl8139TcpProbeError!void {
    var attempts: usize = 0;
    while (attempts < 20_000) : (attempts += 1) {
        if (pal_net.pollTcpPacketStrictInto(result)) |packet_received| {
            if (packet_received) return;
        } else |err| {
            return switch (err) {
                error.NotIpv4 => error.LastFrameNotIpv4,
                error.NotTcp => error.LastPacketNotTcp,
                error.FrameTooShort, error.PacketTooShort => error.LastFrameTooShort,
                error.InvalidVersion, error.UnsupportedOptions, error.InvalidTotalLength, error.HeaderChecksumMismatch => error.LastIpv4DecodeFailed,
                error.InvalidDataOffset, error.ChecksumMismatch => error.LastTcpDecodeFailed,
                else => error.PacketMissing,
            };
        }
        spinPause(1);
    }
    return classifyTcpProbeTimeout(eth);
}

fn sendTcpProbeSegment(
    source_ip: [4]u8,
    destination_ip: [4]u8,
    source_port: u16,
    destination_port: u16,
    outbound: tcp_protocol.Outbound,
) Rtl8139TcpProbeError!u32 {
    const expected_wire_len: u32 = @as(u32, @intCast(ethernet_protocol.header_len + ipv4_protocol.header_len + tcp_protocol.header_len + outbound.payload.len));
    const sent = pal_net.sendTcpPacket(
        ethernet_protocol.broadcast_mac,
        source_ip,
        destination_ip,
        source_port,
        destination_port,
        outbound.sequence_number,
        outbound.acknowledgment_number,
        outbound.flags,
        outbound.window_size,
        outbound.payload,
    ) catch return error.TxFailed;
    if (sent != expected_wire_len) return error.TxFailed;
    return @max(expected_wire_len, 60);
}

fn expectTcpProbePacket(
    packet: *const pal_net.TcpPacket,
    expected_source_mac: [ethernet_protocol.mac_len]u8,
    expected_source_ip: [4]u8,
    expected_destination_ip: [4]u8,
    expected_source_port: u16,
    expected_destination_port: u16,
    expected: tcp_protocol.Outbound,
) Rtl8139TcpProbeError!void {
    if (!std.mem.eql(u8, ethernet_protocol.broadcast_mac[0..], packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
    if (!std.mem.eql(u8, expected_source_mac[0..], packet.ethernet_source[0..])) return error.PacketSourceMismatch;
    if (packet.ipv4_header.protocol != ipv4_protocol.protocol_tcp) return error.PacketProtocolMismatch;
    if (!std.mem.eql(u8, expected_source_ip[0..], packet.ipv4_header.source_ip[0..])) return error.PacketSenderMismatch;
    if (!std.mem.eql(u8, expected_destination_ip[0..], packet.ipv4_header.destination_ip[0..])) return error.PacketTargetMismatch;
    if (packet.source_port != expected_source_port or packet.destination_port != expected_destination_port) return error.PacketPortsMismatch;
    if (packet.sequence_number != expected.sequence_number) return error.PacketSequenceMismatch;
    if (packet.acknowledgment_number != expected.acknowledgment_number) return error.PacketAcknowledgmentMismatch;
    if (packet.flags != expected.flags) return error.PacketFlagsMismatch;
    if (packet.window_size != expected.window_size) return error.WindowSizeMismatch;
    if (!std.mem.eql(u8, expected.payload, packet.payload[0..packet.payload_len])) return error.PayloadMismatch;
}

fn runRtl8139TcpProbe() Rtl8139TcpProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };

    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const source_port: u16 = 4321;
    const destination_port: u16 = 443;
    const payload = "OPENCLAW-TCP";
    const server_window_size: u16 = 8192;
    const retransmit_interval_ticks: u64 = 4;
    var client = tcp_protocol.Session.initClient(source_port, destination_port, 0x0102_0304, 4096);
    var server = tcp_protocol.Session.initServer(destination_port, source_port, 0xA0B0_C0D0, server_window_size);
    var packet_storage: pal_net.TcpPacket = undefined;
    var probe_tick: u64 = 0;

    const syn = client.buildSynWithTimeout(probe_tick, retransmit_interval_ticks) catch |err| return mapTcpSessionProbeError(err);
    _ = try sendTcpProbeSegment(source_ip, destination_ip, source_port, destination_port, syn);
    try pollTcpProbePacket(eth, &packet_storage);
    try expectTcpProbePacket(&packet_storage, eth.mac, source_ip, destination_ip, source_port, destination_port, syn);

    if (client.pollRetransmit(retransmit_interval_ticks - 1) != null) return error.RetransmitTooEarly;
    probe_tick = retransmit_interval_ticks;
    const retry_syn = client.pollRetransmit(probe_tick) orelse return error.RetransmitMissing;
    if (retry_syn.sequence_number != syn.sequence_number or
        retry_syn.acknowledgment_number != syn.acknowledgment_number or
        retry_syn.flags != syn.flags or
        retry_syn.window_size != syn.window_size or
        retry_syn.payload.len != 0)
    {
        return error.RetransmitShapeMismatch;
    }
    _ = try sendTcpProbeSegment(source_ip, destination_ip, source_port, destination_port, retry_syn);
    try pollTcpProbePacket(eth, &packet_storage);
    try expectTcpProbePacket(&packet_storage, eth.mac, source_ip, destination_ip, source_port, destination_port, retry_syn);

    const syn_ack = server.acceptSyn(tcpPacketView(&packet_storage)) catch |err| return mapTcpSessionProbeError(err);
    _ = try sendTcpProbeSegment(destination_ip, source_ip, destination_port, source_port, syn_ack);
    try pollTcpProbePacket(eth, &packet_storage);
    try expectTcpProbePacket(&packet_storage, eth.mac, destination_ip, source_ip, destination_port, source_port, syn_ack);

    const ack = client.acceptSynAck(tcpPacketView(&packet_storage)) catch |err| return mapTcpSessionProbeError(err);
    if (client.retransmit.armed()) return error.RetransmitNotCleared;
    _ = try sendTcpProbeSegment(source_ip, destination_ip, source_port, destination_port, ack);
    try pollTcpProbePacket(eth, &packet_storage);
    try expectTcpProbePacket(&packet_storage, eth.mac, source_ip, destination_ip, source_port, destination_port, ack);
    server.acceptAck(tcpPacketView(&packet_storage)) catch |err| return mapTcpSessionProbeError(err);

    const data = client.buildPayloadWithTimeout(payload, probe_tick, retransmit_interval_ticks) catch |err| return mapTcpSessionProbeError(err);
    const expected_data_frame_len = try sendTcpProbeSegment(source_ip, destination_ip, source_port, destination_port, data);
    try pollTcpProbePacket(eth, &packet_storage);
    try expectTcpProbePacket(&packet_storage, eth.mac, source_ip, destination_ip, source_port, destination_port, data);
    if (eth.last_rx_len != expected_data_frame_len) return error.FrameLengthMismatch;

    if (client.pollRetransmit(probe_tick + retransmit_interval_ticks - 1) != null) return error.RetransmitTooEarly;
    probe_tick +%= retransmit_interval_ticks;
    const retry_data = client.pollRetransmit(probe_tick) orelse return error.RetransmitMissing;
    if (retry_data.sequence_number != data.sequence_number or
        retry_data.acknowledgment_number != data.acknowledgment_number or
        retry_data.flags != data.flags or
        retry_data.window_size != data.window_size or
        !std.mem.eql(u8, retry_data.payload, data.payload))
    {
        return error.RetransmitShapeMismatch;
    }

    _ = try sendTcpProbeSegment(source_ip, destination_ip, source_port, destination_port, retry_data);
    try pollTcpProbePacket(eth, &packet_storage);
    try expectTcpProbePacket(&packet_storage, eth.mac, source_ip, destination_ip, source_port, destination_port, retry_data);
    server.acceptPayload(tcpPacketView(&packet_storage)) catch |err| return mapTcpSessionProbeError(err);

    const payload_ack = server.buildAck() catch |err| return mapTcpSessionProbeError(err);
    const expected_ack_frame_len = try sendTcpProbeSegment(destination_ip, source_ip, destination_port, source_port, payload_ack);
    try pollTcpProbePacket(eth, &packet_storage);
    try expectTcpProbePacket(&packet_storage, eth.mac, destination_ip, source_ip, destination_port, source_port, payload_ack);
    client.acceptAck(tcpPacketView(&packet_storage)) catch |err| return mapTcpSessionProbeError(err);
    if (client.retransmit.armed()) return error.RetransmitNotCleared;

    if (client.state != .established or server.state != .established) return error.SessionStateMismatch;
    if (eth.last_rx_len != expected_ack_frame_len) return error.FrameLengthMismatch;
    if (eth.tx_packets < 7 or eth.rx_packets < 7) return error.CounterMismatch;
}

fn rtl8139TcpProbeFailureCode(err: Rtl8139TcpProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0xC8,
        error.DeviceNotFound => 0xC9,
        error.ResetTimeout => 0xCA,
        error.BufferProgramFailed => 0xCB,
        error.MacReadFailed => 0xCC,
        error.DataPathEnableFailed => 0xCD,
        error.StateMagicMismatch => 0xCE,
        error.BackendMismatch => 0xCF,
        error.InitFlagMismatch => 0xD0,
        error.HardwareBackedMismatch => 0xD1,
        error.IoBaseMismatch => 0xD2,
        error.TxFailed => 0xD3,
        error.RxTimedOut => 0xD4,
        error.LastFrameTooShort => 0xD5,
        error.LastFrameNotIpv4 => 0xD6,
        error.LastIpv4DecodeFailed => 0xD7,
        error.LastPacketNotTcp => 0xD8,
        error.LastTcpDecodeFailed => 0xD9,
        error.DataPathDropped => 0xDA,
        error.TxCompletedNoRxInterrupt => 0xDB,
        error.TxCompletedNoRxProgress => 0xDC,
        error.RxProducerStalled => 0xDD,
        error.RxProducerAdvancedNoFrame => 0xDE,
        error.PacketMissing => 0xDF,
        error.PacketDestinationMismatch => 0xE0,
        error.PacketSourceMismatch => 0xE1,
        error.PacketProtocolMismatch => 0xE2,
        error.PacketSenderMismatch => 0xE3,
        error.PacketTargetMismatch => 0xE4,
        error.PacketPortsMismatch => 0xE5,
        error.PacketSequenceMismatch => 0xE6,
        error.PacketAcknowledgmentMismatch => 0xE7,
        error.PacketFlagsMismatch => 0xE8,
        error.WindowSizeMismatch => 0xE9,
        error.PayloadMismatch => 0xEA,
        error.FrameLengthMismatch => 0xEB,
        error.CounterMismatch => 0xEC,
        error.SessionStateMismatch => 0xED,
        error.RetransmitTooEarly => 0xEE,
        error.RetransmitMissing => 0xEF,
        error.RetransmitShapeMismatch => 0xF0,
        error.RetransmitNotCleared => 0xF1,
    };
}

fn runRtl8139DhcpProbe() Rtl8139DhcpProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };

    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;

    const source_ip = if (builtin.is_test)
        [4]u8{ 0, 0, 0, 0 }
    else
        [4]u8{ 192, 168, 56, 10 };
    const destination_ip = if (builtin.is_test)
        [4]u8{ 255, 255, 255, 255 }
    else
        [4]u8{ 192, 168, 56, 1 };
    const source_port: u16 = if (builtin.is_test) dhcp_protocol.client_port else 4068;
    const destination_port: u16 = if (builtin.is_test) dhcp_protocol.server_port else 4067;
    const transaction_id: u32 = 0x1234_5678;
    const parameter_request_list = [_]u8{
        dhcp_protocol.option_subnet_mask,
        dhcp_protocol.option_router,
        dhcp_protocol.option_dns_server,
        dhcp_protocol.option_hostname,
    };
    var dhcp_payload: [pal_net.max_ipv4_payload_len]u8 = undefined;
    const dhcp_payload_len = dhcp_protocol.encodeDiscover(
        dhcp_payload[0..],
        eth.mac,
        transaction_id,
        parameter_request_list[0..],
    ) catch return error.TxFailed;
    const expected_wire_len = pal_net.sendUdpPacket(
        ethernet_protocol.broadcast_mac,
        source_ip,
        destination_ip,
        source_port,
        destination_port,
        dhcp_payload[0..dhcp_payload_len],
    ) catch return error.TxFailed;
    const expected_frame_len: u32 = @max(expected_wire_len, 60);

    var attempts: usize = 0;
    var packet_received = false;
    var packet_storage: pal_net.UdpPacket = undefined;
    while (attempts < 20_000) : (attempts += 1) {
        packet_received = pal_net.pollUdpPacketStrictInto(&packet_storage) catch |err| return switch (err) {
            error.NotIpv4 => error.LastFrameNotIpv4,
            error.FrameTooShort, error.PacketTooShort => error.LastFrameTooShort,
            error.InvalidVersion, error.UnsupportedOptions, error.InvalidTotalLength, error.HeaderChecksumMismatch => error.LastIpv4DecodeFailed,
            error.InvalidLength, error.ChecksumMismatch => error.LastUdpDecodeFailed,
            else => error.PacketMissing,
        };
        if (packet_received) break;
        spinPause(1);
    }

    if (!packet_received) return classifyDhcpProbeTimeout(eth);
    const packet = &packet_storage;
    if (!std.mem.eql(u8, ethernet_protocol.broadcast_mac[0..], packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
    if (!std.mem.eql(u8, eth.mac[0..], packet.ethernet_source[0..])) return error.PacketSourceMismatch;
    if (packet.ipv4_header.protocol != ipv4_protocol.protocol_udp) return error.PacketProtocolMismatch;
    if (!std.mem.eql(u8, source_ip[0..], packet.ipv4_header.source_ip[0..])) return error.PacketSenderMismatch;
    if (!std.mem.eql(u8, destination_ip[0..], packet.ipv4_header.destination_ip[0..])) return error.PacketTargetMismatch;
    if (packet.source_port != source_port or packet.destination_port != destination_port) return error.PacketPortsMismatch;
    const decoded = dhcp_protocol.decode(packet.payload[0..packet.payload_len]) catch return error.LastDhcpDecodeFailed;
    if (decoded.op != dhcp_protocol.boot_request) return error.PacketOperationMismatch;
    if (decoded.transaction_id != transaction_id) return error.TransactionIdMismatch;
    if (decoded.message_type == null or decoded.message_type.? != dhcp_protocol.message_type_discover) return error.MessageTypeMismatch;
    if (!std.mem.eql(u8, eth.mac[0..], decoded.client_mac[0..])) return error.PacketClientMacMismatch;
    if (decoded.parameter_request_list.len != parameter_request_list.len or !std.mem.eql(u8, parameter_request_list[0..], decoded.parameter_request_list[0..])) {
        return error.ParameterRequestListMismatch;
    }
    if (decoded.flags != dhcp_protocol.flags_broadcast) return error.FlagsMismatch;
    if (decoded.client_identifier.len != 1 + ethernet_protocol.mac_len) return error.PacketClientMacMismatch;
    if (decoded.client_identifier[0] != dhcp_protocol.hardware_type_ethernet or !std.mem.eql(u8, eth.mac[0..], decoded.client_identifier[1 .. 1 + ethernet_protocol.mac_len])) {
        return error.PacketClientMacMismatch;
    }
    if (decoded.max_message_size == null or decoded.max_message_size.? != 1500) return error.MaxMessageSizeMismatch;
    if (packet.checksum_value == 0) return error.ChecksumMissing;
    if (eth.last_rx_len != expected_frame_len) return error.FrameLengthMismatch;
    if (eth.tx_packets == 0 or eth.rx_packets == 0) return error.CounterMismatch;
}

fn rtl8139DhcpProbeFailureCode(err: Rtl8139DhcpProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0x40,
        error.DeviceNotFound => 0x41,
        error.ResetTimeout => 0x42,
        error.BufferProgramFailed => 0x43,
        error.MacReadFailed => 0x44,
        error.DataPathEnableFailed => 0x45,
        error.StateMagicMismatch => 0x46,
        error.BackendMismatch => 0x47,
        error.InitFlagMismatch => 0x48,
        error.HardwareBackedMismatch => 0x49,
        error.IoBaseMismatch => 0x4A,
        error.TxFailed => 0x4B,
        error.RxTimedOut => 0x4C,
        error.LastFrameTooShort => 0x4D,
        error.LastFrameNotIpv4 => 0x4E,
        error.LastIpv4DecodeFailed => 0x4F,
        error.LastPacketNotUdp => 0x50,
        error.LastUdpDecodeFailed => 0x51,
        error.LastPacketNotDhcp => 0x52,
        error.LastDhcpDecodeFailed => 0x53,
        error.DataPathDropped => 0x54,
        error.TxCompletedNoRxInterrupt => 0x55,
        error.TxCompletedNoRxProgress => 0x56,
        error.RxProducerStalled => 0x57,
        error.RxProducerAdvancedNoFrame => 0x58,
        error.PacketMissing => 0x59,
        error.PacketDestinationMismatch => 0x5A,
        error.PacketSourceMismatch => 0x5B,
        error.PacketProtocolMismatch => 0x5C,
        error.PacketSenderMismatch => 0x5D,
        error.PacketTargetMismatch => 0x5E,
        error.PacketPortsMismatch => 0x5F,
        error.PacketOperationMismatch => 0x60,
        error.TransactionIdMismatch => 0x61,
        error.MessageTypeMismatch => 0x62,
        error.PacketClientMacMismatch => 0x63,
        error.ParameterRequestListMismatch => 0x64,
        error.FlagsMismatch => 0x65,
        error.MaxMessageSizeMismatch => 0x66,
        error.ChecksumMissing => 0x67,
        error.FrameLengthMismatch => 0x68,
        error.CounterMismatch => 0x69,
    };
}

fn runRtl8139DnsProbe() Rtl8139DnsProbeError!void {
    rtl8139.initDetailed() catch |err| return switch (err) {
        error.UnsupportedPlatform => error.UnsupportedPlatform,
        error.DeviceNotFound => error.DeviceNotFound,
        error.ResetTimeout => error.ResetTimeout,
        error.BufferProgramFailed => error.BufferProgramFailed,
        error.MacReadFailed => error.MacReadFailed,
        error.DataPathEnableFailed => error.DataPathEnableFailed,
    };

    const eth = oc_ethernet_state_ptr();
    if (eth.magic != abi.ethernet_magic) return error.StateMagicMismatch;
    if (eth.backend != abi.ethernet_backend_rtl8139) return error.BackendMismatch;
    if (eth.initialized == 0) return error.InitFlagMismatch;
    if (!builtin.is_test and eth.hardware_backed == 0) return error.HardwareBackedMismatch;
    if (eth.io_base == 0) return error.IoBaseMismatch;

    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const source_port: u16 = 53000;
    const query_id: u16 = 0x1234;
    const query_name = "openclaw.local";
    const resolved_address = [4]u8{ 192, 168, 56, 1 };
    const response_destination_mac = if (builtin.is_test) eth.mac else ethernet_protocol.broadcast_mac;

    const expected_query_wire_len = pal_net.sendDnsQuery(
        ethernet_protocol.broadcast_mac,
        source_ip,
        server_ip,
        source_port,
        query_id,
        query_name,
        dns_protocol.type_a,
    ) catch return error.TxFailed;
    const expected_query_frame_len: u32 = @max(expected_query_wire_len, 60);

    var attempts: usize = 0;
    var packet_received = false;
    var query_packet_storage: pal_net.DnsPacket = undefined;
    while (attempts < 20_000) : (attempts += 1) {
        packet_received = pal_net.pollDnsPacketStrictInto(&query_packet_storage) catch |err| return switch (err) {
            error.NotIpv4 => error.LastFrameNotIpv4,
            error.NotUdp => error.LastPacketNotUdp,
            error.NotDns => error.LastPacketNotDns,
            error.FrameTooShort, error.PacketTooShort => error.LastFrameTooShort,
            error.InvalidVersion, error.UnsupportedOptions, error.InvalidTotalLength, error.HeaderChecksumMismatch => error.LastIpv4DecodeFailed,
            error.InvalidLength, error.ChecksumMismatch => error.LastUdpDecodeFailed,
            error.InvalidLabelLength, error.InvalidPointer, error.UnsupportedLabelType, error.NameTooLong, error.CompressionLoop, error.UnsupportedQuestionCount, error.ResourceDataTooLarge => error.LastDnsDecodeFailed,
            else => error.PacketMissing,
        };
        if (packet_received) break;
        spinPause(1);
    }

    if (!packet_received) return classifyDnsProbeTimeout(eth);
    const query_packet = &query_packet_storage;
    if (!std.mem.eql(u8, ethernet_protocol.broadcast_mac[0..], query_packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
    if (!std.mem.eql(u8, eth.mac[0..], query_packet.ethernet_source[0..])) return error.PacketSourceMismatch;
    if (query_packet.ipv4_header.protocol != ipv4_protocol.protocol_udp) return error.PacketProtocolMismatch;
    if (!std.mem.eql(u8, source_ip[0..], query_packet.ipv4_header.source_ip[0..])) return error.PacketSenderMismatch;
    if (!std.mem.eql(u8, server_ip[0..], query_packet.ipv4_header.destination_ip[0..])) return error.PacketTargetMismatch;
    if (query_packet.source_port != source_port or query_packet.destination_port != dns_protocol.default_port) return error.PacketPortsMismatch;
    if (query_packet.id != query_id) return error.TransactionIdMismatch;
    if (query_packet.flags != dns_protocol.flags_standard_query) return error.FlagsMismatch;
    if (query_packet.question_count != 1) return error.QuestionCountMismatch;
    if (!std.mem.eql(u8, query_name, query_packet.question_name[0..query_packet.question_name_len])) return error.QuestionNameMismatch;
    if (query_packet.question_type != dns_protocol.type_a) return error.QuestionTypeMismatch;
    if (query_packet.question_class != dns_protocol.class_in) return error.QuestionClassMismatch;
    if (query_packet.answer_count_total != 0 or query_packet.answer_count != 0) return error.AnswerCountMismatch;
    if (query_packet.udp_checksum_value == 0) return error.ChecksumMissing;
    if (eth.last_rx_len != expected_query_frame_len) return error.FrameLengthMismatch;

    var dns_payload: [pal_net.max_ipv4_payload_len]u8 = undefined;
    const dns_len = dns_protocol.encodeAResponse(dns_payload[0..], query_id, query_name, 300, resolved_address) catch return error.TxFailed;
    const expected_response_wire_len = pal_net.sendUdpPacket(
        response_destination_mac,
        server_ip,
        source_ip,
        dns_protocol.default_port,
        source_port,
        dns_payload[0..dns_len],
    ) catch return error.TxFailed;
    const expected_response_frame_len: u32 = @max(expected_response_wire_len, 60);

    attempts = 0;
    packet_received = false;
    var response_packet_storage: pal_net.DnsPacket = undefined;
    while (attempts < 20_000) : (attempts += 1) {
        packet_received = pal_net.pollDnsPacketStrictInto(&response_packet_storage) catch |err| return switch (err) {
            error.NotIpv4 => error.LastFrameNotIpv4,
            error.NotUdp => error.LastPacketNotUdp,
            error.NotDns => error.LastPacketNotDns,
            error.FrameTooShort, error.PacketTooShort => error.LastFrameTooShort,
            error.InvalidVersion, error.UnsupportedOptions, error.InvalidTotalLength, error.HeaderChecksumMismatch => error.LastIpv4DecodeFailed,
            error.InvalidLength, error.ChecksumMismatch => error.LastUdpDecodeFailed,
            error.InvalidLabelLength, error.InvalidPointer, error.UnsupportedLabelType, error.NameTooLong, error.CompressionLoop, error.UnsupportedQuestionCount, error.ResourceDataTooLarge => error.LastDnsDecodeFailed,
            else => error.PacketMissing,
        };
        if (packet_received) break;
        spinPause(1);
    }

    if (!packet_received) return classifyDnsProbeTimeout(eth);
    const response_packet = &response_packet_storage;
    if (!std.mem.eql(u8, response_destination_mac[0..], response_packet.ethernet_destination[0..])) return error.PacketDestinationMismatch;
    if (!std.mem.eql(u8, eth.mac[0..], response_packet.ethernet_source[0..])) return error.PacketSourceMismatch;
    if (response_packet.ipv4_header.protocol != ipv4_protocol.protocol_udp) return error.PacketProtocolMismatch;
    if (!std.mem.eql(u8, server_ip[0..], response_packet.ipv4_header.source_ip[0..])) return error.PacketSenderMismatch;
    if (!std.mem.eql(u8, source_ip[0..], response_packet.ipv4_header.destination_ip[0..])) return error.PacketTargetMismatch;
    if (response_packet.source_port != dns_protocol.default_port or response_packet.destination_port != source_port) return error.PacketPortsMismatch;
    if (response_packet.id != query_id) return error.TransactionIdMismatch;
    if (response_packet.flags != dns_protocol.flags_standard_success_response) return error.FlagsMismatch;
    if (response_packet.question_count != 1) return error.QuestionCountMismatch;
    if (!std.mem.eql(u8, query_name, response_packet.question_name[0..response_packet.question_name_len])) return error.QuestionNameMismatch;
    if (response_packet.question_type != dns_protocol.type_a) return error.QuestionTypeMismatch;
    if (response_packet.question_class != dns_protocol.class_in) return error.QuestionClassMismatch;
    if (response_packet.answer_count_total != 1 or response_packet.answer_count != 1) return error.AnswerCountMismatch;
    if (!std.mem.eql(u8, query_name, response_packet.answers[0].nameSlice())) return error.AnswerNameMismatch;
    if (response_packet.answers[0].rr_type != dns_protocol.type_a) return error.AnswerTypeMismatch;
    if (response_packet.answers[0].rr_class != dns_protocol.class_in) return error.AnswerClassMismatch;
    if (response_packet.answers[0].ttl != 300) return error.AnswerTtlMismatch;
    if (!std.mem.eql(u8, resolved_address[0..], response_packet.answers[0].dataSlice())) return error.AnswerDataMismatch;
    if (response_packet.udp_checksum_value == 0) return error.ChecksumMissing;
    if (eth.last_rx_len != expected_response_frame_len) return error.FrameLengthMismatch;
    if (eth.tx_packets < 2 or eth.rx_packets < 2) return error.CounterMismatch;
}

fn rtl8139DnsProbeFailureCode(err: Rtl8139DnsProbeError) u8 {
    return switch (err) {
        error.UnsupportedPlatform => 0x6A,
        error.DeviceNotFound => 0x6B,
        error.ResetTimeout => 0x6C,
        error.BufferProgramFailed => 0x6D,
        error.MacReadFailed => 0x6E,
        error.DataPathEnableFailed => 0x6F,
        error.StateMagicMismatch => 0x70,
        error.BackendMismatch => 0x71,
        error.InitFlagMismatch => 0x72,
        error.HardwareBackedMismatch => 0x73,
        error.IoBaseMismatch => 0x74,
        error.TxFailed => 0x75,
        error.RxTimedOut => 0x76,
        error.LastFrameTooShort => 0x77,
        error.LastFrameNotIpv4 => 0x78,
        error.LastIpv4DecodeFailed => 0x79,
        error.LastPacketNotUdp => 0x7A,
        error.LastUdpDecodeFailed => 0x7B,
        error.LastPacketNotDns => 0x7C,
        error.LastDnsDecodeFailed => 0x7D,
        error.DataPathDropped => 0x7E,
        error.TxCompletedNoRxInterrupt => 0x7F,
        error.TxCompletedNoRxProgress => 0x80,
        error.RxProducerStalled => 0x81,
        error.RxProducerAdvancedNoFrame => 0x82,
        error.PacketMissing => 0x83,
        error.PacketDestinationMismatch => 0x84,
        error.PacketSourceMismatch => 0x85,
        error.PacketProtocolMismatch => 0x86,
        error.PacketSenderMismatch => 0x87,
        error.PacketTargetMismatch => 0x88,
        error.PacketPortsMismatch => 0x89,
        error.TransactionIdMismatch => 0x8A,
        error.FlagsMismatch => 0x8B,
        error.QuestionCountMismatch => 0x8C,
        error.QuestionNameMismatch => 0x8D,
        error.QuestionTypeMismatch => 0x8E,
        error.QuestionClassMismatch => 0x8F,
        error.AnswerCountMismatch => 0x90,
        error.AnswerNameMismatch => 0x91,
        error.AnswerTypeMismatch => 0x92,
        error.AnswerClassMismatch => 0x93,
        error.AnswerTtlMismatch => 0x94,
        error.AnswerDataMismatch => 0x95,
        error.ChecksumMissing => 0x96,
        error.FrameLengthMismatch => 0x97,
        error.CounterMismatch => 0x98,
    };
}

fn toolExecProbeFailureCode(err: ToolExecProbeError) u8 {
    return switch (err) {
        error.AllocatorExhausted => 0x99,
        error.HelpRunFailed => 0x9A,
        error.HelpExitCodeFailed => 0x9B,
        error.HelpMissingBuiltin => 0x9C,
        error.MkdirRunFailed => 0x9D,
        error.MkdirExitCodeFailed => 0x9E,
        error.MkdirOutputMismatch => 0x9F,
        error.WriteRunFailed => 0xA0,
        error.WriteExitCodeFailed => 0xA1,
        error.WriteOutputMismatch => 0xA2,
        error.CatRunFailed => 0xA3,
        error.CatExitCodeFailed => 0xA4,
        error.CatMismatch => 0xA5,
        error.StatRunFailed => 0xA6,
        error.StatExitCodeFailed => 0xA7,
        error.StatMismatch => 0xA8,
        error.EchoRunFailed => 0xA9,
        error.EchoExitCodeFailed => 0xAA,
        error.EchoOutputMismatch => 0xAB,
        error.UnexpectedStderr => 0xAC,
        error.FilesystemReadbackFailed => 0xAD,
        error.FilesystemReadbackMismatch => 0xAE,
    };
}

fn probeFilesystemContent(path: []const u8, expected: []const u8) bool {
    var scratch: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const content = filesystem.readFileAlloc(fba.allocator(), path, scratch.len) catch return false;
    return std.mem.eql(u8, content, expected);
}

fn runToolExecProbe() ToolExecProbeError!void {
    resetBaremetalRuntimeForTest();
    vga_text_console.clear();

    var scratch: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const allocator = fba.allocator();
    const io: std.Io = undefined;

    var help = pal_proc.runCaptureFreestanding(allocator, io, &.{"help"}, 1000, 256, 128) catch |err| switch (err) {
        error.OutOfMemory => return error.AllocatorExhausted,
        else => return error.HelpRunFailed,
    };
    defer help.deinit(allocator);
    if (pal_proc.termExitCode(help.term) != 0) return error.HelpExitCodeFailed;
    if (!std.mem.containsAtLeast(u8, help.stdout, 1, "OpenClaw bare-metal builtins")) return error.HelpMissingBuiltin;
    if (help.stderr.len != 0) return error.UnexpectedStderr;

    var mkdir = pal_proc.runCaptureFreestanding(allocator, io, &.{ "mkdir", "/tools/tmp" }, 1000, 256, 128) catch |err| switch (err) {
        error.OutOfMemory => return error.AllocatorExhausted,
        else => return error.MkdirRunFailed,
    };
    defer mkdir.deinit(allocator);
    if (pal_proc.termExitCode(mkdir.term) != 0) return error.MkdirExitCodeFailed;
    if (!std.mem.eql(u8, mkdir.stdout, "created /tools/tmp\n")) return error.MkdirOutputMismatch;
    if (mkdir.stderr.len != 0) return error.UnexpectedStderr;

    var write_file = pal_proc.runCaptureFreestanding(allocator, io, &.{ "write-file", "/tools/tmp/tool.txt", "baremetal-tool" }, 1000, 256, 128) catch |err| switch (err) {
        error.OutOfMemory => return error.AllocatorExhausted,
        else => return error.WriteRunFailed,
    };
    defer write_file.deinit(allocator);
    if (pal_proc.termExitCode(write_file.term) != 0) return error.WriteExitCodeFailed;
    if (!std.mem.eql(u8, write_file.stdout, "wrote 14 bytes to /tools/tmp/tool.txt\n")) return error.WriteOutputMismatch;
    if (write_file.stderr.len != 0) return error.UnexpectedStderr;

    var cat = pal_proc.runCaptureFreestanding(allocator, io, &.{ "cat", "/tools/tmp/tool.txt" }, 1000, 256, 128) catch |err| switch (err) {
        error.OutOfMemory => return error.AllocatorExhausted,
        else => return error.CatRunFailed,
    };
    defer cat.deinit(allocator);
    if (pal_proc.termExitCode(cat.term) != 0) return error.CatExitCodeFailed;
    if (!std.mem.eql(u8, cat.stdout, "baremetal-tool")) return error.CatMismatch;
    if (cat.stderr.len != 0) return error.UnexpectedStderr;

    var stat = pal_proc.runCaptureFreestanding(allocator, io, &.{ "stat", "/tools/tmp/tool.txt" }, 1000, 256, 128) catch |err| switch (err) {
        error.OutOfMemory => return error.AllocatorExhausted,
        else => return error.StatRunFailed,
    };
    defer stat.deinit(allocator);
    if (pal_proc.termExitCode(stat.term) != 0) return error.StatExitCodeFailed;
    if (!std.mem.eql(u8, stat.stdout, "path=/tools/tmp/tool.txt kind=file size=14\n")) return error.StatMismatch;
    if (stat.stderr.len != 0) return error.UnexpectedStderr;

    const readback = filesystem.readFileAlloc(allocator, "/tools/tmp/tool.txt", 64) catch |err| switch (err) {
        error.OutOfMemory => return error.AllocatorExhausted,
        else => return error.FilesystemReadbackFailed,
    };
    defer allocator.free(readback);
    if (!std.mem.eql(u8, readback, "baremetal-tool")) return error.FilesystemReadbackMismatch;

    vga_text_console.clear();

    var echo = pal_proc.runCaptureFreestanding(allocator, io, &.{ "echo", "tool-exec-ok" }, 1000, 256, 128) catch |err| switch (err) {
        error.OutOfMemory => return error.AllocatorExhausted,
        else => return error.EchoRunFailed,
    };
    defer echo.deinit(allocator);
    if (pal_proc.termExitCode(echo.term) != 0) return error.EchoExitCodeFailed;
    if (!std.mem.eql(u8, echo.stdout, "tool-exec-ok\n")) return error.EchoOutputMismatch;
    if (echo.stderr.len != 0) return error.UnexpectedStderr;
}

fn ataStorageProbeFailureCode(err: AtaStorageProbeError) u8 {
    return switch (err) {
        error.AtaBackendUnavailable => 0x41,
        error.AtaCapacityTooSmall => 0x42,
        error.RawPatternWriteFailed => 0x43,
        error.RawPatternFlushFailed => 0x44,
        error.RawPatternReadbackFailed => 0x45,
        error.ToolLayoutInitFailed => 0x46,
        error.ToolLayoutWriteFailed => 0x47,
        error.ToolLayoutReadbackFailed => 0x48,
        error.ToolLayoutReloadFailed => 0x49,
        error.FilesystemInitFailed => 0x4A,
        error.FilesystemDirCreateFailed => 0x4B,
        error.FilesystemWriteFailed => 0x4C,
        error.FilesystemReadbackFailed => 0x4D,
        error.FilesystemReloadFailed => 0x4E,
    };
}

comptime {
    if (!builtin.is_test) {
        @export(&baremetalStart, .{ .name = "_start" });
    }
}

fn processPendingCommand() void {
    if (command_mailbox.seq == status.command_seq_ack) return;

    const command_seq = command_mailbox.seq;
    status.last_command_opcode = command_mailbox.opcode;
    status.last_command_result = if (command_mailbox.magic != abi.command_magic or
        command_mailbox.api_version != abi.api_version)
        abi.result_invalid_argument
    else
        executeCommand(command_mailbox.opcode, command_mailbox.arg0, command_mailbox.arg1);
    status.command_seq_ack = command_seq;
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
            const task_id = @as(u32, @truncate(arg0));
            const slot = schedulerFindTaskSlot(task_id) orelse return abi.result_not_found;
            if (scheduler_wait_kind[slot] == wait_condition_timer) {
                _ = timerCancelTask(task_id);
            }
            if (!schedulerWakeTask(task_id, abi.wake_reason_manual, 0, 0, status.ticks)) {
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
            const task_id = @as(u32, @truncate(arg0));
            const slot = schedulerFindTaskSlot(task_id) orelse return abi.result_not_found;
            if (scheduler_wait_kind[slot] == wait_condition_timer) {
                _ = timerCancelTask(task_id);
            }
            if (!schedulerWakeTask(task_id, abi.wake_reason_manual, 0, 0, status.ticks)) {
                return abi.result_not_found;
            }
            return abi.result_ok;
        },
        else => return abi.result_not_supported,
    }
}

fn mapStorageError(err: anyerror) i16 {
    return switch (err) {
        error.OutOfRange, error.UnalignedLength, error.InvalidSlot, error.CorruptLayout, error.InvalidPath, error.NotDirectory, error.IsDirectory, error.CorruptFilesystem, error.FileTooBig => abi.result_invalid_argument,
        error.FileNotFound => abi.result_not_found,
        error.NoSpace => abi.result_no_space,
        error.NotMounted => abi.result_conflict,
        error.NoDevice, error.DeviceFault, error.BusyTimeout, error.ProtocolError => abi.result_not_supported,
        else => abi.result_not_supported,
    };
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

    if (timer_state.enabled != abi.timer_state_enabled) return;

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
    var cleared_wait = false;
    for (&timer_entries) |*entry| {
        if (entry.state == abi.timer_entry_state_armed and entry.task_id == task_id) {
            entry.state = abi.timer_entry_state_canceled;
            canceled_any = true;
        }
    }
    if (schedulerFindTaskSlot(task_id)) |slot| {
        if (scheduler_tasks[slot].state == abi.task_state_waiting) {
            const kind = scheduler_wait_kind[slot];
            if (kind == wait_condition_timer) {
                schedulerSetWaitCondition(slot, wait_condition_manual, 0);
                cleared_wait = true;
            } else if ((kind == wait_condition_interrupt_any or kind == wait_condition_interrupt_vector) and
                scheduler_wait_timeout_tick[slot] != 0)
            {
                schedulerSetWaitCondition(slot, kind, scheduler_wait_interrupt_vector[slot]);
                cleared_wait = true;
            }
        }
    }
    if (!canceled_any and !cleared_wait) return abi.result_not_found;
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

fn wakeQueueRemoveTask(task_id: u32) u32 {
    if (wake_queue_count == 0) return 0;

    var kept: [wake_queue_capacity]BaremetalWakeEvent = std.mem.zeroes([wake_queue_capacity]BaremetalWakeEvent);
    var kept_count: u32 = 0;
    var removed: u32 = 0;
    var idx: u32 = 0;
    while (idx < wake_queue_count) : (idx += 1) {
        const event = oc_wake_queue_event(idx);
        if (event.task_id == task_id) {
            removed += 1;
            continue;
        }
        kept[kept_count] = event;
        kept_count += 1;
    }

    if (removed == 0) return 0;

    @memset(&wake_queue, std.mem.zeroes(BaremetalWakeEvent));
    var write_idx: u32 = 0;
    while (write_idx < kept_count) : (write_idx += 1) {
        wake_queue[@as(usize, @intCast(write_idx))] = kept[write_idx];
    }
    wake_queue_tail = 0;
    wake_queue_count = kept_count;
    wake_queue_head = if (kept_count == 0) 0 else @mod(kept_count, @as(u32, wake_queue_capacity));
    timer_state.pending_wake_count = @as(u16, @intCast(wake_queue_count));
    return removed;
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
    _ = timerCancelTask(task_id);
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
    _ = timerCancelTask(task_id);
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
    _ = timerCancelTask(task_id);
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
            _ = wakeQueueRemoveTask(task_id);
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
    framebuffer_console.resetForTest();
    vga_text_console.resetForTest();
    rtl8139.resetForTest();
    storage_backend.resetForTest();
    ps2_input.resetForTest();
    tool_layout.resetForTest();
    filesystem.resetForTest();
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

    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_diagnostics.phase);
    const boot_seq_before = boot_diagnostics.boot_seq;

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
    try std.testing.expectEqual(@as(u32, 1), boot_diagnostics.phase_changes);
    const captured_stack_snapshot = boot_diagnostics.stack_pointer_snapshot;
    try std.testing.expect(captured_stack_snapshot != 0);

    seq = oc_submit_command(abi.command_set_boot_phase, 99, 0);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 1), boot_diagnostics.phase_changes);
    try std.testing.expectEqual(captured_stack_snapshot, boot_diagnostics.stack_pointer_snapshot);

    seq = oc_submit_command(abi.command_reset_boot_diagnostics, 0, 0);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(u64, seq), boot_diagnostics.last_command_seq);
    try std.testing.expectEqual(boot_seq_before + 1, boot_diagnostics.boot_seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 0), boot_diagnostics.phase_changes);
    try std.testing.expectEqual(@as(u64, 0), boot_diagnostics.stack_pointer_snapshot);
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

test "baremetal mailbox header validation rejects invalid magic and api version" {
    resetBaremetalRuntimeForTest();

    command_mailbox = .{
        .magic = 0,
        .api_version = abi.api_version,
        .opcode = abi.command_set_tick_batch_hint,
        .seq = 1,
        .arg0 = 7,
        .arg1 = 0,
    };
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), status.command_seq_ack);
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u32, 0), command_mailbox.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version), command_mailbox.api_version);
    try std.testing.expectEqual(@as(u32, 1), command_mailbox.seq);
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_len());
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), oc_command_history_event(0).result);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), oc_command_history_event(0).opcode);

    command_mailbox = .{
        .magic = abi.command_magic,
        .api_version = abi.api_version + 1,
        .opcode = abi.command_set_tick_batch_hint,
        .seq = 2,
        .arg0 = 9,
        .arg1 = 0,
    };
    oc_tick();
    try std.testing.expectEqual(@as(u32, 2), status.command_seq_ack);
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u32, abi.command_magic), command_mailbox.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version + 1), command_mailbox.api_version);
    try std.testing.expectEqual(@as(u32, 2), command_mailbox.seq);
    try std.testing.expectEqual(@as(u32, 2), oc_command_history_len());
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), oc_command_history_event(1).result);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), oc_command_history_event(1).opcode);

    command_mailbox.magic = abi.command_magic;
    command_mailbox.api_version = abi.api_version;
    _ = oc_submit_command(abi.command_set_tick_batch_hint, 5, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 5), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u32, 3), status.command_seq_ack);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 3), oc_command_history_len());
    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_command_history_event(2).result);
}

test "baremetal mailbox replay no-op and sequence wraparound remain deterministic" {
    resetBaremetalRuntimeForTest();

    var seq = oc_submit_command(abi.command_set_tick_batch_hint, 4, 0);
    try std.testing.expectEqual(@as(u32, 1), seq);
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(u32, 4), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_event(0).seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), oc_command_history_event(0).opcode);
    try std.testing.expectEqual(@as(u64, 4), oc_command_history_event(0).arg0);
    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_command_history_event(0).result);

    const history_len_before_replay = oc_command_history_len();
    const last_opcode_before_replay = status.last_command_opcode;
    const last_result_before_replay = status.last_command_result;
    command_mailbox.opcode = abi.command_set_tick_batch_hint;
    command_mailbox.arg0 = 9;
    command_mailbox.arg1 = 0;
    oc_tick();
    try std.testing.expectEqual(seq, status.command_seq_ack);
    try std.testing.expectEqual(@as(u32, 4), status.tick_batch_hint);
    try std.testing.expectEqual(last_opcode_before_replay, status.last_command_opcode);
    try std.testing.expectEqual(last_result_before_replay, status.last_command_result);
    try std.testing.expectEqual(history_len_before_replay, oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_event(0).seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), oc_command_history_event(0).opcode);
    try std.testing.expectEqual(@as(u64, 4), oc_command_history_event(0).arg0);
    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_command_history_event(0).result);
    try std.testing.expectEqual(@as(u32, 1), command_mailbox.seq);

    command_mailbox.seq = std.math.maxInt(u32) - 1;
    status.command_seq_ack = std.math.maxInt(u32) - 1;

    seq = oc_submit_command(abi.command_set_tick_batch_hint, 6, 0);
    try std.testing.expectEqual(std.math.maxInt(u32), seq);
    oc_tick();
    try std.testing.expectEqual(std.math.maxInt(u32), status.command_seq_ack);
    try std.testing.expectEqual(@as(u32, 6), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u32, 2), oc_command_history_len());
    try std.testing.expectEqual(std.math.maxInt(u32), oc_command_history_event(1).seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), oc_command_history_event(1).opcode);
    try std.testing.expectEqual(@as(u64, 6), oc_command_history_event(1).arg0);
    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_command_history_event(1).result);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), command_mailbox.seq);

    seq = oc_submit_command(abi.command_set_tick_batch_hint, 7, 0);
    try std.testing.expectEqual(@as(u32, 0), seq);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), status.command_seq_ack);
    try std.testing.expectEqual(@as(u32, 7), status.tick_batch_hint);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 3), oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_command_history_event(2).seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_tick_batch_hint), oc_command_history_event(2).opcode);
    try std.testing.expectEqual(@as(u64, 7), oc_command_history_event(2).arg0);
    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_command_history_event(2).result);
    try std.testing.expectEqual(@as(u32, 0), command_mailbox.seq);
}

test "baremetal descriptor mailbox commands update init and load telemetry" {
    resetBaremetalRuntimeForTest();

    const init_before = x86_bootstrap.oc_descriptor_init_count();
    const attempts_before = x86_bootstrap.oc_descriptor_load_attempt_count();
    const success_before = x86_bootstrap.oc_descriptor_load_success_count();

    _ = oc_submit_command(abi.command_reinit_descriptor_tables, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(init_before + 1, x86_bootstrap.oc_descriptor_init_count());
    try std.testing.expect(x86_bootstrap.oc_descriptor_tables_ready());

    _ = oc_submit_command(abi.command_load_descriptor_tables, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(attempts_before + 1, x86_bootstrap.oc_descriptor_load_attempt_count());
    try std.testing.expectEqual(success_before + 1, x86_bootstrap.oc_descriptor_load_success_count());
    try std.testing.expect(x86_bootstrap.oc_descriptor_tables_loaded());
}

test "baremetal descriptor table content commands preserve descriptor pointers and entry wiring" {
    resetBaremetalRuntimeForTest();

    const init_before = x86_bootstrap.oc_descriptor_init_count();
    const attempts_before = x86_bootstrap.oc_descriptor_load_attempt_count();
    const success_before = x86_bootstrap.oc_descriptor_load_success_count();

    _ = oc_submit_command(abi.command_reinit_descriptor_tables, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_reinit_descriptor_tables), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), status.command_seq_ack);
    try std.testing.expectEqual(init_before + 1, x86_bootstrap.oc_descriptor_init_count());
    try std.testing.expect(x86_bootstrap.oc_descriptor_tables_ready());
    try std.testing.expect(x86_bootstrap.oc_descriptor_tables_loaded());

    _ = oc_submit_command(abi.command_load_descriptor_tables, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_load_descriptor_tables), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 2), status.command_seq_ack);
    try std.testing.expectEqual(attempts_before + 1, x86_bootstrap.oc_descriptor_load_attempt_count());
    try std.testing.expectEqual(success_before + 1, x86_bootstrap.oc_descriptor_load_success_count());
    try std.testing.expect(x86_bootstrap.oc_descriptor_tables_loaded());

    const gdtr = x86_bootstrap.oc_gdtr_ptr().*;
    const idtr = x86_bootstrap.oc_idtr_ptr().*;
    const gdt = x86_bootstrap.oc_gdt_ptr().*;
    const idt = x86_bootstrap.oc_idt_ptr().*;
    const interrupt_stub_addr = @intFromPtr(&x86_bootstrap.oc_interrupt_stub);
    const idt0_handler_addr =
        @as(u64, idt[0].offset_low) |
        (@as(u64, idt[0].offset_mid) << 16) |
        (@as(u64, idt[0].offset_high) << 32);
    const idt255_handler_addr =
        @as(u64, idt[255].offset_low) |
        (@as(u64, idt[255].offset_mid) << 16) |
        (@as(u64, idt[255].offset_high) << 32);

    try std.testing.expectEqual(
        @as(u16, @intCast(@sizeOf(x86_bootstrap.GdtEntry) * x86_bootstrap.gdt_entries_count - 1)),
        gdtr.limit,
    );
    try std.testing.expectEqual(
        @as(u16, @intCast(@sizeOf(x86_bootstrap.IdtEntry) * x86_bootstrap.idt_entries_count - 1)),
        idtr.limit,
    );
    try std.testing.expectEqual(@as(u64, @intFromPtr(x86_bootstrap.oc_gdt_ptr())), gdtr.base);
    try std.testing.expectEqual(@as(u64, @intFromPtr(x86_bootstrap.oc_idt_ptr())), idtr.base);

    try std.testing.expectEqual(@as(u16, 0xFFFF), gdt[1].limit_low);
    try std.testing.expectEqual(@as(u8, 0x9A), gdt[1].access);
    try std.testing.expectEqual(@as(u8, 0xAF), gdt[1].granularity);
    try std.testing.expectEqual(@as(u16, 0xFFFF), gdt[2].limit_low);
    try std.testing.expectEqual(@as(u8, 0x92), gdt[2].access);
    try std.testing.expectEqual(@as(u8, 0xAF), gdt[2].granularity);

    try std.testing.expectEqual(@as(u16, 0x08), idt[0].selector);
    try std.testing.expectEqual(@as(u8, 0), idt[0].ist);
    try std.testing.expectEqual(@as(u8, 0x8E), idt[0].type_attr);
    try std.testing.expectEqual(@as(u32, 0), idt[0].zero);
    try std.testing.expectEqual(interrupt_stub_addr, idt0_handler_addr);
    try std.testing.expectEqual(@as(u16, 0x08), idt[255].selector);
    try std.testing.expectEqual(@as(u8, 0), idt[255].ist);
    try std.testing.expectEqual(@as(u8, 0x8E), idt[255].type_attr);
    try std.testing.expectEqual(@as(u32, 0), idt[255].zero);
    try std.testing.expectEqual(interrupt_stub_addr, idt255_handler_addr);
}

test "baremetal descriptor dispatch commands update interrupt and exception histories" {
    resetBaremetalRuntimeForTest();

    x86_bootstrap.oc_interrupt_mask_clear_all();
    x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_reset_exception_counters();
    x86_bootstrap.oc_interrupt_history_clear();
    x86_bootstrap.oc_exception_history_clear();

    const init_before = x86_bootstrap.oc_descriptor_init_count();
    const attempts_before = x86_bootstrap.oc_descriptor_load_attempt_count();
    const success_before = x86_bootstrap.oc_descriptor_load_success_count();

    _ = oc_submit_command(abi.command_reinit_descriptor_tables, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_reinit_descriptor_tables), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), status.command_seq_ack);
    try std.testing.expectEqual(init_before + 1, x86_bootstrap.oc_descriptor_init_count());
    try std.testing.expect(x86_bootstrap.oc_descriptor_tables_ready());

    _ = oc_submit_command(abi.command_load_descriptor_tables, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_load_descriptor_tables), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 2), status.command_seq_ack);
    try std.testing.expectEqual(attempts_before + 1, x86_bootstrap.oc_descriptor_load_attempt_count());
    try std.testing.expectEqual(success_before + 1, x86_bootstrap.oc_descriptor_load_success_count());
    try std.testing.expect(x86_bootstrap.oc_descriptor_tables_loaded());

    _ = oc_submit_command(abi.command_reset_interrupt_counters, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_reset_interrupt_counters), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 3), status.command_seq_ack);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());

    _ = oc_submit_command(abi.command_reset_exception_counters, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_reset_exception_counters), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 4), status.command_seq_ack);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_exception_count());

    _ = oc_submit_command(abi.command_clear_interrupt_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_clear_interrupt_history), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 5), status.command_seq_ack);
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_history_len());

    _ = oc_submit_command(abi.command_clear_exception_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_clear_exception_history), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 6), status.command_seq_ack);
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_exception_history_len());

    _ = oc_submit_command(abi.command_trigger_interrupt, 44, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_trigger_interrupt), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 7), status.command_seq_ack);

    _ = oc_submit_command(abi.command_trigger_exception, 13, 51966);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_trigger_exception), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 8), status.command_seq_ack);

    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_exception_vector());
    try std.testing.expectEqual(@as(u64, 51966), x86_bootstrap.oc_last_exception_code());
    try std.testing.expectEqual(@as(u32, 2), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());

    const interrupt0 = x86_bootstrap.oc_interrupt_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), interrupt0.seq);
    try std.testing.expectEqual(@as(u8, 44), interrupt0.vector);
    try std.testing.expectEqual(@as(u8, 0), interrupt0.is_exception);
    try std.testing.expectEqual(@as(u64, 0), interrupt0.code);
    try std.testing.expectEqual(@as(u64, 1), interrupt0.interrupt_count);
    try std.testing.expectEqual(@as(u64, 0), interrupt0.exception_count);

    const interrupt1 = x86_bootstrap.oc_interrupt_history_event(1);
    try std.testing.expectEqual(@as(u32, 2), interrupt1.seq);
    try std.testing.expectEqual(@as(u8, 13), interrupt1.vector);
    try std.testing.expectEqual(@as(u8, 1), interrupt1.is_exception);
    try std.testing.expectEqual(@as(u64, 51966), interrupt1.code);
    try std.testing.expectEqual(@as(u64, 2), interrupt1.interrupt_count);
    try std.testing.expectEqual(@as(u64, 1), interrupt1.exception_count);

    const exception0 = x86_bootstrap.oc_exception_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), exception0.seq);
    try std.testing.expectEqual(@as(u8, 13), exception0.vector);
    try std.testing.expectEqual(@as(u64, 51966), exception0.code);
    try std.testing.expectEqual(@as(u64, 2), exception0.interrupt_count);
    try std.testing.expectEqual(@as(u64, 1), exception0.exception_count);
}

test "baremetal reset vector counters command clears vector tables without disturbing histories" {
    resetBaremetalRuntimeForTest();

    x86_bootstrap.oc_interrupt_mask_clear_all();
    x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_reset_exception_counters();
    x86_bootstrap.oc_reset_vector_counters();
    x86_bootstrap.oc_interrupt_history_clear();
    x86_bootstrap.oc_exception_history_clear();

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_exception, 13, 0xCAFE);
    oc_tick();

    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(13));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_vector_count(13));
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_exception_vector());
    try std.testing.expectEqual(@as(u64, 0xCAFE), x86_bootstrap.oc_last_exception_code());
    try std.testing.expectEqual(@as(u32, 2), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());

    _ = oc_submit_command(abi.command_reset_vector_counters, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_vector_count(13));
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_exception_vector_count(13));
    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_exception_vector());
    try std.testing.expectEqual(@as(u64, 0xCAFE), x86_bootstrap.oc_last_exception_code());
    try std.testing.expectEqual(@as(u32, 2), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());
}

test "baremetal vector history overflow commands saturate histories and preserve per-vector telemetry" {
    resetBaremetalRuntimeForTest();

    x86_bootstrap.oc_interrupt_mask_clear_all();
    x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_interrupt_history_clear();
    x86_bootstrap.oc_reset_vector_counters();

    var idx: u32 = 0;
    while (idx < 35) : (idx += 1) {
        _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
        oc_tick();
    }

    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_trigger_interrupt), status.last_command_opcode);
    try std.testing.expectEqual(@as(u64, 35), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 35), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u32, 32), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 3), x86_bootstrap.oc_interrupt_history_overflow_count());
    try std.testing.expectEqual(@as(u8, 200), x86_bootstrap.oc_last_interrupt_vector());
    const interrupt_first = x86_bootstrap.oc_interrupt_history_event(0);
    try std.testing.expectEqual(@as(u32, 4), interrupt_first.seq);
    try std.testing.expectEqual(@as(u8, 200), interrupt_first.vector);
    try std.testing.expectEqual(@as(u8, 0), interrupt_first.is_exception);
    const interrupt_last = x86_bootstrap.oc_interrupt_history_event(x86_bootstrap.oc_interrupt_history_len() - 1);
    try std.testing.expectEqual(@as(u32, 35), interrupt_last.seq);
    try std.testing.expectEqual(@as(u8, 200), interrupt_last.vector);

    _ = oc_submit_command(abi.command_reset_exception_counters, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_clear_exception_history, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_reset_interrupt_counters, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_clear_interrupt_history, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_reset_vector_counters, 0, 0);
    oc_tick();

    idx = 0;
    while (idx < 19) : (idx += 1) {
        _ = oc_submit_command(abi.command_trigger_exception, 13, 100 + idx);
        oc_tick();
    }

    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_trigger_exception), status.last_command_opcode);
    try std.testing.expectEqual(@as(u64, 19), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 19), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u64, 19), x86_bootstrap.oc_interrupt_vector_count(13));
    try std.testing.expectEqual(@as(u64, 19), x86_bootstrap.oc_exception_vector_count(13));
    try std.testing.expectEqual(@as(u32, 19), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 16), x86_bootstrap.oc_exception_history_len());
    try std.testing.expectEqual(@as(u32, 3), x86_bootstrap.oc_exception_history_overflow_count());
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u8, 13), x86_bootstrap.oc_last_exception_vector());
    try std.testing.expectEqual(@as(u64, 118), x86_bootstrap.oc_last_exception_code());
    const exception_first = x86_bootstrap.oc_exception_history_event(0);
    try std.testing.expectEqual(@as(u32, 4), exception_first.seq);
    try std.testing.expectEqual(@as(u8, 13), exception_first.vector);
    try std.testing.expectEqual(@as(u64, 103), exception_first.code);
    const exception_last = x86_bootstrap.oc_exception_history_event(x86_bootstrap.oc_exception_history_len() - 1);
    try std.testing.expectEqual(@as(u32, 19), exception_last.seq);
    try std.testing.expectEqual(@as(u8, 13), exception_last.vector);
    try std.testing.expectEqual(@as(u64, 118), exception_last.code);
}

test "baremetal scheduler default budget command rejects zero without clobbering state" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    try std.testing.expect(!oc_scheduler_enabled());

    _ = oc_submit_command(abi.command_scheduler_set_default_budget, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 9), oc_scheduler_state_ptr().default_budget_ticks);

    _ = oc_submit_command(abi.command_task_create, 0, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    const task0 = oc_scheduler_task(0);
    try std.testing.expect(task0.task_id != 0);
    try std.testing.expectEqual(@as(u32, 9), task0.budget_ticks);
    try std.testing.expectEqual(@as(u32, 9), task0.budget_remaining);

    _ = oc_submit_command(abi.command_scheduler_set_default_budget, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 9), oc_scheduler_state_ptr().default_budget_ticks);

    _ = oc_submit_command(abi.command_task_create, 0, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_task_count());
    const task1 = oc_scheduler_task(1);
    try std.testing.expect(task1.task_id != 0);
    try std.testing.expectEqual(@as(u32, 9), task1.budget_ticks);
    try std.testing.expectEqual(@as(u32, 9), task1.budget_remaining);
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

test "baremetal clear command history preserves health history and restarts command sequence" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_health_code, 418, 0);
    oc_tick();

    const pre_health_len = oc_health_history_len();
    const pre_health_seq = health_history_seq;
    const pre_boot_seq = boot_diagnostics.boot_seq;

    _ = oc_submit_command(abi.command_clear_command_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 1), oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_command_history_overflow_count());
    const clear_event = oc_command_history_event(0);
    try std.testing.expectEqual(status.command_seq_ack, clear_event.seq);
    try std.testing.expectEqual(@as(u16, abi.command_clear_command_history), clear_event.opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), clear_event.result);
    try std.testing.expectEqual(pre_health_len + 1, oc_health_history_len());
    try std.testing.expectEqual(pre_health_seq + 1, health_history_seq);
    try std.testing.expectEqual(pre_boot_seq, boot_diagnostics.boot_seq);
    try std.testing.expectEqual(@as(u16, 200), oc_health_history_event(oc_health_history_len() - 1).health_code);

    _ = oc_submit_command(abi.command_set_health_code, 512, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 2), oc_command_history_len());
    const restarted_event = oc_command_history_event(1);
    try std.testing.expectEqual(status.command_seq_ack, restarted_event.seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_health_code), restarted_event.opcode);
    try std.testing.expectEqual(@as(u64, 512), restarted_event.arg0);
}

test "baremetal command history overflow clear resets ring and restarts from the clear command" {
    resetBaremetalRuntimeForTest();

    const cap = oc_command_history_capacity();
    var idx: u32 = 0;
    while (idx < cap + 3) : (idx += 1) {
        _ = oc_submit_command(abi.command_set_health_code, 600 + idx, 0);
        oc_tick();
    }

    try std.testing.expectEqual(cap, oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 3), oc_command_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 4), oc_command_history_event(0).seq);
    try std.testing.expectEqual(@as(u64, 603), oc_command_history_event(0).arg0);
    const overflow_last = oc_command_history_event(cap - 1);
    try std.testing.expectEqual(@as(u32, 35), overflow_last.seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_health_code), overflow_last.opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), overflow_last.result);
    try std.testing.expectEqual(@as(u64, 634), overflow_last.arg0);

    const pre_health_len = oc_health_history_len();
    const pre_health_overflow = oc_health_history_overflow_count();

    _ = oc_submit_command(abi.command_clear_command_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 1), oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_command_history_overflow_count());
    const clear_event = oc_command_history_event(0);
    try std.testing.expectEqual(status.command_seq_ack, clear_event.seq);
    try std.testing.expectEqual(@as(u16, abi.command_clear_command_history), clear_event.opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), clear_event.result);
    try std.testing.expectEqual(pre_health_len, oc_health_history_len());
    try std.testing.expectEqual(pre_health_overflow + 1, oc_health_history_overflow_count());

    _ = oc_submit_command(abi.command_set_health_code, 999, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 2), oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_command_history_head_index());
    const restarted_event = oc_command_history_event(1);
    try std.testing.expectEqual(status.command_seq_ack, restarted_event.seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_health_code), restarted_event.opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), restarted_event.result);
    try std.testing.expectEqual(@as(u64, 999), restarted_event.arg0);
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

test "baremetal clear health history preserves command history and restarts health sequence" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_health_code, 418, 0);
    oc_tick();

    const pre_command_len = oc_command_history_len();
    const pre_boot_seq = boot_diagnostics.boot_seq;

    _ = oc_submit_command(abi.command_clear_health_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(pre_command_len + 1, oc_command_history_len());
    const clear_command = oc_command_history_event(oc_command_history_len() - 1);
    try std.testing.expectEqual(@as(u16, abi.command_clear_health_history), clear_command.opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_health_history_overflow_count());
    const clear_health = oc_health_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), clear_health.seq);
    try std.testing.expectEqual(@as(u16, 200), clear_health.health_code);
    try std.testing.expectEqual(pre_boot_seq, boot_diagnostics.boot_seq);

    _ = oc_submit_command(abi.command_set_health_code, 777, 0);
    oc_tick();

    try std.testing.expect(oc_health_history_len() >= 3);
    const restarted_health = oc_health_history_event(1);
    try std.testing.expectEqual(@as(u32, 2), restarted_health.seq);
    try std.testing.expectEqual(@as(u16, 777), restarted_health.health_code);
}

test "baremetal health history overflow clear resets ring and restarts from seq one" {
    resetBaremetalRuntimeForTest();

    const cap = oc_health_history_capacity();
    var idx: u32 = 0;
    while (oc_health_history_len() < cap or oc_health_history_overflow_count() == 0) : (idx += 1) {
        _ = oc_submit_command(abi.command_set_health_code, 700 + idx, 0);
        oc_tick();
    }

    try std.testing.expectEqual(cap, oc_health_history_len());
    try std.testing.expect(oc_health_history_overflow_count() > 0);
    try std.testing.expect(oc_health_history_event(0).seq > 1);

    const pre_command_len = oc_command_history_len();
    const pre_command_overflow = oc_command_history_overflow_count();

    _ = oc_submit_command(abi.command_clear_health_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 1), oc_health_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_health_history_overflow_count());
    const clear_health = oc_health_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), clear_health.seq);
    try std.testing.expectEqual(@as(u16, 200), clear_health.health_code);
    try std.testing.expectEqual(@as(u8, abi.mode_running), clear_health.mode);
    try std.testing.expectEqual(status.command_seq_ack, clear_health.command_seq_ack);
    try std.testing.expectEqual(pre_command_len, oc_command_history_len());
    try std.testing.expectEqual(pre_command_overflow + 1, oc_command_history_overflow_count());

    _ = oc_submit_command(abi.command_set_health_code, 777, 0);
    oc_tick();

    try std.testing.expect(oc_health_history_len() >= 3);
    const restarted_health = oc_health_history_event(1);
    try std.testing.expectEqual(@as(u32, 2), restarted_health.seq);
    try std.testing.expectEqual(@as(u16, 777), restarted_health.health_code);
    try std.testing.expectEqual(@as(u8, abi.mode_running), restarted_health.mode);
    try std.testing.expectEqual(status.command_seq_ack - 1, restarted_health.command_seq_ack);
}

test "baremetal repeated health-code commands saturate command and health histories together" {
    resetBaremetalRuntimeForTest();

    var idx: u32 = 0;
    while (idx < 35) : (idx += 1) {
        _ = oc_submit_command(abi.command_set_health_code, 100 + idx, 0);
        oc_tick();
    }

    try std.testing.expectEqual(@as(u32, 35), status.command_seq_ack);
    try std.testing.expectEqual(@as(u16, abi.command_set_health_code), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(status.ticks >= 35);

    try std.testing.expectEqual(@as(u32, 32), oc_command_history_len());
    try std.testing.expectEqual(@as(u32, 3), oc_command_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 3), oc_command_history_head_index());
    const first_command = oc_command_history_event(0);
    try std.testing.expectEqual(@as(u32, 4), first_command.seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_health_code), first_command.opcode);
    try std.testing.expectEqual(@as(u64, 103), first_command.arg0);
    const last_command = oc_command_history_event(oc_command_history_len() - 1);
    try std.testing.expectEqual(@as(u32, 35), last_command.seq);
    try std.testing.expectEqual(@as(u16, abi.command_set_health_code), last_command.opcode);
    try std.testing.expectEqual(@as(u64, 134), last_command.arg0);

    try std.testing.expectEqual(@as(u32, 64), oc_health_history_len());
    try std.testing.expect(oc_health_history_overflow_count() >= 6);
    const first_health = oc_health_history_event(0);
    try std.testing.expect(first_health.seq > 1);
    try std.testing.expect(first_health.health_code >= 103 and first_health.health_code <= 104);
    const prev_last_health = oc_health_history_event(oc_health_history_len() - 2);
    try std.testing.expect(prev_last_health.seq >= 69);
    try std.testing.expectEqual(@as(u16, 134), prev_last_health.health_code);
    try std.testing.expectEqual(@as(u32, 34), prev_last_health.command_seq_ack);
    const last_health = oc_health_history_event(oc_health_history_len() - 1);
    try std.testing.expect(last_health.seq >= prev_last_health.seq);
    try std.testing.expectEqual(@as(u16, 200), last_health.health_code);
    try std.testing.expectEqual(@as(u32, 35), last_health.command_seq_ack);
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
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), mode_history_seq);

    status.mode = abi.mode_running;
    status.panic_count = 0;
    _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_head_index());
    const m_after_clear = oc_mode_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), m_after_clear.seq);
    try std.testing.expectEqual(@as(u8, abi.mode_running), m_after_clear.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), m_after_clear.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_command), m_after_clear.reason);
}

test "baremetal mode history overflow clear resets ring and restarts from seq one" {
    resetBaremetalRuntimeForTest();

    const cap = oc_mode_history_capacity();
    var iteration: u32 = 0;
    while (iteration < (cap / 2) + 1) : (iteration += 1) {
        _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
        oc_tick();
    }

    try std.testing.expectEqual(cap, oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 3), oc_mode_history_event(0).seq);
    try std.testing.expectEqual(@as(u8, abi.mode_running), oc_mode_history_event(0).previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), oc_mode_history_event(0).new_mode);
    const latest_overflow_mode = oc_mode_history_event(cap - 1);
    try std.testing.expectEqual(@as(u32, 66), latest_overflow_mode.seq);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), latest_overflow_mode.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_running), latest_overflow_mode.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_runtime_tick), latest_overflow_mode.reason);

    _ = oc_submit_command(abi.command_clear_mode_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), mode_history_seq);

    status.mode = abi.mode_running;
    status.panic_count = 0;
    _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 2), mode_history_seq);
    const restarted_mode = oc_mode_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), restarted_mode.seq);
    try std.testing.expectEqual(@as(u8, abi.mode_running), restarted_mode.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), restarted_mode.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_command), restarted_mode.reason);
    const restarted_runtime_mode = oc_mode_history_event(1);
    try std.testing.expectEqual(@as(u32, 2), restarted_runtime_mode.seq);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), restarted_runtime_mode.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_running), restarted_runtime_mode.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_runtime_tick), restarted_runtime_mode.reason);
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
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), boot_phase_history_seq);

    status.mode = abi.mode_running;
    status.panic_count = 0;
    boot_diagnostics.phase = abi.boot_phase_runtime;
    boot_diagnostics.phase_changes = 0;
    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_head_index());
    const p_after_clear = oc_boot_phase_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), p_after_clear.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), p_after_clear.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), p_after_clear.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), p_after_clear.reason);
}

test "baremetal mode and boot phase history clear preserve sibling ring and restart both histories" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_panic_flag, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 3), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 3), oc_boot_phase_history_len());

    _ = oc_submit_command(abi.command_clear_mode_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), mode_history_seq);
    try std.testing.expectEqual(@as(u32, 3), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 3), boot_phase_history_seq);
    const preserved_boot = oc_boot_phase_history_event(2);
    try std.testing.expectEqual(@as(u32, 3), preserved_boot.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), preserved_boot.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_panicked), preserved_boot.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_panic), preserved_boot.reason);

    _ = oc_submit_command(abi.command_clear_boot_phase_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), boot_phase_history_seq);

    status.mode = abi.mode_running;
    status.panic_count = 0;
    boot_diagnostics.phase = abi.boot_phase_runtime;
    boot_diagnostics.phase_changes = 0;

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 2), mode_history_seq);
    const reset_mode0 = oc_mode_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), reset_mode0.seq);
    try std.testing.expectEqual(@as(u8, abi.mode_running), reset_mode0.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), reset_mode0.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_command), reset_mode0.reason);
    const reset_mode1 = oc_mode_history_event(1);
    try std.testing.expectEqual(@as(u32, 2), reset_mode1.seq);
    try std.testing.expectEqual(@as(u8, abi.mode_booting), reset_mode1.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_running), reset_mode1.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_runtime_tick), reset_mode1.reason);

    try std.testing.expectEqual(@as(u32, 2), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_boot_phase_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 2), boot_phase_history_seq);
    const reset_boot0 = oc_boot_phase_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), reset_boot0.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), reset_boot0.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), reset_boot0.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), reset_boot0.reason);
    const reset_boot1 = oc_boot_phase_history_event(1);
    try std.testing.expectEqual(@as(u32, 2), reset_boot1.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), reset_boot1.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), reset_boot1.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_runtime_tick), reset_boot1.reason);
}

test "baremetal boot phase history overflow clear resets ring and restarts from seq one" {
    resetBaremetalRuntimeForTest();

    const cap = oc_boot_phase_history_capacity();
    var iteration: u32 = 0;
    while (iteration < (cap / 2) + 1) : (iteration += 1) {
        _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
        oc_tick();
        _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
        oc_tick();
    }

    try std.testing.expectEqual(cap, oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_boot_phase_history_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_boot_phase_history_overflow_count());
    const oldest_phase = oc_boot_phase_history_event(0);
    try std.testing.expectEqual(@as(u32, 3), oldest_phase.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), oldest_phase.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), oldest_phase.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), oldest_phase.reason);
    const newest_phase = oc_boot_phase_history_event(cap - 1);
    try std.testing.expectEqual(@as(u32, 66), newest_phase.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), newest_phase.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), newest_phase.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_runtime_tick), newest_phase.reason);

    _ = oc_submit_command(abi.command_clear_boot_phase_history, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), boot_phase_history_seq);
    try std.testing.expectEqual(oc_mode_history_capacity(), oc_mode_history_len());

    status.mode = abi.mode_running;
    status.panic_count = 0;
    boot_diagnostics.phase = abi.boot_phase_runtime;
    boot_diagnostics.phase_changes = 0;
    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_head_index());
    const restarted_phase = oc_boot_phase_history_event(0);
    try std.testing.expectEqual(@as(u32, 1), restarted_phase.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), restarted_phase.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), restarted_phase.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), restarted_phase.reason);

    _ = oc_submit_command(abi.command_set_mode, abi.mode_booting, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 2), oc_boot_phase_history_len());
    try std.testing.expectEqual(@as(u32, 2), oc_boot_phase_history_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_overflow_count());
    try std.testing.expectEqual(@as(u32, 2), boot_phase_history_seq);
    const restarted_second_phase = oc_boot_phase_history_event(1);
    try std.testing.expectEqual(@as(u32, 2), restarted_second_phase.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), restarted_second_phase.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), restarted_second_phase.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_runtime_tick), restarted_second_phase.reason);
}

test "baremetal direct mode and boot phase setters are isolated, idempotent, and reject invalid values" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_mode, abi.mode_running, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_mode), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.mode_running), status.mode);
    try std.testing.expectEqual(@as(u32, 0), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 0), status.panic_count);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_len());

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_runtime, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_boot_phase), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 0), boot_diagnostics.phase_changes);
    try std.testing.expectEqual(@as(u32, 0), oc_boot_phase_history_len());

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_boot_phase), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());
    const boot0 = oc_boot_phase_history_event(0);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot0.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot0.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), boot0.reason);

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_boot_phase), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 1), boot_diagnostics.phase_changes);
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());

    _ = oc_submit_command(abi.command_set_boot_phase, 99, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_boot_phase), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());

    _ = oc_submit_command(abi.command_set_mode, abi.mode_panicked, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_mode), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.mode_panicked), status.mode);
    try std.testing.expectEqual(@as(u32, 0), status.panic_count);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 1), oc_mode_history_len());
    const mode0 = oc_mode_history_event(0);
    try std.testing.expectEqual(@as(u8, abi.mode_running), mode0.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_panicked), mode0.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_command), mode0.reason);

    _ = oc_submit_command(abi.command_set_mode, abi.mode_running, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_mode), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.mode_running), status.mode);
    try std.testing.expectEqual(@as(u32, 0), status.panic_count);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_len());
    const mode1 = oc_mode_history_event(1);
    try std.testing.expectEqual(@as(u8, abi.mode_panicked), mode1.previous_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_running), mode1.new_mode);
    try std.testing.expectEqual(@as(u8, abi.mode_change_reason_command), mode1.reason);
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());

    _ = oc_submit_command(abi.command_set_mode, 77, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_set_mode), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.mode_running), status.mode);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());

    _ = oc_submit_command(abi.command_set_mode, abi.mode_running, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.mode_running), status.mode);
    try std.testing.expectEqual(@as(u32, 2), oc_mode_history_len());
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u32, 1), oc_boot_phase_history_len());
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

test "baremetal reset command result counters preserves runtime state and restarts cleanly" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_health_code, 418, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_mode, 77, 0);
    oc_tick();
    _ = oc_submit_command(65535, 0, 0);
    oc_tick();

    const pre_command_len = oc_command_history_len();
    const pre_health_len = oc_health_history_len();
    const pre_health = status.last_health_code;
    const pre_mode = status.mode;

    _ = oc_submit_command(abi.command_reset_command_result_counters, 0, 0);
    oc_tick();

    try std.testing.expectEqual(pre_mode, status.mode);
    try std.testing.expectEqual(pre_health, status.last_health_code);
    try std.testing.expectEqual(pre_command_len + 1, oc_command_history_len());
    try std.testing.expectEqual(pre_health_len + 1, oc_health_history_len());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_total_count());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_ok());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_invalid_argument());
    try std.testing.expectEqual(@as(u32, 0), oc_command_result_count_not_supported());
    try std.testing.expectEqual(@as(u16, abi.command_reset_command_result_counters), oc_command_result_counters_ptr().last_opcode);

    _ = oc_submit_command(abi.command_set_mode, 77, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 2), oc_command_result_total_count());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_ok());
    try std.testing.expectEqual(@as(u32, 1), oc_command_result_count_invalid_argument());
    try std.testing.expectEqual(@as(u16, abi.command_set_mode), oc_command_result_counters_ptr().last_opcode);
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
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
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
    try std.testing.expectEqual(@as(u32, status.command_seq_ack), oc_command_history_event(0).seq);
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_len());
    try std.testing.expectEqual(@as(u16, 200), oc_health_history_event(0).health_code);
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_event(0).seq);
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

test "baremetal reset counters preserves feature flags and tick batch hint configuration" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_feature_flags, 0xA55AA55A, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_tick_batch_hint, 4, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_health_code, 123, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 8, 2);
    oc_tick();

    _ = oc_submit_command(abi.command_reset_counters, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u32, 0xA55AA55A), status.feature_flags);
    try std.testing.expectEqual(@as(u32, 4), status.tick_batch_hint);
    try std.testing.expectEqual(@as(u64, 4), status.ticks);
    try std.testing.expectEqual(@as(u32, 1), oc_command_history_len());
    try std.testing.expectEqual(@as(u16, abi.command_reset_counters), oc_command_history_event(0).opcode);
    try std.testing.expectEqual(@as(u32, status.command_seq_ack), oc_command_history_event(0).seq);
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_len());
    try std.testing.expectEqual(@as(u16, 200), oc_health_history_event(0).health_code);
    try std.testing.expectEqual(@as(u32, 1), oc_health_history_event(0).seq);
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

test "baremetal capture stack pointer refreshes diagnostics without resetting boot state" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();

    const boot_seq_before = boot_diagnostics.boot_seq;
    const phase_changes_before = boot_diagnostics.phase_changes;
    const history_len_before = oc_boot_phase_history_len();

    _ = oc_submit_command(abi.command_capture_stack_pointer, 0, 0);
    oc_tick();

    const first_snapshot = boot_diagnostics.stack_pointer_snapshot;
    const first_observed = boot_diagnostics.last_tick_observed;
    try std.testing.expect(first_snapshot != 0);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(boot_seq_before, boot_diagnostics.boot_seq);
    try std.testing.expectEqual(phase_changes_before, boot_diagnostics.phase_changes);
    try std.testing.expectEqual(history_len_before, oc_boot_phase_history_len());
    try std.testing.expect(boot_diagnostics.last_tick_observed >= boot_diagnostics.last_command_tick);

    _ = oc_submit_command(abi.command_capture_stack_pointer, 0, 0);
    oc_tick();

    try std.testing.expect(boot_diagnostics.stack_pointer_snapshot != 0);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_diagnostics.phase);
    try std.testing.expectEqual(boot_seq_before, boot_diagnostics.boot_seq);
    try std.testing.expectEqual(history_len_before, oc_boot_phase_history_len());
    try std.testing.expect(boot_diagnostics.last_tick_observed >= first_observed);
}

test "baremetal reset boot diagnostics preserves histories and runtime mode" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_set_health_code, 418, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_capture_stack_pointer, 0, 0);
    oc_tick();

    const pre_boot_seq = boot_diagnostics.boot_seq;
    const pre_command_len = oc_command_history_len();
    const pre_health_len = oc_health_history_len();
    const pre_boot_history_len = oc_boot_phase_history_len();
    try std.testing.expect(boot_diagnostics.stack_pointer_snapshot != 0);

    _ = oc_submit_command(abi.command_reset_boot_diagnostics, 0, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u8, abi.mode_running), status.mode);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_diagnostics.phase);
    try std.testing.expectEqual(pre_boot_seq +% 1, boot_diagnostics.boot_seq);
    try std.testing.expectEqual(@as(u32, 0), boot_diagnostics.phase_changes);
    try std.testing.expectEqual(@as(u64, 0), boot_diagnostics.stack_pointer_snapshot);
    try std.testing.expectEqual(pre_command_len + 1, oc_command_history_len());
    try std.testing.expectEqual(pre_health_len + 1, oc_health_history_len());
    try std.testing.expectEqual(pre_boot_history_len, oc_boot_phase_history_len());
    const preserved_boot_event = oc_boot_phase_history_event(pre_boot_history_len - 1);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), preserved_boot_event.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), preserved_boot_event.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), preserved_boot_event.reason);
    try std.testing.expectEqual(@as(u32, 1), preserved_boot_event.command_seq_ack);

    const reset_event = oc_command_history_event(oc_command_history_len() - 1);
    try std.testing.expectEqual(@as(u32, 4), reset_event.seq);
    try std.testing.expectEqual(@as(u16, abi.command_reset_boot_diagnostics), reset_event.opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), reset_event.result);
    try std.testing.expectEqual(@as(u64, 0), reset_event.arg0);
    try std.testing.expectEqual(@as(u64, 0), reset_event.arg1);

    const reset_health_event = oc_health_history_event(oc_health_history_len() - 1);
    try std.testing.expectEqual(@as(u32, 5), reset_health_event.seq);
    try std.testing.expectEqual(@as(u16, 200), reset_health_event.health_code);
    try std.testing.expectEqual(@as(u8, abi.mode_running), reset_health_event.mode);
    try std.testing.expectEqual(@as(u32, 4), reset_health_event.command_seq_ack);

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_init, 0);
    oc_tick();

    try std.testing.expectEqual(pre_boot_history_len + 1, oc_boot_phase_history_len());

    const boot_restart_event = oc_boot_phase_history_event(oc_boot_phase_history_len() - 1);
    try std.testing.expectEqual(@as(u32, 2), boot_restart_event.seq);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_restart_event.previous_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_init), boot_restart_event.new_phase);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_change_reason_command), boot_restart_event.reason);
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
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_scheduler_enable), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), status.command_seq_ack);

    _ = oc_submit_command(abi.command_task_create, 3, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_create), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 2), status.command_seq_ack);
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
    try std.testing.expectEqual(@as(u16, abi.command_task_create), status.last_command_opcode);
    try std.testing.expectEqual(capacity + 1, status.command_seq_ack);
    try std.testing.expectEqual(capacity, oc_scheduler_task_count());

    _ = oc_submit_command(abi.command_task_terminate, reused_slot_previous_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_terminate), status.last_command_opcode);
    try std.testing.expectEqual(capacity + 2, status.command_seq_ack);
    try std.testing.expectEqual(capacity - 1, oc_scheduler_task_count());
    const terminated = oc_scheduler_task(reuse_slot);
    try std.testing.expectEqual(reused_slot_previous_id, terminated.task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), terminated.state);

    _ = oc_submit_command(abi.command_task_create, 7, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_create), status.last_command_opcode);
    try std.testing.expectEqual(capacity + 3, status.command_seq_ack);
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
    try std.testing.expectEqual(@as(u32, 1), state_after_alloc.alloc_ops);
    try std.testing.expectEqual(@as(u32, 0), state_after_alloc.free_ops);
    try std.testing.expectEqual(initial_free - 2, state_after_alloc.free_pages);
    try std.testing.expectEqual(@as(u64, 8192), state_after_alloc.bytes_in_use);
    try std.testing.expectEqual(@as(u64, 8192), state_after_alloc.peak_bytes_in_use);
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
    try std.testing.expectEqual(@as(u32, 1), state_after_free.alloc_ops);
    try std.testing.expectEqual(@as(u32, 1), state_after_free.free_ops);
    try std.testing.expectEqual(initial_free, state_after_free.free_pages);
    try std.testing.expectEqual(@as(u64, 0), state_after_free.bytes_in_use);
    try std.testing.expectEqual(@as(u64, 8192), state_after_free.peak_bytes_in_use);
    try std.testing.expectEqual(alloc0.ptr, state_after_free.last_free_ptr);
    try std.testing.expectEqual(@as(u64, 8192), state_after_free.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(0).state);

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
    try std.testing.expectEqual(@as(u8, 0), entry0.flags);
    try std.testing.expectEqual(@as(u64, 0xAA55), entry0.handler_token);

    _ = oc_submit_command(abi.command_syscall_invoke, 7, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const syscall_state_after_invoke = oc_syscall_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 7), syscall_state_after_invoke.last_syscall_id);
    try std.testing.expect(syscall_state_after_invoke.dispatch_count > 0);
    try std.testing.expect(syscall_state_after_invoke.last_invoke_tick > 0);
    try std.testing.expectEqual(@as(i64, 0xB866), syscall_state_after_invoke.last_result);
    try std.testing.expectEqual(@as(u64, 1), oc_syscall_entry(0).invoke_count);
    try std.testing.expectEqual(@as(u64, 0x1234), oc_syscall_entry(0).last_arg);
    try std.testing.expectEqual(@as(i64, 0xB866), oc_syscall_entry(0).last_result);

    _ = oc_submit_command(abi.command_syscall_unregister, 7, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_entry_count());
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(0).state);

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
    const timer_state_after_wake = oc_timer_state_ptr().*;
    const timer_entry_after_wake = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u8, 1), timer_state_after_wake.enabled);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expect(timer_state_after_wake.pending_wake_count >= 1);
    try std.testing.expect(timer_state_after_wake.dispatch_count >= 1);
    try std.testing.expect(timer_state_after_wake.last_wake_tick > 0);
    try std.testing.expectEqual(timer_entry.timer_id, timer_entry_after_wake.timer_id);
    try std.testing.expectEqual(task1_id, timer_entry_after_wake.task_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_fired), timer_entry_after_wake.state);
    try std.testing.expect(timer_entry_after_wake.fire_count >= 1);
    try std.testing.expect(timer_entry_after_wake.last_fire_tick > 0);
    try std.testing.expectEqual(timer_entry_after_wake.last_fire_tick, wake0.tick);
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

test "baremetal syscall control commands isolate mutation and invoke paths" {
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

    _ = oc_submit_command(abi.command_syscall_register, 11, 0xBEEF);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_register), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_syscall_entry_count());
    try std.testing.expectEqual(@as(u64, 0xBEEF), oc_syscall_entry(0).handler_token);
    try std.testing.expectEqual(@as(u8, 0), oc_syscall_entry(0).flags);

    _ = oc_submit_command(abi.command_syscall_register, 11, 0xCAFE);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_register), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_syscall_entry_count());
    try std.testing.expectEqual(@as(u64, 0xCAFE), oc_syscall_entry(0).handler_token);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).invoke_count);

    _ = oc_submit_command(abi.command_syscall_set_flags, 11, abi.syscall_entry_flag_blocked);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_set_flags), status.last_command_opcode);
    try std.testing.expectEqual(abi.syscall_entry_flag_blocked, oc_syscall_entry(0).flags);

    _ = oc_submit_command(abi.command_syscall_invoke, 11, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_conflict), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_invoke), status.last_command_opcode);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).invoke_count);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).last_arg);
    try std.testing.expectEqual(@as(i64, 0), oc_syscall_entry(0).last_result);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_state_ptr().last_syscall_id);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_state_ptr().last_invoke_tick);
    try std.testing.expectEqual(@as(i64, 0), oc_syscall_state_ptr().last_result);

    _ = oc_submit_command(abi.command_syscall_disable, 0, 0);
    oc_tick();
    try std.testing.expect(!oc_syscall_enabled());

    _ = oc_submit_command(abi.command_syscall_set_flags, 11, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, 0), oc_syscall_entry(0).flags);

    _ = oc_submit_command(abi.command_syscall_invoke, 11, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_supported), status.last_command_result);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).invoke_count);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).last_arg);
    try std.testing.expectEqual(@as(i64, 0), oc_syscall_entry(0).last_result);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_state_ptr().last_syscall_id);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_state_ptr().last_invoke_tick);
    try std.testing.expectEqual(@as(i64, 0), oc_syscall_state_ptr().last_result);

    _ = oc_submit_command(abi.command_syscall_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_syscall_enabled());
    try std.testing.expectEqual(@as(u16, abi.command_syscall_enable), status.last_command_opcode);

    _ = oc_submit_command(abi.command_syscall_invoke, 11, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_invoke), status.last_command_opcode);
    const invoke_expected: i64 = @as(i64, @bitCast(@as(u64, 0xCAFE ^ 0x1234 ^ 11)));
    try std.testing.expectEqual(@as(u64, 1), oc_syscall_entry(0).invoke_count);
    try std.testing.expectEqual(@as(u64, 0x1234), oc_syscall_entry(0).last_arg);
    try std.testing.expectEqual(invoke_expected, oc_syscall_entry(0).last_result);
    const syscall_state_after_invoke = oc_syscall_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 11), syscall_state_after_invoke.last_syscall_id);
    try std.testing.expectEqual(@as(u64, 1), syscall_state_after_invoke.dispatch_count);
    try std.testing.expect(syscall_state_after_invoke.last_invoke_tick > 0);
    try std.testing.expectEqual(invoke_expected, syscall_state_after_invoke.last_result);

    _ = oc_submit_command(abi.command_syscall_unregister, 11, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_unregister), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_entry_count());
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(0).state);

    _ = oc_submit_command(abi.command_syscall_set_flags, 11, abi.syscall_entry_flag_blocked);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_entry_count());

    _ = oc_submit_command(abi.command_syscall_unregister, 11, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_unregister), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_entry_count());
    try std.testing.expect(oc_syscall_enabled());
    try std.testing.expectEqual(@as(u64, 1), oc_syscall_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 11), oc_syscall_state_ptr().last_syscall_id);
    try std.testing.expectEqual(invoke_expected, oc_syscall_state_ptr().last_result);
    try std.testing.expect(oc_syscall_state_ptr().last_invoke_tick > 0);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(0).state);
    try std.testing.expectEqual(@as(u8, 0), oc_syscall_entry(0).flags);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).invoke_count);
}

test "baremetal syscall table saturates and reuses cleared slots" {
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

    const capacity = oc_syscall_entry_capacity();
    const reuse_slot_index: u32 = 5;
    const reuse_previous_id: u32 = reuse_slot_index + 1;
    const overflow_id: u32 = capacity + 1;
    const reused_id: u32 = capacity + 42;
    const reused_token: u64 = 0xA55A;
    const reused_invoke_arg: u64 = 0x66;

    var index: u32 = 0;
    while (index < capacity) : (index += 1) {
        _ = oc_submit_command(abi.command_syscall_register, index + 1, 0x1000 + index);
        oc_tick();
        try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    }

    try std.testing.expectEqual(capacity, oc_syscall_entry_count());
    try std.testing.expectEqual(capacity, oc_syscall_state_ptr().entry_count);
    try std.testing.expectEqual(capacity, oc_syscall_entry(capacity - 1).syscall_id);
    try std.testing.expectEqual(@as(u64, 0x1000 + (capacity - 1)), oc_syscall_entry(capacity - 1).handler_token);
    try std.testing.expectEqual(reuse_previous_id, oc_syscall_entry(reuse_slot_index).syscall_id);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), oc_syscall_entry(reuse_slot_index).state);

    _ = oc_submit_command(abi.command_syscall_register, overflow_id, 0xDEAD);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_no_space), status.last_command_result);
    try std.testing.expectEqual(capacity, oc_syscall_entry_count());
    try std.testing.expectEqual(reuse_previous_id, oc_syscall_entry(reuse_slot_index).syscall_id);

    _ = oc_submit_command(abi.command_syscall_unregister, reuse_previous_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(capacity - 1, oc_syscall_entry_count());
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(reuse_slot_index).state);

    _ = oc_submit_command(abi.command_syscall_register, reused_id, reused_token);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(capacity, oc_syscall_entry_count());
    const reused_entry = oc_syscall_entry(reuse_slot_index);
    try std.testing.expectEqual(reused_id, reused_entry.syscall_id);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), reused_entry.state);
    try std.testing.expectEqual(reused_token, reused_entry.handler_token);
    try std.testing.expectEqual(@as(u64, 0), reused_entry.invoke_count);
    try std.testing.expectEqual(@as(u8, 0), reused_entry.flags);

    _ = oc_submit_command(abi.command_syscall_invoke, reused_id, reused_invoke_arg);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const invoke_expected: i64 = @as(i64, @bitCast(@as(u64, reused_token ^ reused_invoke_arg ^ reused_id)));
    const reused_entry_after_invoke = oc_syscall_entry(reuse_slot_index);
    try std.testing.expectEqual(@as(u64, 1), reused_entry_after_invoke.invoke_count);
    try std.testing.expectEqual(reused_invoke_arg, reused_entry_after_invoke.last_arg);
    try std.testing.expectEqual(invoke_expected, reused_entry_after_invoke.last_result);
    try std.testing.expectEqual(@as(u32, reused_id), oc_syscall_state_ptr().last_syscall_id);
    try std.testing.expectEqual(@as(u64, 1), oc_syscall_state_ptr().dispatch_count);
    try std.testing.expect(oc_syscall_state_ptr().last_invoke_tick > 0);
    try std.testing.expectEqual(invoke_expected, oc_syscall_state_ptr().last_result);
}

test "baremetal syscall reset clears saturated table and restarts dispatch state" {
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

    const capacity = oc_syscall_entry_capacity();
    var index: u32 = 0;
    while (index < capacity) : (index += 1) {
        _ = oc_submit_command(abi.command_syscall_register, index + 1, 0x2000 + index);
        oc_tick();
        try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    }

    const pre_reset_invoke_id: u32 = 7;
    const pre_reset_invoke_arg: u64 = 0x55;
    _ = oc_submit_command(abi.command_syscall_invoke, pre_reset_invoke_id, pre_reset_invoke_arg);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const pre_reset_expected: i64 = @as(i64, @bitCast(@as(u64, (0x2000 + (pre_reset_invoke_id - 1)) ^ pre_reset_invoke_arg ^ pre_reset_invoke_id)));
    try std.testing.expectEqual(@as(u16, abi.command_syscall_invoke), status.last_command_opcode);
    try std.testing.expectEqual(capacity, oc_syscall_entry_count());
    try std.testing.expectEqual(@as(u64, 1), oc_syscall_state_ptr().dispatch_count);
    try std.testing.expectEqual(pre_reset_invoke_id, oc_syscall_state_ptr().last_syscall_id);
    try std.testing.expectEqual(pre_reset_expected, oc_syscall_state_ptr().last_result);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), oc_syscall_entry(0).state);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), oc_syscall_entry(1).state);

    _ = oc_submit_command(abi.command_syscall_reset, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_reset), status.last_command_opcode);
    try std.testing.expect(oc_syscall_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_entry_count());
    const state_after_reset = oc_syscall_state_ptr().*;
    try std.testing.expectEqual(@as(u64, 0), state_after_reset.dispatch_count);
    try std.testing.expectEqual(@as(u32, 0), state_after_reset.last_syscall_id);
    try std.testing.expectEqual(@as(u64, 0), state_after_reset.last_invoke_tick);
    try std.testing.expectEqual(@as(i64, 0), state_after_reset.last_result);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(0).state);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(1).state);

    const fresh_id: u32 = 777;
    const fresh_token: u64 = 0xD00D;
    const fresh_invoke_arg: u64 = 0x99;
    _ = oc_submit_command(abi.command_syscall_register, fresh_id, fresh_token);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_register), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_syscall_entry_count());
    try std.testing.expectEqual(fresh_id, oc_syscall_entry(0).syscall_id);
    try std.testing.expectEqual(fresh_token, oc_syscall_entry(0).handler_token);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), oc_syscall_entry(0).state);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(1).state);

    _ = oc_submit_command(abi.command_syscall_invoke, fresh_id, fresh_invoke_arg);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_syscall_invoke), status.last_command_opcode);
    const fresh_expected: i64 = @as(i64, @bitCast(@as(u64, fresh_token ^ fresh_invoke_arg ^ fresh_id)));
    try std.testing.expectEqual(@as(u64, 1), oc_syscall_entry(0).invoke_count);
    try std.testing.expectEqual(fresh_invoke_arg, oc_syscall_entry(0).last_arg);
    try std.testing.expectEqual(fresh_expected, oc_syscall_entry(0).last_result);
    try std.testing.expectEqual(@as(u64, 1), oc_syscall_state_ptr().dispatch_count);
    try std.testing.expectEqual(fresh_id, oc_syscall_state_ptr().last_syscall_id);
    try std.testing.expect(oc_syscall_state_ptr().last_invoke_tick > 0);
    try std.testing.expectEqual(fresh_expected, oc_syscall_state_ptr().last_result);
}

test "baremetal allocator and syscall reset commands clear dirty runtime state" {
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
    oc_syscall_reset();
    oc_command_result_counters_clear();
    oc_scheduler_reset();

    _ = oc_submit_command(abi.command_allocator_alloc, 8192, 4096);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const alloc_state_dirty = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), alloc_state_dirty.allocation_count);
    try std.testing.expectEqual(@as(u32, 1), alloc_state_dirty.alloc_ops);
    try std.testing.expectEqual(@as(u64, 8192), alloc_state_dirty.bytes_in_use);
    try std.testing.expectEqual(@as(u64, 8192), alloc_state_dirty.peak_bytes_in_use);
    try std.testing.expect(alloc_state_dirty.last_alloc_ptr != 0);

    _ = oc_submit_command(abi.command_syscall_register, 12, 0xCAFE);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    _ = oc_submit_command(abi.command_syscall_invoke, 12, 0x55AA);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const syscall_state_dirty = oc_syscall_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), syscall_state_dirty.entry_count);
    try std.testing.expect(syscall_state_dirty.dispatch_count > 0);
    try std.testing.expectEqual(@as(u32, 12), syscall_state_dirty.last_syscall_id);
    try std.testing.expect(syscall_state_dirty.last_invoke_tick > 0);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), oc_syscall_entry(0).state);

    _ = oc_submit_command(abi.command_allocator_reset, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const alloc_state_reset = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(alloc_state_reset.total_pages, alloc_state_reset.free_pages);
    try std.testing.expectEqual(@as(u32, 0), alloc_state_reset.allocation_count);
    try std.testing.expectEqual(@as(u32, 0), alloc_state_reset.alloc_ops);
    try std.testing.expectEqual(@as(u32, 0), alloc_state_reset.free_ops);
    try std.testing.expectEqual(@as(u64, 0), alloc_state_reset.bytes_in_use);
    try std.testing.expectEqual(@as(u64, 0), alloc_state_reset.peak_bytes_in_use);
    try std.testing.expectEqual(@as(u64, 0), alloc_state_reset.last_alloc_ptr);
    try std.testing.expectEqual(@as(u64, 0), alloc_state_reset.last_free_ptr);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(0).state);

    _ = oc_submit_command(abi.command_syscall_reset, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const syscall_state_reset = oc_syscall_state_ptr().*;
    try std.testing.expect(oc_syscall_enabled());
    try std.testing.expectEqual(@as(u32, 0), syscall_state_reset.entry_count);
    try std.testing.expectEqual(@as(u32, 0), syscall_state_reset.last_syscall_id);
    try std.testing.expectEqual(@as(u64, 0), syscall_state_reset.dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), syscall_state_reset.last_invoke_tick);
    try std.testing.expectEqual(@as(i64, 0), syscall_state_reset.last_result);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_unused), oc_syscall_entry(0).state);

    _ = oc_submit_command(abi.command_syscall_invoke, 12, 0x55AA);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
}

test "baremetal allocator and syscall failure paths preserve allocator and syscall state" {
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
    oc_syscall_reset();
    oc_scheduler_reset();
    oc_command_result_counters_clear();

    const allocator_initial = oc_allocator_state_ptr().*;
    const invalid_align_size: u64 = allocator_default_page_size;
    const invalid_align: u64 = 3000;
    const valid_align: u64 = allocator_default_page_size;
    const syscall_id: u64 = 9;
    const handler_token: u64 = 0xBEEF;

    _ = oc_submit_command(abi.command_allocator_alloc, invalid_align_size, invalid_align);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_alloc, status.last_command_opcode);
    const state_after_invalid_align = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(allocator_initial.free_pages, state_after_invalid_align.free_pages);
    try std.testing.expectEqual(@as(u32, 0), state_after_invalid_align.allocation_count);
    try std.testing.expectEqual(@as(u64, 0), state_after_invalid_align.bytes_in_use);

    _ = oc_submit_command(abi.command_allocator_alloc, allocator_initial.heap_size + valid_align, valid_align);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_no_space), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_alloc, status.last_command_opcode);
    const state_after_no_space = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(allocator_initial.free_pages, state_after_no_space.free_pages);
    try std.testing.expectEqual(@as(u32, 0), state_after_no_space.allocation_count);
    try std.testing.expectEqual(@as(u64, 0), state_after_no_space.bytes_in_use);

    _ = oc_submit_command(abi.command_syscall_register, syscall_id, handler_token);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_syscall_register, status.last_command_opcode);

    _ = oc_submit_command(abi.command_syscall_set_flags, syscall_id, abi.syscall_entry_flag_blocked);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_syscall_set_flags, status.last_command_opcode);
    try std.testing.expectEqual(abi.syscall_entry_flag_blocked, oc_syscall_entry(0).flags);

    _ = oc_submit_command(abi.command_syscall_invoke, syscall_id, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_conflict), status.last_command_result);
    try std.testing.expectEqual(abi.command_syscall_invoke, status.last_command_opcode);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).invoke_count);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).last_arg);
    try std.testing.expectEqual(@as(i64, 0), oc_syscall_entry(0).last_result);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 0), oc_syscall_state_ptr().last_syscall_id);

    _ = oc_submit_command(abi.command_syscall_disable, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_syscall_disable, status.last_command_opcode);
    try std.testing.expect(!oc_syscall_enabled());

    _ = oc_submit_command(abi.command_syscall_invoke, syscall_id, 0x1234);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_supported), status.last_command_result);
    try std.testing.expectEqual(abi.command_syscall_invoke, status.last_command_opcode);

    const counters = command_result_counters;
    try std.testing.expectEqual(@as(u32, 3), counters.ok_count);
    try std.testing.expectEqual(@as(u32, 1), counters.invalid_argument_count);
    try std.testing.expectEqual(@as(u32, 1), counters.not_supported_count);
    try std.testing.expectEqual(@as(u32, 2), counters.other_error_count);
    try std.testing.expectEqual(@as(u32, 7), counters.total_count);
    try std.testing.expectEqual(@as(i16, abi.result_not_supported), counters.last_result);
    try std.testing.expectEqual(abi.command_syscall_invoke, counters.last_opcode);
    try std.testing.expectEqual(status.command_seq_ack, counters.last_seq);

    const syscall_state_final = oc_syscall_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), syscall_state_final.entry_count);
    try std.testing.expectEqual(@as(u32, 0), syscall_state_final.last_syscall_id);
    try std.testing.expectEqual(@as(u64, 0), syscall_state_final.dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), syscall_state_final.last_invoke_tick);
    try std.testing.expectEqual(@as(i64, 0), syscall_state_final.last_result);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_state_registered), oc_syscall_entry(0).state);
    try std.testing.expectEqual(@as(u8, abi.syscall_entry_flag_blocked), oc_syscall_entry(0).flags);
    try std.testing.expectEqual(handler_token, oc_syscall_entry(0).handler_token);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).invoke_count);
    try std.testing.expectEqual(@as(u64, 0), oc_syscall_entry(0).last_arg);
    try std.testing.expectEqual(@as(i64, 0), oc_syscall_entry(0).last_result);
}

test "baremetal allocator saturation reset command clears full table and restarts cleanly" {
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

    const capacity = oc_allocator_allocation_capacity();
    const alloc_size: u64 = allocator_default_page_size;
    const alloc_alignment: u64 = allocator_default_page_size;
    const fresh_alloc_size: u64 = allocator_default_page_size * 2;

    var idx: u32 = 0;
    while (idx < capacity) : (idx += 1) {
        _ = oc_submit_command(abi.command_allocator_alloc, alloc_size, alloc_alignment);
        oc_tick();
        try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
        const record = oc_allocator_allocation(idx);
        try std.testing.expectEqual(@as(u8, abi.allocation_state_active), record.state);
        try std.testing.expectEqual(allocator_default_heap_base + @as(u64, idx) * allocator_default_page_size, record.ptr);
        try std.testing.expectEqual(alloc_size, record.size_bytes);
        try std.testing.expectEqual(idx, record.page_start);
        try std.testing.expectEqual(@as(u32, 1), record.page_len);
    }

    const saturated_state = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(capacity, oc_allocator_allocation_count());
    try std.testing.expectEqual(saturated_state.total_pages - capacity, saturated_state.free_pages);
    try std.testing.expectEqual(capacity, saturated_state.allocation_count);
    try std.testing.expectEqual(capacity, saturated_state.alloc_ops);
    try std.testing.expectEqual(@as(u32, 0), saturated_state.free_ops);
    try std.testing.expectEqual(@as(u64, capacity) * alloc_size, saturated_state.bytes_in_use);
    try std.testing.expectEqual(@as(u64, capacity) * alloc_size, saturated_state.peak_bytes_in_use);
    try std.testing.expectEqual(allocator_default_heap_base + @as(u64, capacity - 1) * allocator_default_page_size, saturated_state.last_alloc_ptr);
    try std.testing.expectEqual(alloc_size, saturated_state.last_alloc_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), oc_allocator_allocation(0).state);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), oc_allocator_allocation(capacity - 1).state);
    try std.testing.expectEqual(@as(u8, 1), oc_allocator_page_bitmap_ptr().*[0]);
    try std.testing.expectEqual(@as(u8, 1), oc_allocator_page_bitmap_ptr().*[@as(usize, @intCast(capacity - 1))]);
    try std.testing.expectEqual(@as(u8, 0), oc_allocator_page_bitmap_ptr().*[@as(usize, @intCast(capacity))]);

    _ = oc_submit_command(abi.command_allocator_alloc, alloc_size, alloc_alignment);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_no_space), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_alloc, status.last_command_opcode);
    const overflow_state = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(saturated_state.free_pages, overflow_state.free_pages);
    try std.testing.expectEqual(saturated_state.allocation_count, overflow_state.allocation_count);
    try std.testing.expectEqual(saturated_state.alloc_ops, overflow_state.alloc_ops);
    try std.testing.expectEqual(saturated_state.bytes_in_use, overflow_state.bytes_in_use);
    try std.testing.expectEqual(saturated_state.last_alloc_ptr, overflow_state.last_alloc_ptr);

    _ = oc_submit_command(abi.command_allocator_reset, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_reset, status.last_command_opcode);
    const reset_state = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(reset_state.total_pages, reset_state.free_pages);
    try std.testing.expectEqual(@as(u32, 0), reset_state.allocation_count);
    try std.testing.expectEqual(@as(u32, 0), reset_state.alloc_ops);
    try std.testing.expectEqual(@as(u32, 0), reset_state.free_ops);
    try std.testing.expectEqual(@as(u64, 0), reset_state.bytes_in_use);
    try std.testing.expectEqual(@as(u64, 0), reset_state.peak_bytes_in_use);
    try std.testing.expectEqual(@as(u64, 0), reset_state.last_alloc_ptr);
    try std.testing.expectEqual(@as(u64, 0), reset_state.last_alloc_size);
    try std.testing.expectEqual(@as(u64, 0), reset_state.last_free_ptr);
    try std.testing.expectEqual(@as(u64, 0), reset_state.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(0).state);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(1).state);
    try std.testing.expectEqual(@as(u8, 0), oc_allocator_page_bitmap_ptr().*[0]);
    try std.testing.expectEqual(@as(u8, 0), oc_allocator_page_bitmap_ptr().*[63]);

    _ = oc_submit_command(abi.command_allocator_alloc, fresh_alloc_size, alloc_alignment);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_alloc, status.last_command_opcode);
    const fresh_state = oc_allocator_state_ptr().*;
    const fresh_record = oc_allocator_allocation(0);
    try std.testing.expectEqual(@as(u32, 1), fresh_state.allocation_count);
    try std.testing.expectEqual(@as(u32, 1), fresh_state.alloc_ops);
    try std.testing.expectEqual(fresh_alloc_size, fresh_state.bytes_in_use);
    try std.testing.expectEqual(fresh_alloc_size, fresh_state.peak_bytes_in_use);
    try std.testing.expectEqual(allocator_default_heap_base, fresh_state.last_alloc_ptr);
    try std.testing.expectEqual(fresh_alloc_size, fresh_state.last_alloc_size);
    try std.testing.expectEqual(fresh_state.total_pages - 2, fresh_state.free_pages);
    try std.testing.expectEqual(allocator_default_heap_base, fresh_record.ptr);
    try std.testing.expectEqual(fresh_alloc_size, fresh_record.size_bytes);
    try std.testing.expectEqual(@as(u32, 0), fresh_record.page_start);
    try std.testing.expectEqual(@as(u32, 2), fresh_record.page_len);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), fresh_record.state);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(1).state);
}

test "baremetal allocator saturation free reuses record slot and first fit pages" {
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

    const capacity = oc_allocator_allocation_capacity();
    const alloc_size: u64 = allocator_default_page_size;
    const alloc_alignment: u64 = allocator_default_page_size;
    const reuse_slot_index: u32 = 5;
    const fresh_alloc_size: u64 = allocator_default_page_size * 2;

    var idx: u32 = 0;
    while (idx < capacity) : (idx += 1) {
        _ = oc_submit_command(abi.command_allocator_alloc, alloc_size, alloc_alignment);
        oc_tick();
        try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    }

    try std.testing.expectEqual(capacity, oc_allocator_allocation_count());
    _ = oc_submit_command(abi.command_allocator_alloc, alloc_size, alloc_alignment);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_no_space), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_alloc, status.last_command_opcode);

    const reused_before = oc_allocator_allocation(reuse_slot_index);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), reused_before.state);
    const freed_ptr = reused_before.ptr;

    _ = oc_submit_command(abi.command_allocator_free, freed_ptr, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_free, status.last_command_opcode);
    const state_after_free = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(capacity - 1, state_after_free.allocation_count);
    try std.testing.expectEqual(state_after_free.total_pages - (capacity - 1), state_after_free.free_pages);
    try std.testing.expectEqual(capacity, state_after_free.alloc_ops);
    try std.testing.expectEqual(@as(u32, 1), state_after_free.free_ops);
    try std.testing.expectEqual(freed_ptr, state_after_free.last_free_ptr);
    try std.testing.expectEqual(alloc_size, state_after_free.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(reuse_slot_index).state);
    try std.testing.expectEqual(@as(u8, 0), oc_allocator_page_bitmap_ptr().*[@as(usize, @intCast(reuse_slot_index))]);

    _ = oc_submit_command(abi.command_allocator_alloc, fresh_alloc_size, alloc_alignment);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_alloc, status.last_command_opcode);
    const state_after_reuse = oc_allocator_state_ptr().*;
    const reused_after = oc_allocator_allocation(reuse_slot_index);
    try std.testing.expectEqual(capacity, state_after_reuse.allocation_count);
    try std.testing.expectEqual(state_after_reuse.total_pages - (capacity + 1), state_after_reuse.free_pages);
    try std.testing.expectEqual(capacity + 1, state_after_reuse.alloc_ops);
    try std.testing.expectEqual(@as(u32, 1), state_after_reuse.free_ops);
    try std.testing.expectEqual(allocator_default_heap_base + @as(u64, capacity) * allocator_default_page_size, state_after_reuse.last_alloc_ptr);
    try std.testing.expectEqual(fresh_alloc_size, state_after_reuse.last_alloc_size);
    try std.testing.expectEqual((@as(u64, capacity) * alloc_size) - alloc_size + fresh_alloc_size, state_after_reuse.bytes_in_use);
    try std.testing.expectEqual((@as(u64, capacity) * alloc_size) - alloc_size + fresh_alloc_size, state_after_reuse.peak_bytes_in_use);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), reused_after.state);
    try std.testing.expectEqual(allocator_default_heap_base + @as(u64, capacity) * allocator_default_page_size, reused_after.ptr);
    try std.testing.expectEqual(fresh_alloc_size, reused_after.size_bytes);
    try std.testing.expectEqual(capacity, reused_after.page_start);
    try std.testing.expectEqual(@as(u32, 2), reused_after.page_len);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), oc_allocator_allocation(reuse_slot_index + 1).state);
    try std.testing.expectEqual(@as(u8, 0), oc_allocator_page_bitmap_ptr().*[@as(usize, @intCast(reuse_slot_index))]);
    try std.testing.expectEqual(@as(u8, 1), oc_allocator_page_bitmap_ptr().*[@as(usize, @intCast(capacity))]);
    try std.testing.expectEqual(@as(u8, 1), oc_allocator_page_bitmap_ptr().*[@as(usize, @intCast(capacity + 1))]);
}

test "baremetal allocator free command rejects bad pointer size and double free without clobbering state" {
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

    const initial_free = oc_allocator_state_ptr().free_pages;
    const alloc_size: u64 = allocator_default_page_size * 2;
    const alloc_alignment: u64 = allocator_default_page_size;

    _ = oc_submit_command(abi.command_allocator_alloc, alloc_size, alloc_alignment);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const alloc = oc_allocator_allocation(0);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), alloc.state);
    try std.testing.expectEqual(allocator_default_heap_base, alloc.ptr);
    try std.testing.expectEqual(alloc_size, alloc.size_bytes);
    try std.testing.expectEqual(@as(u32, 2), alloc.page_len);

    _ = oc_submit_command(abi.command_allocator_free, alloc.ptr + allocator_default_page_size, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_free, status.last_command_opcode);
    const state_after_bad_ptr = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), state_after_bad_ptr.allocation_count);
    try std.testing.expectEqual(initial_free - 2, state_after_bad_ptr.free_pages);
    try std.testing.expectEqual(@as(u64, 0), state_after_bad_ptr.last_free_ptr);
    try std.testing.expectEqual(@as(u64, 0), state_after_bad_ptr.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), oc_allocator_allocation(0).state);

    _ = oc_submit_command(abi.command_allocator_free, alloc.ptr, allocator_default_page_size);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_free, status.last_command_opcode);
    const state_after_bad_size = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), state_after_bad_size.allocation_count);
    try std.testing.expectEqual(initial_free - 2, state_after_bad_size.free_pages);
    try std.testing.expectEqual(@as(u64, 0), state_after_bad_size.last_free_ptr);
    try std.testing.expectEqual(@as(u64, 0), state_after_bad_size.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), oc_allocator_allocation(0).state);

    _ = oc_submit_command(abi.command_allocator_free, alloc.ptr, alloc_size);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_free, status.last_command_opcode);
    const state_after_free = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 0), state_after_free.allocation_count);
    try std.testing.expectEqual(initial_free, state_after_free.free_pages);
    try std.testing.expectEqual(alloc.ptr, state_after_free.last_free_ptr);
    try std.testing.expectEqual(alloc_size, state_after_free.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(0).state);

    _ = oc_submit_command(abi.command_allocator_free, alloc.ptr, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_free, status.last_command_opcode);
    const state_after_double_free = oc_allocator_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 0), state_after_double_free.allocation_count);
    try std.testing.expectEqual(initial_free, state_after_double_free.free_pages);
    try std.testing.expectEqual(alloc.ptr, state_after_double_free.last_free_ptr);
    try std.testing.expectEqual(alloc_size, state_after_double_free.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_unused), oc_allocator_allocation(0).state);

    _ = oc_submit_command(abi.command_allocator_alloc, allocator_default_page_size, alloc_alignment);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.command_allocator_alloc, status.last_command_opcode);
    const state_after_realloc = oc_allocator_state_ptr().*;
    const realloc = oc_allocator_allocation(0);
    try std.testing.expectEqual(@as(u32, 1), state_after_realloc.allocation_count);
    try std.testing.expectEqual(initial_free - 1, state_after_realloc.free_pages);
    try std.testing.expectEqual(allocator_default_heap_base, state_after_realloc.last_alloc_ptr);
    try std.testing.expectEqual(allocator_default_page_size, state_after_realloc.last_alloc_size);
    try std.testing.expectEqual(alloc.ptr, state_after_realloc.last_free_ptr);
    try std.testing.expectEqual(alloc_size, state_after_realloc.last_free_size);
    try std.testing.expectEqual(@as(u8, abi.allocation_state_active), realloc.state);
    try std.testing.expectEqual(allocator_default_heap_base, realloc.ptr);
    try std.testing.expectEqual(@as(u32, 0), realloc.page_start);
    try std.testing.expectEqual(@as(u32, 1), realloc.page_len);
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
    try std.testing.expectEqual(@as(u16, abi.command_scheduler_disable), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_timer_set_quantum, 2, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_timer_set_quantum), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_quantum());

    _ = oc_submit_command(abi.command_task_create, 8, 1);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_task_create), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_task_count());
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_task(0).priority);
    try std.testing.expectEqual(@as(u32, 8), oc_scheduler_task(0).budget_ticks);
    try std.testing.expectEqual(@as(u32, 8), oc_scheduler_task(0).budget_remaining);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task(0).run_count);

    _ = oc_submit_command(abi.command_timer_schedule_periodic, task_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_timer_schedule_periodic), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    var entry = oc_timer_entry(0);
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u8, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, abi.timer_entry_flag_periodic), entry.flags & abi.timer_entry_flag_periodic);
    try std.testing.expectEqual(@as(u32, 2), entry.period_ticks);
    try std.testing.expectEqual(task_id, entry.task_id);
    try std.testing.expectEqual(@as(u32, 1), entry.timer_id);

    var spin: u8 = 0;
    while (oc_timer_entry(0).fire_count == 0 and spin < 8) : (spin += 1) {
        oc_tick();
    }
    entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), entry.state);
    try std.testing.expectEqual(@as(u64, 1), entry.fire_count);
    try std.testing.expect(entry.last_fire_tick > 0);
    try std.testing.expect(entry.next_fire_tick > entry.last_fire_tick);
    try std.testing.expect(entry.next_fire_tick <= entry.last_fire_tick + entry.period_ticks);
    const first_fire_tick = entry.last_fire_tick;
    try std.testing.expect(oc_wake_queue_len() >= 1);
    try std.testing.expectEqual(@as(u32, 1), timer_state.pending_wake_count);
    try std.testing.expectEqual(@as(u64, 1), timer_state.dispatch_count);
    try std.testing.expectEqual(entry.last_fire_tick, timer_state.last_wake_tick);

    _ = oc_submit_command(abi.command_timer_disable, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_timer_disable), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    const wakes_before_pause = oc_wake_queue_len();
    const fires_before_pause = entry.fire_count;
    const dispatch_before_pause = timer_state.dispatch_count;
    const last_fire_before_pause = entry.last_fire_tick;
    oc_tick();
    oc_tick();
    try std.testing.expectEqual(wakes_before_pause, oc_wake_queue_len());
    try std.testing.expectEqual(fires_before_pause, oc_timer_entry(0).fire_count);
    try std.testing.expectEqual(dispatch_before_pause, timer_state.dispatch_count);
    try std.testing.expectEqual(last_fire_before_pause, oc_timer_entry(0).last_fire_tick);
    try std.testing.expect(!oc_timer_enabled());

    _ = oc_submit_command(abi.command_timer_enable, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_timer_enable), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(oc_timer_enabled());
    spin = 0;
    while (oc_timer_entry(0).fire_count < 2 and spin < 8) : (spin += 1) {
        oc_tick();
    }
    entry = oc_timer_entry(0);
    try std.testing.expect(entry.fire_count >= 2);
    try std.testing.expectEqual(@as(u64, 2), entry.fire_count);
    try std.testing.expect(entry.last_fire_tick > last_fire_before_pause);
    try std.testing.expect(entry.next_fire_tick > entry.last_fire_tick);
    try std.testing.expect(entry.next_fire_tick <= entry.last_fire_tick + entry.period_ticks);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), timer_state.pending_wake_count);
    try std.testing.expectEqual(@as(u64, 2), timer_state.dispatch_count);
    try std.testing.expectEqual(entry.last_fire_tick, timer_state.last_wake_tick);
    const wake0 = oc_wake_queue_event(0);
    const wake1 = oc_wake_queue_event(1);
    try std.testing.expectEqual(@as(u32, 1), wake0.seq);
    try std.testing.expectEqual(task_id, wake0.task_id);
    try std.testing.expectEqual(@as(u32, 1), wake0.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), wake0.reason);
    try std.testing.expectEqual(@as(u8, 0), wake0.vector);
    try std.testing.expectEqual(first_fire_tick, wake0.tick);
    try std.testing.expectEqual(@as(u32, 2), wake1.seq);
    try std.testing.expectEqual(task_id, wake1.task_id);
    try std.testing.expectEqual(@as(u32, 1), wake1.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), wake1.reason);
    try std.testing.expectEqual(@as(u8, 0), wake1.vector);
    try std.testing.expectEqual(entry.last_fire_tick, wake1.tick);
}

test "baremetal periodic timer clamps near max tick without wraparound" {
    resetBaremetalRuntimeForTest();

    const near_max_tick = std.math.maxInt(u64) - 1;
    const max_tick = std.math.maxInt(u64);

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 8, 1);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());

    status.ticks = near_max_tick;
    _ = oc_submit_command(abi.command_timer_schedule_periodic, task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(max_tick, status.ticks);

    var entry = oc_timer_entry(0);
    try std.testing.expectEqual(task_id, entry.task_id);
    try std.testing.expectEqual(@as(u32, 1), entry.timer_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), entry.state);
    try std.testing.expectEqual(@as(u16, abi.timer_entry_flag_periodic), entry.flags & abi.timer_entry_flag_periodic);
    try std.testing.expectEqual(@as(u32, 10), entry.period_ticks);
    try std.testing.expectEqual(max_tick, entry.next_fire_tick);
    try std.testing.expectEqual(@as(u64, 0), entry.fire_count);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    oc_tick();
    try std.testing.expectEqual(@as(u64, 0), status.ticks);
    entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u64, 1), entry.fire_count);
    try std.testing.expectEqual(max_tick, entry.last_fire_tick);
    try std.testing.expectEqual(max_tick, entry.next_fire_tick);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), entry.state);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());

    const wake0 = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 1), wake0.seq);
    try std.testing.expectEqual(task_id, wake0.task_id);
    try std.testing.expectEqual(@as(u32, 1), wake0.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), wake0.reason);
    try std.testing.expectEqual(@as(u8, 0), wake0.vector);
    try std.testing.expectEqual(max_tick, wake0.tick);

    oc_tick();
    try std.testing.expectEqual(@as(u64, 1), status.ticks);
    entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u64, 1), entry.fire_count);
    try std.testing.expectEqual(max_tick, entry.next_fire_tick);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
}

test "baremetal periodic interrupt flow preserves cadence and cancels cleanly" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_timer_set_quantum, 2, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_create, 8, 1);
    oc_tick();
    const periodic_task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(periodic_task_id != 0);

    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const interrupt_task_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(interrupt_task_id != 0);

    _ = oc_submit_command(abi.command_timer_schedule_periodic, periodic_task_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    var periodic_entry = oc_timer_entry(0);
    try std.testing.expectEqual(periodic_task_id, periodic_entry.task_id);
    try std.testing.expectEqual(@as(u32, 1), periodic_entry.timer_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), periodic_entry.state);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), periodic_entry.reason);
    try std.testing.expectEqual(@as(u16, abi.timer_entry_flag_periodic), periodic_entry.flags & abi.timer_entry_flag_periodic);
    try std.testing.expectEqual(@as(u32, 2), periodic_entry.period_ticks);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, interrupt_task_id, 6);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());

    oc_tick_n(2);
    periodic_entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u64, 1), periodic_entry.fire_count);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), periodic_entry.state);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const wake0 = oc_wake_queue_event(0);
    try std.testing.expectEqual(periodic_task_id, wake0.task_id);
    try std.testing.expectEqual(@as(u32, 1), wake0.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), wake0.reason);
    try std.testing.expectEqual(@as(u8, 0), wake0.vector);
    try std.testing.expectEqual(periodic_entry.last_fire_tick, wake0.tick);

    _ = oc_submit_command(abi.command_trigger_interrupt, 31, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    const wake1 = oc_wake_queue_event(1);
    try std.testing.expectEqual(interrupt_task_id, wake1.task_id);
    try std.testing.expectEqual(@as(u32, 0), wake1.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), wake1.reason);
    try std.testing.expectEqual(@as(u8, 31), wake1.vector);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 31), x86_bootstrap.oc_last_interrupt_vector());

    oc_tick();
    periodic_entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 2), periodic_entry.fire_count);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), periodic_entry.state);
    try std.testing.expect(periodic_entry.next_fire_tick > periodic_entry.last_fire_tick);
    const wake2 = oc_wake_queue_event(2);
    try std.testing.expectEqual(periodic_task_id, wake2.task_id);
    try std.testing.expectEqual(@as(u32, 1), wake2.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), wake2.reason);
    try std.testing.expectEqual(@as(u8, 0), wake2.vector);
    try std.testing.expectEqual(periodic_entry.last_fire_tick, wake2.tick);
    try std.testing.expect(wake0.tick < wake1.tick);
    try std.testing.expect(wake1.tick <= wake2.tick);

    _ = oc_submit_command(abi.command_timer_cancel_task, periodic_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    periodic_entry = oc_timer_entry(0);
    try std.testing.expectEqual(periodic_task_id, periodic_entry.task_id);
    try std.testing.expectEqual(@as(u32, 1), periodic_entry.timer_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), periodic_entry.state);
    try std.testing.expectEqual(@as(u64, 2), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().last_interrupt_count);

    const wake_count_after_cancel = oc_wake_queue_len();
    oc_tick_n(10);
    try std.testing.expectEqual(wake_count_after_cancel, oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 31), x86_bootstrap.oc_last_interrupt_vector());
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
    _ = oc_submit_command(abi.command_task_create, 9, 2);
    oc_tick();
    var task = oc_scheduler_task(0);
    const task_id = task.task_id;
    try std.testing.expect(task_id != 0);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
    try std.testing.expectEqual(@as(u8, 2), task.priority);
    try std.testing.expectEqual(@as(u32, 9), task.budget_ticks);
    try std.testing.expectEqual(@as(u32, 9), task.budget_remaining);
    try std.testing.expectEqual(@as(u32, 0), task.run_count);

    _ = oc_submit_command(abi.command_timer_set_quantum, 3, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_timer_set_quantum), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 3), oc_timer_quantum());

    _ = oc_submit_command(abi.command_timer_schedule, task_id, 1);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_timer_schedule), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    var timer_entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u32, 1), timer_entry.timer_id);
    try std.testing.expectEqual(task_id, timer_entry.task_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), timer_entry.state);
    try std.testing.expectEqual(status.ticks, timer_entry.next_fire_tick);
    const quantum: u64 = @as(u64, oc_timer_quantum());
    const expected_boundary_tick = ((timer_entry.next_fire_tick / quantum) + 1) * quantum;

    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), task.state);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), task.state);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
    const wake = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 1), wake.seq);
    try std.testing.expectEqual(task_id, wake.task_id);
    try std.testing.expectEqual(@as(u32, 1), wake.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), wake.reason);
    try std.testing.expectEqual(@as(u8, 0), wake.vector);
    try std.testing.expectEqual(expected_boundary_tick, wake.tick);
    timer_entry = oc_timer_entry(0);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_fired), timer_entry.state);
    try std.testing.expectEqual(@as(u64, 1), timer_entry.fire_count);
    try std.testing.expectEqual(expected_boundary_tick, timer_entry.last_fire_tick);
}

test "baremetal task lifecycle commands control runnable state wake queue and post-terminate rejection" {
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
    try std.testing.expectEqual(@as(u16, abi.command_task_wait), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());

    _ = oc_submit_command(abi.command_scheduler_wake_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_scheduler_wake_task), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    var evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);

    _ = oc_submit_command(abi.command_task_wait, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_wait), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_task_resume, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_resume), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    evt = oc_wake_queue_event(1);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);

    _ = oc_submit_command(abi.command_task_terminate, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_terminate), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_scheduler_wake_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_scheduler_wake_task), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), oc_scheduler_task(0).state);
}

test "baremetal task resume clears timer-backed wait and prevents stale wake" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_timer_set_quantum, 5, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_wait_for, task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_task_resume, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), oc_timer_entry(0).state);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u32, 0), evt.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);

    oc_tick_n(20);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);

    _ = oc_submit_command(abi.command_task_wait_for, task_id, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 2), oc_timer_entry(0).timer_id);
    try std.testing.expectEqual(@as(u32, 3), oc_timer_state_ptr().next_timer_id);
}

test "baremetal scheduler wake clears timer-backed wait and prevents stale wake" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_timer_set_quantum, 5, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_wait_for, task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_scheduler_wake_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), oc_timer_entry(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);

    oc_tick_n(20);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 5), oc_timer_state_ptr().tick_quantum);

    _ = oc_submit_command(abi.command_task_wait_for, task_id, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 2), oc_timer_entry(0).timer_id);
    try std.testing.expectEqual(@as(u32, 3), oc_timer_state_ptr().next_timer_id);
}

test "baremetal task resume clears interrupt-timeout wait and prevents stale timeout wake" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expect(scheduler_wait_timeout_tick[0] > status.ticks);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_task_resume, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);
    try std.testing.expectEqual(@as(u32, 0), evt.timer_id);

    oc_tick_n(20);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expect(scheduler_wait_timeout_tick[0] > status.ticks);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
}

test "baremetal timer cancel task clears interrupt-timeout wait and prevents stale timeout wake" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expect(scheduler_wait_timeout_tick[0] > status.ticks);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());

    _ = oc_submit_command(abi.command_timer_cancel_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().last_wake_tick);
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    oc_tick_n(20);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().last_wake_tick);
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), evt.reason);
    try std.testing.expectEqual(@as(u8, 200), evt.vector);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);
    try std.testing.expectEqual(@as(u16, 200), x86_bootstrap.oc_last_interrupt_vector());
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
    try std.testing.expectEqual(@as(u8, abi.command_task_create), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_task_count());
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_task(0).priority);
    try std.testing.expectEqual(@as(u32, 7), oc_scheduler_task(0).budget_ticks);
    try std.testing.expectEqual(@as(u32, 7), oc_scheduler_task(0).budget_remaining);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task(0).run_count);

    _ = oc_submit_command(abi.command_timer_schedule, task_id, 10);
    oc_tick();
    _ = oc_submit_command(abi.command_timer_schedule_periodic, task_id, 20);
    oc_tick();
    try std.testing.expectEqual(@as(u8, abi.command_timer_schedule_periodic), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry(0).timer_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), oc_timer_entry(0).state);
    try std.testing.expectEqual(task_id, oc_timer_entry(0).task_id);
    try std.testing.expect(oc_timer_entry(0).next_fire_tick > status.ticks);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry(0).fire_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_entry(0).last_fire_tick);

    _ = oc_submit_command(abi.command_timer_cancel_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u8, abi.command_timer_cancel_task), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), oc_timer_entry(0).state);
    try std.testing.expectEqual(task_id, oc_timer_entry(0).task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);

    _ = oc_submit_command(abi.command_timer_cancel_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u8, abi.command_timer_cancel_task), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), oc_timer_entry(0).state);
    try std.testing.expectEqual(task_id, oc_timer_entry(0).task_id);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
}

test "baremetal timer disable suppresses timer wake but not interrupt wake" {
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
    const interrupt_task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(interrupt_task_id != 0);

    _ = oc_submit_command(abi.command_task_create, 6, 0);
    oc_tick();
    const timer_task_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(timer_task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt, interrupt_task_id, abi.wait_interrupt_any_vector);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_wait_for, timer_task_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());

    _ = oc_submit_command(abi.command_timer_disable, 0, 0);
    oc_tick();
    try std.testing.expect(!oc_timer_enabled());

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const interrupt_evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(interrupt_task_id, interrupt_evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), interrupt_evt.reason);
    try std.testing.expectEqual(@as(u8, 200), interrupt_evt.vector);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, 1), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 200), x86_bootstrap.oc_last_interrupt_vector());

    oc_tick_n(4);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, 1), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expect(status.ticks > oc_timer_entry(0).next_fire_tick);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 200), x86_bootstrap.oc_last_interrupt_vector());

    _ = oc_submit_command(abi.command_timer_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, 2), oc_timer_state_ptr().pending_wake_count);
    const timer_evt = oc_wake_queue_event(1);
    const timer_entry = oc_timer_entry(0);
    try std.testing.expectEqual(timer_task_id, timer_evt.task_id);
    try std.testing.expectEqual(timer_entry.timer_id, timer_evt.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), timer_evt.reason);
    try std.testing.expectEqual(@as(u8, 0), timer_evt.vector);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(1).state);
    try std.testing.expect(oc_timer_state_ptr().dispatch_count >= 1);
    try std.testing.expectEqual(interrupt_evt.interrupt_count, timer_evt.interrupt_count);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 200), x86_bootstrap.oc_last_interrupt_vector());
}

test "baremetal timer disable and re-enable resumes overdue one-shot wake" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 6, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_for, task_id, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    const armed_tick = oc_timer_entry(0).next_fire_tick;

    _ = oc_submit_command(abi.command_timer_disable, 0, 0);
    oc_tick();
    try std.testing.expect(!oc_timer_enabled());

    oc_tick_n(4);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expect(oc_timer_entry(0).next_fire_tick == armed_tick);
    try std.testing.expect(status.ticks > armed_tick);

    _ = oc_submit_command(abi.command_timer_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().dispatch_count);
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), evt.reason);
    try std.testing.expect(evt.tick > armed_tick);
}

test "baremetal timer pressure reuses canceled slot with fresh timer id" {
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

    const task_capacity_u32: u32 = @as(u32, @intCast(scheduler_task_capacity));
    var idx: usize = 0;
    while (idx < scheduler_task_capacity) : (idx += 1) {
        _ = oc_submit_command(abi.command_task_create, 4 + @as(u64, idx), @as(u64, idx + 1));
        oc_tick();
        try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

        const task_id = oc_scheduler_task(@as(u32, @intCast(idx))).task_id;
        try std.testing.expect(task_id != 0);

        _ = oc_submit_command(abi.command_timer_schedule, task_id, 40 + @as(u64, idx));
        oc_tick();
        try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    }

    try std.testing.expectEqual(task_capacity_u32, oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, scheduler_task_capacity + 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    idx = 0;
    while (idx < scheduler_task_capacity) : (idx += 1) {
        const task = oc_scheduler_task(@as(u32, @intCast(idx)));
        const entry = oc_timer_entry(@as(u32, @intCast(idx)));
        try std.testing.expectEqual(task.task_id, entry.task_id);
        try std.testing.expectEqual(@as(u32, @intCast(idx + 1)), entry.timer_id);
        try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), entry.state);
        try std.testing.expect(entry.next_fire_tick > status.ticks);
    }

    const reuse_slot_index: u32 = 5;
    const reuse_task_id = oc_scheduler_task(reuse_slot_index).task_id;
    const reuse_old_entry = oc_timer_entry(reuse_slot_index);
    try std.testing.expect(reuse_task_id != 0);

    _ = oc_submit_command(abi.command_timer_cancel_task, reuse_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(task_capacity_u32 - 1, oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, scheduler_task_capacity + 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(reuse_slot_index).state);

    const canceled_entry = oc_timer_entry(reuse_slot_index);
    try std.testing.expectEqual(reuse_task_id, canceled_entry.task_id);
    try std.testing.expectEqual(reuse_old_entry.timer_id, canceled_entry.timer_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), canceled_entry.state);

    _ = oc_submit_command(abi.command_timer_schedule, reuse_task_id, 200);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(task_capacity_u32, oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, scheduler_task_capacity + 2), oc_timer_state_ptr().next_timer_id);

    const reused_entry = oc_timer_entry(reuse_slot_index);
    try std.testing.expectEqual(reuse_task_id, reused_entry.task_id);
    try std.testing.expectEqual(@as(u32, scheduler_task_capacity + 1), reused_entry.timer_id);
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_armed), reused_entry.state);
    try std.testing.expect(reused_entry.next_fire_tick > status.ticks);
}

test "baremetal timer reset clears timer entries and timer-backed waits" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();

    _ = oc_submit_command(abi.command_task_create, 6, 0);
    oc_tick();
    const timer_task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(timer_task_id != 0);

    _ = oc_submit_command(abi.command_task_create, 7, 1);
    oc_tick();
    const interrupt_task_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(interrupt_task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_for, timer_task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, interrupt_task_id, 20);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_timer_set_quantum, 5, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    _ = oc_submit_command(abi.command_timer_disable, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    try std.testing.expect(!oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 5), oc_timer_quantum());

    _ = oc_submit_command(abi.command_timer_reset, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().last_wake_tick);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_quantum());
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u8, wait_condition_manual), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[1]);

    oc_tick_n(25);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u8, wait_condition_manual), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[1]);

    _ = oc_submit_command(abi.command_scheduler_wake_task, timer_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const manual_evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(timer_task_id, manual_evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), manual_evt.reason);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);

    _ = oc_submit_command(abi.command_trigger_interrupt, 31, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    const interrupt_evt = oc_wake_queue_event(1);
    try std.testing.expectEqual(interrupt_task_id, interrupt_evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), interrupt_evt.reason);
    try std.testing.expectEqual(@as(u8, 31), interrupt_evt.vector);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[1]);

    _ = oc_submit_command(abi.command_task_wait_for, timer_task_id, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry(0).timer_id);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_timer), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expect(oc_timer_entry(0).next_fire_tick > status.ticks);
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
    try std.testing.expectEqual(task_id, first_before.task_id);
    try std.testing.expectEqual(task_id, second_before.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), first_before.reason);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), second_before.reason);
    try std.testing.expect(second_before.seq > first_before.seq);
    try std.testing.expect(second_before.tick > first_before.tick);

    _ = oc_submit_command(abi.command_wake_queue_pop, 1, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const first_after = oc_wake_queue_event(0);
    try std.testing.expectEqual(second_before.seq, first_after.seq);
    try std.testing.expectEqual(second_before.task_id, first_after.task_id);
    try std.testing.expectEqual(second_before.reason, first_after.reason);
    try std.testing.expectEqual(second_before.tick, first_after.tick);

    _ = oc_submit_command(abi.command_wake_queue_pop, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_wake_queue_pop, 1, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_wake_queue_pop), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
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
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_tail_index());

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

test "baremetal wake queue clear command resets wrapped queue and reuse" {
    resetBaremetalRuntimeForTest();

    const cap = oc_wake_queue_capacity();
    var idx: u32 = 0;
    while (idx < cap + 2) : (idx += 1) {
        wakeQueuePush(5500 + idx, 0, abi.wake_reason_manual, 0, 500 + idx, 0);
    }

    try std.testing.expectEqual(cap, oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_tail_index());

    _ = oc_submit_command(abi.command_wake_queue_clear, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_overflow_count());
    const cleared = oc_wake_queue_summary();
    try std.testing.expectEqual(@as(u32, 0), cleared.len);
    try std.testing.expectEqual(@as(u32, 0), cleared.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), cleared.reason_manual_count);
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);

    wakeQueuePush(6600, 0, abi.wake_reason_manual, 0, 900, 0);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u16, 1), oc_timer_state_ptr().pending_wake_count);
    const reused = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 1), reused.seq);
    try std.testing.expectEqual(@as(u32, 6600), reused.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), reused.reason);
    try std.testing.expectEqual(@as(u64, 900), reused.tick);
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
    try std.testing.expectEqual(@as(u16, abi.command_wake_queue_pop), status.last_command_opcode);
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
    const after_batch = oc_wake_queue_summary();
    try std.testing.expectEqual(@as(u32, 2), after_batch.len);
    try std.testing.expectEqual(@as(u32, 2), after_batch.overflow_count);
    try std.testing.expectEqual(@as(u32, 2), after_batch.reason_manual_count);

    _ = oc_submit_command(abi.command_wake_queue_pop, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_wake_queue_pop), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    const final_survivor = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 66), final_survivor.seq);
    try std.testing.expectEqual(@as(u32, 6065), final_survivor.task_id);
    try std.testing.expectEqual(@as(u64, 265), final_survivor.tick);

    _ = oc_submit_command(abi.command_wake_queue_pop, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_wake_queue_pop), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    const drained = oc_wake_queue_summary();
    try std.testing.expectEqual(@as(u32, 0), drained.len);
    try std.testing.expectEqual(@as(u32, 2), drained.overflow_count);
    try std.testing.expectEqual(@as(u32, 0), drained.reason_manual_count);

    wakeQueuePush(7000, 0, abi.wake_reason_manual, 0, 300, 0);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    const reused = oc_wake_queue_event(0);
    try std.testing.expectEqual(@as(u32, 67), reused.seq);
    try std.testing.expectEqual(@as(u32, 7000), reused.task_id);
    try std.testing.expectEqual(@as(u64, 300), reused.tick);
    const reused_summary = oc_wake_queue_summary();
    try std.testing.expectEqual(@as(u32, 1), reused_summary.len);
    try std.testing.expectEqual(@as(u32, 2), reused_summary.overflow_count);
    try std.testing.expectEqual(@as(u32, 1), reused_summary.reason_manual_count);
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
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 31));

    _ = oc_submit_command(abi.command_wake_queue_pop_vector, 13, 31);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_vector_count(31));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 31));
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
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 31));
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
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_manual, 0));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_manual, 31);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 33), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_count(abi.wake_reason_manual));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_count(abi.wake_reason_interrupt));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_vector_count(abi.wake_reason_manual, 0));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
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
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_vector_count(abi.wake_reason_manual, 0));
    try std.testing.expectEqual(@as(u32, 32), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
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
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_head_index());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_tail_index());
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_overflow_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_before_tick_count(565));
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
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_count(abi.wake_reason_interrupt));
    try std.testing.expectEqual(@as(u32, 1001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 1004), oc_wake_queue_event(1).task_id);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_interrupt, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 1004), oc_wake_queue_event(1).task_id);
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
    try std.testing.expectEqual(@as(u32, 2001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_vector_count(13));
    try std.testing.expectEqual(@as(u8, 0), oc_wake_queue_event(0).vector);
    try std.testing.expectEqual(@as(u32, 2003), oc_wake_queue_event(1).task_id);
    try std.testing.expectEqual(@as(u8, 13), oc_wake_queue_event(1).vector);
    try std.testing.expectEqual(@as(u32, 2004), oc_wake_queue_event(2).task_id);
    try std.testing.expectEqual(@as(u8, 31), oc_wake_queue_event(2).vector);

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
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 2001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u8, 0), oc_wake_queue_event(0).vector);
    try std.testing.expectEqual(@as(u32, 2004), oc_wake_queue_event(1).task_id);
    try std.testing.expectEqual(@as(u8, 31), oc_wake_queue_event(1).vector);
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
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 3004), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), oc_wake_queue_event(0).reason);
    try std.testing.expectEqual(@as(u8, 0), oc_wake_queue_event(0).vector);
    try std.testing.expectEqual(@as(u64, 40), oc_wake_queue_event(0).tick);
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
    try std.testing.expectEqual(@as(u32, 0), summary_after.reason_manual_count);
    try std.testing.expectEqual(@as(u32, 2), summary_after.nonzero_vector_count);
    try std.testing.expectEqual(@as(u32, 2), summary_after.stale_count);
    try std.testing.expectEqual(@as(u64, 12), summary_after.oldest_tick);
    try std.testing.expectEqual(@as(u64, 13), summary_after.newest_tick);
    const summary_snapshot_after = oc_wake_queue_summary_ptr().*;
    try std.testing.expectEqual(summary_after, summary_snapshot_after);
    const buckets_after = oc_wake_queue_age_buckets(2);
    try std.testing.expectEqual(@as(u64, 14), buckets_after.current_tick);
    try std.testing.expectEqual(@as(u64, 2), buckets_after.quantum_ticks);
    try std.testing.expectEqual(@as(u32, 2), buckets_after.stale_count);
    try std.testing.expectEqual(@as(u32, 1), buckets_after.stale_older_than_quantum_count);
    try std.testing.expectEqual(@as(u32, 0), buckets_after.future_count);
    const age_bucket_snapshot_after = oc_wake_queue_age_buckets_ptr(2).*;
    try std.testing.expectEqual(buckets_after, age_bucket_snapshot_after);
    const age_bucket_snapshot_after_quantum_2 = oc_wake_queue_age_buckets_ptr_quantum_2().*;
    try std.testing.expectEqual(buckets_after, age_bucket_snapshot_after_quantum_2);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason_vector, 0, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 13));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_vector_count(abi.wake_reason_interrupt, 19));
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_reason_vector_count(abi.wake_reason_timer, 13));
    try std.testing.expectEqual(@as(u32, 4003), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), oc_wake_queue_event(0).reason);
    try std.testing.expectEqual(@as(u8, 19), oc_wake_queue_event(0).vector);
    try std.testing.expectEqual(@as(u32, 4004), oc_wake_queue_event(1).task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), oc_wake_queue_event(1).reason);
    try std.testing.expectEqual(@as(u8, 13), oc_wake_queue_event(1).vector);
    try std.testing.expectEqual(summary_after, oc_wake_queue_summary());
    const buckets_after_invalid = oc_wake_queue_age_buckets(2);
    try std.testing.expectEqual(@as(u64, 15), buckets_after_invalid.current_tick);
    try std.testing.expectEqual(@as(u64, 2), buckets_after_invalid.quantum_ticks);
    try std.testing.expectEqual(@as(u32, 2), buckets_after_invalid.stale_count);
    try std.testing.expectEqual(@as(u32, 2), buckets_after_invalid.stale_older_than_quantum_count);
    try std.testing.expectEqual(@as(u32, 0), buckets_after_invalid.future_count);
}

test "baremetal wake queue count snapshot ptr reflects live query" {
    resetBaremetalRuntimeForTest();

    wakeQueuePush(5001, 51, abi.wake_reason_timer, 0, 10, 0);
    wakeQueuePush(5002, 52, abi.wake_reason_interrupt, 13, 20, 5);
    wakeQueuePush(5003, 53, abi.wake_reason_interrupt, 13, 30, 6);
    wakeQueuePush(5004, 54, abi.wake_reason_interrupt, 31, 40, 7);
    wakeQueuePush(5005, 55, abi.wake_reason_manual, 0, 50, 8);

    const query = oc_wake_queue_count_query_ptr();
    query.* = .{
        .vector = 13,
        .reason = abi.wake_reason_interrupt,
        .reserved0 = 0,
        .reserved1 = 0,
        .max_tick = 20,
    };
    const first_snapshot = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 2), first_snapshot.vector_count);
    try std.testing.expectEqual(@as(u32, 2), first_snapshot.before_tick_count);
    try std.testing.expectEqual(@as(u32, 2), first_snapshot.reason_vector_count);

    query.vector = 31;
    query.max_tick = 40;
    const second_snapshot = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), second_snapshot.vector_count);
    try std.testing.expectEqual(@as(u32, 4), second_snapshot.before_tick_count);
    try std.testing.expectEqual(@as(u32, 1), second_snapshot.reason_vector_count);

    query.reason = abi.wake_reason_manual;
    query.max_tick = 55;
    const third_snapshot = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), third_snapshot.vector_count);
    try std.testing.expectEqual(@as(u32, 5), third_snapshot.before_tick_count);
    try std.testing.expectEqual(@as(u32, 0), third_snapshot.reason_vector_count);
}

test "baremetal wake queue count snapshot ptr stays live across queue mutations" {
    resetBaremetalRuntimeForTest();

    wakeQueuePush(5101, 61, abi.wake_reason_timer, 0, 10, 0);
    wakeQueuePush(5102, 62, abi.wake_reason_interrupt, 13, 20, 5);
    wakeQueuePush(5103, 63, abi.wake_reason_interrupt, 13, 30, 6);
    wakeQueuePush(5104, 64, abi.wake_reason_interrupt, 31, 40, 7);
    wakeQueuePush(5105, 65, abi.wake_reason_manual, 0, 50, 8);

    const query = oc_wake_queue_count_query_ptr();
    query.* = .{
        .vector = 13,
        .reason = abi.wake_reason_interrupt,
        .reserved0 = 0,
        .reserved1 = 0,
        .max_tick = 40,
    };
    const before = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 2), before.vector_count);
    try std.testing.expectEqual(@as(u32, 4), before.before_tick_count);
    try std.testing.expectEqual(@as(u32, 2), before.reason_vector_count);

    try std.testing.expect(wakeQueuePopReason(abi.wake_reason_interrupt, 1));
    const after_reason = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), after_reason.vector_count);
    try std.testing.expectEqual(@as(u32, 3), after_reason.before_tick_count);
    try std.testing.expectEqual(@as(u32, 1), after_reason.reason_vector_count);

    try std.testing.expect(wakeQueuePopVector(13, 99));
    const after_vector = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 0), after_vector.vector_count);
    try std.testing.expectEqual(@as(u32, 2), after_vector.before_tick_count);
    try std.testing.expectEqual(@as(u32, 0), after_vector.reason_vector_count);

    query.vector = 31;
    query.reason = abi.wake_reason_manual;
    query.max_tick = 55;
    const manual_snapshot = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), manual_snapshot.vector_count);
    try std.testing.expectEqual(@as(u32, 3), manual_snapshot.before_tick_count);
    try std.testing.expectEqual(@as(u32, 0), manual_snapshot.reason_vector_count);
}

test "baremetal wake queue selective mixed command sequence preserves telemetry" {
    resetBaremetalRuntimeForTest();

    wakeQueuePush(6001, 1, abi.wake_reason_timer, 0, 10, 1);
    wakeQueuePush(6002, 2, abi.wake_reason_interrupt, 13, 20, 2);
    wakeQueuePush(6003, 3, abi.wake_reason_interrupt, 13, 30, 3);
    wakeQueuePush(6004, 4, abi.wake_reason_interrupt, 31, 40, 4);
    wakeQueuePush(6005, 5, abi.wake_reason_manual, 0, 50, 5);
    status.ticks = 45;

    const query = oc_wake_queue_count_query_ptr();
    query.* = .{
        .vector = 13,
        .reason = abi.wake_reason_interrupt,
        .reserved0 = 0,
        .reserved1 = 0,
        .max_tick = 40,
    };
    const before = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 2), before.vector_count);
    try std.testing.expectEqual(@as(u32, 4), before.before_tick_count);
    try std.testing.expectEqual(@as(u32, 2), before.reason_vector_count);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason, abi.wake_reason_interrupt, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 4), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 6001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 6003), oc_wake_queue_event(1).task_id);
    const after_reason = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), after_reason.vector_count);
    try std.testing.expectEqual(@as(u32, 3), after_reason.before_tick_count);
    try std.testing.expectEqual(@as(u32, 1), after_reason.reason_vector_count);

    _ = oc_submit_command(abi.command_wake_queue_pop_vector, 13, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 3), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 6001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 6004), oc_wake_queue_event(1).task_id);
    try std.testing.expectEqual(@as(u32, 6005), oc_wake_queue_event(2).task_id);
    const after_vector = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 0), after_vector.vector_count);
    try std.testing.expectEqual(@as(u32, 2), after_vector.before_tick_count);
    try std.testing.expectEqual(@as(u32, 0), after_vector.reason_vector_count);

    query.vector = 31;
    query.max_tick = 55;
    const before_reason_vector = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), before_reason_vector.vector_count);
    try std.testing.expectEqual(@as(u32, 3), before_reason_vector.before_tick_count);
    try std.testing.expectEqual(@as(u32, 1), before_reason_vector.reason_vector_count);

    const pair_interrupt_31: u64 = @as(u64, abi.wake_reason_interrupt) | (@as(u64, 31) << 8);
    _ = oc_submit_command(abi.command_wake_queue_pop_reason_vector, pair_interrupt_31, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 6001), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u32, 6005), oc_wake_queue_event(1).task_id);
    const after_reason_vector = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 0), after_reason_vector.vector_count);
    try std.testing.expectEqual(@as(u32, 2), after_reason_vector.before_tick_count);
    try std.testing.expectEqual(@as(u32, 0), after_reason_vector.reason_vector_count);

    query.vector = 0;
    query.reason = abi.wake_reason_manual;
    query.max_tick = 15;
    const before_before_tick = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 2), before_before_tick.vector_count);
    try std.testing.expectEqual(@as(u32, 1), before_before_tick.before_tick_count);
    try std.testing.expectEqual(@as(u32, 1), before_before_tick.reason_vector_count);

    _ = oc_submit_command(abi.command_wake_queue_pop_before_tick, 15, 99);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 6005), oc_wake_queue_event(0).task_id);
    const after_before_tick = oc_wake_queue_count_snapshot_ptr().*;
    try std.testing.expectEqual(@as(u32, 1), after_before_tick.vector_count);
    try std.testing.expectEqual(@as(u32, 0), after_before_tick.before_tick_count);
    try std.testing.expectEqual(@as(u32, 1), after_before_tick.reason_vector_count);

    _ = oc_submit_command(abi.command_wake_queue_pop_reason_vector, 0, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 6005), oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), oc_wake_queue_event(0).reason);
    try std.testing.expectEqual(@as(u8, 0), oc_wake_queue_event(0).vector);
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
    _ = oc_submit_command(abi.command_scheduler_set_default_budget, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 9), oc_scheduler_state_ptr().default_budget_ticks);
    _ = oc_submit_command(abi.command_task_create, 0, 1); // low uses default budget
    oc_tick();
    const low_id = oc_scheduler_task(0).task_id;
    try std.testing.expectEqual(@as(u32, 9), oc_scheduler_task(0).budget_ticks);
    try std.testing.expectEqual(@as(u32, 9), oc_scheduler_task(0).budget_remaining);
    _ = oc_submit_command(abi.command_task_create, 6, 9); // high
    oc_tick();
    const high_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(low_id != 0 and high_id != 0);
    try std.testing.expectEqual(@as(u32, 6), oc_scheduler_task(1).budget_ticks);
    try std.testing.expectEqual(@as(u32, 6), oc_scheduler_task(1).budget_remaining);

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
    try std.testing.expectEqual(@as(u8, 1), low_task.priority);
    try std.testing.expectEqual(@as(u8, 9), high_task.priority);
    const high_run_before = high_task.run_count;

    _ = oc_submit_command(abi.command_task_set_priority, low_id, 15);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expect(low_task.run_count >= 1);
    try std.testing.expectEqual(@as(u8, 15), low_task.priority);
    try std.testing.expect(high_task.run_count >= high_run_before);

    _ = oc_submit_command(abi.command_scheduler_set_policy, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_priority), oc_scheduler_policy());
    try std.testing.expectEqual(@as(u8, 15), oc_scheduler_task(0).priority);

    _ = oc_submit_command(abi.command_task_set_priority, 99999, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_not_found), status.last_command_result);
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_priority), oc_scheduler_policy());
    try std.testing.expectEqual(@as(u8, 15), low_task.priority);
    try std.testing.expectEqual(@as(u32, 2), scheduler_state.task_count);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), low_task.state);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), high_task.state);
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
    var first = oc_scheduler_task(0);
    var second = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 1), first.run_count);
    try std.testing.expectEqual(@as(u32, 0), second.run_count);
    try std.testing.expectEqual(@as(u32, 3), first.budget_remaining);
    try std.testing.expectEqual(@as(u32, 4), second.budget_remaining);

    oc_tick();
    first = oc_scheduler_task(0);
    second = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 1), first.run_count);
    try std.testing.expectEqual(@as(u32, 1), second.run_count);
    try std.testing.expectEqual(@as(u32, 3), first.budget_remaining);
    try std.testing.expectEqual(@as(u32, 3), second.budget_remaining);

    oc_tick();
    first = oc_scheduler_task(0);
    second = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 2), first.run_count);
    try std.testing.expectEqual(@as(u32, 1), second.run_count);
    try std.testing.expectEqual(@as(u32, 2), first.budget_remaining);
    try std.testing.expectEqual(@as(u32, 3), second.budget_remaining);
    try std.testing.expectEqual(@as(u8, 2), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_round_robin), oc_scheduler_policy());
    try std.testing.expect(status.last_command_result == abi.result_ok);
}

test "baremetal scheduler live timeslice updates change subsequent budget consumption" {
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

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_state_ptr().timeslice_ticks);

    _ = oc_submit_command(abi.command_task_create, 10, 2);
    oc_tick();
    var task = oc_scheduler_task(0);
    try std.testing.expect(task.task_id != 0);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 9), task.budget_remaining);

    _ = oc_submit_command(abi.command_scheduler_set_timeslice, 4, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 4), oc_scheduler_state_ptr().timeslice_ticks);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 2), task.run_count);
    try std.testing.expectEqual(@as(u32, 5), task.budget_remaining);

    _ = oc_submit_command(abi.command_scheduler_set_timeslice, 2, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_state_ptr().timeslice_ticks);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 3), task.run_count);
    try std.testing.expectEqual(@as(u32, 3), task.budget_remaining);

    _ = oc_submit_command(abi.command_scheduler_set_timeslice, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_scheduler_set_timeslice), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_state_ptr().timeslice_ticks);
    try std.testing.expect(oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 4), task.run_count);
    try std.testing.expectEqual(@as(u32, 1), task.budget_remaining);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
    try std.testing.expect(oc_scheduler_state_ptr().dispatch_count >= 4);
}

test "baremetal scheduler disable and re-enable gate dispatch under active load" {
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

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_scheduler_enabled());

    _ = oc_submit_command(abi.command_task_create, 5, 2);
    oc_tick();
    var task = oc_scheduler_task(0);
    try std.testing.expect(task.task_id != 0);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 4), task.budget_remaining);
    const dispatch_before_disable = oc_scheduler_state_ptr().dispatch_count;

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_scheduler_disable), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(!oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 4), task.budget_remaining);
    try std.testing.expectEqual(dispatch_before_disable, oc_scheduler_state_ptr().dispatch_count);

    oc_tick();
    try std.testing.expect(!oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 4), task.budget_remaining);
    try std.testing.expectEqual(dispatch_before_disable, oc_scheduler_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_scheduler_enable), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(dispatch_before_disable +% 1, oc_scheduler_state_ptr().dispatch_count);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 2), task.run_count);
    try std.testing.expectEqual(@as(u32, 3), task.budget_remaining);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
}

test "baremetal scheduler reset clears active state and restarts ids" {
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

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_scheduler_enabled());

    _ = oc_submit_command(abi.command_task_create, 5, 2);
    oc_tick();
    var task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 1), task.task_id);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 4), task.budget_remaining);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_scheduler_reset, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(!oc_scheduler_enabled());
    const reset_state = oc_scheduler_state_ptr().*;
    try std.testing.expectEqual(@as(u32, 0), reset_state.task_count);
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), reset_state.running_slot);
    try std.testing.expectEqual(@as(u32, 1), reset_state.next_task_id);
    try std.testing.expectEqual(@as(u64, 0), reset_state.dispatch_count);
    try std.testing.expectEqual(@as(u32, 1), reset_state.timeslice_ticks);
    try std.testing.expectEqual(@as(u32, 8), reset_state.default_budget_ticks);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 0), task.task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_unused), task.state);

    oc_tick();
    try std.testing.expect(!oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_task_create, 6, 7);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 1), task.task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
    try std.testing.expectEqual(@as(u8, 7), task.priority);
    try std.testing.expectEqual(@as(u32, 6), task.budget_ticks);
    try std.testing.expectEqual(@as(u32, 6), task.budget_remaining);
    try std.testing.expectEqual(@as(u32, 0), task.run_count);
    try std.testing.expect(!oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_state_ptr().next_task_id);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_state_ptr().next_task_id);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_state_ptr().timeslice_ticks);
    try std.testing.expectEqual(@as(u32, 8), oc_scheduler_state_ptr().default_budget_ticks);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 5), task.budget_remaining);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), task.state);
}

test "baremetal scheduler reset clears stale waits wake queue and timer entries" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const timer_task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(timer_task_id != 0);

    _ = oc_submit_command(abi.command_task_create, 6, 1);
    oc_tick();
    const interrupt_task_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(interrupt_task_id != 0);

    _ = oc_submit_command(abi.command_timer_set_quantum, 5, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_wait_for, timer_task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, interrupt_task_id, 20);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_scheduler_wake_task, timer_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, 1), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 5), oc_timer_quantum());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());

    _ = oc_submit_command(abi.command_scheduler_reset, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(!oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 5), oc_timer_quantum());

    oc_tick_n(25);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());

    _ = oc_submit_command(abi.command_task_create, 4, 9);
    oc_tick();
    const fresh_task_id = oc_scheduler_task(0).task_id;
    try std.testing.expectEqual(@as(u32, 1), fresh_task_id);

    _ = oc_submit_command(abi.command_task_wait_for, fresh_task_id, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 2), oc_timer_entry(0).timer_id);
    try std.testing.expectEqual(@as(u32, 3), oc_timer_state_ptr().next_timer_id);
}

test "baremetal scheduler policy switching stays deterministic under active load" {
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
    _ = oc_submit_command(abi.command_task_create, 6, 9); // high
    oc_tick();
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_task_count());

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    var low_task = oc_scheduler_task(0);
    var high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 1), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 0), high_task.run_count);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_round_robin), oc_scheduler_policy());

    oc_tick();
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 1), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 1), high_task.run_count);
    try std.testing.expectEqual(@as(u32, 5), low_task.budget_remaining);
    try std.testing.expectEqual(@as(u32, 5), high_task.budget_remaining);

    _ = oc_submit_command(abi.command_scheduler_set_policy, abi.scheduler_policy_priority, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_priority), oc_scheduler_policy());
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 1), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 2), high_task.run_count);
    try std.testing.expectEqual(@as(u32, 4), high_task.budget_remaining);

    const low_id = low_task.task_id;
    _ = oc_submit_command(abi.command_task_set_priority, low_id, 15);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u8, 15), low_task.priority);
    try std.testing.expectEqual(@as(u32, 2), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 2), high_task.run_count);
    try std.testing.expectEqual(@as(u32, 4), low_task.budget_remaining);

    _ = oc_submit_command(abi.command_scheduler_set_policy, abi.scheduler_policy_round_robin, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_round_robin), oc_scheduler_policy());
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 2), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 3), high_task.run_count);
    try std.testing.expectEqual(@as(u32, 3), high_task.budget_remaining);

    _ = oc_submit_command(abi.command_scheduler_set_policy, 9, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_round_robin), oc_scheduler_policy());
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 3), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 3), high_task.run_count);
    try std.testing.expectEqual(@as(u32, 3), low_task.budget_remaining);
    try std.testing.expectEqual(@as(u32, 3), high_task.budget_remaining);
}

test "baremetal task terminate command fails over cleanly under active load" {
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
    _ = oc_submit_command(abi.command_task_create, 6, 9); // high
    oc_tick();
    _ = oc_submit_command(abi.command_scheduler_set_policy, abi.scheduler_policy_priority, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u8, abi.scheduler_policy_priority), oc_scheduler_policy());

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    var low_task = oc_scheduler_task(0);
    var high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 0), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 1), high_task.run_count);
    try std.testing.expectEqual(@as(u32, 5), high_task.budget_remaining);

    const high_id = high_task.task_id;
    _ = oc_submit_command(abi.command_task_terminate, high_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_terminate), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 1), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 5), low_task.budget_remaining);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), high_task.state);

    _ = oc_submit_command(abi.command_task_terminate, high_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_terminate), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u32, 2), low_task.run_count);
    try std.testing.expectEqual(@as(u32, 4), low_task.budget_remaining);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), high_task.state);

    const dispatch_before_final_terminate = oc_scheduler_state_ptr().dispatch_count;
    const low_id = low_task.task_id;
    _ = oc_submit_command(abi.command_task_terminate, low_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_terminate), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(dispatch_before_final_terminate, oc_scheduler_state_ptr().dispatch_count);
    low_task = oc_scheduler_task(0);
    high_task = oc_scheduler_task(1);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), low_task.state);
    try std.testing.expectEqual(@as(u32, 0), low_task.budget_remaining);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), high_task.state);
    try std.testing.expectEqual(@as(u32, 0), high_task.budget_remaining);
}

test "baremetal task terminate clears mixed timer and wake state for the target task only" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 1);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 6, 2);
    oc_tick();
    const terminated_task_id = oc_scheduler_task(0).task_id;
    const survivor_task_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(terminated_task_id != 0 and survivor_task_id != 0);

    _ = oc_submit_command(abi.command_timer_set_quantum, 5, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_task_wait_for, terminated_task_id, 10);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());

    _ = oc_submit_command(abi.command_scheduler_wake_task, terminated_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    var event = oc_wake_queue_event(0);
    try std.testing.expectEqual(terminated_task_id, event.task_id);

    _ = oc_submit_command(abi.command_task_wait, survivor_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    _ = oc_submit_command(abi.command_scheduler_wake_task, survivor_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    event = oc_wake_queue_event(1);
    try std.testing.expectEqual(survivor_task_id, event.task_id);

    _ = oc_submit_command(abi.command_task_terminate, terminated_task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u8, abi.timer_entry_state_canceled), oc_timer_entry(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u16, 1), oc_timer_state_ptr().pending_wake_count);
    event = oc_wake_queue_event(0);
    try std.testing.expectEqual(survivor_task_id, event.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), event.reason);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[1]);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 5), oc_timer_state_ptr().tick_quantum);

    oc_tick_n(20);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 2), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u32, 5), oc_timer_state_ptr().tick_quantum);
    event = oc_wake_queue_event(0);
    try std.testing.expectEqual(survivor_task_id, event.task_id);
}

test "baremetal task terminate clears interrupt-timeout wait and prevents stale timeout wake" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 1);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 8);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expect(scheduler_wait_timeout_tick[0] > status.ticks);

    _ = oc_submit_command(abi.command_task_terminate, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u8, abi.task_state_terminated), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u16, 0), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);

    oc_tick_n(20);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
}

test "baremetal panic flag freezes scheduler until mode recovery under active load" {
    resetBaremetalRuntimeForTest();

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_scheduler_enabled());

    _ = oc_submit_command(abi.command_task_create, 6, 2);
    oc_tick();
    var task = oc_scheduler_task(0);
    if (task.run_count == 0) {
        oc_tick();
        task = oc_scheduler_task(0);
    }
    try std.testing.expect(task.task_id != 0);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 5), task.budget_remaining);

    const dispatch_before_panic = oc_scheduler_state_ptr().dispatch_count;
    _ = oc_submit_command(abi.command_trigger_panic_flag, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_trigger_panic_flag), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.mode_panicked), status.mode);
    try std.testing.expectEqual(@as(u32, 1), status.panic_count);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_panicked), boot_diagnostics.phase);
    try std.testing.expectEqual(dispatch_before_panic, oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 5), task.budget_remaining);

    oc_tick();
    try std.testing.expectEqual(dispatch_before_panic, oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 1), task.run_count);
    try std.testing.expectEqual(@as(u32, 5), task.budget_remaining);

    _ = oc_submit_command(abi.command_set_mode, abi.mode_running, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_mode), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.mode_running), status.mode);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_panicked), boot_diagnostics.phase);
    try std.testing.expectEqual(dispatch_before_panic + 1, oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 2), task.run_count);
    try std.testing.expectEqual(@as(u32, 4), task.budget_remaining);

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_runtime, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_boot_phase), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_diagnostics.phase);
    try std.testing.expectEqual(dispatch_before_panic + 2, oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().task_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    task = oc_scheduler_task(0);
    try std.testing.expectEqual(@as(u32, 3), task.run_count);
    try std.testing.expectEqual(@as(u32, 3), task.budget_remaining);
}

test "baremetal panic preserves interrupt and timer wakes until recovery" {
    resetBaremetalRuntimeForTest();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 6, 0);
    oc_tick();
    const interrupt_task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(interrupt_task_id != 0);

    _ = oc_submit_command(abi.command_task_create, 7, 1);
    oc_tick();
    const timer_task_id = oc_scheduler_task(1).task_id;
    try std.testing.expect(timer_task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt, interrupt_task_id, abi.wait_interrupt_any_vector);
    oc_tick();
    _ = oc_submit_command(abi.command_task_wait_for, timer_task_id, 5);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());

    _ = oc_submit_command(abi.command_scheduler_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_scheduler_enabled());
    try std.testing.expectEqual(@as(u64, 0), oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());

    _ = oc_submit_command(abi.command_trigger_panic_flag, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_trigger_panic_flag), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.mode_panicked), status.mode);
    try std.testing.expectEqual(@as(u32, 1), status.panic_count);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_panicked), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u64, 0), oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, scheduler_no_slot), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, abi.command_trigger_interrupt), status.last_command_opcode);
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const interrupt_evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(interrupt_task_id, interrupt_evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), interrupt_evt.reason);
    try std.testing.expectEqual(@as(u8, 200), interrupt_evt.vector);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_scheduler_state_ptr().dispatch_count);

    var spins: u32 = 0;
    while (oc_wake_queue_len() < 2 and spins < 8) : (spins += 1) {
        oc_tick();
    }
    try std.testing.expect(spins < 8);
    try std.testing.expectEqual(@as(u32, 2), oc_wake_queue_len());
    const timer_evt = oc_wake_queue_event(1);
    try std.testing.expectEqual(timer_task_id, timer_evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), timer_evt.reason);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expect(oc_timer_state_ptr().dispatch_count >= 1);
    try std.testing.expectEqual(@as(u64, 0), oc_scheduler_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_set_mode, abi.mode_running, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_mode), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.mode_running), status.mode);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_panicked), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u64, 1), oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task(0).run_count);
    try std.testing.expectEqual(@as(u32, 5), oc_scheduler_task(0).budget_remaining);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task(1).run_count);
    try std.testing.expectEqual(@as(u32, 7), oc_scheduler_task(1).budget_remaining);

    _ = oc_submit_command(abi.command_set_boot_phase, abi.boot_phase_runtime, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_set_boot_phase), status.last_command_opcode);
    try std.testing.expectEqual(@as(u8, abi.boot_phase_runtime), boot_diagnostics.phase);
    try std.testing.expectEqual(@as(u64, 2), oc_scheduler_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u8, 1), oc_scheduler_state_ptr().running_slot);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task(0).run_count);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task(1).run_count);
    try std.testing.expectEqual(@as(u32, 6), oc_scheduler_task(1).budget_remaining);
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
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(task_any_id, oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), oc_wake_queue_event(0).reason);
    try std.testing.expectEqual(@as(u8, 200), oc_wake_queue_event(0).vector);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);

    oc_wake_queue_clear();

    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_vec_id = oc_scheduler_task(1).task_id;
    _ = oc_submit_command(abi.command_task_wait_interrupt, task_vec_id, 13);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, 13), scheduler_wait_interrupt_vector[1]);
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_vector), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_vector), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u8, 13), scheduler_wait_interrupt_vector[1]);
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 13, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const vec_evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_vec_id, vec_evt.task_id);
    try std.testing.expectEqual(@as(u8, 13), vec_evt.vector);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), vec_evt.reason);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u32, 2), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[1]);

    _ = oc_submit_command(abi.command_task_wait_interrupt, task_vec_id, @as(u64, abi.wait_interrupt_any_vector) + 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(@as(u16, abi.command_task_wait_interrupt), status.last_command_opcode);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(task_vec_id, oc_wake_queue_event(0).task_id);
    try std.testing.expectEqual(@as(u8, 13), oc_wake_queue_event(0).vector);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(1).state);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[1]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[1]);
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
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_vector_count(13));
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
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_vector_count(13));

    _ = oc_submit_command(abi.command_clear_exception_history, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_exception_history_len());
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_exception_history_overflow_count());
    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_vector_count(13));
}

test "baremetal interrupt and exception counter reset commands preserve histories and vector tables" {
    resetBaremetalRuntimeForTest();

    x86_bootstrap.oc_interrupt_mask_clear_all();
    x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_reset_exception_counters();
    x86_bootstrap.oc_reset_vector_counters();
    x86_bootstrap.oc_interrupt_history_clear();
    x86_bootstrap.oc_exception_history_clear();

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_trigger_exception, 13, 0xCAFE);
    oc_tick();

    try std.testing.expectEqual(@as(u64, 2), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_vector_count(13));
    try std.testing.expectEqual(@as(u32, 2), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());

    _ = oc_submit_command(abi.command_interrupt_mask_apply_profile, abi.interrupt_mask_profile_external_all, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    _ = oc_submit_command(abi.command_trigger_interrupt, 201, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u8, 201), x86_bootstrap.oc_interrupt_last_masked_vector());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_vector_count(201));

    _ = oc_submit_command(abi.command_reset_interrupt_counters, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u8, 0), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u8, 0), x86_bootstrap.oc_interrupt_last_masked_vector());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_mask_ignored_vector_count(201));
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_vector_count(200));
    try std.testing.expectEqual(@as(u32, 2), x86_bootstrap.oc_interrupt_history_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());

    _ = oc_submit_command(abi.command_reset_exception_counters, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_exception_count());
    try std.testing.expectEqual(@as(u8, 0), x86_bootstrap.oc_last_exception_vector());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_last_exception_code());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_exception_vector_count(13));
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_exception_history_len());
    try std.testing.expectEqual(@as(u32, 2), x86_bootstrap.oc_interrupt_history_len());
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
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_event(0).timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), oc_wake_queue_event(0).reason);
    try std.testing.expectEqual(@as(u8, 13), oc_wake_queue_event(0).vector);
    try std.testing.expect(oc_wake_queue_event(0).tick >= 1);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(task_id, oc_scheduler_task(0).task_id);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, 0), oc_scheduler_task(0).priority);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task(0).run_count);
    try std.testing.expectEqual(@as(u32, 5), oc_scheduler_task(0).budget_ticks);
    try std.testing.expectEqual(@as(u32, 5), oc_scheduler_task(0).budget_remaining);
    try std.testing.expect(x86_bootstrap.oc_interrupt_mask_is_set(200));
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(13));
    try std.testing.expectEqual(abi.interrupt_mask_profile_external_all, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 224), x86_bootstrap.oc_interrupt_masked_count());

    _ = oc_submit_command(abi.command_interrupt_mask_set, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(200));
    try std.testing.expectEqual(abi.interrupt_mask_profile_custom, x86_bootstrap.oc_interrupt_mask_profile());

    _ = oc_submit_command(abi.command_interrupt_mask_set, 300, 1);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(abi.interrupt_mask_profile_custom, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 223), x86_bootstrap.oc_interrupt_masked_count());
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(200));

    _ = oc_submit_command(abi.command_interrupt_mask_set, 200, 2);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_invalid_argument), status.last_command_result);
    try std.testing.expectEqual(abi.interrupt_mask_profile_custom, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 223), x86_bootstrap.oc_interrupt_masked_count());
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(200));

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
    try std.testing.expectEqual(abi.interrupt_mask_profile_custom, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 223), x86_bootstrap.oc_interrupt_masked_count());
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(200));
    try std.testing.expect(x86_bootstrap.oc_interrupt_mask_is_set(201));

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
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(63));
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(64));
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(201));

    _ = oc_submit_command(abi.command_interrupt_mask_clear_all, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_masked_count());
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(201));
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(63));
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(64));
    try std.testing.expectEqual(abi.interrupt_mask_profile_none, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u8, 0), x86_bootstrap.oc_interrupt_last_masked_vector());
}

test "baremetal interrupt mask clear all restores wake delivery for an active waiter" {
    resetBaremetalRuntimeForTest();
    x86_bootstrap.oc_reset_interrupt_counters();
    x86_bootstrap.oc_interrupt_mask_clear_all();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt, task_id, abi.wait_interrupt_any_vector);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);

    _ = oc_submit_command(abi.command_interrupt_mask_apply_profile, abi.interrupt_mask_profile_external_all, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(x86_bootstrap.oc_interrupt_mask_is_set(200));
    try std.testing.expectEqual(@as(u32, 224), x86_bootstrap.oc_interrupt_masked_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u8, 200), x86_bootstrap.oc_interrupt_last_masked_vector());

    _ = oc_submit_command(abi.command_interrupt_mask_clear_all, 0, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expect(!x86_bootstrap.oc_interrupt_mask_is_set(200));
    try std.testing.expectEqual(abi.interrupt_mask_profile_none, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u32, 0), x86_bootstrap.oc_interrupt_masked_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u8, 200), x86_bootstrap.oc_interrupt_last_masked_vector());

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), evt.reason);
    try std.testing.expectEqual(@as(u8, 200), evt.vector);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u32, 1), x86_bootstrap.oc_interrupt_count());
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
    try std.testing.expectEqual(@as(u8, abi.task_state_waiting), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, status.ticks), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());

    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);
}

test "baremetal interrupt wait with timeout resumes on timer after re-enable" {
    resetBaremetalRuntimeForTest();
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

    _ = oc_submit_command(abi.command_timer_disable, 0, 0);
    oc_tick();
    try std.testing.expect(!oc_timer_enabled());

    oc_tick_n(4);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);

    _ = oc_submit_command(abi.command_timer_enable, 0, 0);
    oc_tick();
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);
}

test "baremetal masked interrupt wait with timeout falls back to timer wake" {
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
    x86_bootstrap.oc_interrupt_mask_reset_ignored_counts();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_interrupt_mask_apply_profile, abi.interrupt_mask_profile_external_all, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(abi.interrupt_mask_profile_external_all, x86_bootstrap.oc_interrupt_mask_profile());

    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt_for, task_id, 3);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u8, 200), x86_bootstrap.oc_interrupt_last_masked_vector());
    try std.testing.expectEqual(abi.interrupt_mask_profile_external_all, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());

    var wake_spin: u8 = 0;
    while (oc_wake_queue_len() == 0 and wake_spin < 4) : (wake_spin += 1) {
        oc_tick();
    }
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_mask_ignored_count());
    try std.testing.expectEqual(@as(u8, 200), x86_bootstrap.oc_interrupt_last_masked_vector());
    try std.testing.expectEqual(abi.interrupt_mask_profile_external_all, x86_bootstrap.oc_interrupt_mask_profile());
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());
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
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expect(scheduler_wait_timeout_tick[0] > status.ticks);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_trigger_interrupt, 31, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(abi.task_state_ready, oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u8, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 31), x86_bootstrap.oc_last_interrupt_vector());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), evt.reason);
    try std.testing.expectEqual(@as(u8, 31), evt.vector);
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);

    oc_tick_n(8);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u8, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 31), x86_bootstrap.oc_last_interrupt_vector());
}

test "baremetal interrupt wait with timeout cancels cleanly on manual wake" {
    resetBaremetalRuntimeForTest();
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
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expect(scheduler_wait_timeout_tick[0] > status.ticks);
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_scheduler_wake_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());

    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);

    oc_tick_n(8);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);
}

test "baremetal interrupt wait with timeout still wakes on interrupt while timer is disabled" {
    resetBaremetalRuntimeForTest();
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

    _ = oc_submit_command(abi.command_timer_disable, 0, 0);
    oc_tick();
    try std.testing.expect(!oc_timer_enabled());

    _ = oc_submit_command(abi.command_trigger_interrupt, 31, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expect(!oc_timer_enabled());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().pending_wake_count);

    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_interrupt), evt.reason);
    try std.testing.expectEqual(@as(u8, 31), evt.vector);

    _ = oc_submit_command(abi.command_timer_enable, 0, 0);
    oc_tick_n(6);
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().pending_wake_count);
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);
}

test "baremetal interrupt wait cancels cleanly on manual wake" {
    resetBaremetalRuntimeForTest();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt, task_id, abi.wait_interrupt_any_vector);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_scheduler_wake_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().pending_wake_count);

    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 200), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expect(oc_timer_enabled());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(@as(u64, 1), oc_timer_state_ptr().pending_wake_count);

    oc_tick_n(4);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);
}

test "baremetal task resume clears interrupt wait and prevents later interrupt wake" {
    resetBaremetalRuntimeForTest();
    x86_bootstrap.oc_reset_interrupt_counters();

    _ = oc_submit_command(abi.command_scheduler_disable, 0, 0);
    oc_tick();
    _ = oc_submit_command(abi.command_task_create, 5, 0);
    oc_tick();
    const task_id = oc_scheduler_task(0).task_id;
    try std.testing.expect(task_id != 0);

    _ = oc_submit_command(abi.command_task_wait_interrupt, task_id, abi.wait_interrupt_any_vector);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());

    _ = oc_submit_command(abi.command_task_resume, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u16, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().last_interrupt_count);
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());

    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u32, 0), evt.timer_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);

    _ = oc_submit_command(abi.command_trigger_interrupt, 200, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 200), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u32, 0), oc_timer_entry_count());
    try std.testing.expectEqual(@as(u32, 1), oc_timer_state_ptr().next_timer_id);
    try std.testing.expectEqual(@as(u64, 0), oc_timer_state_ptr().dispatch_count);

    oc_tick_n(4);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);
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
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(abi.task_state_waiting, oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_manual), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 0), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 0), x86_bootstrap.oc_last_interrupt_vector());

    _ = oc_submit_command(abi.command_trigger_interrupt, 44, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(abi.task_state_waiting, oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_manual), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 44), x86_bootstrap.oc_last_interrupt_vector());

    _ = oc_submit_command(abi.command_scheduler_wake_task, task_id, 0);
    oc_tick();
    try std.testing.expectEqual(@as(i16, abi.result_ok), status.last_command_result);
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_waiting_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_interrupt_count());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(abi.task_state_ready, oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 44), x86_bootstrap.oc_last_interrupt_vector());
    const evt = oc_wake_queue_event(0);
    try std.testing.expectEqual(task_id, evt.task_id);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_manual), evt.reason);
    try std.testing.expectEqual(@as(u8, 0), evt.vector);
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);

    oc_tick_n(4);
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 1), oc_scheduler_task_count());
    try std.testing.expectEqual(abi.task_state_ready, oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u64, 1), x86_bootstrap.oc_interrupt_count());
    try std.testing.expectEqual(@as(u16, 44), x86_bootstrap.oc_last_interrupt_vector());
    try std.testing.expectEqual(evt.tick, oc_timer_state_ptr().last_wake_tick);
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
    try std.testing.expectEqual(@as(u8, wait_condition_interrupt_any), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(std.math.maxInt(u64), scheduler_wait_timeout_tick[0]);

    oc_tick();
    try std.testing.expectEqual(@as(u32, 1), oc_wake_queue_len());
    try std.testing.expectEqual(@as(u32, 0), oc_scheduler_wait_timeout_count());
    try std.testing.expectEqual(@as(u8, wait_condition_none), scheduler_wait_kind[0]);
    try std.testing.expectEqual(@as(u8, 0), scheduler_wait_interrupt_vector[0]);
    try std.testing.expectEqual(@as(u64, 0), scheduler_wait_timeout_tick[0]);
    try std.testing.expectEqual(@as(u8, abi.task_state_ready), oc_scheduler_task(0).state);
    try std.testing.expectEqual(@as(u8, abi.wake_reason_timer), oc_wake_queue_event(0).reason);
    try std.testing.expectEqual(std.math.maxInt(u64), oc_wake_queue_event(0).tick);
}

test "baremetal console export surface updates host-backed console state" {
    resetBaremetalRuntimeForTest();

    const console = oc_console_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.console_magic), console.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version), console.api_version);
    try std.testing.expectEqual(@as(u16, 80), console.cols);
    try std.testing.expectEqual(@as(u16, 25), console.rows);
    try std.testing.expectEqual(@as(u8, abi.console_backend_host_buffer), console.backend);
    try std.testing.expectEqual(@as(u32, 0), console.write_count);
    try std.testing.expectEqual(@as(u32, 0), console.scroll_count);
    try std.testing.expectEqual(@as(u32, 0), console.clear_count);

    oc_console_clear();
    try std.testing.expectEqual(@as(u32, 1), console.clear_count);
    try std.testing.expectEqual((@as(u16, console.attribute) << 8) | @as(u16, ' '), oc_console_cell(0));

    oc_console_putc('O');
    oc_console_putc('K');
    try std.testing.expectEqual(@as(u32, 2), console.write_count);
    try std.testing.expectEqual(@as(u16, 0), console.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), console.cursor_col);
    try std.testing.expectEqual((@as(u16, console.attribute) << 8) | @as(u16, 'O'), oc_console_cell(0));
    try std.testing.expectEqual((@as(u16, console.attribute) << 8) | @as(u16, 'K'), oc_console_cell(1));
}

test "baremetal framebuffer export surface updates host-backed framebuffer state" {
    resetBaremetalRuntimeForTest();

    try std.testing.expectEqual(@as(u8, 0), oc_framebuffer_init());
    const framebuffer = oc_framebuffer_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.framebuffer_magic), framebuffer.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version), framebuffer.api_version);
    try std.testing.expectEqual(@as(u8, abi.console_backend_linear_framebuffer), framebuffer.backend);
    try std.testing.expectEqual(@as(u8, 0), framebuffer.hardware_backed);
    try std.testing.expectEqual(@as(u16, 640), framebuffer.width);
    try std.testing.expectEqual(@as(u16, 400), framebuffer.height);
    try std.testing.expectEqual(@as(u16, 80), framebuffer.cols);
    try std.testing.expectEqual(@as(u16, 25), framebuffer.rows);

    oc_framebuffer_clear();
    oc_framebuffer_putc('O');
    oc_framebuffer_putc('K');

    try std.testing.expectEqual(@as(u32, 2), framebuffer.write_count);
    try std.testing.expect(framebuffer.clear_count >= 1);

    var o_has_ink = false;
    var k_has_ink = false;
    var py: u32 = 0;
    while (py < 16) : (py += 1) {
        var px: u32 = 0;
        while (px < 8) : (px += 1) {
            if (oc_framebuffer_pixel_at(px, py) != 0) o_has_ink = true;
            if (oc_framebuffer_pixel_at(8 + px, py) != 0) k_has_ink = true;
        }
    }
    try std.testing.expect(o_has_ink);
    try std.testing.expect(k_has_ink);
    try std.testing.expectEqual(@as(u32, 0), oc_framebuffer_pixel_at(0, 0));
}

test "baremetal ethernet export surface initializes mock rtl8139 and loops a frame" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expectEqual(@as(u8, 1), oc_ethernet_init());
    const eth = oc_ethernet_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.ethernet_magic), eth.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version), eth.api_version);
    try std.testing.expectEqual(@as(u8, abi.ethernet_backend_rtl8139), eth.backend);
    try std.testing.expectEqual(@as(u8, 1), eth.initialized);
    try std.testing.expectEqual(@as(u8, 1), eth.loopback_enabled);
    try std.testing.expectEqual(@as(u8, 0x52), oc_ethernet_mac_byte(0));

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_ethernet_send_pattern(96, 0x41));
    try std.testing.expectEqual(@as(u32, 96), oc_ethernet_poll());
    try std.testing.expectEqual(@as(u32, 96), oc_ethernet_rx_len());
    try std.testing.expectEqual(@as(u8, 0x52), oc_ethernet_rx_byte(0));
    try std.testing.expectEqual(@as(u8, 0x88), oc_ethernet_rx_byte(12));
    try std.testing.expectEqual(@as(u8, 0x41), oc_ethernet_rx_byte(14));
    try std.testing.expectEqual(@as(u32, 1), eth.tx_packets);
    try std.testing.expectEqual(@as(u32, 1), eth.rx_packets);
}

test "baremetal ethernet arp request loops through mock rtl8139 and parses request" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expectEqual(@as(u8, 1), oc_ethernet_init());
    const eth = oc_ethernet_state_ptr();
    const sender_ip = [4]u8{ 192, 168, 56, 10 };
    const target_ip = [4]u8{ 192, 168, 56, 1 };

    try std.testing.expectEqual(@as(u32, arp_protocol.frame_len), try pal_net.sendArpRequest(sender_ip, target_ip));
    const packet = (try pal_net.pollArpPacket()).?;

    try std.testing.expectEqual(arp_protocol.operation_request, packet.operation);
    try std.testing.expectEqualSlices(u8, ethernet_protocol.broadcast_mac[0..], packet.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, eth.mac[0..], packet.ethernet_source[0..]);
    try std.testing.expectEqualSlices(u8, eth.mac[0..], packet.sender_mac[0..]);
    try std.testing.expectEqualSlices(u8, sender_ip[0..], packet.sender_ip[0..]);
    try std.testing.expectEqualSlices(u8, target_ip[0..], packet.target_ip[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, packet.target_mac[0..]);
    try std.testing.expectEqual(@as(u32, 1), eth.tx_packets);
    try std.testing.expectEqual(@as(u32, 1), eth.rx_packets);
    try std.testing.expect(eth.last_rx_len >= arp_protocol.frame_len);
}

test "baremetal rtl8139 ipv4 probe succeeds through mock device" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try runRtl8139Ipv4Probe();
}

test "baremetal rtl8139 udp probe succeeds through mock device" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try runRtl8139UdpProbe();
}

test "baremetal rtl8139 tcp probe succeeds through mock device" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try runRtl8139TcpProbe();
}

test "baremetal rtl8139 dhcp probe succeeds through mock device" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try runRtl8139DhcpProbe();
}

test "baremetal rtl8139 dns probe succeeds through mock device" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try runRtl8139DnsProbe();
}

test "baremetal rtl8139 gateway routing probe succeeds through mock device" {
    resetBaremetalRuntimeForTest();
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try runRtl8139GatewayProbe();
}

test "baremetal tool exec probe succeeds through pal proc freestanding path" {
    try runToolExecProbe();
}

test "baremetal storage export surface persists block writes and flush state" {
    resetBaremetalRuntimeForTest();

    oc_storage_init();
    const storage = oc_storage_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.storage_magic), storage.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version), storage.api_version);
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ram_disk), storage.backend);
    try std.testing.expectEqual(@as(u8, 1), storage.mounted);
    try std.testing.expectEqual(@as(u32, storage_backend.block_size), storage.block_size);
    try std.testing.expectEqual(@as(u32, storage_backend.block_count), storage.block_count);

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_storage_write_pattern(4, 2, 0x41));
    try std.testing.expectEqual(@as(u32, 2), storage.write_ops);
    try std.testing.expectEqual(@as(u8, 1), storage.dirty);
    try std.testing.expectEqual(@as(u8, 0x41), oc_storage_read_byte(4, 0));
    try std.testing.expectEqual(@as(u8, 0x42), oc_storage_read_byte(4, 1));
    try std.testing.expectEqual(@as(u8, 0x41), oc_storage_read_byte(5, 0));

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_storage_flush());
    try std.testing.expectEqual(@as(u32, 1), storage.flush_ops);
    try std.testing.expectEqual(@as(u8, 0), storage.dirty);
}

test "baremetal storage backend facade reports ram-disk backend baseline" {
    resetBaremetalRuntimeForTest();

    oc_storage_init();
    const storage = oc_storage_state_ptr();
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ram_disk), storage.backend);
    try std.testing.expectEqual(@as(u32, storage_backend.block_size), storage.block_size);
    try std.testing.expectEqual(@as(u32, storage_backend.block_count), storage.block_count);
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ram_disk), storage_backend.activeBackend());
}

test "baremetal storage exports report ata pio backend when a device is available" {
    resetBaremetalRuntimeForTest();
    ata_pio_disk.testEnableMockDevice(4096);
    defer ata_pio_disk.testDisableMockDevice();

    oc_storage_init();
    const storage = oc_storage_state_ptr();
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ata_pio), storage.backend);
    try std.testing.expectEqual(@as(u8, 1), storage.mounted);
    try std.testing.expectEqual(@as(u32, 4096), storage.block_count);

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_storage_write_pattern(6, 1, 0x55));
    try std.testing.expectEqual(@as(u8, 0x55), oc_storage_read_byte(6, 0));
    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_storage_flush());
}

test "baremetal tool layout persists patterned tool slot payloads on ram disk" {
    resetBaremetalRuntimeForTest();

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_tool_layout_init());
    const layout = oc_tool_layout_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.tool_layout_magic), layout.magic);
    try std.testing.expectEqual(@as(u8, 1), layout.formatted);
    try std.testing.expectEqual(@as(u16, tool_layout.slot_count), layout.slot_count);
    try std.testing.expectEqual(@as(u32, tool_layout.slot_data_lba), layout.slot_data_lba);

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_tool_slot_write_pattern(1, 1000, 0x30));
    const slot = oc_tool_layout_slot(1);
    try std.testing.expectEqual(@as(u32, 1), layout.write_count);
    try std.testing.expectEqual(@as(u32, 2), slot.block_count);
    try std.testing.expectEqual(@as(u32, 1000), slot.byte_len);
    try std.testing.expectEqual(tool_layout.tool_slot_flag_valid, slot.flags);
    try std.testing.expectEqual(@as(u8, 0x30), oc_tool_slot_byte(1, 0));
    try std.testing.expectEqual(@as(u8, 0x31), oc_tool_slot_byte(1, 1));
    try std.testing.expectEqual(@as(u8, 0x30), oc_tool_slot_byte(1, 512));
    try std.testing.expectEqual(@as(u8, 0x30), oc_storage_read_byte(slot.start_lba, 0));

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_tool_slot_clear(1));
    const cleared = oc_tool_layout_slot(1);
    try std.testing.expectEqual(@as(u32, 1), layout.clear_count);
    try std.testing.expectEqual(@as(u32, 0), cleared.block_count);
    try std.testing.expectEqual(@as(u32, 0), cleared.byte_len);
    try std.testing.expectEqual(@as(u32, 0), cleared.flags);
    try std.testing.expectEqual(@as(u8, 0), oc_tool_slot_byte(1, 0));
}

test "baremetal filesystem persists path-based files on the ram disk" {
    resetBaremetalRuntimeForTest();

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_filesystem_init());
    const fs_state = oc_filesystem_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.filesystem_magic), fs_state.magic);
    try std.testing.expectEqual(@as(u8, 1), fs_state.formatted);
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ram_disk), fs_state.active_backend);

    const io = std.Io.Threaded.global_single_threaded.io();
    if (builtin.os.tag == .freestanding) {
        try pal_fs.createDirPath(io, "/runtime/state");
        try pal_fs.writeFile(io, "/runtime/state/agent.json", "{\"ok\":true}");
        const stat = try pal_fs.statNoFollow(io, "/runtime/state/agent.json");
        try std.testing.expectEqual(@as(std.Io.File.Kind, .file), stat.kind);
        try std.testing.expectEqual(@as(u64, 11), stat.size);

        const content = try pal_fs.readFileAlloc(io, std.testing.allocator, "/runtime/state/agent.json", 64);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("{\"ok\":true}", content);
    } else {
        try filesystem.createDirPath("/runtime/state");
        try filesystem.writeFile("/runtime/state/agent.json", "{\"ok\":true}", status.ticks);
        const stat = try filesystem.statNoFollow("/runtime/state/agent.json");
        try std.testing.expectEqual(@as(std.Io.File.Kind, .file), stat.kind);
        try std.testing.expectEqual(@as(u64, 11), stat.size);

        const content = try filesystem.readFileAlloc(std.testing.allocator, "/runtime/state/agent.json", 64);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("{\"ok\":true}", content);
    }

    try std.testing.expectEqual(@as(u16, 2), fs_state.dir_entries);
    try std.testing.expectEqual(@as(u16, 1), fs_state.file_entries);

    filesystem.resetForTest();
    try filesystem.init();
    const reloaded = try filesystem.readFileAlloc(std.testing.allocator, "/runtime/state/agent.json", 64);
    defer std.testing.allocator.free(reloaded);
    try std.testing.expectEqualStrings("{\"ok\":true}", reloaded);
}

test "baremetal filesystem persists path-based files on ata-backed storage" {
    resetBaremetalRuntimeForTest();
    ata_pio_disk.testEnableMockDevice(4096);
    defer ata_pio_disk.testDisableMockDevice();

    try std.testing.expectEqual(@as(i16, abi.result_ok), oc_filesystem_init());
    try filesystem.createDirPath("/tools/cache");
    try filesystem.writeFile("/tools/cache/tool.txt", "edge", 99);

    const fs_state = oc_filesystem_state_ptr();
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ata_pio), fs_state.active_backend);
    try std.testing.expectEqual(@as(u16, 2), fs_state.dir_entries);
    try std.testing.expectEqual(@as(u16, 1), fs_state.file_entries);

    filesystem.resetForTest();
    try filesystem.init();
    const stat = try filesystem.statNoFollow("/tools/cache/tool.txt");
    try std.testing.expectEqual(@as(std.Io.File.Kind, .file), stat.kind);
    try std.testing.expectEqual(@as(u64, 4), stat.size);
    const content = try filesystem.readFileAlloc(std.testing.allocator, "/tools/cache/tool.txt", 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("edge", content);
}

test "baremetal ata storage probe validates raw, tool layout, and filesystem persistence" {
    resetBaremetalRuntimeForTest();
    ata_pio_disk.testEnableMockDevice(4096);
    defer ata_pio_disk.testDisableMockDevice();

    try runAtaStorageProbe();

    const storage = oc_storage_state_ptr();
    try std.testing.expectEqual(@as(u8, abi.storage_backend_ata_pio), storage.backend);
    try std.testing.expectEqual(@as(u8, 0x41), oc_storage_read_byte(ata_probe_raw_lba, 0));
    try std.testing.expectEqual(@as(u8, 0x42), oc_storage_read_byte(ata_probe_raw_lba, 1));
    try std.testing.expectEqual(@as(u8, 0x41), oc_storage_read_byte(ata_probe_raw_lba + 1, 0));

    const slot = oc_tool_layout_slot(ata_probe_tool_slot_id);
    try std.testing.expectEqual(ata_probe_tool_slot_expected_lba, slot.start_lba);
    try std.testing.expectEqual(@as(u8, ata_probe_tool_slot_seed), oc_tool_slot_byte(ata_probe_tool_slot_id, 0));
    try std.testing.expectEqual(@as(u8, ata_probe_tool_slot_seed), oc_tool_slot_byte(ata_probe_tool_slot_id, 512));

    const content = try filesystem.readFileAlloc(std.testing.allocator, ata_probe_filesystem_path, 64);
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings(ata_probe_filesystem_payload, content);
}

test "baremetal keyboard export surface captures interrupt-driven scancodes" {
    resetBaremetalRuntimeForTest();
    x86_bootstrap.init();
    const keyboard = oc_keyboard_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.keyboard_magic), keyboard.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version), keyboard.api_version);
    try std.testing.expectEqual(@as(u8, 1), keyboard.connected);

    oc_keyboard_inject_scancode(0x2A);
    _ = oc_submit_command(abi.command_trigger_interrupt, ps2_input.keyboard_irq_vector, 0);
    oc_tick();
    try std.testing.expectEqual(abi.input_modifier_shift, keyboard.modifiers);

    oc_keyboard_inject_scancode(0x1E);
    _ = oc_submit_command(abi.command_trigger_interrupt, ps2_input.keyboard_irq_vector, 0);
    oc_tick();
    try std.testing.expectEqual(@as(u16, 2), keyboard.queue_len);
    try std.testing.expectEqual(@as(u32, 2), keyboard.event_count);
    try std.testing.expectEqual(@as(u8, 0x1E), keyboard.last_scancode);
    try std.testing.expectEqual(@as(u16, 'A'), keyboard.last_keycode);
    try std.testing.expectEqual(@as(u64, 1), keyboard.last_tick);

    const evt0 = oc_keyboard_event(0);
    try std.testing.expectEqual(@as(u8, 0x2A), evt0.scancode);
    try std.testing.expectEqual(@as(u8, 1), evt0.pressed);
    try std.testing.expectEqual(@as(u8, abi.input_modifier_shift), evt0.modifiers);
    try std.testing.expectEqual(@as(u16, 0x2A), evt0.keycode);
    try std.testing.expectEqual(@as(u64, 0), evt0.tick);
    try std.testing.expectEqual(@as(u32, 1), evt0.interrupt_seq);

    const evt = oc_keyboard_event(1);
    try std.testing.expectEqual(@as(u8, 0x1E), evt.scancode);
    try std.testing.expectEqual(@as(u8, 1), evt.pressed);
    try std.testing.expectEqual(@as(u8, abi.input_modifier_shift), evt.modifiers);
    try std.testing.expectEqual(@as(u16, 'A'), evt.keycode);
    try std.testing.expectEqual(@as(u64, 1), evt.tick);
    try std.testing.expectEqual(@as(u32, 2), evt.interrupt_seq);
}

test "baremetal mouse export surface captures interrupt-driven packets" {
    resetBaremetalRuntimeForTest();
    x86_bootstrap.init();
    const mouse = oc_mouse_state_ptr();
    try std.testing.expectEqual(@as(u32, abi.mouse_magic), mouse.magic);
    try std.testing.expectEqual(@as(u16, abi.api_version), mouse.api_version);
    try std.testing.expectEqual(@as(u8, 1), mouse.connected);

    oc_mouse_inject_packet(0x05, 6, -3);
    _ = oc_submit_command(abi.command_trigger_interrupt, ps2_input.mouse_irq_vector, 0);
    oc_tick();

    try std.testing.expectEqual(@as(u16, 1), mouse.queue_len);
    try std.testing.expectEqual(@as(u32, 1), mouse.packet_count);
    try std.testing.expectEqual(@as(u8, 0x05), mouse.last_buttons);
    try std.testing.expectEqual(@as(i32, 6), mouse.accum_x);
    try std.testing.expectEqual(@as(i32, -3), mouse.accum_y);
    try std.testing.expectEqual(@as(i16, 6), mouse.last_dx);
    try std.testing.expectEqual(@as(i16, -3), mouse.last_dy);
    try std.testing.expectEqual(@as(u64, 0), mouse.last_tick);

    const pkt = oc_mouse_packet(0);
    try std.testing.expectEqual(@as(u8, 0x05), pkt.buttons);
    try std.testing.expectEqual(@as(i16, 6), pkt.dx);
    try std.testing.expectEqual(@as(i16, -3), pkt.dy);
    try std.testing.expectEqual(@as(u64, 0), pkt.tick);
    try std.testing.expectEqual(@as(u32, 1), pkt.interrupt_seq);
}
