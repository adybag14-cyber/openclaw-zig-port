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
pub const RouteError = error{
    RouteUnconfigured,
    MissingLeaseIp,
    MissingSubnetMask,
    AddressUnresolved,
};
pub const RoutedUdpError = UdpError || RouteError;
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
pub const arp_cache_capacity: usize = 8;

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

pub const ArpCacheEntry = struct {
    valid: bool,
    ip: [4]u8,
    mac: [ethernet.mac_len]u8,
};

pub const RouteDecision = struct {
    next_hop_ip: [4]u8,
    used_gateway: bool,
};

pub const RouteState = struct {
    configured: bool,
    local_ip: [4]u8,
    subnet_mask_valid: bool,
    subnet_mask: [4]u8,
    gateway_valid: bool,
    gateway: [4]u8,
    last_next_hop: [4]u8,
    last_used_gateway: bool,
    last_cache_hit: bool,
    pending_resolution: bool,
    pending_ip: [4]u8,
    cache_entry_count: usize,
    cache: [arp_cache_capacity]ArpCacheEntry,
};

fn defaultRouteState() RouteState {
    return .{
        .configured = false,
        .local_ip = [_]u8{ 0, 0, 0, 0 },
        .subnet_mask_valid = false,
        .subnet_mask = [_]u8{ 0, 0, 0, 0 },
        .gateway_valid = false,
        .gateway = [_]u8{ 0, 0, 0, 0 },
        .last_next_hop = [_]u8{ 0, 0, 0, 0 },
        .last_used_gateway = false,
        .last_cache_hit = false,
        .pending_resolution = false,
        .pending_ip = [_]u8{ 0, 0, 0, 0 },
        .cache_entry_count = 0,
        .cache = [_]ArpCacheEntry{.{
            .valid = false,
            .ip = [_]u8{ 0, 0, 0, 0 },
            .mac = [_]u8{ 0, 0, 0, 0, 0, 0 },
        }} ** arp_cache_capacity,
    };
}

var route_state: RouteState = defaultRouteState();
var route_cache_insert_index: usize = 0;

fn ipv4IsZero(ip: [4]u8) bool {
    return std.mem.eql(u8, ip[0..], &[_]u8{ 0, 0, 0, 0 });
}

fn macIsZero(mac: [ethernet.mac_len]u8) bool {
    return std.mem.eql(u8, mac[0..], &[_]u8{ 0, 0, 0, 0, 0, 0 });
}

fn sameSubnet(local_ip: [4]u8, destination_ip: [4]u8, subnet_mask: [4]u8) bool {
    var index: usize = 0;
    while (index < 4) : (index += 1) {
        if ((local_ip[index] & subnet_mask[index]) != (destination_ip[index] & subnet_mask[index])) return false;
    }
    return true;
}

fn arpCacheIndexFor(ip: [4]u8) ?usize {
    var index: usize = 0;
    while (index < route_state.cache.len) : (index += 1) {
        if (route_state.cache[index].valid and std.mem.eql(u8, route_state.cache[index].ip[0..], ip[0..])) {
            return index;
        }
    }
    return null;
}

fn arpCacheUpsert(ip: [4]u8, mac: [ethernet.mac_len]u8) void {
    if (arpCacheIndexFor(ip)) |existing_index| {
        route_state.cache[existing_index].mac = mac;
        return;
    }

    const insert_index = route_cache_insert_index;
    const was_valid = route_state.cache[insert_index].valid;
    route_state.cache[insert_index] = .{
        .valid = true,
        .ip = ip,
        .mac = mac,
    };
    if (!was_valid and route_state.cache_entry_count < route_state.cache.len) {
        route_state.cache_entry_count += 1;
    }
    route_cache_insert_index = (route_cache_insert_index + 1) % route_state.cache.len;
}

pub fn clearRouteState() void {
    route_state = defaultRouteState();
    route_cache_insert_index = 0;
}

pub fn clearRouteStateForTest() void {
    if (!builtin.is_test) return;
    clearRouteState();
}

pub fn routeStatePtr() *const RouteState {
    return &route_state;
}

