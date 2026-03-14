const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const baremetal_qemu_smoke = b.option(bool, "baremetal-qemu-smoke", "Enable QEMU auto-exit boot smoke path in bare-metal image") orelse false;
    const baremetal_console_probe_banner = b.option(bool, "baremetal-console-probe-banner", "Enable the bare-metal console probe banner in the freestanding image") orelse false;
    const baremetal_framebuffer_probe_banner = b.option(bool, "baremetal-framebuffer-probe-banner", "Enable the bare-metal linear framebuffer probe banner in the freestanding image") orelse false;
    const baremetal_ata_storage_probe = b.option(bool, "baremetal-ata-storage-probe", "Enable the ATA-backed storage validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_probe = b.option(bool, "baremetal-rtl8139-probe", "Enable the RTL8139 Ethernet validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_arp_probe = b.option(bool, "baremetal-rtl8139-arp-probe", "Enable the RTL8139 ARP validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_ipv4_probe = b.option(bool, "baremetal-rtl8139-ipv4-probe", "Enable the RTL8139 IPv4 validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_udp_probe = b.option(bool, "baremetal-rtl8139-udp-probe", "Enable the RTL8139 UDP validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_tcp_probe = b.option(bool, "baremetal-rtl8139-tcp-probe", "Enable the RTL8139 TCP validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_dhcp_probe = b.option(bool, "baremetal-rtl8139-dhcp-probe", "Enable the RTL8139 DHCP validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_dns_probe = b.option(bool, "baremetal-rtl8139-dns-probe", "Enable the RTL8139 DNS validation path in the freestanding image") orelse false;
    const baremetal_rtl8139_gateway_probe = b.option(bool, "baremetal-rtl8139-gateway-probe", "Enable the RTL8139 gateway-routing validation path in the freestanding image") orelse false;
    const baremetal_tool_exec_probe = b.option(bool, "baremetal-tool-exec-probe", "Enable the bare-metal tool execution validation path in the freestanding image") orelse false;
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) {
        // Zig master on Windows currently fails to emit a PDB reliably for this project.
        // Strip debug symbols here so install doesn't attempt to copy a missing .pdb.
        root_module.strip = true;
    }
    if (target.result.os.tag == .linux and target.result.abi.isAndroid() and target.result.cpu.arch == .arm) {
        // armv7 Android currently links with unresolved TLS symbol (__tls_get_addr)
        // under Zig master for this codebase. Single-threaded build avoids TLS runtime linkage.
        root_module.single_threaded = true;
    }

    const exe = b.addExecutable(.{
        .name = "openclaw-zig",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the OpenClaw Zig bootstrap binary");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const baremetal_test_module = b.createModule(.{
        .root_source_file = b.path("src/baremetal_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (target.result.os.tag == .windows) {
        // Work around a Zig master Windows build-runner regression around `--listen`.
        const test_cmd = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "test",
            "src/main.zig",
        });
        test_step.dependOn(&test_cmd.step);
        const baremetal_test_cmd = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "test",
            "src/baremetal_main.zig",
        });
        test_step.dependOn(&baremetal_test_cmd.step);
    } else {
        const tests = b.addTest(.{
            .root_module = root_module,
        });
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
        const baremetal_tests = b.addTest(.{
            .root_module = baremetal_test_module,
        });
        const run_baremetal_tests = b.addRunArtifact(baremetal_tests);
        test_step.dependOn(&run_baremetal_tests.step);
    }

    const baremetal_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    });
    const baremetal_module = b.createModule(.{
        .root_source_file = b.path("src/baremetal_main.zig"),
        .target = baremetal_target,
        .optimize = optimize,
    });
    const baremetal_options = b.addOptions();
    baremetal_options.addOption(bool, "qemu_smoke", baremetal_qemu_smoke);
    baremetal_options.addOption(bool, "console_probe_banner", baremetal_console_probe_banner);
    baremetal_options.addOption(bool, "framebuffer_probe_banner", baremetal_framebuffer_probe_banner);
    baremetal_options.addOption(bool, "ata_storage_probe", baremetal_ata_storage_probe);
    baremetal_options.addOption(bool, "rtl8139_probe", baremetal_rtl8139_probe);
    baremetal_options.addOption(bool, "rtl8139_arp_probe", baremetal_rtl8139_arp_probe);
    baremetal_options.addOption(bool, "rtl8139_ipv4_probe", baremetal_rtl8139_ipv4_probe);
    baremetal_options.addOption(bool, "rtl8139_udp_probe", baremetal_rtl8139_udp_probe);
    baremetal_options.addOption(bool, "rtl8139_tcp_probe", baremetal_rtl8139_tcp_probe);
    baremetal_options.addOption(bool, "rtl8139_dhcp_probe", baremetal_rtl8139_dhcp_probe);
    baremetal_options.addOption(bool, "rtl8139_dns_probe", baremetal_rtl8139_dns_probe);
    baremetal_options.addOption(bool, "rtl8139_gateway_probe", baremetal_rtl8139_gateway_probe);
    baremetal_options.addOption(bool, "tool_exec_probe", baremetal_tool_exec_probe);
    baremetal_module.addOptions("build_options", baremetal_options);
    baremetal_module.single_threaded = true;
    baremetal_module.strip = false;

    const baremetal_exe = b.addExecutable(.{
        .name = "openclaw-zig-baremetal",
        .root_module = baremetal_module,
    });
    // Keep the Multiboot2 header section alive in optimized freestanding builds.
    // Zig master currently garbage-collects the custom `.multiboot` section here
    // unless section GC is disabled at the final bare-metal artifact boundary.
    baremetal_exe.link_gc_sections = false;
    const install_baremetal = b.addInstallArtifact(baremetal_exe, .{
        .dest_sub_path = "openclaw-zig-baremetal.elf",
    });
    const baremetal_step = b.step("baremetal", "Build freestanding bare-metal runtime image");
    baremetal_step.dependOn(&install_baremetal.step);
}
