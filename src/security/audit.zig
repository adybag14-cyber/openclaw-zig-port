const std = @import("std");
const config = @import("../config.zig");
const guard = @import("guard.zig");

pub const Finding = struct {
    checkId: []const u8,
    severity: []const u8,
    title: []const u8,
    detail: []const u8,
    remediation: ?[]const u8 = null,
};

pub const Summary = struct {
    critical: usize,
    warn: usize,
    info: usize,
};

pub const DeepGateway = struct {
    attempted: bool,
    target: []const u8,
    ok: bool,
    @"error": ?[]const u8 = null,
};

pub const DeepPolicyBundle = struct {
    attempted: bool,
    path: []const u8,
    exists: bool,
    parseOk: bool,
    @"error": ?[]const u8 = null,
};

pub const DeepReport = struct {
    gateway: DeepGateway,
    policyBundle: DeepPolicyBundle,
};

pub const FixAction = struct {
    kind: []const u8,
    target: []const u8,
    ok: bool,
    skipped: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const FixResult = struct {
    ok: bool,
    changes: []const []const u8,
    actions: []FixAction,
};

pub const Report = struct {
    ts: i64,
    summary: Summary,
    findings: []Finding,
    deep: ?DeepReport = null,
    fix: ?FixResult = null,

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        allocator.free(self.findings);
        if (self.fix) |fix| {
            allocator.free(fix.changes);
            allocator.free(fix.actions);
        }
    }
};

pub const DoctorCheck = struct {
    id: []const u8,
    status: []const u8,
    message: []const u8,
    detail: []const u8,
};

pub const DoctorReport = struct {
    checks: []DoctorCheck,
    security: Report,

    pub fn deinit(self: *DoctorReport, allocator: std.mem.Allocator) void {
        allocator.free(self.checks);
        self.security.deinit(allocator);
    }
};

pub const Options = struct {
    deep: bool = false,
    fix: bool = false,
};

pub fn optionsFromFrame(allocator: std.mem.Allocator, frame_json: []const u8) !Options {
    var out: Options = .{};
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return out;
    const params = parsed.value.object.get("params") orelse return out;
    if (params != .object) return out;

    if (params.object.get("deep")) |value| {
        out.deep = boolFromJson(value, false);
    }
    if (params.object.get("fix")) |value| {
        out.fix = boolFromJson(value, false);
    }
    return out;
}

