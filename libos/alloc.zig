// Bump allocator over SYS_FRAME_ALLOC'd frames
//
// Phase 2 uses identity mapping (phys == virt), so the physical address
// from SYS_FRAME_PHYS is directly dereferenceable.

const sys = @import("syscall.zig");

pub const MAX_FRAMES = 256;

pub const BumpAllocator = struct {
    frames: [MAX_FRAMES]u32 = [_]u32{0} ** MAX_FRAMES,
    frame_count: u32 = 0,
    current_frame_phys: u64 = 0,
    offset: u32 = 0,

    pub fn init() BumpAllocator {
        return .{};
    }

    /// Allocate `size` bytes with the given alignment (must be power of 2).
    /// Returns a pointer to the allocated region, or null on failure.
    pub fn alloc(self: *BumpAllocator, size: u32, alignment: u32) ?[*]u8 {
        if (size == 0) return null;

        const align_val = if (alignment > 0) alignment else 1;
        // Alignment must be a power of 2
        if (align_val & (align_val - 1) != 0) return null;
        const align_mask = align_val - 1;

        // Try to fit in current frame
        if (self.current_frame_phys != 0) {
            const aligned = (self.offset + align_mask) & ~align_mask;
            if (aligned + size <= 4096) {
                self.offset = aligned + size;
                return @ptrFromInt(self.current_frame_phys + aligned);
            }
        }

        // Need a new frame — single frame can't hold more than 4096 bytes
        if (size > 4096) return null;
        if (self.frame_count >= MAX_FRAMES) return null;

        const cap_result = sys.frameAlloc();
        if (cap_result < 0) return null;
        const cap_idx: u32 = @intCast(cap_result);

        const phys_result = sys.framePhys(cap_idx);
        if (phys_result < 0) return null;

        self.frames[self.frame_count] = cap_idx;
        self.frame_count += 1;
        self.current_frame_phys = @bitCast(phys_result);
        self.offset = size;

        return @ptrFromInt(self.current_frame_phys);
    }
};
