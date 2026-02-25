// Syscall Dispatcher
//
// Routes SVC calls from user space (EL0) to kernel services.
// Every syscall is gated by capabilities — no capability, no access.
//
// Convention (matches Linux arm64 for familiarity):
//   x8  = syscall number
//   x0-x5 = arguments
//   x0  = return value (0 = success, negative = error)
//
// Frame layout from vectors.S (indices into [*]u64):
//   frame[31] = x0,  frame[32] = x1
//   frame[0]  = x2,  frame[1]  = x3
//   frame[2]  = x4,  frame[3]  = x5
//   frame[6]  = x8  (syscall number)

const builtin = @import("builtin");
const is_test = builtin.is_test;

const sched = @import("sched");
const cap = @import("cap");
const uart = @import("uart");
const frame_mod = @import("frame");
const ipc = @import("ipc");
const fault_mod = @import("fault");

// ─── Syscall Numbers ───────────────────────────────────────────────

pub const SYS_WRITE = 0;
pub const SYS_EXIT = 1;
pub const SYS_YIELD = 2;
pub const SYS_CAP_READ = 3;
pub const SYS_FRAME_ALLOC = 4;
pub const SYS_FRAME_FREE = 5;
pub const SYS_CAP_DERIVE = 6;
pub const SYS_CAP_DELETE = 7;
pub const SYS_FRAME_PHYS = 8;
pub const SYS_IPC_SEND = 9;
pub const SYS_IPC_RECV = 10;
pub const SYS_EP_CREATE = 11;
pub const SYS_THREAD_CREATE = 12;
pub const SYS_THREAD_GRANT = 13;
pub const SYS_IPC_SEND_WITH_TAG = 14;
pub const SYS_EP_GRANT = 15;
pub const SYS_SUPERVISOR_SET = 16;
pub const SYS_IPC_SEND_CAP = 17;
pub const SYS_IPC_RECV_CAP = 18;
pub const SYS_THREAD_REAP = 19;
pub const SYS_THREAD_KILL = 20;
pub const SYS_IPC_RECV_BLOCK = 21;
pub const SYS_IPC_RECV_CAP_BLOCK = 22;

// ─── Error codes (returned in x0) ──────────────────────────────────

const E_OK: u64 = 0;
const E_BADCAP: u64 = @bitCast(@as(i64, -1));
const E_BADARG: u64 = @bitCast(@as(i64, -2));
const E_BADSYS: u64 = @bitCast(@as(i64, -3));
const E_NOMEM: u64 = @bitCast(@as(i64, -4));
const E_FULL: u64 = @bitCast(@as(i64, -5));
const E_CLOSED: u64 = @bitCast(@as(i64, -6));
const E_AGAIN: u64 = @bitCast(@as(i64, -7));

// ─── User pointer validation ─────────────────────────────────────
//
// Identity-mapped user-space range: blocks 1-31 (0x200000 to 0x3FFFFFF).
// Any pointer from user space must fall within this range. The kernel
// resides in block 0 (0x80000+) which is EL1-only — accepting a kernel
// address would let user space read/write arbitrary kernel memory.

const USER_MEM_START: u64 = 0x200000;
const USER_MEM_END: u64 = 0x3FFFFFF;

/// Safely convert a capability object field to a ThreadId.
/// Returns null if the value is out of range, preventing @intCast panics
/// and ensuring the ID is within the thread/endpoint table bounds.
fn capObjectToId(object: usize) ?sched.ThreadId {
    if (object >= sched.MAX_THREADS) return null;
    return @intCast(object);
}

fn isValidUserRange(ptr: u64, len: u64) bool {
    if (len == 0) return true;
    if (ptr < USER_MEM_START) return false;
    // Check for overflow and range
    const end = @addWithOverflow(ptr, len - 1);
    if (end[1] != 0) return false; // overflow
    return end[0] <= USER_MEM_END;
}

// ─── Dispatch ──────────────────────────────────────────────────────

pub fn dispatch(thread_id: sched.ThreadId, frame: [*]u64) void {
    const syscall_num = frame[6]; // x8
    const arg0 = frame[31]; // x0
    const arg1 = frame[32]; // x1
    const arg2 = frame[0]; // x2
    const arg3 = frame[1]; // x3

    const result: u64 = switch (syscall_num) {
        SYS_WRITE => sysWrite(thread_id, @truncate(arg0), arg1, arg2),
        SYS_EXIT => sysExit(thread_id),
        SYS_YIELD => sysYield(),
        SYS_CAP_READ => sysCapRead(thread_id, @truncate(arg0)),
        SYS_FRAME_ALLOC => sysFrameAlloc(thread_id),
        SYS_FRAME_FREE => sysFrameFree(thread_id, @truncate(arg0)),
        SYS_CAP_DERIVE => sysCapDerive(thread_id, @truncate(arg0), @truncate(arg1)),
        SYS_CAP_DELETE => sysCapDelete(thread_id, @truncate(arg0)),
        SYS_FRAME_PHYS => sysFramePhys(thread_id, @truncate(arg0)),
        SYS_IPC_SEND => sysIpcSend(thread_id, @truncate(arg0), arg1, arg2, 0),
        SYS_IPC_RECV => sysIpcRecv(thread_id, frame, @truncate(arg0), arg1, arg2),
        SYS_EP_CREATE => sysEpCreate(thread_id),
        SYS_THREAD_CREATE => sysThreadCreate(thread_id, arg0, arg1),
        SYS_THREAD_GRANT => sysThreadGrant(thread_id, @truncate(arg0), @truncate(arg1)),
        SYS_IPC_SEND_WITH_TAG => sysIpcSend(thread_id, @truncate(arg0), arg1, arg2, arg3),
        SYS_EP_GRANT => sysEpGrant(thread_id, @truncate(arg0), @truncate(arg1)),
        SYS_SUPERVISOR_SET => sysSupervisorSet(thread_id, @truncate(arg0), @truncate(arg1)),
        SYS_IPC_SEND_CAP => sysIpcSendCap(thread_id, @truncate(arg0), arg1, arg2, @truncate(arg3)),
        SYS_IPC_RECV_CAP => sysIpcRecvCap(thread_id, frame, @truncate(arg0), arg1, arg2),
        SYS_THREAD_REAP => sysThreadReap(thread_id, @truncate(arg0)),
        SYS_THREAD_KILL => sysThreadKill(thread_id, @truncate(arg0)),
        SYS_IPC_RECV_BLOCK => sysIpcRecvBlock(thread_id, frame, @truncate(arg0), arg1, arg2),
        SYS_IPC_RECV_CAP_BLOCK => sysIpcRecvCapBlock(thread_id, frame, @truncate(arg0), arg1, arg2),
        else => E_BADSYS,
    };

    // Write return value back to x0 in the exception frame.
    // (sysIpcRecv, sysIpcRecvCap, and sysIpcRecvBlock write their return values directly to frame)
    if (syscall_num != SYS_IPC_RECV and syscall_num != SYS_IPC_RECV_CAP and syscall_num != SYS_IPC_RECV_BLOCK and syscall_num != SYS_IPC_RECV_CAP_BLOCK) {
        frame[31] = result;
    }

    if (syscall_num == SYS_EXIT) {
        frame[29] = platform.idleLoopAddr();
        frame[30] = 0x3c5; // SPSR = EL1h, DAIF masked
    }
}

