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

// ─── Error codes (returned in x0) ──────────────────────────────────

const E_OK: u64 = 0;
const E_BADCAP: u64 = @bitCast(@as(i64, -1));
const E_BADARG: u64 = @bitCast(@as(i64, -2));
const E_BADSYS: u64 = @bitCast(@as(i64, -3));
const E_NOMEM: u64 = @bitCast(@as(i64, -4));
const E_FULL: u64 = @bitCast(@as(i64, -5));
const E_CLOSED: u64 = @bitCast(@as(i64, -6));
const E_AGAIN: u64 = @bitCast(@as(i64, -7));

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
        else => E_BADSYS,
    };

    // Write return value back to x0 in the exception frame.
    // (sysIpcRecv and sysIpcRecvCap write their return values directly to frame)
    if (syscall_num != SYS_IPC_RECV and syscall_num != SYS_IPC_RECV_CAP) {
        frame[31] = result;
    }

    if (syscall_num == SYS_EXIT) {
        frame[29] = @intFromPtr(&idle_loop);
        frame[30] = 0x3c5; // SPSR = EL1h, DAIF masked
    }
}

/// Idle loop that eret returns to after SYS_EXIT.
export fn idle_loop() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    uart.puts("Returning to kernel idle loop.\n");
    while (true) {
        asm volatile ("wfe");
    }
}

// Assembly trampoline for new threads entering EL0 (in user_entry.S).
extern const thread_entry_trampoline: u8;

// ─── Phase 1 syscalls ────────────────────────────────────────────────

fn sysWrite(thread_id: sched.ThreadId, cap_idx: cap.CapIndex, buf_ptr: u64, buf_len: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const c = table.lookup(cap_idx) orelse return E_BADCAP;
    if (c.cap_type != .device) return E_BADCAP;
    if (!c.rights.write) return E_BADCAP;

    if (buf_len == 0) return E_OK;
    if (buf_ptr == 0) return E_BADARG;

    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: usize = @intCast(@min(buf_len, 4096));

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

    const ep_idx: sched.ThreadId = @intCast(c.object);
    const ep = sched.getEndpoint(ep_idx) orelse return E_BADCAP;

    const len: u32 = @intCast(@min(msg_len, ipc.MAX_PAYLOAD));
    var msg = ipc.Message{ .tag = tag, .payload_len = len };

    if (msg_ptr != 0 and len > 0) {
        const src: [*]const u8 = @ptrFromInt(msg_ptr);
        for (0..len) |i| {
            msg.payload[i] = src[i];
        }
    }

    ep.send(msg, null, null) catch |err| {
        return switch (err) {
            error.QueueFull => E_FULL,
            error.EndpointClosed => E_CLOSED,
            error.InvalidCapability => E_BADCAP,
            error.TableFull => E_FULL,
        };
    };
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

    const ep_idx: sched.ThreadId = @intCast(c.object);
    const ep = sched.getEndpoint(ep_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };

    const msg = ep.recv(tag_filter) orelse {
        frame[31] = E_AGAIN;
        return E_AGAIN;
    };

    // Copy payload to user buffer
    if (buf_ptr != 0 and msg.payload_len > 0) {
        const dst: [*]u8 = @ptrFromInt(buf_ptr);
        for (0..msg.payload_len) |i| {
            dst[i] = msg.payload[i];
        }
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

    const target_id: sched.ThreadId = @intCast(thread_cap.object);
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

    if (entry_pc == 0) return E_BADARG;
    if (stack_ptr == 0) return E_BADARG;

    const new_id = sched.global.spawnAt(entry_pc, stack_ptr, @intFromPtr(&thread_entry_trampoline)) catch {
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

    const target_id: sched.ThreadId = @intCast(thread_cap.object);
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

    const target_id: sched.ThreadId = @intCast(thread_cap.object);
    const target_thread = sched.global.getThread(target_id) orelse return E_BADCAP;

    // Store the endpoint index so kill() can deliver the fault notification
    target_thread.supervisor_ep = @intCast(ep_cap.object);

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

    const ep_idx: sched.ThreadId = @intCast(ep_cap_val.object);
    const ep = sched.getEndpoint(ep_idx) orelse return E_BADCAP;

    // Receiver's cap table: endpoint[i] is owned by thread i
    const receiver_table = sched.getCapTable(ep_idx) orelse return E_BADCAP;

    const len: u32 = @intCast(@min(msg_len, ipc.MAX_PAYLOAD));
    var msg = ipc.Message{ .payload_len = len };
    if (msg_ptr != 0 and len > 0) {
        const src: [*]const u8 = @ptrFromInt(msg_ptr);
        for (0..len) |i| {
            msg.payload[i] = src[i];
        }
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

    const ep_idx: sched.ThreadId = @intCast(c.object);
    const ep = sched.getEndpoint(ep_idx) orelse {
        frame[31] = E_BADCAP;
        return E_BADCAP;
    };

    const msg = ep.recv(tag_filter) orelse {
        frame[31] = E_AGAIN;
        frame[32] = @as(u64, cap.CAP_NULL);
        return E_AGAIN;
    };

    // Copy payload to user buffer
    if (buf_ptr != 0 and msg.payload_len > 0) {
        const dst: [*]u8 = @ptrFromInt(buf_ptr);
        for (0..msg.payload_len) |i| {
            dst[i] = msg.payload[i];
        }
    }

    // x0 = payload length, x1 = transferred cap index (CAP_NULL if none)
    frame[31] = @as(u64, msg.payload_len);
    frame[32] = if (msg.cap_count > 0)
        @as(u64, msg.caps[0])
    else
        @as(u64, cap.CAP_NULL);
    return @as(u64, msg.payload_len);
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