pub fn configureIpv4Route(local_ip: [4]u8, subnet_mask: ?[4]u8, gateway: ?[4]u8) void {
    route_state.configured = true;
    route_state.local_ip = local_ip;
    route_state.subnet_mask_valid = subnet_mask != null;
    route_state.subnet_mask = subnet_mask orelse [_]u8{ 0, 0, 0, 0 };
    route_state.gateway_valid = gateway != null and !ipv4IsZero(gateway.?);
    route_state.gateway = gateway orelse [_]u8{ 0, 0, 0, 0 };
    route_state.last_next_hop = [_]u8{ 0, 0, 0, 0 };
    route_state.last_used_gateway = false;
    route_state.last_cache_hit = false;
    route_state.pending_resolution = false;
    route_state.pending_ip = [_]u8{ 0, 0, 0, 0 };
}

pub fn configureIpv4RouteFromDhcp(packet: *const DhcpPacket) RouteError!void {
    if (ipv4IsZero(packet.your_ip)) return error.MissingLeaseIp;
    if (!packet.subnet_mask_valid) return error.MissingSubnetMask;
    const gateway: ?[4]u8 = if (packet.router_valid and !ipv4IsZero(packet.router)) packet.router else null;
    configureIpv4Route(packet.your_ip, packet.subnet_mask, gateway);
}

pub fn resolveNextHop(destination_ip: [4]u8) RouteError!RouteDecision {
    if (!route_state.configured) return error.RouteUnconfigured;

    const used_gateway = route_state.subnet_mask_valid and route_state.gateway_valid and
        !sameSubnet(route_state.local_ip, destination_ip, route_state.subnet_mask);
    const next_hop_ip = if (used_gateway) route_state.gateway else destination_ip;
    route_state.last_next_hop = next_hop_ip;
    route_state.last_used_gateway = used_gateway;
    route_state.last_cache_hit = false;
    return .{
        .next_hop_ip = next_hop_ip,
        .used_gateway = used_gateway,
    };
}

pub fn lookupArpCache(ip: [4]u8) ?[ethernet.mac_len]u8 {
    if (arpCacheIndexFor(ip)) |index| {
        route_state.last_cache_hit = true;
        return route_state.cache[index].mac;
    }
    route_state.last_cache_hit = false;
    return null;
}

pub fn learnArpPacket(packet: ArpPacket) bool {
    if (ipv4IsZero(packet.sender_ip) or macIsZero(packet.sender_mac)) return false;
    if (route_state.configured and
        std.mem.eql(u8, route_state.local_ip[0..], packet.sender_ip[0..]) and
        std.mem.eql(u8, macAddress()[0..], packet.sender_mac[0..]))
    {
        return false;
    }

    arpCacheUpsert(packet.sender_ip, packet.sender_mac);
    if (std.mem.eql(u8, route_state.pending_ip[0..], packet.sender_ip[0..])) {
        route_state.pending_resolution = false;
    }
    return true;
}

pub fn sendUdpPacketRouted(
    destination_ip: [4]u8,
    source_port: u16,
    destination_port: u16,
    payload: []const u8,
) RoutedUdpError!u32 {
    const route = try resolveNextHop(destination_ip);
    if (lookupArpCache(route.next_hop_ip)) |destination_mac| {
        return try sendUdpPacket(
            destination_mac,
            route_state.local_ip,
            destination_ip,
            source_port,
            destination_port,
            payload,
        );
    }

    _ = sendArpRequest(route_state.local_ip, route.next_hop_ip) catch |err| switch (err) {
        error.BufferTooSmall => unreachable,
        error.NotAvailable => return error.NotAvailable,
        error.NotInitialized => return error.NotInitialized,
        error.Timeout => return error.Timeout,
        error.HardwareFault => return error.HardwareFault,
        else => return error.HardwareFault,
    };
    route_state.pending_resolution = true;
    route_state.pending_ip = route.next_hop_ip;
    return error.AddressUnresolved;
}

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
        error.WindowExceeded => return error.WindowExceeded,
        error.HeaderChecksumMismatch => return error.HeaderChecksumMismatch,
        error.FrameTooShort => return error.FrameTooShort,
        error.InvalidDataOffset => return error.InvalidDataOffset,
        error.ChecksumMismatch => return error.ChecksumMismatch,
        error.EmptyPayload => return error.EmptyPayload,
        error.InvalidState => return error.InvalidState,
        error.UnexpectedFlags => return error.UnexpectedFlags,
        error.PortMismatch => return error.PortMismatch,
        error.SequenceMismatch => return error.SequenceMismatch,
        error.AcknowledgmentMismatch => return error.AcknowledgmentMismatch,
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

