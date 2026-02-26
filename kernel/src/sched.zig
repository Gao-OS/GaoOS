// Scheduler — Round-Robin with Preemption
//
// Phase 1: cooperative + timer-preempted round-robin.
//
// Design for BEAM:
// - The exokernel scheduler provides mechanism only (round-robin);
//   the LibOS can implement priority and fairness on top.
// - Timer preemption is the safety net for runaway threads.
//
// Memory layout: thread control blocks, cap tables, and IPC endpoints
// are separate global arrays to ensure proper alignment and keep the
// scheduling hot path cache-friendly.

const cap = @import("cap");
const ipc = @import("ipc");

/// Maximum threads in Phase 1.
pub const MAX_THREADS = 64;

/// Per-thread kernel stack size (4KB).
pub const KERNEL_STACK_SIZE = 4096;

pub const ThreadId = u32;
pub const THREAD_NONE: ThreadId = 0xFFFFFFFF;

pub const ThreadState = enum(u8) {
    free,
    ready,
    running,
    blocked,
    dead,
};

/// Callee-saved register context for context switch.
pub const Context = struct {
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    x29: u64 = 0,
    x30: u64 = 0,
    sp: u64 = 0,
    sp_el0: u64 = 0, // EL0 user-space stack pointer — must be saved/restored across context switches
};

/// Thread control block — lightweight, contains only scheduling state.
pub const Thread = struct {
    id: ThreadId = 0,
    state: ThreadState = .free,
    context: Context = .{},
    stack_base: usize = 0,
    supervisor: ThreadId = 0,
    supervisor_ep: u32 = 0xFFFFFFFF, // Endpoint index for fault notifications (0xFFFFFFFF = none)
    blocked_ep: ThreadId = THREAD_NONE, // Endpoint this thread is blocked waiting on (THREAD_NONE = not blocked)
};

/// Per-thread kernel stacks for context switching.
var kernel_stacks: [MAX_THREADS][KERNEL_STACK_SIZE]u8 align(16) = @splat([_]u8{0} ** KERNEL_STACK_SIZE);

/// Per-thread capability tables — separate global for alignment.
var cap_tables: [MAX_THREADS]cap.CapabilityTable align(16) = @splat(cap.CapabilityTable{});

/// Per-thread IPC endpoints — separate global for alignment.
var endpoints: [MAX_THREADS]ipc.Endpoint align(16) = @splat(ipc.Endpoint{});

/// Get a thread's capability table by ID.
pub fn getCapTable(id: ThreadId) ?*cap.CapabilityTable {
    if (id >= MAX_THREADS) return null;
    return &cap_tables[id];
}

/// Get a thread's IPC endpoint by ID.
pub fn getEndpoint(id: ThreadId) ?*ipc.Endpoint {
    if (id >= MAX_THREADS) return null;
    return &endpoints[id];
}

/// Reset a thread's cap table (for reap/reuse).
pub fn resetCapTable(id: ThreadId) void {
    if (id >= MAX_THREADS) return;
    // Zero out field-by-field to avoid SIMD alignment issues
    cap_tables[id].count = 0;
    for (&cap_tables[id].slots) |*slot| {
        slot.valid = false;
        slot.cap = cap.Capability.INVALID;
        slot.generation = 0;
    }
}

/// Reset a thread's endpoint (for reap/reuse).
pub fn resetEndpoint(id: ThreadId) void {
    if (id >= MAX_THREADS) return;
    endpoints[id].head = 0;
    endpoints[id].tail = 0;
    endpoints[id].count = 0;
    endpoints[id].closed = false;
}

