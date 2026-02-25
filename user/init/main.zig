// First Zig user-space program for GaoOS
//
// Demonstrates: UART output via capability, frame allocation, formatted I/O.
// The kernel grants cap[0] = device(UART, write) before entering EL0.

const libos = @import("libos");
const sys = libos.syscall;
const io = libos.io;

const UART_CAP: u32 = 0;

export fn user_main() void {
    io.println(UART_CAP, "Hello from GaoOS user space!");

    // Allocate a physical frame
    const frame_result = sys.frameAlloc();
    if (frame_result >= 0) {
        const cap_idx: u32 = @intCast(frame_result);

        // Query its physical address
        const phys_result = sys.framePhys(cap_idx);
        if (phys_result >= 0) {
            io.print(UART_CAP, "  Allocated frame at 0x");
            io.putHex(UART_CAP, @bitCast(phys_result));
            io.print(UART_CAP, "\n");
        }

        // Free the frame
        _ = sys.frameFree(cap_idx);
        io.println(UART_CAP, "  Frame freed.");
    } else {
        io.println(UART_CAP, "  Frame alloc failed!");
    }

    io.println(UART_CAP, "Exiting.");
}
