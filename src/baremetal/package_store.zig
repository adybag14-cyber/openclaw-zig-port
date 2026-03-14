const std = @import("std");
const abi = @import("abi.zig");
const filesystem = @import("filesystem.zig");
const storage_backend = @import("storage_backend.zig");
const ata_pio_disk = @import("ata_pio_disk.zig");

pub const max_name_len: usize = 32;

pub const Error = filesystem.Error || std.mem.Allocator.Error || error{
    InvalidPackageName,
    PackageNotFound,
    ResponseTooLarge,
};

pub fn installScriptPackage(name: []const u8, script: []const u8, tick: u64) Error!void {
    try validatePackageName(name);

    var root_buf: [filesystem.max_path_len]u8 = undefined;
    var bin_buf: [filesystem.max_path_len]u8 = undefined;
    var meta_buf: [filesystem.max_path_len]u8 = undefined;
    var entrypoint_buf: [filesystem.max_path_len]u8 = undefined;
    var manifest_buf: [filesystem.max_path_len]u8 = undefined;

    try filesystem.createDirPath(packageRootPath(name, &root_buf));
    try filesystem.createDirPath(packageBinPath(name, &bin_buf));
    try filesystem.createDirPath(packageMetaPath(name, &meta_buf));

    const entrypoint = try entrypointPath(name, &entrypoint_buf);
    const manifest = try manifestPath(name, &manifest_buf);

    try filesystem.writeFile(entrypoint, script, tick);

    var metadata: [192]u8 = undefined;
    const manifest_body = std.fmt.bufPrint(&metadata, "name={s}\nentrypoint={s}\n", .{
        name,
        entrypoint,
    }) catch return error.InvalidPath;
    try filesystem.writeFile(manifest, manifest_body, tick);
}

pub fn entrypointPath(name: []const u8, buffer: *[filesystem.max_path_len]u8) Error![]const u8 {
    try validatePackageName(name);
    return std.fmt.bufPrint(buffer, "/packages/{s}/bin/main.oc", .{name}) catch error.InvalidPath;
}

pub fn manifestPath(name: []const u8, buffer: *[filesystem.max_path_len]u8) Error![]const u8 {
    try validatePackageName(name);
    return std.fmt.bufPrint(buffer, "/packages/{s}/meta/package.txt", .{name}) catch error.InvalidPath;
}

pub fn listPackagesAlloc(allocator: std.mem.Allocator, max_bytes: usize) Error![]u8 {
    try filesystem.init();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var idx: u32 = 0;
    while (idx < filesystem.max_entries) : (idx += 1) {
        const record = filesystem.entry(idx);
        if (record.kind != abi.filesystem_kind_file) continue;
        const path = record.path[0..record.path_len];
        const package_name = packageNameFromEntrypoint(path) orelse continue;

        const line = try std.fmt.allocPrint(allocator, "{s}\n", .{package_name});
        defer allocator.free(line);
        if (out.items.len + line.len > max_bytes) return error.ResponseTooLarge;
        try out.appendSlice(allocator, line);
    }

    return out.toOwnedSlice(allocator);
}

fn validatePackageName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_len) return error.InvalidPackageName;
    for (name) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') continue;
        return error.InvalidPackageName;
    }
}

fn packageRootPath(name: []const u8, buffer: *[filesystem.max_path_len]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "/packages/{s}", .{name}) catch unreachable;
}

fn packageBinPath(name: []const u8, buffer: *[filesystem.max_path_len]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "/packages/{s}/bin", .{name}) catch unreachable;
}

fn packageMetaPath(name: []const u8, buffer: *[filesystem.max_path_len]u8) []const u8 {
    return std.fmt.bufPrint(buffer, "/packages/{s}/meta", .{name}) catch unreachable;
}

fn packageNameFromEntrypoint(path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "/packages/")) return null;
    if (!std.mem.endsWith(u8, path, "/bin/main.oc")) return null;
    const name = path["/packages/".len .. path.len - "/bin/main.oc".len];
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    return name;
}

test "package store installs script packages into canonical layout" {
    storage_backend.resetForTest();
    filesystem.resetForTest();

    try installScriptPackage("demo", "echo package-ok", 7);

    var entrypoint_buf: [filesystem.max_path_len]u8 = undefined;
    var manifest_buf: [filesystem.max_path_len]u8 = undefined;
    const entrypoint = try entrypointPath("demo", &entrypoint_buf);
    const manifest = try manifestPath("demo", &manifest_buf);

    const script = try filesystem.readFileAlloc(std.testing.allocator, entrypoint, 64);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("echo package-ok", script);

    const metadata = try filesystem.readFileAlloc(std.testing.allocator, manifest, 128);
    defer std.testing.allocator.free(metadata);
    try std.testing.expect(std.mem.indexOf(u8, metadata, "name=demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, metadata, entrypoint) != null);

    const listing = try listPackagesAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(listing);
    try std.testing.expectEqualStrings("demo\n", listing);
}

test "package store persists canonical layout on ata-backed storage" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    ata_pio_disk.testEnableMockDevice(8192);
    ata_pio_disk.testInstallMockMbrPartition(2048, 4096, 0x83);
    defer ata_pio_disk.testDisableMockDevice();

    try installScriptPackage("persisted", "echo persisted-package", 11);
    try std.testing.expectEqual(@as(u32, 2048), ata_pio_disk.logicalBaseLba());

    filesystem.resetForTest();

    var entrypoint_buf: [filesystem.max_path_len]u8 = undefined;
    const entrypoint = try entrypointPath("persisted", &entrypoint_buf);
    const script = try filesystem.readFileAlloc(std.testing.allocator, entrypoint, 64);
    defer std.testing.allocator.free(script);
    try std.testing.expectEqualStrings("echo persisted-package", script);

    const listing = try listPackagesAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(listing);
    try std.testing.expectEqualStrings("persisted\n", listing);
}
