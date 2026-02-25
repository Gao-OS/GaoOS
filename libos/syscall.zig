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
