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

pub const GatewayConfig = struct {
    require_token: bool,
    auth_token: []const u8,
    rate_limit_enabled: bool,
    rate_limit_window_ms: u32,
    rate_limit_max_requests: u32,
    stream_chunk_default_bytes: u32 = 4096,
    stream_chunk_max_bytes: u32 = 64 * 1024,
};

pub const RuntimeConfig = struct {
    file_sandbox_enabled: bool,
    file_allowed_roots: []const u8,
    exec_enabled: bool,
    exec_allowlist: []const u8,
};

pub const Config = struct {
    http_bind: []const u8,
    http_port: u16,
    state_path: []const u8,
    lightpanda_endpoint: []const u8,
    lightpanda_timeout_ms: u32,
    gateway: GatewayConfig,
    runtime: RuntimeConfig,
    security: SecurityConfig,
};

pub fn fingerprint(cfg: Config) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashStringField(&hasher, "http_bind", cfg.http_bind);
    hashIntField(&hasher, "http_port", cfg.http_port);
    hashStringField(&hasher, "state_path", cfg.state_path);
    hashStringField(&hasher, "lightpanda_endpoint", cfg.lightpanda_endpoint);
    hashIntField(&hasher, "lightpanda_timeout_ms", cfg.lightpanda_timeout_ms);
    hashBoolField(&hasher, "gateway.require_token", cfg.gateway.require_token);
    hashStringField(&hasher, "gateway.auth_token", cfg.gateway.auth_token);
    hashBoolField(&hasher, "gateway.rate_limit_enabled", cfg.gateway.rate_limit_enabled);
    hashIntField(&hasher, "gateway.rate_limit_window_ms", cfg.gateway.rate_limit_window_ms);
    hashIntField(&hasher, "gateway.rate_limit_max_requests", cfg.gateway.rate_limit_max_requests);
    hashIntField(&hasher, "gateway.stream_chunk_default_bytes", cfg.gateway.stream_chunk_default_bytes);
    hashIntField(&hasher, "gateway.stream_chunk_max_bytes", cfg.gateway.stream_chunk_max_bytes);
    hashBoolField(&hasher, "runtime.file_sandbox_enabled", cfg.runtime.file_sandbox_enabled);
    hashStringField(&hasher, "runtime.file_allowed_roots", cfg.runtime.file_allowed_roots);
    hashBoolField(&hasher, "runtime.exec_enabled", cfg.runtime.exec_enabled);
    hashStringField(&hasher, "runtime.exec_allowlist", cfg.runtime.exec_allowlist);
    hashBoolField(&hasher, "security.loop_guard_enabled", cfg.security.loop_guard_enabled);
    hashIntField(&hasher, "security.loop_guard_window_ms", cfg.security.loop_guard_window_ms);
    hashIntField(&hasher, "security.loop_guard_max_hits", cfg.security.loop_guard_max_hits);
    hashIntField(&hasher, "security.risk_review_threshold", cfg.security.risk_review_threshold);
    hashIntField(&hasher, "security.risk_block_threshold", cfg.security.risk_block_threshold);
    hashStringField(&hasher, "security.blocked_message_patterns", cfg.security.blocked_message_patterns);
    hashStringField(&hasher, "security.policy_bundle_path", cfg.security.policy_bundle_path);
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn fingerprintHex(cfg: Config) [64]u8 {
    const digest = fingerprint(cfg);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn defaults() Config {
    return .{
        .http_bind = "127.0.0.1",
        .http_port = 8080,
        .state_path = ".openclaw-zig/state",
        .lightpanda_endpoint = "http://127.0.0.1:9222",
        .lightpanda_timeout_ms = 15_000,
        .gateway = .{
            .require_token = false,
            .auth_token = "",
            .rate_limit_enabled = true,
            .rate_limit_window_ms = 60_000,
            .rate_limit_max_requests = 300,
            .stream_chunk_default_bytes = 4096,
            .stream_chunk_max_bytes = 64 * 1024,
        },
        .runtime = .{
            .file_sandbox_enabled = false,
            .file_allowed_roots = "",
            .exec_enabled = true,
            .exec_allowlist = "",
        },
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
    cfg.gateway.require_token = try parseBoolEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN", cfg.gateway.require_token);
    cfg.gateway.auth_token = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN", cfg.gateway.auth_token);
    cfg.gateway.rate_limit_enabled = try parseBoolEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_ENABLED", cfg.gateway.rate_limit_enabled);
    cfg.gateway.rate_limit_window_ms = try parseU32EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_WINDOW_MS", cfg.gateway.rate_limit_window_ms);
    cfg.gateway.rate_limit_max_requests = try parseU32EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_MAX_REQUESTS", cfg.gateway.rate_limit_max_requests);
    cfg.gateway.stream_chunk_default_bytes = try parseU32EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_GATEWAY_STREAM_CHUNK_DEFAULT_BYTES", cfg.gateway.stream_chunk_default_bytes);
    cfg.gateway.stream_chunk_max_bytes = try parseU32EnvOrDefault(allocator, environ, "OPENCLAW_ZIG_GATEWAY_STREAM_CHUNK_MAX_BYTES", cfg.gateway.stream_chunk_max_bytes);
    cfg.runtime.file_sandbox_enabled = try parseBoolEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_RUNTIME_FILE_SANDBOX_ENABLED", cfg.runtime.file_sandbox_enabled);
    cfg.runtime.file_allowed_roots = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_RUNTIME_FILE_ALLOWED_ROOTS", cfg.runtime.file_allowed_roots);
    cfg.runtime.exec_enabled = try parseBoolEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_RUNTIME_EXEC_ENABLED", cfg.runtime.exec_enabled);
    cfg.runtime.exec_allowlist = try getEnvOrDefault(allocator, environ, "OPENCLAW_ZIG_RUNTIME_EXEC_ALLOWLIST", cfg.runtime.exec_allowlist);
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

fn hashStringField(hasher: *std.crypto.hash.sha2.Sha256, key: []const u8, value: []const u8) void {
    hasher.update(key);
    hasher.update("\n");
    hasher.update(value);
    hasher.update("\n");
}

fn hashBoolField(hasher: *std.crypto.hash.sha2.Sha256, key: []const u8, value: bool) void {
    hashStringField(hasher, key, if (value) "1" else "0");
}

fn hashIntField(hasher: *std.crypto.hash.sha2.Sha256, key: []const u8, value: anytype) void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    hashStringField(hasher, key, text);
}

test "defaults are stable" {
    const cfg = defaults();
    try std.testing.expectEqual(@as(u16, 8080), cfg.http_port);
    try std.testing.expect(std.mem.eql(u8, cfg.http_bind, "127.0.0.1"));
    try std.testing.expect(!cfg.gateway.require_token);
    try std.testing.expect(cfg.gateway.rate_limit_enabled);
    try std.testing.expectEqual(@as(u32, 300), cfg.gateway.rate_limit_max_requests);
    try std.testing.expectEqual(@as(u32, 4096), cfg.gateway.stream_chunk_default_bytes);
    try std.testing.expectEqual(@as(u32, 64 * 1024), cfg.gateway.stream_chunk_max_bytes);
    try std.testing.expect(!cfg.runtime.file_sandbox_enabled);
    try std.testing.expect(std.mem.eql(u8, cfg.runtime.file_allowed_roots, ""));
    try std.testing.expect(cfg.runtime.exec_enabled);
    try std.testing.expect(std.mem.eql(u8, cfg.runtime.exec_allowlist, ""));
    try std.testing.expect(cfg.security.loop_guard_enabled);
    try std.testing.expectEqual(@as(u8, 90), cfg.security.risk_block_threshold);
}

test "fingerprint is deterministic and sensitive to config changes" {
    const cfg_a = defaults();
    const hash_a = fingerprintHex(cfg_a);
    const hash_a_repeat = fingerprintHex(cfg_a);
    try std.testing.expect(std.mem.eql(u8, &hash_a, &hash_a_repeat));

    var cfg_b = cfg_a;
    cfg_b.gateway.require_token = true;
    const hash_b = fingerprintHex(cfg_b);
    try std.testing.expect(!std.mem.eql(u8, &hash_a, &hash_b));
}
