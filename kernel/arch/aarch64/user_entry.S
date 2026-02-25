// EL0 Entry Trampoline
//
// enter_el0(entry_point: u64, user_sp: u64)
//   Drops from EL1 to EL0 via eret.

.section .text
.global enter_el0

enter_el0:
    msr     sp_el0, x1
    msr     elr_el1, x0
    mov     x0, #0x0                // SPSR_EL1 = EL0t
    msr     spsr_el1, x0
    eret
