// MMU control: set up page tables and enable the MMU
//
// This is where the kernel switches from 1:1 physical=virtual addressing
// to real virtual memory. We set TTBR0_EL1 (user space) and TTBR1_EL1
// (kernel space), configure caching and permissions, then enable SCTLR_EL1.

const uart = @import("uart");

/// Memory attribute index mapping (MAIR_EL1).
/// Index 0: normal cached, WB (write-back), RA (read-allocate), WA (write-allocate)
/// Index 1: device nGnRnE (strongly ordered, for MMIO)
pub fn initMAIR() void {
    // MAIR_EL1 format: 8 bytes, each byte is an attribute descriptor
    const mair: u64 =
        (0xFF << 0) | // Attr 0: Normal memory, WB RW-Allocate
        (0x04 << 8); // Attr 1: Device nGnRnE (bit 2 = E bit for normal access)
    asm volatile ("msr mair_el1, %[val]"
        :
        : [val] "r" (mair),
    );
}

/// Initialize TCR_EL1: controls page table walks, granule size, VA size.
pub fn initTCR() void {
    // TCR_EL1 configuration for TTBR0 (user) and TTBR1 (kernel):
    // - IPS = 0b010 (40-bit physical): supports up to 1TB physical memory
    // - TG0 = 0b00 (4KB granule for TTBR0)
    // - SH0 = 0b11 (inner shareable for TTBR0)
    // - ORGN0/IRGN0 = 0b01 (normal memory, write-back for TTBR0)
    // - T0SZ = 0b010000 (16: 48-bit VA for TTBR0)
    // - Same for TG1, SH1, etc.
    // - EPD1 = 0 (TTBR1 walk enabled)

    const tcr: u64 =
        (2 << 32) | // IPS[34:32] = 0b010 (40-bit PA)
        (0 << 30) | // TG1[31:30] = 0b00 (4KB)
        (3 << 28) | // SH1[29:28] = 0b11 (inner shareable)
        (1 << 26) | // ORGN1[27:26] = 0b01 (WB)
        (1 << 24) | // IRGN1[25:24] = 0b01 (WB)
        (16 << 16) | // T1SZ[21:16] = 16 (48-bit VA)
        (0 << 14) | // TG0[15:14] = 0b00 (4KB)
        (3 << 12) | // SH0[13:12] = 0b11 (inner shareable)
        (1 << 10) | // ORGN0[11:10] = 0b01 (WB)
        (1 << 8) | // IRGN0[9:8] = 0b01 (WB)
        (16 << 0); // T0SZ[5:0] = 16 (48-bit VA)

    asm volatile ("msr tcr_el1, %[val]"
        :
        : [val] "r" (tcr),
    );
}

/// Enable the MMU by setting SCTLR_EL1.
/// Must be called after TTBR0/TTBR1, MAIR, and TCR are configured.
pub fn enable() void {
    // Set SCTLR_EL1 bit 0 (M = MMU enable) and bit 2 (C = cache enable).
    // Also bit 12 (I = I-cache enable), bit 4 (SA = stack alignment).
    var sctlr: u64 = asm ("mrs %[ret], sctlr_el1"
        : [ret] "=r" (-> u64),
    );

    sctlr |= (1 << 0) | // M: MMU enable
        (1 << 2) | // C: D-cache enable
        (1 << 12) | // I: I-cache enable
        (1 << 4); // SA: SP alignment check

    asm volatile ("msr sctlr_el1, %[val]"
        :
        : [val] "r" (sctlr),
    );

    // ISB to ensure MMU is enabled before next instruction
    asm volatile ("isb");
}

/// Set TTBR0_EL1 (user-space page table root).
/// For Phase 1, we don't use this; enable() will use default TTBRs.
pub fn setTTBR0(table_paddr: u64) void {
    asm volatile ("msr ttbr0_el1, %[val]"
        :
        : [val] "r" (table_paddr),
    );
}

/// Set TTBR1_EL1 (kernel-space page table root).
/// For Phase 1, we don't use this; enable() will use default TTBRs.
pub fn setTTBR1(table_paddr: u64) void {
    asm volatile ("msr ttbr1_el1, %[val]"
        :
        : [val] "r" (table_paddr),
    );
}

/// Invalidate TLB entries for a given virtual address (EL1).
pub fn tlbiVA(vaddr: u64) void {
    asm volatile ("tlbi vaae1, %[va]"
        :
        : [va] "r" (vaddr >> 12), // VA in pages
    );
}

/// Invalidate all TLB entries.
pub fn tlbiAll() void {
    asm volatile ("tlbi alle1");
}