// ─── Platform-specific symbols ──────────────────────────────────────
// These are only available on aarch64. Host-target tests use stubs.

// ─── Platform-specific symbols (aarch64 only) ──────────────────────
// Host-target tests never enter user space, so these are stubbed.

const platform = if (is_test) struct {
    // Stubs for host testing — never actually called/entered
    var idle_loop_stub: u8 = 0;
    fn idleLoopAddr() usize { return @intFromPtr(&idle_loop_stub); }
    fn trampolineAddr() u64 { return 0; }
} else struct {
    // Real symbols linked from assembly files
    export fn idle_loop() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
        uart.puts("Returning to kernel idle loop.\n");
        while (true) {
            asm volatile ("wfe");
        }
    }
    extern const thread_entry_trampoline: u8;
    fn idleLoopAddr() usize { return @intFromPtr(&idle_loop); }
    fn trampolineAddr() u64 { return @intFromPtr(&thread_entry_trampoline); }
};

// ─── Phase 1 syscalls ────────────────────────────────────────────────

fn sysWrite(thread_id: sched.ThreadId, cap_idx: cap.CapIndex, buf_ptr: u64, buf_len: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const c = table.lookup(cap_idx) orelse return E_BADCAP;
    if (c.cap_type != .device) return E_BADCAP;
    if (!c.rights.write) return E_BADCAP;

    if (buf_len == 0) return E_OK;
    const len: usize = @intCast(@min(buf_len, 4096));
    if (!isValidUserRange(buf_ptr, len)) return E_BADARG;

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);

    for (buf[0..len]) |byte| {
        uart.putc(byte);
    }
    return len;
}

fn sysExit(thread_id: sched.ThreadId) u64 {
    fault_mod.notify(thread_id, .exit, 0, 0);
    uart.puts("[kernel] thread ");
    putDec(thread_id);
    uart.puts(" exited via syscall\n");
    sched.global.kill(thread_id);
    return E_OK;
}

fn sysYield() u64 {
    return E_OK;
}

fn sysCapRead(thread_id: sched.ThreadId, cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const c = table.lookup(cap_idx) orelse return E_BADCAP;
    return @intFromEnum(c.cap_type);
}

// ─── Phase 2 memory syscalls ─────────────────────────────────────────

fn sysFrameAlloc(thread_id: sched.ThreadId) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const paddr = frame_mod.global.alloc() catch return E_NOMEM;

    // Frame creator gets ALL rights (including grant) so it can delegate the frame via IPC.
    const cap_idx = table.create(.frame, @intCast(paddr), cap.Rights.ALL) catch {
        frame_mod.global.free(paddr) catch {};
        return E_FULL;
    };
    return @as(u64, cap_idx);
}

fn sysFrameFree(thread_id: sched.ThreadId, cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const c = table.lookup(cap_idx) orelse return E_BADCAP;
    if (c.cap_type != .frame) return E_BADCAP;

    frame_mod.global.free(@intCast(c.object)) catch return E_BADCAP;
    table.delete(cap_idx);
    return E_OK;
}

fn sysCapDerive(thread_id: sched.ThreadId, src_cap_idx: cap.CapIndex, new_rights_raw: u8) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const new_rights: cap.Rights = @bitCast(new_rights_raw);

    const new_idx = table.derive(src_cap_idx, new_rights) catch |err| {
        return switch (err) {
            error.InvalidCapability => E_BADCAP,
            error.RightsEscalation => E_BADCAP,
            error.TableFull => E_FULL,
        };
    };
    return @as(u64, new_idx);
}

fn sysCapDelete(thread_id: sched.ThreadId, cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    if (table.lookup(cap_idx) == null) return E_BADCAP;
    table.delete(cap_idx);
    return E_OK;
}

fn sysFramePhys(thread_id: sched.ThreadId, cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const c = table.lookup(cap_idx) orelse return E_BADCAP;
    if (c.cap_type != .frame) return E_BADCAP;
    if (!c.rights.read) return E_BADCAP;
    return @intCast(c.object);
}

