// ARM64 boot stub for Raspberry Pi 3 (Cortex-A53)
//
// QEMU raspi3b starts all cores at EL3 with no firmware.
// Real Pi firmware drops to EL1 before jumping to kernel8.img at 0x80000.
// We handle both cases: check CurrentEL and drop as needed.
//
// After reaching EL1, we set up a bootstrap identity-map page table so
// that RAM is marked as Normal memory (not Device). Without this, all
// memory accesses use Device-nGnRnE semantics which require strict
// natural alignment — breaking any compiler-generated unaligned access.

.section .text.boot
.global _start

_start:
    // Park non-primary cores (MPIDR_EL1 bits [1:0] = core ID)
    mrs     x0, mpidr_el1
    and     x0, x0, #0x3
    cbnz    x0, .park

    // Check current exception level
    mrs     x0, CurrentEL
    and     x0, x0, #0xC           // bits [3:2] = EL
    cmp     x0, #0xC               // EL3?
    b.eq    .from_el3
    cmp     x0, #0x8               // EL2?
    b.eq    .from_el2
    b       .at_el1                 // Already EL1

.from_el3:
    // Configure EL2: enable AArch64 at EL2
    ldr     x0, =0x5b1             // SCR_EL3: RW=1 (AArch64), HCE=1, SMD=0, NS=1
    msr     scr_el3, x0

    // Set return address and SPSR for EL2h
    ldr     x0, =.from_el2
    msr     elr_el3, x0
    mov     x0, #0x3c9             // SPSR_EL3: EL2h, DAIF masked
    msr     spsr_el3, x0
    eret

.from_el2:
    // Configure EL1: enable AArch64 at EL1
    ldr     x0, =0x80000000        // HCR_EL2: RW=1 (AArch64 at EL1)
    msr     hcr_el2, x0

    // Disable EL2 coprocessor traps
    msr     cptr_el2, xzr

    // Set return address and SPSR for EL1h
    ldr     x0, =.at_el1
    msr     elr_el2, x0
    mov     x0, #0x3c5             // SPSR_EL2: EL1h, DAIF masked
    msr     spsr_el2, x0
    eret

.at_el1:
    // Enable FP/SIMD at EL1 (CPACR_EL1.FPEN = 0b11)
    mov     x0, #(3 << 20)
    msr     cpacr_el1, x0
    isb

    // Set up stack below _start (grows downward from 0x80000)
    // Must happen before BSS clear and MMU setup (need SP for ldr =)
    ldr     x0, =_start
    mov     sp, x0

    // ─── Bootstrap MMU: identity-map first 1GB as Normal memory ────
    //
    // Without MMU, Cortex-A53 treats all memory as Device-nGnRnE which
    // has strict natural-alignment requirements. We need Normal memory
    // attributes for RAM so the compiler can use unaligned accesses.
    //
    // Strategy: use 2MB block descriptors at Level 2.
    // Level 0 → Level 1 → Level 2 (2MB blocks)
    // We need a Level 1 table (1 entry pointing to Level 2 table)
    // and a Level 2 table (512 entries × 2MB = 1GB coverage).
    //
    // Table placement: below stack at 0x80000.
    //   Level 1 (L1): 0x70000 (4KB, 512 entries)
    //   Level 2 (L2): 0x71000 (4KB, 512 entries)
    // Stack grows down from 0x80000 toward ~0x7F000.
    // Tables at 0x70000-0x71FFF are safe (well below stack bottom).

    // MAIR_EL1: memory attributes
    //   Attr 0: Normal WB-RW-allocate (0xFF)
    //   Attr 1: Device nGnRnE (0x00)
    ldr     x0, =(0xFF | (0x00 << 8))
    msr     mair_el1, x0

    // TCR_EL1: translation control
    //   T0SZ = 25: 39-bit VA (512GB, need L1+L2 with 4KB granule)
    //   TG0 = 0b00: 4KB granule
    //   SH0 = 0b11: inner shareable
    //   ORGN0 = 0b01: normal, WB-WA
    //   IRGN0 = 0b01: normal, WB-WA
    //   EPD1 = 1: disable TTBR1 walks (no kernel upper-half mapping yet)
    //   IPS = 0b010: 40-bit PA
    ldr     x0, =( \
        (25 << 0)  | /* T0SZ = 25 (39-bit VA) */ \
        (0 << 14)  | /* TG0 = 4KB granule */ \
        (3 << 12)  | /* SH0 = inner shareable */ \
        (1 << 10)  | /* ORGN0 = WB-WA */ \
        (1 << 8)   | /* IRGN0 = WB-WA */ \
        (1 << 23)  | /* EPD1 = 1 (disable TTBR1 walks) */ \
        (2 << 32)    /* IPS = 40-bit PA */ \
    )
    msr     tcr_el1, x0

    // Zero out the L1 and L2 tables
    ldr     x0, =0x70000            // L1 table base
    mov     x1, #(4096 * 2 / 8)    // 1024 quad-words (2 pages)
