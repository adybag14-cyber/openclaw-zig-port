const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const x86_bootstrap = @import("x86_bootstrap.zig");

pub const keyboard_irq_vector: u8 = 33;
pub const mouse_irq_vector: u8 = 44;
pub const keyboard_queue_capacity: usize = 32;
pub const mouse_packet_capacity: usize = 16;
const controller_keyboard_capacity: usize = 32;
const controller_mouse_capacity: usize = 16;

const PendingMousePacket = extern struct {
    buttons: u8,
    dx: i16,
    dy: i16,
};

const controller_data_port: u16 = 0x60;
const controller_status_port: u16 = 0x64;
const controller_command_port: u16 = 0x64;
const controller_status_output_full: u8 = 1 << 0;
const controller_status_input_full: u8 = 1 << 1;
const controller_status_aux_data: u8 = 1 << 5;
const controller_command_read_config: u8 = 0x20;
const controller_command_write_config: u8 = 0x60;
const controller_command_enable_keyboard: u8 = 0xAE;
const controller_command_enable_mouse: u8 = 0xA8;
const controller_wait_limit: usize = 1024;
const controller_drain_limit: usize = 64;

var keyboard_state: abi.BaremetalKeyboardState = .{
    .magic = abi.keyboard_magic,
    .api_version = abi.api_version,
    .connected = 1,
    .modifiers = 0,
    .queue_len = 0,
    .queue_overflow = 0,
    .event_count = 0,
    .key_down_count = 0,
    .key_up_count = 0,
    .last_scancode = 0,
    .last_pressed = 0,
    .reserved0 = .{ 0, 0 },
    .last_keycode = 0,
    .reserved1 = 0,
    .last_tick = 0,
};

var keyboard_events: [keyboard_queue_capacity]abi.BaremetalKeyboardEvent = std.mem.zeroes([keyboard_queue_capacity]abi.BaremetalKeyboardEvent);
var keyboard_head: u32 = 0;
var keyboard_count: u32 = 0;
var keyboard_seq: u32 = 0;

var mouse_state: abi.BaremetalMouseState = .{
    .magic = abi.mouse_magic,
    .api_version = abi.api_version,
    .connected = 1,
    .reserved0 = 0,
    .queue_len = 0,
    .queue_overflow = 0,
    .packet_count = 0,
    .last_buttons = 0,
    .reserved1 = .{ 0, 0, 0 },
    .accum_x = 0,
    .accum_y = 0,
    .last_dx = 0,
    .last_dy = 0,
    .last_tick = 0,
};

var mouse_packets: [mouse_packet_capacity]abi.BaremetalMousePacket = std.mem.zeroes([mouse_packet_capacity]abi.BaremetalMousePacket);
var mouse_head: u32 = 0;
var mouse_count: u32 = 0;
var mouse_seq: u32 = 0;

var pending_keyboard: [controller_keyboard_capacity]u8 = std.mem.zeroes([controller_keyboard_capacity]u8);
var pending_keyboard_head: u32 = 0;
var pending_keyboard_count: u32 = 0;

var pending_mouse: [controller_mouse_capacity]PendingMousePacket = undefined;
var pending_mouse_head: u32 = 0;
var pending_mouse_count: u32 = 0;
var controller_mouse_bytes: [3]u8 = .{ 0, 0, 0 };
var controller_mouse_byte_count: u8 = 0;
var controller_configured: bool = false;

var last_processed_interrupt_seq: u32 = 0;

pub fn init() void {
    resetForTest();
    initController();
}