test "baremetal net pal completes tcp handshake and payload exchange through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const destination_mac = macAddress();
    const payload = "OPENCLAW-TCP-HANDSHAKE";

    var client = tcp.Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = tcp.Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    const syn = try client.buildSyn();
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, syn.sequence_number, syn.acknowledgment_number, syn.flags, syn.window_size, syn.payload);
    const syn_packet = (try pollTcpPacketStrict()).?;
    const syn_ack = try server.acceptSyn(.{
        .source_port = syn_packet.source_port,
        .destination_port = syn_packet.destination_port,
        .sequence_number = syn_packet.sequence_number,
        .acknowledgment_number = syn_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = syn_packet.flags,
        .window_size = syn_packet.window_size,
        .checksum_value = syn_packet.checksum_value,
        .urgent_pointer = syn_packet.urgent_pointer,
        .payload = syn_packet.payload[0..syn_packet.payload_len],
    });

    _ = try sendTcpPacket(destination_mac, server_ip, client_ip, server.local_port, server.remote_port, syn_ack.sequence_number, syn_ack.acknowledgment_number, syn_ack.flags, syn_ack.window_size, syn_ack.payload);
    const syn_ack_packet = (try pollTcpPacketStrict()).?;
    const ack = try client.acceptSynAck(.{
        .source_port = syn_ack_packet.source_port,
        .destination_port = syn_ack_packet.destination_port,
        .sequence_number = syn_ack_packet.sequence_number,
        .acknowledgment_number = syn_ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = syn_ack_packet.flags,
        .window_size = syn_ack_packet.window_size,
        .checksum_value = syn_ack_packet.checksum_value,
        .urgent_pointer = syn_ack_packet.urgent_pointer,
        .payload = syn_ack_packet.payload[0..syn_ack_packet.payload_len],
    });

    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, ack.sequence_number, ack.acknowledgment_number, ack.flags, ack.window_size, ack.payload);
    const ack_packet = (try pollTcpPacketStrict()).?;
    try server.acceptAck(.{
        .source_port = ack_packet.source_port,
        .destination_port = ack_packet.destination_port,
        .sequence_number = ack_packet.sequence_number,
        .acknowledgment_number = ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = ack_packet.flags,
        .window_size = ack_packet.window_size,
        .checksum_value = ack_packet.checksum_value,
        .urgent_pointer = ack_packet.urgent_pointer,
        .payload = ack_packet.payload[0..ack_packet.payload_len],
    });

    const data = try client.buildPayload(payload);
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, data.sequence_number, data.acknowledgment_number, data.flags, data.window_size, data.payload);
    const data_packet = (try pollTcpPacketStrict()).?;
    try server.acceptPayload(.{
        .source_port = data_packet.source_port,
        .destination_port = data_packet.destination_port,
        .sequence_number = data_packet.sequence_number,
        .acknowledgment_number = data_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = data_packet.flags,
        .window_size = data_packet.window_size,
        .checksum_value = data_packet.checksum_value,
        .urgent_pointer = data_packet.urgent_pointer,
        .payload = data_packet.payload[0..data_packet.payload_len],
    });

    try std.testing.expectEqual(tcp.State.established, client.state);
    try std.testing.expectEqual(tcp.State.established, server.state);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), client.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), server.recv_next);
}

