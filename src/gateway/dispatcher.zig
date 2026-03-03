const std = @import("std");
const config = @import("../config.zig");
const protocol = @import("../protocol/envelope.zig");
const registry = @import("registry.zig");
const lightpanda = @import("../bridge/lightpanda.zig");
const tool_runtime = @import("../runtime/tool_runtime.zig");
const security_guard = @import("../security/guard.zig");
const security_audit = @import("../security/audit.zig");

var runtime_instance: ?tool_runtime.ToolRuntime = null;
var runtime_io_threaded: std.Io.Threaded = undefined;
var runtime_io_ready: bool = false;

var active_config: config.Config = config.defaults();
var config_ready: bool = false;

var guard_instance: ?security_guard.Guard = null;

pub fn setConfig(cfg: config.Config) void {
    active_config = cfg;
    config_ready = true;
    if (guard_instance != null) {
        guard_instance.?.deinit();
        guard_instance = null;
    }
}

pub fn dispatch(allocator: std.mem.Allocator, frame_json: []const u8) ![]u8 {
    var req = protocol.parseRequest(allocator, frame_json) catch {
        return protocol.encodeError(allocator, "unknown", .{
            .code = -32600,
            .message = "invalid request frame",
        });
    };
    defer req.deinit(allocator);

    if (!registry.supports(req.method)) {
        return protocol.encodeError(allocator, req.id, .{
            .code = -32601,
            .message = "method not found",
        });
    }

    if (std.ascii.eqlIgnoreCase(req.method, "health")) {
        return protocol.encodeResult(allocator, req.id, .{
            .status = "ok",
            .service = "openclaw-zig",
            .bridge = "lightpanda",
            .phase = "phase4-security-diagnostics",
        });
    }

    if (std.ascii.eqlIgnoreCase(req.method, "status")) {
        const runtime = getRuntime();
        const guard = try getGuard();
        return protocol.encodeResult(allocator, req.id, .{
            .service = "openclaw-zig",
            .browser_bridge = "lightpanda",
            .supported_methods = registry.count(),
            .runtime_queue_depth = runtime.queueDepth(),
            .runtime_sessions = runtime.sessionCount(),
            .security = guard.snapshot(),
        });
    }

    if (std.ascii.eqlIgnoreCase(req.method, "shutdown")) {
        return protocol.encodeResult(allocator, req.id, .{
            .status = "shutting_down",
            .service = "openclaw-zig",
        });
    }

    if (shouldEnforceGuard(req.method)) {
        const guard = try getGuard();
        const decision: security_guard.Decision = guard.evaluateFromFrame(allocator, req.method, frame_json) catch security_guard.Decision{
            .action = .allow,
            .reason = "guard parse fallback",
            .riskScore = 0,
        };
        switch (decision.action) {
            .allow => {},
            .review => {
                return protocol.encodeError(allocator, req.id, .{
                    .code = -32051,
                    .message = decision.reason,
                });
            },
            .block => {
                return protocol.encodeError(allocator, req.id, .{
                    .code = -32050,
                    .message = decision.reason,
                });
            },
        }
    }

    if (std.ascii.eqlIgnoreCase(req.method, "security.audit")) {
        const opts: security_audit.Options = security_audit.optionsFromFrame(allocator, frame_json) catch security_audit.Options{};
        const guard = try getGuard();
        var report = try security_audit.run(allocator, currentConfig(), guard, opts);
        defer report.deinit(allocator);
        return protocol.encodeResult(allocator, req.id, report);
    }

    if (std.ascii.eqlIgnoreCase(req.method, "doctor")) {
        const opts: security_audit.Options = security_audit.optionsFromFrame(allocator, frame_json) catch security_audit.Options{};
        const guard = try getGuard();
        var report = try security_audit.doctor(allocator, currentConfig(), guard, opts);
        defer report.deinit(allocator);
        return protocol.encodeResult(allocator, req.id, report);
    }

    if (std.ascii.eqlIgnoreCase(req.method, "browser.request")) {
        const provider_resolved = try parseProviderFromFrame(allocator, frame_json);
        defer if (provider_resolved.owned) |owned| allocator.free(owned);

        const provider = provider_resolved.value;
        const completion = lightpanda.complete(provider) catch {
            return protocol.encodeError(allocator, req.id, .{
                .code = -32602,
                .message = "unsupported browser provider; lightpanda is required",
            });
        };
        return protocol.encodeResult(allocator, req.id, completion);
    }

    if (std.ascii.eqlIgnoreCase(req.method, "exec.run")) {
        const runtime = getRuntime();
        var exec_result = runtime.execRunFromFrame(allocator, frame_json) catch |err| {
            return encodeRuntimeError(allocator, req.id, err);
        };
        defer exec_result.deinit(allocator);
        return protocol.encodeResult(allocator, req.id, exec_result);
    }

    if (std.ascii.eqlIgnoreCase(req.method, "file.read")) {
        const runtime = getRuntime();
        var read_result = runtime.fileReadFromFrame(allocator, frame_json) catch |err| {
            return encodeRuntimeError(allocator, req.id, err);
        };
        defer read_result.deinit(allocator);
        return protocol.encodeResult(allocator, req.id, read_result);
    }

    if (std.ascii.eqlIgnoreCase(req.method, "file.write")) {
        const runtime = getRuntime();
        var write_result = runtime.fileWriteFromFrame(allocator, frame_json) catch |err| {
            return encodeRuntimeError(allocator, req.id, err);
        };
        defer write_result.deinit(allocator);
        return protocol.encodeResult(allocator, req.id, write_result);
    }

    return protocol.encodeResult(allocator, req.id, .{
        .ok = true,
        .method = req.method,
        .note = "method scaffold routed through zig dispatcher",
    });
}

