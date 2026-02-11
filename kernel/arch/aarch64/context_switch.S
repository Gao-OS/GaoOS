// ARM64 Context Switch
//
// Switches execution from one kernel thread to another by saving
// callee-saved registers into the old thread's Context struct and
// restoring from the new thread's Context struct.
//
// Called from Zig as:
//   context_switch(old_ctx: *Context, new_ctx: *Context)
//
// AAPCS64: x0 = old_ctx, x1 = new_ctx
//
// Context struct layout (must match sched.zig Context):
//   offset  0: x19
//   offset  8: x20
//   offset 16: x21
//   offset 24: x22
//   offset 32: x23
//   offset 40: x24
//   offset 48: x25
//   offset 56: x26
//   offset 64: x27
//   offset 72: x28
//   offset 80: x29 (FP)
//   offset 88: x30 (LR / return address)
//   offset 96: sp

.section .text
.global context_switch
context_switch:
    // Save callee-saved registers into old context (x0)
    stp     x19, x20, [x0, #0]
    stp     x21, x22, [x0, #16]
    stp     x23, x24, [x0, #32]
    stp     x25, x26, [x0, #48]
    stp     x27, x28, [x0, #64]
    stp     x29, x30, [x0, #80]
    mov     x2, sp
    str     x2,       [x0, #96]

    // Restore callee-saved registers from new context (x1)
    ldp     x19, x20, [x1, #0]
    ldp     x21, x22, [x1, #16]
    ldp     x23, x24, [x1, #32]
    ldp     x25, x26, [x1, #48]
    ldp     x27, x28, [x1, #64]
    ldp     x29, x30, [x1, #80]
    ldr     x2,       [x1, #96]
    mov     sp, x2

    // Return to the new thread's saved LR (x30)
    ret