// ─── IPC syscalls (M2.4) ────────────────────────────────────────────

fn sysIpcSend(thread_id: sched.ThreadId, ep_cap_idx: cap.CapIndex, msg_ptr: u64, msg_len: u64, tag: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const c = table.lookup(ep_cap_idx) orelse return E_BADCAP;
    if (c.cap_type != .ipc_endpoint) return E_BADCAP;
    if (!c.rights.write) return E_BADCAP;

    const ep_idx = capObjectToId(c.object) orelse return E_BADCAP;
    const ep = sched.getEndpoint(ep_idx) orelse return E_BADCAP;

    const len: u32 = @intCast(@min(msg_len, ipc.MAX_PAYLOAD));
    if (len > 0 and !isValidUserRange(msg_ptr, len)) return E_BADARG;

    var msg = ipc.Message{ .tag = tag, .payload_len = len };

    if (msg_ptr != 0 and len > 0) {
        const src: [*]const u8 = @ptrFromInt(msg_ptr);
        @memcpy(msg.payload[0..len], src[0..len]);
    }

    ep.send(msg, null, null) catch |err| {
        return switch (err) {
            error.QueueFull => E_FULL,
            error.EndpointClosed => E_CLOSED,
            error.InvalidCapability => E_BADCAP,
            error.TableFull => E_FULL,
        };
    };

    // Wake any thread blocked on recv for this endpoint
    sched.global.wakeBlockedRecv(ep_idx);

    return E_OK;
}

fn sysIpcRecv(thread_id: sched.ThreadId, frame: [*]u64, ep_cap_idx: cap.CapIndex, buf_ptr: u64, tag_filter: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const c = table.lookup(ep_cap_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    if (c.cap_type != .ipc_endpoint) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }
    if (!c.rights.read) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }

    const ep_idx = capObjectToId(c.object) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const ep = sched.getEndpoint(ep_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };

    // Validate user buffer before consuming message (avoid losing messages on bad ptr)
    if (buf_ptr != 0 and !isValidUserRange(buf_ptr, ipc.MAX_PAYLOAD)) {
        frame[31] = E_BADARG;
        return E_BADARG;
    }

    const msg = ep.recv(tag_filter) orelse {
        frame[31] = E_AGAIN;
        return E_AGAIN;
    };

    // Copy payload to user buffer
    if (buf_ptr != 0 and msg.payload_len > 0) {
        const dst: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(dst[0..msg.payload_len], msg.payload[0..msg.payload_len]);
    }

    // Return: x0 = payload length, x1 = tag
    frame[31] = @as(u64, msg.payload_len);
    frame[32] = msg.tag;
    return @as(u64, msg.payload_len);
}

fn sysIpcRecvBlock(thread_id: sched.ThreadId, frame: [*]u64, ep_cap_idx: cap.CapIndex, buf_ptr: u64, tag_filter: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const c = table.lookup(ep_cap_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    if (c.cap_type != .ipc_endpoint) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }
    if (!c.rights.read) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }

    const ep_idx = capObjectToId(c.object) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const ep = sched.getEndpoint(ep_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };

    // Validate user buffer before consuming message
    if (buf_ptr != 0 and !isValidUserRange(buf_ptr, ipc.MAX_PAYLOAD)) {
        frame[31] = E_BADARG;
        return E_BADARG;
    }

    const msg = ep.recv(tag_filter) orelse {
        // Closed endpoint with no pending messages — return E_CLOSED
        // so the caller doesn't block forever waiting for a dead sender.
        if (ep.closed) {
            frame[31] = E_CLOSED;
            return E_CLOSED;
        }
        // No message available — block the calling thread.
        // The exception handler will reschedule. When a send to this
        // endpoint later unblocks us, user space retries the recv.
        const thread = sched.global.getThread(thread_id) orelse {
            frame[31] = E_AGAIN;
            return E_AGAIN;
        };
        thread.blocked_ep = ep_idx;
        sched.global.blockCurrent();
        frame[31] = E_AGAIN;
        return E_AGAIN;
    };

    // Copy payload to user buffer
    if (buf_ptr != 0 and msg.payload_len > 0) {
        const dst: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(dst[0..msg.payload_len], msg.payload[0..msg.payload_len]);
    }

    // Return: x0 = payload length, x1 = tag
    frame[31] = @as(u64, msg.payload_len);
    frame[32] = msg.tag;
    return @as(u64, msg.payload_len);
}

fn sysEpCreate(thread_id: sched.ThreadId) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    // Create a cap pointing to the calling thread's own endpoint
    const cap_idx = table.create(.ipc_endpoint, @intCast(thread_id), cap.Rights.ALL) catch {
        return E_FULL;
    };
    return @as(u64, cap_idx);
}

fn sysEpGrant(thread_id: sched.ThreadId, ep_cap_idx: cap.CapIndex, thread_cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    // Validate endpoint cap with grant right
    const ep_cap = table.lookup(ep_cap_idx) orelse return E_BADCAP;
    if (ep_cap.cap_type != .ipc_endpoint) return E_BADCAP;
    if (!ep_cap.rights.grant) return E_BADCAP;

    // Validate thread cap
    const thread_cap = table.lookup(thread_cap_idx) orelse return E_BADCAP;
    if (thread_cap.cap_type != .thread) return E_BADCAP;

    const target_id = capObjectToId(thread_cap.object) orelse return E_BADCAP;
    const target_table = sched.getCapTable(target_id) orelse return E_BADCAP;

    // Create read-only endpoint cap in target's table
    const new_idx = target_table.create(.ipc_endpoint, ep_cap.object, cap.Rights.READ_WRITE) catch {
        return E_FULL;
    };
    return @as(u64, new_idx);
}