test "baremetal net pal surfaces tcp handshake acknowledgment mismatch through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const destination_mac = macAddress();

    var client = tcp.Session.initClient(4321, 443, 0x0102_0304, 4096);
    _ = try client.buildSyn();

    _ = try sendTcpPacket(destination_mac, server_ip, client_ip, 443, 4321, 0xA0B0_C0D0, client.send_next +% 1, tcp.flag_syn | tcp.flag_ack, 8192, "");
    const syn_ack_packet = (try pollTcpPacketStrict()).?;
    try std.testing.expectError(error.AcknowledgmentMismatch, client.acceptSynAck(.{
        .source_port = syn_ack_packet.source_port,
        .destination_port = syn_ack_packet.destination_port,
        .sequence_number = syn_ack_packet.sequence_number,
        .acknowledgment_number = syn_ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = syn_ack_packet.flags,
        .window_size = syn_ack_packet.window_size,
        .checksum_value = syn_ack_packet.checksum_value,
        .urgent_pointer = syn_ack_packet.urgent_pointer,
        .payload = syn_ack_packet.payload[0..syn_ack_packet.payload_len],
    }));
}

test "baremetal net pal retransmits dropped syn and establishes tcp session through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const destination_mac = macAddress();
    const payload = "OPENCLAW-TCP-RETRY";

    var client = tcp.Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = tcp.Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    const syn = try client.buildSynWithTimeout(0, 4);
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, syn.sequence_number, syn.acknowledgment_number, syn.flags, syn.window_size, syn.payload);
    const first_syn_packet = (try pollTcpPacketStrict()).?;
    try std.testing.expectEqual(tcp.flag_syn, first_syn_packet.flags);
    try std.testing.expectEqual(syn.sequence_number, first_syn_packet.sequence_number);
    try std.testing.expectEqual(@as(?tcp.Outbound, null), client.pollRetransmit(3));

    const retry_syn = client.pollRetransmit(4).?;
    try std.testing.expectEqual(syn.sequence_number, retry_syn.sequence_number);
    try std.testing.expectEqual(syn.flags, retry_syn.flags);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, retry_syn.sequence_number, retry_syn.acknowledgment_number, retry_syn.flags, retry_syn.window_size, retry_syn.payload);
    const retry_syn_packet = (try pollTcpPacketStrict()).?;
    const syn_ack = try server.acceptSyn(.{
        .source_port = retry_syn_packet.source_port,
        .destination_port = retry_syn_packet.destination_port,
        .sequence_number = retry_syn_packet.sequence_number,
        .acknowledgment_number = retry_syn_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = retry_syn_packet.flags,
        .window_size = retry_syn_packet.window_size,
        .checksum_value = retry_syn_packet.checksum_value,
        .urgent_pointer = retry_syn_packet.urgent_pointer,
        .payload = retry_syn_packet.payload[0..retry_syn_packet.payload_len],
    });

    _ = try sendTcpPacket(destination_mac, server_ip, client_ip, server.local_port, server.remote_port, syn_ack.sequence_number, syn_ack.acknowledgment_number, syn_ack.flags, syn_ack.window_size, syn_ack.payload);
    const syn_ack_packet = (try pollTcpPacketStrict()).?;
    const ack = try client.acceptSynAck(.{
        .source_port = syn_ack_packet.source_port,
        .destination_port = syn_ack_packet.destination_port,
        .sequence_number = syn_ack_packet.sequence_number,
        .acknowledgment_number = syn_ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = syn_ack_packet.flags,
        .window_size = syn_ack_packet.window_size,
        .checksum_value = syn_ack_packet.checksum_value,
        .urgent_pointer = syn_ack_packet.urgent_pointer,
        .payload = syn_ack_packet.payload[0..syn_ack_packet.payload_len],
    });

    try std.testing.expect(!client.retransmit.armed());
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, ack.sequence_number, ack.acknowledgment_number, ack.flags, ack.window_size, ack.payload);
    const ack_packet = (try pollTcpPacketStrict()).?;
    try server.acceptAck(.{
        .source_port = ack_packet.source_port,
        .destination_port = ack_packet.destination_port,
        .sequence_number = ack_packet.sequence_number,
        .acknowledgment_number = ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = ack_packet.flags,
        .window_size = ack_packet.window_size,
        .checksum_value = ack_packet.checksum_value,
        .urgent_pointer = ack_packet.urgent_pointer,
        .payload = ack_packet.payload[0..ack_packet.payload_len],
    });

    const data = try client.buildPayload(payload);
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, data.sequence_number, data.acknowledgment_number, data.flags, data.window_size, data.payload);
    const data_packet = (try pollTcpPacketStrict()).?;
    try server.acceptPayload(.{
        .source_port = data_packet.source_port,
        .destination_port = data_packet.destination_port,
        .sequence_number = data_packet.sequence_number,
        .acknowledgment_number = data_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = data_packet.flags,
        .window_size = data_packet.window_size,
        .checksum_value = data_packet.checksum_value,
        .urgent_pointer = data_packet.urgent_pointer,
        .payload = data_packet.payload[0..data_packet.payload_len],
    });

    try std.testing.expectEqual(tcp.State.established, client.state);
    try std.testing.expectEqual(tcp.State.established, server.state);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), client.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), server.recv_next);
}

