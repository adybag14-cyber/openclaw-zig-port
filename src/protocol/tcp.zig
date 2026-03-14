const std = @import("std");
const ipv4 = @import("ipv4.zig");

pub const header_len: usize = 20;
pub const header_words_no_options: u8 = 5;

pub const flag_fin: u16 = 0x001;
pub const flag_syn: u16 = 0x002;
pub const flag_rst: u16 = 0x004;
pub const flag_psh: u16 = 0x008;
pub const flag_ack: u16 = 0x010;
pub const flag_urg: u16 = 0x020;
pub const flag_ece: u16 = 0x040;
pub const flag_cwr: u16 = 0x080;
pub const flag_ns: u16 = 0x100;
pub const all_known_flags: u16 = 0x1FF;

pub const Error = error{
    BufferTooSmall,
    PacketTooShort,
    InvalidDataOffset,
    UnsupportedOptions,
    PayloadTooLarge,
    WindowExceeded,
    ChecksumMismatch,
    EmptyPayload,
    InvalidState,
    UnexpectedFlags,
    PortMismatch,
    SequenceMismatch,
    AcknowledgmentMismatch,
};

pub const Header = struct {
    source_port: u16,
    destination_port: u16,
    sequence_number: u32 = 0,
    acknowledgment_number: u32 = 0,
    flags: u16 = 0,
    window_size: u16 = 4096,
    urgent_pointer: u16 = 0,

    pub fn encode(
        self: Header,
        buffer: []u8,
        payload: []const u8,
        source_ip: [4]u8,
        destination_ip: [4]u8,
    ) Error!usize {
        const total_len = header_len + payload.len;
        if (buffer.len < total_len) return error.BufferTooSmall;
        if ((self.flags & ~all_known_flags) != 0) return error.InvalidDataOffset;

        writeU16Be(buffer[0..2], self.source_port);
        writeU16Be(buffer[2..4], self.destination_port);
        writeU32Be(buffer[4..8], self.sequence_number);
        writeU32Be(buffer[8..12], self.acknowledgment_number);
        buffer[12] = (header_words_no_options << 4) | @as(u8, @intCast((self.flags >> 8) & 0x01));
        buffer[13] = @as(u8, @truncate(self.flags));
        writeU16Be(buffer[14..16], self.window_size);
        buffer[16] = 0;
        buffer[17] = 0;
        writeU16Be(buffer[18..20], self.urgent_pointer);
        std.mem.copyForwards(u8, buffer[header_len..total_len], payload);

        writeU16Be(buffer[16..18], checksum(buffer[0..total_len], source_ip, destination_ip));
        return total_len;
    }
};

pub const Packet = struct {
    source_port: u16,
    destination_port: u16,
    sequence_number: u32,
    acknowledgment_number: u32,
    data_offset_bytes: usize,
    flags: u16,
    window_size: u16,
    checksum_value: u16,
    urgent_pointer: u16,
    payload: []const u8,
};

pub const Role = enum {
    client,
    server,
};

pub const State = enum {
    closed,
    listen,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    close_wait,
    last_ack,
};

pub const RetransmitKind = enum {
    none,
    syn,
    payload,
    fin,
};

pub const Outbound = struct {
    sequence_number: u32,
    acknowledgment_number: u32,
    flags: u16,
    window_size: u16,
    payload: []const u8 = "",
};

pub const RetransmitState = struct {
    kind: RetransmitKind = .none,
    timeout_ticks: u64 = 0,
    deadline_tick: u64 = 0,
    last_fire_tick: u64 = 0,
    fire_recorded: bool = false,
    attempts: u32 = 0,
    sequence_number: u32 = 0,
    acknowledgment_number: u32 = 0,
    flags: u16 = 0,
    window_size: u16 = 0,
    payload: []const u8 = "",

    pub fn armed(self: RetransmitState) bool {
        return self.kind != .none;
    }
};

pub const FlowKey = struct {
    local_ip: [4]u8,
    remote_ip: [4]u8,
    local_port: u16,
    remote_port: u16,

    pub fn eql(self: FlowKey, other: FlowKey) bool {
        return std.mem.eql(u8, self.local_ip[0..], other.local_ip[0..]) and
            std.mem.eql(u8, self.remote_ip[0..], other.remote_ip[0..]) and
            self.local_port == other.local_port and
            self.remote_port == other.remote_port;
    }

    pub fn matchesInboundPacket(self: FlowKey, source_ip: [4]u8, destination_ip: [4]u8, packet: Packet) bool {
        return std.mem.eql(u8, self.local_ip[0..], destination_ip[0..]) and
            std.mem.eql(u8, self.remote_ip[0..], source_ip[0..]) and
            self.local_port == packet.destination_port and
            self.remote_port == packet.source_port;
    }
};

