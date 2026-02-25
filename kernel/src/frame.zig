// Physical Frame Allocator
//
// Bitmap-based allocator managing the user-space memory pool.
// All state is statically allocated — no heap, no hidden allocations.
//
// Pool: 0x400000–0x3FFFFFF (~60MB, 15104 frames of 4KB each).
// The first 4MB is reserved for page tables, kernel image, and initial user program.

pub const FRAME_SIZE: u64 = 4096;
pub const USER_POOL_START: u64 = 0x400000;
pub const USER_POOL_END: u64 = 0x3FFFFFF;
pub const TOTAL_FRAMES: u32 = @intCast((USER_POOL_END - USER_POOL_START + 1) / FRAME_SIZE);

const BITMAP_LEN: u32 = (TOTAL_FRAMES + 63) / 64;

pub const FrameAllocator = struct {
    bitmap: [BITMAP_LEN]u64,
    free_count: u32,

    pub fn init() FrameAllocator {
        return .{
            .bitmap = [_]u64{0} ** BITMAP_LEN,
            .free_count = TOTAL_FRAMES,
        };
    }

    /// Allocate a single 4KB frame. Returns the physical address.
    pub fn alloc(self: *FrameAllocator) error{OutOfMemory}!u64 {
        for (&self.bitmap, 0..) |*word, wi| {
            if (word.* == ~@as(u64, 0)) continue; // all bits set = all allocated

            // Find first zero bit
            const free_bits = ~word.*;
            const bit: u6 = @intCast(@ctz(free_bits));
            const frame_idx: u32 = @intCast(wi * 64 + bit);

            if (frame_idx >= TOTAL_FRAMES) return error.OutOfMemory;

            word.* |= @as(u64, 1) << bit;
            self.free_count -= 1;
            return USER_POOL_START + @as(u64, frame_idx) * FRAME_SIZE;
        }
        return error.OutOfMemory;
    }

    /// Free a previously allocated frame.
    pub fn free(self: *FrameAllocator, paddr: u64) error{InvalidFrame}!void {
        const idx = addrToIndex(paddr) orelse return error.InvalidFrame;
        const word_idx = idx / 64;
        const bit: u6 = @intCast(idx % 64);
        const mask = @as(u64, 1) << bit;

        // Double-free check: bit must be set
        if (self.bitmap[word_idx] & mask == 0) return error.InvalidFrame;

        self.bitmap[word_idx] &= ~mask;
        self.free_count += 1;
    }

    /// Check if a frame at the given address is currently allocated.
    pub fn isAllocated(self: *const FrameAllocator, paddr: u64) bool {
        const idx = addrToIndex(paddr) orelse return false;
        const word_idx = idx / 64;
        const bit: u6 = @intCast(idx % 64);
        return (self.bitmap[word_idx] & (@as(u64, 1) << bit)) != 0;
    }
};

/// Convert a physical address to a frame index, validating range and alignment.
fn addrToIndex(paddr: u64) ?u32 {
    if (paddr < USER_POOL_START) return null;
    if (paddr > USER_POOL_END) return null;
    if (paddr & (FRAME_SIZE - 1) != 0) return null; // not aligned
    return @intCast((paddr - USER_POOL_START) / FRAME_SIZE);
}

pub var global: FrameAllocator = FrameAllocator.init();

// ─── Tests ──────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "alloc returns valid frame address" {
    var fa = FrameAllocator.init();
    const addr = try fa.alloc();

    try testing.expect(addr >= USER_POOL_START);
    try testing.expect(addr <= USER_POOL_END);
    try testing.expect(addr & (FRAME_SIZE - 1) == 0); // page-aligned
    try testing.expectEqual(TOTAL_FRAMES - 1, fa.free_count);
}

test "alloc exhausts pool" {
    var fa = FrameAllocator.init();
    for (0..TOTAL_FRAMES) |_| {
        _ = try fa.alloc();
    }
    try testing.expectEqual(@as(u32, 0), fa.free_count);
    try testing.expectError(error.OutOfMemory, fa.alloc());
}

test "free and realloc" {
    var fa = FrameAllocator.init();
    const addr = try fa.alloc();
    try fa.free(addr);
    try testing.expectEqual(TOTAL_FRAMES, fa.free_count);

    const addr2 = try fa.alloc();
    try testing.expectEqual(addr, addr2); // reuses same frame
}

test "free invalid address" {
    var fa = FrameAllocator.init();

    // Out of range
    try testing.expectError(error.InvalidFrame, fa.free(0x0));
    try testing.expectError(error.InvalidFrame, fa.free(0x100000));
    // Unaligned
    try testing.expectError(error.InvalidFrame, fa.free(USER_POOL_START + 1));
}

test "double free" {
    var fa = FrameAllocator.init();
    const addr = try fa.alloc();
    try fa.free(addr);
    try testing.expectError(error.InvalidFrame, fa.free(addr));
}

test "isAllocated reports correctly" {
    var fa = FrameAllocator.init();
    const addr = try fa.alloc();

    try testing.expect(fa.isAllocated(addr));
    try fa.free(addr);
    try testing.expect(!fa.isAllocated(addr));

    // Invalid address
    try testing.expect(!fa.isAllocated(0x0));
}

test "alloc returns distinct addresses" {
    var fa = FrameAllocator.init();
    const a1 = try fa.alloc();
    const a2 = try fa.alloc();
    const a3 = try fa.alloc();

    try testing.expect(a1 != a2);
    try testing.expect(a2 != a3);
    try testing.expect(a1 != a3);

    // All should be page-aligned and in range
    for ([_]u64{ a1, a2, a3 }) |addr| {
        try testing.expect(addr >= USER_POOL_START);
        try testing.expect(addr <= USER_POOL_END);
        try testing.expect(addr & (FRAME_SIZE - 1) == 0);
    }
}

test "free at pool boundaries" {
    var fa = FrameAllocator.init();

    // Allocate first frame (should be at USER_POOL_START)
    const first = try fa.alloc();
    try testing.expectEqual(USER_POOL_START, first);
    try fa.free(first);

    // Free at exact pool boundary addresses (but out-of-range)
    try testing.expectError(error.InvalidFrame, fa.free(USER_POOL_START - FRAME_SIZE));
    // Address just past pool end (aligned)
    const past_end = (USER_POOL_END + 1 + FRAME_SIZE - 1) & ~(FRAME_SIZE - 1);
    try testing.expectError(error.InvalidFrame, fa.free(past_end));
}