// ─── Thread syscalls (M2.5) ─────────────────────────────────────────

fn sysThreadCreate(thread_id: sched.ThreadId, entry_pc: u64, stack_ptr: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    // Entry point must be in user-space code range and 4-byte aligned
    // (ARM64 instruction fetch requires 4-byte alignment)
    if (!isValidUserRange(entry_pc, 4)) return E_BADARG;
    if (entry_pc & 0x3 != 0) return E_BADARG;
    // Stack pointer must be in user-space range and 16-byte aligned
    // (AArch64 ABI requires SP to be 16-byte aligned at function entry)
    if (!isValidUserRange(stack_ptr -| 1, 1)) return E_BADARG;
    if (stack_ptr & 0xF != 0) return E_BADARG;

    const new_id = sched.global.spawnAt(entry_pc, stack_ptr, platform.trampolineAddr()) catch {
        return E_FULL;
    };

    const cap_idx = table.create(.thread, @intCast(new_id), cap.Rights.ALL) catch {
        sched.global.kill(new_id);
        sched.global.reap(new_id);
        return E_FULL;
    };

    return @as(u64, cap_idx);
}

fn sysThreadGrant(thread_id: sched.ThreadId, thread_cap_idx: cap.CapIndex, cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    // Validate thread cap with grant right
    const thread_cap = table.lookup(thread_cap_idx) orelse return E_BADCAP;
    if (thread_cap.cap_type != .thread) return E_BADCAP;
    if (!thread_cap.rights.grant) return E_BADCAP;

    // Validate the cap to transfer has grant right
    const src_cap = table.lookup(cap_idx) orelse return E_BADCAP;
    if (!src_cap.rights.grant) return E_BADCAP;

    const target_id = capObjectToId(thread_cap.object) orelse return E_BADCAP;
    const target_table = sched.getCapTable(target_id) orelse return E_BADCAP;

    // Copy capability to target's table
    _ = target_table.create(src_cap.cap_type, src_cap.object, src_cap.rights) catch {
        return E_FULL;
    };

    return E_OK;
}

// ─── Supervisor syscalls (M3.1) ──────────────────────────────────────

fn sysSupervisorSet(thread_id: sched.ThreadId, thread_cap_idx: cap.CapIndex, ep_cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    // Validate thread cap with write right
    const thread_cap = table.lookup(thread_cap_idx) orelse return E_BADCAP;
    if (thread_cap.cap_type != .thread) return E_BADCAP;
    if (!thread_cap.rights.write) return E_BADCAP;

    // Validate endpoint cap with write right
    const ep_cap = table.lookup(ep_cap_idx) orelse return E_BADCAP;
    if (ep_cap.cap_type != .ipc_endpoint) return E_BADCAP;
    if (!ep_cap.rights.write) return E_BADCAP;

    const target_id = capObjectToId(thread_cap.object) orelse return E_BADCAP;
    const target_thread = sched.global.getThread(target_id) orelse return E_BADCAP;

    // Store the endpoint index so kill() can deliver the fault notification
    target_thread.supervisor_ep = capObjectToId(ep_cap.object) orelse return E_BADCAP;

    return E_OK;
}

fn sysThreadReap(thread_id: sched.ThreadId, thread_cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    const thread_cap = table.lookup(thread_cap_idx) orelse return E_BADCAP;
    if (thread_cap.cap_type != .thread) return E_BADCAP;
    if (!thread_cap.rights.write) return E_BADCAP;

    const target_id = capObjectToId(thread_cap.object) orelse return E_BADCAP;
    const target = sched.global.getThread(target_id) orelse return E_BADCAP;

    // Only dead threads can be reaped
    if (target.state != .dead) return E_BADARG;

    sched.global.reap(target_id);

    // Delete the thread cap since the thread no longer exists
    table.delete(thread_cap_idx);

    return E_OK;
}

fn sysThreadKill(thread_id: sched.ThreadId, thread_cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    const thread_cap = table.lookup(thread_cap_idx) orelse return E_BADCAP;
    if (thread_cap.cap_type != .thread) return E_BADCAP;
    if (!thread_cap.rights.write) return E_BADCAP;

    const target_id = capObjectToId(thread_cap.object) orelse return E_BADCAP;

    // Cannot kill yourself via this syscall (use SYS_EXIT instead)
    if (target_id == thread_id) return E_BADARG;

    const target = sched.global.getThread(target_id) orelse return E_BADCAP;
    if (target.state == .dead or target.state == .free) return E_BADARG;

    // Notify supervisor before killing (BEAM supervision pattern)
    fault_mod.notify(target_id, .killed, 0, 0);
    sched.global.kill(target_id);

    return E_OK;
}

// ─── Cap delegation syscalls (M3.2) ──────────────────────────────────