pub const Session = struct {
    role: Role,
    state: State,
    local_port: u16,
    remote_port: u16,
    send_unacked: u32,
    send_next: u32,
    recv_next: u32 = 0,
    local_window: u16,
    remote_window: u16 = 0,
    retransmit: RetransmitState = .{},

    pub fn initClient(local_port: u16, remote_port: u16, initial_sequence_number: u32, window_size: u16) Session {
        return .{
            .role = .client,
            .state = .closed,
            .local_port = local_port,
            .remote_port = remote_port,
            .send_unacked = initial_sequence_number,
            .send_next = initial_sequence_number,
            .local_window = window_size,
        };
    }

    pub fn initServer(local_port: u16, remote_port: u16, initial_sequence_number: u32, window_size: u16) Session {
        return .{
            .role = .server,
            .state = .listen,
            .local_port = local_port,
            .remote_port = remote_port,
            .send_unacked = initial_sequence_number,
            .send_next = initial_sequence_number,
            .local_window = window_size,
        };
    }

    pub fn bytesInFlight(self: Session) u32 {
        return self.send_next -% self.send_unacked;
    }

    pub fn headerFor(self: Session, outbound: Outbound) Header {
        return .{
            .source_port = self.local_port,
            .destination_port = self.remote_port,
            .sequence_number = outbound.sequence_number,
            .acknowledgment_number = outbound.acknowledgment_number,
            .flags = outbound.flags,
            .window_size = outbound.window_size,
        };
    }

    pub fn buildSyn(self: *Session) Error!Outbound {
        if (self.role != .client or self.state != .closed) return error.InvalidState;

        const outbound = Outbound{
            .sequence_number = self.send_next,
            .acknowledgment_number = 0,
            .flags = flag_syn,
            .window_size = self.local_window,
        };
        self.send_next +%= 1;
        self.state = .syn_sent;
        return outbound;
    }

    pub fn buildSynWithTimeout(self: *Session, now_tick: u64, timeout_ticks: u64) Error!Outbound {
        const outbound = try self.buildSyn();
        self.armRetransmit(.syn, outbound, now_tick, timeout_ticks);
        return outbound;
    }

    pub fn pollRetransmit(self: *Session, now_tick: u64) ?Outbound {
        if (!self.retransmit.armed()) return null;
        switch (self.retransmit.kind) {
            .none => return null,
            .syn => {
                if (self.state != .syn_sent) {
                    self.clearRetransmit();
                    return null;
                }
            },
            .payload => {
                if (self.state != .established) {
                    self.clearRetransmit();
                    return null;
                }
            },
            .fin => switch (self.state) {
                .fin_wait_1, .last_ack => {},
                else => {
                    self.clearRetransmit();
                    return null;
                },
            },
        }
        if (now_tick < self.retransmit.deadline_tick) return null;
        if (self.retransmit.fire_recorded and self.retransmit.last_fire_tick == now_tick) return null;

        self.retransmit.attempts +%= 1;
        self.retransmit.last_fire_tick = now_tick;
        self.retransmit.fire_recorded = true;
        self.retransmit.deadline_tick = addTicksSaturating(now_tick, self.retransmit.timeout_ticks);
        return .{
            .sequence_number = self.retransmit.sequence_number,
            .acknowledgment_number = self.retransmit.acknowledgment_number,
            .flags = self.retransmit.flags,
            .window_size = self.retransmit.window_size,
            .payload = self.retransmit.payload,
        };
    }

    pub fn acceptSyn(self: *Session, packet: Packet) Error!Outbound {
        if (self.role != .server or self.state != .listen) return error.InvalidState;
        try self.validatePorts(packet);
        if (packet.flags != flag_syn or packet.payload.len != 0) return error.UnexpectedFlags;

        self.recv_next = packet.sequence_number +% 1;
        self.remote_window = packet.window_size;
        const outbound = Outbound{
            .sequence_number = self.send_next,
            .acknowledgment_number = self.recv_next,
            .flags = flag_syn | flag_ack,
            .window_size = self.local_window,
        };
        self.send_next +%= 1;
        self.state = .syn_received;
        return outbound;
    }

    pub fn acceptSynAck(self: *Session, packet: Packet) Error!Outbound {
        if (self.role != .client or self.state != .syn_sent) return error.InvalidState;
        try self.validatePorts(packet);
        if (packet.flags != (flag_syn | flag_ack) or packet.payload.len != 0) return error.UnexpectedFlags;
        if (packet.acknowledgment_number != self.send_next) return error.AcknowledgmentMismatch;

        self.recv_next = packet.sequence_number +% 1;
        self.remote_window = packet.window_size;
        self.state = .established;
        self.send_unacked = self.send_next;
        self.clearRetransmit();
        return .{
            .sequence_number = self.send_next,
            .acknowledgment_number = self.recv_next,
            .flags = flag_ack,
            .window_size = self.local_window,
        };
    }

    pub fn acceptAck(self: *Session, packet: Packet) Error!void {
        try self.validatePorts(packet);
        if (packet.flags != flag_ack or packet.payload.len != 0) return error.UnexpectedFlags;
        if (packet.sequence_number != self.recv_next) return error.SequenceMismatch;
        if (packet.acknowledgment_number != self.send_next) return error.AcknowledgmentMismatch;

        self.remote_window = packet.window_size;
        switch (self.state) {
            .syn_received => {
                self.state = .established;
                self.send_unacked = self.send_next;
            },
            .established => {
                try self.acceptEstablishedAck(packet.acknowledgment_number);
                if (self.retransmit.kind == .payload and self.send_unacked == self.send_next) {
                    self.clearRetransmit();
                }
            },
            .fin_wait_1 => {
                self.state = .fin_wait_2;
                self.send_unacked = packet.acknowledgment_number;
                self.clearRetransmit();
            },
            .last_ack => {
                self.state = .closed;
                self.send_unacked = packet.acknowledgment_number;
                self.clearRetransmit();
            },
            else => return error.InvalidState,
        }
    }

    pub fn buildFin(self: *Session) Error!Outbound {
        if (self.retransmit.armed()) return error.InvalidState;

        const next_state = switch (self.state) {
            .established => State.fin_wait_1,
            .close_wait => State.last_ack,
            else => return error.InvalidState,
        };

        const outbound = Outbound{
            .sequence_number = self.send_next,
            .acknowledgment_number = self.recv_next,
            .flags = flag_fin | flag_ack,
            .window_size = self.local_window,
        };
        self.send_next +%= 1;
        self.state = next_state;
        return outbound;
    }

    pub fn buildFinWithTimeout(self: *Session, now_tick: u64, timeout_ticks: u64) Error!Outbound {
        const outbound = try self.buildFin();
        self.armRetransmit(.fin, outbound, now_tick, timeout_ticks);
        return outbound;
    }

    pub fn buildAck(self: *Session) Error!Outbound {
        if (self.state != .established) return error.InvalidState;

        return .{
            .sequence_number = self.send_next,
            .acknowledgment_number = self.recv_next,
            .flags = flag_ack,
            .window_size = self.local_window,
        };
    }

    pub fn buildPayload(self: *Session, payload: []const u8) Error!Outbound {
        return self.buildPayloadInternal(payload);
    }

    pub fn buildPayloadChunk(self: *Session, payload: []const u8) Error!Outbound {
        if (self.state != .established) return error.InvalidState;
        if (payload.len == 0) return error.EmptyPayload;
        const available_window = self.availableRemoteWindow();
        if (available_window == 0) return error.WindowExceeded;

        const chunk_len: usize = @min(payload.len, available_window);
        return self.buildPayloadInternal(payload[0..chunk_len]);
    }

    pub fn buildPayloadWithTimeout(self: *Session, payload: []const u8, now_tick: u64, timeout_ticks: u64) Error!Outbound {
        if (self.retransmit.armed()) return error.InvalidState;

        const outbound = try self.buildPayloadInternal(payload);
        self.armRetransmit(.payload, outbound, now_tick, timeout_ticks);
        return outbound;
    }

    fn buildPayloadInternal(self: *Session, payload: []const u8) Error!Outbound {
        if (self.state != .established) return error.InvalidState;
        if (payload.len == 0) return error.EmptyPayload;
        if (payload.len > self.availableRemoteWindow()) return error.WindowExceeded;

        const outbound = Outbound{
            .sequence_number = self.send_next,
            .acknowledgment_number = self.recv_next,
            .flags = flag_ack | flag_psh,
            .window_size = self.local_window,
            .payload = payload,
        };
        self.send_next +%= @as(u32, @intCast(payload.len));
        return outbound;
    }

    fn availableRemoteWindow(self: Session) usize {
        const in_flight = self.bytesInFlight();
        if (in_flight >= self.remote_window) return 0;
        return @as(usize, self.remote_window - @as(u16, @intCast(in_flight)));
    }

    fn acceptEstablishedAck(self: *Session, acknowledgment_number: u32) Error!void {
        const acknowledged_bytes = acknowledgment_number -% self.send_unacked;
        const bytes_in_flight = self.send_next -% self.send_unacked;
        if (acknowledged_bytes > bytes_in_flight) return error.AcknowledgmentMismatch;
        self.send_unacked = acknowledgment_number;
    }

    pub fn acceptFin(self: *Session, packet: Packet) Error!Outbound {
        try self.validatePorts(packet);
        if (packet.flags != (flag_fin | flag_ack) or packet.payload.len != 0) return error.UnexpectedFlags;
        if (packet.sequence_number != self.recv_next) return error.SequenceMismatch;
        if (packet.acknowledgment_number != self.send_next) return error.AcknowledgmentMismatch;

        self.remote_window = packet.window_size;
        self.recv_next +%= 1;
        self.state = switch (self.state) {
            .established => .close_wait,
            .fin_wait_1, .fin_wait_2 => .closed,
            else => return error.InvalidState,
        };
        return .{
            .sequence_number = self.send_next,
            .acknowledgment_number = self.recv_next,
            .flags = flag_ack,
            .window_size = self.local_window,
        };
    }

    pub fn acceptPayload(self: *Session, packet: Packet) Error!void {
        if (self.state != .established) return error.InvalidState;
        try self.validatePorts(packet);
        if (packet.flags != (flag_ack | flag_psh) or packet.payload.len == 0) return error.UnexpectedFlags;
        if (packet.sequence_number != self.recv_next) return error.SequenceMismatch;
        if (packet.acknowledgment_number != self.send_next) return error.AcknowledgmentMismatch;

        self.remote_window = packet.window_size;
        self.recv_next +%= @as(u32, @intCast(packet.payload.len));
    }

    fn validatePorts(self: Session, packet: Packet) Error!void {
        if (packet.source_port != self.remote_port or packet.destination_port != self.local_port) {
            return error.PortMismatch;
        }
    }

    fn armRetransmit(self: *Session, kind: RetransmitKind, outbound: Outbound, now_tick: u64, timeout_ticks: u64) void {
        const effective_timeout = if (timeout_ticks == 0) @as(u64, 1) else timeout_ticks;
        self.retransmit = .{
            .kind = kind,
            .timeout_ticks = effective_timeout,
            .deadline_tick = addTicksSaturating(now_tick, effective_timeout),
            .last_fire_tick = 0,
            .fire_recorded = false,
            .attempts = 0,
            .sequence_number = outbound.sequence_number,
            .acknowledgment_number = outbound.acknowledgment_number,
            .flags = outbound.flags,
            .window_size = outbound.window_size,
            .payload = outbound.payload,
        };
    }

    fn clearRetransmit(self: *Session) void {
        self.retransmit = .{};
    }
};

pub const SessionTableError = error{
    NoSpace,
    AlreadyExists,
};

