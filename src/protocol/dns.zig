const std = @import("std");

pub const header_len: usize = 12;
pub const default_port: u16 = 53;
pub const class_in: u16 = 1;
pub const type_a: u16 = 1;
pub const type_aaaa: u16 = 28;

pub const flag_response: u16 = 0x8000;
pub const flag_recursion_desired: u16 = 0x0100;
pub const flag_recursion_available: u16 = 0x0080;
pub const flags_standard_query: u16 = flag_recursion_desired;
pub const flags_standard_success_response: u16 = flag_response | flag_recursion_desired | flag_recursion_available;

pub const max_label_len: usize = 63;
pub const max_name_len: usize = 255;
pub const max_answers: usize = 4;
pub const max_answer_data_len: usize = 16;

pub const Error = error{
    BufferTooSmall,
    PacketTooShort,
    InvalidLabelLength,
    InvalidPointer,
    UnsupportedLabelType,
    NameTooLong,
    CompressionLoop,
    UnsupportedQuestionCount,
    ResourceDataTooLarge,
};

pub const Answer = struct {
    name_len: usize,
    name: [max_name_len]u8,
    rr_type: u16,
    rr_class: u16,
    ttl: u32,
    data_len: usize,
    data: [max_answer_data_len]u8,

    pub fn nameSlice(self: *const Answer) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn dataSlice(self: *const Answer) []const u8 {
        return self.data[0..self.data_len];
    }
};

pub const Packet = struct {
    id: u16,
    flags: u16,
    question_count: u16,
    answer_count_total: u16,
    authority_count: u16,
    additional_count: u16,
    question_name_len: usize,
    question_name: [max_name_len]u8,
    question_type: u16,
    question_class: u16,
    answer_count: usize,
    answers: [max_answers]Answer,

    pub fn questionName(self: *const Packet) []const u8 {
        return self.question_name[0..self.question_name_len];
    }
};

const NameInfo = struct {
    next_index: usize,
    len: usize,
};

pub fn encodeQuery(buffer: []u8, id: u16, name: []const u8, qtype: u16) Error!usize {
    if (buffer.len < header_len) return error.BufferTooSmall;

    writeU16Be(buffer[0..2], id);
    writeU16Be(buffer[2..4], flags_standard_query);
    writeU16Be(buffer[4..6], 1);
    writeU16Be(buffer[6..8], 0);
    writeU16Be(buffer[8..10], 0);
    writeU16Be(buffer[10..12], 0);

    var cursor: usize = header_len;
    cursor += try encodeName(buffer[cursor..], name);
    if (cursor + 4 > buffer.len) return error.BufferTooSmall;
    writeU16Be(buffer[cursor .. cursor + 2], qtype);
    writeU16Be(buffer[cursor + 2 .. cursor + 4], class_in);
    return cursor + 4;
}

pub fn encodeAResponse(
    buffer: []u8,
    id: u16,
    name: []const u8,
    ttl: u32,
    address: [4]u8,
) Error!usize {
    if (buffer.len < header_len) return error.BufferTooSmall;

    writeU16Be(buffer[0..2], id);
    writeU16Be(buffer[2..4], flags_standard_success_response);
    writeU16Be(buffer[4..6], 1);
    writeU16Be(buffer[6..8], 1);
    writeU16Be(buffer[8..10], 0);
    writeU16Be(buffer[10..12], 0);

    var cursor: usize = header_len;
    cursor += try encodeName(buffer[cursor..], name);
    if (cursor + 4 > buffer.len) return error.BufferTooSmall;
    writeU16Be(buffer[cursor .. cursor + 2], type_a);
    writeU16Be(buffer[cursor + 2 .. cursor + 4], class_in);
    cursor += 4;

    if (cursor + 16 > buffer.len) return error.BufferTooSmall;
    buffer[cursor] = 0xC0;
    buffer[cursor + 1] = @as(u8, @intCast(header_len));
    writeU16Be(buffer[cursor + 2 .. cursor + 4], type_a);
    writeU16Be(buffer[cursor + 4 .. cursor + 6], class_in);
    writeU32Be(buffer[cursor + 6 .. cursor + 10], ttl);
    writeU16Be(buffer[cursor + 10 .. cursor + 12], address.len);
    std.mem.copyForwards(u8, buffer[cursor + 12 .. cursor + 16], address[0..]);
    return cursor + 16;
}

