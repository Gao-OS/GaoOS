// Fault Notification Protocol
//
// When a thread dies, the kernel sends a structured fault message to its
// supervisor's IPC endpoint. This is the foundation for BEAM-style supervision
// trees — a supervisor can receive fault notifications using selective receive
// on the distinguished FAULT_TAG.
//
// Fault notification is best-effort: if the supervisor's endpoint is full or
// closed, the notification is silently dropped. The kernel never blocks waiting
// for a supervisor to receive.

const ipc = @import("ipc");
const sched = @import("sched");

/// Distinguished tag for fault notification messages.
/// Supervisors use selective receive on this tag to separate fault
/// notifications from normal messages.
pub const FAULT_TAG: u64 = 0xDEAD_DEAD_DEAD_DEAD;

/// Why a thread died.
pub const Reason = enum(u8) {
    exit = 0, // Thread called SYS_EXIT
    killed = 1, // Supervisor called kill
    exception = 2, // Unhandled exception (data abort, undefined, etc.)
    cap_violation = 3, // Capability check failed in kernel
};

/// Fault notification payload — fits in a single IPC message.
/// Uses extern layout for stable serialization.
pub const FaultMsg = extern struct {
    reason: u8,
    pad: [3]u8,
    thread_id: u32,
    fault_addr: u64,
    esr: u64, // Exception Syndrome Register value (0 for non-exception faults)
};

comptime {
    if (@sizeOf(FaultMsg) > ipc.MAX_PAYLOAD)
        @compileError("FaultMsg exceeds IPC payload limit");
}

/// Send a fault notification to a specific IPC endpoint.
/// Called with the supervisor's endpoint. If the queue is full or closed,
/// the notification is silently dropped.
pub fn notifyEndpoint(
    ep: *ipc.Endpoint,
    reason: Reason,
    thread_id: sched.ThreadId,
    fault_addr: u64,
    esr: u64,
) void {
    const fault_data = FaultMsg{
        .reason = @intFromEnum(reason),
        .pad = .{ 0, 0, 0 },
        .thread_id = thread_id,
        .fault_addr = fault_addr,
        .esr = esr,
    };

    var msg = ipc.Message{ .tag = FAULT_TAG };
    const src: [*]const u8 = @ptrCast(&fault_data);
    for (0..@sizeOf(FaultMsg)) |i| {
        msg.payload[i] = src[i];
    }
    msg.payload_len = @intCast(@sizeOf(FaultMsg));

    ep.send(msg, null, null) catch {};
}

/// Notify a thread's supervisor (if any) of its death.
/// Must be called BEFORE sched.kill() while the thread is still alive.
/// No-op if the thread has no supervisor or if the supervisor endpoint
/// is full or closed.
pub fn notify(
    thread_id: sched.ThreadId,
    reason: Reason,
    fault_addr: u64,
    esr: u64,
) void {
    const thread = sched.global.getThread(thread_id) orelse return;
    const sup_ep_idx = thread.supervisor_ep;
    if (sup_ep_idx == 0xFFFFFFFF) return;

    const ep = sched.getEndpoint(sup_ep_idx) orelse return;
    notifyEndpoint(ep, reason, thread_id, fault_addr, esr);
}

// ─── Tests ──────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "FaultMsg fits in IPC payload" {
    try testing.expect(@sizeOf(FaultMsg) <= ipc.MAX_PAYLOAD);
}

test "fault message round-trips through IPC endpoint" {
    var ep = ipc.Endpoint{};

    notifyEndpoint(&ep, .exception, 7, 0x200500, 0x9200001F);

    const received = ep.recv(ipc.TAG_ANY).?;
    try testing.expectEqual(FAULT_TAG, received.tag);
    try testing.expectEqual(@as(u32, @sizeOf(FaultMsg)), received.payload_len);

    // Deserialize
    var copy: FaultMsg = undefined;
    const dst: [*]u8 = @ptrCast(&copy);
    for (0..@sizeOf(FaultMsg)) |i| {
        dst[i] = received.payload[i];
    }
    try testing.expectEqual(@as(u8, @intFromEnum(Reason.exception)), copy.reason);
    try testing.expectEqual(@as(u32, 7), copy.thread_id);
    try testing.expectEqual(@as(u64, 0x200500), copy.fault_addr);
    try testing.expectEqual(@as(u64, 0x9200001F), copy.esr);
}

test "notify with closed endpoint is silent" {
    var ep = ipc.Endpoint{};
    ep.close();
    // Must not crash even with closed endpoint
    notifyEndpoint(&ep, .exit, 0, 0, 0);
    try testing.expect(ep.isEmpty());
}

test "notify with full endpoint drops silently" {
    var ep = ipc.Endpoint{};
    // Fill the queue
    for (0..ipc.QUEUE_SIZE) |_| {
        try ep.send(ipc.Message.init(1, "fill"), null, null);
    }
    const before = ep.count;
    notifyEndpoint(&ep, .exit, 5, 0, 0);
    // Count unchanged — notification dropped
    try testing.expectEqual(before, ep.count);
}

