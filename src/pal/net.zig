const std = @import("std");
const builtin = @import("builtin");
const time_util = @import("../util/time.zig");
const abi = @import("../baremetal/abi.zig");
const rtl8139 = @import("../baremetal/rtl8139.zig");
const ethernet = @import("../protocol/ethernet.zig");
const arp = @import("../protocol/arp.zig");
const ipv4 = @import("../protocol/ipv4.zig");
const udp = @import("../protocol/udp.zig");

pub const Response = struct {
    status_code: u16,
    body: []u8,
    latency_ms: i64,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const EthernetState = abi.BaremetalEthernetState;
pub const Error = rtl8139.Error;
pub const ArpPacket = arp.Packet;
pub const ArpError = rtl8139.Error || arp.Error;
pub const Ipv4Error = rtl8139.Error || ethernet.Error || ipv4.Error;
pub const UdpError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error;
pub const StrictIpv4PollError = rtl8139.Error || ethernet.Error || ipv4.Error || error{NotIpv4};
pub const StrictUdpPollError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error || error{ NotIpv4, NotUdp };
pub const max_frame_len: usize = 2048;
pub const max_ipv4_payload_len: usize = max_frame_len - ethernet.header_len - ipv4.header_len;
pub const max_udp_payload_len: usize = max_ipv4_payload_len - udp.header_len;

pub const Ipv4Packet = struct {
    ethernet_destination: [ethernet.mac_len]u8,
    ethernet_source: [ethernet.mac_len]u8,
    header: ipv4.Header,
    total_len: u16,
    payload_len: usize,
    payload: [max_ipv4_payload_len]u8,
};

pub const UdpPacket = struct {
    ethernet_destination: [ethernet.mac_len]u8,
    ethernet_source: [ethernet.mac_len]u8,
    ipv4_header: ipv4.Header,
    source_port: u16,
    destination_port: u16,
    checksum_value: u16,
    payload_len: usize,
    payload: [max_udp_payload_len]u8,
};

pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    payload: []const u8,
    headers: []const std.http.Header,
) !Response {
    var client: std.http.Client = .{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
    };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();
    const started_ms = time_util.nowMs();

    const fetch_result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .keep_alive = false,
        .extra_headers = headers,
        .response_writer = &response_body.writer,
    });

    return .{
        .status_code = @as(u16, @intCast(@intFromEnum(fetch_result.status))),
        .body = try response_body.toOwnedSlice(),
        .latency_ms = time_util.nowMs() - started_ms,
    };
}

pub fn initDevice() bool {
    return rtl8139.init();
}

pub fn resetDeviceForTest() void {
    if (!builtin.is_test) return;
    rtl8139.resetForTest();
}

pub fn deviceState() *const EthernetState {
    return rtl8139.statePtr();
}

pub fn macAddress() [6]u8 {
    return rtl8139.statePtr().mac;
}

pub fn sendFrame(frame: []const u8) Error!void {
    try rtl8139.sendFrame(frame);
}

pub fn pollReceive() Error!u32 {
    return try rtl8139.pollReceive();
}

pub fn rxByte(index: u32) u8 {
    return rtl8139.rxByte(index);
}

pub fn sendArpRequest(sender_ip: [4]u8, target_ip: [4]u8) ArpError!u32 {
    if (!initDevice()) return error.NotAvailable;
    var frame: [arp.frame_len]u8 = undefined;
    const frame_len = try arp.encodeRequestFrame(frame[0..], macAddress(), sender_ip, target_ip);
    try sendFrame(frame[0..frame_len]);
    return @as(u32, @intCast(frame_len));
}

pub fn pollArpPacket() ArpError!?ArpPacket {
    const rx_len = try pollReceive();
    if (rx_len == 0) return null;

    var frame: [256]u8 = undefined;
    const copy_len = @min(frame.len, @as(usize, @intCast(rx_len)));
    var index: usize = 0;
    while (index < copy_len) : (index += 1) {
        frame[index] = rxByte(@as(u32, @intCast(index)));
    }

    return arp.decodeFrame(frame[0..copy_len]) catch |err| switch (err) {
        error.NotArp => null,
        else => return err,
    };
}

pub fn sendIpv4Frame(
    destination_mac: [ethernet.mac_len]u8,
    source_ip: [4]u8,
    destination_ip: [4]u8,
    protocol: u8,
    payload: []const u8,
) Ipv4Error!u32 {
    if (!initDevice()) return error.NotAvailable;

    var frame: [max_frame_len]u8 = undefined;
    const eth_header = ethernet.Header{
        .destination = destination_mac,
        .source = macAddress(),
        .ether_type = ethernet.ethertype_ipv4,
    };
    _ = try eth_header.encode(frame[0..ethernet.header_len]);

    const ip_header = ipv4.Header{
        .protocol = protocol,
        .source_ip = source_ip,
        .destination_ip = destination_ip,
    };
    const ip_header_len = try ip_header.encode(frame[ethernet.header_len .. ethernet.header_len + ipv4.header_len], payload.len);
    std.mem.copyForwards(u8, frame[ethernet.header_len + ip_header_len .. ethernet.header_len + ip_header_len + payload.len], payload);

    const frame_len = ethernet.header_len + ip_header_len + payload.len;
    try sendFrame(frame[0..frame_len]);
    return @as(u32, @intCast(frame_len));
}

