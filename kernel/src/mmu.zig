// ARMv8 Page Table Management
//
// 4KB granule, 4-level page tables (L0-L3, aka PGD-PTE).
// Each level has 512 entries (9 bits per level), supporting 48-bit VA.
// Entry format: bit 0 = valid, bit 1 = type (0=table, 1=block/page),
// bits [47:12] = output address, bits [11:2] = attributes.

const std = @import("std");

pub const VA_BITS = 48;
pub const PAGE_BITS = 12; // 4KB pages
pub const PAGE_SIZE = 1 << PAGE_BITS;
pub const ENTRIES_PER_TABLE = 512; // 2^9
pub const PAGE_TABLE_SIZE = ENTRIES_PER_TABLE * @sizeOf(u64);

/// Physical address of a memory frame (must be page-aligned).
pub const PhysAddr = u64;

/// Virtual address.
pub const VirtAddr = u64;

/// Page table entry: bits [51:12] = PA, bits [11:0] = attributes.
pub const PageTableEntry = packed struct {
    valid: u1,           // Bit 0: Entry valid
    type_table: u1,      // Bit 1: 0 = block/page, 1 = table
    attr_index: u3,      // Bits [4:2]: MAIR index
    ns: u1,              // Bit 5: Non-secure
    ap: u2,              // Bits [7:6]: Access perms (0=none, 1=EL1 only, 2=RW any, 3=RO any)
    sh: u2,              // Bits [9:8]: Shareability
    af: u1,              // Bit 10: Access flag
    ng: u1,              // Bit 11: Not global
    output_pa: u52,      // Bits [63:12]: Physical address / next table
};

comptime {
    if (@sizeOf(PageTableEntry) != 8) @compileError("PageTableEntry must be 8 bytes");
}

/// A single page table (512 entries).
pub const PageTable = [ENTRIES_PER_TABLE]PageTableEntry;

/// Allocator interface for page table operations.
pub const Allocator = struct {
    allocFn: *const fn (*anyopaque) anyerror!PhysAddr,
    ptr: *anyopaque,

    fn alloc(self: Allocator) !PhysAddr {
        return self.allocFn(self.ptr);
    }
};

/// Map a single 4KB page in the page table hierarchy.
/// If intermediate tables don't exist, creates them at the first frame from allocator.
pub fn mapPage(
    l0_table: *PageTable,
    vaddr: VirtAddr,
    paddr: PhysAddr,
    allocator: Allocator,
    flags: PageTableEntry,
) !void {
    // Extract indices from virtual address: [47:39]=L0, [38:30]=L1, [29:21]=L2, [20:12]=L3
    const l0_idx = (vaddr >> 39) & 0x1FF;
    const l1_idx = (vaddr >> 30) & 0x1FF;
    const l2_idx = (vaddr >> 21) & 0x1FF;
    const l3_idx = (vaddr >> 12) & 0x1FF;

    // Navigate/create L1 table
    const l1_entry = &l0_table[l0_idx];
    var l1_table: *PageTable = if (l1_entry.valid == 1) blk: {
        // Existing table
        break :blk @ptrFromInt(l1_entry.output_pa << 12);
    } else blk: {
        // Create new table
        const new_frame = try allocator.alloc();
        const table: *PageTable = @ptrFromInt(new_frame);
        @memset(std.mem.asBytes(table), 0);
        l1_entry.* = .{
            .valid = 1,
            .type_table = 1,
            .attr_index = 0,
            .ns = 0,
            .ap = 0,
            .sh = 0,
            .af = 1,
            .ng = 0,
            .output_pa = @truncate((new_frame >> 12) & 0xFFFFFFFFFFFFF),
        };
        break :blk table;
    };

    // Navigate/create L2 table (same pattern)
    const l2_entry = &l1_table[l1_idx];
    var l2_table: *PageTable = if (l2_entry.valid == 1) blk: {
        break :blk @ptrFromInt(l2_entry.output_pa << 12);
    } else blk: {
        const new_frame = try allocator.alloc();
        const table: *PageTable = @ptrFromInt(new_frame);
        @memset(std.mem.asBytes(table), 0);
        l2_entry.* = .{
            .valid = 1,
            .type_table = 1,
            .attr_index = 0,
            .ns = 0,
            .ap = 0,
            .sh = 0,
            .af = 1,
            .ng = 0,
            .output_pa = @truncate((new_frame >> 12) & 0xFFFFFFFFFFFFF),
        };
        break :blk table;
    };

    // Insert final page entry at L3
    const l3_entry = &l2_table[l2_idx];
    var l3_table: *PageTable = if (l3_entry.valid == 1) blk: {
        break :blk @ptrFromInt(l3_entry.output_pa << 12);
    } else blk: {
        const new_frame = try allocator.alloc();
        const table: *PageTable = @ptrFromInt(new_frame);
        @memset(std.mem.asBytes(table), 0);
        l3_entry.* = .{
            .valid = 1,
            .type_table = 1,
            .attr_index = 0,
            .ns = 0,
            .ap = 0,
            .sh = 0,
            .af = 1,
            .ng = 0,
            .output_pa = @truncate((new_frame >> 12) & 0xFFFFFFFFFFFFF),
        };
        break :blk table;
    };

    // Map the page at L3
    l3_table[l3_idx] = .{
        .valid = 1,
        .type_table = 0,
        .attr_index = flags.attr_index,
        .ns = flags.ns,
        .ap = flags.ap,
        .sh = flags.sh,
        .af = 1,
        .ng = flags.ng,
        .output_pa = @truncate((paddr >> 12) & 0xFFFFFFFFFFFFF),
    };
}

