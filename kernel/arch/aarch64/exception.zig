// ARM64 Exception Handling
//
// This is the debuggability foundation — every future bug goes through here.
// Handlers print diagnostic info (exception type, ESR, ELR, FAR) and halt.
// Future phases will route exceptions to user-space fault handlers.

const uart = @import("uart");
const syscall = @import("syscall");
const sched = @import("sched");
const fault_mod = @import("fault");

const ExceptionSource = enum(u8) {
    // Current EL, SP_EL0
    current_el0_sync = 0,
    current_el0_irq = 1,
    current_el0_fiq = 2,
    current_el0_serror = 3,
    // Current EL, SP_ELx
    current_elx_sync = 4,
    current_elx_irq = 5,
    current_elx_fiq = 6,
    current_elx_serror = 7,
    // Lower EL, AArch64
    lower_a64_sync = 8,
    lower_a64_irq = 9,
    lower_a64_fiq = 10,
    lower_a64_serror = 11,
    // Lower EL, AArch32
    lower_a32_sync = 12,
    lower_a32_irq = 13,
    lower_a32_fiq = 14,
    lower_a32_serror = 15,
};

const source_names = [16][]const u8{
    "EL1t Sync",
    "EL1t IRQ",
    "EL1t FIQ",
    "EL1t SError",
    "EL1h Sync",
    "EL1h IRQ",
    "EL1h FIQ",
    "EL1h SError",
    "EL0 64-bit Sync",
    "EL0 64-bit IRQ",
    "EL0 64-bit FIQ",
    "EL0 64-bit SError",
    "EL0 32-bit Sync",
    "EL0 32-bit IRQ",
    "EL0 32-bit FIQ",
    "EL0 32-bit SError",
};

// ESR_EL1 exception class (bits [31:26])
fn esrClassName(ec: u6) []const u8 {
    return switch (ec) {
        0x00 => "Unknown",
        0x01 => "WFI/WFE trapped",
        0x0E => "Illegal execution state",
        0x15 => "SVC (AArch64)",
        0x18 => "MSR/MRS trap",
        0x20 => "Instruction abort (lower EL)",
        0x21 => "Instruction abort (same EL)",
        0x22 => "PC alignment fault",
        0x24 => "Data abort (lower EL)",
        0x25 => "Data abort (same EL)",
        0x26 => "SP alignment fault",
        0x2C => "FP exception",
        0x30 => "SError",
        0x3C => "BRK (debug)",
        else => "Other",
    };
}

/// Timer IRQ callback. Set by the scheduler at init time.
var timer_handler: ?*const fn () void = null;

/// Register a callback for timer IRQ handling.
pub fn setTimerHandler(handler: *const fn () void) void {
    timer_handler = handler;
}

/// Assembly context switch (defined in context_switch.S).
extern fn context_switch(old: *sched.Context, new: *sched.Context) void;

