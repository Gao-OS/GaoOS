const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    const opts = .{ .target = target, .optimize = optimize };

    // Shared platform modules
    const mmio = b.createModule(.{ .root_source_file = b.path("platform/raspi/mmio.zig"), .target = opts.target, .optimize = opts.optimize });
    const gpio = b.createModule(.{ .root_source_file = b.path("platform/raspi/gpio.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{.{ .name = "mmio", .module = mmio }} });
    const uart = b.createModule(.{ .root_source_file = b.path("platform/raspi/uart.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "mmio", .module = mmio }, .{ .name = "gpio", .module = gpio } } });

    // Kernel arch modules
    const exception = b.createModule(.{ .root_source_file = b.path("kernel/arch/aarch64/exception.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{.{ .name = "uart", .module = uart }} });
    const arch_mmu = b.createModule(.{ .root_source_file = b.path("kernel/arch/aarch64/mmu.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{.{ .name = "uart", .module = uart }} });

    // Kernel core modules
    const mmu = b.createModule(.{ .root_source_file = b.path("kernel/src/mmu.zig"), .target = opts.target, .optimize = opts.optimize });
    const cap = b.createModule(.{ .root_source_file = b.path("kernel/src/cap.zig"), .target = opts.target, .optimize = opts.optimize });
    const ipc = b.createModule(.{ .root_source_file = b.path("kernel/src/ipc.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{.{ .name = "cap", .module = cap }} });

    // Kernel executable
    const kernel = b.addExecutable(.{
        .name = "kernel8",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/main.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "uart", .module = uart },
                .{ .name = "exception", .module = exception },
                .{ .name = "arch_mmu", .module = arch_mmu },
                .{ .name = "mmu", .module = mmu },
                .{ .name = "cap", .module = cap },
                .{ .name = "ipc", .module = ipc },
            },
        }),
    });

    kernel.setLinkerScript(b.path("kernel/arch/aarch64/linker.ld"));
    kernel.addAssemblyFile(b.path("kernel/arch/aarch64/boot.S"));
    kernel.addAssemblyFile(b.path("kernel/arch/aarch64/vectors.S"));

    // Output raw binary for QEMU
    const raw = kernel.addObjCopy(.{ .format = .bin });
    const install_raw = b.addInstallBinFile(raw.getOutput(), "kernel8.img");
    b.getInstallStep().dependOn(&install_raw.step);
    b.installArtifact(kernel);

    // Run in QEMU
    const run_step = b.step("run", "Boot kernel in QEMU raspi3b");
    const run_cmd = b.addSystemCommand(&.{ "qemu-system-aarch64", "-M", "raspi3b", "-kernel" });
    run_cmd.addFileArg(raw.getOutput());
    run_cmd.addArgs(&.{ "-serial", "stdio", "-display", "none", "-no-reboot" });
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // Host-target unit tests (cap, mmu data structures, etc.)
    const test_step = b.step("test", "Run kernel unit tests on host");

    const cap_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/cap.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(cap_tests).step);

    const host_cap = b.createModule(.{ .root_source_file = b.path("kernel/src/cap.zig"), .target = b.graph.host });
    const ipc_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/ipc.zig"),
            .target = b.graph.host,
            .imports = &.{.{ .name = "cap", .module = host_cap }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ipc_tests).step);
}
