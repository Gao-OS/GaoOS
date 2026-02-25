// LibOS Thread helpers
//
// High-level wrappers for thread creation that handle stack allocation
// and capability setup, reducing boilerplate in user programs.

const sys = @import("syscall.zig");

/// Result of spawning a thread: the thread cap and its stack frame cap
/// (caller must hold the stack cap for cleanup).
pub const SpawnResult = struct {
    thread_cap: u32,
    stack_cap: u32,
};

/// Spawn a new thread with automatic stack allocation.
/// The caller gets both the thread cap and the stack cap (for later cleanup).
/// Returns negative error code on failure.
pub fn spawn(entry: *const fn () callconv(.{ .aarch64_aapcs = .{} }) noreturn) SpawnError!SpawnResult {
    // Allocate a 4KB stack frame
    const stack_r = sys.frameAlloc();
    if (stack_r < 0) return error.StackAlloc;
    const stack_cap: u32 = @intCast(stack_r);

    const phys_r = sys.framePhys(stack_cap);
    if (phys_r < 0) {
        _ = sys.frameFree(stack_cap);
        return error.StackPhys;
    }
    const stack_top: u64 = @as(u64, @bitCast(phys_r)) +| 4096;

    // Create the thread
    const thread_r = sys.threadCreate(@intFromPtr(entry), stack_top);
    if (thread_r < 0) {
        _ = sys.frameFree(stack_cap);
        return error.ThreadCreate;
    }

    return .{
        .thread_cap = @intCast(thread_r),
        .stack_cap = stack_cap,
    };
}

pub const SpawnError = error{
    StackAlloc,
    StackPhys,
    ThreadCreate,
};
