const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        // Disable NEON/FP to avoid SIMD alignment faults in kernel code.
        // AArch64 SIMD stores require 16-byte alignment, but struct fields
        // and stack locals may only be 8-byte aligned.
        .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .neon, .fp_armv8 }),
    });

    const opts = .{ .target = target, .optimize = optimize };

    // Shared platform modules
    const mmio = b.createModule(.{ .root_source_file = b.path("platform/raspi/mmio.zig"), .target = opts.target, .optimize = opts.optimize });
    const gpio = b.createModule(.{ .root_source_file = b.path("platform/raspi/gpio.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{.{ .name = "mmio", .module = mmio }} });
    const uart = b.createModule(.{ .root_source_file = b.path("platform/raspi/uart.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "mmio", .module = mmio }, .{ .name = "gpio", .module = gpio } } });
    const spi = b.createModule(.{ .root_source_file = b.path("platform/raspi/spi.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "mmio", .module = mmio }, .{ .name = "gpio", .module = gpio } } });
    _ = spi; // Available for real-hardware builds; QEMU uses mock SPI

    // Kernel modules (ordered by dependency)
    const timer = b.createModule(.{ .root_source_file = b.path("kernel/arch/aarch64/timer.zig"), .target = opts.target, .optimize = opts.optimize });
    const frame = b.createModule(.{ .root_source_file = b.path("kernel/src/frame.zig"), .target = opts.target, .optimize = opts.optimize });
    const cap = b.createModule(.{ .root_source_file = b.path("kernel/src/cap.zig"), .target = opts.target, .optimize = opts.optimize });
    const ipc = b.createModule(.{ .root_source_file = b.path("kernel/src/ipc.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{.{ .name = "cap", .module = cap }} });
    const sched = b.createModule(.{ .root_source_file = b.path("kernel/src/sched.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "cap", .module = cap }, .{ .name = "ipc", .module = ipc } } });
    const fault = b.createModule(.{ .root_source_file = b.path("kernel/src/fault.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "ipc", .module = ipc }, .{ .name = "cap", .module = cap }, .{ .name = "sched", .module = sched } } });
    const syscall = b.createModule(.{ .root_source_file = b.path("kernel/src/syscall.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "sched", .module = sched }, .{ .name = "cap", .module = cap }, .{ .name = "uart", .module = uart }, .{ .name = "frame", .module = frame }, .{ .name = "ipc", .module = ipc }, .{ .name = "fault", .module = fault } } });
    const exception = b.createModule(.{ .root_source_file = b.path("kernel/arch/aarch64/exception.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "uart", .module = uart }, .{ .name = "syscall", .module = syscall }, .{ .name = "sched", .module = sched }, .{ .name = "fault", .module = fault } } });

    // ── User-space LibOS + init program ──────────────────────────────

    const libos = b.createModule(.{
        .root_source_file = b.path("libos/lib.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    // E-ink user-space driver modules (mock SPI over UART for QEMU)
    const waveshare = b.createModule(.{ .root_source_file = b.path("user/eink/waveshare.zig"), .target = opts.target, .optimize = opts.optimize });
    const spi_mock = b.createModule(.{ .root_source_file = b.path("user/eink/spi_mock.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{.{ .name = "libos", .module = libos }} });
    const eink_driver = b.createModule(.{ .root_source_file = b.path("user/eink/driver.zig"), .target = opts.target, .optimize = opts.optimize, .imports = &.{ .{ .name = "libos", .module = libos }, .{ .name = "waveshare", .module = waveshare }, .{ .name = "spi_mock", .module = spi_mock } } });

    const user_init_exe = b.addExecutable(.{
        .name = "user_init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/init/main.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{ .{ .name = "libos", .module = libos }, .{ .name = "eink_driver", .module = eink_driver } },
        }),
    });
    user_init_exe.setLinkerScript(b.path("user/linker.ld"));
    user_init_exe.addAssemblyFile(b.path("libos/entry.S"));

    const user_raw = user_init_exe.addObjCopy(.{ .format = .bin });

    // Embed user binary into kernel via generated module
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(user_raw.getOutput(), "user_init.bin");
    const embed_src = wf.add("user_init_embed.zig",
        \\pub const data = @embedFile("user_init.bin");
    );

    const user_embed = b.createModule(.{
        .root_source_file = embed_src,
        .target = opts.target,
        .optimize = opts.optimize,
    });

    // ── Kernel executable ────────────────────────────────────────────

    const kernel = b.addExecutable(.{
        .name = "kernel8",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/main.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "uart", .module = uart },
                .{ .name = "exception", .module = exception },
                .{ .name = "cap", .module = cap },
                .{ .name = "ipc", .module = ipc },
                .{ .name = "sched", .module = sched },
                .{ .name = "timer", .module = timer },
                .{ .name = "frame", .module = frame },
                .{ .name = "user_init", .module = user_embed },
            },
        }),
    });

    kernel.setLinkerScript(b.path("kernel/arch/aarch64/linker.ld"));
    kernel.addAssemblyFile(b.path("kernel/arch/aarch64/boot.S"));
    kernel.addAssemblyFile(b.path("kernel/arch/aarch64/vectors.S"));
    kernel.addAssemblyFile(b.path("kernel/arch/aarch64/context_switch.S"));
    kernel.addAssemblyFile(b.path("kernel/arch/aarch64/user_entry.S"));

    // Output raw binary for QEMU
    const raw = kernel.addObjCopy(.{ .format = .bin });
    const install_raw = b.addInstallBinFile(raw.getOutput(), "kernel8.img");
    b.getInstallStep().dependOn(&install_raw.step);
    b.installArtifact(kernel);

    // Also install user binary for inspection
    const install_user = b.addInstallBinFile(user_raw.getOutput(), "user_init.bin");
    b.getInstallStep().dependOn(&install_user.step);

    // Run in QEMU
    const run_step = b.step("run", "Boot kernel in QEMU raspi3b");
    const run_cmd = b.addSystemCommand(&.{ "qemu-system-aarch64", "-M", "raspi3b", "-kernel" });
    run_cmd.addFileArg(raw.getOutput());
    run_cmd.addArgs(&.{ "-serial", "stdio", "-display", "none", "-no-reboot" });
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);

    // ── Host-target unit tests ───────────────────────────────────────

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

    const host_ipc = b.createModule(.{ .root_source_file = b.path("kernel/src/ipc.zig"), .target = b.graph.host, .imports = &.{.{ .name = "cap", .module = host_cap }} });
    const sched_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/sched.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "cap", .module = host_cap }, .{ .name = "ipc", .module = host_ipc } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(sched_tests).step);

    const frame_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/frame.zig"),
            .target = b.graph.host,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(frame_tests).step);

    const host_sched = b.createModule(.{ .root_source_file = b.path("kernel/src/sched.zig"), .target = b.graph.host, .imports = &.{ .{ .name = "cap", .module = host_cap }, .{ .name = "ipc", .module = host_ipc } } });
    const fault_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/fault.zig"),
            .target = b.graph.host,
            .imports = &.{ .{ .name = "ipc", .module = host_ipc }, .{ .name = "cap", .module = host_cap }, .{ .name = "sched", .module = host_sched } },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(fault_tests).step);

    // ── QEMU integration test ───────────────────────────────────────

    const qemu_test_step = b.step("qemu-test", "Run QEMU integration test (requires qemu-system-aarch64)");
    const qemu_test_cmd = b.addSystemCommand(&.{ "bash", "tests/qemu/run_test.sh" });
    qemu_test_cmd.addFileArg(raw.getOutput());
    qemu_test_cmd.step.dependOn(b.getInstallStep());
    qemu_test_step.dependOn(&qemu_test_cmd.step);
}