pub fn SessionTable(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Slot = struct {
            in_use: bool = false,
            key: FlowKey = .{
                .local_ip = [_]u8{ 0, 0, 0, 0 },
                .remote_ip = [_]u8{ 0, 0, 0, 0 },
                .local_port = 0,
                .remote_port = 0,
            },
            session: Session = Session.initClient(0, 0, 0, 0),
        };

        slots: [capacity]Slot = [_]Slot{.{}} ** capacity,

        pub fn init() Self {
            return .{};
        }

        pub fn reset(self: *Self) void {
            self.* = .{};
        }

        pub fn entryCount(self: *const Self) usize {
            var count: usize = 0;
            for (self.slots) |slot| {
                if (slot.in_use) count += 1;
            }
            return count;
        }

        pub fn createClient(
            self: *Self,
            key: FlowKey,
            initial_sequence_number: u32,
            window_size: u16,
        ) SessionTableError!*Session {
            return self.insert(key, Session.initClient(key.local_port, key.remote_port, initial_sequence_number, window_size));
        }

        pub fn createServer(
            self: *Self,
            key: FlowKey,
            initial_sequence_number: u32,
            window_size: u16,
        ) SessionTableError!*Session {
            return self.insert(key, Session.initServer(key.local_port, key.remote_port, initial_sequence_number, window_size));
        }

        pub fn find(self: *Self, key: FlowKey) ?*Session {
            for (&self.slots) |*slot| {
                if (slot.in_use and slot.key.eql(key)) return &slot.session;
            }
            return null;
        }

        pub fn findConst(self: *const Self, key: FlowKey) ?*const Session {
            for (&self.slots) |*slot| {
                if (slot.in_use and slot.key.eql(key)) return &slot.session;
            }
            return null;
        }

        pub fn findByInboundPacket(
            self: *Self,
            source_ip: [4]u8,
            destination_ip: [4]u8,
            packet: Packet,
        ) ?*Session {
            for (&self.slots) |*slot| {
                if (!slot.in_use or slot.session.state == .closed) continue;
                if (slot.key.matchesInboundPacket(source_ip, destination_ip, packet)) return &slot.session;
            }
            return null;
        }

        pub fn release(self: *Self, key: FlowKey) bool {
            for (&self.slots) |*slot| {
                if (slot.in_use and slot.key.eql(key)) {
                    slot.* = .{};
                    return true;
                }
            }
            return false;
        }

        fn insert(self: *Self, key: FlowKey, session: Session) SessionTableError!*Session {
            var free_slot: ?*Slot = null;

            for (&self.slots) |*slot| {
                if (slot.in_use) {
                    if (slot.key.eql(key)) {
                        return error.AlreadyExists;
                    }
                } else if (free_slot == null) {
                    free_slot = slot;
                }
            }

            const target = free_slot orelse return error.NoSpace;
            target.* = .{
                .in_use = true,
                .key = key,
                .session = session,
            };
            return &target.session;
        }
    };
}

pub fn encodeOutboundSegment(
    session: Session,
    outbound: Outbound,
    buffer: []u8,
    source_ip: [4]u8,
    destination_ip: [4]u8,
) Error!usize {
    return try session.headerFor(outbound).encode(buffer, outbound.payload, source_ip, destination_ip);
}

pub fn decode(packet: []const u8, source_ip: [4]u8, destination_ip: [4]u8) Error!Packet {
    if (packet.len < header_len) return error.PacketTooShort;

    const data_offset_words = packet[12] >> 4;
    if (data_offset_words < header_words_no_options) return error.InvalidDataOffset;
    if (data_offset_words != header_words_no_options) return error.UnsupportedOptions;

    const actual_header_len = @as(usize, data_offset_words) * 4;
    if (packet.len < actual_header_len) return error.PacketTooShort;

    if (checksum(packet, source_ip, destination_ip) != 0) {
        return error.ChecksumMismatch;
    }

    return .{
        .source_port = readU16Be(packet[0..2]),
        .destination_port = readU16Be(packet[2..4]),
        .sequence_number = readU32Be(packet[4..8]),
        .acknowledgment_number = readU32Be(packet[8..12]),
        .data_offset_bytes = actual_header_len,
        .flags = ((@as(u16, packet[12]) & 0x01) << 8) | @as(u16, packet[13]),
        .window_size = readU16Be(packet[14..16]),
        .checksum_value = readU16Be(packet[16..18]),
        .urgent_pointer = readU16Be(packet[18..20]),
        .payload = packet[actual_header_len..],
    };
}

pub fn checksum(segment: []const u8, source_ip: [4]u8, destination_ip: [4]u8) u16 {
    var sum: u32 = 0;

    sum +%= readU16Be(source_ip[0..2]);
    sum +%= readU16Be(source_ip[2..4]);
    sum +%= readU16Be(destination_ip[0..2]);
    sum +%= readU16Be(destination_ip[2..4]);
    sum +%= ipv4.protocol_tcp;
    sum +%= std.math.cast(u16, segment.len) orelse 0;

    var index: usize = 0;
    while (index + 1 < segment.len) : (index += 2) {
        sum +%= readU16Be(segment[index .. index + 2]);
    }
    if (index < segment.len) {
        sum +%= @as(u16, segment[index]) << 8;
    }

    while ((sum >> 16) != 0) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return ~@as(u16, @truncate(sum));
}

fn addTicksSaturating(base: u64, delta: u64) u64 {
    const sum, const overflowed = @addWithOverflow(base, delta);
    return if (overflowed != 0) std.math.maxInt(u64) else sum;
}

fn writeU16Be(bytes: []u8, value: u16) void {
    bytes[0] = @as(u8, @intCast(value >> 8));
    bytes[1] = @as(u8, @truncate(value));
}

fn writeU32Be(bytes: []u8, value: u32) void {
    bytes[0] = @as(u8, @intCast(value >> 24));
    bytes[1] = @as(u8, @truncate(value >> 16));
    bytes[2] = @as(u8, @truncate(value >> 8));
    bytes[3] = @as(u8, @truncate(value));
}

fn readU16Be(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

fn readU32Be(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

test "tcp encodes and decodes packet with checksum" {
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-TCP";
    const header = Header{
        .source_port = 4321,
        .destination_port = 443,
        .sequence_number = 0x0102_0304,
        .acknowledgment_number = 0xA0B0_C0D0,
        .flags = flag_ack | flag_psh,
        .window_size = 8192,
    };

    var segment: [header_len + payload.len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, header_len + payload.len), try header.encode(segment[0..], payload, source_ip, destination_ip));

    const decoded = try decode(segment[0..], source_ip, destination_ip);
    try std.testing.expectEqual(@as(u16, 4321), decoded.source_port);
    try std.testing.expectEqual(@as(u16, 443), decoded.destination_port);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), decoded.sequence_number);
    try std.testing.expectEqual(@as(u32, 0xA0B0_C0D0), decoded.acknowledgment_number);
    try std.testing.expectEqual(flag_ack | flag_psh, decoded.flags);
    try std.testing.expectEqual(@as(u16, 8192), decoded.window_size);
    try std.testing.expectEqual(@as(usize, header_len), decoded.data_offset_bytes);
    try std.testing.expectEqualSlices(u8, payload, decoded.payload);
}

test "tcp rejects checksum mismatch" {
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-TCP";
    const header = Header{
        .source_port = 4321,
        .destination_port = 443,
        .flags = flag_syn,
    };

    var segment: [header_len + payload.len]u8 = undefined;
    _ = try header.encode(segment[0..], payload, source_ip, destination_ip);
    segment[header_len] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, decode(segment[0..], source_ip, destination_ip));
}

test "tcp rejects invalid data offset" {
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "DATA";
    const header = Header{
        .source_port = 1000,
        .destination_port = 2000,
        .flags = flag_ack,
    };

    var segment: [header_len + payload.len]u8 = undefined;
    _ = try header.encode(segment[0..], payload, source_ip, destination_ip);
    segment[12] = 0x40;
    writeU16Be(segment[16..18], 0);
    writeU16Be(segment[16..18], checksum(segment[0..], source_ip, destination_ip));
    try std.testing.expectError(error.InvalidDataOffset, decode(segment[0..], source_ip, destination_ip));
}