/// The scheduler: thread table + round-robin state.
pub const Scheduler = struct {
    threads: [MAX_THREADS]Thread = [_]Thread{Thread{}} ** MAX_THREADS,
    current: ThreadId = 0,
    count: u32 = 0,
    has_current: bool = false,

    pub fn spawn(self: *Scheduler) error{ThreadTableFull}!ThreadId {
        for (&self.threads, 0..) |*thread, i| {
            if (thread.state == .free) {
                const id: ThreadId = @intCast(i);
                thread.id = id;
                thread.state = .ready;
                // Zero context field-by-field to avoid SIMD alignment faults.
                // Context sits at offset 8 in Thread (after id+state+padding),
                // which is 8-byte aligned but not 16-byte aligned.
                zeroContext(&thread.context);
                thread.stack_base = 0;
                thread.supervisor = 0;
                self.count += 1;
                return id;
            }
        }
        return error.ThreadTableFull;
    }

    /// Spawn a new thread with a specific EL0 entry point and user stack.
    /// The trampoline_addr is the address of the assembly trampoline that
    /// sets up EL0 and does eret. The new thread's callee-saved registers
    /// carry: x19 = entry_pc, x20 = stack_ptr, x30 = trampoline.
    pub fn spawnAt(self: *Scheduler, entry_pc: u64, stack_ptr: u64, trampoline_addr: u64) error{ThreadTableFull}!ThreadId {
        const id = try self.spawn();
        const thread = &self.threads[id];

        thread.context.x19 = entry_pc;
        thread.context.x20 = stack_ptr;
        thread.context.x30 = trampoline_addr;
        // Kernel stack for this thread (top = base + size, grows down)
        thread.stack_base = @intFromPtr(&kernel_stacks[id]) + KERNEL_STACK_SIZE;
        thread.context.sp = thread.stack_base;

        return id;
    }

    pub fn getThread(self: *Scheduler, id: ThreadId) ?*Thread {
        if (id >= MAX_THREADS) return null;
        const thread = &self.threads[id];
        if (thread.state == .free) return null;
        return thread;
    }

    pub fn schedule(self: *Scheduler) ?*Thread {
        if (self.count == 0) return null;

        if (self.has_current) {
            const cur = &self.threads[self.current];
            if (cur.state == .running) {
                cur.state = .ready;
            }
        }

        const start: u32 = if (self.has_current)
            self.current + 1
        else
            0;

        var i: u32 = 0;
        while (i < MAX_THREADS) : (i += 1) {
            const idx = (start + i) % MAX_THREADS;
            if (self.threads[idx].state == .ready) {
                self.threads[idx].state = .running;
                self.current = idx;
                self.has_current = true;
                return &self.threads[idx];
            }
        }

        return null;
    }

    pub fn kill(self: *Scheduler, id: ThreadId) void {
        if (id >= MAX_THREADS) return;
        const thread = &self.threads[id];
        if (thread.state == .free or thread.state == .dead) return;

        thread.state = .dead;
        thread.blocked_ep = THREAD_NONE;
        endpoints[id].close();
        // Wake any threads blocked on this thread's endpoint.
        // They will see E_CLOSED on retry instead of blocking forever.
        self.wakeBlockedRecv(id);
    }

    pub fn reap(self: *Scheduler, id: ThreadId) void {
        if (id >= MAX_THREADS) return;
        const thread = &self.threads[id];
        if (thread.state != .dead) return;

        thread.id = 0;
        thread.state = .free;
        zeroContext(&thread.context);
        thread.stack_base = 0;
        thread.supervisor = 0;
        thread.supervisor_ep = 0xFFFFFFFF;
        thread.blocked_ep = THREAD_NONE;
        resetCapTable(id);
        resetEndpoint(id);
        if (self.count > 0) self.count -= 1;
    }

    pub fn blockCurrent(self: *Scheduler) void {
        if (!self.has_current) return;
        const cur = &self.threads[self.current];
        if (cur.state == .running) {
            cur.state = .blocked;
        }
    }

    pub fn unblock(self: *Scheduler, id: ThreadId) void {
        if (id >= MAX_THREADS) return;
        const thread = &self.threads[id];
        if (thread.state == .blocked) {
            thread.state = .ready;
            thread.blocked_ep = THREAD_NONE;
        }
    }

    /// Wake one thread blocked on recv for the given endpoint.
    /// Called after a message is enqueued to an endpoint.
    pub fn wakeBlockedRecv(self: *Scheduler, ep_id: ThreadId) void {
        for (&self.threads) |*thread| {
            if (thread.state == .blocked and thread.blocked_ep == ep_id) {
                thread.state = .ready;
                thread.blocked_ep = THREAD_NONE;
                return; // wake only one
            }
        }
    }
};

