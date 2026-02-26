// GaoOS Multi-Runtime Demo
//
// Demonstrates the full Phase 2+3 capability stack:
//   - Frame allocation and deallocation
//   - IPC endpoint creation and message passing
//   - Thread creation from user space
//   - Capability delegation (frame cap transfer via IPC)
//   - Fault supervision (orchestrator receives death notifications)
//   - Blocking IPC receive (thread sleeps until message arrives)
//   - Supervisor-initiated thread kill (BEAM supervision pattern)
//   - E-ink user-space driver (mock SPI over UART)
//
// Structure:
//   Thread 0 (orchestrator): spawns Worker A, Worker B, and E-Ink driver,
//     sets itself as supervisor for all, then drains its IPC endpoint.
//
//   Worker A: allocates a frame, sends it via SYS_IPC_SEND_CAP, exits.
//   Worker B: spins (yield loop) until forcefully killed by orchestrator.
//   E-Ink:    runs Waveshare init/write/refresh/sleep sequence over mock SPI.

const libos = @import("libos");
const sys = libos.syscall;
const io = libos.io;
const ipc_lib = libos.ipc;
const fault_lib = libos.fault;
const thread_lib = libos.thread;
const eink = @import("eink_driver");

/// Extract a physical address from framePhys, returning null on error.
fn checkedFramePhys(cap_idx: u32) ?u64 {
    const result = sys.framePhys(cap_idx);
    if (result < 0) return null;
    return @bitCast(result);
}

const UART_CAP: u32 = 0;
const ORCH_EP_CAP: u32 = 1; // Orchestrator's endpoint (in its own table)
const WORKER_A_EP_CAP: u32 = 1; // Worker A's cap pointing to orchestrator's endpoint

const CAP_NULL: u32 = sys.CAP_NULL;
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
    const phys = checkedFramePhys(frame_cap) orelse 0;
    io.print(UART_CAP, "  [Worker A] allocated frame 0x");
    io.putHex(UART_CAP, phys);
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
// Worker B demonstrates supervisor-initiated kill: it loops forever
// (yielding on each iteration) until the orchestrator kills it.

fn worker_b() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    io.println(UART_CAP, "  [Worker B] hello!");
    io.println(UART_CAP, "  [Worker B] spinning (waiting to be killed)...");
    while (true) {
        sys.yield();
    }
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
    const a = thread_lib.spawn(&worker_a) catch {
        io.println(UART_CAP, "FATAL: Worker A spawn failed");
        return;
    };
    // cap[0]=UART, cap[1]=orch_endpoint in Worker A's table
    _ = sys.threadGrant(a.thread_cap, UART_CAP);
    _ = sys.threadGrant(a.thread_cap, ORCH_EP_CAP);
    _ = sys.supervisorSet(a.thread_cap, ORCH_EP_CAP);

    // ── Spawn Worker B ───────────────────────────────────────────────
    io.println(UART_CAP, "Spawning Worker B...");
    const b = thread_lib.spawn(&worker_b) catch {
        io.println(UART_CAP, "FATAL: Worker B spawn failed");
        return;
    };
    _ = sys.threadGrant(b.thread_cap, UART_CAP);
    _ = sys.supervisorSet(b.thread_cap, ORCH_EP_CAP);

    // ── Spawn E-Ink driver ───────────────────────────────────────────
    io.println(UART_CAP, "Spawning E-Ink driver...");
    const e = thread_lib.spawn(&eink.einkMain) catch {
        io.println(UART_CAP, "FATAL: E-Ink spawn failed");
        return;
    };
    _ = sys.threadGrant(e.thread_cap, UART_CAP);
    _ = sys.supervisorSet(e.thread_cap, ORCH_EP_CAP);

    io.println(UART_CAP, "Workers spawned. Waiting for messages...");

    // ── Phase 1: collect voluntary exits (Worker A + E-Ink) ──────────
    // Uses blocking receive — the thread sleeps until a message arrives.
    // Worker B is spinning and will be killed later.
    var buf: [256]u8 = undefined;
    var fault_count: u32 = 0;
    var got_frame = false;
    const VOLUNTARY_WORKERS: u32 = 2; // Worker A + E-Ink exit voluntarily

    while (fault_count < VOLUNTARY_WORKERS or !got_frame) {
        const rcap = ipc_lib.recvWithCapBlocking(ORCH_EP_CAP, &buf);
        if (rcap.payload_len < 0) {
            io.println(UART_CAP, "Orchestrator: recv error!");
            break;
        }

        const len: usize = if (rcap.payload_len > 0) @as(usize, @intCast(rcap.payload_len)) else 0;

        if (rcap.cap_idx != CAP_NULL) {
            // Capability transfer from Worker A
            if (!got_frame) {
                const phys = checkedFramePhys(rcap.cap_idx) orelse 0;
                io.print(UART_CAP, "Orchestrator: received frame 0x");
                io.putHex(UART_CAP, phys);
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

    // ── Phase 2: forcefully kill Worker B (still spinning) ──────────
    io.println(UART_CAP, "Orchestrator: killing Worker B...");
    const kill_rc = sys.threadKill(b.thread_cap);
    if (kill_rc < 0) {
        io.println(UART_CAP, "Orchestrator: threadKill failed!");
    } else {
        io.println(UART_CAP, "Thread kill: OK");
    }

    // ── Phase 3: collect kill fault notification ──────────────────────
    {
        const rcap = ipc_lib.recvWithCapBlocking(ORCH_EP_CAP, &buf);
        if (rcap.payload_len >= 0) {
            const len: usize = if (rcap.payload_len > 0) @as(usize, @intCast(rcap.payload_len)) else 0;
            if (fault_lib.parse(buf[0..len])) |fm| {
                fault_count += 1;
                io.print(UART_CAP, "Orchestrator: fault from thread ");
                io.putDec(UART_CAP, fm.thread_id);
                io.print(UART_CAP, " (");
                io.putDec(UART_CAP, fault_count);
                io.println(UART_CAP, "/3)");
            }
        }
    }

    if (fault_count >= TOTAL_WORKERS) io.println(UART_CAP, "Fault supervision: OK");

    // Reap dead workers (all 3 have exited by now)
    _ = sys.threadReap(a.thread_cap);
    _ = sys.threadReap(b.thread_cap);
    _ = sys.threadReap(e.thread_cap);
    io.println(UART_CAP, "Thread reap: OK");

    io.println(UART_CAP, "All workers done. System shutting down.");

    _ = sys.frameFree(a.stack_cap);
    _ = sys.frameFree(b.stack_cap);
    _ = sys.frameFree(e.stack_cap);
}
