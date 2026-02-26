// LibOS IPC helpers
//
// High-level wrappers over raw IPC syscalls for common messaging patterns.

const sys = @import("syscall.zig");

pub const MAX_PAYLOAD = 256;
/// Tag filter value that matches any message tag (kernel treats 0 as wildcard).
pub const TAG_ANY: u64 = 0;

/// Send a byte-slice message on an endpoint capability.
pub fn send(ep_cap: u32, data: []const u8) i64 {
    return sys.ipcSend(ep_cap, data.ptr, data.len);
}

/// Send a tagged message.
pub fn sendTagged(ep_cap: u32, tag: u64, data: []const u8) i64 {
    return sys.ipcSendWithTag(ep_cap, data.ptr, data.len, tag);
}

/// Receive a message. Returns payload length and tag, or negative error.
pub fn recv(ep_cap: u32, buf: []u8) sys.RecvResult {
    return sys.ipcRecv(ep_cap, buf.ptr, TAG_ANY);
}

/// Receive with tag filter (selective receive).
pub fn recvTagged(ep_cap: u32, tag: u64, buf: []u8) sys.RecvResult {
    return sys.ipcRecv(ep_cap, buf.ptr, tag);
}

/// Create an endpoint capability for the calling thread.
pub fn createEndpoint() i64 {
    return sys.epCreate();
}

/// Grant an endpoint to another thread (requires grant right on both caps).
pub fn grantEndpoint(ep_cap: u32, thread_cap: u32) i64 {
    return sys.epGrant(ep_cap, thread_cap);
}

/// Send a message with a capability transfer. The cap is atomically moved
/// from sender to receiver. Requires grant right on cap_to_send.
pub fn sendWithCap(ep_cap: u32, data: []const u8, cap_to_send: u32) i64 {
    return sys.ipcSendCap(ep_cap, data.ptr, data.len, cap_to_send);
}

/// Receive a message and any transferred capability.
/// Returns payload_len and cap_idx (CAP_NULL = 0xFFFFFFFF if no cap).
pub fn recvWithCap(ep_cap: u32, buf: []u8) sys.RecvCapResult {
    return sys.ipcRecvCap(ep_cap, buf.ptr, TAG_ANY);
}

/// Receive with tag filter, also retrieving any transferred capability.
pub fn recvTaggedWithCap(ep_cap: u32, tag: u64, buf: []u8) sys.RecvCapResult {
    return sys.ipcRecvCap(ep_cap, buf.ptr, tag);
}

// ─── Blocking variants ─────────────────────────────────────────────
// These block the calling thread until a message arrives or the endpoint
// is closed (E_CLOSED). Preferred for supervisor-style receive loops.

/// Blocking receive. Sleeps until a message arrives.
/// Returns E_CLOSED if the endpoint is closed and empty.
pub fn recvBlocking(ep_cap: u32, buf: []u8) sys.RecvResult {
    return sys.ipcRecvBlock(ep_cap, buf.ptr, TAG_ANY);
}

/// Blocking receive with tag filter.
pub fn recvTaggedBlocking(ep_cap: u32, tag: u64, buf: []u8) sys.RecvResult {
    return sys.ipcRecvBlock(ep_cap, buf.ptr, tag);
}

/// Blocking receive with capability transfer.
/// Returns E_CLOSED if the endpoint is closed and empty.
pub fn recvWithCapBlocking(ep_cap: u32, buf: []u8) sys.RecvCapResult {
    return sys.ipcRecvCapBlock(ep_cap, buf.ptr, TAG_ANY);
}

/// Blocking receive with tag filter and capability transfer.
pub fn recvTaggedWithCapBlocking(ep_cap: u32, tag: u64, buf: []u8) sys.RecvCapResult {
    return sys.ipcRecvCapBlock(ep_cap, buf.ptr, tag);
}