fn sysIpcSendCap(thread_id: sched.ThreadId, ep_cap_idx: cap.CapIndex, msg_ptr: u64, msg_len: u64, cap_to_send: cap.CapIndex) u64 {
    const sender_table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    // Validate endpoint cap
    const ep_cap_val = sender_table.lookup(ep_cap_idx) orelse return E_BADCAP;
    if (ep_cap_val.cap_type != .ipc_endpoint) return E_BADCAP;
    if (!ep_cap_val.rights.write) return E_BADCAP;

    // Validate the capability to transfer (must exist and have grant right)
    const src_cap = sender_table.lookup(cap_to_send) orelse return E_BADCAP;
    if (!src_cap.rights.grant) return E_BADCAP;

    const ep_idx = capObjectToId(ep_cap_val.object) orelse return E_BADCAP;
    const ep = sched.getEndpoint(ep_idx) orelse return E_BADCAP;

    // Receiver's cap table: endpoint[i] is owned by thread i
    const receiver_table = sched.getCapTable(ep_idx) orelse return E_BADCAP;

    const len: u32 = @intCast(@min(msg_len, ipc.MAX_PAYLOAD));
    if (len > 0 and !isValidUserRange(msg_ptr, len)) return E_BADARG;

    var msg = ipc.Message{ .payload_len = len };
    if (msg_ptr != 0 and len > 0) {
        const src: [*]const u8 = @ptrFromInt(msg_ptr);
        @memcpy(msg.payload[0..len], src[0..len]);
    }
    msg.attachCap(cap_to_send) catch return E_BADARG;

    ep.send(msg, sender_table, receiver_table) catch |err| {
        return switch (err) {
            error.QueueFull => E_FULL,
            error.EndpointClosed => E_CLOSED,
            error.InvalidCapability => E_BADCAP,
            error.TableFull => E_FULL,
        };
    };

    // Wake any thread blocked on recv for this endpoint
    sched.global.wakeBlockedRecv(ep_idx);

    return E_OK;
}

fn sysIpcRecvCap(thread_id: sched.ThreadId, frame: [*]u64, ep_cap_idx: cap.CapIndex, buf_ptr: u64, tag_filter: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const c = table.lookup(ep_cap_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    if (c.cap_type != .ipc_endpoint) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }
    if (!c.rights.read) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }

    const ep_idx = capObjectToId(c.object) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const ep = sched.getEndpoint(ep_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };

    // Validate user buffer before consuming message
    if (buf_ptr != 0 and !isValidUserRange(buf_ptr, ipc.MAX_PAYLOAD)) {
        frame[31] = E_BADARG;
        frame[32] = @as(u64, cap.CAP_NULL);
        return E_BADARG;
    }

    const msg = ep.recv(tag_filter) orelse {
        frame[31] = E_AGAIN;
        frame[32] = @as(u64, cap.CAP_NULL);
        return E_AGAIN;
    };

    // Copy payload to user buffer
    if (buf_ptr != 0 and msg.payload_len > 0) {
        const dst: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(dst[0..msg.payload_len], msg.payload[0..msg.payload_len]);
    }

    // x0 = payload length, x1 = transferred cap index (CAP_NULL if none)
    frame[31] = @as(u64, msg.payload_len);
    frame[32] = if (msg.cap_count > 0 and msg.cap_count <= ipc.MAX_MSG_CAPS)
        @as(u64, msg.caps[0])
    else
        @as(u64, cap.CAP_NULL);
    return @as(u64, msg.payload_len);
}

fn sysIpcRecvCapBlock(thread_id: sched.ThreadId, frame: [*]u64, ep_cap_idx: cap.CapIndex, buf_ptr: u64, tag_filter: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const c = table.lookup(ep_cap_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    if (c.cap_type != .ipc_endpoint) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }
    if (!c.rights.read) {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    }

    const ep_idx = capObjectToId(c.object) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };
    const ep = sched.getEndpoint(ep_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };

    if (buf_ptr != 0 and !isValidUserRange(buf_ptr, ipc.MAX_PAYLOAD)) {
        frame[31] = E_BADARG;
        frame[32] = @as(u64, cap.CAP_NULL);
        return E_BADARG;
    }

    const msg = ep.recv(tag_filter) orelse {
        // Closed endpoint with no pending messages — return E_CLOSED
        if (ep.closed) {
            frame[31] = E_CLOSED;
            frame[32] = @as(u64, cap.CAP_NULL);
            return E_CLOSED;
        }
        // Block the calling thread until a message arrives
        const thread = sched.global.getThread(thread_id) orelse {
            frame[31] = E_AGAIN;
            frame[32] = @as(u64, cap.CAP_NULL);
            return E_AGAIN;
        };
        thread.blocked_ep = ep_idx;
        sched.global.blockCurrent();
        frame[31] = E_AGAIN;
        frame[32] = @as(u64, cap.CAP_NULL);
        return E_AGAIN;
    };

    if (buf_ptr != 0 and msg.payload_len > 0) {
        const dst: [*]u8 = @ptrFromInt(buf_ptr);
        @memcpy(dst[0..msg.payload_len], msg.payload[0..msg.payload_len]);
    }

    frame[31] = @as(u64, msg.payload_len);
    frame[32] = if (msg.cap_count > 0 and msg.cap_count <= ipc.MAX_MSG_CAPS)
        @as(u64, msg.caps[0])
    else
        @as(u64, cap.CAP_NULL);
    return @as(u64, msg.payload_len);
}

// ─── Tests ──────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "isValidUserRange accepts valid ranges" {
    // Zero length is always valid
    try testing.expect(isValidUserRange(0, 0));
    try testing.expect(isValidUserRange(0x100000, 0));

    // Exact start of user memory
    try testing.expect(isValidUserRange(USER_MEM_START, 1));
    try testing.expect(isValidUserRange(USER_MEM_START, 4096));

    // Exact end of user memory
    try testing.expect(isValidUserRange(USER_MEM_END, 1));

    // Full user range
    try testing.expect(isValidUserRange(USER_MEM_START, USER_MEM_END - USER_MEM_START + 1));
}

test "isValidUserRange rejects invalid ranges" {
    // Below user memory
    try testing.expect(!isValidUserRange(0x100000, 1));
    try testing.expect(!isValidUserRange(0, 1));

    // Just below boundary
    try testing.expect(!isValidUserRange(USER_MEM_START - 1, 1));

    // Extends past end
    try testing.expect(!isValidUserRange(USER_MEM_END, 2));

    // Overflow
    try testing.expect(!isValidUserRange(0xFFFFFFFFFFFFFFFF, 2));
}

