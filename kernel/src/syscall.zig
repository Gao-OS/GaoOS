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

// ─── Syscall Numbers ───────────────────────────────────────────────

pub const SYS_WRITE = 0; // write(cap_idx, buf_ptr, buf_len) → bytes_written
pub const SYS_EXIT = 1; // exit() → noreturn (does not return)
pub const SYS_YIELD = 2; // yield() → 0
pub const SYS_CAP_READ = 3; // cap_read(cap_idx) → cap_type (introspect a capability)

// ─── Error codes (returned in x0) ──────────────────────────────────

const E_OK: u64 = 0;
const E_BADCAP: u64 = @bitCast(@as(i64, -1)); // Invalid or insufficient capability
const E_BADARG: u64 = @bitCast(@as(i64, -2)); // Invalid argument
const E_BADSYS: u64 = @bitCast(@as(i64, -3)); // Unknown syscall number

// ─── Dispatch ──────────────────────────────────────────────────────

/// Called from exception.zig when an SVC arrives from EL0.
/// thread_id: the current thread's ID (from scheduler)
/// frame: pointer to the saved register context on the kernel stack
pub fn dispatch(thread_id: sched.ThreadId, frame: [*]u64) void {
    const syscall_num = frame[6]; // x8
    const arg0 = frame[31]; // x0
    const arg1 = frame[32]; // x1
    const arg2 = frame[0]; // x2

    const result: u64 = switch (syscall_num) {
        SYS_WRITE => sysWrite(thread_id, @truncate(arg0), arg1, arg2),
        SYS_EXIT => sysExit(thread_id),
        SYS_YIELD => sysYield(),
        SYS_CAP_READ => sysCapRead(thread_id, @truncate(arg0)),
        else => E_BADSYS,
    };

    // Write return value back to x0 in the exception frame.
    frame[31] = result;

    // For SYS_EXIT: redirect eret to kernel idle loop instead of user space.
    // frame[29] = ELR_EL1, frame[30] = SPSR_EL1
    // Set ELR to idle_loop and SPSR to EL1h (kernel mode).
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

// ─── Syscall implementations ───────────────────────────────────────

/// SYS_WRITE: write bytes to a device (currently UART only).
/// Requires a device capability with write permission.
fn sysWrite(thread_id: sched.ThreadId, cap_idx: cap.CapIndex, buf_ptr: u64, buf_len: u64) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;

    // Check: must have device cap with write rights
    const c = table.lookup(cap_idx) orelse return E_BADCAP;
    if (c.cap_type != .device) return E_BADCAP;
    if (!c.rights.write) return E_BADCAP;

    // Validate buffer pointer and length
    if (buf_len == 0) return E_OK;
    if (buf_ptr == 0) return E_BADARG;

    // Safety: in Phase 1 we share the identity map, so the pointer is valid.
    // Future phases will validate against the thread's address space.
    const buf: [*]const u8 = @ptrFromInt(buf_ptr);
    const len: usize = @intCast(@min(buf_len, 4096)); // cap at 4KB per call

    for (buf[0..len]) |byte| {
        uart.putc(byte);
    }

    return len;
}

/// SYS_EXIT: terminate the calling thread.
/// Modifies ELR_EL1 in the frame to redirect execution to the idle loop
/// instead of returning to user space.
fn sysExit(thread_id: sched.ThreadId) u64 {
    uart.puts("[kernel] thread ");
    putDec(thread_id);
    uart.puts(" exited via syscall\n");

    sched.global.kill(thread_id);
    return E_OK;
}

/// SYS_YIELD: voluntarily yield the CPU.
fn sysYield() u64 {
    // In a full implementation this would trigger a context switch.
    // For Phase 1.7 demo, it's a no-op that returns success.
    return E_OK;
}

/// SYS_CAP_READ: introspect a capability (returns the type as u64).
/// Useful for user-space to verify what capabilities it holds.
fn sysCapRead(thread_id: sched.ThreadId, cap_idx: cap.CapIndex) u64 {
    const table = sched.getCapTable(thread_id) orelse return E_BADCAP;
    const c = table.lookup(cap_idx) orelse return E_BADCAP;
    return @intFromEnum(c.cap_type);
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
