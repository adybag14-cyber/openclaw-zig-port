const std = @import("std");

pub const ProviderError = error{
    UnsupportedProvider,
};

pub const BrowserCompletion = struct {
    ok: bool,
    engine: []const u8,
    provider: []const u8,
    status: []const u8,
    message: []const u8,
};

pub fn normalizeProvider(raw: []const u8) ProviderError![]const u8 {
    const provider = std.mem.trim(u8, raw, " \t\r\n");
    if (provider.len == 0) return "lightpanda";
    if (std.ascii.eqlIgnoreCase(provider, "lightpanda")) return "lightpanda";
    if (std.ascii.eqlIgnoreCase(provider, "playwright")) return ProviderError.UnsupportedProvider;
    if (std.ascii.eqlIgnoreCase(provider, "puppeteer")) return ProviderError.UnsupportedProvider;
    return ProviderError.UnsupportedProvider;
}

pub fn complete(provider_raw: []const u8) ProviderError!BrowserCompletion {
    const provider = try normalizeProvider(provider_raw);
    return .{
        .ok = true,
        .engine = "lightpanda",
        .provider = provider,
        .status = "completed",
        .message = "lightpanda browser bridge ready",
    };
}

test "lightpanda is the only browser provider" {
    try std.testing.expectError(ProviderError.UnsupportedProvider, normalizeProvider("playwright"));
    try std.testing.expectError(ProviderError.UnsupportedProvider, normalizeProvider("puppeteer"));
    const provider = try normalizeProvider("lightpanda");
    try std.testing.expect(std.mem.eql(u8, provider, "lightpanda"));
}
