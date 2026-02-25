// First Zig user-space program for GaoOS
//
// Demonstrates: UART output, frame allocation, IPC, thread creation.
// The kernel grants cap[0] = device(UART, write+grant) before entering EL0.

const libos = @import("libos");
const sys = libos.syscall;
const io = libos.io;
const ipc = libos.ipc;

const UART_CAP: u32 = 0;

export fn user_main() void {
    io.println(UART_CAP, "Hello from GaoOS user space!");

    // ── Frame allocation demo ───────────────────────────────────
    const frame_result = sys.frameAlloc();
    if (frame_result >= 0) {
        const cap_idx: u32 = @intCast(frame_result);
        const phys_result = sys.framePhys(cap_idx);
        if (phys_result >= 0) {
            io.print(UART_CAP, "  Allocated frame at 0x");
            io.putHex(UART_CAP, @bitCast(phys_result));
            io.print(UART_CAP, "\n");
        }
        _ = sys.frameFree(cap_idx);
        io.println(UART_CAP, "  Frame freed.");
    } else {
        io.println(UART_CAP, "  Frame alloc failed!");
    }

    // ── IPC demo ────────────────────────────────────────────────
    io.println(UART_CAP, "IPC test:");

    const ep_result = ipc.createEndpoint();
    if (ep_result < 0) {
        io.println(UART_CAP, "  EP create failed!");
        io.println(UART_CAP, "Exiting.");
        return;
    }
    const ep_cap: u32 = @intCast(ep_result);
    io.print(UART_CAP, "  Created endpoint cap=");
    io.putDec(UART_CAP, ep_cap);
    io.print(UART_CAP, "\n");

    const msg = "ping";
    const send_rc = ipc.sendTagged(ep_cap, 42, msg);
    if (send_rc < 0) {
        io.println(UART_CAP, "  Send failed!");
    } else {
        io.println(UART_CAP, "  Sent tagged message (tag=42)");
    }

    var buf: [256]u8 = undefined;
    const recv_res = ipc.recvTagged(ep_cap, 42, &buf);
    if (recv_res.payload_len >= 0) {
        io.print(UART_CAP, "  Received ");
        io.putDec(UART_CAP, @intCast(@as(u64, @bitCast(recv_res.payload_len))));
        io.print(UART_CAP, " bytes, tag=");
        io.putDec(UART_CAP, @intCast(recv_res.tag));
        io.print(UART_CAP, "\n");
    } else {
        io.println(UART_CAP, "  Recv failed!");
    }

    // ── Thread creation demo ────────────────────────────────────
    io.println(UART_CAP, "Thread test:");

    // Allocate a stack frame for the child
    const stack_frame = sys.frameAlloc();
    if (stack_frame < 0) {
        io.println(UART_CAP, "  Stack alloc failed!");
        io.println(UART_CAP, "Exiting.");
        return;
    }
    const stack_cap: u32 = @intCast(stack_frame);
    const stack_phys = sys.framePhys(stack_cap);
    if (stack_phys < 0) {
        io.println(UART_CAP, "  Stack phys failed!");
        io.println(UART_CAP, "Exiting.");
        return;
    }

    // Stack grows down — point to top of the 4K frame
    const child_sp: u64 = @as(u64, @bitCast(stack_phys)) + 4096;
    const child_entry: u64 = @intFromPtr(&child_thread);

    const thread_result = sys.threadCreate(child_entry, child_sp);
    if (thread_result < 0) {
        io.println(UART_CAP, "  Thread create failed!");
    } else {
        const thread_cap: u32 = @intCast(thread_result);
        io.print(UART_CAP, "  Created thread cap=");
        io.putDec(UART_CAP, thread_cap);
        io.print(UART_CAP, "\n");

        // Grant the UART cap to the child so it can print
        const grant_rc = sys.threadGrant(thread_cap, UART_CAP);
        if (grant_rc < 0) {
            io.println(UART_CAP, "  Grant UART failed!");
        } else {
            io.println(UART_CAP, "  Granted UART to child");
        }

        // Yield to let child run
        sys.yield();

        io.println(UART_CAP, "  [parent] Resumed after yield");
    }

    io.println(UART_CAP, "Exiting.");
}

fn child_thread() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    // Child has UART cap at slot 0 (granted by parent)
    io.println(0, "  [child] Hello from child thread!");
    sys.exit();
}