test "tcp rejects unsupported options in strict slice" {
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "DATA";
    const header = Header{
        .source_port = 1000,
        .destination_port = 2000,
        .flags = flag_ack,
    };

    var segment: [header_len + 4 + payload.len]u8 = [_]u8{0} ** (header_len + 4 + payload.len);
    _ = try header.encode(segment[0 .. header_len + payload.len], payload, source_ip, destination_ip);
    std.mem.copyBackwards(u8, segment[header_len + 4 .. header_len + 4 + payload.len], segment[header_len .. header_len + payload.len]);
    @memset(segment[header_len .. header_len + 4], 0);
    segment[12] = 0x60;
    writeU16Be(segment[16..18], 0);
    writeU16Be(segment[16..18], checksum(segment[0..], source_ip, destination_ip));
    try std.testing.expectError(error.UnsupportedOptions, decode(segment[0..], source_ip, destination_ip));
}

test "tcp session completes handshake and payload exchange" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-TCP-HANDSHAKE";

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    var syn_segment: [header_len]u8 = undefined;
    const syn = try client.buildSyn();
    const syn_len = try encodeOutboundSegment(client, syn, syn_segment[0..], client_ip, server_ip);
    const syn_packet = try decode(syn_segment[0..syn_len], client_ip, server_ip);
    const syn_ack = try server.acceptSyn(syn_packet);
    try std.testing.expectEqual(State.syn_sent, client.state);
    try std.testing.expectEqual(State.syn_received, server.state);

    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_len = try encodeOutboundSegment(server, syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);
    const ack = try client.acceptSynAck(syn_ack_packet);
    try std.testing.expectEqual(State.established, client.state);

    var ack_segment: [header_len]u8 = undefined;
    const ack_len = try encodeOutboundSegment(client, ack, ack_segment[0..], client_ip, server_ip);
    const ack_packet = try decode(ack_segment[0..ack_len], client_ip, server_ip);
    try server.acceptAck(ack_packet);
    try std.testing.expectEqual(State.established, server.state);

    var payload_segment: [header_len + payload.len]u8 = undefined;
    const data = try client.buildPayload(payload);
    const data_len = try encodeOutboundSegment(client, data, payload_segment[0..], client_ip, server_ip);
    const data_packet = try decode(payload_segment[0..data_len], client_ip, server_ip);
    try server.acceptPayload(data_packet);

    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), client.send_next);
    try std.testing.expectEqual(@as(u32, 0xA0B0_C0D1), client.recv_next);
    try std.testing.expectEqual(@as(u32, 0xA0B0_C0D1), server.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), server.recv_next);
    try std.testing.expectEqual(@as(u16, 4096), server.remote_window);
}

test "tcp session rejects synack with mismatched acknowledgment number" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    _ = try client.buildSyn();

    const bad_syn_ack = Outbound{
        .sequence_number = 0xA0B0_C0D0,
        .acknowledgment_number = client.send_next +% 1,
        .flags = flag_syn | flag_ack,
        .window_size = 8192,
    };
    var syn_ack_segment: [header_len]u8 = undefined;
    const server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);
    const syn_ack_len = try encodeOutboundSegment(server, bad_syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);

    try std.testing.expectError(error.AcknowledgmentMismatch, client.acceptSynAck(syn_ack_packet));
}

test "tcp session retransmits client syn after timeout and clears timer on synack" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    const syn = try client.buildSynWithTimeout(100, 5);
    try std.testing.expectEqual(State.syn_sent, client.state);
    try std.testing.expect(client.retransmit.armed());
    try std.testing.expectEqual(RetransmitKind.syn, client.retransmit.kind);
    try std.testing.expectEqual(@as(u64, 105), client.retransmit.deadline_tick);
    try std.testing.expectEqual(@as(u32, 0), client.retransmit.attempts);
    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(104));

    const retry = client.pollRetransmit(105).?;
    try std.testing.expectEqual(syn.sequence_number, retry.sequence_number);
    try std.testing.expectEqual(syn.acknowledgment_number, retry.acknowledgment_number);
    try std.testing.expectEqual(syn.flags, retry.flags);
    try std.testing.expectEqual(syn.window_size, retry.window_size);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    try std.testing.expectEqual(@as(u64, 110), client.retransmit.deadline_tick);

    var retry_segment: [header_len]u8 = undefined;
    const retry_len = try encodeOutboundSegment(client, retry, retry_segment[0..], client_ip, server_ip);
    const retry_packet = try decode(retry_segment[0..retry_len], client_ip, server_ip);
    const syn_ack = try server.acceptSyn(retry_packet);

    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_len = try encodeOutboundSegment(server, syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);
    _ = try client.acceptSynAck(syn_ack_packet);

    try std.testing.expectEqual(State.established, client.state);
    try std.testing.expectEqual(State.syn_received, server.state);
    try std.testing.expect(!client.retransmit.armed());
}

test "tcp session retransmit timeout clamps zero and does not double fire on one tick" {
    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);

    const syn = try client.buildSynWithTimeout(40, 0);
    try std.testing.expectEqual(@as(u64, 1), client.retransmit.timeout_ticks);
    try std.testing.expectEqual(@as(u64, 41), client.retransmit.deadline_tick);
    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(40));

    const first_retry = client.pollRetransmit(41).?;
    try std.testing.expectEqual(syn.sequence_number, first_retry.sequence_number);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(41));

    const second_retry = client.pollRetransmit(42).?;
    try std.testing.expectEqual(syn.sequence_number, second_retry.sequence_number);
    try std.testing.expectEqual(@as(u32, 2), client.retransmit.attempts);
}

test "tcp session retransmits established payload after timeout and clears timer on ack" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-TCP-PAYLOAD-RETRY";

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    const syn = try client.buildSyn();
    var syn_segment: [header_len]u8 = undefined;
    const syn_len = try encodeOutboundSegment(client, syn, syn_segment[0..], client_ip, server_ip);
    const syn_packet = try decode(syn_segment[0..syn_len], client_ip, server_ip);
    const syn_ack = try server.acceptSyn(syn_packet);

    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_len = try encodeOutboundSegment(server, syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);
    const ack = try client.acceptSynAck(syn_ack_packet);

    var ack_segment: [header_len]u8 = undefined;
    const ack_len = try encodeOutboundSegment(client, ack, ack_segment[0..], client_ip, server_ip);
    const ack_packet = try decode(ack_segment[0..ack_len], client_ip, server_ip);
    try server.acceptAck(ack_packet);

    const data = try client.buildPayloadWithTimeout(payload, 200, 5);
    try std.testing.expect(client.retransmit.armed());
    try std.testing.expectEqual(RetransmitKind.payload, client.retransmit.kind);
    try std.testing.expectEqual(@as(u64, 205), client.retransmit.deadline_tick);
    try std.testing.expectEqualStrings(payload, client.retransmit.payload);
    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(204));

    const retry = client.pollRetransmit(205).?;
    try std.testing.expectEqual(data.sequence_number, retry.sequence_number);
    try std.testing.expectEqual(data.acknowledgment_number, retry.acknowledgment_number);
    try std.testing.expectEqual(data.flags, retry.flags);
    try std.testing.expectEqual(data.window_size, retry.window_size);
    try std.testing.expectEqualStrings(payload, retry.payload);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    try std.testing.expectEqual(@as(u64, 210), client.retransmit.deadline_tick);

    var retry_segment: [header_len + payload.len]u8 = undefined;
    const retry_len = try encodeOutboundSegment(client, retry, retry_segment[0..], client_ip, server_ip);
    const retry_packet = try decode(retry_segment[0..retry_len], client_ip, server_ip);
    try server.acceptPayload(retry_packet);

    const payload_ack = try server.buildAck();
    var payload_ack_segment: [header_len]u8 = undefined;
    const payload_ack_len = try encodeOutboundSegment(server, payload_ack, payload_ack_segment[0..], server_ip, client_ip);
    const payload_ack_packet = try decode(payload_ack_segment[0..payload_ack_len], server_ip, client_ip);
    try client.acceptAck(payload_ack_packet);

    try std.testing.expectEqual(State.established, client.state);
    try std.testing.expectEqual(State.established, server.state);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), client.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), server.recv_next);
    try std.testing.expect(!client.retransmit.armed());
}