1:  str     xzr, [x0], #8
    subs    x1, x1, #1
    b.ne    1b

    // L1[0] = table descriptor pointing to L2 at 0x71000 (first 1GB, detailed)
    // L1[1] = 1GB block descriptor for 0x40000000-0x7FFFFFFF (Device, for QA7)
    ldr     x0, =0x70000            // L1 base
    ldr     x1, =(0x71000 | 0x3)    // L2 addr | table descriptor
    str     x1, [x0]                // L1[0] → L2

    // L1[1]: 1GB block for QA7 local peripherals at 0x40000000
    // 1GB block descriptor: [1:0] = 0b01, AttrIndx=1 (Device), AF=1
    // 0x40000000 | 0x401 = AF=1, AttrIndx=1(bits[4:2]=001), Block(01)
    // Wait: for L1 block entries, bits[1:0]=01, address in bits[47:30]
    ldr     x1, =(0x40000000 | 0x405)  // Device block | AF | AttrIndx=1
    str     x1, [x0, #8]               // L1[1]

    // Fill L2 with 512 × 2MB block entries covering 0x00000000 - 0x3FFFFFFF
    // Block descriptor format:
    //   [1:0] = 0b01 (block)
    //   [4:2] = AttrIndx
    //   [7:6] = AP (0b00 = EL1 RW)
    //   [9:8] = SH (0b11 = inner shareable)
    //   [10]  = AF (access flag, must be 1)
    //   [47:21] = output address [47:21] (2MB aligned)
    //
    // Normal memory block: AttrIndx=0, SH=11, AF=1
    //   = 0x00000000_00000701 | (block_addr)
    // Device memory block: AttrIndx=1, SH=00, AF=1
    //   = 0x00000000_00000405 | (block_addr)

    ldr     x0, =0x71000            // L2 base
    mov     x1, #0                  // block physical address
    mov     x2, #512                // 512 entries

    // Normal memory attributes: AF=1, SH=inner-shareable, AttrIndx=0, block
    // 0x701 = 0b 0111 0000 0001 = AF(1) | SH(11) | AttrIndx(000) | block(01)
    ldr     x3, =0x701              // normal memory attributes

    // Device memory attributes: AF=1, SH=none, AttrIndx=1, block
    // 0x405 = 0b 0100 0000 0101 = AF(1) | SH(00) | AttrIndx(001) | block(01)
    ldr     x4, =0x405              // device memory attributes

    // BCM2837 peripherals start at 0x3F000000 = block index 504 (504 * 2MB = 0x3F000000)
    // Local peripherals (QA7) at 0x40000000 = block index 512 (outside our range, but 511 covers it)
    // So blocks 0-503: Normal, blocks 504-511: Device
    mov     x5, #504                // first device block index

2:  cmp     x2, #0
    b.eq    3f
    // Determine: device or normal?
    mov     x6, #512
    sub     x6, x6, x2             // x6 = current block index (0-based)
    cmp     x6, x5
    b.ge    .use_device
    orr     x7, x1, x3             // normal: addr | 0x701
    b       .store_entry
.use_device:
    orr     x7, x1, x4             // device: addr | 0x405
.store_entry:
    str     x7, [x0], #8
    add     x1, x1, #(1 << 21)     // next 2MB block
    sub     x2, x2, #1
    b       2b
3:

    // Set TTBR0_EL1 to L1 table
    ldr     x0, =0x70000
    msr     ttbr0_el1, x0

    // TLB invalidate all (vmalle1 is the EL1 form; alle1 is EL2-only)
    tlbi    vmalle1
    dsb     sy
    isb

    // Enable MMU
    mrs     x0, sctlr_el1
    orr     x0, x0, #(1 << 0)      // M: MMU enable
    orr     x0, x0, #(1 << 2)      // C: D-cache enable
    orr     x0, x0, #(1 << 12)     // I: I-cache enable
    bic     x0, x0, #(1 << 1)      // Clear A: no alignment check
    bic     x0, x0, #(1 << 3)      // Clear SA: no SP alignment check
    msr     sctlr_el1, x0
    isb

    // ─── BSS clear (after MMU is on, so stores use Normal memory) ──

    ldr     x0, =__bss_start
    ldr     x1, =__bss_end
.bss_zero:
    cmp     x0, x1
    b.ge    .bss_done
    str     xzr, [x0], #8
    b       .bss_zero
.bss_done:

    // Jump to Zig kernel entry
    bl      kernel_main

    // If kernel_main returns, halt
.park:
    wfe
    b       .park