/// Zero a Context without triggering SIMD stores (alignment-safe).
fn zeroContext(ctx: *Context) void {
    ctx.x19 = 0;
    ctx.x20 = 0;
    ctx.x21 = 0;
    ctx.x22 = 0;
    ctx.x23 = 0;
    ctx.x24 = 0;
    ctx.x25 = 0;
    ctx.x26 = 0;
    ctx.x27 = 0;
    ctx.x28 = 0;
    ctx.x29 = 0;
    ctx.x30 = 0;
    ctx.sp = 0;
    ctx.sp_el0 = 0;
}

pub var global: Scheduler = .{};

// ─── Tests ──────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "spawn and get thread" {
    var sched = Scheduler{};

    const id = try sched.spawn();
    try testing.expectEqual(@as(ThreadId, 0), id);
    try testing.expectEqual(@as(u32, 1), sched.count);

    const thread = sched.getThread(id).?;
    try testing.expectEqual(ThreadState.ready, thread.state);
    try testing.expectEqual(id, thread.id);
}

test "round-robin scheduling" {
    var sched = Scheduler{};

    const t0 = try sched.spawn();
    const t1 = try sched.spawn();
    const t2 = try sched.spawn();

    const first = sched.schedule().?;
    try testing.expectEqual(t0, first.id);
    try testing.expectEqual(ThreadState.running, first.state);

    const second = sched.schedule().?;
    try testing.expectEqual(t1, second.id);

    const third = sched.schedule().?;
    try testing.expectEqual(t2, third.id);

    const fourth = sched.schedule().?;
    try testing.expectEqual(t0, fourth.id);
}

test "schedule skips blocked and dead threads" {
    var sched = Scheduler{};

    const t0 = try sched.spawn();
    const t1 = try sched.spawn();
    const t2 = try sched.spawn();

    _ = sched.schedule();
    try testing.expectEqual(t0, sched.current);

    sched.threads[t1].state = .blocked;
    sched.kill(t2);

    const next = sched.schedule().?;
    try testing.expectEqual(t0, next.id);
}

test "kill and reap thread" {
    var sched = Scheduler{};

    const id = try sched.spawn();
    try testing.expectEqual(@as(u32, 1), sched.count);

    sched.kill(id);
    try testing.expectEqual(ThreadState.dead, sched.threads[id].state);
    try testing.expect(endpoints[id].closed);

    sched.reap(id);
    try testing.expectEqual(@as(u32, 0), sched.count);
    try testing.expectEqual(ThreadState.free, sched.threads[id].state);
}

test "spawn reuses reaped slot" {
    var sched = Scheduler{};

    const first = try sched.spawn();
    sched.kill(first);
    sched.reap(first);

    const second = try sched.spawn();
    try testing.expectEqual(first, second);
}

test "block and unblock" {
    var sched = Scheduler{};

    const id = try sched.spawn();
    _ = sched.schedule();
    try testing.expectEqual(ThreadState.running, sched.threads[id].state);

    sched.blockCurrent();
    try testing.expectEqual(ThreadState.blocked, sched.threads[id].state);

    sched.unblock(id);
    try testing.expectEqual(ThreadState.ready, sched.threads[id].state);
}

test "empty scheduler returns null" {
    var sched = Scheduler{};
    try testing.expect(sched.schedule() == null);
}

test "thread table full" {
    var sched = Scheduler{};

    for (0..MAX_THREADS) |_| {
        _ = try sched.spawn();
    }

    const result = sched.spawn();
    try testing.expectError(error.ThreadTableFull, result);
}

test "spawnAt sets context fields" {
    var s = Scheduler{};
    const id = try s.spawnAt(0x200000, 0x400000, 0x80100);
    const thread = s.getThread(id).?;
    try testing.expectEqual(@as(u64, 0x200000), thread.context.x19);
    try testing.expectEqual(@as(u64, 0x400000), thread.context.x20);
    try testing.expectEqual(@as(u64, 0x80100), thread.context.x30);
    try testing.expect(thread.stack_base != 0);
}

