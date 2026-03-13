const abi = @import("../baremetal/abi.zig");
const vga_text_console = @import("../baremetal/vga_text_console.zig");

pub const State = abi.BaremetalConsoleState;

pub fn init() void {
    vga_text_console.init();
}

pub fn clear() void {
    vga_text_console.clear();
}

pub fn putByte(byte: u8) void {
    vga_text_console.putByte(byte);
}

pub fn write(text: []const u8) void {
    vga_text_console.write(text);
}

pub fn statePtr() *const State {
    return vga_text_console.statePtr();
}

pub fn cell(index: u32) u16 {
    return vga_text_console.cell(index);
}