test "baremetal net pal retransmits dropped payload and clears timer on ack through rtl8139 mock device" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();

    try std.testing.expect(initDevice());
    const client_ip = [4]u8{ 192, 168, 56, 10 };
    const server_ip = [4]u8{ 192, 168, 56, 1 };
    const destination_mac = macAddress();
    const payload = "OPENCLAW-TCP-PAYLOAD-RETRY";

    var client = tcp.Session.initClient(4321, 443, 0x0102_0304, 4096);
    var server = tcp.Session.initServer(443, 4321, 0xA0B0_C0D0, 8192);

    const syn = try client.buildSyn();
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, syn.sequence_number, syn.acknowledgment_number, syn.flags, syn.window_size, syn.payload);
    const syn_packet = (try pollTcpPacketStrict()).?;
    const syn_ack = try server.acceptSyn(.{
        .source_port = syn_packet.source_port,
        .destination_port = syn_packet.destination_port,
        .sequence_number = syn_packet.sequence_number,
        .acknowledgment_number = syn_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = syn_packet.flags,
        .window_size = syn_packet.window_size,
        .checksum_value = syn_packet.checksum_value,
        .urgent_pointer = syn_packet.urgent_pointer,
        .payload = syn_packet.payload[0..syn_packet.payload_len],
    });

    _ = try sendTcpPacket(destination_mac, server_ip, client_ip, server.local_port, server.remote_port, syn_ack.sequence_number, syn_ack.acknowledgment_number, syn_ack.flags, syn_ack.window_size, syn_ack.payload);
    const syn_ack_packet = (try pollTcpPacketStrict()).?;
    const ack = try client.acceptSynAck(.{
        .source_port = syn_ack_packet.source_port,
        .destination_port = syn_ack_packet.destination_port,
        .sequence_number = syn_ack_packet.sequence_number,
        .acknowledgment_number = syn_ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = syn_ack_packet.flags,
        .window_size = syn_ack_packet.window_size,
        .checksum_value = syn_ack_packet.checksum_value,
        .urgent_pointer = syn_ack_packet.urgent_pointer,
        .payload = syn_ack_packet.payload[0..syn_ack_packet.payload_len],
    });

    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, ack.sequence_number, ack.acknowledgment_number, ack.flags, ack.window_size, ack.payload);
    const ack_packet = (try pollTcpPacketStrict()).?;
    try server.acceptAck(.{
        .source_port = ack_packet.source_port,
        .destination_port = ack_packet.destination_port,
        .sequence_number = ack_packet.sequence_number,
        .acknowledgment_number = ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = ack_packet.flags,
        .window_size = ack_packet.window_size,
        .checksum_value = ack_packet.checksum_value,
        .urgent_pointer = ack_packet.urgent_pointer,
        .payload = ack_packet.payload[0..ack_packet.payload_len],
    });

    const data = try client.buildPayloadWithTimeout(payload, 10, 4);
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, data.sequence_number, data.acknowledgment_number, data.flags, data.window_size, data.payload);
    const first_data_packet = (try pollTcpPacketStrict()).?;
    try std.testing.expectEqual(data.sequence_number, first_data_packet.sequence_number);
    try std.testing.expectEqualStrings(payload, first_data_packet.payload[0..first_data_packet.payload_len]);
    try std.testing.expectEqual(@as(?tcp.Outbound, null), client.pollRetransmit(13));

    const retry_data = client.pollRetransmit(14).?;
    try std.testing.expectEqual(data.sequence_number, retry_data.sequence_number);
    try std.testing.expectEqual(data.acknowledgment_number, retry_data.acknowledgment_number);
    try std.testing.expectEqual(data.flags, retry_data.flags);
    try std.testing.expectEqual(data.window_size, retry_data.window_size);
    try std.testing.expectEqualStrings(payload, retry_data.payload);
    try std.testing.expectEqual(@as(u32, 1), client.retransmit.attempts);
    _ = try sendTcpPacket(destination_mac, client_ip, server_ip, client.local_port, client.remote_port, retry_data.sequence_number, retry_data.acknowledgment_number, retry_data.flags, retry_data.window_size, retry_data.payload);
    const retry_data_packet = (try pollTcpPacketStrict()).?;
    try server.acceptPayload(.{
        .source_port = retry_data_packet.source_port,
        .destination_port = retry_data_packet.destination_port,
        .sequence_number = retry_data_packet.sequence_number,
        .acknowledgment_number = retry_data_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = retry_data_packet.flags,
        .window_size = retry_data_packet.window_size,
        .checksum_value = retry_data_packet.checksum_value,
        .urgent_pointer = retry_data_packet.urgent_pointer,
        .payload = retry_data_packet.payload[0..retry_data_packet.payload_len],
    });

    const payload_ack = try server.buildAck();
    _ = try sendTcpPacket(destination_mac, server_ip, client_ip, server.local_port, server.remote_port, payload_ack.sequence_number, payload_ack.acknowledgment_number, payload_ack.flags, payload_ack.window_size, payload_ack.payload);
    const payload_ack_packet = (try pollTcpPacketStrict()).?;
    try client.acceptAck(.{
        .source_port = payload_ack_packet.source_port,
        .destination_port = payload_ack_packet.destination_port,
        .sequence_number = payload_ack_packet.sequence_number,
        .acknowledgment_number = payload_ack_packet.acknowledgment_number,
        .data_offset_bytes = tcp.header_len,
        .flags = payload_ack_packet.flags,
        .window_size = payload_ack_packet.window_size,
        .checksum_value = payload_ack_packet.checksum_value,
        .urgent_pointer = payload_ack_packet.urgent_pointer,
        .payload = payload_ack_packet.payload[0..payload_ack_packet.payload_len],
    });

    try std.testing.expectEqual(tcp.State.established, client.state);
    try std.testing.expectEqual(tcp.State.established, server.state);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), client.send_next);
    try std.testing.expectEqual(@as(u32, 0x0102_0305 + payload.len), server.recv_next);
    try std.testing.expect(!client.retransmit.armed());
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

