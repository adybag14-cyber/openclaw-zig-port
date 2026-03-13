const std = @import("std");

pub const version: u8 = 4;
pub const header_len: usize = 20;
pub const header_words_no_options: u8 = 5;
pub const protocol_udp: u8 = 17;
pub const default_ttl: u8 = 64;

pub const Error = error{
    BufferTooSmall,
    PacketTooShort,
    InvalidVersion,
    UnsupportedOptions,
    InvalidTotalLength,
    PayloadTooLarge,
    HeaderChecksumMismatch,
};

pub const Header = struct {
    dscp_ecn: u8 = 0,
    identification: u16 = 0,
    flags_fragment_offset: u16 = 0,
    ttl: u8 = default_ttl,
    protocol: u8,
    source_ip: [4]u8,
    destination_ip: [4]u8,

    pub fn encode(self: Header, buffer: []u8, payload_len: usize) Error!usize {
        if (buffer.len < header_len) return error.BufferTooSmall;
        const total_len = std.math.cast(u16, header_len + payload_len) orelse return error.PayloadTooLarge;

        buffer[0] = (version << 4) | header_words_no_options;
        buffer[1] = self.dscp_ecn;
        writeU16Be(buffer[2..4], total_len);
        writeU16Be(buffer[4..6], self.identification);
        writeU16Be(buffer[6..8], self.flags_fragment_offset);
        buffer[8] = self.ttl;
        buffer[9] = self.protocol;
        buffer[10] = 0;
        buffer[11] = 0;
        std.mem.copyForwards(u8, buffer[12..16], self.source_ip[0..]);
        std.mem.copyForwards(u8, buffer[16..20], self.destination_ip[0..]);
        writeU16Be(buffer[10..12], checksum(buffer[0..header_len]));
        return header_len;
    }
};

pub const Packet = struct {
    header: Header,
    total_len: u16,
    payload: []const u8,
};

pub fn decode(packet: []const u8) Error!Packet {
    if (packet.len < header_len) return error.PacketTooShort;

    const version_value = packet[0] >> 4;
    if (version_value != version) return error.InvalidVersion;

    const ihl_words = packet[0] & 0x0F;
    if (ihl_words != header_words_no_options) return error.UnsupportedOptions;

    const actual_header_len = @as(usize, ihl_words) * 4;
    if (packet.len < actual_header_len) return error.PacketTooShort;

    const total_len = readU16Be(packet[2..4]);
    if (total_len < actual_header_len or total_len > packet.len) return error.InvalidTotalLength;

    if (checksum(packet[0..actual_header_len]) != 0) return error.HeaderChecksumMismatch;

    var source_ip: [4]u8 = undefined;
    var destination_ip: [4]u8 = undefined;
    std.mem.copyForwards(u8, source_ip[0..], packet[12..16]);
    std.mem.copyForwards(u8, destination_ip[0..], packet[16..20]);

    return .{
        .header = .{
            .dscp_ecn = packet[1],
            .identification = readU16Be(packet[4..6]),
            .flags_fragment_offset = readU16Be(packet[6..8]),
            .ttl = packet[8],
            .protocol = packet[9],
            .source_ip = source_ip,
            .destination_ip = destination_ip,
        },
        .total_len = total_len,
        .payload = packet[actual_header_len..total_len],
    };
}

pub fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) {
        sum +%= readU16Be(bytes[index .. index + 2]);
    }
    if (index < bytes.len) {
        sum +%= @as(u16, bytes[index]) << 8;
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

fn readU16Be(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

test "ipv4 encodes and decodes packet with checksum" {
    const header = Header{
        .identification = 0x1234,
        .flags_fragment_offset = 0,
        .ttl = 32,
        .protocol = protocol_udp,
        .source_ip = .{ 192, 168, 56, 10 },
        .destination_ip = .{ 192, 168, 56, 1 },
    };
    const payload = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };

    var packet: [header_len + payload.len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, header_len), try header.encode(packet[0..header_len], payload.len));
    std.mem.copyForwards(u8, packet[header_len..], payload[0..]);

    const decoded = try decode(packet[0..]);
    try std.testing.expectEqual(protocol_udp, decoded.header.protocol);
    try std.testing.expectEqual(@as(u8, 32), decoded.header.ttl);
    try std.testing.expectEqualSlices(u8, header.source_ip[0..], decoded.header.source_ip[0..]);
    try std.testing.expectEqualSlices(u8, header.destination_ip[0..], decoded.header.destination_ip[0..]);
    try std.testing.expectEqualSlices(u8, payload[0..], decoded.payload);
}

test "ipv4 rejects checksum mismatch" {
    const header = Header{
        .protocol = protocol_udp,
        .source_ip = .{ 10, 0, 0, 2 },
        .destination_ip = .{ 10, 0, 0, 1 },
    };
    var packet: [header_len + 2]u8 = undefined;
    _ = try header.encode(packet[0..header_len], 2);
    packet[header_len] = 0x01;
    packet[header_len + 1] = 0x02;
    packet[8] ^= 0x01;
    try std.testing.expectError(error.HeaderChecksumMismatch, decode(packet[0..]));
}

test "ipv4 rejects invalid total length" {
    const header = Header{
        .protocol = protocol_udp,
        .source_ip = .{ 10, 0, 0, 2 },
        .destination_ip = .{ 10, 0, 0, 1 },
    };
    var packet: [header_len]u8 = undefined;
    _ = try header.encode(packet[0..], 0);
    writeU16Be(packet[2..4], 10);
    writeU16Be(packet[10..12], checksum(packet[0..]));
    try std.testing.expectError(error.InvalidTotalLength, decode(packet[0..]));
}

test "ipv4 rejects options in strict slice" {
    const header = Header{
        .protocol = protocol_udp,
        .source_ip = .{ 10, 0, 0, 2 },
        .destination_ip = .{ 10, 0, 0, 1 },
    };
    var packet: [header_len]u8 = undefined;
    _ = try header.encode(packet[0..], 0);
    packet[0] = (version << 4) | 6;
    writeU16Be(packet[10..12], 0);
    writeU16Be(packet[10..12], checksum(packet[0..]));
    try std.testing.expectError(error.UnsupportedOptions, decode(packet[0..]));
}
