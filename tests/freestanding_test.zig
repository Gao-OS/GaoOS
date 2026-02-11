// Minimal freestanding test: verifies Zig can compile for aarch64-freestanding-none.
// This produces a valid binary with no OS dependencies.

export fn _start() callconv(.naked) noreturn {
    // Halt: infinite loop (WFE = wait for event, low-power idle)
    asm volatile (
        \\1: wfe
        \\   b 1b
    );
}
