// LibOS IPC helpers
//
// High-level wrappers over raw IPC syscalls for common messaging patterns.

const sys = @import("syscall.zig");

pub const MAX_PAYLOAD = 256;
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