test "tcp session payload retransmit timeout clamps zero and does not double fire on one tick" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "PING";

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    const syn = try client.buildSyn();
    var syn_segment: [header_len]u8 = undefined;
    const syn_len = try encodeOutboundSegment(client, syn, syn_segment[0..], client_ip, server_ip);
    const syn_packet = try decode(syn_segment[0..syn_len], client_ip, server_ip);
    const syn_ack = try server.acceptSyn(syn_packet);

    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_len = try encodeOutboundSegment(server, syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);
    const ack = try client.acceptSynAck(syn_ack_packet);

    var ack_segment: [header_len]u8 = undefined;
    const ack_len = try encodeOutboundSegment(client, ack, ack_segment[0..], client_ip, server_ip);
    const ack_packet = try decode(ack_segment[0..ack_len], client_ip, server_ip);
    try server.acceptAck(ack_packet);

    const data = try client.buildPayloadWithTimeout(payload, 40, 0);
    try std.testing.expectEqual(@as(u64, 1), client.retransmit.timeout_ticks);
    try std.testing.expectEqual(@as(u64, 41), client.retransmit.deadline_tick);
    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(40));

    const first_retry = client.pollRetransmit(41).?;
    try std.testing.expectEqual(data.sequence_number, first_retry.sequence_number);
    try std.testing.expectEqualStrings(payload, first_retry.payload);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(41));

    const second_retry = client.pollRetransmit(42).?;
    try std.testing.expectEqual(data.sequence_number, second_retry.sequence_number);
    try std.testing.expectEqualStrings(payload, second_retry.payload);
    try std.testing.expectEqual(@as(u32, 2), client.retransmit.attempts);
}

test "tcp session retransmits client fin after timeout and clears timer on fin ack" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    var syn_segment: [header_len]u8 = undefined;
    const syn = try client.buildSyn();
    const syn_packet = try testDecodeOutbound(client, syn, client_ip, server_ip, syn_segment[0..]);

    const syn_ack = try server.acceptSyn(syn_packet);
    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_packet = try testDecodeOutbound(server, syn_ack, server_ip, client_ip, syn_ack_segment[0..]);

    const ack = try client.acceptSynAck(syn_ack_packet);
    var ack_segment: [header_len]u8 = undefined;
    const ack_packet = try testDecodeOutbound(client, ack, client_ip, server_ip, ack_segment[0..]);
    try server.acceptAck(ack_packet);

    const client_fin = try client.buildFinWithTimeout(100, 5);
    try std.testing.expectEqual(State.fin_wait_1, client.state);
    try std.testing.expect(client.retransmit.armed());
    try std.testing.expectEqual(RetransmitKind.fin, client.retransmit.kind);
    try std.testing.expectEqual(@as(u64, 105), client.retransmit.deadline_tick);
    try std.testing.expectEqual(@as(u32, 0), client.retransmit.attempts);

    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(104));

    const retry_fin = client.pollRetransmit(105) orelse unreachable;
    try std.testing.expectEqual(client_fin.sequence_number, retry_fin.sequence_number);
    try std.testing.expectEqual(client_fin.acknowledgment_number, retry_fin.acknowledgment_number);
    try std.testing.expectEqual(client_fin.flags, retry_fin.flags);
    try std.testing.expectEqual(client_fin.window_size, retry_fin.window_size);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    try std.testing.expectEqual(@as(u64, 110), client.retransmit.deadline_tick);

    var retry_fin_segment: [header_len]u8 = undefined;
    const retry_fin_packet = try testDecodeOutbound(client, retry_fin, client_ip, server_ip, retry_fin_segment[0..]);
    const fin_ack = try server.acceptFin(retry_fin_packet);
    try std.testing.expectEqual(State.close_wait, server.state);

    var fin_ack_segment: [header_len]u8 = undefined;
    const fin_ack_packet = try testDecodeOutbound(server, fin_ack, server_ip, client_ip, fin_ack_segment[0..]);
    try client.acceptAck(fin_ack_packet);

    try std.testing.expectEqual(State.fin_wait_2, client.state);
    try std.testing.expect(!client.retransmit.armed());
}

test "tcp session fin retransmit timeout clamps zero and does not double fire on one tick" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    var syn_segment: [header_len]u8 = undefined;
    const syn = try client.buildSyn();
    const syn_packet = try testDecodeOutbound(client, syn, client_ip, server_ip, syn_segment[0..]);

    const syn_ack = try server.acceptSyn(syn_packet);
    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_packet = try testDecodeOutbound(server, syn_ack, server_ip, client_ip, syn_ack_segment[0..]);

    const ack = try client.acceptSynAck(syn_ack_packet);
    var ack_segment: [header_len]u8 = undefined;
    const ack_packet = try testDecodeOutbound(client, ack, client_ip, server_ip, ack_segment[0..]);
    try server.acceptAck(ack_packet);

    _ = try client.buildFinWithTimeout(40, 0);
    try std.testing.expectEqual(@as(u64, 1), client.retransmit.timeout_ticks);
    try std.testing.expectEqual(@as(u64, 41), client.retransmit.deadline_tick);

    const retry1 = client.pollRetransmit(41) orelse unreachable;
    try std.testing.expectEqual(flag_fin | flag_ack, retry1.flags);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    try std.testing.expectEqual(@as(?Outbound, null), client.pollRetransmit(41));

    const retry2 = client.pollRetransmit(42) orelse unreachable;
    try std.testing.expectEqual(retry1.sequence_number, retry2.sequence_number);
    try std.testing.expectEqual(@as(u32, 2), client.retransmit.attempts);
}

test "tcp session retransmits responder fin after timeout and clears timer on final ack" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    var syn_segment: [header_len]u8 = undefined;
    const syn = try client.buildSyn();
    const syn_packet = try testDecodeOutbound(client, syn, client_ip, server_ip, syn_segment[0..]);

    const syn_ack = try server.acceptSyn(syn_packet);
    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_packet = try testDecodeOutbound(server, syn_ack, server_ip, client_ip, syn_ack_segment[0..]);

    const ack = try client.acceptSynAck(syn_ack_packet);
    var ack_segment: [header_len]u8 = undefined;
    const ack_packet = try testDecodeOutbound(client, ack, client_ip, server_ip, ack_segment[0..]);
    try server.acceptAck(ack_packet);

    const client_fin = try client.buildFin();
    var client_fin_segment: [header_len]u8 = undefined;
    const client_fin_packet = try testDecodeOutbound(client, client_fin, client_ip, server_ip, client_fin_segment[0..]);
    const fin_ack = try server.acceptFin(client_fin_packet);

    var fin_ack_segment: [header_len]u8 = undefined;
    const fin_ack_packet = try testDecodeOutbound(server, fin_ack, server_ip, client_ip, fin_ack_segment[0..]);
    try client.acceptAck(fin_ack_packet);

    const server_fin = try server.buildFinWithTimeout(200, 5);
    try std.testing.expectEqual(State.last_ack, server.state);
    try std.testing.expect(server.retransmit.armed());
    try std.testing.expectEqual(RetransmitKind.fin, server.retransmit.kind);
    try std.testing.expectEqual(@as(u64, 205), server.retransmit.deadline_tick);

    try std.testing.expectEqual(@as(?Outbound, null), server.pollRetransmit(204));

    const retry_fin = server.pollRetransmit(205) orelse unreachable;
    try std.testing.expectEqual(server_fin.sequence_number, retry_fin.sequence_number);
    try std.testing.expectEqual(server_fin.acknowledgment_number, retry_fin.acknowledgment_number);
    try std.testing.expectEqual(server_fin.flags, retry_fin.flags);
    try std.testing.expectEqual(server_fin.window_size, retry_fin.window_size);
    try std.testing.expectEqual(@as(u32, 1), server.retransmit.attempts);
    try std.testing.expectEqual(@as(u64, 210), server.retransmit.deadline_tick);

    var retry_fin_segment: [header_len]u8 = undefined;
    const retry_fin_packet = try testDecodeOutbound(server, retry_fin, server_ip, client_ip, retry_fin_segment[0..]);
    const final_ack = try client.acceptFin(retry_fin_packet);
    try std.testing.expectEqual(State.closed, client.state);

    var final_ack_segment: [header_len]u8 = undefined;
    const final_ack_packet = try testDecodeOutbound(client, final_ack, client_ip, server_ip, final_ack_segment[0..]);
    try server.acceptAck(final_ack_packet);

    try std.testing.expectEqual(State.closed, server.state);
    try std.testing.expect(!server.retransmit.armed());
}

