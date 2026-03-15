const std = @import("std");
const abi = @import("abi.zig");
const ata_pio_disk = @import("ata_pio_disk.zig");
const filesystem = @import("filesystem.zig");
const package_store = @import("package_store.zig");
const storage_backend = @import("storage_backend.zig");
const tool_exec = @import("tool_exec.zig");
const tool_layout = @import("tool_layout.zig");

pub const boot_dir_path = "/boot";
pub const system_dir_path = "/system";
pub const runtime_dir_path = "/runtime";
pub const install_dir_path = "/runtime/install";
pub const loader_cfg_path = "/boot/loader.cfg";
pub const kernel_info_path = "/system/kernel.txt";
pub const install_manifest_path = "/runtime/install/manifest.txt";
pub const bootstrap_package_name = "bootstrap";
pub const bootstrap_state_path = "/runtime/state/bootstrap.txt";
pub const bootstrap_state_payload = "install-ok";
pub const bootstrap_script =
    \\mkdir /runtime/state
    \\write-file /runtime/state/bootstrap.txt install-ok
    \\echo bootstrap-ok
;

pub const Error = filesystem.Error || package_store.Error || tool_layout.Error || storage_backend.Error || error{
    ManifestTooLong,
};

pub fn installDefaultLayout(tick: u64) Error!void {
    storage_backend.init();
    try tool_layout.init();
    try filesystem.init();

    try filesystem.createDirPath(boot_dir_path);
    try filesystem.createDirPath(system_dir_path);
    try filesystem.createDirPath(install_dir_path);

    var loader_buf: [160]u8 = undefined;
    var kernel_buf: [128]u8 = undefined;
    var manifest_buf: [192]u8 = undefined;

    const loader = try loaderConfigForCurrentBackend(&loader_buf);
    const kernel = try kernelConfigForCurrentBackend(&kernel_buf);
    const manifest = try installManifestForCurrentBackend(&manifest_buf);

    try filesystem.writeFile(loader_cfg_path, loader, tick);
    try filesystem.writeFile(kernel_info_path, kernel, tick);
    try filesystem.writeFile(install_manifest_path, manifest, tick);
    try package_store.installScriptPackage(bootstrap_package_name, bootstrap_script, tick);
}

pub fn loaderConfigForCurrentBackend(buffer: []u8) Error![]const u8 {
    return std.fmt.bufPrint(buffer, "default={s}\nentrypoint=/packages/{s}/bin/main.oc\nbackend={s}\n", .{
        bootstrap_package_name,
        bootstrap_package_name,
        backendName(storage_backend.activeBackend()),
    }) catch error.ManifestTooLong;
}

pub fn kernelConfigForCurrentBackend(buffer: []u8) Error![]const u8 {
    return std.fmt.bufPrint(buffer, "name=openclaw-zig\napi_version={d}\nstorage_backend={s}\n", .{
        abi.api_version,
        backendName(storage_backend.activeBackend()),
    }) catch error.ManifestTooLong;
}

pub fn installManifestForCurrentBackend(buffer: []u8) Error![]const u8 {
    return std.fmt.bufPrint(buffer, "backend={s}\nlogical_base_lba={d}\nblock_count={d}\nbootstrap_package={s}\n", .{
        backendName(storage_backend.activeBackend()),
        currentLogicalBaseLba(),
        storage_backend.statePtr().block_count,
        bootstrap_package_name,
    }) catch error.ManifestTooLong;
}

fn backendName(backend: u8) []const u8 {
    return switch (backend) {
        abi.storage_backend_ata_pio => "ata_pio",
        abi.storage_backend_ram_disk => "ram_disk",
        else => "unknown",
    };
}

fn currentLogicalBaseLba() u32 {
    return switch (storage_backend.activeBackend()) {
        abi.storage_backend_ata_pio => ata_pio_disk.logicalBaseLba(),
        else => 0,
    };
}

test "disk installer seeds loader, kernel, manifest, and bootstrap package on ram disk" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    tool_layout.resetForTest();

    try installDefaultLayout(9);

    var loader_buf: [160]u8 = undefined;
    var kernel_buf: [128]u8 = undefined;
    var manifest_buf: [192]u8 = undefined;

    const loader = try filesystem.readFileAlloc(std.testing.allocator, loader_cfg_path, 160);
    defer std.testing.allocator.free(loader);
    try std.testing.expectEqualStrings(try loaderConfigForCurrentBackend(loader_buf[0..]), loader);

    const kernel = try filesystem.readFileAlloc(std.testing.allocator, kernel_info_path, 128);
    defer std.testing.allocator.free(kernel);
    try std.testing.expectEqualStrings(try kernelConfigForCurrentBackend(kernel_buf[0..]), kernel);

    const manifest = try filesystem.readFileAlloc(std.testing.allocator, install_manifest_path, 192);
    defer std.testing.allocator.free(manifest);
    try std.testing.expectEqualStrings(try installManifestForCurrentBackend(manifest_buf[0..]), manifest);

    const listing = try package_store.listPackagesAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(listing);
    try std.testing.expectEqualStrings("bootstrap\n", listing);
}

test "disk installer persists loader and bootstrap package on ata-backed GPT storage" {
    storage_backend.resetForTest();
    filesystem.resetForTest();
    tool_layout.resetForTest();
    ata_pio_disk.testEnableMockDevice(16384);
    ata_pio_disk.testInstallMockProtectiveGptPartition(2048, 8192);
    defer ata_pio_disk.testDisableMockDevice();

    try installDefaultLayout(11);
    try std.testing.expectEqual(@as(u32, 2048), ata_pio_disk.logicalBaseLba());

    filesystem.resetForTest();
    tool_layout.resetForTest();

    const loader = try filesystem.readFileAlloc(std.testing.allocator, loader_cfg_path, 160);
    defer std.testing.allocator.free(loader);
    try std.testing.expect(std.mem.indexOf(u8, loader, "backend=ata_pio") != null);

    const listing = try package_store.listPackagesAlloc(std.testing.allocator, 64);
    defer std.testing.allocator.free(listing);
    try std.testing.expectEqualStrings("bootstrap\n", listing);

    var result = try tool_exec.runCapture(std.testing.allocator, "run-package bootstrap", 512, 256);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expectEqualStrings("created /runtime/state\nwrote 10 bytes to /runtime/state/bootstrap.txt\nbootstrap-ok\n", result.stdout);
    try std.testing.expectEqualStrings("", result.stderr);

    filesystem.resetForTest();
    const payload = try filesystem.readFileAlloc(std.testing.allocator, bootstrap_state_path, 64);
    defer std.testing.allocator.free(payload);
    try std.testing.expectEqualStrings(bootstrap_state_payload, payload);
}