test "getThread returns null for free slot" {
    var s = Scheduler{};
    try testing.expect(s.getThread(0) == null); // slot 0 is free
    try testing.expect(s.getThread(999) == null); // out of range
}

test "kill ignores free and dead threads" {
    var s = Scheduler{};
    // Kill on free thread should not crash or change state
    s.kill(0);
    try testing.expectEqual(ThreadState.free, s.threads[0].state);

    // Kill on already-dead thread should be idempotent
    const id = try s.spawn();
    s.kill(id);
    try testing.expectEqual(ThreadState.dead, s.threads[id].state);
    s.kill(id); // second kill should not crash
    try testing.expectEqual(ThreadState.dead, s.threads[id].state);
}

test "reap resets supervisor_ep" {
    var s = Scheduler{};
    const id = try s.spawn();
    s.threads[id].supervisor_ep = 5;
    s.kill(id);
    s.reap(id);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), s.threads[id].supervisor_ep);
    try testing.expectEqual(@as(u32, 0), s.threads[id].supervisor);
    try testing.expectEqual(ThreadState.free, s.threads[id].state);
}

test "wakeBlockedRecv unblocks waiting thread" {
    var s = Scheduler{};
    const t0 = try s.spawn();
    const t1 = try s.spawn();

    // Make t0 running, then block it on endpoint t1
    _ = s.schedule();
    try testing.expectEqual(t0, s.current);
    s.threads[t0].blocked_ep = t1;
    s.blockCurrent();
    try testing.expectEqual(ThreadState.blocked, s.threads[t0].state);
    try testing.expectEqual(t1, s.threads[t0].blocked_ep);

    // Wake thread blocked on endpoint t1
    s.wakeBlockedRecv(t1);
    try testing.expectEqual(ThreadState.ready, s.threads[t0].state);
    try testing.expectEqual(THREAD_NONE, s.threads[t0].blocked_ep);

    // t0 is now schedulable again
    _ = s.schedule(); // runs t1 (round-robin from t0)
    const next = s.schedule().?;
    try testing.expectEqual(t0, next.id);
}

test "kill clears blocked_ep" {
    var s = Scheduler{};
    const t0 = try s.spawn();
    _ = s.schedule();
    s.threads[t0].blocked_ep = 3;
    s.blockCurrent();
    try testing.expectEqual(@as(ThreadId, 3), s.threads[t0].blocked_ep);

    s.kill(t0);
    try testing.expectEqual(ThreadState.dead, s.threads[t0].state);
    try testing.expectEqual(THREAD_NONE, s.threads[t0].blocked_ep);
}

test "kill wakes threads blocked on dying thread endpoint" {
    var s = Scheduler{};
    const owner = try s.spawn(); // thread 0 owns endpoint 0
    const waiter = try s.spawn(); // thread 1 blocked on endpoint 0

    _ = s.schedule(); // owner running
    _ = s.schedule(); // waiter running

    // Block waiter on owner's endpoint
    s.threads[waiter].blocked_ep = owner;
    s.threads[waiter].state = .blocked;

    // Kill the owner — should wake the waiter
    s.kill(owner);
    try testing.expectEqual(ThreadState.ready, s.threads[waiter].state);
    try testing.expectEqual(THREAD_NONE, s.threads[waiter].blocked_ep);
}

test "wakeBlockedRecv ignores threads on other endpoints" {
    var s = Scheduler{};
    const t0 = try s.spawn();
    _ = try s.spawn(); // t1

    _ = s.schedule();
    s.threads[t0].blocked_ep = 5; // blocked on endpoint 5
    s.blockCurrent();

    // Wake for endpoint 3 — should not wake t0
    s.wakeBlockedRecv(3);
    try testing.expectEqual(ThreadState.blocked, s.threads[t0].state);
}

test "reap is idempotent and count does not underflow" {
    var s = Scheduler{};
    const id = try s.spawn();
    try testing.expectEqual(@as(u32, 1), s.count);

    s.kill(id);
    s.reap(id);
    try testing.expectEqual(@as(u32, 0), s.count);

    // Second reap on now-free thread is a no-op
    s.reap(id);
    try testing.expectEqual(@as(u32, 0), s.count);
}

