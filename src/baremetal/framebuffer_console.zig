const std = @import("std");
const builtin = @import("builtin");
const abi = @import("abi.zig");
const pci = @import("pci.zig");

pub const width: usize = 640;
pub const height: usize = 400;
pub const bytes_per_pixel: usize = 4;
pub const pitch: usize = width * bytes_per_pixel;
pub const cols: usize = 80;
pub const rows: usize = 25;
pub const cell_width: usize = 8;
pub const cell_height: usize = 16;
const pixel_count: usize = width * height;
const cell_count: usize = cols * rows;
const fg_color: u32 = 0x00FFFFFF;
const bg_color: u32 = 0x00000000;

const bga_index_port: u16 = 0x01CE;
const bga_data_port: u16 = 0x01CF;
const bga_reg_id: u16 = 0x0;
const bga_reg_xres: u16 = 0x1;
const bga_reg_yres: u16 = 0x2;
const bga_reg_bpp: u16 = 0x3;
const bga_reg_enable: u16 = 0x4;
const bga_reg_bank: u16 = 0x5;
const bga_reg_virtual_width: u16 = 0x6;
const bga_reg_virtual_height: u16 = 0x7;
const bga_reg_x_offset: u16 = 0x8;
const bga_reg_y_offset: u16 = 0x9;
const bga_enable_flag: u16 = 0x01;
const bga_linear_framebuffer_flag: u16 = 0x40;

var state: abi.BaremetalFramebufferState = undefined;
var host_pixels: [pixel_count]u32 = [_]u32{0} ** pixel_count;
var cells: [cell_count]u8 = [_]u8{' '} ** cell_count;
var cursor_row: u16 = 0;
var cursor_col: u16 = 0;

fn hardwareBacked() bool {
    return builtin.os.tag == .freestanding and builtin.cpu.arch == .x86_64;
}

fn pixelPtr() [*]volatile u32 {
    if (state.hardware_backed != 0 and state.framebuffer_addr != 0) {
        return @as([*]volatile u32, @ptrFromInt(@as(usize, @intCast(state.framebuffer_addr))));
    }
    return @as([*]volatile u32, @ptrCast(&host_pixels[0]));
}

fn fillAllPixels(color: u32) void {
    if (state.hardware_backed != 0 and state.framebuffer_addr != 0) {
        const pixels = @as([*]u32, @ptrFromInt(@as(usize, @intCast(state.framebuffer_addr))))[0..pixel_count];
        @memset(pixels, color);
        return;
    }
    @memset(&host_pixels, color);
}

fn writePort16(port: u16, value: u16) void {
    if (!hardwareBacked()) return;
    asm volatile ("outw %[ax], %[dx]"
        :
        : [dx] "{dx}" (port),
          [ax] "{ax}" (value),
        : "memory");
}

fn readPort16(port: u16) u16 {
    if (!hardwareBacked()) return 0;
    return asm volatile ("inw %[dx], %[ax]"
        : [ax] "={ax}" (-> u16),
        : [dx] "{dx}" (port),
        : "memory");
}

fn bgaWriteReg(index: u16, value: u16) void {
    writePort16(bga_index_port, index);
    writePort16(bga_data_port, value);
}

fn bgaReadReg(index: u16) u16 {
    writePort16(bga_index_port, index);
    return readPort16(bga_data_port);
}

fn initState() void {
    state = .{
        .magic = abi.framebuffer_magic,
        .api_version = abi.api_version,
        .width = @intCast(width),
        .height = @intCast(height),
        .cols = @intCast(cols),
        .rows = @intCast(rows),
        .pitch = @intCast(pitch),
        .framebuffer_bytes = @intCast(width * height * bytes_per_pixel),
        .framebuffer_addr = @intCast(@intFromPtr(&host_pixels[0])),
        .bytes_per_pixel = @intCast(bytes_per_pixel),
        .backend = abi.console_backend_linear_framebuffer,
        .hardware_backed = 0,
        .reserved0 = 0,
        .write_count = 0,
        .clear_count = 0,
        .present_count = 0,
        .cell_width = @intCast(cell_width),
        .cell_height = @intCast(cell_height),
        .reserved1 = .{ 0, 0 },
        .fg_color = fg_color,
        .bg_color = bg_color,
    };
}

