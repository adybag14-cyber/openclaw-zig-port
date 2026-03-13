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
    ChecksumMismatch,
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
