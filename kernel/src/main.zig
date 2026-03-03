// GaoOS kernel entry point
//
// Called from boot.S after core 0 has set up the stack and cleared BSS.

const uart = @import("uart");
const exception = @import("exception");
const timer = @import("timer");
const sched = @import("sched");
const cap = @import("cap");
const user_init = @import("user_init");

/// Enable interrupts (clear DAIF.I bit to unmask IRQs).
fn enableIRQ() void {
    asm volatile ("msr daifclr, #2");
}

// BCM2836 QA7 (ARM local peripherals) registers
const QA7_BASE = 0x40000000;
const CORE0_TIMER_CTL = QA7_BASE + 0x40; // Core 0 timer interrupt control

// L2 page table base (set up in boot.S, 512 entries × 8 bytes)
const L2_TABLE_BASE = 0x71000;

/// Enable virtual timer IRQ for core 0.
fn enableTimerIRQ() void {
    const core0_timer_ctl: *volatile u32 = @ptrFromInt(CORE0_TIMER_CTL);
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

/// User memory layout:
///   Block 1 (0x200000-0x3FFFFF): user program + stack
///   Blocks 2-31 (0x400000-0x3FFFFFF): frame allocator pool (EL0-accessible)
const USER_CODE_BASE: u64 = 0x200000;
const USER_STACK_TOP: u64 = 0x400000; // Top of 2MB block, SP decrements before use
const USER_BLOCK_SIZE: u64 = USER_STACK_TOP - USER_CODE_BASE; // 2MB

comptime {
    if (user_init.data.len > USER_BLOCK_SIZE)
        @compileError("User program exceeds 2MB block (would corrupt frame pool)");
}

/// Patch L2 page table entries to allow EL0 data access (AP[1]=1) for a
/// range of 2MB blocks, then batch-invalidate the TLB once.
fn enableEL0AccessForBlocks(start: usize, end: usize) void {
    const l2_base: [*]volatile u64 = @ptrFromInt(L2_TABLE_BASE);
    for (start..end) |block_index| {
        l2_base[block_index] |= (1 << 6); // AP=10 → EL1 RW, EL0 RW
    }
    // Single TLB invalidation for all modified entries
    asm volatile ("tlbi vmalle1is");
    asm volatile ("dsb sy");
    asm volatile ("isb");
}

/// Copy the embedded user binary to EL0-accessible memory.
fn copyUserProgram() u64 {
    const data = user_init.data;
    const dst: [*]u8 = @ptrFromInt(USER_CODE_BASE);

    for (data, 0..) |byte, i| {
        dst[i] = byte;
    }

    // Ensure instruction cache sees the new code.
    // Round up to cache line boundary so the last partial line is flushed.
    const cache_end = (USER_CODE_BASE + data.len + 63) & ~@as(u64, 63);
    var addr: u64 = USER_CODE_BASE;
    while (addr < cache_end) : (addr += 64) {
        asm volatile ("dc cvau, %[addr]"
            :
            : [addr] "r" (addr),
        );
    }
    asm volatile ("dsb ish");
    addr = USER_CODE_BASE;
    while (addr < cache_end) : (addr += 64) {
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

export fn kernel_main() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    uart.init();
    uart.puts("GaoOS v0.2\n");

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
    _ = ct.create(.device, 0x3F20_1000, cap.Rights{ .write = true, .grant = true }) catch {
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
    uart.puts("Setting up user space...\n");

    // Enable EL0 access for blocks 1-31 (user program, stack, frame pool)
    enableEL0AccessForBlocks(1, 32);

    // Copy embedded user binary to block 1
    const entry = copyUserProgram();
    uart.puts("  User program at 0x");
    putHex(entry);
    uart.puts(" (");
    putDec(@intCast(user_init.data.len));
    uart.puts(" bytes)\n");

    uart.puts("\nDropping to EL0 → user init\n");
    uart.puts("─────────────────────────────────\n");

    // Enter EL0
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
