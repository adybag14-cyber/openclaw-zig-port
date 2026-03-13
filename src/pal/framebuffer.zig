const abi = @import("../baremetal/abi.zig");
const framebuffer_console = @import("../baremetal/framebuffer_console.zig");

pub const State = abi.BaremetalFramebufferState;

pub fn init() bool {
    return framebuffer_console.init();
}

pub fn clear() void {
    framebuffer_console.clear();
}

pub fn putByte(byte: u8) void {
    framebuffer_console.putByte(byte);
}

pub fn write(text: []const u8) void {
    framebuffer_console.write(text);
}

pub fn statePtr() *const State {
    return framebuffer_console.statePtr();
}

pub fn pixel(index: u32) u32 {
    return framebuffer_console.pixel(index);
}

pub fn pixelAt(x: u32, y: u32) u32 {
    return framebuffer_console.pixelAt(x, y);
}

pub fn resetForTest() void {
    framebuffer_console.resetForTest();
}
