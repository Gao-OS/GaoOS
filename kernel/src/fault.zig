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
