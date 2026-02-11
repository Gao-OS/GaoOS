// ARM64 boot stub for Raspberry Pi 3 (Cortex-A53)
//
// QEMU raspi3b starts all cores at EL3 with no firmware.
// Real Pi firmware drops to EL1 before jumping to kernel8.img at 0x80000.
// We handle both cases: check CurrentEL and drop as needed.

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
    // Set up stack below _start (grows downward from 0x80000)
    ldr     x0, =_start
    mov     sp, x0

    // Clear BSS section
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
