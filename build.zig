const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
    });

    // Kernel executable
    const kernel = b.addExecutable(.{
        .name = "kernel8",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/main.zig"),
            .target = target,
            .optimize = optimize,
            // Platform drivers available as imports
            .imports = &.{
                .{ .name = "uart", .module = b.createModule(.{
                    .root_source_file = b.path("platform/raspi/uart.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "mmio", .module = b.createModule(.{
                            .root_source_file = b.path("platform/raspi/mmio.zig"),
                            .target = target,
                            .optimize = optimize,
                        }) },
                        .{ .name = "gpio", .module = b.createModule(.{
                            .root_source_file = b.path("platform/raspi/gpio.zig"),
                            .target = target,
                            .optimize = optimize,
                            .imports = &.{
                                .{ .name = "mmio", .module = b.createModule(.{
                                    .root_source_file = b.path("platform/raspi/mmio.zig"),
                                    .target = target,
                                    .optimize = optimize,
                                }) },
                            },
                        }) },
                    },
                }) },
            },
        }),
    });

    // Use custom linker script
    kernel.setLinkerScript(b.path("kernel/arch/aarch64/linker.ld"));

    // Add assembly boot stub
    kernel.addAssemblyFile(b.path("kernel/arch/aarch64/boot.S"));

    // Output raw binary (kernel8.img) for QEMU -kernel flag
    const raw = kernel.addObjCopy(.{
        .format = .bin,
    });
    const install_raw = b.addInstallBinFile(raw.getOutput(), "kernel8.img");
    b.getInstallStep().dependOn(&install_raw.step);

    // Also install ELF for debugging
    b.installArtifact(kernel);

    // Run in QEMU
    const run_step = b.step("run", "Boot kernel in QEMU raspi3b");
    const run_cmd = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-M",
        "raspi3b",
        "-kernel",
    });
    run_cmd.addFileArg(raw.getOutput());
    run_cmd.addArgs(&.{
        "-serial",
        "stdio",
        "-display",
        "none",
        "-no-reboot",
    });
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
}