test "capObjectToId accepts valid thread IDs" {
    try testing.expectEqual(@as(?sched.ThreadId, 0), capObjectToId(0));
    try testing.expectEqual(@as(?sched.ThreadId, 63), capObjectToId(63));
}

test "capObjectToId rejects out-of-range values" {
    try testing.expect(capObjectToId(64) == null);
    try testing.expect(capObjectToId(0xFFFFFFFF) == null);
    try testing.expect(capObjectToId(0xDEAD) == null);
}

// ─── Syscall handler tests ───────────────────────────────────────────
// These test the actual syscall functions with real kernel state (sched.global,
// cap tables, IPC endpoints, frame allocator). The platform-specific parts
// (idle_loop, trampoline) are stubbed out for host testing.

fn testSetup() sched.ThreadId {
    // Reset scheduler state
    sched.global = .{};
    frame_mod.global = frame_mod.FrameAllocator.init();
    // Spawn a test thread
    const id = sched.global.spawn() catch unreachable;
    sched.global.threads[id].state = .running;
    sched.global.current = id;
    sched.global.has_current = true;
    // Give it a device cap (UART) at slot 0
    const table = sched.getCapTable(id).?;
    _ = table.create(.device, 0, cap.Rights.ALL) catch unreachable;
    return id;
}

fn testTeardown() void {
    sched.global = .{};
    frame_mod.global = frame_mod.FrameAllocator.init();
}

test "sysCapRead returns cap type" {
    const tid = testSetup();
    defer testTeardown();
    // cap[0] is device
    try testing.expectEqual(E_OK + @intFromEnum(cap.CapabilityType.device), sysCapRead(tid, 0));
    // non-existent cap
    try testing.expectEqual(E_BADCAP, sysCapRead(tid, 99));
}

test "sysFrameAlloc and sysFrameFree round-trip" {
    const tid = testSetup();
    defer testTeardown();
    const result = sysFrameAlloc(tid);
    // Should succeed: cap index returned (small positive number)
    try testing.expect(result < 256);
    const cap_idx: cap.CapIndex = @intCast(result);

    // Verify it's a frame cap
    try testing.expectEqual(E_OK + @intFromEnum(cap.CapabilityType.frame), sysCapRead(tid, cap_idx));

    // Free it
    try testing.expectEqual(E_OK, sysFrameFree(tid, cap_idx));

    // Double-free should fail (cap was deleted)
    try testing.expectEqual(E_BADCAP, sysFrameFree(tid, cap_idx));
}

test "sysFramePhys returns physical address" {
    const tid = testSetup();
    defer testTeardown();
    const alloc_result = sysFrameAlloc(tid);
    const cap_idx: cap.CapIndex = @intCast(alloc_result);

    const phys = sysFramePhys(tid, cap_idx);
    // Physical address should be in the frame pool range
    try testing.expect(phys >= 0x400000);
    try testing.expect(phys < 0x4000000);
}

test "sysFramePhys rejects non-frame cap" {
    const tid = testSetup();
    defer testTeardown();
    // cap[0] is device, not frame
    try testing.expectEqual(E_BADCAP, sysFramePhys(tid, 0));
}

test "sysCapDerive attenuates rights" {
    const tid = testSetup();
    defer testTeardown();
    // Allocate a frame (has ALL rights)
    const frame_cap: cap.CapIndex = @intCast(sysFrameAlloc(tid));

    // Derive with read-only rights
    const read_only: u8 = @bitCast(cap.Rights{ .read = true });
    const derived = sysCapDerive(tid, frame_cap, read_only);
    try testing.expect(derived < 256);

    // Verify derived cap exists
    const derived_idx: cap.CapIndex = @intCast(derived);
    try testing.expectEqual(E_OK + @intFromEnum(cap.CapabilityType.frame), sysCapRead(tid, derived_idx));
}

test "sysCapDerive rejects rights escalation" {
    const tid = testSetup();
    defer testTeardown();
    // Create a read-only frame cap via derive
    const frame_cap: cap.CapIndex = @intCast(sysFrameAlloc(tid));
    const read_only: u8 = @bitCast(cap.Rights{ .read = true });
    const derived: cap.CapIndex = @intCast(sysCapDerive(tid, frame_cap, read_only));

    // Try to escalate back to ALL — should fail
    const all: u8 = @bitCast(cap.Rights.ALL);
    try testing.expectEqual(E_BADCAP, sysCapDerive(tid, derived, all));
}

test "sysCapDelete removes capability" {
    const tid = testSetup();
    defer testTeardown();
    const frame_cap: cap.CapIndex = @intCast(sysFrameAlloc(tid));

    try testing.expectEqual(E_OK, sysCapDelete(tid, frame_cap));
    // Now it's gone
    try testing.expectEqual(E_BADCAP, sysCapRead(tid, frame_cap));
}

test "sysCapDelete rejects invalid cap" {
    const tid = testSetup();
    defer testTeardown();
    try testing.expectEqual(E_BADCAP, sysCapDelete(tid, 200));
}

test "sysEpCreate creates endpoint cap" {
    const tid = testSetup();
    defer testTeardown();
    const result = sysEpCreate(tid);
    try testing.expect(result < 256);
    const ep_cap: cap.CapIndex = @intCast(result);
    try testing.expectEqual(E_OK + @intFromEnum(cap.CapabilityType.ipc_endpoint), sysCapRead(tid, ep_cap));
}

test "sysIpcSend and sysIpcRecv round-trip" {
    const tid = testSetup();
    defer testTeardown();
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));

    // Send with empty payload and tag=42
    const send_result = sysIpcSend(tid, ep_cap, 0, 0, 42);
    try testing.expectEqual(E_OK, send_result);

    // Receive
    var frame_buf: [34]u64 = undefined;
    const recv_result = sysIpcRecv(tid, &frame_buf, ep_cap, 0, 0);
    // x0 = payload_len (0), x1 = tag (42)
    try testing.expectEqual(@as(u64, 0), frame_buf[31]); // payload_len
    try testing.expectEqual(@as(u64, 42), frame_buf[32]); // tag
    _ = recv_result;
}