fn initHardwareMode() bool {
    if (!hardwareBacked()) return false;
    const framebuffer_addr = pci.discoverDisplayFramebufferBar() orelse return false;

    const version = bgaReadReg(bga_reg_id);
    if ((version & 0xFFF0) != 0xB0C0) return false;

    bgaWriteReg(bga_reg_enable, 0);
    bgaWriteReg(bga_reg_xres, width);
    bgaWriteReg(bga_reg_yres, height);
    bgaWriteReg(bga_reg_bpp, 32);
    bgaWriteReg(bga_reg_bank, 0);
    bgaWriteReg(bga_reg_virtual_width, width);
    bgaWriteReg(bga_reg_virtual_height, height);
    bgaWriteReg(bga_reg_x_offset, 0);
    bgaWriteReg(bga_reg_y_offset, 0);
    bgaWriteReg(bga_reg_enable, bga_enable_flag | bga_linear_framebuffer_flag);
    state.framebuffer_addr = framebuffer_addr;
    return true;
}

fn plotPixel(x: usize, y: usize, color: u32) void {
    if (x >= width or y >= height) return;
    pixelPtr()[(y * width) + x] = color;
}

fn fillRect(x: usize, y: usize, w: usize, h: usize, color: u32) void {
    if (x >= width or y >= height) return;
    const clipped_w = @min(w, width - x);
    const clipped_h = @min(h, height - y);
    const pixels = pixelPtr();

    var py: usize = 0;
    while (py < clipped_h) : (py += 1) {
        const row_base = ((y + py) * width) + x;
        var px: usize = 0;
        while (px < clipped_w) : (px += 1) {
            pixels[row_base + px] = color;
        }
    }
}

fn normalizeGlyphByte(byte: u8) u8 {
    if (byte >= 'a' and byte <= 'z') return byte - 32;
    return byte;
}

fn genericGlyphRow(byte: u8, row: usize) u8 {
    if (byte == ' ' or row >= 7) return 0;
    return switch (row) {
        0 => 0x3C,
        1 => 0x42 | ((byte & 0x01) << 2),
        2 => 0x40 | ((byte >> 1) & 0x3F),
        3 => 0x7E,
        4 => 0x40 | ((byte >> 2) & 0x3F),
        5 => 0x42 | ((byte >> 3) & 0x1C),
        6 => 0x3C,
        else => 0,
    };
}

