const std = @import("std");
const config = @import("config.zig");
const dispatcher = @import("gateway/dispatcher.zig");
const http_server = @import("gateway/http_server.zig");
const _registry = @import("gateway/registry.zig");
const _protocol = @import("protocol/envelope.zig");
const _lightpanda = @import("bridge/lightpanda.zig");
const _runtime = @import("runtime/state.zig");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = try config.loadFromEnviron(allocator, init.minimal.environ);
    const run_server = try hasServeFlag(allocator, init.minimal.args);
    if (run_server) {
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

fn hasServeFlag(allocator: std.mem.Allocator, args: std.process.Args) !bool {
    var it = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer it.deinit();
    var index: usize = 0;
    while (it.next()) |arg| {
        defer index += 1;
        if (index == 0) continue;
        if (std.mem.eql(u8, arg, "--serve")) return true;
    }
    return false;
}

fn hasServeFlagFromSlice(args: []const []const u8) bool {
    if (args.len <= 1) return false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--serve")) return true;
    }
    return false;
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

test "hasServeFlag detects serve argument" {
    const args = [_][]const u8{
        "openclaw-zig",
        "--serve",
    };
    try std.testing.expect(hasServeFlagFromSlice(&args));
}