pub fn run(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    runtime_guard: *const guard.Guard,
    options: Options,
) !Report {
    var findings = std.ArrayList(Finding).empty;
    defer findings.deinit(allocator);
    const io = std.Io.Threaded.global_single_threaded.io();

    if (!isLoopbackBind(cfg.http_bind)) {
        try findings.append(allocator, .{
            .checkId = "gateway.bind.public",
            .severity = "warn",
            .title = "Gateway bind is publicly reachable",
            .detail = "http_bind should be loopback-scoped for local control plane usage",
            .remediation = "set OPENCLAW_ZIG_HTTP_BIND=127.0.0.1 for production defaults",
        });
    }

    if (!cfg.security.loop_guard_enabled) {
        try findings.append(allocator, .{
            .checkId = "security.loop_guard.disabled",
            .severity = "warn",
            .title = "Loop guard is disabled",
            .detail = "security.loop_guard_enabled=false weakens replay/loop defense",
            .remediation = "enable OPENCLAW_ZIG_SECURITY_LOOP_GUARD_ENABLED=true",
        });
    }

    if (cfg.security.loop_guard_enabled and (cfg.security.loop_guard_window_ms == 0 or cfg.security.loop_guard_max_hits == 0)) {
        try findings.append(allocator, .{
            .checkId = "security.loop_guard.thresholds.invalid",
            .severity = "warn",
            .title = "Loop guard thresholds are invalid",
            .detail = "loop_guard_window_ms and loop_guard_max_hits must be positive",
            .remediation = "set positive loop guard thresholds",
        });
    }

    if (cfg.security.risk_review_threshold < 40 or cfg.security.risk_block_threshold < 60) {
        try findings.append(allocator, .{
            .checkId = "security.risk_thresholds.permissive",
            .severity = "warn",
            .title = "Risk thresholds are permissive",
            .detail = "review/block thresholds are lower than recommended minimums",
            .remediation = "set review >= 40 and block >= 60",
        });
    }

    if (std.mem.trim(u8, cfg.security.blocked_message_patterns, " \t\r\n").len == 0) {
        try findings.append(allocator, .{
            .checkId = "security.blocked_patterns.empty",
            .severity = "warn",
            .title = "Blocked message patterns are empty",
            .detail = "no deny signatures configured in blocked message patterns",
            .remediation = "configure blocked patterns for prompt-injection signatures",
        });
    }

    const policy_path = std.mem.trim(u8, cfg.security.policy_bundle_path, " \t\r\n");
    if (policy_path.len == 0 or startsWithIgnoreCase(policy_path, "memory://")) {
        try findings.append(allocator, .{
            .checkId = "security.policy_bundle.unset",
            .severity = "info",
            .title = "Policy bundle path is not persisted",
            .detail = "policy bundle path is empty or memory-backed",
            .remediation = "set OPENCLAW_ZIG_SECURITY_POLICY_BUNDLE_PATH to a file path",
        });
    } else {
        if (std.Io.Dir.cwd().statFile(io, policy_path, .{})) |info| {
            if (info.kind == .directory) {
                try findings.append(allocator, .{
                    .checkId = "security.policy_bundle.is_dir",
                    .severity = "warn",
                    .title = "Policy bundle path points to a directory",
                    .detail = "policy bundle path must reference a JSON file",
                    .remediation = "set policy bundle path to a JSON file path",
                });
            }
        } else |_| {
            try findings.append(allocator, .{
                .checkId = "security.policy_bundle.stat_failed",
                .severity = "warn",
                .title = "Policy bundle file cannot be inspected",
                .detail = "policy bundle path does not exist or is inaccessible",
                .remediation = "ensure policy bundle file exists and is readable",
            });
        }
    }

    const guard_snapshot = runtime_guard.snapshot();
    if (guard_snapshot.blockedPatternCount == 0) {
        try findings.append(allocator, .{
            .checkId = "security.guard.patterns.empty",
            .severity = "warn",
            .title = "Runtime guard has zero blocked patterns",
            .detail = "guard pattern list is empty after configuration parse",
            .remediation = "configure blocked patterns or restore defaults",
        });
    }

    const fix_result = if (options.fix) try applyFixes(allocator, cfg) else null;
    const deep_result = if (options.deep) try buildDeepReport(allocator, cfg) else null;

    const owned_findings = try findings.toOwnedSlice(allocator);
    return .{
        .ts = std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds(),
        .summary = summarize(owned_findings),
        .findings = owned_findings,
        .deep = deep_result,
        .fix = fix_result,
    };
}

pub fn doctor(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    runtime_guard: *const guard.Guard,
    options: Options,
) !DoctorReport {
    var security = try run(allocator, cfg, runtime_guard, options);
    errdefer security.deinit(allocator);

    var checks = std.ArrayList(DoctorCheck).empty;
    defer checks.deinit(allocator);

    try checks.append(allocator, .{
        .id = "gateway.bind_scope",
        .status = if (isLoopbackBind(cfg.http_bind)) "pass" else "warn",
        .message = cfg.http_bind,
        .detail = "prefer loopback bind for local control endpoints",
    });
    try checks.append(allocator, .{
        .id = "security.loop_guard",
        .status = if (cfg.security.loop_guard_enabled) "pass" else "warn",
        .message = if (cfg.security.loop_guard_enabled) "enabled" else "disabled",
        .detail = "loop guard blocks repetitive tool calls",
    });
    try checks.append(allocator, .{
        .id = "security.audit.summary",
        .status = if (security.summary.critical > 0) "fail" else if (security.summary.warn > 0) "warn" else "pass",
        .message = "derived",
        .detail = "derived from security.audit findings",
    });
    const docker_available = commandAvailable(allocator, "docker");
    try checks.append(allocator, .{
        .id = "docker.binary",
        .status = if (docker_available) "pass" else "warn",
        .message = if (docker_available) "available" else "unavailable",
        .detail = "docker is used by smoke/system validation",
    });

    return .{
        .checks = try checks.toOwnedSlice(allocator),
        .security = security,
    };
}