fn glyphRow(byte: u8, row: usize) u8 {
    if (row >= 7) return 0;
    const ch = normalizeGlyphByte(byte);
    if (ch == ' ') return 0;
    const glyph: [7]u8 = switch (ch) {
        '-' => .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00 },
        '_' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7E },
        '.' => .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18 },
        ',' => .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x10 },
        ':' => .{ 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00 },
        '/' => .{ 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x00 },
        '?' => .{ 0x3C, 0x42, 0x04, 0x18, 0x10, 0x00, 0x10 },
        '0' => .{ 0x3C, 0x46, 0x4A, 0x52, 0x62, 0x42, 0x3C },
        '1' => .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E },
        '2' => .{ 0x3C, 0x42, 0x02, 0x0C, 0x30, 0x40, 0x7E },
        '3' => .{ 0x3C, 0x42, 0x02, 0x1C, 0x02, 0x42, 0x3C },
        '4' => .{ 0x08, 0x18, 0x28, 0x48, 0x7E, 0x08, 0x08 },
        '5' => .{ 0x7E, 0x40, 0x7C, 0x02, 0x02, 0x42, 0x3C },
        '6' => .{ 0x1C, 0x20, 0x40, 0x7C, 0x42, 0x42, 0x3C },
        '7' => .{ 0x7E, 0x02, 0x04, 0x08, 0x10, 0x10, 0x10 },
        '8' => .{ 0x3C, 0x42, 0x42, 0x3C, 0x42, 0x42, 0x3C },
        '9' => .{ 0x3C, 0x42, 0x42, 0x3E, 0x02, 0x04, 0x38 },
        'A' => .{ 0x18, 0x24, 0x42, 0x7E, 0x42, 0x42, 0x42 },
        'B' => .{ 0x7C, 0x42, 0x42, 0x7C, 0x42, 0x42, 0x7C },
        'C' => .{ 0x3C, 0x42, 0x40, 0x40, 0x40, 0x42, 0x3C },
        'D' => .{ 0x78, 0x44, 0x42, 0x42, 0x42, 0x44, 0x78 },
        'E' => .{ 0x7E, 0x40, 0x40, 0x7C, 0x40, 0x40, 0x7E },
        'F' => .{ 0x7E, 0x40, 0x40, 0x7C, 0x40, 0x40, 0x40 },
        'G' => .{ 0x3C, 0x42, 0x40, 0x4E, 0x42, 0x42, 0x3C },
        'H' => .{ 0x42, 0x42, 0x42, 0x7E, 0x42, 0x42, 0x42 },
        'I' => .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x7E },
        'J' => .{ 0x1E, 0x04, 0x04, 0x04, 0x44, 0x44, 0x38 },
        'K' => .{ 0x42, 0x44, 0x48, 0x70, 0x48, 0x44, 0x42 },
        'L' => .{ 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x7E },
        'M' => .{ 0x42, 0x66, 0x5A, 0x5A, 0x42, 0x42, 0x42 },
        'N' => .{ 0x42, 0x62, 0x52, 0x4A, 0x46, 0x42, 0x42 },
        'O' => .{ 0x3C, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C },
        'P' => .{ 0x7C, 0x42, 0x42, 0x7C, 0x40, 0x40, 0x40 },
        'Q' => .{ 0x3C, 0x42, 0x42, 0x42, 0x4A, 0x44, 0x3A },
        'R' => .{ 0x7C, 0x42, 0x42, 0x7C, 0x48, 0x44, 0x42 },
        'S' => .{ 0x3C, 0x42, 0x40, 0x3C, 0x02, 0x42, 0x3C },
        'T' => .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18 },
        'U' => .{ 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x3C },
        'V' => .{ 0x42, 0x42, 0x42, 0x42, 0x42, 0x24, 0x18 },
        'W' => .{ 0x42, 0x42, 0x42, 0x5A, 0x5A, 0x66, 0x42 },
        'X' => .{ 0x42, 0x42, 0x24, 0x18, 0x24, 0x42, 0x42 },
        'Y' => .{ 0x42, 0x42, 0x24, 0x18, 0x18, 0x18, 0x18 },
        'Z' => .{ 0x7E, 0x02, 0x04, 0x18, 0x20, 0x40, 0x7E },
        else => return genericGlyphRow(ch, row),
    };
    return glyph[row];
}

fn renderCell(index: usize) void {
    if (index >= cell_count) return;
    const ch = cells[index];
    const col = index % cols;
    const row = index / cols;
    const origin_x = col * cell_width;
    const origin_y = row * cell_height;

    fillRect(origin_x, origin_y, cell_width, cell_height, bg_color);

    var py: usize = 0;
    while (py < cell_height) : (py += 1) {
        if (py == 0 or py == cell_height - 1) continue;
        const glyph = glyphRow(ch, (py - 1) / 2);
        var px: usize = 0;
        while (px < cell_width) : (px += 1) {
            const bit = @as(u8, 1) << @as(u3, @intCast(7 - px));
            if ((glyph & bit) != 0) plotPixel(origin_x + px, origin_y + py, fg_color);
        }
    }
    state.present_count +%= 1;
}

fn rerenderAll() void {
    fillAllPixels(bg_color);
    var index: usize = 0;
    while (index < cell_count) : (index += 1) renderCell(index);
}

fn lineFeed() void {
    cursor_col = 0;
    if (cursor_row + 1 >= rows) {
        var row: usize = 1;
        while (row < rows) : (row += 1) {
            var col: usize = 0;
            while (col < cols) : (col += 1) {
                cells[((row - 1) * cols) + col] = cells[(row * cols) + col];
            }
        }
        var col: usize = 0;
        while (col < cols) : (col += 1) cells[((rows - 1) * cols) + col] = ' ';
        cursor_row = rows - 1;
        rerenderAll();
    } else {
        cursor_row += 1;
    }
}

