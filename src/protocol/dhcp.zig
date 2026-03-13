const std = @import("std");

pub const client_port: u16 = 68;
pub const server_port: u16 = 67;
pub const fixed_header_len: usize = 236;
pub const magic_cookie_len: usize = 4;
pub const options_offset: usize = fixed_header_len + magic_cookie_len;
pub const hardware_type_ethernet: u8 = 1;
pub const hardware_len_ethernet: u8 = 6;
pub const boot_request: u8 = 1;
pub const boot_reply: u8 = 2;
pub const flags_broadcast: u16 = 0x8000;
pub const magic_cookie: u32 = 0x6382_5363;

pub const option_pad: u8 = 0;
pub const option_subnet_mask: u8 = 1;
pub const option_router: u8 = 3;
pub const option_dns_server: u8 = 6;
pub const option_hostname: u8 = 12;
pub const option_requested_ip: u8 = 50;
pub const option_lease_time: u8 = 51;
pub const option_message_type: u8 = 53;
pub const option_server_identifier: u8 = 54;
pub const option_parameter_request_list: u8 = 55;
pub const option_max_message_size: u8 = 57;
pub const option_client_identifier: u8 = 61;
pub const option_end: u8 = 255;

pub const message_type_discover: u8 = 1;
pub const message_type_offer: u8 = 2;
pub const message_type_request: u8 = 3;
pub const message_type_decline: u8 = 4;
pub const message_type_ack: u8 = 5;
pub const message_type_nak: u8 = 6;
pub const message_type_release: u8 = 7;
pub const message_type_inform: u8 = 8;

pub const Error = error{
    BufferTooSmall,
    PacketTooShort,
    InvalidOperation,
    InvalidHardwareType,
    InvalidHardwareLength,
    InvalidMagicCookie,
    OptionTruncated,
    FieldLengthMismatch,
};

pub const Packet = struct {
    op: u8,
    hardware_type: u8,
    hardware_length: u8,
    hops: u8,
    transaction_id: u32,
    seconds: u16,
    flags: u16,
    client_ip: [4]u8,
    your_ip: [4]u8,
    server_ip: [4]u8,
    gateway_ip: [4]u8,
    client_mac: [6]u8,
    message_type: ?u8,
    subnet_mask: ?[4]u8,
    router: ?[4]u8,
    requested_ip: ?[4]u8,
    server_identifier: ?[4]u8,
    lease_time_seconds: ?u32,
    max_message_size: ?u16,
    dns_server_count: usize,
    dns_servers: [2][4]u8,
    parameter_request_list: []const u8,
    client_identifier: []const u8,
    hostname: []const u8,
    options: []const u8,
};

pub fn encodeDiscover(
    buffer: []u8,
    client_mac: [6]u8,
    transaction_id: u32,
    parameter_request_list: []const u8,
) Error!usize {
    const client_identifier_len = 1 + client_mac.len;
    const options_len = 3 +
        2 + parameter_request_list.len +
        2 + client_identifier_len +
        4 +
        1;
    const total_len = options_offset + options_len;
    if (buffer.len < total_len) return error.BufferTooSmall;

    @memset(buffer[0..total_len], 0);
    buffer[0] = boot_request;
    buffer[1] = hardware_type_ethernet;
    buffer[2] = hardware_len_ethernet;
    buffer[3] = 0;
    writeU32Be(buffer[4..8], transaction_id);
    writeU16Be(buffer[8..10], 0);
    writeU16Be(buffer[10..12], flags_broadcast);
    std.mem.copyForwards(u8, buffer[28..34], client_mac[0..]);
    writeU32Be(buffer[fixed_header_len..options_offset], magic_cookie);

    var cursor: usize = options_offset;
    cursor = try writeOptionU8(buffer, cursor, option_message_type, message_type_discover);
    cursor = try writeOptionSlice(buffer, cursor, option_parameter_request_list, parameter_request_list);

    var client_identifier: [1 + 6]u8 = undefined;
    client_identifier[0] = hardware_type_ethernet;
    std.mem.copyForwards(u8, client_identifier[1..], client_mac[0..]);
    cursor = try writeOptionSlice(buffer, cursor, option_client_identifier, client_identifier[0..]);

    var max_message_size_bytes: [2]u8 = undefined;
    writeU16Be(max_message_size_bytes[0..], 1500);
    cursor = try writeOptionSlice(buffer, cursor, option_max_message_size, max_message_size_bytes[0..]);

    if (cursor >= buffer.len) return error.BufferTooSmall;
    buffer[cursor] = option_end;
    return cursor + 1;
}

