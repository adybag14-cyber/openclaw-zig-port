const std = @import("std");

pub const header_len: usize = 14;
pub const mac_len: usize = 6;
pub const ethertype_arp: u16 = 0x0806;
pub const ethertype_ipv4: u16 = 0x0800;
pub const broadcast_mac = [mac_len]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

pub const Error = error{
    BufferTooSmall,
    FrameTooShort,
};

pub const Header = struct {
    destination: [mac_len]u8,
    source: [mac_len]u8,
    ether_type: u16,

    pub fn encode(self: Header, buffer: []u8) Error!usize {
        if (buffer.len < header_len) return error.BufferTooSmall;
        std.mem.copyForwards(u8, buffer[0..mac_len], self.destination[0..]);
        std.mem.copyForwards(u8, buffer[mac_len .. mac_len * 2], self.source[0..]);
        writeU16Be(buffer[12..14], self.ether_type);
        return header_len;
    }

    pub fn decode(frame: []const u8) Error!Header {
        if (frame.len < header_len) return error.FrameTooShort;
        var destination: [mac_len]u8 = undefined;
        var source: [mac_len]u8 = undefined;
        std.mem.copyForwards(u8, destination[0..], frame[0..mac_len]);
        std.mem.copyForwards(u8, source[0..], frame[mac_len .. mac_len * 2]);
        return .{
            .destination = destination,
            .source = source,
            .ether_type = readU16Be(frame[12..14]),
        };
    }
};

pub fn writeU16Be(bytes: []u8, value: u16) void {
    bytes[0] = @as(u8, @intCast(value >> 8));
    bytes[1] = @as(u8, @truncate(value));
}

pub fn readU16Be(bytes: []const u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

test "ethernet header encodes and decodes" {
    const header = Header{
        .destination = broadcast_mac,
        .source = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 },
        .ether_type = ethertype_arp,
    };

    var buffer: [header_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, header_len), try header.encode(buffer[0..]));

    const decoded = try Header.decode(buffer[0..]);
    try std.testing.expectEqualSlices(u8, header.destination[0..], decoded.destination[0..]);
    try std.testing.expectEqualSlices(u8, header.source[0..], decoded.source[0..]);
    try std.testing.expectEqual(header.ether_type, decoded.ether_type);
}