fn summarize(findings: []const Finding) Summary {
    var out: Summary = .{ .critical = 0, .warn = 0, .info = 0 };
    for (findings) |item| {
        if (std.mem.eql(u8, item.severity, "critical")) out.critical += 1 else if (std.mem.eql(u8, item.severity, "warn")) out.warn += 1 else out.info += 1;
    }
    return out;
}

fn applyFixes(allocator: std.mem.Allocator, cfg: config.Config) !FixResult {
    var changes = std.ArrayList([]const u8).empty;
    defer changes.deinit(allocator);
    var actions = std.ArrayList(FixAction).empty;
    defer actions.deinit(allocator);
    const io = std.Io.Threaded.global_single_threaded.io();

    var ok = true;
    const policy_raw = std.mem.trim(u8, cfg.security.policy_bundle_path, " \t\r\n");
    var policy_path = policy_raw;
    if (policy_path.len == 0 or startsWithIgnoreCase(policy_path, "memory://")) {
        policy_path = ".openclaw-zig/security-policy.json";
        try changes.append(allocator, "set policy bundle path to persisted default");
    }

    if (std.fs.path.dirname(policy_path)) |dir_name| {
        std.Io.Dir.cwd().createDirPath(io, dir_name) catch |err| {
            ok = false;
            try actions.append(allocator, .{
                .kind = "mkdir",
                .target = dir_name,
                .ok = false,
                .@"error" = @errorName(err),
            });
            return .{
                .ok = false,
                .changes = try changes.toOwnedSlice(allocator),
                .actions = try actions.toOwnedSlice(allocator),
            };
        };
        try actions.append(allocator, .{
            .kind = "mkdir",
            .target = dir_name,
            .ok = true,
        });
    }

    const default_policy =
        \\{
        \\  "version": 1,
        \\  "generatedBy": "openclaw-zig-security-audit-fix",
        \\  "default_action": "allow",
        \\  "tool_policies": {},
        \\  "blocked_message_patterns": ["ignore previous instructions", "system prompt", "jailbreak"]
        \\}
    ;

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = policy_path, .data = default_policy }) catch |err| {
        ok = false;
        try actions.append(allocator, .{
            .kind = "write",
            .target = policy_path,
            .ok = false,
            .@"error" = @errorName(err),
        });
        return .{
            .ok = false,
            .changes = try changes.toOwnedSlice(allocator),
            .actions = try actions.toOwnedSlice(allocator),
        };
    };
    try changes.append(allocator, "created policy bundle file");
    try actions.append(allocator, .{
        .kind = "write",
        .target = policy_path,
        .ok = true,
    });

    return .{
        .ok = ok,
        .changes = try changes.toOwnedSlice(allocator),
        .actions = try actions.toOwnedSlice(allocator),
    };
}

fn buildDeepReport(allocator: std.mem.Allocator, cfg: config.Config) !DeepReport {
    _ = allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const target = try std.fmt.allocPrint(std.heap.page_allocator, "{s}:{d}", .{ cfg.http_bind, cfg.http_port });
    defer std.heap.page_allocator.free(target);

    const gateway = blk: {
        const address = std.Io.net.IpAddress.resolve(io, cfg.http_bind, cfg.http_port) catch |err| {
            break :blk DeepGateway{
                .attempted = true,
                .target = target,
                .ok = false,
                .@"error" = @errorName(err),
            };
        };
        var stream = address.connect(io, .{ .mode = .stream, .protocol = .tcp, .timeout = .{
            .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromMilliseconds(1500),
            },
        } }) catch |err| {
            break :blk DeepGateway{
                .attempted = true,
                .target = target,
                .ok = false,
                .@"error" = @errorName(err),
            };
        };
        stream.close(io);
        break :blk DeepGateway{
            .attempted = true,
            .target = target,
            .ok = true,
        };
    };

    const policy = probePolicyBundle(cfg.security.policy_bundle_path);
    return .{
        .gateway = gateway,
        .policyBundle = policy,
    };
}

