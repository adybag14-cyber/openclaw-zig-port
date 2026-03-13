const std = @import("std");
const ipv4 = @import("ipv4.zig");

pub const header_len: usize = 8;

pub const Error = error{
    BufferTooSmall,
    PacketTooShort,
    InvalidLength,
    PayloadTooLarge,
    ChecksumMismatch,
};

pub const Header = struct {
    source_port: u16,
    destination_port: u16,

    pub fn encode(
        self: Header,
        buffer: []u8,
        payload: []const u8,
        source_ip: [4]u8,
        destination_ip: [4]u8,
    ) Error!usize {
        const total_len = std.math.cast(u16, header_len + payload.len) orelse return error.PayloadTooLarge;
        if (buffer.len < total_len) return error.BufferTooSmall;

        writeU16Be(buffer[0..2], self.source_port);
        writeU16Be(buffer[2..4], self.destination_port);
        writeU16Be(buffer[4..6], total_len);
        buffer[6] = 0;
        buffer[7] = 0;
        std.mem.copyForwards(u8, buffer[header_len .. header_len + payload.len], payload);

        var checksum_value = checksum(buffer[0..total_len], source_ip, destination_ip);
        if (checksum_value == 0) checksum_value = 0xFFFF;
        writeU16Be(buffer[6..8], checksum_value);
        return total_len;
    }
};

pub const Packet = struct {
    source_port: u16,
    destination_port: u16,
    length: u16,
    checksum_value: u16,
    payload: []const u8,
};

pub fn decode(packet: []const u8, source_ip: [4]u8, destination_ip: [4]u8) Error!Packet {
    if (packet.len < header_len) return error.PacketTooShort;

    const length = readU16Be(packet[4..6]);
    if (length < header_len or length > packet.len) return error.InvalidLength;

    const checksum_value = readU16Be(packet[6..8]);
    if (checksum_value != 0 and checksum(packet[0..length], source_ip, destination_ip) != 0) {
        return error.ChecksumMismatch;
    }

    return .{
        .source_port = readU16Be(packet[0..2]),
        .destination_port = readU16Be(packet[2..4]),
        .length = length,
        .checksum_value = checksum_value,
        .payload = packet[header_len..length],
    };
}

pub fn checksum(segment: []const u8, source_ip: [4]u8, destination_ip: [4]u8) u16 {
    var sum: u32 = 0;

    sum +%= readU16Be(source_ip[0..2]);
    sum +%= readU16Be(source_ip[2..4]);
    sum +%= readU16Be(destination_ip[0..2]);
    sum +%= readU16Be(destination_ip[2..4]);
    sum +%= ipv4.protocol_udp;
    sum +%= @as(u16, @intCast(segment.len));

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

fn readU16Be(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

test "udp encodes and decodes with checksum" {
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "PING";
    const header = Header{
        .source_port = 4321,
        .destination_port = 9001,
    };

    var segment: [header_len + payload.len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, header_len + payload.len), try header.encode(segment[0..], payload, source_ip, destination_ip));

    const decoded = try decode(segment[0..], source_ip, destination_ip);
    try std.testing.expectEqual(@as(u16, 4321), decoded.source_port);
    try std.testing.expectEqual(@as(u16, 9001), decoded.destination_port);
    try std.testing.expectEqualSlices(u8, payload, decoded.payload);
    try std.testing.expect(decoded.checksum_value != 0);
}

test "udp rejects checksum mismatch" {
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "PING";
    const header = Header{
        .source_port = 4321,
        .destination_port = 9001,
    };

    var segment: [header_len + payload.len]u8 = undefined;
    _ = try header.encode(segment[0..], payload, source_ip, destination_ip);
    segment[header_len] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, decode(segment[0..], source_ip, destination_ip));
}

test "udp rejects invalid length" {
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "PING";
    const header = Header{
        .source_port = 4321,
        .destination_port = 9001,
    };

    var segment: [header_len + payload.len]u8 = undefined;
    _ = try header.encode(segment[0..], payload, source_ip, destination_ip);
    writeU16Be(segment[4..6], 7);
    try std.testing.expectError(error.InvalidLength, decode(segment[0..], source_ip, destination_ip));
}