pub fn init() bool {
    initState();
    @memset(&cells, ' ');
    cursor_row = 0;
    cursor_col = 0;
    @memset(&host_pixels, 0);
    state.hardware_backed = if (initHardwareMode()) 1 else 0;
    state.framebuffer_addr = if (state.hardware_backed != 0) state.framebuffer_addr else @intFromPtr(&host_pixels[0]);
    clear();
    return state.hardware_backed != 0;
}

pub fn initForProbe() bool {
    initState();
    @memset(&cells, ' ');
    cursor_row = 0;
    cursor_col = 0;
    @memset(&host_pixels, 0);
    state.hardware_backed = if (initHardwareMode()) 1 else 0;
    state.framebuffer_addr = if (state.hardware_backed != 0) state.framebuffer_addr else @intFromPtr(&host_pixels[0]);
    return state.hardware_backed != 0;
}

pub fn clear() void {
    @memset(&cells, ' ');
    cursor_row = 0;
    cursor_col = 0;
    fillAllPixels(bg_color);
    state.clear_count +%= 1;
    state.present_count +%= 1;
}

pub fn putByte(byte: u8) void {
    switch (byte) {
        '\r' => {
            cursor_col = 0;
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

    const index = (@as(usize, cursor_row) * cols) + cursor_col;
    cells[index] = byte;
    renderCell(index);
    state.write_count +%= 1;

    cursor_col += 1;
    if (cursor_col >= cols) lineFeed();
}

pub fn write(text: []const u8) void {
    for (text) |byte| putByte(byte);
}

pub fn statePtr() *const abi.BaremetalFramebufferState {
    return &state;
}

pub fn pixel(index: u32) u32 {
    const idx: usize = @intCast(index);
    if (idx >= pixel_count) return 0;
    return pixelPtr()[idx];
}

pub fn pixelAt(x: u32, y: u32) u32 {
    const xi: usize = @intCast(x);
    const yi: usize = @intCast(y);
    if (xi >= width or yi >= height) return 0;
    return pixelPtr()[(yi * width) + xi];
}

pub fn resetForTest() void {
    initState();
    pci.testResetForTest();
    @memset(&host_pixels, 0);
    @memset(&cells, ' ');
    cursor_row = 0;
    cursor_col = 0;
    state.hardware_backed = 0;
    state.framebuffer_addr = @intFromPtr(&host_pixels[0]);
}

fn cellHasInk(col: usize, row: usize) bool {
    const start_x = col * cell_width;
    const start_y = row * cell_height;

    var py: usize = 0;
    while (py < cell_height) : (py += 1) {
        var px: usize = 0;
        while (px < cell_width) : (px += 1) {
            if (pixelAt(@intCast(start_x + px), @intCast(start_y + py)) != 0) return true;
        }
    }
    return false;
}

test "framebuffer console clear and write update host state" {
    resetForTest();
    _ = init();
    const fb = statePtr();
    try std.testing.expectEqual(@as(u32, abi.framebuffer_magic), fb.magic);
    try std.testing.expectEqual(@as(u8, abi.console_backend_linear_framebuffer), fb.backend);
    try std.testing.expectEqual(@as(u8, 0), fb.hardware_backed);
    try std.testing.expectEqual(@as(u16, @intCast(width)), fb.width);
    try std.testing.expectEqual(@as(u16, @intCast(height)), fb.height);
    try std.testing.expectEqual(@as(u16, @intCast(cols)), fb.cols);
    try std.testing.expectEqual(@as(u16, @intCast(rows)), fb.rows);

    clear();
    write("OK");
    try std.testing.expectEqual(@as(u32, 2), fb.write_count);
    try std.testing.expect(fb.clear_count >= 1);
    try std.testing.expect(cellHasInk(0, 0));
    try std.testing.expect(cellHasInk(1, 0));
}