test "baremetal net pal configures route state from dhcp lease" {
    clearRouteStateForTest();
    defer clearRouteStateForTest();

    var packet: DhcpPacket = std.mem.zeroes(DhcpPacket);
    packet.your_ip = .{ 192, 168, 56, 10 };
    packet.subnet_mask_valid = true;
    packet.subnet_mask = .{ 255, 255, 255, 0 };
    packet.router_valid = true;
    packet.router = .{ 192, 168, 56, 1 };

    try configureIpv4RouteFromDhcp(&packet);

    const state = routeStatePtr().*;
    try std.testing.expect(state.configured);
    try std.testing.expect(state.subnet_mask_valid);
    try std.testing.expect(state.gateway_valid);
    try std.testing.expectEqualSlices(u8, packet.your_ip[0..], state.local_ip[0..]);
    try std.testing.expectEqualSlices(u8, packet.subnet_mask[0..], state.subnet_mask[0..]);
    try std.testing.expectEqualSlices(u8, packet.router[0..], state.gateway[0..]);
}

test "baremetal net pal routes off-subnet udp via learned gateway arp entry" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();
    clearRouteStateForTest();
    defer clearRouteStateForTest();

    try std.testing.expect(initDevice());
    const local_ip = [4]u8{ 192, 168, 56, 10 };
    const remote_ip = [4]u8{ 1, 1, 1, 1 };
    const gateway_ip = [4]u8{ 192, 168, 56, 1 };
    const gateway_mac = [6]u8{ 0x02, 0xAA, 0xBB, 0xCC, 0xDD, 0x01 };
    const payload = "ROUTED-UDP";
    configureIpv4Route(local_ip, .{ 255, 255, 255, 0 }, gateway_ip);

    try std.testing.expectError(error.AddressUnresolved, sendUdpPacketRouted(remote_ip, 54000, 53, payload));
    const request_packet = (try pollArpPacket()).?;
    try std.testing.expectEqual(arp.operation_request, request_packet.operation);
    try std.testing.expectEqualSlices(u8, gateway_ip[0..], request_packet.target_ip[0..]);
    try std.testing.expectEqualSlices(u8, local_ip[0..], request_packet.sender_ip[0..]);
    try std.testing.expect(!learnArpPacket(request_packet));

    var reply_frame: [arp.frame_len]u8 = undefined;
    const reply_len = try arp.encodeReplyFrame(reply_frame[0..], gateway_mac, gateway_ip, macAddress(), local_ip);
    try sendFrame(reply_frame[0..reply_len]);
    const reply_packet = (try pollArpPacket()).?;
    try std.testing.expectEqual(arp.operation_reply, reply_packet.operation);
    try std.testing.expect(learnArpPacket(reply_packet));

    const expected_wire_len: u32 = ethernet.header_len + ipv4.header_len + udp.header_len + payload.len;
    try std.testing.expectEqual(expected_wire_len, try sendUdpPacketRouted(remote_ip, 54000, 53, payload));

    const packet = (try pollUdpPacketStrict()).?;
    try std.testing.expectEqualSlices(u8, gateway_mac[0..], packet.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, local_ip[0..], packet.ipv4_header.source_ip[0..]);
    try std.testing.expectEqualSlices(u8, remote_ip[0..], packet.ipv4_header.destination_ip[0..]);
    try std.testing.expectEqualSlices(u8, payload, packet.payload[0..packet.payload_len]);
    try std.testing.expect(routeStatePtr().last_used_gateway);
    try std.testing.expect(routeStatePtr().last_cache_hit);
    try std.testing.expect(!routeStatePtr().pending_resolution);
    try std.testing.expectEqual(@as(usize, 1), routeStatePtr().cache_entry_count);
}