pub fn decode(packet: []const u8) Error!Packet {
    if (packet.len < options_offset) return error.PacketTooShort;
    if (packet[0] != boot_request and packet[0] != boot_reply) return error.InvalidOperation;
    if (packet[1] != hardware_type_ethernet) return error.InvalidHardwareType;
    if (packet[2] != hardware_len_ethernet) return error.InvalidHardwareLength;
    if (readU32Be(packet[fixed_header_len..options_offset]) != magic_cookie) return error.InvalidMagicCookie;

    var client_ip: [4]u8 = undefined;
    var your_ip: [4]u8 = undefined;
    var server_ip: [4]u8 = undefined;
    var gateway_ip: [4]u8 = undefined;
    var client_mac: [6]u8 = undefined;
    std.mem.copyForwards(u8, client_ip[0..], packet[12..16]);
    std.mem.copyForwards(u8, your_ip[0..], packet[16..20]);
    std.mem.copyForwards(u8, server_ip[0..], packet[20..24]);
    std.mem.copyForwards(u8, gateway_ip[0..], packet[24..28]);
    std.mem.copyForwards(u8, client_mac[0..], packet[28..34]);

    var message_type: ?u8 = null;
    var subnet_mask: ?[4]u8 = null;
    var router: ?[4]u8 = null;
    var requested_ip: ?[4]u8 = null;
    var server_identifier: ?[4]u8 = null;
    var lease_time_seconds: ?u32 = null;
    var max_message_size: ?u16 = null;
    var dns_server_count: usize = 0;
    var dns_servers = [2][4]u8{
        [_]u8{ 0, 0, 0, 0 },
        [_]u8{ 0, 0, 0, 0 },
    };
    var parameter_request_list: []const u8 = &.{};
    var client_identifier: []const u8 = &.{};
    var hostname: []const u8 = &.{};

    var index: usize = options_offset;
    while (index < packet.len) {
        const option_code = packet[index];
        index += 1;
        switch (option_code) {
            option_pad => continue,
            option_end => break,
            else => {},
        }

        if (index >= packet.len) return error.OptionTruncated;
        const option_len = packet[index];
        index += 1;
        if (index + option_len > packet.len) return error.OptionTruncated;
        const option_value = packet[index .. index + option_len];

        switch (option_code) {
            option_message_type => {
                if (option_value.len != 1) return error.FieldLengthMismatch;
                message_type = option_value[0];
            },
            option_subnet_mask => subnet_mask = try parseIpv4Option(option_value),
            option_router => {
                if (option_value.len < 4 or option_value.len % 4 != 0) return error.FieldLengthMismatch;
                router = try parseIpv4Option(option_value[0..4]);
            },
            option_dns_server => {
                if (option_value.len < 4 or option_value.len % 4 != 0) return error.FieldLengthMismatch;
                var dns_index: usize = 0;
                while (dns_index + 4 <= option_value.len and dns_server_count < dns_servers.len) : (dns_index += 4) {
                    dns_servers[dns_server_count] = try parseIpv4Option(option_value[dns_index .. dns_index + 4]);
                    dns_server_count += 1;
                }
            },
            option_hostname => hostname = option_value,
            option_requested_ip => requested_ip = try parseIpv4Option(option_value),
            option_lease_time => {
                if (option_value.len != 4) return error.FieldLengthMismatch;
                lease_time_seconds = readU32Be(option_value);
            },
            option_server_identifier => server_identifier = try parseIpv4Option(option_value),
            option_parameter_request_list => parameter_request_list = option_value,
            option_max_message_size => {
                if (option_value.len != 2) return error.FieldLengthMismatch;
                max_message_size = readU16Be(option_value);
            },
            option_client_identifier => client_identifier = option_value,
            else => {},
        }

        index += option_len;
    }

    return .{
        .op = packet[0],
        .hardware_type = packet[1],
        .hardware_length = packet[2],
        .hops = packet[3],
        .transaction_id = readU32Be(packet[4..8]),
        .seconds = readU16Be(packet[8..10]),
        .flags = readU16Be(packet[10..12]),
        .client_ip = client_ip,
        .your_ip = your_ip,
        .server_ip = server_ip,
        .gateway_ip = gateway_ip,
        .client_mac = client_mac,
        .message_type = message_type,
        .subnet_mask = subnet_mask,
        .router = router,
        .requested_ip = requested_ip,
        .server_identifier = server_identifier,
        .lease_time_seconds = lease_time_seconds,
        .max_message_size = max_message_size,
        .dns_server_count = dns_server_count,
        .dns_servers = dns_servers,
        .parameter_request_list = parameter_request_list,
        .client_identifier = client_identifier,
        .hostname = hostname,
        .options = packet[options_offset..packet.len],
    };
}