/// Unmap a 4KB page (mark invalid). Intermediate tables are not freed.
/// Returns false if the page was not mapped (missing intermediate table).
pub fn unmapPage(l0_table: *PageTable, vaddr: VirtAddr) bool {
    const l0_idx = (vaddr >> 39) & 0x1FF;
    const l1_idx = (vaddr >> 30) & 0x1FF;
    const l2_idx = (vaddr >> 21) & 0x1FF;
    const l3_idx = (vaddr >> 12) & 0x1FF;

    if (l0_table[l0_idx].valid == 0) return false;
    const l1_table: *PageTable = @ptrFromInt(@as(u64, l0_table[l0_idx].output_pa) << 12);
    if (l1_table[l1_idx].valid == 0) return false;
    const l2_table: *PageTable = @ptrFromInt(@as(u64, l1_table[l1_idx].output_pa) << 12);
    if (l2_table[l2_idx].valid == 0) return false;
    const l3_table: *PageTable = @ptrFromInt(@as(u64, l2_table[l2_idx].output_pa) << 12);

    l3_table[l3_idx].valid = 0;
    return true;
}

/// Physical frame allocator: simple bitmap for contiguous physical memory.
pub const FrameAllocator = struct {
    bitmap: []u64, // One bit per 4KB frame
    used: usize, // Number of frames allocated

    /// Allocate a physical frame. Returns its physical address.
    pub fn allocFrame(self: *FrameAllocator) !PhysAddr {
        var byte_idx: usize = 0;
        while (byte_idx < self.bitmap.len) : (byte_idx += 1) {
            if (self.bitmap[byte_idx] != 0xFFFFFFFFFFFFFFFF) {
                // Found a free bit
                var bit_idx: u6 = 0;
                while (bit_idx < 64) : (bit_idx += 1) {
                    if ((self.bitmap[byte_idx] & (@as(u64, 1) << bit_idx)) == 0) {
                        self.bitmap[byte_idx] |= @as(u64, 1) << bit_idx;
                        const frame_idx = byte_idx * 64 + bit_idx;
                        self.used += 1;
                        return @as(u64, frame_idx) * PAGE_SIZE;
                    }
                }
            }
        }
        return error.OutOfMemory;
    }

    /// Free a physical frame. Validates bounds and double-free.
    pub fn freeFrame(self: *FrameAllocator, paddr: PhysAddr) void {
        const frame_idx = paddr / PAGE_SIZE;
        const byte_idx = frame_idx / 64;
        if (byte_idx >= self.bitmap.len) return;
        const bit_idx: u6 = @truncate(frame_idx % 64);
        const mask = @as(u64, 1) << bit_idx;
        if (self.bitmap[byte_idx] & mask == 0) return; // not allocated (double-free guard)
        self.bitmap[byte_idx] &= ~mask;
        if (self.used > 0) self.used -= 1;
    }
};

