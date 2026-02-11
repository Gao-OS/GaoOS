// EL0 Entry Trampoline + User Program
//
// enter_el0(entry_point: u64, user_sp: u64)
//   Drops from EL1 to EL0.

.section .text
.global enter_el0

enter_el0:
    msr     sp_el0, x1
    msr     elr_el1, x0
    mov     x0, #0x0                // SPSR_EL1 = EL0t
    msr     spsr_el1, x0
    eret

// ─── User Init Program (copied to EL0-accessible memory at runtime) ─
//
// Position-independent: uses only register immediates and PC-relative
// branches. No literal pool references (uses movz/movk for constants).
//
// Syscalls: x8=num, x0-x2=args, x0=return
//   SYS_WRITE(0): write(cap_idx, buf_ptr, len)
//   SYS_EXIT(1):  exit()
//   SYS_CAP_READ(3): cap_read(cap_idx) → type

.global user_program_start
.global user_program_end

user_program_start:
    // Allocate 32 bytes on stack for string building
    sub     sp, sp, #32

    // ── Write "Hello from EL0!\n" (16 bytes) ──
    // Little-endian: "Hello fr" = 0x7266206f6c6c6548
    movz    x9, #0x6548
    movk    x9, #0x6c6c, lsl #16
    movk    x9, #0x206f, lsl #32
    movk    x9, #0x7266, lsl #48
    str     x9, [sp, #0]
    // "om EL0!\n" = 0x0a21304c45206d6f
    movz    x9, #0x6d6f
    movk    x9, #0x4520, lsl #16
    movk    x9, #0x304c, lsl #32
    movk    x9, #0x0a21, lsl #48
    str     x9, [sp, #8]

    mov     x0, #0                  // cap_idx = 0 (UART cap)
    mov     x1, sp                  // buf = stack
    mov     x2, #16                 // len
    mov     x8, #0                  // SYS_WRITE
    svc     #0

    // ── Write "  SVC works!\n" (13 bytes) ──
    // "  SVC wo" = 0x6f77204356532020
    movz    x9, #0x2020
    movk    x9, #0x5653, lsl #16
    movk    x9, #0x2043, lsl #32    // wait, " C" is wrong. Let me recalculate.
    // Actually: "  SVC wo"
    // ' '=0x20, ' '=0x20, 'S'=0x53, 'V'=0x56, 'C'=0x43, ' '=0x20, 'w'=0x77, 'o'=0x6f
    // LE u64: bytes [0..7] = 0x20, 0x20, 0x53, 0x56, 0x43, 0x20, 0x77, 0x6f
    //       = 0x6f772043_56532020
    movz    x9, #0x2020
    movk    x9, #0x5653, lsl #16
    movk    x9, #0x2043, lsl #32
    movk    x9, #0x6f77, lsl #48
    str     x9, [sp, #0]
    // "rks!\n" + padding = 0x000a21736b72
    // 'r'=0x72, 'k'=0x6b, 's'=0x73, '!'=0x21, '\n'=0x0a
    movz    x9, #0x6b72
    movk    x9, #0x2173, lsl #16
    movk    x9, #0x000a, lsl #32
    str     x9, [sp, #8]

    mov     x0, #0
    mov     x1, sp
    mov     x2, #13
    mov     x8, #0
    svc     #0

    // ── cap_read(0) → x0 ──
    mov     x0, #0
    mov     x8, #3                  // SYS_CAP_READ
    svc     #0
    mov     x10, x0                 // save result

    // ── Write "  cap=N\n" where N is the cap type digit ──
    // "  cap=" = 0x3d706163_2020 (6 bytes)
    movz    x9, #0x2020             // "  "
    movk    x9, #0x6163, lsl #16    // "ca"
    movk    x9, #0x3d70, lsl #32    // "p="
    // Add the cap type as ASCII digit + newline
    add     x11, x10, #0x30        // ASCII '0' + type
    orr     x9, x9, x11, lsl #48   // byte 6 = digit
    str     x9, [sp, #0]
    mov     x9, #0x0a              // '\n'
    strb    w9, [sp, #7]

    mov     x0, #0
    mov     x1, sp
    mov     x2, #8
    mov     x8, #0
    svc     #0

    // ── Write "  Exiting.\n" (11 bytes) ──
    // "  Exitin" = 0x6e697469_78452020
    movz    x9, #0x2020
    movk    x9, #0x7845, lsl #16
    movk    x9, #0x7469, lsl #32
    movk    x9, #0x6e69, lsl #48
    str     x9, [sp, #0]
    // "g.\n" = 0x0a2e67
    movz    x9, #0x2e67
    movk    x9, #0x000a, lsl #16
    str     x9, [sp, #8]

    mov     x0, #0
    mov     x1, sp
    mov     x2, #11
    mov     x8, #0
    svc     #0

    // Clean up stack
    add     sp, sp, #32

    // ── Exit ──
    mov     x8, #1                  // SYS_EXIT
    svc     #0

    // Should not reach here
1:  wfe
    b       1b

user_program_end:
