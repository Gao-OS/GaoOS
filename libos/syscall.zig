// Raw syscall wrappers — inline SVC for AArch64
//
// Convention: x8 = syscall number, x0-x5 = args, x0 = return value.

pub fn write(cap_idx: u32, buf: [*]const u8, len: usize) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, cap_idx)),
          [x1] "{x1}" (@intFromPtr(buf)),
          [x2] "{x2}" (@as(u64, len)),
          [x8] "{x8}" (@as(u64, 0)),
        : .{ .memory = true }
    );
}

pub fn exit() noreturn {
    asm volatile ("svc #0"
        :
        : [x8] "{x8}" (@as(u64, 1)),
        : .{ .memory = true }
    );
    unreachable;
}

pub fn yield() void {
    asm volatile ("svc #0"
        :
        : [x8] "{x8}" (@as(u64, 2)),
        : .{ .memory = true }
    );
}

pub fn capRead(cap_idx: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, cap_idx)),
          [x8] "{x8}" (@as(u64, 3)),
        : .{ .memory = true }
    );
}

pub fn frameAlloc() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x8] "{x8}" (@as(u64, 4)),
        : .{ .memory = true }
    );
}

pub fn frameFree(cap_idx: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, cap_idx)),
          [x8] "{x8}" (@as(u64, 5)),
        : .{ .memory = true }
    );
}

pub fn capDerive(src: u32, rights: u8) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, src)),
          [x1] "{x1}" (@as(u64, rights)),
          [x8] "{x8}" (@as(u64, 6)),
        : .{ .memory = true }
    );
}

pub fn capDelete(cap_idx: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, cap_idx)),
          [x8] "{x8}" (@as(u64, 7)),
        : .{ .memory = true }
    );
}

pub fn framePhys(cap_idx: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, cap_idx)),
          [x8] "{x8}" (@as(u64, 8)),
        : .{ .memory = true }
    );
}

// ─── IPC syscalls ────────────────────────────────────────────────

pub fn ipcSend(ep_cap: u32, buf: [*]const u8, len: usize) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, ep_cap)),
          [x1] "{x1}" (@intFromPtr(buf)),
          [x2] "{x2}" (@as(u64, len)),
          [x8] "{x8}" (@as(u64, 9)),
        : .{ .memory = true }
    );
}

pub const RecvResult = struct {
    payload_len: i64,
    tag: u64,
};

pub fn ipcRecv(ep_cap: u32, buf: [*]u8, tag_filter: u64) RecvResult {
    var len: i64 = undefined;
    var tag: u64 = undefined;
    asm volatile ("svc #0"
        : [x0] "={x0}" (len),
          [x1] "={x1}" (tag),
        : [arg0] "{x0}" (@as(u64, ep_cap)),
          [arg1] "{x1}" (@intFromPtr(buf)),
          [arg2] "{x2}" (tag_filter),
          [x8] "{x8}" (@as(u64, 10)),
        : .{ .memory = true }
    );
    return .{ .payload_len = len, .tag = tag };
}

pub fn epCreate() i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x8] "{x8}" (@as(u64, 11)),
        : .{ .memory = true }
    );
}

pub fn threadCreate(entry_pc: u64, stack_ptr: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (entry_pc),
          [x1] "{x1}" (stack_ptr),
          [x8] "{x8}" (@as(u64, 12)),
        : .{ .memory = true }
    );
}

pub fn threadGrant(thread_cap: u32, cap_idx: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, thread_cap)),
          [x1] "{x1}" (@as(u64, cap_idx)),
          [x8] "{x8}" (@as(u64, 13)),
        : .{ .memory = true }
    );
}

pub fn ipcSendWithTag(ep_cap: u32, buf: [*]const u8, len: usize, tag: u64) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, ep_cap)),
          [x1] "{x1}" (@intFromPtr(buf)),
          [x2] "{x2}" (@as(u64, len)),
          [x3] "{x3}" (tag),
          [x8] "{x8}" (@as(u64, 14)),
        : .{ .memory = true }
    );
}

pub fn epGrant(ep_cap: u32, thread_cap: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, ep_cap)),
          [x1] "{x1}" (@as(u64, thread_cap)),
          [x8] "{x8}" (@as(u64, 15)),
        : .{ .memory = true }
    );
}

pub fn supervisorSet(thread_cap: u32, ep_cap: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, thread_cap)),
          [x1] "{x1}" (@as(u64, ep_cap)),
          [x8] "{x8}" (@as(u64, 16)),
        : .{ .memory = true }
    );
}

pub const RecvCapResult = struct {
    payload_len: i64,
    cap_idx: u32, // CAP_NULL (0xFFFFFFFF) if no cap transferred
};

pub fn ipcSendCap(ep_cap: u32, buf: [*]const u8, len: usize, cap_to_send: u32) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (@as(u64, ep_cap)),
          [x1] "{x1}" (@intFromPtr(buf)),
          [x2] "{x2}" (@as(u64, len)),
          [x3] "{x3}" (@as(u64, cap_to_send)),
          [x8] "{x8}" (@as(u64, 17)),
        : .{ .memory = true }
    );
}

pub fn ipcRecvCap(ep_cap: u32, buf: [*]u8, tag_filter: u64) RecvCapResult {
    var len: i64 = undefined;
    var cap_val: u64 = undefined;
    asm volatile ("svc #0"
        : [x0] "={x0}" (len),
          [x1] "={x1}" (cap_val),
        : [arg0] "{x0}" (@as(u64, ep_cap)),
          [arg1] "{x1}" (@intFromPtr(buf)),
          [arg2] "{x2}" (tag_filter),
          [x8] "{x8}" (@as(u64, 18)),
        : .{ .memory = true }
    );
    return .{ .payload_len = len, .cap_idx = @truncate(cap_val) };
}
