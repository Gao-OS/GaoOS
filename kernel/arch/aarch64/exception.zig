// ARM64 Exception Handling
//
// This is the debuggability foundation — every future bug goes through here.
// Handlers print diagnostic info (exception type, ESR, ELR, FAR) and halt.
// Future phases will route exceptions to user-space fault handlers.

const uart = @import("uart");

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

/// Called from vectors.S for all 16 exception vectors.
/// type_id: 0-15 identifying which vector fired
/// frame: pointer to saved register context on stack
export fn exception_handler(type_id: u64, frame: [*]u64) callconv(.{ .aarch64_aapcs = .{} }) void {
    const esr = asm ("mrs %[ret], esr_el1"
        : [ret] "=r" (-> u64),
    );
    const elr = asm ("mrs %[ret], elr_el1"
        : [ret] "=r" (-> u64),
    );
    const far = asm ("mrs %[ret], far_el1"
        : [ret] "=r" (-> u64),
    );

    uart.puts("\n!!! EXCEPTION !!!\n");

    // Exception source
    uart.puts("  Type: ");
    if (type_id < 16) {
        uart.puts(source_names[@intCast(type_id)]);
    } else {
        uart.puts("Invalid");
    }
    uart.puts("\n");

    // ESR_EL1: syndrome register (tells us what happened)
    const ec: u6 = @truncate(esr >> 26);
    uart.puts("  ESR_EL1:  0x");
    putHex64(esr);
    uart.puts(" (");
    uart.puts(esrClassName(ec));
    uart.puts(")\n");

    // ELR_EL1: return address (where it happened)
    uart.puts("  ELR_EL1:  0x");
    putHex64(elr);
    uart.puts("\n");

    // FAR_EL1: fault address (for data/instruction aborts)
    uart.puts("  FAR_EL1:  0x");
    putHex64(far);
    uart.puts("\n");

    // Frame layout (from vectors.S _exception_common):
    //   [sp+0]:   x2,  x3
    //   [sp+16]:  x4,  x5
    //   ...
    //   [sp+208]: x28, x29
    //   [sp+224]: x30, ELR_EL1
    //   [sp+240]: SPSR_EL1
    //   [sp+248]: x0,  x1  (relocated from initial push)
    uart.puts("  x0-x3:    ");
    // x0 is at frame[31] (offset 248/8), x1 at frame[32]
    uart.puts("0x");
    putHex64(frame[31]);
    uart.putc(' ');
    uart.puts("0x");
    putHex64(frame[32]);
    uart.putc(' ');
    // x2 at frame[0], x3 at frame[1]
    uart.puts("0x");
    putHex64(frame[0]);
    uart.putc(' ');
    uart.puts("0x");
    putHex64(frame[1]);
    uart.puts("\n");
    // x30 (LR) at frame[28] (offset 224/8)
    uart.puts("  x30 (LR): 0x");
    putHex64(frame[28]);
    uart.puts("\n");

    // SVC is a deliberate syscall — return to caller (ELR already points past SVC)
    if (ec == 0x15) {
        uart.puts("  (returning from SVC)\n");
        return;
    }

    // All other exceptions are fatal for now — halt
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
