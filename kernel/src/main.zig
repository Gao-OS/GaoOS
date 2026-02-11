// GaoOS kernel entry point
//
// Called from boot.S after core 0 has set up the stack and cleared BSS.

const uart = @import("uart");
const exception = @import("exception");

export fn kernel_main() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    uart.init();
    exception.init();

    uart.puts("GaoOS v0.1\n");

    while (true) {
        asm volatile ("wfe");
    }
}