fn writeOptionU8(buffer: []u8, cursor: usize, code: u8, value: u8) Error!usize {
    if (cursor + 3 > buffer.len) return error.BufferTooSmall;
    buffer[cursor] = code;
    buffer[cursor + 1] = 1;
    buffer[cursor + 2] = value;
    return cursor + 3;
}

fn writeOptionSlice(buffer: []u8, cursor: usize, code: u8, value: []const u8) Error!usize {
    const option_len: u8 = std.math.cast(u8, value.len) orelse return error.BufferTooSmall;
    if (cursor + 2 + value.len > buffer.len) return error.BufferTooSmall;
    buffer[cursor] = code;
    buffer[cursor + 1] = option_len;
    std.mem.copyForwards(u8, buffer[cursor + 2 .. cursor + 2 + value.len], value);
    return cursor + 2 + value.len;
}

fn parseIpv4Option(bytes: []const u8) Error![4]u8 {
    if (bytes.len != 4) return error.FieldLengthMismatch;
    var ip: [4]u8 = undefined;
    std.mem.copyForwards(u8, ip[0..], bytes);
    return ip;
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

test "dhcp discover encodes and decodes with parameter request list" {
    const client_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const parameter_request_list = [_]u8{ option_subnet_mask, option_router, option_dns_server, option_hostname };
    var packet: [320]u8 = undefined;
    const packet_len = try encodeDiscover(packet[0..], client_mac, 0x1234_5678, parameter_request_list[0..]);

    const decoded = try decode(packet[0..packet_len]);
    try std.testing.expectEqual(@as(u8, boot_request), decoded.op);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), decoded.transaction_id);
    try std.testing.expectEqual(@as(u16, flags_broadcast), decoded.flags);
    try std.testing.expectEqual(message_type_discover, decoded.message_type.?);
    try std.testing.expectEqualSlices(u8, client_mac[0..], decoded.client_mac[0..]);
    try std.testing.expectEqualSlices(u8, parameter_request_list[0..], decoded.parameter_request_list);
    try std.testing.expectEqual(@as(u16, 1500), decoded.max_message_size.?);
    try std.testing.expectEqual(@as(u8, hardware_type_ethernet), decoded.client_identifier[0]);
    try std.testing.expectEqualSlices(u8, client_mac[0..], decoded.client_identifier[1..]);
}

test "dhcp rejects invalid magic cookie" {
    const client_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const parameter_request_list = [_]u8{ option_subnet_mask, option_router };
    var packet: [320]u8 = undefined;
    const packet_len = try encodeDiscover(packet[0..], client_mac, 1, parameter_request_list[0..]);
    packet[fixed_header_len] ^= 0xFF;
    try std.testing.expectError(error.InvalidMagicCookie, decode(packet[0..packet_len]));
}

test "dhcp rejects truncated option payload" {
    const client_mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    const parameter_request_list = [_]u8{ option_subnet_mask, option_router };
    var packet: [320]u8 = undefined;
    const packet_len = try encodeDiscover(packet[0..], client_mac, 1, parameter_request_list[0..]);
    packet[options_offset + 4] = 0xFF;
    try std.testing.expectError(error.OptionTruncated, decode(packet[0 .. packet_len - 1]));
}