/// Initialize the frame allocator for a given memory region.
/// Marks frames 0 to reserved_frames as used (for kernel, boot tables, etc).
pub fn initFrameAllocator(
    allocator: std.mem.Allocator,
    total_bytes: u64,
    reserved_frames: usize,
) !FrameAllocator {
    const total_frames = total_bytes / PAGE_SIZE;
    const bitmap_size = (total_frames + 63) / 64; // Round up to 64-bit words

    const bitmap = try allocator.alloc(u64, bitmap_size);
    @memset(bitmap, 0);

    // Mark reserved frames as used
    var frame_idx: usize = 0;
    while (frame_idx < reserved_frames) : (frame_idx += 1) {
        const byte_idx = frame_idx / 64;
        const bit_idx: u6 = @truncate(frame_idx % 64);
        bitmap[byte_idx] |= @as(u64, 1) << bit_idx;
    }

    return FrameAllocator{
        .bitmap = bitmap,
        .used = reserved_frames,
    };
}

// ─── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "PageTableEntry is 8 bytes" {
    try testing.expectEqual(@as(usize, 8), @sizeOf(PageTableEntry));
}

test "PageTable is 4KB" {
    try testing.expectEqual(@as(usize, PAGE_SIZE), @sizeOf(PageTable));
}

test "frame allocator: alloc returns page-aligned addresses" {
    var fa = try initFrameAllocator(testing.allocator, 64 * PAGE_SIZE, 0);
    defer testing.allocator.free(fa.bitmap);

    const a0 = try fa.allocFrame();
    try testing.expectEqual(@as(u64, 0), a0);
    try testing.expectEqual(@as(usize, 1), fa.used);

    const a1 = try fa.allocFrame();
    try testing.expectEqual(@as(u64, PAGE_SIZE), a1);
}

test "frame allocator: reserved frames are skipped" {
    var fa = try initFrameAllocator(testing.allocator, 64 * PAGE_SIZE, 4);
    defer testing.allocator.free(fa.bitmap);

    try testing.expectEqual(@as(usize, 4), fa.used);

    const addr = try fa.allocFrame();
    try testing.expectEqual(@as(u64, 4 * PAGE_SIZE), addr);
}

test "frame allocator: exhaust and OOM" {
    // Use 64 frames (exactly one bitmap word) so exhaustion is detected
    var fa = try initFrameAllocator(testing.allocator, 64 * PAGE_SIZE, 0);
    defer testing.allocator.free(fa.bitmap);

    for (0..64) |_| {
        _ = try fa.allocFrame();
    }
    try testing.expectEqual(@as(usize, 64), fa.used);
    try testing.expectError(error.OutOfMemory, fa.allocFrame());
}

test "frame allocator: free and realloc" {
    var fa = try initFrameAllocator(testing.allocator, 64 * PAGE_SIZE, 0);
    defer testing.allocator.free(fa.bitmap);

    const a0 = try fa.allocFrame();
    const a1 = try fa.allocFrame();
    fa.freeFrame(a0);
    try testing.expectEqual(@as(usize, 1), fa.used);

    const a2 = try fa.allocFrame();
    try testing.expectEqual(a0, a2);
    _ = a1;
}