/// Called from vectors.S for all 16 exception vectors.
/// type_id: 0-15 identifying which vector fired
/// frame: pointer to saved register context on stack
export fn exception_handler(type_id: u64, frame: [*]u64) callconv(.{ .aarch64_aapcs = .{} }) void {
    // Fast path: IRQ from current EL (type 5) or lower EL (type 9)
    // Check if it's a timer IRQ and handle without full diagnostic dump
    if (type_id == 5 or type_id == 9) {
        // Read Core 0 interrupt source to identify which IRQ
        // BCM2837 local interrupt controller: 0x40000060 = Core 0 IRQ Source
        const core0_irq_source: *volatile u32 = @ptrFromInt(0x40000060);
        const source = core0_irq_source.*;

        // Bit 3 = virtual timer IRQ (CNTVIRQ)
        if (source & (1 << 3) != 0) {
            if (timer_handler) |handler| {
                handler();
            }

            // Preemptive context switch: pick next ready thread
            if (sched.global.has_current) {
                const old_id = sched.global.current;
                if (sched.global.schedule()) |next| {
                    if (next.id != old_id) {
                        context_switch(&sched.global.threads[old_id].context, &next.context);
                    }
                }
            }
            return;
        }

        // Unknown IRQ — fall through to diagnostic handler
    }

    // Read syndrome register early for fast-path checks
    const esr = asm ("mrs %[ret], esr_el1"
        : [ret] "=r" (-> u64),
    );
    const ec: u6 = @truncate(esr >> 26);

    // Fast path: SVC from lower EL (user-space syscall)
    if (ec == 0x15 and type_id == 8) {
        if (sched.global.has_current) {
            const syscall_num = frame[6]; // x8
            syscall.dispatch(sched.global.current, frame);

            // Yield and exit trigger an immediate reschedule
            if (syscall_num == syscall.SYS_YIELD or syscall_num == syscall.SYS_EXIT) {
                const old_id = sched.global.current;
                if (sched.global.schedule()) |next| {
                    if (next.id != old_id) {
                        // Save/restore ELR and SPSR across context switch.
                        // Each thread's exception frame is on its own kernel stack,
                        // but the hardware ELR/SPSR registers are shared — we must
                        // preserve them so vectors.S restores the correct values.
                        const saved_elr = asm ("mrs %[ret], elr_el1"
                            : [ret] "=r" (-> u64),
                        );
                        const saved_spsr = asm ("mrs %[ret], spsr_el1"
                            : [ret] "=r" (-> u64),
                        );
                        context_switch(&sched.global.threads[old_id].context, &next.context);
                        // Resumed — restore our ELR/SPSR
                        asm volatile ("msr elr_el1, %[v]"
                            :
                            : [v] "r" (saved_elr),
                        );
                        asm volatile ("msr spsr_el1, %[v]"
                            :
                            : [v] "r" (saved_spsr),
                        );
                    }
                }
            }
        }
        return;
    }

    // Fast path: SVC from current EL (kernel self-test)
    if (ec == 0x15) {
        return;
    }

    // ─── Diagnostic dump for unexpected exceptions ─────────────────

    const elr = asm ("mrs %[ret], elr_el1"
        : [ret] "=r" (-> u64),
    );
    const far = asm ("mrs %[ret], far_el1"
        : [ret] "=r" (-> u64),
    );

    uart.puts("\n!!! EXCEPTION !!!\n");

    uart.puts("  Type: ");
    if (type_id < 16) {
        uart.puts(source_names[@intCast(type_id)]);
    } else {
        uart.puts("Invalid");
    }
    uart.puts("\n");

    uart.puts("  ESR_EL1:  0x");
    putHex64(esr);
    uart.puts(" (");
    uart.puts(esrClassName(ec));
    uart.puts(")\n");

    uart.puts("  ELR_EL1:  0x");
    putHex64(elr);
    uart.puts("\n");

    uart.puts("  FAR_EL1:  0x");
    putHex64(far);
    uart.puts("\n");

    // Frame layout: x0 at frame[31], x1 at frame[32], x2 at frame[0], etc.
    uart.puts("  x0-x3:    ");
    uart.puts("0x");
    putHex64(frame[31]);
    uart.putc(' ');
    uart.puts("0x");
    putHex64(frame[32]);
    uart.putc(' ');
    uart.puts("0x");
    putHex64(frame[0]);
    uart.putc(' ');
    uart.puts("0x");
    putHex64(frame[1]);
    uart.puts("\n");
    uart.puts("  x30 (LR): 0x");
    putHex64(frame[28]);
    uart.puts("\n");

    // If exception came from EL0 (user space), notify supervisor, kill the
    // thread, and reschedule — the rest of the system keeps running.
    // Do NOT reap here: the supervisor may inspect the dead thread later.
    if (type_id >= 8 and type_id <= 11 and sched.global.has_current) {
        const cur_id = sched.global.current;
        fault_mod.notify(cur_id, .exception, far, esr);
        sched.global.kill(cur_id);

        // Reschedule: pick the next ready thread and context-switch to it
        if (sched.global.schedule()) |next| {
            const saved_elr = asm ("mrs %[ret], elr_el1"
                : [ret] "=r" (-> u64),
            );
            const saved_spsr = asm ("mrs %[ret], spsr_el1"
                : [ret] "=r" (-> u64),
            );
            context_switch(&sched.global.threads[cur_id].context, &next.context);
            asm volatile ("msr elr_el1, %[v]"
                :
                : [v] "r" (saved_elr),
            );
            asm volatile ("msr spsr_el1, %[v]"
                :
                : [v] "r" (saved_spsr),
            );
        } else {
            // No runnable threads remain — halt
            uart.puts("\n  No runnable threads — HALTED\n");
            while (true) {
                asm volatile ("wfe");
            }
        }
        return;
    }

    // EL1 exceptions are unrecoverable — halt
    uart.puts("\n  HALTED\n");
    while (true) {
        asm volatile ("wfe");
    }
}

/// Install the vector table by writing VBAR_EL1.
pub fn init() void {
    const table_addr = @intFromPtr(&exception_vector_table);
    asm volatile ("msr vbar_el1, %[addr]"
        :
        : [addr] "r" (table_addr),
    );
    // ISB ensures the new VBAR is visible before any exception can fire
    asm volatile ("isb");
}

extern const exception_vector_table: u8;

// Print a 64-bit value as 16 hex digits
fn putHex64(val: u64) void {
    const hex = "0123456789abcdef";
    var v = val;
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@truncate(v & 0xF)];
        v >>= 4;
    }
    uart.puts(&buf);
}
