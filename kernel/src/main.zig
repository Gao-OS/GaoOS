// GaoOS kernel entry point
//
// Called from boot.S after core 0 has set up the stack and cleared BSS.

const uart = @import("uart");
const exception = @import("exception");
const timer = @import("timer");
const sched = @import("sched");
const cap = @import("cap");

/// Enable interrupts (clear DAIF.I bit to unmask IRQs).
fn enableIRQ() void {
    asm volatile ("msr daifclr, #2");
}

/// BCM2837 local interrupt controller: enable virtual timer IRQ for core 0.
fn enableTimerIRQ() void {
    const core0_timer_ctl: *volatile u32 = @ptrFromInt(0x40000040);
    core0_timer_ctl.* = (1 << 3);
}

/// Timer tick handler: rearm timer and print a tick marker.
var tick_count: u32 = 0;

fn timerTick() void {
    tick_count += 1;
    timer.ack();

    if (tick_count % 100 == 0) {
        uart.puts("[tick] ");
        putDec(tick_count);
        uart.puts("\n");
    }
}

/// User memory layout (all in 2MB block 1: 0x200000-0x3FFFFF):
///   0x200000: user program code (copied from kernel image)
///   0x201000: user stack top (grows down from here)
const USER_CODE_BASE: u64 = 0x200000;
const USER_STACK_TOP: u64 = 0x201000;

/// Patch a single L2 page table entry to allow EL0 data access (AP[1]=1).
/// Uses per-VA TLB invalidation to avoid disturbing other TLB entries.
fn enableEL0AccessForBlock(block_index: usize) void {
    const l2_base: [*]volatile u64 = @ptrFromInt(0x71000);
    l2_base[block_index] |= (1 << 6); // AP[1] = 1 → EL0 RW

    const va: u64 = @as(u64, block_index) << 21;
    const tlbi_val: u64 = va >> 12;
    asm volatile ("tlbi vae1, %[val]"
        :
        : [val] "r" (tlbi_val),
    );
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

/// Copy the user program to EL0-accessible memory (block 1).
/// The program is position-independent (uses only movz/movk + PC-relative branches).
fn copyUserProgram() u64 {
    const start = @intFromPtr(&user_program_start);
    const end = @intFromPtr(&user_program_end);
    const size = end - start;

    const src: [*]const u8 = @ptrFromInt(start);
    const dst: [*]u8 = @ptrFromInt(USER_CODE_BASE);

    for (0..size) |i| {
        dst[i] = src[i];
    }

    // Ensure instruction cache sees the new code
    // DC CVAU: clean data cache to point of unification
    // IC IVAU: invalidate instruction cache
    var addr: u64 = USER_CODE_BASE;
    while (addr < USER_CODE_BASE + size) : (addr += 64) {
        asm volatile ("dc cvau, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }
    asm volatile ("dsb ish");
    addr = USER_CODE_BASE;
    while (addr < USER_CODE_BASE + size) : (addr += 64) {
        asm volatile ("ic ivau, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }
    asm volatile ("dsb ish");
    asm volatile ("isb");

    return USER_CODE_BASE;
}

/// External symbols
extern fn enter_el0(entry: u64, user_sp: u64) noreturn;
extern const user_program_start: u8;
extern const user_program_end: u8;

export fn kernel_main() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    uart.init();
    uart.puts("GaoOS v0.1\n");

    exception.init();
    uart.puts("MMU enabled (identity map from boot.S).\n");

    // ─── Scheduler init ────────────────────────────────────────────
    uart.puts("Initializing scheduler...\n");
    const t0 = sched.global.spawn() catch {
        uart.puts("FATAL: failed to spawn thread 0\n");
        halt();
    };
    uart.puts("  Thread 0 (init): id=");
    putDec(t0);
    uart.puts("\n");

    _ = sched.global.schedule();

    // ─── Grant capabilities to thread 0 ────────────────────────────
    const ct = sched.getCapTable(t0) orelse {
        uart.puts("FATAL: no cap table for thread 0\n");
        halt();
    };
    _ = ct.create(.device, 0x3F20_1000, cap.Rights{ .write = true }) catch {
        uart.puts("FATAL: failed to create UART cap\n");
        halt();
    };
    uart.puts("  Granted: cap[0] = device(UART, write)\n");

    // ─── Timer preemption ──────────────────────────────────────────
    uart.puts("Starting timer (10ms slice)...\n");
    exception.setTimerHandler(&timerTick);
    enableTimerIRQ();
    timer.armTimeSlice();
    enableIRQ();

    // ─── Enter user space ──────────────────────────────────────────
    // 1. Enable EL0 access for block 1 (0x200000-0x3FFFFF)
    uart.puts("Setting up user space...\n");
    enableEL0AccessForBlock(1);

    // 2. Copy user program to block 1
    const entry = copyUserProgram();
    uart.puts("  User program at 0x");
    putHex(entry);
    uart.puts("\n");

    uart.puts("\nDropping to EL0 → user init\n");
    uart.puts("─────────────────────────────────\n");

    // 3. Enter EL0
    enter_el0(entry, USER_STACK_TOP);
}

fn halt() noreturn {
    while (true) {
        asm volatile ("wfe");
    }
}

fn putDec(val: u32) void {
    if (val == 0) {
        uart.putc('0');
        return;
    }
    var buf: [10]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) {
        buf[i] = @intCast((n % 10) + '0');
        n /= 10;
        i += 1;
    }
    while (i > 0) {
        i -= 1;
        uart.putc(buf[i]);
    }
}

fn putHex(val: u64) void {
    const hex = "0123456789abcdef";
    var v = val;
    var buf: [16]u8 = undefined;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@truncate(v & 0xF)];
        v >>= 4;
    }
    // Skip leading zeros
    var start: usize = 0;
    while (start < 15 and buf[start] == '0') start += 1;
    for (buf[start..]) |c| uart.putc(c);
}
