// GaoOS kernel entry point
//
// Called from boot.S after core 0 has set up the stack and cleared BSS.
// Initializes hardware and halts — Phase 1.1 boot validation.

const uart = @import("uart");

export fn kernel_main() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    uart.init();
    uart.puts("GaoOS v0.1\n");

    // Halt: low-power wait loop
    while (true) {
        asm volatile ("wfe");
    }
}