test "per-thread cap table and endpoint" {
    // Use thread ID 63 (last slot) to avoid collision with other tests
    const id: ThreadId = 63;
    const ct = getCapTable(id).?;
    const ep = getEndpoint(id).?;

    const cap_idx = try ct.create(.frame, 0x1000, cap.Rights.READ_ONLY);
    try testing.expect(ct.lookup(cap_idx) != null);

    const msg = ipc.Message.init(42, "hello");
    try ep.send(msg, null, null);

    const received = ep.recv(ipc.TAG_ANY).?;
    try testing.expectEqual(@as(u64, 42), received.tag);

    // Clean up
    ct.delete(cap_idx);
    _ = ep.recv(ipc.TAG_ANY);
}

test "wakeBlockedRecv wakes only one of multiple waiters" {
    var s = Scheduler{};
    const t0 = try s.spawn();
    const t1 = try s.spawn();
    const target_ep: ThreadId = 5; // arbitrary endpoint ID

    // Make both threads running then block both on the same endpoint
    _ = s.schedule(); // t0 running
    s.threads[t0].blocked_ep = target_ep;
    s.blockCurrent();
    _ = s.schedule(); // t1 running
    s.threads[t1].blocked_ep = target_ep;
    s.blockCurrent();

    try testing.expectEqual(ThreadState.blocked, s.threads[t0].state);
    try testing.expectEqual(ThreadState.blocked, s.threads[t1].state);

    // Wake — only the first should be unblocked
    s.wakeBlockedRecv(target_ep);
    try testing.expectEqual(ThreadState.ready, s.threads[t0].state);
    try testing.expectEqual(ThreadState.blocked, s.threads[t1].state);
}

test "kill current running thread does not resurrect on schedule" {
    var s = Scheduler{};
    const id = try s.spawn();
    _ = s.schedule(); // id is now .running, current = id
    try testing.expectEqual(ThreadState.running, s.threads[id].state);

    s.kill(id);
    try testing.expectEqual(ThreadState.dead, s.threads[id].state);

    // schedule() must not set dead thread back to ready
    const next = s.schedule();
    try testing.expect(next == null);
    try testing.expectEqual(ThreadState.dead, s.threads[id].state);
}

test "wakeBlockedRecv with no blocked threads is a no-op" {
    var s = Scheduler{};
    const t0 = try s.spawn();
    const t1 = try s.spawn();

    // Both threads are ready (not blocked)
    try testing.expectEqual(ThreadState.ready, s.threads[t0].state);
    try testing.expectEqual(ThreadState.ready, s.threads[t1].state);

    // Wake on an arbitrary endpoint — should change nothing
    s.wakeBlockedRecv(5);
    try testing.expectEqual(ThreadState.ready, s.threads[t0].state);
    try testing.expectEqual(ThreadState.ready, s.threads[t1].state);
}

test "schedule after kill of current finds newly-spawned thread" {
    var s = Scheduler{};
    const id = try s.spawn();
    _ = s.schedule(); // id running
    s.kill(id);

    const id2 = try s.spawn();
    const next = s.schedule().?;
    try testing.expectEqual(id2, next.id);
    try testing.expectEqual(ThreadState.running, next.state);
    try testing.expectEqual(ThreadState.dead, s.threads[id].state);
}

test "getThread returns non-null for dead slot" {
    // getThread only filters .free; callers must check .dead themselves.
    // This is intentional: reap/kill use getThread to inspect dead threads.
    var s = Scheduler{};
    const id = try s.spawn();
    s.kill(id);
    try testing.expectEqual(ThreadState.dead, s.threads[id].state);
    // getThread must not hide the dead thread from callers
    try testing.expect(s.getThread(id) != null);
}

test "schedule returns null when all threads are blocked" {
    var s = Scheduler{};
    const t0 = try s.spawn();
    const t1 = try s.spawn();

    _ = s.schedule(); // t0 running
    s.threads[t0].blocked_ep = 0;
    s.blockCurrent();
    _ = s.schedule(); // t1 running
    s.threads[t1].blocked_ep = 0;
    s.blockCurrent();

    // Both blocked — no thread available to schedule
    try testing.expect(s.schedule() == null);
}