pub fn decode(packet: []const u8) Error!Packet {
    if (packet.len < header_len) return error.PacketTooShort;

    const question_count = readU16Be(packet[4..6]);
    if (question_count != 1) return error.UnsupportedQuestionCount;

    var question_name = [_]u8{0} ** max_name_len;
    var answers = [_]Answer{zeroAnswer()} ** max_answers;

    var cursor: usize = header_len;
    const question_info = try readName(packet, cursor, question_name[0..]);
    cursor = question_info.next_index;
    if (cursor + 4 > packet.len) return error.PacketTooShort;

    const question_type = readU16Be(packet[cursor .. cursor + 2]);
    const question_class = readU16Be(packet[cursor + 2 .. cursor + 4]);
    cursor += 4;

    const answer_count_total = readU16Be(packet[6..8]);
    const authority_count = readU16Be(packet[8..10]);
    const additional_count = readU16Be(packet[10..12]);

    var stored_answer_count: usize = 0;
    var answer_index: usize = 0;
    while (answer_index < answer_count_total) : (answer_index += 1) {
        if (stored_answer_count < max_answers) {
            var answer_name = [_]u8{0} ** max_name_len;
            const name_info = try readName(packet, cursor, answer_name[0..]);
            cursor = name_info.next_index;
            if (cursor + 10 > packet.len) return error.PacketTooShort;

            const rr_type = readU16Be(packet[cursor .. cursor + 2]);
            const rr_class = readU16Be(packet[cursor + 2 .. cursor + 4]);
            const ttl = readU32Be(packet[cursor + 4 .. cursor + 8]);
            const data_len = readU16Be(packet[cursor + 8 .. cursor + 10]);
            cursor += 10;
            if (cursor + data_len > packet.len) return error.PacketTooShort;
            if (data_len > max_answer_data_len) return error.ResourceDataTooLarge;

            answers[stored_answer_count] = .{
                .name_len = name_info.len,
                .name = answer_name,
                .rr_type = rr_type,
                .rr_class = rr_class,
                .ttl = ttl,
                .data_len = data_len,
                .data = [_]u8{0} ** max_answer_data_len,
            };
            std.mem.copyForwards(u8, answers[stored_answer_count].data[0..data_len], packet[cursor .. cursor + data_len]);
            stored_answer_count += 1;
            cursor += data_len;
        } else {
            cursor = try skipResourceRecord(packet, cursor);
        }
    }

    var remaining_rrs: usize = authority_count;
    while (remaining_rrs > 0) : (remaining_rrs -= 1) {
        cursor = try skipResourceRecord(packet, cursor);
    }
    remaining_rrs = additional_count;
    while (remaining_rrs > 0) : (remaining_rrs -= 1) {
        cursor = try skipResourceRecord(packet, cursor);
    }

    return .{
        .id = readU16Be(packet[0..2]),
        .flags = readU16Be(packet[2..4]),
        .question_count = question_count,
        .answer_count_total = answer_count_total,
        .authority_count = authority_count,
        .additional_count = additional_count,
        .question_name_len = question_info.len,
        .question_name = question_name,
        .question_type = question_type,
        .question_class = question_class,
        .answer_count = stored_answer_count,
        .answers = answers,
    };
}

fn encodeName(buffer: []u8, name: []const u8) Error!usize {
    if (name.len == 0 or (name.len == 1 and name[0] == '.')) {
        if (buffer.len < 1) return error.BufferTooSmall;
        buffer[0] = 0;
        return 1;
    }

    var cursor: usize = 0;
    var start: usize = 0;
    while (true) {
        const end = std.mem.indexOfScalarPos(u8, name, start, '.') orelse name.len;
        const label = name[start..end];
        if (label.len == 0 or label.len > max_label_len) return error.InvalidLabelLength;
        if (cursor + 1 + label.len > buffer.len) return error.BufferTooSmall;

        buffer[cursor] = @as(u8, @intCast(label.len));
        cursor += 1;
        std.mem.copyForwards(u8, buffer[cursor .. cursor + label.len], label);
        cursor += label.len;

        if (end == name.len) break;
        start = end + 1;
    }

    if (cursor >= buffer.len) return error.BufferTooSmall;
    buffer[cursor] = 0;
    return cursor + 1;
}

