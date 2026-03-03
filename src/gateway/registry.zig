const std = @import("std");

pub const supported_methods = [_][]const u8{
    "connect",
    "health",
    "status",
    "shutdown",
    "exec.run",
    "file.read",
    "file.write",
    "web.login.start",
    "web.login.wait",
    "web.login.complete",
    "web.login.status",
    "browser.request",
    "security.audit",
    "doctor",
    "channels.status",
};

pub fn supports(method: []const u8) bool {
    for (supported_methods) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, method)) return true;
    }
    return false;
}

pub fn count() usize {
    return supported_methods.len;
}

test "registry includes browser.request and health" {
    try std.testing.expect(supports("browser.request"));
    try std.testing.expect(supports("health"));
    try std.testing.expect(!supports("unknown.method"));
}
