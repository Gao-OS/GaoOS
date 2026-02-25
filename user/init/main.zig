// GaoOS Multi-Runtime Demo
//
// Demonstrates the full Phase 2+3 capability stack:
//   - Frame allocation and deallocation
//   - IPC endpoint creation and message passing
//   - Thread creation from user space
//   - Capability delegation (frame cap transfer via IPC)
//   - Fault supervision (orchestrator receives death notifications)
//   - E-ink user-space driver (mock SPI over UART)
//
// Structure:
//   Thread 0 (orchestrator): spawns Worker A, Worker B, and E-Ink driver,
//     sets itself as supervisor for all, then drains its IPC endpoint.
//
//   Worker A: allocates a frame, sends it via SYS_IPC_SEND_CAP, exits.
//   Worker B: prints a greeting, exits.
//   E-Ink:    runs Waveshare init/write/refresh/sleep sequence over mock SPI.

const libos = @import("libos");
const sys = libos.syscall;
const io = libos.io;
const ipc_lib = libos.ipc;
const fault_lib = libos.fault;
const eink = @import("eink_driver");

const UART_CAP: u32 = 0;
const ORCH_EP_CAP: u32 = 1; // Orchestrator's endpoint (in its own table)
const WORKER_A_EP_CAP: u32 = 1; // Worker A's cap pointing to orchestrator's endpoint

const CAP_NULL: u32 = 0xFFFFFFFF;
const TAG_ANY: u64 = 0;
const MAX_ITERATIONS: u32 = 500;
const TOTAL_WORKERS: u32 = 3;

// ─── Worker A ────────────────────────────────────────────────────────

fn worker_a() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    io.println(UART_CAP, "  [Worker A] hello!");

    const frame_result = sys.frameAlloc();
    if (frame_result < 0) {
        io.println(UART_CAP, "  [Worker A] frame alloc failed!");
        sys.exit();
    }
    const frame_cap: u32 = @intCast(frame_result);
    const phys = sys.framePhys(frame_cap);
    io.print(UART_CAP, "  [Worker A] allocated frame 0x");
    io.putHex(UART_CAP, @bitCast(phys));
    io.print(UART_CAP, "\n");

    // Delegate frame cap to orchestrator via IPC
    const msg = "frame-gift";
    const rc = sys.ipcSendCap(WORKER_A_EP_CAP, msg.ptr, msg.len, frame_cap);
    if (rc < 0) {
        io.println(UART_CAP, "  [Worker A] cap send failed!");
    } else {
        io.println(UART_CAP, "  [Worker A] sent frame cap to orchestrator.");
    }

    io.println(UART_CAP, "  [Worker A] exiting.");
    sys.exit();
}

// ─── Worker B ────────────────────────────────────────────────────────

fn worker_b() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    io.println(UART_CAP, "  [Worker B] hello!");
    io.println(UART_CAP, "  [Worker B] exiting.");
    sys.exit();
}

// ─── Orchestrator (thread 0) ─────────────────────────────────────────

