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

// Thread entry trampoline for newly spawned threads.
// Called via context_switch when a new thread is first scheduled.
// Callee-saved registers carry the entry point and user stack:
//   x19 = entry_pc
//   x20 = user_sp
.global thread_entry_trampoline
thread_entry_trampoline:
    msr     sp_el0, x20
    msr     elr_el1, x19
    mov     x0, #0x0                // SPSR_EL1 = EL0t
    msr     spsr_el1, x0
    eret