test "notify sends fault to valid supervisor" {
    // Reset scheduler state for this test
    sched.global = .{};

    const sup_id = try sched.global.spawn(); // thread 0 = supervisor
    const child_id = try sched.global.spawn(); // thread 1 = child

    // Set child's supervisor endpoint to supervisor's endpoint index
    sched.global.threads[child_id].supervisor_ep = sup_id;

    // Notify via the top-level notify() which looks up the thread → endpoint chain
    notify(child_id, .exit, 0, 0);

    // The fault message should arrive at supervisor's endpoint
    const ep = sched.getEndpoint(sup_id).?;
    const received = ep.recv(FAULT_TAG);
    try testing.expect(received != null);
    const msg = received.?;
    try testing.expectEqual(FAULT_TAG, msg.tag);

    // Deserialize and verify thread_id
    var fm: FaultMsg = undefined;
    const dst: [*]u8 = @ptrCast(&fm);
    for (0..@sizeOf(FaultMsg)) |i| {
        dst[i] = msg.payload[i];
    }
    try testing.expectEqual(child_id, fm.thread_id);
    try testing.expectEqual(@as(u8, @intFromEnum(Reason.exit)), fm.reason);

    // Cleanup
    sched.global.kill(sup_id);
    sched.global.reap(sup_id);
    sched.global.kill(child_id);
    sched.global.reap(child_id);
}

test "fault reason killed serializes correctly" {
    var ep = ipc.Endpoint{};
    notifyEndpoint(&ep, .killed, 3, 0, 0);

    const received = ep.recv(FAULT_TAG).?;
    var copy: FaultMsg = undefined;
    const dst: [*]u8 = @ptrCast(&copy);
    for (0..@sizeOf(FaultMsg)) |i| {
        dst[i] = received.payload[i];
    }
    try testing.expectEqual(@as(u8, @intFromEnum(Reason.killed)), copy.reason);
    try testing.expectEqual(@as(u32, 3), copy.thread_id);
    try testing.expectEqual(@as(u64, 0), copy.fault_addr);
}

test "notify with out-of-range thread_id is silent" {
    sched.global = .{};

    // thread_id 999 is way beyond MAX_THREADS — should not crash
    notify(999, .exception, 0xDEAD, 0);

    // No endpoint should have received anything
    const ep = sched.getEndpoint(0).?;
    try testing.expect(ep.recv(ipc.TAG_ANY) == null);
}

test "notify with out-of-range supervisor_ep is silent" {
    sched.global = .{};

    const id = try sched.global.spawn();
    // Set supervisor_ep to a valid-looking but out-of-range value
    sched.global.threads[id].supervisor_ep = sched.MAX_THREADS + 10;

    // Should silently return — getEndpoint returns null for out-of-range
    notify(id, .killed, 0, 0);

    // Thread's own endpoint should be empty
    const ep = sched.getEndpoint(id).?;
    try testing.expect(ep.recv(ipc.TAG_ANY) == null);

    sched.global.kill(id);
    sched.global.reap(id);
}

test "fault reason cap_violation serializes correctly" {
    var ep = ipc.Endpoint{};
    notifyEndpoint(&ep, .cap_violation, 42, 0xCAFE_BAD0, 0x9600_0004);

    const received = ep.recv(FAULT_TAG).?;
    var copy: FaultMsg = undefined;
    const dst: [*]u8 = @ptrCast(&copy);
    for (0..@sizeOf(FaultMsg)) |i| {
        dst[i] = received.payload[i];
    }
    try testing.expectEqual(@as(u8, @intFromEnum(Reason.cap_violation)), copy.reason);
    try testing.expectEqual(@as(u32, 42), copy.thread_id);
    try testing.expectEqual(@as(u64, 0xCAFE_BAD0), copy.fault_addr);
    try testing.expectEqual(@as(u64, 0x9600_0004), copy.esr);
}

test "fault reason exit serializes correctly" {
    var ep = ipc.Endpoint{};
    notifyEndpoint(&ep, .exit, 1, 0xABCD, 0);

    const received = ep.recv(FAULT_TAG).?;
    var copy: FaultMsg = undefined;
    const dst: [*]u8 = @ptrCast(&copy);
    for (0..@sizeOf(FaultMsg)) |i| {
        dst[i] = received.payload[i];
    }
    try testing.expectEqual(@as(u8, @intFromEnum(Reason.exit)), copy.reason);
    try testing.expectEqual(@as(u32, 1), copy.thread_id);
    try testing.expectEqual(@as(u64, 0xABCD), copy.fault_addr);
    try testing.expectEqual(@as(u64, 0), copy.esr);
}

test "fault reason exception serializes correctly" {
    var ep = ipc.Endpoint{};
    notifyEndpoint(&ep, .exception, 15, 0xF00D_CAFE, 0x9600_0048);

    const received = ep.recv(FAULT_TAG).?;
    var copy: FaultMsg = undefined;
    const dst: [*]u8 = @ptrCast(&copy);
    for (0..@sizeOf(FaultMsg)) |i| {
        dst[i] = received.payload[i];
    }
    try testing.expectEqual(@as(u8, @intFromEnum(Reason.exception)), copy.reason);
    try testing.expectEqual(@as(u32, 15), copy.thread_id);
    try testing.expectEqual(@as(u64, 0xF00D_CAFE), copy.fault_addr);
    try testing.expectEqual(@as(u64, 0x9600_0048), copy.esr);
}

test "notify skips thread with no supervisor" {
    sched.global = .{};

    const id = try sched.global.spawn();
    // supervisor_ep defaults to 0xFFFFFFFF (none)
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), sched.global.threads[id].supervisor_ep);

    // This should be a no-op — no crash, no message sent anywhere
    notify(id, .killed, 0xDEAD, 0);

    // The thread's own endpoint should be empty (no self-notification)
    const ep = sched.getEndpoint(id).?;
    try testing.expect(ep.recv(ipc.TAG_ANY) == null);

    sched.global.kill(id);
    sched.global.reap(id);
}