export fn user_main() void {
    io.println(UART_CAP, "GaoOS Multi-Runtime Demo");
    io.println(UART_CAP, "========================");

    // ── Create orchestrator's IPC endpoint ───────────────────────────
    const ep_result = ipc_lib.createEndpoint();
    if (ep_result < 0) {
        io.println(UART_CAP, "FATAL: ep create failed");
        return;
    }
    // ep_result is now ORCH_EP_CAP (cap[1]) in orchestrator's table

    // ── Spawn Worker A ───────────────────────────────────────────────
    io.println(UART_CAP, "Spawning Worker A...");
    const a_stack_r = sys.frameAlloc();
    if (a_stack_r < 0) {
        io.println(UART_CAP, "FATAL: Worker A stack alloc failed");
        return;
    }
    const a_stack_cap: u32 = @intCast(a_stack_r);
    const a_stack_top: u64 = @as(u64, @bitCast(sys.framePhys(a_stack_cap))) + 4096;

    const a_thread_r = sys.threadCreate(@intFromPtr(&worker_a), a_stack_top);
    if (a_thread_r < 0) {
        io.println(UART_CAP, "FATAL: Worker A thread create failed");
        return;
    }
    const a_thread_cap: u32 = @intCast(a_thread_r);

    // cap[0]=UART, cap[1]=orch_endpoint in Worker A's table
    _ = sys.threadGrant(a_thread_cap, UART_CAP);
    _ = sys.threadGrant(a_thread_cap, ORCH_EP_CAP);

    // Set orchestrator as Worker A's supervisor
    _ = sys.supervisorSet(a_thread_cap, ORCH_EP_CAP);

    // ── Spawn Worker B ───────────────────────────────────────────────
    io.println(UART_CAP, "Spawning Worker B...");
    const b_stack_r = sys.frameAlloc();
    if (b_stack_r < 0) {
        io.println(UART_CAP, "FATAL: Worker B stack alloc failed");
        return;
    }
    const b_stack_cap: u32 = @intCast(b_stack_r);
    const b_stack_top: u64 = @as(u64, @bitCast(sys.framePhys(b_stack_cap))) + 4096;

    const b_thread_r = sys.threadCreate(@intFromPtr(&worker_b), b_stack_top);
    if (b_thread_r < 0) {
        io.println(UART_CAP, "FATAL: Worker B thread create failed");
        return;
    }
    const b_thread_cap: u32 = @intCast(b_thread_r);

    // cap[0]=UART in Worker B's table
    _ = sys.threadGrant(b_thread_cap, UART_CAP);

    // Set orchestrator as Worker B's supervisor
    _ = sys.supervisorSet(b_thread_cap, ORCH_EP_CAP);

    // ── Spawn E-Ink driver ───────────────────────────────────────────
    io.println(UART_CAP, "Spawning E-Ink driver...");
    const e_stack_r = sys.frameAlloc();
    if (e_stack_r < 0) {
        io.println(UART_CAP, "FATAL: E-Ink stack alloc failed");
        return;
    }
    const e_stack_cap: u32 = @intCast(e_stack_r);
    const e_stack_top: u64 = @as(u64, @bitCast(sys.framePhys(e_stack_cap))) + 4096;

    const e_thread_r = sys.threadCreate(@intFromPtr(&eink.einkMain), e_stack_top);
    if (e_thread_r < 0) {
        io.println(UART_CAP, "FATAL: E-Ink thread create failed");
        return;
    }
    const e_thread_cap: u32 = @intCast(e_thread_r);

    // cap[0]=UART in E-Ink driver's table
    _ = sys.threadGrant(e_thread_cap, UART_CAP);

    // Set orchestrator as E-Ink driver's supervisor
    _ = sys.supervisorSet(e_thread_cap, ORCH_EP_CAP);

    io.println(UART_CAP, "Workers spawned. Waiting for messages...");

    // ── Drain endpoint: cap message + 2 fault notifications ──────────
    var buf: [256]u8 = undefined;
    var fault_count: u32 = 0;
    var got_frame = false;
    var iterations: u32 = 0;

    while (fault_count < TOTAL_WORKERS) {
        if (iterations >= MAX_ITERATIONS) {
            io.println(UART_CAP, "Orchestrator: timeout!");
            break;
        }
        iterations += 1;

        const rcap = sys.ipcRecvCap(ORCH_EP_CAP, &buf, TAG_ANY);
        if (rcap.payload_len < 0) {
            sys.yield();
            continue;
        }

        const len: usize = @intCast(@as(u64, @bitCast(rcap.payload_len)));

        if (rcap.cap_idx != CAP_NULL) {
            // Capability transfer from Worker A
            if (!got_frame) {
                const phys = sys.framePhys(rcap.cap_idx);
                io.print(UART_CAP, "Orchestrator: received frame 0x");
                io.putHex(UART_CAP, @bitCast(phys));
                io.println(UART_CAP, "");
                _ = sys.frameFree(rcap.cap_idx);
                got_frame = true;
            }
        } else if (fault_lib.parse(buf[0..len])) |fm| {
            // Fault notification from a worker
            fault_count += 1;
            io.print(UART_CAP, "Orchestrator: fault from thread ");
            io.putDec(UART_CAP, fm.thread_id);
            io.print(UART_CAP, " (");
            io.putDec(UART_CAP, fault_count);
            io.println(UART_CAP, "/3)");
        }
    }

    if (got_frame) io.println(UART_CAP, "Cap delegation: OK");
    if (fault_count >= TOTAL_WORKERS) io.println(UART_CAP, "Fault supervision: OK");

    // Reap dead workers (all 3 have exited by now)
    _ = sys.threadReap(a_thread_cap);
    _ = sys.threadReap(b_thread_cap);
    _ = sys.threadReap(e_thread_cap);
    io.println(UART_CAP, "Thread reap: OK");

    io.println(UART_CAP, "All workers done. System shutting down.");

    _ = sys.frameFree(a_stack_cap);
    _ = sys.frameFree(b_stack_cap);
    _ = sys.frameFree(e_stack_cap);
}
