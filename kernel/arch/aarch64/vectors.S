// ARM64 Exception Vector Table
//
// VBAR_EL1 must be 2048-byte (0x800) aligned. 16 entries, each 0x80 bytes.
// Each entry is a small stub that saves x0, loads the type ID, and branches
// to shared save/restore code. This keeps entries within the 128-byte limit.

.section .text.vectors
.balign 0x800
.global exception_vector_table
exception_vector_table:

// --- Current EL with SP_EL0 ---
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #0
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #1
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #2
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #3
    b       _exception_common

// --- Current EL with SP_ELx (kernel exceptions) ---
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #4
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #5
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #6
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #7
    b       _exception_common

// --- Lower EL, AArch64 ---
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #8
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #9
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #10
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #11
    b       _exception_common

// --- Lower EL, AArch32 ---
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #12
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #13
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #14
    b       _exception_common
.balign 0x80
    stp     x0, x1, [sp, #-16]!
    mov     x0, #15
    b       _exception_common

// ─── Shared exception entry ──────────────────────────────────────
// x0 = exception type (0-15), x0/x1 already saved on stack.
// Save full context, call Zig handler, restore, eret.
.section .text
_exception_common:
    // x0/x1 already pushed. Save the rest.
    // We build a 288-byte frame: 31 GP regs + ELR + SPSR + padding
    // x0/x1 are at [sp], we'll move them into the full frame.

    // Allocate the rest of the frame (288 - 16 already pushed = 272)
    sub     sp, sp, #272

    // Save x2-x29 (x0/x1 will be relocated)
    stp     x2,  x3,  [sp, #0]
    stp     x4,  x5,  [sp, #16]
    stp     x6,  x7,  [sp, #32]
    stp     x8,  x9,  [sp, #48]
    stp     x10, x11, [sp, #64]
    stp     x12, x13, [sp, #80]
    stp     x14, x15, [sp, #96]
    stp     x16, x17, [sp, #112]
    stp     x18, x19, [sp, #128]
    stp     x20, x21, [sp, #144]
    stp     x22, x23, [sp, #160]
    stp     x24, x25, [sp, #176]
    stp     x26, x27, [sp, #192]
    stp     x28, x29, [sp, #208]

    // Save x30 (LR), ELR_EL1, SPSR_EL1
    mrs     x1, elr_el1
    mrs     x2, spsr_el1
    stp     x30, x1,  [sp, #224]       // x30, ELR_EL1
    str     x2,       [sp, #240]        // SPSR_EL1

    // Relocate x0/x1 from the mini-push into our frame
    // They're at sp + 272 (the 16 bytes we pushed first)
    ldp     x3, x4, [sp, #272]         // original x0, x1
    stp     x3, x4, [sp, #248]         // store in frame slots 248/256

    // Call Zig handler: x0 = type (already set), x1 = frame pointer
    // x0 still holds the type ID from the stub
    mov     x1, sp
    bl      exception_handler

    // Restore ELR and SPSR
    ldp     x30, x1,  [sp, #224]
    ldr     x2,       [sp, #240]
    msr     elr_el1, x1
    msr     spsr_el1, x2

    // Restore x2-x29
    ldp     x28, x29, [sp, #208]
    ldp     x26, x27, [sp, #192]
    ldp     x24, x25, [sp, #176]
    ldp     x22, x23, [sp, #160]
    ldp     x20, x21, [sp, #144]
    ldp     x18, x19, [sp, #128]
    ldp     x16, x17, [sp, #112]
    ldp     x14, x15, [sp, #96]
    ldp     x12, x13, [sp, #80]
    ldp     x10, x11, [sp, #64]
    ldp     x8,  x9,  [sp, #48]
    ldp     x6,  x7,  [sp, #32]
    ldp     x4,  x5,  [sp, #16]
    ldp     x2,  x3,  [sp, #0]

    // Restore x0/x1 from relocated slots
    ldp     x0,  x1,  [sp, #248]

    // Pop full frame (272 + 16 from initial push)
    add     sp, sp, #288
    eret
