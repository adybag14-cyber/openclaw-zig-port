const std = @import("std");
const ethernet = @import("ethernet.zig");

pub const header_len: usize = 28;
pub const frame_len: usize = ethernet.header_len + header_len;
pub const hardware_type_ethernet: u16 = 1;
pub const protocol_type_ipv4: u16 = ethernet.ethertype_ipv4;
pub const hardware_address_len: u8 = ethernet.mac_len;
pub const protocol_address_len_ipv4: u8 = 4;
pub const operation_request: u16 = 1;
pub const operation_reply: u16 = 2;

pub const Error = error{
    BufferTooSmall,
    FrameTooShort,
    NotArp,
    UnsupportedHardwareType,
    UnsupportedProtocolType,
    UnsupportedHardwareAddressLength,
    UnsupportedProtocolAddressLength,
};

pub const Packet = struct {
    ethernet_destination: [ethernet.mac_len]u8,
    ethernet_source: [ethernet.mac_len]u8,
    hardware_type: u16,
    protocol_type: u16,
    hardware_address_length: u8,
    protocol_address_length: u8,
    operation: u16,
    sender_mac: [ethernet.mac_len]u8,
    sender_ip: [4]u8,
    target_mac: [ethernet.mac_len]u8,
    target_ip: [4]u8,
};

pub fn encodeRequestFrame(
    buffer: []u8,
    source_mac: [ethernet.mac_len]u8,
    sender_ip: [4]u8,
    target_ip: [4]u8,
) Error!usize {
    if (buffer.len < frame_len) return error.BufferTooSmall;

    const eth_header = ethernet.Header{
        .destination = ethernet.broadcast_mac,
        .source = source_mac,
        .ether_type = ethernet.ethertype_arp,
    };
    _ = try eth_header.encode(buffer[0..ethernet.header_len]);

    ethernet.writeU16Be(buffer[14..16], hardware_type_ethernet);
    ethernet.writeU16Be(buffer[16..18], protocol_type_ipv4);
    buffer[18] = hardware_address_len;
    buffer[19] = protocol_address_len_ipv4;
    ethernet.writeU16Be(buffer[20..22], operation_request);
    std.mem.copyForwards(u8, buffer[22..28], source_mac[0..]);
    std.mem.copyForwards(u8, buffer[28..32], sender_ip[0..]);
    @memset(buffer[32..38], 0);
    std.mem.copyForwards(u8, buffer[38..42], target_ip[0..]);
    return frame_len;
}

pub fn encodeReplyFrame(
    buffer: []u8,
    source_mac: [ethernet.mac_len]u8,
    sender_ip: [4]u8,
    target_mac: [ethernet.mac_len]u8,
    target_ip: [4]u8,
) Error!usize {
    if (buffer.len < frame_len) return error.BufferTooSmall;

    const eth_header = ethernet.Header{
        .destination = target_mac,
        .source = source_mac,
        .ether_type = ethernet.ethertype_arp,
    };
    _ = try eth_header.encode(buffer[0..ethernet.header_len]);

    ethernet.writeU16Be(buffer[14..16], hardware_type_ethernet);
    ethernet.writeU16Be(buffer[16..18], protocol_type_ipv4);
    buffer[18] = hardware_address_len;
    buffer[19] = protocol_address_len_ipv4;
    ethernet.writeU16Be(buffer[20..22], operation_reply);
    std.mem.copyForwards(u8, buffer[22..28], source_mac[0..]);
    std.mem.copyForwards(u8, buffer[28..32], sender_ip[0..]);
    std.mem.copyForwards(u8, buffer[32..38], target_mac[0..]);
    std.mem.copyForwards(u8, buffer[38..42], target_ip[0..]);
    return frame_len;
}

pub fn decodeFrame(frame: []const u8) Error!Packet {
    if (frame.len < frame_len) return error.FrameTooShort;
    const eth_header = try ethernet.Header.decode(frame);
    if (eth_header.ether_type != ethernet.ethertype_arp) return error.NotArp;

    const hardware_type = ethernet.readU16Be(frame[14..16]);
    if (hardware_type != hardware_type_ethernet) return error.UnsupportedHardwareType;
    const protocol_type = ethernet.readU16Be(frame[16..18]);
    if (protocol_type != protocol_type_ipv4) return error.UnsupportedProtocolType;
    if (frame[18] != hardware_address_len) return error.UnsupportedHardwareAddressLength;
    if (frame[19] != protocol_address_len_ipv4) return error.UnsupportedProtocolAddressLength;

    var sender_mac: [ethernet.mac_len]u8 = undefined;
    var sender_ip: [4]u8 = undefined;
    var target_mac: [ethernet.mac_len]u8 = undefined;
    var target_ip: [4]u8 = undefined;
    std.mem.copyForwards(u8, sender_mac[0..], frame[22..28]);
    std.mem.copyForwards(u8, sender_ip[0..], frame[28..32]);
    std.mem.copyForwards(u8, target_mac[0..], frame[32..38]);
    std.mem.copyForwards(u8, target_ip[0..], frame[38..42]);

    return .{
        .ethernet_destination = eth_header.destination,
        .ethernet_source = eth_header.source,
        .hardware_type = hardware_type,
        .protocol_type = protocol_type,
        .hardware_address_length = frame[18],
        .protocol_address_length = frame[19],
        .operation = ethernet.readU16Be(frame[20..22]),
        .sender_mac = sender_mac,
        .sender_ip = sender_ip,
        .target_mac = target_mac,
        .target_ip = target_ip,
    };
}

test "arp request frame encodes and decodes" {
    const source_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const sender_ip = [4]u8{ 192, 168, 56, 10 };
    const target_ip = [4]u8{ 192, 168, 56, 1 };

    var buffer: [frame_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, frame_len), try encodeRequestFrame(buffer[0..], source_mac, sender_ip, target_ip));

    const decoded = try decodeFrame(buffer[0..]);
    try std.testing.expectEqual(operation_request, decoded.operation);
    try std.testing.expectEqualSlices(u8, ethernet.broadcast_mac[0..], decoded.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, source_mac[0..], decoded.ethernet_source[0..]);
    try std.testing.expectEqualSlices(u8, source_mac[0..], decoded.sender_mac[0..]);
    try std.testing.expectEqualSlices(u8, sender_ip[0..], decoded.sender_ip[0..]);
    try std.testing.expectEqualSlices(u8, target_ip[0..], decoded.target_ip[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0, 0 }, decoded.target_mac[0..]);
}

test "arp reply frame encodes and decodes" {
    const source_mac = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    const sender_ip = [4]u8{ 192, 168, 56, 1 };
    const target_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const target_ip = [4]u8{ 192, 168, 56, 10 };

    var buffer: [frame_len]u8 = undefined;
    try std.testing.expectEqual(@as(usize, frame_len), try encodeReplyFrame(buffer[0..], source_mac, sender_ip, target_mac, target_ip));

    const decoded = try decodeFrame(buffer[0..]);
    try std.testing.expectEqual(operation_reply, decoded.operation);
    try std.testing.expectEqualSlices(u8, target_mac[0..], decoded.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, source_mac[0..], decoded.ethernet_source[0..]);
    try std.testing.expectEqualSlices(u8, source_mac[0..], decoded.sender_mac[0..]);
    try std.testing.expectEqualSlices(u8, sender_ip[0..], decoded.sender_ip[0..]);
    try std.testing.expectEqualSlices(u8, target_mac[0..], decoded.target_mac[0..]);
    try std.testing.expectEqualSlices(u8, target_ip[0..], decoded.target_ip[0..]);
}
