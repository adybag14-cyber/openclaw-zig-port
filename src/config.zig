const std = @import("std");

pub const Config = struct {
    http_bind: []const u8,
    http_port: u16,
    state_path: []const u8,
    lightpanda_endpoint: []const u8,
    lightpanda_timeout_ms: u32,
};

pub fn defaults() Config {
    return .{
        .http_bind = "127.0.0.1",
        .http_port = 8080,
        .state_path = ".openclaw-zig/state",
        .lightpanda_endpoint = "http://127.0.0.1:9222",
        .lightpanda_timeout_ms = 15_000,
    };
}

pub fn loadFromEnviron(allocator: std.mem.Allocator, environ: std.process.Environ) !Config {
    var cfg = defaults();

    cfg.http_bind = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_HTTP_BIND", cfg.http_bind);
    cfg.http_port = try parseU16EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_HTTP_PORT", cfg.http_port);
    cfg.state_path = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_STATE_PATH", cfg.state_path);
    cfg.lightpanda_endpoint = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_LIGHTPANDA_ENDPOINT", cfg.lightpanda_endpoint);
    cfg.lightpanda_timeout_ms = try parseU32EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_LIGHTPANDA_TIMEOUT_MS", cfg.lightpanda_timeout_ms);

    return cfg;
}

fn getEnvOrDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    fallback: []const u8,
) ![]const u8 {
    const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return fallback,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    return trimmed;
}

fn parseU16EnvOrDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    fallback: u16,
) !u16 {
    const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return fallback,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    return std.fmt.parseInt(u16, trimmed, 10) catch fallback;
}

fn parseU32EnvOrDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    fallback: u32,
) !u32 {
    const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return fallback,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    return std.fmt.parseInt(u32, trimmed, 10) catch fallback;
}

test "defaults are stable" {
    const cfg = defaults();
    try std.testing.expectEqual(@as(u16, 8080), cfg.http_port);
    try std.testing.expect(std.mem.eql(u8, cfg.http_bind, "127.0.0.1"));
}