fn readName(packet: []const u8, start: usize, out: []u8) Error!NameInfo {
    var cursor = start;
    var next_index = start;
    var jumped = false;
    var out_len: usize = 0;
    var steps: usize = 0;

    while (true) {
        if (steps >= packet.len) return error.CompressionLoop;
        steps += 1;

        if (cursor >= packet.len) return error.PacketTooShort;
        const length = packet[cursor];
        if (length == 0) {
            if (!jumped) next_index = cursor + 1;
            break;
        }

        const label_type = length & 0xC0;
        if (label_type == 0xC0) {
            if (cursor + 1 >= packet.len) return error.PacketTooShort;
            const pointer = ((@as(u16, length & 0x3F)) << 8) | @as(u16, packet[cursor + 1]);
            if (pointer >= packet.len) return error.InvalidPointer;
            if (!jumped) next_index = cursor + 2;
            cursor = pointer;
            jumped = true;
            continue;
        }
        if (label_type != 0) return error.UnsupportedLabelType;

        const label_len = @as(usize, length);
        if (label_len == 0 or label_len > max_label_len) return error.InvalidLabelLength;
        if (cursor + 1 + label_len > packet.len) return error.PacketTooShort;

        if (out_len != 0) {
            if (out_len >= out.len) return error.NameTooLong;
            out[out_len] = '.';
            out_len += 1;
        }
        if (out_len + label_len > out.len) return error.NameTooLong;
        std.mem.copyForwards(u8, out[out_len .. out_len + label_len], packet[cursor + 1 .. cursor + 1 + label_len]);
        out_len += label_len;

        cursor += 1 + label_len;
        if (!jumped) next_index = cursor;
    }

    return .{ .next_index = next_index, .len = out_len };
}

fn skipResourceRecord(packet: []const u8, start: usize) Error!usize {
    var scratch = [_]u8{0} ** max_name_len;
    const name_info = try readName(packet, start, scratch[0..]);
    var cursor = name_info.next_index;
    if (cursor + 10 > packet.len) return error.PacketTooShort;
    const data_len = readU16Be(packet[cursor + 8 .. cursor + 10]);
    cursor += 10;
    if (cursor + data_len > packet.len) return error.PacketTooShort;
    return cursor + data_len;
}

fn zeroAnswer() Answer {
    return .{
        .name_len = 0,
        .name = [_]u8{0} ** max_name_len,
        .rr_type = 0,
        .rr_class = 0,
        .ttl = 0,
        .data_len = 0,
        .data = [_]u8{0} ** max_answer_data_len,
    };
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

test "dns query encodes and decodes" {
    var packet: [512]u8 = undefined;
    const packet_len = try encodeQuery(packet[0..], 0x1234, "openclaw.local", type_a);

    const decoded = try decode(packet[0..packet_len]);
    try std.testing.expectEqual(@as(u16, 0x1234), decoded.id);
    try std.testing.expectEqual(flags_standard_query, decoded.flags);
    try std.testing.expectEqual(@as(u16, 1), decoded.question_count);
    try std.testing.expectEqualStrings("openclaw.local", decoded.questionName());
    try std.testing.expectEqual(type_a, decoded.question_type);
    try std.testing.expectEqual(class_in, decoded.question_class);
    try std.testing.expectEqual(@as(usize, 0), decoded.answer_count);
}

test "dns compressed A response decodes" {
    var packet: [512]u8 = undefined;
    const address = [4]u8{ 192, 168, 56, 1 };
    const packet_len = try encodeAResponse(packet[0..], 0xBEEF, "openclaw.local", 300, address);

    const decoded = try decode(packet[0..packet_len]);
    try std.testing.expectEqual(@as(u16, 0xBEEF), decoded.id);
    try std.testing.expectEqual(flags_standard_success_response, decoded.flags);
    try std.testing.expectEqualStrings("openclaw.local", decoded.questionName());
    try std.testing.expectEqual(@as(u16, 1), decoded.answer_count_total);
    try std.testing.expectEqual(@as(usize, 1), decoded.answer_count);
    try std.testing.expectEqualStrings("openclaw.local", decoded.answers[0].nameSlice());
    try std.testing.expectEqual(type_a, decoded.answers[0].rr_type);
    try std.testing.expectEqual(class_in, decoded.answers[0].rr_class);
    try std.testing.expectEqual(@as(u32, 300), decoded.answers[0].ttl);
    try std.testing.expectEqualSlices(u8, address[0..], decoded.answers[0].dataSlice());
}

test "dns rejects invalid compression pointer" {
    var packet: [512]u8 = undefined;
    const packet_len = try encodeAResponse(packet[0..], 0xCAFE, "openclaw.local", 60, .{ 127, 0, 0, 1 });
    const answer_offset = packet_len - 16;
    packet[answer_offset + 1] = 0xFF;
    try std.testing.expectError(error.InvalidPointer, decode(packet[0..packet_len]));
}

test "dns rejects truncated answer payload" {
    var packet: [512]u8 = undefined;
    const packet_len = try encodeAResponse(packet[0..], 0xCAFE, "openclaw.local", 60, .{ 127, 0, 0, 1 });
    try std.testing.expectError(error.PacketTooShort, decode(packet[0 .. packet_len - 1]));
}