pub fn resetForTest() void {
    keyboard_state = .{
        .magic = abi.keyboard_magic,
        .api_version = abi.api_version,
        .connected = 1,
        .modifiers = 0,
        .queue_len = 0,
        .queue_overflow = 0,
        .event_count = 0,
        .key_down_count = 0,
        .key_up_count = 0,
        .last_scancode = 0,
        .last_pressed = 0,
        .reserved0 = .{ 0, 0 },
        .last_keycode = 0,
        .reserved1 = 0,
        .last_tick = 0,
    };
    @memset(&keyboard_events, std.mem.zeroes(abi.BaremetalKeyboardEvent));
    keyboard_head = 0;
    keyboard_count = 0;
    keyboard_seq = 0;

    mouse_state = .{
        .magic = abi.mouse_magic,
        .api_version = abi.api_version,
        .connected = 1,
        .reserved0 = 0,
        .queue_len = 0,
        .queue_overflow = 0,
        .packet_count = 0,
        .last_buttons = 0,
        .reserved1 = .{ 0, 0, 0 },
        .accum_x = 0,
        .accum_y = 0,
        .last_dx = 0,
        .last_dy = 0,
        .last_tick = 0,
    };
    @memset(&mouse_packets, std.mem.zeroes(abi.BaremetalMousePacket));
    mouse_head = 0;
    mouse_count = 0;
    mouse_seq = 0;

    @memset(&pending_keyboard, 0);
    pending_keyboard_head = 0;
    pending_keyboard_count = 0;
    @memset(&pending_mouse, .{ .buttons = 0, .dx = 0, .dy = 0 });
    pending_mouse_head = 0;
    pending_mouse_count = 0;
    controller_mouse_bytes = .{ 0, 0, 0 };
    controller_mouse_byte_count = 0;
    controller_configured = false;
    last_processed_interrupt_seq = 0;
}

pub fn keyboardStatePtr() *const abi.BaremetalKeyboardState {
    return &keyboard_state;
}

pub fn mouseStatePtr() *const abi.BaremetalMouseState {
    return &mouse_state;
}

pub fn keyboardEvent(index: u32) abi.BaremetalKeyboardEvent {
    if (index >= keyboard_count) return std.mem.zeroes(abi.BaremetalKeyboardEvent);
    const cap: u32 = @as(u32, keyboard_queue_capacity);
    const oldest = if (keyboard_count == cap) keyboard_head else 0;
    const pos = @mod(oldest + index, cap);
    return keyboard_events[pos];
}

pub fn mousePacket(index: u32) abi.BaremetalMousePacket {
    if (index >= mouse_count) return std.mem.zeroes(abi.BaremetalMousePacket);
    const cap: u32 = @as(u32, mouse_packet_capacity);
    const oldest = if (mouse_count == cap) mouse_head else 0;
    const pos = @mod(oldest + index, cap);
    return mouse_packets[pos];
}

pub fn injectKeyboardScancode(scancode: u8) void {
    queueKeyboardScancode(scancode);
}

pub fn injectMousePacket(buttons: u8, dx: i16, dy: i16) void {
    queueMousePacket(buttons, dx, dy);
}

fn isHardwareBacked() bool {
    return builtin.os.tag == .freestanding and builtin.cpu.arch == .x86_64;
}

fn readPort(port: u16) u8 {
    if (!isHardwareBacked()) return 0;
    return asm volatile ("inb %[dx], %[al]"
        : [al] "={al}" (-> u8),
        : [dx] "{dx}" (port),
        : "memory");
}

fn writePort(port: u16, value: u8) void {
    if (!isHardwareBacked()) return;
    asm volatile ("outb %[al], %[dx]"
        :
        : [dx] "{dx}" (port),
          [al] "{al}" (value),
        : "memory");
}

