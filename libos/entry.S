// User-space entry point
//
// The kernel drops to EL0 at _start with SP_EL0 set.
// Calls the user's exported user_main() function, then exits.

.section .text._start
.global _start

_start:
    bl      user_main
    mov     x8, #1          // SYS_EXIT
    svc     #0
1:  wfe
    b       1b
