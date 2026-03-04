const std = @import("std");
const config = @import("config.zig");
const dispatcher = @import("gateway/dispatcher.zig");
const http_server = @import("gateway/http_server.zig");
const security_guard = @import("security/guard.zig");
const security_audit = @import("security/audit.zig");
const baremetal_abi = @import("baremetal/abi.zig");
const baremetal_x86_bootstrap = @import("baremetal/x86_bootstrap.zig");

const CliFlags = struct {
    serve: bool = false,
    doctor: bool = false,
    security_audit: bool = false,
    deep: bool = false,
    fix: bool = false,
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    dispatcher.setEnviron(init.minimal.environ);
    const cfg = try config.loadFromEnviron(allocator, init.minimal.environ);
    dispatcher.setConfig(cfg);

    const flags = try parseCliFlags(allocator, init.minimal.args);

    if (flags.doctor or flags.security_audit) {
        var runtime_guard = try security_guard.Guard.init(std.heap.page_allocator, cfg.security);
        defer runtime_guard.deinit();

        if (flags.doctor) {
            var report = try security_audit.doctor(allocator, cfg, &runtime_guard, .{
                .deep = flags.deep,
                .fix = flags.fix,
            });
            defer report.deinit(allocator);
            try printJson(report);
            return;
        }

        var report = try security_audit.run(allocator, cfg, &runtime_guard, .{
            .deep = flags.deep,
            .fix = flags.fix,
        });
        defer report.deinit(allocator);
        try printJson(report);
        return;
    }

    if (flags.serve) {
        std.debug.print(
            "openclaw-zig server start ({s}:{d}) bridge=lightpanda endpoint={s}\n",
            .{ cfg.http_bind, cfg.http_port, cfg.lightpanda_endpoint },
        );
        try http_server.serve(allocator, cfg, .{});
        return;
    }

    const health_frame = try dispatcher.dispatch(
        allocator,
        "{\"id\":\"boot\",\"method\":\"health\",\"params\":{}}",
    );

    std.debug.print(
        "openclaw-zig bootstrap ready ({s}:{d}) bridge=lightpanda endpoint={s}\n",
        .{ cfg.http_bind, cfg.http_port, cfg.lightpanda_endpoint },
    );
    std.debug.print("health -> {s}\n", .{health_frame});
}

fn parseCliFlags(allocator: std.mem.Allocator, args: std.process.Args) !CliFlags {
    var out: CliFlags = .{};
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    var index: usize = 0;
    while (it.next()) |arg| {
        defer index += 1;
        if (index == 0) continue;
        if (std.mem.eql(u8, arg, "--serve")) out.serve = true else if (std.mem.eql(u8, arg, "--doctor")) out.doctor = true else if (std.mem.eql(u8, arg, "--security-audit")) out.security_audit = true else if (std.mem.eql(u8, arg, "--deep")) out.deep = true else if (std.mem.eql(u8, arg, "--fix")) out.fix = true;
    }
    return out;
}

fn parseCliFlagsFromSlice(args: []const []const u8) CliFlags {
    var out: CliFlags = .{};
    if (args.len <= 1) return out;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--serve")) out.serve = true else if (std.mem.eql(u8, arg, "--doctor")) out.doctor = true else if (std.mem.eql(u8, arg, "--security-audit")) out.security_audit = true else if (std.mem.eql(u8, arg, "--deep")) out.deep = true else if (std.mem.eql(u8, arg, "--fix")) out.fix = true;
    }
    return out;
}

fn printJson(value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    const bytes = try out.toOwnedSlice();
    defer std.heap.page_allocator.free(bytes);
    std.debug.print("{s}\n", .{bytes});
}

test "bootstrap string is non-empty" {
    const value = "openclaw-zig bootstrap ready";
    try std.testing.expect(value.len > 0);
}

test "main modules include lightpanda-only dispatcher" {
    const allocator = std.testing.allocator;
    const out = try dispatcher.dispatch(
        allocator,
        "{\"id\":\"4\",\"method\":\"browser.request\",\"params\":{\"provider\":\"puppeteer\"}}",
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"code\":-32602") != null);
}

test "parseCliFlags detects serve/doctor/security flags" {
    const args = [_][]const u8{
        "openclaw-zig",
        "--serve",
        "--doctor",
        "--deep",
        "--fix",
    };
    const flags = parseCliFlagsFromSlice(&args);
    try std.testing.expect(flags.serve);
    try std.testing.expect(flags.doctor);
    try std.testing.expect(flags.deep);
    try std.testing.expect(flags.fix);
}

test "baremetal abi module exposes expected v2 contract constants" {
    try std.testing.expectEqual(@as(u16, 2), baremetal_abi.api_version);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_command_mailbox) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_command_mailbox) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_descriptor_tables_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_interrupt_stub) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_interrupt_mailbox_control) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_interrupt_mailbox) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_interrupt_state_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_interrupt_state) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_descriptor_load_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_descriptor_load) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_exception_telemetry_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_exception_telemetry) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_exception_code_payload_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_exception_payload) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_exception_history_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_exception_history) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_interrupt_history_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_interrupt_history) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_vector_counters_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_vector_counters) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_boot_diagnostics_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_boot_diagnostics) != 0);
    try std.testing.expect((baremetal_abi.defaultFeatureFlags() & baremetal_abi.feature_command_history_export) != 0);
    try std.testing.expect((baremetal_abi.defaultAbiFlags() & baremetal_abi.kernel_abi_command_history) != 0);
}

test "baremetal x86 bootstrap module exports descriptor table metadata" {
    baremetal_x86_bootstrap.init();
    try std.testing.expect(baremetal_x86_bootstrap.oc_descriptor_tables_ready());
    _ = baremetal_x86_bootstrap.oc_gdtr_ptr();
    _ = baremetal_x86_bootstrap.oc_idtr_ptr();
    _ = baremetal_x86_bootstrap.oc_gdt_ptr();
    _ = baremetal_x86_bootstrap.oc_idt_ptr();
    try std.testing.expect(baremetal_x86_bootstrap.oc_descriptor_init_count() > 0);
    _ = baremetal_x86_bootstrap.oc_interrupt_state_ptr();
    _ = baremetal_x86_bootstrap.oc_try_load_descriptor_tables();
    try std.testing.expect(baremetal_x86_bootstrap.oc_descriptor_tables_loaded());
    _ = baremetal_x86_bootstrap.oc_last_exception_vector();
    _ = baremetal_x86_bootstrap.oc_exception_count();
    _ = baremetal_x86_bootstrap.oc_last_exception_code();
    _ = baremetal_x86_bootstrap.oc_exception_history_capacity();
    _ = baremetal_x86_bootstrap.oc_exception_history_len();
    _ = baremetal_x86_bootstrap.oc_exception_history_event(0);
    _ = baremetal_x86_bootstrap.oc_exception_history_ptr();
    _ = baremetal_x86_bootstrap.oc_interrupt_history_capacity();
    _ = baremetal_x86_bootstrap.oc_interrupt_history_len();
    _ = baremetal_x86_bootstrap.oc_interrupt_history_event(0);
    _ = baremetal_x86_bootstrap.oc_interrupt_history_ptr();
    _ = baremetal_x86_bootstrap.oc_interrupt_vector_counts_ptr();
    _ = baremetal_x86_bootstrap.oc_exception_vector_counts_ptr();
    _ = baremetal_x86_bootstrap.oc_interrupt_vector_count(0);
    _ = baremetal_x86_bootstrap.oc_exception_vector_count(0);
}