test "sysIpcRecv returns E_AGAIN when empty" {
    const tid = testSetup();
    defer testTeardown();
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));

    var frame_buf: [34]u64 = undefined;
    const result = sysIpcRecv(tid, &frame_buf, ep_cap, 0, 0);
    try testing.expectEqual(E_AGAIN, result);
}

test "sysThreadCreate validates alignment" {
    const tid = testSetup();
    defer testTeardown();

    // Misaligned entry point (not 4-byte aligned)
    try testing.expectEqual(E_BADARG, sysThreadCreate(tid, 0x200001, 0x201000));

    // Misaligned stack (not 16-byte aligned)
    try testing.expectEqual(E_BADARG, sysThreadCreate(tid, 0x200000, 0x201008));

    // Entry outside user range
    try testing.expectEqual(E_BADARG, sysThreadCreate(tid, 0x80000, 0x201000));
}

test "sysThreadCreate succeeds with valid args" {
    const tid = testSetup();
    defer testTeardown();
    // Valid: entry in user range, 4-byte aligned; stack in user range, 16-byte aligned
    const result = sysThreadCreate(tid, 0x200000, 0x300000);
    try testing.expect(result < 256); // returns cap index
}

test "sysThreadGrant transfers capability" {
    const tid = testSetup();
    defer testTeardown();
    // Create a child thread
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));

    // Grant cap[0] (device/UART) to child
    const result = sysThreadGrant(tid, child_cap, 0);
    try testing.expectEqual(E_OK, result);

    // Verify child has the cap — look up child's cap table
    const table = sched.getCapTable(tid).?;
    const thread_cap_val = table.lookup(child_cap).?;
    const child_id = capObjectToId(thread_cap_val.object).?;
    const child_table = sched.getCapTable(child_id).?;
    // Child should have a device cap
    const child_cap0 = child_table.lookup(0).?;
    try testing.expectEqual(cap.CapabilityType.device, child_cap0.cap_type);
}

test "sysThreadGrant rejects without grant right" {
    const tid = testSetup();
    defer testTeardown();
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));

    // Create a read-only device cap (no grant right)
    const table = sched.getCapTable(tid).?;
    const ro_cap = table.create(.device, 0, cap.Rights{ .read = true }) catch unreachable;

    // Try to grant the read-only cap — should fail (no grant right)
    try testing.expectEqual(E_BADCAP, sysThreadGrant(tid, child_cap, ro_cap));
}

test "sysSupervisorSet configures supervisor endpoint" {
    const tid = testSetup();
    defer testTeardown();
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));

    const result = sysSupervisorSet(tid, child_cap, ep_cap);
    try testing.expectEqual(E_OK, result);

    // Verify the child's supervisor_ep is set
    const table = sched.getCapTable(tid).?;
    const thread_cap_val = table.lookup(child_cap).?;
    const child_id = capObjectToId(thread_cap_val.object).?;
    const child_thread = sched.global.getThread(child_id).?;
    try testing.expectEqual(tid, child_thread.supervisor_ep);
}

test "sysThreadKill kills target and notifies supervisor" {
    const tid = testSetup();
    defer testTeardown();
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));
    _ = sysSupervisorSet(tid, child_cap, ep_cap);

    // Kill the child
    const result = sysThreadKill(tid, child_cap);
    try testing.expectEqual(E_OK, result);

    // Child should be dead
    const table = sched.getCapTable(tid).?;
    const thread_cap_val = table.lookup(child_cap).?;
    const child_id = capObjectToId(thread_cap_val.object).?;
    const child_thread = sched.global.getThread(child_id).?;
    try testing.expectEqual(sched.ThreadState.dead, child_thread.state);

    // Supervisor should have received a fault notification
    const ep = sched.getEndpoint(tid).?;
    const msg = ep.recv(0);
    try testing.expect(msg != null);
    try testing.expectEqual(@as(u64, 0xDEAD_DEAD_DEAD_DEAD), msg.?.tag);
}

test "sysThreadKill rejects self-kill" {
    const tid = testSetup();
    defer testTeardown();
    // Create a thread cap pointing to ourselves
    const table = sched.getCapTable(tid).?;
    const self_cap = table.create(.thread, @intCast(tid), cap.Rights.ALL) catch unreachable;

    try testing.expectEqual(E_BADARG, sysThreadKill(tid, self_cap));
}

test "sysThreadReap cleans up dead thread" {
    const tid = testSetup();
    defer testTeardown();
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));

    // Get child ID before killing
    const table = sched.getCapTable(tid).?;
    const thread_cap_val = table.lookup(child_cap).?;
    const child_id = capObjectToId(thread_cap_val.object).?;

    // Kill then reap
    _ = sysThreadKill(tid, child_cap);
    const result = sysThreadReap(tid, child_cap);
    try testing.expectEqual(E_OK, result);

    // Thread should be free now
    try testing.expectEqual(sched.ThreadState.free, sched.global.threads[child_id].state);
    // Cap should be deleted
    try testing.expect(table.lookup(child_cap) == null);
}

test "sysThreadReap rejects non-dead thread" {
    const tid = testSetup();
    defer testTeardown();
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));

    // Child is still ready, not dead
    try testing.expectEqual(E_BADARG, sysThreadReap(tid, child_cap));
}

