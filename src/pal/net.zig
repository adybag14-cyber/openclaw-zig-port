const std = @import("std");
const builtin = @import("builtin");
const time_util = @import("../util/time.zig");
const abi = @import("../baremetal/abi.zig");
const rtl8139 = @import("../baremetal/rtl8139.zig");
const ethernet = @import("../protocol/ethernet.zig");
const arp = @import("../protocol/arp.zig");
const dhcp = @import("../protocol/dhcp.zig");
const dns = @import("../protocol/dns.zig");
const ipv4 = @import("../protocol/ipv4.zig");
const tcp = @import("../protocol/tcp.zig");
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
pub const DhcpError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error || dhcp.Error;
pub const DnsError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error || dns.Error;
pub const Ipv4Error = rtl8139.Error || ethernet.Error || ipv4.Error;
pub const TcpError = rtl8139.Error || ethernet.Error || ipv4.Error || tcp.Error;
pub const UdpError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error;
pub const StrictDhcpPollError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error || dhcp.Error || error{ NotIpv4, NotUdp, NotDhcp };
pub const StrictDnsPollError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error || dns.Error || error{ NotIpv4, NotUdp, NotDns };
pub const StrictIpv4PollError = rtl8139.Error || ethernet.Error || ipv4.Error || error{NotIpv4};
pub const StrictTcpPollError = rtl8139.Error || ethernet.Error || ipv4.Error || tcp.Error || error{ NotIpv4, NotTcp };
pub const StrictUdpPollError = rtl8139.Error || ethernet.Error || ipv4.Error || udp.Error || error{ NotIpv4, NotUdp };
pub const max_frame_len: usize = 2048;
pub const max_ipv4_payload_len: usize = max_frame_len - ethernet.header_len - ipv4.header_len;
pub const max_tcp_payload_len: usize = max_ipv4_payload_len - tcp.header_len;
pub const max_udp_payload_len: usize = max_ipv4_payload_len - udp.header_len;
pub const max_dhcp_parameter_request_list_len: usize = 64;
pub const max_dhcp_client_identifier_len: usize = 32;
pub const max_dhcp_hostname_len: usize = 64;
pub const max_dhcp_dns_servers: usize = 2;
pub const max_dns_name_len: usize = dns.max_name_len;
pub const max_dns_answers: usize = dns.max_answers;
pub const max_dns_answer_data_len: usize = dns.max_answer_data_len;

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

pub const TcpPacket = struct {
    ethernet_destination: [ethernet.mac_len]u8,
    ethernet_source: [ethernet.mac_len]u8,
    ipv4_header: ipv4.Header,
    source_port: u16,
    destination_port: u16,
    sequence_number: u32,
    acknowledgment_number: u32,
    flags: u16,
    window_size: u16,
    checksum_value: u16,
    urgent_pointer: u16,
    payload_len: usize,
    payload: [max_tcp_payload_len]u8,
};

pub const DhcpPacket = struct {
    ethernet_destination: [ethernet.mac_len]u8,
    ethernet_source: [ethernet.mac_len]u8,
    ipv4_header: ipv4.Header,
    source_port: u16,
    destination_port: u16,
    udp_checksum_value: u16,
    op: u8,
    transaction_id: u32,
    flags: u16,
    client_ip: [4]u8,
    your_ip: [4]u8,
    server_ip: [4]u8,
    gateway_ip: [4]u8,
    client_mac: [ethernet.mac_len]u8,
    message_type: ?u8,
    subnet_mask_valid: bool,
    subnet_mask: [4]u8,
    router_valid: bool,
    router: [4]u8,
    requested_ip_valid: bool,
    requested_ip: [4]u8,
    server_identifier_valid: bool,
    server_identifier: [4]u8,
    lease_time_valid: bool,
    lease_time_seconds: u32,
    max_message_size_valid: bool,
    max_message_size: u16,
    dns_server_count: usize,
    dns_servers: [max_dhcp_dns_servers][4]u8,
    parameter_request_list_len: usize,
    parameter_request_list: [max_dhcp_parameter_request_list_len]u8,
    client_identifier_len: usize,
    client_identifier: [max_dhcp_client_identifier_len]u8,
    hostname_len: usize,
    hostname: [max_dhcp_hostname_len]u8,
    options_len: usize,
    options: [max_udp_payload_len]u8,
};