test "tcp session completes four-way teardown after established payload exchange" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "BYE";

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    const syn = try client.buildSyn();
    var syn_segment: [header_len]u8 = undefined;
    const syn_len = try encodeOutboundSegment(client, syn, syn_segment[0..], client_ip, server_ip);
    const syn_packet = try decode(syn_segment[0..syn_len], client_ip, server_ip);
    const syn_ack = try server.acceptSyn(syn_packet);

    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_len = try encodeOutboundSegment(server, syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);
    const ack = try client.acceptSynAck(syn_ack_packet);

    var ack_segment: [header_len]u8 = undefined;
    const ack_len = try encodeOutboundSegment(client, ack, ack_segment[0..], client_ip, server_ip);
    const ack_packet = try decode(ack_segment[0..ack_len], client_ip, server_ip);
    try server.acceptAck(ack_packet);

    const data = try client.buildPayload(payload);
    var data_segment: [header_len + payload.len]u8 = undefined;
    const data_len = try encodeOutboundSegment(client, data, data_segment[0..], client_ip, server_ip);
    const data_packet = try decode(data_segment[0..data_len], client_ip, server_ip);
    try server.acceptPayload(data_packet);

    const payload_ack = try server.buildAck();
    var payload_ack_segment: [header_len]u8 = undefined;
    const payload_ack_len = try encodeOutboundSegment(server, payload_ack, payload_ack_segment[0..], server_ip, client_ip);
    const payload_ack_packet = try decode(payload_ack_segment[0..payload_ack_len], server_ip, client_ip);
    try client.acceptAck(payload_ack_packet);

    const client_fin = try client.buildFin();
    try std.testing.expectEqual(State.fin_wait_1, client.state);
    var client_fin_segment: [header_len]u8 = undefined;
    const client_fin_len = try encodeOutboundSegment(client, client_fin, client_fin_segment[0..], client_ip, server_ip);
    const client_fin_packet = try decode(client_fin_segment[0..client_fin_len], client_ip, server_ip);
    const fin_ack = try server.acceptFin(client_fin_packet);
    try std.testing.expectEqual(State.close_wait, server.state);

    var fin_ack_segment: [header_len]u8 = undefined;
    const fin_ack_len = try encodeOutboundSegment(server, fin_ack, fin_ack_segment[0..], server_ip, client_ip);
    const fin_ack_packet = try decode(fin_ack_segment[0..fin_ack_len], server_ip, client_ip);
    try client.acceptAck(fin_ack_packet);
    try std.testing.expectEqual(State.fin_wait_2, client.state);

    const server_fin = try server.buildFin();
    try std.testing.expectEqual(State.last_ack, server.state);
    var server_fin_segment: [header_len]u8 = undefined;
    const server_fin_len = try encodeOutboundSegment(server, server_fin, server_fin_segment[0..], server_ip, client_ip);
    const server_fin_packet = try decode(server_fin_segment[0..server_fin_len], server_ip, client_ip);
    const final_ack = try client.acceptFin(server_fin_packet);
    try std.testing.expectEqual(State.closed, client.state);

    var final_ack_segment: [header_len]u8 = undefined;
    const final_ack_len = try encodeOutboundSegment(client, final_ack, final_ack_segment[0..], client_ip, server_ip);
    const final_ack_packet = try decode(final_ack_segment[0..final_ack_len], client_ip, server_ip);
    try server.acceptAck(final_ack_packet);

    try std.testing.expectEqual(State.closed, client.state);
    try std.testing.expectEqual(State.closed, server.state);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len + 1), client.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len + 1), server.recv_next);
    try std.testing.expectEqual(@as(u32, 0xA0B0_C0D2), server.send_next);
    try std.testing.expectEqual(@as(u32, 0xA0B0_C0D2), client.recv_next);
}

test "tcp session rejects fin outside teardown states and rejects malformed fin packets" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "bad";

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    try std.testing.expectError(error.InvalidState, client.buildFin());

    const syn = try client.buildSyn();
    var syn_segment: [header_len]u8 = undefined;
    const syn_len = try encodeOutboundSegment(client, syn, syn_segment[0..], client_ip, server_ip);
    const syn_packet = try decode(syn_segment[0..syn_len], client_ip, server_ip);
    const syn_ack = try server.acceptSyn(syn_packet);

    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_len = try encodeOutboundSegment(server, syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);
    const ack = try client.acceptSynAck(syn_ack_packet);

    var ack_segment: [header_len]u8 = undefined;
    const ack_len = try encodeOutboundSegment(client, ack, ack_segment[0..], client_ip, server_ip);
    const ack_packet = try decode(ack_segment[0..ack_len], client_ip, server_ip);
    try server.acceptAck(ack_packet);

    const malformed_fin = Packet{
        .source_port = client.local_port,
        .destination_port = client.remote_port,
        .sequence_number = client.send_next,
        .acknowledgment_number = client.recv_next,
        .data_offset_bytes = header_len,
        .flags = flag_fin | flag_ack,
        .window_size = client.local_window,
        .checksum_value = 0,
        .urgent_pointer = 0,
        .payload = payload,
    };
    try std.testing.expectError(error.UnexpectedFlags, server.acceptFin(malformed_fin));
}

test "tcp session rejects payload larger than remote window" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 4);

    const syn = try client.buildSyn();
    var syn_segment: [header_len]u8 = undefined;
    const syn_len = try encodeOutboundSegment(client, syn, syn_segment[0..], client_ip, server_ip);
    const syn_packet = try decode(syn_segment[0..syn_len], client_ip, server_ip);
    const syn_ack = try server.acceptSyn(syn_packet);

    var syn_ack_segment: [header_len]u8 = undefined;
    const syn_ack_len = try encodeOutboundSegment(server, syn_ack, syn_ack_segment[0..], server_ip, client_ip);
    const syn_ack_packet = try decode(syn_ack_segment[0..syn_ack_len], server_ip, client_ip);
    _ = try client.acceptSynAck(syn_ack_packet);

    try std.testing.expectEqual(@as(u16, 4), client.remote_window);
    try std.testing.expectError(error.WindowExceeded, client.buildPayload("12345"));
    try std.testing.expectError(error.WindowExceeded, client.buildPayloadWithTimeout("12345", 10, 3));
}

test "tcp session blocks payload on zero window until pure ack reopens it" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 4);

    var buffer: [header_len + 32]u8 = undefined;

    const syn = try client.buildSyn();
    const syn_packet = try testDecodeOutbound(client, syn, client_ip, server_ip, buffer[0..]);
    const syn_ack = try server.acceptSyn(syn_packet);
    const syn_ack_packet = try testDecodeOutbound(server, syn_ack, server_ip, client_ip, buffer[0..]);
    const ack = try client.acceptSynAck(syn_ack_packet);
    const ack_packet = try testDecodeOutbound(client, ack, client_ip, server_ip, buffer[0..]);
    try server.acceptAck(ack_packet);

    var zero_window_update = try server.buildAck();
    zero_window_update.window_size = 0;
    const zero_window_packet = try testDecodeOutbound(server, zero_window_update, server_ip, client_ip, buffer[0..]);
    try client.acceptAck(zero_window_packet);

    try std.testing.expectEqual(@as(u16, 0), client.remote_window);
    try std.testing.expectError(error.WindowExceeded, client.buildPayload("X"));
    try std.testing.expectError(error.WindowExceeded, client.buildPayloadWithTimeout("X", 10, 3));

    var reopen_window_update = try server.buildAck();
    reopen_window_update.window_size = 4;
    const reopen_window_packet = try testDecodeOutbound(server, reopen_window_update, server_ip, client_ip, buffer[0..]);
    try client.acceptAck(reopen_window_packet);

    try std.testing.expectEqual(@as(u16, 4), client.remote_window);
    const reopened_payload = try client.buildPayload("1234");
    try std.testing.expectEqual(@as(usize, 4), reopened_payload.payload.len);
    try std.testing.expectEqual(@as(u32, 4), client.bytesInFlight());
    try std.testing.expectError(error.WindowExceeded, client.buildPayloadChunk("12345"));
    try std.testing.expectError(error.WindowExceeded, client.buildPayload("12345"));
}

