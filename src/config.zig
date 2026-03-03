const std = @import("std");

pub const SecurityConfig = struct {
    loop_guard_enabled: bool,
    loop_guard_window_ms: u32,
    loop_guard_max_hits: u16,
    risk_review_threshold: u8,
    risk_block_threshold: u8,
    blocked_message_patterns: []const u8,
    policy_bundle_path: []const u8,
};

pub const Config = struct {
    http_bind: []const u8,
    http_port: u16,
    state_path: []const u8,
    lightpanda_endpoint: []const u8,
    lightpanda_timeout_ms: u32,
    security: SecurityConfig,
};

pub fn defaults() Config {
    return .{
        .http_bind = "127.0.0.1",
        .http_port = 8080,
        .state_path = ".openclaw-zig/state",
        .lightpanda_endpoint = "http://127.0.0.1:9222",
        .lightpanda_timeout_ms = 15_000,
        .security = .{
            .loop_guard_enabled = true,
            .loop_guard_window_ms = 5_000,
            .loop_guard_max_hits = 8,
            .risk_review_threshold = 70,
            .risk_block_threshold = 90,
            .blocked_message_patterns = "ignore previous instructions,system prompt,jailbreak,disable safety",
            .policy_bundle_path = "memory://security-policy.json",
        },
    };
}

pub fn loadFromEnviron(allocator: std.mem.Allocator, environ: std.process.Environ) !Config {
    var cfg = defaults();

    cfg.http_bind = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_HTTP_BIND", cfg.http_bind);
    cfg.http_port = try parseU16EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_HTTP_PORT", cfg.http_port);
    cfg.state_path = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_STATE_PATH", cfg.state_path);
    cfg.lightpanda_endpoint = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_LIGHTPANDA_ENDPOINT", cfg.lightpanda_endpoint);
    cfg.lightpanda_timeout_ms = try parseU32EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_LIGHTPANDA_TIMEOUT_MS", cfg.lightpanda_timeout_ms);
    cfg.security.loop_guard_enabled = try parseBoolEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_SECURITY_LOOP_GUARD_ENABLED", cfg.security.loop_guard_enabled);
    cfg.security.loop_guard_window_ms = try parseU32EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_SECURITY_LOOP_GUARD_WINDOW_MS", cfg.security.loop_guard_window_ms);
    cfg.security.loop_guard_max_hits = try parseU16EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_SECURITY_LOOP_GUARD_MAX_HITS", cfg.security.loop_guard_max_hits);
    cfg.security.risk_review_threshold = try parseU8EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_SECURITY_RISK_REVIEW_THRESHOLD", cfg.security.risk_review_threshold);
    cfg.security.risk_block_threshold = try parseU8EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_SECURITY_RISK_BLOCK_THRESHOLD", cfg.security.risk_block_threshold);
    cfg.security.blocked_message_patterns = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_SECURITY_BLOCKED_PATTERNS", cfg.security.blocked_message_patterns);
    cfg.security.policy_bundle_path = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_SECURITY_POLICY_BUNDLE_PATH", cfg.security.policy_bundle_path);

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

fn parseU8EnvOrDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    fallback: u8,
) !u8 {
    const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return fallback,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return fallback;
    return std.fmt.parseInt(u8, trimmed, 10) catch fallback;
}

fn parseBoolEnvOrDefault(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    key: []const u8,
    fallback: bool,
) !bool {
    const raw = std.process.Environ.getAlloc(environ, allocator, key) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return fallback,
        else => return err,
    };
    const source = std.mem.trim(u8, raw, " \t\r\n");
    if (source.len == 0) return fallback;
    var trimmed = try allocator.dupe(u8, source);
    defer allocator.free(trimmed);
    for (trimmed) |*ch| ch.* = std.ascii.toLower(ch.*);
    if (trimmed.len == 0) return fallback;
    if (std.mem.eql(u8, trimmed, "1") or std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "yes") or std.mem.eql(u8, trimmed, "on")) return true;
    if (std.mem.eql(u8, trimmed, "0") or std.mem.eql(u8, trimmed, "false") or std.mem.eql(u8, trimmed, "no") or std.mem.eql(u8, trimmed, "off")) return false;
    return fallback;
}

test "defaults are stable" {
    const cfg = defaults();
    try std.testing.expectEqual(@as(u16, 8080), cfg.http_port);
    try std.testing.expect(std.mem.eql(u8, cfg.http_bind, "127.0.0.1"));
    try std.testing.expect(cfg.security.loop_guard_enabled);
    try std.testing.expectEqual(@as(u8, 90), cfg.security.risk_block_threshold);
}