// Page-aligned table pool for testing mapPage/unmapPage.
// Tables must be page-aligned because mapPage stores (addr >> 12) in output_pa.
const TestTablePool = struct {
    // Allocate page-aligned tables via the page allocator
    tables: [8]?[]u8,
    next: usize,

    fn init() TestTablePool {
        return .{ .tables = .{null} ** 8, .next = 0 };
    }

    fn deinit(self: *TestTablePool) void {
        for (&self.tables) |*t| {
            if (t.*) |slice| {
                std.heap.page_allocator.free(slice);
                t.* = null;
            }
        }
    }

    fn allocTable(ctx: *anyopaque) anyerror!PhysAddr {
        const self: *TestTablePool = @alignCast(@ptrCast(ctx));
        if (self.next >= self.tables.len) return error.OutOfMemory;
        const mem = try std.heap.page_allocator.alloc(u8, PAGE_SIZE);
        @memset(mem, 0);
        self.tables[self.next] = mem;
        self.next += 1;
        return @intFromPtr(mem.ptr);
    }

    fn allocator(self: *TestTablePool) Allocator {
        return .{ .allocFn = &allocTable, .ptr = @ptrCast(self) };
    }
};

test "mapPage creates page table hierarchy" {
    var pool = TestTablePool.init();
    defer pool.deinit();

    const l0_mem = try std.heap.page_allocator.alloc(u8, PAGE_SIZE);
    defer std.heap.page_allocator.free(l0_mem);
    @memset(l0_mem, 0);
    const l0: *PageTable = @alignCast(@ptrCast(l0_mem.ptr));

    const flags = PageTableEntry{
        .valid = 1, .type_table = 0, .attr_index = 1, .ns = 0,
        .ap = 0, .sh = 3, .af = 1, .ng = 0, .output_pa = 0,
    };

    try mapPage(l0, 0x1000, 0x2000, pool.allocator(), flags);

    // Verify L0 entry is valid (points to L1)
    try testing.expectEqual(@as(u1, 1), l0[0].valid);
    try testing.expectEqual(@as(u1, 1), l0[0].type_table);

    // Walk to L3 and verify the final page entry
    const l1: *PageTable = @ptrFromInt(@as(u64, l0[0].output_pa) << 12);
    try testing.expectEqual(@as(u1, 1), l1[0].valid);
    const l2: *PageTable = @ptrFromInt(@as(u64, l1[0].output_pa) << 12);
    try testing.expectEqual(@as(u1, 1), l2[0].valid);
    const l3: *PageTable = @ptrFromInt(@as(u64, l2[0].output_pa) << 12);

    // VA 0x1000: L3 index = (0x1000 >> 12) & 0x1FF = 1
    const entry = l3[1];
    try testing.expectEqual(@as(u1, 1), entry.valid);
    try testing.expectEqual(@as(u3, 1), entry.attr_index);
    try testing.expectEqual(@as(u2, 3), entry.sh);
    try testing.expectEqual(@as(u64, 0x2000 >> 12), @as(u64, entry.output_pa) & 0xFFFFF);

    // 3 tables allocated (L1, L2, L3)
    try testing.expectEqual(@as(usize, 3), pool.next);
}

test "unmapPage invalidates entry" {
    var pool = TestTablePool.init();
    defer pool.deinit();

    const l0_mem = try std.heap.page_allocator.alloc(u8, PAGE_SIZE);
    defer std.heap.page_allocator.free(l0_mem);
    @memset(l0_mem, 0);
    const l0: *PageTable = @alignCast(@ptrCast(l0_mem.ptr));

    const flags = PageTableEntry{
        .valid = 1, .type_table = 0, .attr_index = 0, .ns = 0,
        .ap = 0, .sh = 0, .af = 1, .ng = 0, .output_pa = 0,
    };

    try mapPage(l0, 0x1000, 0x2000, pool.allocator(), flags);

    const l1: *PageTable = @ptrFromInt(@as(u64, l0[0].output_pa) << 12);
    const l2: *PageTable = @ptrFromInt(@as(u64, l1[0].output_pa) << 12);
    const l3: *PageTable = @ptrFromInt(@as(u64, l2[0].output_pa) << 12);
    try testing.expectEqual(@as(u1, 1), l3[1].valid);

    try testing.expect(unmapPage(l0, 0x1000));
    try testing.expectEqual(@as(u1, 0), l3[1].valid);
}