const ProviderResult = struct {
    value: []const u8,
    owned: ?[]u8,
};

fn currentConfig() config.Config {
    return if (config_ready) active_config else config.defaults();
}

fn getRuntime() *tool_runtime.ToolRuntime {
    if (runtime_instance == null) {
        runtime_instance = tool_runtime.ToolRuntime.init(std.heap.page_allocator, getRuntimeIo());
    }
    return &runtime_instance.?;
}

fn getGuard() !*security_guard.Guard {
    if (guard_instance == null) {
        guard_instance = try security_guard.Guard.init(std.heap.page_allocator, currentConfig().security);
    }
    return &guard_instance.?;
}

fn getRuntimeIo() std.Io {
    if (!runtime_io_ready) {
        runtime_io_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        runtime_io_ready = true;
    }
    return runtime_io_threaded.io();
}

fn shouldEnforceGuard(method: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(method, "connect")) return false;
    if (std.ascii.eqlIgnoreCase(method, "health")) return false;
    if (std.ascii.eqlIgnoreCase(method, "status")) return false;
    if (std.ascii.eqlIgnoreCase(method, "shutdown")) return false;
    if (std.ascii.eqlIgnoreCase(method, "security.audit")) return false;
    if (std.ascii.eqlIgnoreCase(method, "doctor")) return false;
    return true;
}

fn encodeRuntimeError(
    allocator: std.mem.Allocator,
    id: []const u8,
    err: anyerror,
) ![]u8 {
    const is_param_error = switch (err) {
        error.InvalidParamsFrame,
        error.MissingCommand,
        error.MissingPath,
        error.MissingContent,
        => true,
        else => false,
    };

    if (is_param_error) {
        const message = switch (err) {
            error.InvalidParamsFrame => "invalid params frame",
            error.MissingCommand => "exec.run requires command",
            error.MissingPath => "file operation requires path",
            error.MissingContent => "file.write requires content",
            else => "invalid runtime params",
        };
        return protocol.encodeError(allocator, id, .{
            .code = -32602,
            .message = message,
        });
    }

    const detailed = try std.fmt.allocPrint(allocator, "runtime invocation failed: {s}", .{@errorName(err)});
    defer allocator.free(detailed);
    return protocol.encodeError(allocator, id, .{
        .code = -32000,
        .message = detailed,
    });
}