pub const DnsPacket = struct {
    ethernet_destination: [ethernet.mac_len]u8,
    ethernet_source: [ethernet.mac_len]u8,
    ipv4_header: ipv4.Header,
    source_port: u16,
    destination_port: u16,
    udp_checksum_value: u16,
    id: u16,
    flags: u16,
    question_count: u16,
    answer_count_total: u16,
    authority_count: u16,
    additional_count: u16,
    question_name_len: usize,
    question_name: [max_dns_name_len]u8,
    question_type: u16,
    question_class: u16,
    answer_count: usize,
    answers: [max_dns_answers]dns.Answer,
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
    if (copy_len < ethernet.header_len) return error.FrameTooShort;

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

pub fn sendDhcpDiscover(
    transaction_id: u32,
    client_mac: [ethernet.mac_len]u8,
    parameter_request_list: []const u8,
) DhcpError!u32 {
    return sendDhcpDiscoverWithEnvelope(
        ethernet.broadcast_mac,
        .{ 0, 0, 0, 0 },
        .{ 255, 255, 255, 255 },
        transaction_id,
        client_mac,
        parameter_request_list,
    );
}

pub fn sendDhcpDiscoverWithEnvelope(
    destination_mac: [ethernet.mac_len]u8,
    source_ip: [4]u8,
    destination_ip: [4]u8,
    transaction_id: u32,
    client_mac: [ethernet.mac_len]u8,
    parameter_request_list: []const u8,
) DhcpError!u32 {
    if (!initDevice()) return error.NotAvailable;

    var segment: [max_ipv4_payload_len]u8 = undefined;
    const segment_len = try dhcp.encodeDiscover(segment[0..], client_mac, transaction_id, parameter_request_list);
    return try sendUdpPacket(
        destination_mac,
        source_ip,
        destination_ip,
        dhcp.client_port,
        dhcp.server_port,
        segment[0..segment_len],
    );
}

pub fn sendDnsQuery(
    destination_mac: [ethernet.mac_len]u8,
    source_ip: [4]u8,
    destination_ip: [4]u8,
    source_port: u16,
    id: u16,
    name: []const u8,
    qtype: u16,
) DnsError!u32 {
    if (!initDevice()) return error.NotAvailable;

    var segment: [max_ipv4_payload_len]u8 = undefined;
    const segment_len = try dns.encodeQuery(segment[0..], id, name, qtype);
    return try sendUdpPacket(destination_mac, source_ip, destination_ip, source_port, dns.default_port, segment[0..segment_len]);
}

pub fn sendTcpPacket(
    destination_mac: [ethernet.mac_len]u8,
    source_ip: [4]u8,
    destination_ip: [4]u8,
    source_port: u16,
    destination_port: u16,
    sequence_number: u32,
    acknowledgment_number: u32,
    flags: u16,
    window_size: u16,
    payload: []const u8,
) TcpError!u32 {
    if (!initDevice()) return error.NotAvailable;

    var segment: [max_ipv4_payload_len]u8 = undefined;
    const tcp_header = tcp.Header{
        .source_port = source_port,
        .destination_port = destination_port,
        .sequence_number = sequence_number,
        .acknowledgment_number = acknowledgment_number,
        .flags = flags,
        .window_size = window_size,
    };
    const segment_len = try tcp_header.encode(segment[0..], payload, source_ip, destination_ip);
    return try sendIpv4Frame(destination_mac, source_ip, destination_ip, ipv4.protocol_tcp, segment[0..segment_len]);
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

pub fn pollTcpPacket() TcpError!?TcpPacket {
    return pollTcpPacketStrict() catch |err| switch (err) {
        error.NotIpv4, error.NotTcp => null,
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
        error.InvalidDataOffset => return error.InvalidDataOffset,
        error.ChecksumMismatch => return error.ChecksumMismatch,
    };
}

pub fn pollDnsPacket() DnsError!?DnsPacket {
    return pollDnsPacketStrict() catch |err| switch (err) {
        error.NotIpv4, error.NotUdp, error.NotDns => null,
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
        error.InvalidLabelLength => return error.InvalidLabelLength,
        error.InvalidPointer => return error.InvalidPointer,
        error.UnsupportedLabelType => return error.UnsupportedLabelType,
        error.NameTooLong => return error.NameTooLong,
        error.CompressionLoop => return error.CompressionLoop,
        error.UnsupportedQuestionCount => return error.UnsupportedQuestionCount,
        error.ResourceDataTooLarge => return error.ResourceDataTooLarge,
    };
}

pub fn pollDhcpPacket() DhcpError!?DhcpPacket {
    return pollDhcpPacketStrict() catch |err| switch (err) {
        error.NotIpv4, error.NotUdp, error.NotDhcp => null,
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
        error.InvalidOperation => return error.InvalidOperation,
        error.InvalidHardwareType => return error.InvalidHardwareType,
        error.InvalidHardwareLength => return error.InvalidHardwareLength,
        error.InvalidMagicCookie => return error.InvalidMagicCookie,
        error.OptionTruncated => return error.OptionTruncated,
        error.FieldLengthMismatch => return error.FieldLengthMismatch,
    };
}

pub fn pollDnsPacketStrictInto(result: *DnsPacket) StrictDnsPollError!bool {
    var packet: UdpPacket = undefined;
    if (!(try pollUdpPacketStrictInto(&packet))) return false;
    if (!(packet.source_port == dns.default_port or packet.destination_port == dns.default_port)) return error.NotDns;

    const decoded = try dns.decode(packet.payload[0..packet.payload_len]);

    result.ethernet_destination = packet.ethernet_destination;
    result.ethernet_source = packet.ethernet_source;
    result.ipv4_header = packet.ipv4_header;
    result.source_port = packet.source_port;
    result.destination_port = packet.destination_port;
    result.udp_checksum_value = packet.checksum_value;
    result.id = decoded.id;
    result.flags = decoded.flags;
    result.question_count = decoded.question_count;
    result.answer_count_total = decoded.answer_count_total;
    result.authority_count = decoded.authority_count;
    result.additional_count = decoded.additional_count;
    result.question_name_len = decoded.question_name_len;
    result.question_name = [_]u8{0} ** max_dns_name_len;
    if (decoded.question_name_len > 0) {
        std.mem.copyForwards(u8, result.question_name[0..decoded.question_name_len], decoded.question_name[0..decoded.question_name_len]);
    }
    result.question_type = decoded.question_type;
    result.question_class = decoded.question_class;
    result.answer_count = decoded.answer_count;

    var answer_index: usize = 0;
    while (answer_index < max_dns_answers) : (answer_index += 1) {
        if (answer_index < decoded.answer_count) {
            result.answers[answer_index] = decoded.answers[answer_index];
        } else {
            result.answers[answer_index] = std.mem.zeroes(dns.Answer);
        }
    }
    return true;
}

pub fn pollDhcpPacketStrictInto(result: *DhcpPacket) StrictDhcpPollError!bool {
    const packet_opt = try pollUdpPacketStrict();
    if (packet_opt) |packet| {
        if (!((packet.source_port == dhcp.client_port and packet.destination_port == dhcp.server_port) or
            (packet.source_port == dhcp.server_port and packet.destination_port == dhcp.client_port)))
        {
            return error.NotDhcp;
        }

        const decoded = try dhcp.decode(packet.payload[0..packet.payload_len]);
        if (decoded.parameter_request_list.len > max_dhcp_parameter_request_list_len) return error.PayloadTooLarge;
        if (decoded.client_identifier.len > max_dhcp_client_identifier_len) return error.PayloadTooLarge;
        if (decoded.hostname.len > max_dhcp_hostname_len) return error.PayloadTooLarge;
        if (decoded.options.len > max_udp_payload_len) return error.PayloadTooLarge;

        result.* = .{
            .ethernet_destination = packet.ethernet_destination,
            .ethernet_source = packet.ethernet_source,
            .ipv4_header = packet.ipv4_header,
            .source_port = packet.source_port,
            .destination_port = packet.destination_port,
            .udp_checksum_value = packet.checksum_value,
            .op = decoded.op,
            .transaction_id = decoded.transaction_id,
            .flags = decoded.flags,
            .client_ip = decoded.client_ip,
            .your_ip = decoded.your_ip,
            .server_ip = decoded.server_ip,
            .gateway_ip = decoded.gateway_ip,
            .client_mac = decoded.client_mac,
            .message_type = decoded.message_type,
            .subnet_mask_valid = decoded.subnet_mask != null,
            .subnet_mask = decoded.subnet_mask orelse [_]u8{ 0, 0, 0, 0 },
            .router_valid = decoded.router != null,
            .router = decoded.router orelse [_]u8{ 0, 0, 0, 0 },
            .requested_ip_valid = decoded.requested_ip != null,
            .requested_ip = decoded.requested_ip orelse [_]u8{ 0, 0, 0, 0 },
            .server_identifier_valid = decoded.server_identifier != null,
            .server_identifier = decoded.server_identifier orelse [_]u8{ 0, 0, 0, 0 },
            .lease_time_valid = decoded.lease_time_seconds != null,
            .lease_time_seconds = decoded.lease_time_seconds orelse 0,
            .max_message_size_valid = decoded.max_message_size != null,
            .max_message_size = decoded.max_message_size orelse 0,
            .dns_server_count = decoded.dns_server_count,
            .dns_servers = [_][4]u8{
                [_]u8{ 0, 0, 0, 0 },
                [_]u8{ 0, 0, 0, 0 },
            },
            .parameter_request_list_len = decoded.parameter_request_list.len,
            .parameter_request_list = [_]u8{0} ** max_dhcp_parameter_request_list_len,
            .client_identifier_len = decoded.client_identifier.len,
            .client_identifier = [_]u8{0} ** max_dhcp_client_identifier_len,
            .hostname_len = decoded.hostname.len,
            .hostname = [_]u8{0} ** max_dhcp_hostname_len,
            .options_len = decoded.options.len,
            .options = [_]u8{0} ** max_udp_payload_len,
        };
        if (decoded.dns_server_count > 0) {
            std.mem.copyForwards([4]u8, result.dns_servers[0..decoded.dns_server_count], decoded.dns_servers[0..decoded.dns_server_count]);
        }
        std.mem.copyForwards(u8, result.parameter_request_list[0..decoded.parameter_request_list.len], decoded.parameter_request_list);
        std.mem.copyForwards(u8, result.client_identifier[0..decoded.client_identifier.len], decoded.client_identifier);
        std.mem.copyForwards(u8, result.hostname[0..decoded.hostname.len], decoded.hostname);
        std.mem.copyForwards(u8, result.options[0..decoded.options.len], decoded.options);
        return true;
    }
    return false;
}

pub fn pollTcpPacketStrictInto(result: *TcpPacket) StrictTcpPollError!bool {
    var packet_opt = try pollIpv4PacketStrict();
    if (packet_opt) |*packet| {
        if (packet.header.protocol != ipv4.protocol_tcp) return error.NotTcp;

        const decoded = try tcp.decode(packet.payload[0..packet.payload_len], packet.header.source_ip, packet.header.destination_ip);
        if (decoded.payload.len > max_tcp_payload_len) return error.PayloadTooLarge;

        result.* = .{
            .ethernet_destination = packet.ethernet_destination,
            .ethernet_source = packet.ethernet_source,
            .ipv4_header = packet.header,
            .source_port = decoded.source_port,
            .destination_port = decoded.destination_port,
            .sequence_number = decoded.sequence_number,
            .acknowledgment_number = decoded.acknowledgment_number,
            .flags = decoded.flags,
            .window_size = decoded.window_size,
            .checksum_value = decoded.checksum_value,
            .urgent_pointer = decoded.urgent_pointer,
            .payload_len = decoded.payload.len,
            .payload = [_]u8{0} ** max_tcp_payload_len,
        };
        std.mem.copyForwards(u8, result.payload[0..decoded.payload.len], decoded.payload);
        return true;
    }
    return false;
}

pub fn pollTcpPacketStrict() StrictTcpPollError!?TcpPacket {
    var result: TcpPacket = undefined;
    if (try pollTcpPacketStrictInto(&result)) {
        return result;
    }
    return null;
}

pub fn pollDnsPacketStrict() StrictDnsPollError!?DnsPacket {
    var result: DnsPacket = undefined;
    if (try pollDnsPacketStrictInto(&result)) {
        return result;
    }
    return null;
}

pub fn pollDhcpPacketStrict() StrictDhcpPollError!?DhcpPacket {
    var result: DhcpPacket = undefined;
    if (try pollDhcpPacketStrictInto(&result)) {
        return result;
    }
    return null;
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

test "baremetal net pal sends and parses tcp packet through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-TCP";

    _ = try sendTcpPacket(macAddress(), source_ip, destination_ip, 4321, 443, 0x0102_0304, 0xA0B0_C0D0, tcp.flag_ack | tcp.flag_psh, 8192, payload);

    const packet = (try pollTcpPacket()).?;
    try std.testing.expectEqual(@as(u16, 4321), packet.source_port);
    try std.testing.expectEqual(@as(u16, 443), packet.destination_port);
    try std.testing.expectEqual(@as(u32, 0x0102_0304), packet.sequence_number);
    try std.testing.expectEqual(@as(u32, 0xA0B0_C0D0), packet.acknowledgment_number);
    try std.testing.expectEqual(ipv4.protocol_tcp, packet.ipv4_header.protocol);
    try std.testing.expectEqual(tcp.flag_ack | tcp.flag_psh, packet.flags);
    try std.testing.expectEqual(@as(u16, 8192), packet.window_size);
    try std.testing.expectEqualSlices(u8, source_ip[0..], packet.ipv4_header.source_ip[0..]);
    try std.testing.expectEqualSlices(u8, destination_ip[0..], packet.ipv4_header.destination_ip[0..]);
    try std.testing.expectEqualSlices(u8, payload, packet.payload[0..packet.payload_len]);
}

test "baremetal net pal sends and parses dhcp discover through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const client_mac = macAddress();
    const parameter_request_list = [_]u8{
        dhcp.option_subnet_mask,
        dhcp.option_router,
        dhcp.option_dns_server,
        dhcp.option_hostname,
    };

    _ = try sendDhcpDiscover(0x1234_5678, client_mac, parameter_request_list[0..]);

    const packet = (try pollDhcpPacket()).?;
    try std.testing.expectEqual(@as(u16, dhcp.client_port), packet.source_port);
    try std.testing.expectEqual(@as(u16, dhcp.server_port), packet.destination_port);
    try std.testing.expectEqual(ipv4.protocol_udp, packet.ipv4_header.protocol);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, packet.ipv4_header.source_ip[0..]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, packet.ipv4_header.destination_ip[0..]);
    try std.testing.expectEqualSlices(u8, ethernet.broadcast_mac[0..], packet.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, client_mac[0..], packet.ethernet_source[0..]);
    try std.testing.expectEqual(@as(u8, dhcp.boot_request), packet.op);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), packet.transaction_id);
    try std.testing.expectEqual(@as(u16, dhcp.flags_broadcast), packet.flags);
    try std.testing.expectEqual(dhcp.message_type_discover, packet.message_type.?);
    try std.testing.expectEqualSlices(u8, client_mac[0..], packet.client_mac[0..]);
    try std.testing.expectEqualSlices(u8, parameter_request_list[0..], packet.parameter_request_list[0..packet.parameter_request_list_len]);
    try std.testing.expect(packet.max_message_size_valid);
    try std.testing.expectEqual(@as(u16, 1500), packet.max_message_size);
    try std.testing.expect(packet.udp_checksum_value != 0);
}