fn waitControllerInputClear() bool {
    if (!isHardwareBacked()) return false;
    var attempt: usize = 0;
    while (attempt < controller_wait_limit) : (attempt += 1) {
        if ((readPort(controller_status_port) & controller_status_input_full) == 0) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

fn waitControllerOutputReady() bool {
    if (!isHardwareBacked()) return false;
    var attempt: usize = 0;
    while (attempt < controller_wait_limit) : (attempt += 1) {
        if ((readPort(controller_status_port) & controller_status_output_full) != 0) return true;
        std.atomic.spinLoopHint();
    }
    return false;
}

fn queueKeyboardScancode(scancode: u8) void {
    const cap: u32 = @as(u32, controller_keyboard_capacity);
    const write_index = @mod(pending_keyboard_head + pending_keyboard_count, cap);
    pending_keyboard[write_index] = scancode;
    if (pending_keyboard_count < cap) {
        pending_keyboard_count += 1;
    } else {
        pending_keyboard_head = @mod(pending_keyboard_head + 1, cap);
    }
}

fn queueMousePacket(buttons: u8, dx: i16, dy: i16) void {
    const cap: u32 = @as(u32, controller_mouse_capacity);
    const write_index = @mod(pending_mouse_head + pending_mouse_count, cap);
    pending_mouse[write_index] = .{ .buttons = buttons, .dx = dx, .dy = dy };
    if (pending_mouse_count < cap) {
        pending_mouse_count += 1;
    } else {
        pending_mouse_head = @mod(pending_mouse_head + 1, cap);
    }
}

fn signExtendByte(raw: u8) i16 {
    return @as(i16, @intCast(@as(i8, @bitCast(raw))));
}

fn queueControllerMouseByte(raw: u8) void {
    if (controller_mouse_byte_count >= controller_mouse_bytes.len) {
        controller_mouse_byte_count = 0;
    }
    controller_mouse_bytes[controller_mouse_byte_count] = raw;
    controller_mouse_byte_count += 1;
    if (controller_mouse_byte_count == controller_mouse_bytes.len) {
        queueMousePacket(
            controller_mouse_bytes[0] & 0x07,
            signExtendByte(controller_mouse_bytes[1]),
            signExtendByte(controller_mouse_bytes[2]),
        );
        controller_mouse_byte_count = 0;
    }
}

fn drainControllerOutput() void {
    if (!isHardwareBacked()) return;
    var iteration: usize = 0;
    while (iteration < controller_drain_limit) : (iteration += 1) {
        const status = readPort(controller_status_port);
        if ((status & controller_status_output_full) == 0) break;
        const raw = readPort(controller_data_port);
        if ((status & controller_status_aux_data) != 0) {
            queueControllerMouseByte(raw);
        } else {
            queueKeyboardScancode(raw);
        }
    }
}

fn initController() void {
    if (!isHardwareBacked()) return;

    // Flush stale output before touching config so a previous boot does not leak bytes into this session.
    drainControllerOutput();

    if (!waitControllerInputClear()) return;
    writePort(controller_command_port, controller_command_enable_keyboard);
    if (!waitControllerInputClear()) return;
    writePort(controller_command_port, controller_command_enable_mouse);

    if (!waitControllerInputClear()) return;
    writePort(controller_command_port, controller_command_read_config);
    if (!waitControllerOutputReady()) return;
    var config = readPort(controller_data_port);
    config |= 0x03;
    config &= ~@as(u8, 0x30);

    if (!waitControllerInputClear()) return;
    writePort(controller_command_port, controller_command_write_config);
    if (!waitControllerInputClear()) return;
    writePort(controller_data_port, config);
    controller_configured = true;
}

pub fn processInterruptHistory(current_tick: u64) void {
    const len = x86_bootstrap.oc_interrupt_history_len();
    var idx: u32 = 0;
    while (idx < len) : (idx += 1) {
        const event = x86_bootstrap.oc_interrupt_history_event(idx);
        if (event.seq <= last_processed_interrupt_seq) continue;
        if (event.vector == keyboard_irq_vector) {
            processKeyboardInterrupt(event.seq, current_tick);
        } else if (event.vector == mouse_irq_vector) {
            processMouseInterrupt(event.seq, current_tick);
        }
        last_processed_interrupt_seq = event.seq;
    }
}

fn processKeyboardInterrupt(interrupt_seq: u32, current_tick: u64) void {
    drainControllerOutput();
    if (pending_keyboard_count == 0) return;
    const scancode = pending_keyboard[pending_keyboard_head];
    pending_keyboard_head = @mod(pending_keyboard_head + 1, @as(u32, controller_keyboard_capacity));
    pending_keyboard_count -= 1;

    const released = (scancode & 0x80) != 0;
    const base = scancode & 0x7F;
    updateModifierState(base, !released);
    const keycode = translateScancode(base, keyboard_state.modifiers);
    keyboard_seq +%= 1;
    keyboard_state.last_scancode = scancode;
    keyboard_state.last_pressed = if (released) 0 else 1;
    keyboard_state.last_keycode = keycode;
    keyboard_state.last_tick = current_tick;
    keyboard_state.event_count +%= 1;
    if (released) {
        keyboard_state.key_up_count +%= 1;
    } else {
        keyboard_state.key_down_count +%= 1;
    }

    const cap: u32 = @as(u32, keyboard_queue_capacity);
    const write_index = keyboard_head;
    keyboard_events[write_index] = .{
        .seq = keyboard_seq,
        .scancode = scancode,
        .pressed = if (released) 0 else 1,
        .modifiers = keyboard_state.modifiers,
        .reserved0 = 0,
        .keycode = keycode,
        .reserved1 = 0,
        .tick = current_tick,
        .interrupt_seq = interrupt_seq,
        .reserved2 = 0,
    };
    keyboard_head = @mod(keyboard_head + 1, cap);
    if (keyboard_count < cap) {
        keyboard_count += 1;
    } else {
        keyboard_state.queue_overflow +%= 1;
    }
    keyboard_state.queue_len = @as(u16, @intCast(keyboard_count));
}

fn processMouseInterrupt(interrupt_seq: u32, current_tick: u64) void {
    drainControllerOutput();
    if (pending_mouse_count == 0) return;
    const packet = pending_mouse[pending_mouse_head];
    pending_mouse_head = @mod(pending_mouse_head + 1, @as(u32, controller_mouse_capacity));
    pending_mouse_count -= 1;

    mouse_seq +%= 1;
    mouse_state.packet_count +%= 1;
    mouse_state.last_buttons = packet.buttons;
    mouse_state.accum_x += packet.dx;
    mouse_state.accum_y += packet.dy;
    mouse_state.last_dx = packet.dx;
    mouse_state.last_dy = packet.dy;
    mouse_state.last_tick = current_tick;

    const cap: u32 = @as(u32, mouse_packet_capacity);
    const write_index = mouse_head;
    mouse_packets[write_index] = .{
        .seq = mouse_seq,
        .buttons = packet.buttons,
        .reserved0 = 0,
        .dx = packet.dx,
        .dy = packet.dy,
        .tick = current_tick,
        .interrupt_seq = interrupt_seq,
    };
    mouse_head = @mod(mouse_head + 1, cap);
    if (mouse_count < cap) {
        mouse_count += 1;
    } else {
        mouse_state.queue_overflow +%= 1;
    }
    mouse_state.queue_len = @as(u16, @intCast(mouse_count));
}

fn updateModifierState(base: u8, pressed: bool) void {
    const bit: ?u8 = switch (base) {
        0x2A, 0x36 => abi.input_modifier_shift,
        0x1D => abi.input_modifier_ctrl,
        0x38 => abi.input_modifier_alt,
        else => null,
    };
    if (bit) |modifier_bit| {
        if (pressed) {
            keyboard_state.modifiers |= modifier_bit;
        } else {
            keyboard_state.modifiers &= ~modifier_bit;
        }
    }
}

fn translateScancode(base: u8, modifiers: u8) u16 {
    const shifted = (modifiers & abi.input_modifier_shift) != 0;
    return switch (base) {
        0x01 => 27,
        0x0E => 8,
        0x0F => 9,
        0x1C => 13,
        0x39 => ' ',
        0x02 => if (shifted) '!' else '1',
        0x03 => if (shifted) '@' else '2',
        0x04 => if (shifted) '#' else '3',
        0x05 => if (shifted) '$' else '4',
        0x06 => if (shifted) '%' else '5',
        0x07 => if (shifted) '^' else '6',
        0x08 => if (shifted) '&' else '7',
        0x09 => if (shifted) '*' else '8',
        0x0A => if (shifted) '(' else '9',
        0x0B => if (shifted) ')' else '0',
        0x10 => if (shifted) 'Q' else 'q',
        0x11 => if (shifted) 'W' else 'w',
        0x12 => if (shifted) 'E' else 'e',
        0x13 => if (shifted) 'R' else 'r',
        0x14 => if (shifted) 'T' else 't',
        0x15 => if (shifted) 'Y' else 'y',
        0x16 => if (shifted) 'U' else 'u',
        0x17 => if (shifted) 'I' else 'i',
        0x18 => if (shifted) 'O' else 'o',
        0x19 => if (shifted) 'P' else 'p',
        0x1E => if (shifted) 'A' else 'a',
        0x1F => if (shifted) 'S' else 's',
        0x20 => if (shifted) 'D' else 'd',
        0x21 => if (shifted) 'F' else 'f',
        0x22 => if (shifted) 'G' else 'g',
        0x23 => if (shifted) 'H' else 'h',
        0x24 => if (shifted) 'J' else 'j',
        0x25 => if (shifted) 'K' else 'k',
        0x26 => if (shifted) 'L' else 'l',
        0x2C => if (shifted) 'Z' else 'z',
        0x2D => if (shifted) 'X' else 'x',
        0x2E => if (shifted) 'C' else 'c',
        0x2F => if (shifted) 'V' else 'v',
        0x30 => if (shifted) 'B' else 'b',
        0x31 => if (shifted) 'N' else 'n',
        0x32 => if (shifted) 'M' else 'm',
        else => base,
    };
}

test "ps2 keyboard interrupt updates queue and modifier state" {
    resetForTest();
    x86_bootstrap.init();
    x86_bootstrap.oc_interrupt_history_clear();
    x86_bootstrap.oc_reset_interrupt_counters();

    injectKeyboardScancode(0x2A);
    x86_bootstrap.oc_trigger_interrupt(keyboard_irq_vector);
    processInterruptHistory(1);
    try std.testing.expectEqual(@as(u8, abi.input_modifier_shift), keyboard_state.modifiers);

    injectKeyboardScancode(0x1E);
    x86_bootstrap.oc_trigger_interrupt(keyboard_irq_vector);
    processInterruptHistory(2);

    try std.testing.expectEqual(@as(u32, 2), keyboard_state.event_count);
    try std.testing.expectEqual(@as(u16, 2), keyboard_state.queue_len);
    const evt = keyboardEvent(1);
    try std.testing.expectEqual(@as(u8, 0x1E), evt.scancode);
    try std.testing.expectEqual(@as(u8, 1), evt.pressed);
    try std.testing.expectEqual(@as(u16, 'A'), evt.keycode);
}

test "ps2 mouse interrupt updates packet queue and accumulators" {
    resetForTest();
    x86_bootstrap.init();
    x86_bootstrap.oc_interrupt_history_clear();
    x86_bootstrap.oc_reset_interrupt_counters();

    injectMousePacket(0x03, 4, -2);
    x86_bootstrap.oc_trigger_interrupt(mouse_irq_vector);
    processInterruptHistory(5);

    try std.testing.expectEqual(@as(u16, 1), mouse_state.queue_len);
    try std.testing.expectEqual(@as(i32, 4), mouse_state.accum_x);
    try std.testing.expectEqual(@as(i32, -2), mouse_state.accum_y);
    const pkt = mousePacket(0);
    try std.testing.expectEqual(@as(u8, 0x03), pkt.buttons);
    try std.testing.expectEqual(@as(i16, 4), pkt.dx);
    try std.testing.expectEqual(@as(i16, -2), pkt.dy);
}