test "unmapPage returns false for unmapped address" {
    const l0_mem = try std.heap.page_allocator.alloc(u8, PAGE_SIZE);
    defer std.heap.page_allocator.free(l0_mem);
    @memset(l0_mem, 0);
    const l0: *PageTable = @alignCast(@ptrCast(l0_mem.ptr));

    // No pages mapped — should return false, not crash
    try testing.expect(!unmapPage(l0, 0x1000));
}

test "mapPage reuses existing intermediate tables" {
    var pool = TestTablePool.init();
    defer pool.deinit();

    const l0_mem = try std.heap.page_allocator.alloc(u8, PAGE_SIZE);
    defer std.heap.page_allocator.free(l0_mem);
    @memset(l0_mem, 0);
    const l0: *PageTable = @alignCast(@ptrCast(l0_mem.ptr));

    const flags = PageTableEntry{
        .valid = 1, .type_table = 0, .attr_index = 0, .ns = 0,
        .ap = 0, .sh = 0, .af = 1, .ng = 0, .output_pa = 0,
    };

    // Map two pages in the same L3 table (same L0/L1/L2 path)
    try mapPage(l0, 0x1000, 0x2000, pool.allocator(), flags);
    const after_first = pool.next;

    try mapPage(l0, 0x2000, 0x3000, pool.allocator(), flags);
    // No new tables should be allocated (same L1, L2, L3)
    try testing.expectEqual(after_first, pool.next);
}

test "freeFrame ignores out-of-bounds address" {
    var fa = try initFrameAllocator(testing.allocator, 64 * PAGE_SIZE, 0);
    defer testing.allocator.free(fa.bitmap);

    const a0 = try fa.allocFrame();
    _ = a0;
    try testing.expectEqual(@as(usize, 1), fa.used);

    // Free an address way past the end — should be silently ignored
    fa.freeFrame(99999 * PAGE_SIZE);
    try testing.expectEqual(@as(usize, 1), fa.used);
}

test "freeFrame double-free is silent" {
    var fa = try initFrameAllocator(testing.allocator, 64 * PAGE_SIZE, 0);
    defer testing.allocator.free(fa.bitmap);

    const a0 = try fa.allocFrame();
    fa.freeFrame(a0);
    try testing.expectEqual(@as(usize, 0), fa.used);

    // Double-free — should be silently ignored (not underflow)
    fa.freeFrame(a0);
    try testing.expectEqual(@as(usize, 0), fa.used);
}

test "mapPage returns error when allocator exhausted" {
    // Use TestTablePool (capacity 8). Map two pages in different L0 regions
    // to consume 6 slots (3 each). The 3rd path needs 3 more but only 2
    // remain — L3 allocation fails, returning error.OutOfMemory.
    var pool = TestTablePool.init();
    defer pool.deinit();

    const l0_mem = try std.heap.page_allocator.alloc(u8, PAGE_SIZE);
    defer std.heap.page_allocator.free(l0_mem);
    @memset(l0_mem, 0);
    const l0: *PageTable = @alignCast(@ptrCast(l0_mem.ptr));

    const flags = PageTableEntry{
        .valid = 1, .type_table = 0, .attr_index = 0, .ns = 0,
        .ap = 0, .sh = 0, .af = 1, .ng = 0, .output_pa = 0,
    };

    // L0 index = (vaddr >> 39) & 0x1FF
    // Path A: l0_idx=0, vaddr=0x10000 — uses pool slots 0,1,2 (L1,L2,L3)
    try mapPage(l0, 0x0000_0000_0001_0000, 0x2000, pool.allocator(), flags);
    // Path B: l0_idx=1, vaddr=2^39 — uses pool slots 3,4,5
    try mapPage(l0, 0x0000_0080_0000_0000, 0x3000, pool.allocator(), flags);
    try testing.expectEqual(@as(usize, 6), pool.next);

    // Path C: l0_idx=2, vaddr=2*2^39=2^40 — L1 uses slot 6, L2 uses slot 7, L3 hits OOM
    const result = mapPage(l0, 0x0000_0100_0000_0000, 0x4000, pool.allocator(), flags);
    try testing.expectError(error.OutOfMemory, result);
}