test "baremetal net pal sends and parses dns query through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const source_port: u16 = 53000;
    const query_name = "openclaw.local";

    _ = try sendDnsQuery(macAddress(), source_ip, destination_ip, source_port, 0x1234, query_name, dns.type_a);

    const packet = (try pollDnsPacket()).?;
    try std.testing.expectEqual(@as(u16, source_port), packet.source_port);
    try std.testing.expectEqual(@as(u16, dns.default_port), packet.destination_port);
    try std.testing.expectEqual(ipv4.protocol_udp, packet.ipv4_header.protocol);
    try std.testing.expectEqual(@as(u16, 0x1234), packet.id);
    try std.testing.expectEqual(dns.flags_standard_query, packet.flags);
    try std.testing.expectEqual(@as(u16, 1), packet.question_count);
    try std.testing.expectEqualStrings(query_name, packet.question_name[0..packet.question_name_len]);
    try std.testing.expectEqual(dns.type_a, packet.question_type);
    try std.testing.expectEqual(dns.class_in, packet.question_class);
    try std.testing.expectEqual(@as(usize, 0), packet.answer_count);
    try std.testing.expect(packet.udp_checksum_value != 0);
}

test "baremetal net pal sends and parses dns A response through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const client_port: u16 = 53000;
    const query_name = "openclaw.local";
    const address = [4]u8{ 192, 168, 56, 1 };

    var payload: [max_ipv4_payload_len]u8 = undefined;
    const payload_len = try dns.encodeAResponse(payload[0..], 0xBEEF, query_name, 300, address);
    _ = try sendUdpPacket(macAddress(), server_ip, client_ip, dns.default_port, client_port, payload[0..payload_len]);

    const packet = (try pollDnsPacket()).?;
    try std.testing.expectEqual(@as(u16, dns.default_port), packet.source_port);
    try std.testing.expectEqual(@as(u16, client_port), packet.destination_port);
    try std.testing.expectEqual(@as(u16, 0xBEEF), packet.id);
    try std.testing.expectEqual(dns.flags_standard_success_response, packet.flags);
    try std.testing.expectEqualStrings(query_name, packet.question_name[0..packet.question_name_len]);
    try std.testing.expectEqual(@as(u16, 1), packet.answer_count_total);
    try std.testing.expectEqual(@as(usize, 1), packet.answer_count);
    try std.testing.expectEqualStrings(query_name, packet.answers[0].nameSlice());
    try std.testing.expectEqual(dns.type_a, packet.answers[0].rr_type);
    try std.testing.expectEqual(dns.class_in, packet.answers[0].rr_class);
    try std.testing.expectEqual(@as(u32, 300), packet.answers[0].ttl);
    try std.testing.expectEqualSlices(u8, address[0..], packet.answers[0].dataSlice());
}

test "baremetal net pal strict dns poll reports non-dns udp frame" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-UDP";

    _ = try sendUdpPacket(macAddress(), source_ip, destination_ip, 4321, 9001, payload);
    try std.testing.expectError(error.NotDns, pollDnsPacketStrict());
}

test "baremetal net pal strict dhcp poll reports non-dhcp udp frame" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-UDP";

    _ = try sendUdpPacket(macAddress(), source_ip, destination_ip, 4321, 9001, payload);
    try std.testing.expectError(error.NotDhcp, pollDhcpPacketStrict());
}

test "baremetal net pal strict tcp poll reports non-tcp ipv4 frame" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const source_ip = [4]u8{ 192, 168, 56, 10 };
    const destination_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "OPENCLAW-UDP";

    _ = try sendUdpPacket(macAddress(), source_ip, destination_ip, 4321, 9001, payload);
    try std.testing.expectError(error.NotTcp, pollTcpPacketStrict());
}