test "unblock on non-blocked thread is a no-op" {
    var s = Scheduler{};
    const id = try s.spawn(); // .ready

    // Unblocking a ready thread should not change it
    s.unblock(id);
    try testing.expectEqual(ThreadState.ready, s.threads[id].state);

    // Unblocking a free slot should not crash
    s.unblock(5);
    try testing.expectEqual(ThreadState.free, s.threads[5].state);
}

test "blockCurrent is a no-op when no current thread" {
    var s = Scheduler{};
    _ = try s.spawn();
    // has_current starts false — blockCurrent must not modify any thread state
    try testing.expect(!s.has_current);
    s.blockCurrent(); // must not crash or change state
    try testing.expectEqual(ThreadState.ready, s.threads[0].state);
}

test "sequential wakeBlockedRecv drains all waiters in order" {
    var s = Scheduler{};
    const t0 = try s.spawn();
    const t1 = try s.spawn();
    const ep: ThreadId = 7;

    _ = s.schedule(); // t0 running
    s.threads[t0].blocked_ep = ep;
    s.blockCurrent();
    _ = s.schedule(); // t1 running
    s.threads[t1].blocked_ep = ep;
    s.blockCurrent();

    // First wake unblocks the first waiter found (t0, lowest index)
    s.wakeBlockedRecv(ep);
    try testing.expectEqual(ThreadState.ready, s.threads[t0].state);
    try testing.expectEqual(ThreadState.blocked, s.threads[t1].state);

    // Second wake unblocks the remaining waiter
    s.wakeBlockedRecv(ep);
    try testing.expectEqual(ThreadState.ready, s.threads[t0].state);
    try testing.expectEqual(ThreadState.ready, s.threads[t1].state);
}

test "spawn after table full and reap frees a slot" {
    var s = Scheduler{};
    // Fill the thread table
    for (0..MAX_THREADS) |_| {
        _ = try s.spawn();
    }
    try testing.expectError(error.ThreadTableFull, s.spawn());

    // Kill + reap thread 0 to open a slot
    s.kill(0);
    s.reap(0);
    try testing.expectEqual(ThreadState.free, s.threads[0].state);
    try testing.expectEqual(@as(u32, MAX_THREADS - 1), s.count);

    // Spawn should now succeed and reuse slot 0
    const new_id = try s.spawn();
    try testing.expectEqual(@as(ThreadId, 0), new_id);
    try testing.expectEqual(@as(u32, MAX_THREADS), s.count);
}

test "resetEndpoint clears messages and reopens closed endpoint" {
    const id = 0;
    // Start fresh
    resetEndpoint(id);
    const ep = getEndpoint(id).?;
    // Send a message and close
    try ep.send(ipc.Message.init(42, "hi"), null, null);
    ep.close();
    try testing.expect(ep.closed);
    try testing.expectEqual(@as(u32, 1), ep.count);

    // Reset should drain messages and reopen
    resetEndpoint(id);
    try testing.expect(!ep.closed);
    try testing.expectEqual(@as(u32, 0), ep.count);
    try testing.expect(ep.isEmpty());
    // After reset, new sends should succeed
    try ep.send(ipc.Message.init(99, "ok"), null, null);
    try testing.expectEqual(@as(u32, 1), ep.count);
}

test "resetEndpoint ignores out-of-range id" {
    // Must not crash
    resetEndpoint(MAX_THREADS);
    resetEndpoint(0xFFFFFFFF);
}

test "resetCapTable clears all slots and count" {
    const id = 0;
    resetCapTable(id);
    try testing.expectEqual(@as(u32, 0), cap_tables[id].count);
    for (cap_tables[id].slots) |slot| {
        try testing.expect(!slot.valid);
    }

    // Populate via resetCapTable + manual fill
    cap_tables[id].count = 3;
    cap_tables[id].slots[0].valid = true;
    cap_tables[id].slots[1].valid = true;

    resetCapTable(id);
    try testing.expectEqual(@as(u32, 0), cap_tables[id].count);
    try testing.expect(!cap_tables[id].slots[0].valid);
    try testing.expect(!cap_tables[id].slots[1].valid);
}