test "baremetal net pal routes local-subnet udp directly after arp learning" {
    rtl8139.testEnableMockDevice();
    defer rtl8139.testDisableMockDevice();
    clearRouteStateForTest();
    defer clearRouteStateForTest();

    try std.testing.expect(initDevice());
    const local_ip = [4]u8{ 192, 168, 56, 10 };
    const peer_ip = [4]u8{ 192, 168, 56, 77 };
    const peer_mac = [6]u8{ 0x02, 0x10, 0x20, 0x30, 0x40, 0x50 };
    const gateway_ip = [4]u8{ 192, 168, 56, 1 };
    const payload = "DIRECT-UDP";
    configureIpv4Route(local_ip, .{ 255, 255, 255, 0 }, gateway_ip);

    var reply_frame: [arp.frame_len]u8 = undefined;
    const reply_len = try arp.encodeReplyFrame(reply_frame[0..], peer_mac, peer_ip, macAddress(), local_ip);
    try sendFrame(reply_frame[0..reply_len]);
    const reply_packet = (try pollArpPacket()).?;
    try std.testing.expect(learnArpPacket(reply_packet));

    const expected_wire_len: u32 = ethernet.header_len + ipv4.header_len + udp.header_len + payload.len;
    try std.testing.expectEqual(expected_wire_len, try sendUdpPacketRouted(peer_ip, 54001, 9001, payload));

    const packet = (try pollUdpPacketStrict()).?;
    try std.testing.expectEqualSlices(u8, peer_mac[0..], packet.ethernet_destination[0..]);
    try std.testing.expectEqualSlices(u8, local_ip[0..], packet.ipv4_header.source_ip[0..]);
    try std.testing.expectEqualSlices(u8, peer_ip[0..], packet.ipv4_header.destination_ip[0..]);
    try std.testing.expectEqualSlices(u8, payload, packet.payload[0..packet.payload_len]);
    try std.testing.expect(!routeStatePtr().last_used_gateway);
    try std.testing.expect(routeStatePtr().last_cache_hit);
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