pub fn pollIpv4Packet() Ipv4Error!?Ipv4Packet {
    return pollIpv4PacketStrict() catch |err| switch (err) {
        error.NotIpv4 => null,
        error.NotAvailable => return error.NotAvailable,
        error.NotInitialized => return error.NotInitialized,
        error.FrameTooLarge => return error.FrameTooLarge,
        error.HardwareFault => return error.HardwareFault,
        error.Timeout => return error.Timeout,
        error.BufferTooSmall => return error.BufferTooSmall,
        error.PacketTooShort => return error.PacketTooShort,
        error.InvalidVersion => return error.InvalidVersion,
        error.UnsupportedOptions => return error.UnsupportedOptions,
        error.InvalidTotalLength => return error.InvalidTotalLength,
        error.PayloadTooLarge => return error.PayloadTooLarge,
        error.HeaderChecksumMismatch => return error.HeaderChecksumMismatch,
        error.FrameTooShort => return error.FrameTooShort,
    };
}

pub fn pollIpv4PacketStrict() StrictIpv4PollError!?Ipv4Packet {
    const rx_len = try pollReceive();
    if (rx_len == 0) return null;

    var frame: [max_frame_len]u8 = undefined;
    const copy_len = @min(frame.len, @as(usize, @intCast(rx_len)));
    var index: usize = 0;
    while (index < copy_len) : (index += 1) {
        frame[index] = rxByte(@as(u32, @intCast(index)));
    }

    const eth_header = try ethernet.Header.decode(frame[0..copy_len]);
    if (eth_header.ether_type != ethernet.ethertype_ipv4) return error.NotIpv4;

    const packet = try ipv4.decode(frame[ethernet.header_len..copy_len]);
    if (packet.payload.len > max_ipv4_payload_len) return error.PayloadTooLarge;

    var result = Ipv4Packet{
        .ethernet_destination = eth_header.destination,
        .ethernet_source = eth_header.source,
        .header = packet.header,
        .total_len = packet.total_len,
        .payload_len = packet.payload.len,
        .payload = [_]u8{0} ** max_ipv4_payload_len,
    };
    std.mem.copyForwards(u8, result.payload[0..packet.payload.len], packet.payload);
    return result;
}

pub fn sendUdpPacket(
    destination_mac: [ethernet.mac_len]u8,
    source_ip: [4]u8,
    destination_ip: [4]u8,
    source_port: u16,
    destination_port: u16,
    payload: []const u8,
) UdpError!u32 {
    if (!initDevice()) return error.NotAvailable;

    var segment: [max_ipv4_payload_len]u8 = undefined;
    const udp_header = udp.Header{
        .source_port = source_port,
        .destination_port = destination_port,
    };
    const segment_len = try udp_header.encode(segment[0..], payload, source_ip, destination_ip);
    return try sendIpv4Frame(destination_mac, source_ip, destination_ip, ipv4.protocol_udp, segment[0..segment_len]);
}

pub fn pollUdpPacket() UdpError!?UdpPacket {
    return pollUdpPacketStrict() catch |err| switch (err) {
        error.NotIpv4, error.NotUdp => null,
        error.NotAvailable => return error.NotAvailable,
        error.NotInitialized => return error.NotInitialized,
        error.FrameTooLarge => return error.FrameTooLarge,
        error.HardwareFault => return error.HardwareFault,
        error.Timeout => return error.Timeout,
        error.BufferTooSmall => return error.BufferTooSmall,
        error.PacketTooShort => return error.PacketTooShort,
        error.InvalidVersion => return error.InvalidVersion,
        error.UnsupportedOptions => return error.UnsupportedOptions,
        error.InvalidTotalLength => return error.InvalidTotalLength,
        error.PayloadTooLarge => return error.PayloadTooLarge,
        error.HeaderChecksumMismatch => return error.HeaderChecksumMismatch,
        error.FrameTooShort => return error.FrameTooShort,
        error.InvalidLength => return error.InvalidLength,
        error.ChecksumMismatch => return error.ChecksumMismatch,
    };
}