fn probePolicyBundle(path: []const u8) DeepPolicyBundle {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (trimmed.len == 0 or startsWithIgnoreCase(trimmed, "memory://")) {
        return .{
            .attempted = false,
            .path = trimmed,
            .exists = false,
            .parseOk = true,
        };
    }

    const io = std.Io.Threaded.global_single_threaded.io();
    const stat = std.Io.Dir.cwd().statFile(io, trimmed, .{}) catch |err| {
        return .{
            .attempted = true,
            .path = trimmed,
            .exists = false,
            .parseOk = false,
            .@"error" = @errorName(err),
        };
    };
    if (stat.kind == .directory) {
        return .{
            .attempted = true,
            .path = trimmed,
            .exists = true,
            .parseOk = false,
            .@"error" = "path is a directory",
        };
    }

    const raw = std.Io.Dir.cwd().readFileAlloc(io, trimmed, std.heap.page_allocator, .limited(512 * 1024)) catch |err| {
        return .{
            .attempted = true,
            .path = trimmed,
            .exists = true,
            .parseOk = false,
            .@"error" = @errorName(err),
        };
    };
    defer std.heap.page_allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch |err| {
        return .{
            .attempted = true,
            .path = trimmed,
            .exists = true,
            .parseOk = false,
            .@"error" = @errorName(err),
        };
    };
    parsed.deinit();
    return .{
        .attempted = true,
        .path = trimmed,
        .exists = true,
        .parseOk = true,
    };
}

fn isLoopbackBind(bind: []const u8) bool {
    const trimmed = std.mem.trim(u8, bind, " \t\r\n");
    if (trimmed.len == 0) return false;
    return std.ascii.eqlIgnoreCase(trimmed, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(trimmed, "::1") or
        std.ascii.eqlIgnoreCase(trimmed, "localhost");
}

fn commandAvailable(allocator: std.mem.Allocator, command: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    _ = allocator;
    const result = std.process.run(std.heap.page_allocator, io, .{
        .argv = &[_][]const u8{ command, "--version" },
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(1024),
        .timeout = .{
            .duration = .{
                .clock = .awake,
                .raw = std.Io.Duration.fromMilliseconds(2_000),
            },
        },
    }) catch return false;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    return true;
}

fn boolFromJson(value: std.json.Value, fallback: bool) bool {
    return switch (value) {
        .bool => |b| b,
        .string => |s| blk: {
            const trimmed = std.mem.trim(u8, s, " \t\r\n");
            if (trimmed.len == 0) break :blk fallback;
            if (std.ascii.eqlIgnoreCase(trimmed, "true") or std.mem.eql(u8, trimmed, "1") or std.ascii.eqlIgnoreCase(trimmed, "yes") or std.ascii.eqlIgnoreCase(trimmed, "on")) break :blk true;
            if (std.ascii.eqlIgnoreCase(trimmed, "false") or std.mem.eql(u8, trimmed, "0") or std.ascii.eqlIgnoreCase(trimmed, "no") or std.ascii.eqlIgnoreCase(trimmed, "off")) break :blk false;
            break :blk fallback;
        },
        .integer => |i| i != 0,
        else => fallback,
    };
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (prefix, 0..) |ch, idx| {
        if (std.ascii.toLower(value[idx]) != std.ascii.toLower(ch)) return false;
    }
    return true;
}

test "security audit warns when bind is not loopback" {
    const allocator = std.testing.allocator;
    var cfg = config.defaults();
    cfg.http_bind = "0.0.0.0";
    var runtime_guard = try guard.Guard.init(allocator, cfg.security);
    defer runtime_guard.deinit();

    var report = try run(allocator, cfg, &runtime_guard, .{});
    defer report.deinit(allocator);
    try std.testing.expect(report.summary.warn >= 1);
}