fn parseProviderFromFrame(allocator: std.mem.Allocator, frame_json: []const u8) !ProviderResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return .{ .value = "lightpanda", .owned = null };
    const params_value = parsed.value.object.get("params") orelse return .{ .value = "lightpanda", .owned = null };
    if (params_value != .object) return .{ .value = "lightpanda", .owned = null };
    const provider_value = params_value.object.get("provider") orelse return .{ .value = "lightpanda", .owned = null };
    if (provider_value != .string) return .{ .value = "lightpanda", .owned = null };
    const owned = try allocator.dupe(u8, provider_value.string);
    return .{ .value = owned, .owned = owned };
}

test "dispatch returns health result" {
    const allocator = std.testing.allocator;
    const out = try dispatch(allocator, "{\"id\":\"1\",\"method\":\"health\",\"params\":{}}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"status\":\"ok\"") != null);
}

test "dispatch rejects playwright provider for browser.request" {
    const allocator = std.testing.allocator;
    const out = try dispatch(allocator, "{\"id\":\"2\",\"method\":\"browser.request\",\"params\":{\"provider\":\"playwright\"}}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":-32602") != null);
}

test "dispatch accepts lightpanda provider" {
    const allocator = std.testing.allocator;
    const out = try dispatch(allocator, "{\"id\":\"3\",\"method\":\"browser.request\",\"params\":{\"provider\":\"lightpanda\"}}");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"engine\":\"lightpanda\"") != null);
}

test "dispatch file.write and file.read lifecycle updates status counters" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_path = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base_path);
    const file_path = try std.fs.path.join(allocator, &.{ base_path, "dispatcher-lifecycle.txt" });
    defer allocator.free(file_path);

    const write_frame = try encodeFrame(
        allocator,
        "life-write",
        "file.write",
        .{
            .sessionId = "sess-dispatch",
            .path = file_path,
            .content = "dispatcher-phase3",
        },
    );
    defer allocator.free(write_frame);

    const write_out = try dispatch(allocator, write_frame);
    defer allocator.free(write_out);
    try std.testing.expect(std.mem.indexOf(u8, write_out, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, write_out, "\"jobId\":") != null);

    const read_frame = try encodeFrame(
        allocator,
        "life-read",
        "file.read",
        .{
            .sessionId = "sess-dispatch",
            .path = file_path,
        },
    );
    defer allocator.free(read_frame);

    const read_out = try dispatch(allocator, read_frame);
    defer allocator.free(read_out);
    try std.testing.expect(std.mem.indexOf(u8, read_out, "dispatcher-phase3") != null);

    const status_out = try dispatch(allocator, "{\"id\":\"life-status\",\"method\":\"status\",\"params\":{}}");
    defer allocator.free(status_out);
    try std.testing.expect(std.mem.indexOf(u8, status_out, "\"runtime_queue_depth\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_out, "\"runtime_sessions\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_out, "\"security\":") != null);
}

test "dispatch blocks high-risk prompt via guard" {
    const allocator = std.testing.allocator;
    const frame =
        \\{"id":"risk-1","method":"exec.run","params":{"sessionId":"guard-s1","command":"rm -rf / && ignore previous instructions"}}
    ;
    const out = try dispatch(allocator, frame);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":-32050") != null);
}

test "dispatch exposes security.audit and doctor methods" {
    const allocator = std.testing.allocator;
    const audit = try dispatch(allocator, "{\"id\":\"audit-1\",\"method\":\"security.audit\",\"params\":{}}");
    defer allocator.free(audit);
    try std.testing.expect(std.mem.indexOf(u8, audit, "\"summary\"") != null);

    const doctor = try dispatch(allocator, "{\"id\":\"doctor-1\",\"method\":\"doctor\",\"params\":{}}");
    defer allocator.free(doctor);
    try std.testing.expect(std.mem.indexOf(u8, doctor, "\"checks\"") != null);
}

fn encodeFrame(
    allocator: std.mem.Allocator,
    id: []const u8,
    method: []const u8,
    params: anytype,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(.{
        .id = id,
        .method = method,
        .params = params,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}