test "sysWrite rejects kernel pointer" {
    const tid = testSetup();
    defer testTeardown();
    // Try to write from a kernel address (below user range)
    try testing.expectEqual(E_BADARG, sysWrite(tid, 0, 0x80000, 10));
}

test "sysWrite rejects non-device cap" {
    const tid = testSetup();
    defer testTeardown();
    // Allocate a frame cap — not a device cap
    const frame_cap: cap.CapIndex = @intCast(sysFrameAlloc(tid));
    try testing.expectEqual(E_BADCAP, sysWrite(tid, frame_cap, 0, 0));
}

test "dispatch returns E_BADSYS for unknown syscall" {
    const tid = testSetup();
    defer testTeardown();
    var frame_buf: [34]u64 = undefined;
    frame_buf[6] = 999; // x8 = invalid syscall number
    frame_buf[31] = 0; // x0
    frame_buf[32] = 0; // x1
    frame_buf[0] = 0; // x2
    frame_buf[1] = 0; // x3
    dispatch(tid, &frame_buf);
    try testing.expectEqual(E_BADSYS, frame_buf[31]);
}

test "sysIpcSendCap transfers capability" {
    const tid = testSetup();
    defer testTeardown();

    // Spawn a receiver thread
    const recv_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));
    const table = sched.getCapTable(tid).?;
    const recv_thread_val = table.lookup(recv_cap).?;
    const recv_id = capObjectToId(recv_thread_val.object).?;

    // Create endpoint for receiver
    const recv_table = sched.getCapTable(recv_id).?;
    const recv_ep_cap = recv_table.create(.ipc_endpoint, @intCast(recv_id), cap.Rights.ALL) catch unreachable;
    _ = recv_ep_cap;

    // Sender creates endpoint cap pointing to receiver's endpoint
    const sender_ep = table.create(.ipc_endpoint, @intCast(recv_id), cap.Rights.ALL) catch unreachable;

    // Allocate a frame to send
    const frame_cap: cap.CapIndex = @intCast(sysFrameAlloc(tid));

    // Send the frame cap
    const result = sysIpcSendCap(tid, sender_ep, 0, 0, frame_cap);
    try testing.expectEqual(E_OK, result);
}

test "sysExit kills thread and notifies supervisor" {
    const tid = testSetup();
    defer testTeardown();
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));
    _ = sysSupervisorSet(tid, child_cap, ep_cap);

    // Resolve child ID
    const table = sched.getCapTable(tid).?;
    const thread_cap_val = table.lookup(child_cap).?;
    const child_id = capObjectToId(thread_cap_val.object).?;

    // sysExit on the child
    _ = sysExit(child_id);
    try testing.expectEqual(sched.ThreadState.dead, sched.global.threads[child_id].state);

    // Supervisor should have a fault notification
    const ep = sched.getEndpoint(tid).?;
    const msg = ep.recv(0);
    try testing.expect(msg != null);
    try testing.expectEqual(@as(u64, 0xDEAD_DEAD_DEAD_DEAD), msg.?.tag);
}

test "sysEpGrant creates cap in target thread" {
    const tid = testSetup();
    defer testTeardown();
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));
    const child_cap: cap.CapIndex = @intCast(sysThreadCreate(tid, 0x200000, 0x300000));

    // Grant endpoint to child
    const result = sysEpGrant(tid, ep_cap, child_cap);
    try testing.expect(result < 256); // returns new cap index in child's table

    // Verify child has an ipc_endpoint cap
    const table = sched.getCapTable(tid).?;
    const thread_cap_val = table.lookup(child_cap).?;
    const child_id = capObjectToId(thread_cap_val.object).?;
    const child_table = sched.getCapTable(child_id).?;
    const child_ep = child_table.lookup(@intCast(result)).?;
    try testing.expectEqual(cap.CapabilityType.ipc_endpoint, child_ep.cap_type);
}

test "sysIpcRecvBlock blocks on empty endpoint" {
    const tid = testSetup();
    defer testTeardown();
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));

    // Set thread as running/current so blockCurrent works
    sched.global.threads[tid].state = .running;
    sched.global.current = tid;
    sched.global.has_current = true;

    var frame_buf: [34]u64 = undefined;
    const result = sysIpcRecvBlock(tid, &frame_buf, ep_cap, 0, 0);
    try testing.expectEqual(E_AGAIN, result);

    // Thread should be blocked now
    try testing.expectEqual(sched.ThreadState.blocked, sched.global.threads[tid].state);
    try testing.expectEqual(tid, sched.global.threads[tid].blocked_ep);
}

test "sysIpcRecvBlock returns E_CLOSED on closed endpoint" {
    const tid = testSetup();
    defer testTeardown();
    const ep_cap: cap.CapIndex = @intCast(sysEpCreate(tid));

    // Close the endpoint
    const ep = sched.getEndpoint(tid).?;
    ep.close();

    var frame_buf: [34]u64 = undefined;
    const result = sysIpcRecvBlock(tid, &frame_buf, ep_cap, 0, 0);
    try testing.expectEqual(E_CLOSED, result);
}

test "sysFramePhys rejects read without read right" {
    const tid = testSetup();
    defer testTeardown();
    // Allocate a frame, then derive write-only (no read)
    const frame_cap: cap.CapIndex = @intCast(sysFrameAlloc(tid));
    const write_only: u8 = @bitCast(cap.Rights{ .write = true });
    const derived: cap.CapIndex = @intCast(sysCapDerive(tid, frame_cap, write_only));

    try testing.expectEqual(E_BADCAP, sysFramePhys(tid, derived));
}

fn putDec(val: u32) void {
    if (val == 0) {
        uart.putc('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) {
        buf[i] = @intCast((n % 10) + '0');
        n /= 10;
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        uart.putc(buf[i]);
    }
}
