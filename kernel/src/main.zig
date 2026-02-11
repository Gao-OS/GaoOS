// GaoOS kernel entry point
//
// Called from boot.S after core 0 has set up the stack and cleared BSS.

const uart = @import("uart");
const exception = @import("exception");
const arch_mmu = @import("arch_mmu");

export fn kernel_main() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    uart.init();
    uart.puts("GaoOS v0.1\n");

    exception.init();

    // Initialize MMU: enable with identity mapping (VA=PA)
    // We don't set up page tables yet — just enable the caches and
    // configure the MMU to allow physical-address access.
    uart.puts("Enabling MMU...\n");
    arch_mmu.initMAIR();
    arch_mmu.initTCR();

    // For Phase 1, we use identity mapping: set both TTBR0 and TTBR1 to
    // point to a simple identity table. Since we don't have dynamic
    // allocation yet, we skip actual table setup and let QEMU/hardware
    // handle the default behavior (which allows PA=VA for unfaulted accesses).
    // In a real system, we'd create proper page tables.

    // Note: MMU enable is deferred until Phase 1.4 when we have proper page tables.
    // For now, we just initialize the control registers and halt.
    // arch_mmu.enable();
    // arch_mmu.tlbiAll();

    uart.puts("MMU configured (not yet enabled).\n");
    uart.puts("Phase 1.3 complete!\n");

    while (true) {
        asm volatile ("wfe");
    }
}
