// LibOS fault message parsing
//
// User-space representation of kernel fault notifications.
// Supervisors receive these via selective receive on FAULT_TAG.

/// Distinguished IPC tag for fault notifications (matches kernel's FAULT_TAG).
pub const FAULT_TAG: u64 = 0xDEAD_DEAD_DEAD_DEAD;

/// Why a thread died.
pub const Reason = enum(u8) {
    exit = 0,
    killed = 1,
    exception = 2,
    cap_violation = 3,
    _,
};

/// Fault notification payload serialized in an IPC message.
pub const FaultMsg = extern struct {
    reason: u8,
    pad: [3]u8,
    thread_id: u32,
    fault_addr: u64,
    esr: u64,
};

/// Parse a fault message from a raw IPC payload buffer.
/// Returns null if the buffer is too small to contain a FaultMsg.
pub fn parse(buf: []const u8) ?FaultMsg {
    if (buf.len < @sizeOf(FaultMsg)) return null;
    var msg: FaultMsg = undefined;
    const dst: [*]u8 = @ptrCast(&msg);
    for (0..@sizeOf(FaultMsg)) |i| {
        dst[i] = buf[i];
    }
    return msg;
}

/// Extract the reason enum from a FaultMsg.
pub fn reasonOf(msg: FaultMsg) Reason {
    return @enumFromInt(msg.reason);
}
