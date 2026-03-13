const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");

pub const cols: usize = 80;
pub const rows: usize = 25;
const cell_count: usize = cols * rows;
const default_attribute: u8 = 0x07;
const vga_buffer_addr: usize = 0xB8000;
const cursor_index_port: u16 = 0x3D4;
const cursor_data_port: u16 = 0x3D5;

var state: abi.BaremetalConsoleState = undefined;
var host_cells: [cell_count]u16 = [_]u16{0} ** cell_count;

fn isHardwareBacked() bool {
    return builtin.os.tag == .freestanding and builtin.cpu.arch == .x86_64;
}

fn backendKind() u8 {
    return if (isHardwareBacked()) abi.console_backend_vga_text else abi.console_backend_host_buffer;
}

fn blankCell() u16 {
    return (@as(u16, default_attribute) << 8) | @as(u16, ' ');
}

fn vgaBuffer() [*]volatile u16 {
    return @as([*]volatile u16, @ptrFromInt(vga_buffer_addr));
}

fn vgaCellPtr(index: usize) *volatile u16 {
    return @as(*volatile u16, @ptrFromInt(vga_buffer_addr + (index * @sizeOf(u16))));
}

fn writePort(port: u16, value: u8) void {
    if (builtin.cpu.arch != .x86_64) return;
    asm volatile ("outb %[al], %[dx]"
        :
        : [dx] "{dx}" (port),
          [al] "{al}" (value),
        : "memory");
}

fn setCell(index: usize, value: u16) void {
    if (isHardwareBacked()) {
        vgaCellPtr(index).* = value;
    } else {
        host_cells[index] = value;
    }
}

fn getCell(index: usize) u16 {
    if (isHardwareBacked()) {
        return vgaCellPtr(index).*;
    }
    return host_cells[index];
}

fn writeCursor() void {
    if (!isHardwareBacked()) return;
    const cursor: u16 = @intCast((@as(usize, state.cursor_row) * cols) + state.cursor_col);
    writePort(cursor_index_port, 0x0F);
    writePort(cursor_data_port, @intCast(cursor & 0xFF));
    writePort(cursor_index_port, 0x0E);
    writePort(cursor_data_port, @intCast((cursor >> 8) & 0xFF));
}

fn resetState() void {
    state = .{
        .magic = abi.console_magic,
        .api_version = abi.api_version,
        .cols = cols,
        .rows = rows,
        .cursor_row = 0,
        .cursor_col = 0,
        .attribute = default_attribute,
        .backend = backendKind(),
        .reserved0 = 0,
        .write_count = 0,
        .scroll_count = 0,
        .clear_count = 0,
    };
}

fn fillScreen(fill_value: u16) void {
    var index: usize = 0;
    while (index < cell_count) : (index += 1) {
        setCell(index, fill_value);
    }
}

fn scrollUp() void {
    var row: usize = 1;
    while (row < rows) : (row += 1) {
        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const dst = ((row - 1) * cols) + col;
            const src = (row * cols) + col;
            setCell(dst, getCell(src));
        }
    }

    var col: usize = 0;
    while (col < cols) : (col += 1) {
        setCell(((rows - 1) * cols) + col, blankCell());
    }

    state.cursor_row = rows - 1;
    state.cursor_col = 0;
    state.scroll_count +%= 1;
    writeCursor();
}

fn lineFeed() void {
    state.cursor_col = 0;
    if (state.cursor_row + 1 >= rows) {
        scrollUp();
    } else {
        state.cursor_row += 1;
        writeCursor();
    }
}

pub fn init() void {
    resetState();
    fillScreen(blankCell());
    writeCursor();
}

pub fn clear() void {
    fillScreen(blankCell());
    state.cursor_row = 0;
    state.cursor_col = 0;
    state.clear_count +%= 1;
    writeCursor();
}

pub fn putByte(byte: u8) void {
    switch (byte) {
        '\r' => {
            state.cursor_col = 0;
            writeCursor();
            return;
        },
        '\n' => {
            lineFeed();
            return;
        },
        '\t' => {
            var idx: usize = 0;
            while (idx < 4) : (idx += 1) putByte(' ');
            return;
        },
        else => {},
    }

    const index = (@as(usize, state.cursor_row) * cols) + state.cursor_col;
    const value = (@as(u16, state.attribute) << 8) | @as(u16, byte);
    setCell(index, value);
    state.write_count +%= 1;
    state.cursor_col += 1;
    if (state.cursor_col >= cols) {
        lineFeed();
    } else {
        writeCursor();
    }
}

pub fn write(text: []const u8) void {
    for (text) |byte| putByte(byte);
}

pub fn statePtr() *const abi.BaremetalConsoleState {
    return &state;
}

pub fn cell(index: u32) u16 {
    const idx: usize = @intCast(index);
    if (idx >= cell_count) return 0;
    return getCell(idx);
}

pub fn resetForTest() void {
    init();
}

test "vga text console clear and write update host state" {
    init();
    try std.testing.expectEqual(@as(u8, abi.console_backend_host_buffer), state.backend);
    try std.testing.expectEqual(blankCell(), cell(0));

    clear();
    try std.testing.expectEqual(@as(u32, 1), state.clear_count);
    try std.testing.expectEqual(@as(u16, 0), state.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), state.cursor_col);

    write("Hi");
    try std.testing.expectEqual(@as(u32, 2), state.write_count);
    try std.testing.expectEqual((@as(u16, default_attribute) << 8) | @as(u16, 'H'), cell(0));
    try std.testing.expectEqual((@as(u16, default_attribute) << 8) | @as(u16, 'i'), cell(1));
    try std.testing.expectEqual(@as(u16, 0), state.cursor_row);
    try std.testing.expectEqual(@as(u16, 2), state.cursor_col);
}

test "vga text console scroll keeps newest content" {
    init();
    clear();

    var line: usize = 0;
    while (line < rows + 1) : (line += 1) {
        putByte(@intCast('A' + @mod(line, 26)));
        putByte('\n');
    }

    try std.testing.expect(state.scroll_count >= 1);
    try std.testing.expectEqual((@as(u16, default_attribute) << 8) | @as(u16, 'C'), cell(0));
    try std.testing.expectEqual((@as(u16, default_attribute) << 8) | @as(u16, 'Z'), cell((rows - 2) * cols));
}