test "tcp session streams payload in remote-window-sized chunks" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "ABCDEFGHIJ";

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 4);

    var buffer: [header_len + 32]u8 = undefined;

    const syn = try client.buildSyn();
    const syn_packet = try testDecodeOutbound(client, syn, client_ip, server_ip, buffer[0..]);
    const syn_ack = try server.acceptSyn(syn_packet);
    const syn_ack_packet = try testDecodeOutbound(server, syn_ack, server_ip, client_ip, buffer[0..]);
    const ack = try client.acceptSynAck(syn_ack_packet);
    const ack_packet = try testDecodeOutbound(client, ack, client_ip, server_ip, buffer[0..]);
    try server.acceptAck(ack_packet);

    var payload_offset: usize = 0;
    while (payload_offset < payload.len) {
        const outbound = try client.buildPayloadChunk(payload[payload_offset..]);
        const data_packet = try testDecodeOutbound(client, outbound, client_ip, server_ip, buffer[0..]);
        try server.acceptPayload(data_packet);

        const chunk = payload[payload_offset .. payload_offset + outbound.payload.len];
        try std.testing.expectEqualStrings(chunk, outbound.payload);
        payload_offset += outbound.payload.len;

        const payload_ack = try server.buildAck();
        const payload_ack_packet = try testDecodeOutbound(server, payload_ack, server_ip, client_ip, buffer[0..]);
        try client.acceptAck(payload_ack_packet);
    }

    try std.testing.expectEqual(@as(usize, payload.len), payload_offset);
    try std.testing.expectEqual(@as(u32, 0), client.bytesInFlight());
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), client.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), server.recv_next);
}

test "tcp session allows multiple in-flight chunks within remote window and advances on cumulative ack" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    var client = Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = Session.initServer(443, 4321, 0xA0B0_C0D0, 8);

    var buffer: [header_len + 32]u8 = undefined;

    const syn = try client.buildSyn();
    const syn_packet = try testDecodeOutbound(client, syn, client_ip, server_ip, buffer[0..]);
    const syn_ack = try server.acceptSyn(syn_packet);
    const syn_ack_packet = try testDecodeOutbound(server, syn_ack, server_ip, client_ip, buffer[0..]);
    const ack = try client.acceptSynAck(syn_ack_packet);
    const ack_packet = try testDecodeOutbound(client, ack, client_ip, server_ip, buffer[0..]);
    try server.acceptAck(ack_packet);

    const first_chunk = try client.buildPayloadChunk("ABCD");
    try std.testing.expectEqualStrings("ABCD", first_chunk.payload);
    const first_packet = try testDecodeOutbound(client, first_chunk, client_ip, server_ip, buffer[0..]);
    try server.acceptPayload(first_packet);

    const second_chunk = try client.buildPayloadChunk("EFGH");
    try std.testing.expectEqualStrings("EFGH", second_chunk.payload);
    const second_packet = try testDecodeOutbound(client, second_chunk, client_ip, server_ip, buffer[0..]);
    try server.acceptPayload(second_packet);

    try std.testing.expectEqual(@as(u32, 8), client.bytesInFlight());
    try std.testing.expectError(error.WindowExceeded, client.buildPayloadChunk("I"));

    const payload_ack = try server.buildAck();
    const payload_ack_packet = try testDecodeOutbound(server, payload_ack, server_ip, client_ip, buffer[0..]);
    try client.acceptAck(payload_ack_packet);

    try std.testing.expectEqual(@as(u32, 0), client.bytesInFlight());
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + 8), client.send_unacked);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + 8), client.send_next);
}

fn testDecodeOutbound(
    session: Session,
    outbound: Outbound,
    source_ip: [4]u8,
    destination_ip: [4]u8,
    buffer: []u8,
) Error!Packet {
    const len = try encodeOutboundSegment(session, outbound, buffer, source_ip, destination_ip);
    return try decode(buffer[0..len], source_ip, destination_ip);
}

test "tcp session table stores multiple flows and reuses released slots" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };

    const flow_a = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4321,
        .remote_port = 443,
    };
    const flow_b = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4322,
        .remote_port = 444,
    };
    const flow_c = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4323,
        .remote_port = 445,
    };

    var table = SessionTable(2).init();
    const client_a = try table.createClient(flow_a, 0x0102_0304, 4096);
    const client_b = try table.createClient(flow_b, 0x1112_1314, 4096);

    try std.testing.expectEqual(@as(usize, 2), table.entryCount());
    try std.testing.expect(table.find(flow_a) == client_a);
    try std.testing.expect(table.find(flow_b) == client_b);
    try std.testing.expect(table.findConst(flow_c) == null);
    try std.testing.expectError(error.NoSpace, table.createClient(flow_c, 0x2122_2324, 4096));

    try std.testing.expect(table.release(flow_a));
    try std.testing.expectEqual(@as(usize, 1), table.entryCount());
    try std.testing.expect(table.find(flow_a) == null);

    const client_c = try table.createClient(flow_c, 0x2122_2324, 4096);
    try std.testing.expectEqual(@as(usize, 2), table.entryCount());
    try std.testing.expect(table.find(flow_c) == client_c);
}

test "tcp session table demuxes two inbound handshakes independently" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const flow_a = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4321,
        .remote_port = 443,
    };
    const flow_b = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4322,
        .remote_port = 444,
    };

    var table = SessionTable(2).init();
    const client_a = try table.createClient(flow_a, 0x0102_0304, 4096);
    const client_b = try table.createClient(flow_b, 0x1112_1314, 4096);
    var server_a = Session.initServer(flow_a.remote_port, flow_a.local_port, 0xA0B0_C0D0, 8192);
    var server_b = Session.initServer(flow_b.remote_port, flow_b.local_port, 0xB0C0_D0E0, 6144);

    const syn_a = try client_a.buildSyn();
    var syn_a_segment: [header_len]u8 = undefined;
    const syn_a_packet = try testDecodeOutbound(client_a.*, syn_a, client_ip, server_ip, syn_a_segment[0..]);
    const syn_ack_a = try server_a.acceptSyn(syn_a_packet);

    const syn_b = try client_b.buildSyn();
    var syn_b_segment: [header_len]u8 = undefined;
    const syn_b_packet = try testDecodeOutbound(client_b.*, syn_b, client_ip, server_ip, syn_b_segment[0..]);
    const syn_ack_b = try server_b.acceptSyn(syn_b_packet);

    var syn_ack_a_segment: [header_len]u8 = undefined;
    const syn_ack_a_packet = try testDecodeOutbound(server_a, syn_ack_a, server_ip, client_ip, syn_ack_a_segment[0..]);
    const mapped_a = table.findByInboundPacket(server_ip, client_ip, syn_ack_a_packet).?;
    try std.testing.expect(mapped_a == client_a);
    const ack_a = try mapped_a.acceptSynAck(syn_ack_a_packet);

    var ack_a_segment: [header_len]u8 = undefined;
    const ack_a_packet = try testDecodeOutbound(client_a.*, ack_a, client_ip, server_ip, ack_a_segment[0..]);
    try server_a.acceptAck(ack_a_packet);

    var syn_ack_b_segment: [header_len]u8 = undefined;
    const syn_ack_b_packet = try testDecodeOutbound(server_b, syn_ack_b, server_ip, client_ip, syn_ack_b_segment[0..]);
    const mapped_b = table.findByInboundPacket(server_ip, client_ip, syn_ack_b_packet).?;
    try std.testing.expect(mapped_b == client_b);
    const ack_b = try mapped_b.acceptSynAck(syn_ack_b_packet);

    var ack_b_segment: [header_len]u8 = undefined;
    const ack_b_packet = try testDecodeOutbound(client_b.*, ack_b, client_ip, server_ip, ack_b_segment[0..]);
    try server_b.acceptAck(ack_b_packet);

    try std.testing.expectEqual(State.established, client_a.state);
    try std.testing.expectEqual(State.established, client_b.state);
    try std.testing.expectEqual(State.established, server_a.state);
    try std.testing.expectEqual(State.established, server_b.state);
}