pub fn pollUdpPacketStrictInto(result: *UdpPacket) StrictUdpPollError!bool {
    var packet_opt = try pollIpv4PacketStrict();
    if (packet_opt) |*packet| {
        if (packet.header.protocol != ipv4.protocol_udp) return error.NotUdp;

        const decoded = try udp.decode(packet.payload[0..packet.payload_len], packet.header.source_ip, packet.header.destination_ip);
        if (decoded.payload.len > max_udp_payload_len) return error.PayloadTooLarge;

        result.* = .{
            .ethernet_destination = packet.ethernet_destination,
            .ethernet_source = packet.ethernet_source,
            .ipv4_header = packet.header,
            .source_port = decoded.source_port,
            .destination_port = decoded.destination_port,
            .checksum_value = decoded.checksum_value,
            .payload_len = decoded.payload.len,
            .payload = [_]u8{0} ** max_udp_payload_len,
        };
        std.mem.copyForwards(u8, result.payload[0..decoded.payload.len], decoded.payload);
        return true;
    }
    return false;
}

pub fn pollUdpPacketStrict() StrictUdpPollError!?UdpPacket {
    var result: UdpPacket = undefined;
    if (try pollUdpPacketStrictInto(&result)) {
        return result;
    }
    return null;
}

test "baremetal net pal bridges rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const mac = macAddress();
    try std.testing.expectEqual(@as(u8, 0x52), mac[0]);

    var frame = [_]u8{0} ** 64;
    std.mem.copyForwards(u8, frame[0..6], mac[0..]);
    std.mem.copyForwards(u8, frame[6..12], mac[0..]);
    frame[12] = 0x88;
    frame[13] = 0xB5;
    frame[14] = 0x41;
    try sendFrame(frame[0..]);

    const rx_len = try pollReceive();
    try std.testing.expectEqual(@as(u32, 64), rx_len);
    try std.testing.expectEqual(@as(u8, 0x88), rxByte(12));
    try std.testing.expectEqual(@as(u8, 0x41), rxByte(14));
}

test "baremetal net pal sends and parses arp request through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const sender_ip = [4]u8{ 192, 168, 56, 10 };
    const target_ip = [4]u8{ 192, 168, 56, 1 };

    try std.testing.expectEqual(@as(u32, arp.frame_len), try sendArpRequest(sender_ip, target_ip));
    const packet = (try pollArpPacket()).?;

    try std.testing.expectEqual(arp.operation_request, packet.operation);
    try std.testing.expectEqualSlices(u8, ethernet.broadcast_mac[0..], packet.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, macAddress()[0..], packet.ethernet_source[0..]);
    try std.testing.expectEqualSlices(u8, macAddress()[0..], packet.sender_mac[0..]);
    try std.testing.expectEqualSlices(u8, sender_ip[0..], packet.sender_ip[0..]);
    try std.testing.expectEqualSlices(u8, target_ip[0..], packet.target_ip[0..]);
}

test "baremetal net pal sends and parses ipv4 frame through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "PING";

    try std.testing.expectEqual(
        @as(u32, ethernet.header_len + ipv4.header_len + payload.len),
        try sendIpv4Frame(macAddress(), source_ip, destination_ip, ipv4.protocol_udp, payload),
    );

    const packet = (try pollIpv4Packet()).?;
    try std.testing.expectEqual(ipv4.protocol_udp, packet.header.protocol);
    try std.testing.expectEqualSlices(u8, macAddress()[0..], packet.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, macAddress()[0..], packet.ethernet_source[0..]);
    try std.testing.expectEqualSlices(u8, source_ip[0..], packet.header.source_ip[0..]);
    try std.testing.expectEqualSlices(u8, destination_ip[0..], packet.header.destination_ip[0..]);
    try std.testing.expectEqualSlices(u8, payload, packet.payload[0..packet.payload_len]);
}

test "baremetal net pal strict ipv4 poll reports non-ipv4 frame" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const sender_ip = [4]u8{ 192, 168, 56, 10 };
    const target_ip = [4]u8{ 192, 168, 56, 1 };
    _ = try sendArpRequest(sender_ip, target_ip);

    try std.testing.expectError(error.NotIpv4, pollIpv4PacketStrict());
}

test "baremetal net pal sends and parses udp packet through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-UDP";

    _ = try sendUdpPacket(macAddress(), source_ip, destination_ip, 4321, 9001, payload);

    const packet = (try pollUdpPacket()).?;
    try std.testing.expectEqual(@as(u16, 4321), packet.source_port);
    try std.testing.expectEqual(@as(u16, 9001), packet.destination_port);
    try std.testing.expectEqual(ipv4.protocol_udp, packet.ipv4_header.protocol);
    try std.testing.expectEqualSlices(u8, source_ip[0..], packet.ipv4_header.source_ip[0..]);
    try std.testing.expectEqualSlices(u8, destination_ip[0..], packet.ipv4_header.destination_ip[0..]);
    try std.testing.expectEqualSlices(u8, payload, packet.payload[0..packet.payload_len]);
    try std.testing.expect(packet.checksum_value != 0);
}

test "baremetal net pal strict udp poll reports non-udp ipv4 frame" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "PING";

    _ = try sendIpv4Frame(macAddress(), source_ip, destination_ip, 1, payload);
    try std.testing.expectError(error.NotUdp, pollUdpPacketStrict());
}
