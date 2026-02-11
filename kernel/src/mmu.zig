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
pub fn unmapPage(l0_table: *PageTable, vaddr: VirtAddr) void {
    const l0_idx = (vaddr >> 39) & 0x1FF;
    const l1_idx = (vaddr >> 30) & 0x1FF;
    const l2_idx = (vaddr >> 21) & 0x1FF;
    const l3_idx = (vaddr >> 12) & 0x1FF;

    const l1_table: *PageTable = @ptrFromInt((l0_table[l0_idx].output_pa << 12));
    const l2_table: *PageTable = @ptrFromInt((l1_table[l1_idx].output_pa << 12));
    const l3_table: *PageTable = @ptrFromInt((l2_table[l2_idx].output_pa << 12));

    l3_table[l3_idx].valid = 0;
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

    /// Free a physical frame.
    pub fn freeFrame(self: *FrameAllocator, paddr: PhysAddr) void {
        const frame_idx = paddr / PAGE_SIZE;
        const byte_idx = frame_idx / 64;
        const bit_idx: u6 = @truncate(frame_idx % 64);
        self.bitmap[byte_idx] &= ~(@as(u64, 1) << bit_idx);
        self.used -= 1;
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