test "tcp session table advances payload acks independently across two flows" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const flow_a = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4321,
        .remote_port = 443,
    };
    const flow_b = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4322,
        .remote_port = 444,
    };
    const payload_a = "ALPHA";
    const payload_b = "BRAVO!";

    var table = SessionTable(2).init();
    const client_a = try table.createClient(flow_a, 0x0102_0304, 4096);
    const client_b = try table.createClient(flow_b, 0x1112_1314, 4096);
    var server_a = Session.initServer(flow_a.remote_port, flow_a.local_port, 0xA0B0_C0D0, 8192);
    var server_b = Session.initServer(flow_b.remote_port, flow_b.local_port, 0xB0C0_D0E0, 6144);

    {
        const syn = try client_a.buildSyn();
        var segment: [header_len]u8 = undefined;
        const packet = try testDecodeOutbound(client_a.*, syn, client_ip, server_ip, segment[0..]);
        const syn_ack = try server_a.acceptSyn(packet);
        var reply_segment: [header_len]u8 = undefined;
        const reply_packet = try testDecodeOutbound(server_a, syn_ack, server_ip, client_ip, reply_segment[0..]);
        const ack = try table.findByInboundPacket(server_ip, client_ip, reply_packet).?.acceptSynAck(reply_packet);
        var ack_segment: [header_len]u8 = undefined;
        const ack_packet = try testDecodeOutbound(client_a.*, ack, client_ip, server_ip, ack_segment[0..]);
        try server_a.acceptAck(ack_packet);
    }
    {
        const syn = try client_b.buildSyn();
        var segment: [header_len]u8 = undefined;
        const packet = try testDecodeOutbound(client_b.*, syn, client_ip, server_ip, segment[0..]);
        const syn_ack = try server_b.acceptSyn(packet);
        var reply_segment: [header_len]u8 = undefined;
        const reply_packet = try testDecodeOutbound(server_b, syn_ack, server_ip, client_ip, reply_segment[0..]);
        const ack = try table.findByInboundPacket(server_ip, client_ip, reply_packet).?.acceptSynAck(reply_packet);
        var ack_segment: [header_len]u8 = undefined;
        const ack_packet = try testDecodeOutbound(client_b.*, ack, client_ip, server_ip, ack_segment[0..]);
        try server_b.acceptAck(ack_packet);
    }

    const outbound_b = try client_b.buildPayload(payload_b);
    var outbound_b_segment: [header_len + payload_b.len]u8 = undefined;
    const outbound_b_packet = try testDecodeOutbound(client_b.*, outbound_b, client_ip, server_ip, outbound_b_segment[0..]);
    try server_b.acceptPayload(outbound_b_packet);
    const ack_b = try server_b.buildAck();
    var ack_b_segment: [header_len]u8 = undefined;
    const ack_b_packet = try testDecodeOutbound(server_b, ack_b, server_ip, client_ip, ack_b_segment[0..]);
    try table.findByInboundPacket(server_ip, client_ip, ack_b_packet).?.acceptAck(ack_b_packet);

    const outbound_a = try client_a.buildPayload(payload_a);
    var outbound_a_segment: [header_len + payload_a.len]u8 = undefined;
    const outbound_a_packet = try testDecodeOutbound(client_a.*, outbound_a, client_ip, server_ip, outbound_a_segment[0..]);
    try server_a.acceptPayload(outbound_a_packet);
    const ack_a = try server_a.buildAck();
    var ack_a_segment: [header_len]u8 = undefined;
    const ack_a_packet = try testDecodeOutbound(server_a, ack_a, server_ip, client_ip, ack_a_segment[0..]);
    try table.findByInboundPacket(server_ip, client_ip, ack_a_packet).?.acceptAck(ack_a_packet);

    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload_a.len), client_a.send_next);
    try std.testing.expectEqual(@as(u32, 0x1112_1315 + payload_b.len), client_b.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload_a.len), server_a.recv_next);
    try std.testing.expectEqual(@as(u32, 0x1112_1315 + payload_b.len), server_b.recv_next);
}

test "tcp session table teardown on one flow leaves another flow established" {
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const flow_a = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4321,
        .remote_port = 443,
    };
    const flow_b = FlowKey{
        .local_ip = client_ip,
        .remote_ip = server_ip,
        .local_port = 4322,
        .remote_port = 444,
    };

    var table = SessionTable(2).init();
    const client_a = try table.createClient(flow_a, 0x0102_0304, 4096);
    const client_b = try table.createClient(flow_b, 0x1112_1314, 4096);
    var server_a = Session.initServer(flow_a.remote_port, flow_a.local_port, 0xA0B0_C0D0, 8192);
    var server_b = Session.initServer(flow_b.remote_port, flow_b.local_port, 0xB0C0_D0E0, 6144);

    {
        const syn = try client_a.buildSyn();
        var segment: [header_len]u8 = undefined;
        const packet = try testDecodeOutbound(client_a.*, syn, client_ip, server_ip, segment[0..]);
        const syn_ack = try server_a.acceptSyn(packet);
        var reply_segment: [header_len]u8 = undefined;
        const reply_packet = try testDecodeOutbound(server_a, syn_ack, server_ip, client_ip, reply_segment[0..]);
        const ack = try table.findByInboundPacket(server_ip, client_ip, reply_packet).?.acceptSynAck(reply_packet);
        var ack_segment: [header_len]u8 = undefined;
        const ack_packet = try testDecodeOutbound(client_a.*, ack, client_ip, server_ip, ack_segment[0..]);
        try server_a.acceptAck(ack_packet);
    }
    {
        const syn = try client_b.buildSyn();
        var segment: [header_len]u8 = undefined;
        const packet = try testDecodeOutbound(client_b.*, syn, client_ip, server_ip, segment[0..]);
        const syn_ack = try server_b.acceptSyn(packet);
        var reply_segment: [header_len]u8 = undefined;
        const reply_packet = try testDecodeOutbound(server_b, syn_ack, server_ip, client_ip, reply_segment[0..]);
        const ack = try table.findByInboundPacket(server_ip, client_ip, reply_packet).?.acceptSynAck(reply_packet);
        var ack_segment: [header_len]u8 = undefined;
        const ack_packet = try testDecodeOutbound(client_b.*, ack, client_ip, server_ip, ack_segment[0..]);
        try server_b.acceptAck(ack_packet);
    }

    const client_fin = try client_a.buildFin();
    var client_fin_segment: [header_len]u8 = undefined;
    const client_fin_packet = try testDecodeOutbound(client_a.*, client_fin, client_ip, server_ip, client_fin_segment[0..]);
    const fin_ack = try server_a.acceptFin(client_fin_packet);
    var fin_ack_segment: [header_len]u8 = undefined;
    const fin_ack_packet = try testDecodeOutbound(server_a, fin_ack, server_ip, client_ip, fin_ack_segment[0..]);
    try table.findByInboundPacket(server_ip, client_ip, fin_ack_packet).?.acceptAck(fin_ack_packet);

    const server_fin = try server_a.buildFin();
    var server_fin_segment: [header_len]u8 = undefined;
    const server_fin_packet = try testDecodeOutbound(server_a, server_fin, server_ip, client_ip, server_fin_segment[0..]);
    const final_ack = try table.findByInboundPacket(server_ip, client_ip, server_fin_packet).?.acceptFin(server_fin_packet);
    var final_ack_segment: [header_len]u8 = undefined;
    const final_ack_packet = try testDecodeOutbound(client_a.*, final_ack, client_ip, server_ip, final_ack_segment[0..]);
    try server_a.acceptAck(final_ack_packet);

    try std.testing.expectEqual(State.closed, client_a.state);
    try std.testing.expectEqual(State.established, client_b.state);

    const payload_b = try client_b.buildPayload("still-live");
    var payload_b_segment: [header_len + "still-live".len]u8 = undefined;
    const payload_b_packet = try testDecodeOutbound(client_b.*, payload_b, client_ip, server_ip, payload_b_segment[0..]);
    try server_b.acceptPayload(payload_b_packet);
    const payload_b_ack = try server_b.buildAck();
    var payload_b_ack_segment: [header_len]u8 = undefined;
    const payload_b_ack_packet = try testDecodeOutbound(server_b, payload_b_ack, server_ip, client_ip, payload_b_ack_segment[0..]);
    try table.findByInboundPacket(server_ip, client_ip, payload_b_ack_packet).?.acceptAck(payload_b_ack_packet);

    try std.testing.expectEqual(State.established, client_b.state);
    try std.testing.expectEqual(State.established, server_b.state);
}
