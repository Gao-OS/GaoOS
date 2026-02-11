// GaoOS kernel entry point
//
// Called from boot.S after core 0 has set up the stack and cleared BSS.

const uart = @import("uart");
const exception = @import("exception");
const timer = @import("timer");
const sched = @import("sched");

/// Enable interrupts (clear DAIF.I bit to unmask IRQs).
fn enableIRQ() void {
    asm volatile ("msr daifclr, #2");
}

/// BCM2837 local interrupt controller: enable virtual timer IRQ for core 0.
/// The QA7 local peripherals sit at 0x40000000 (above the main peripheral base).
fn enableTimerIRQ() void {
    // Core 0 Timer Interrupt Control (0x40000040)
    // Bit 3 = nCNTVIRQ (virtual timer interrupt enable)
    const core0_timer_ctl: *volatile u32 = @ptrFromInt(0x40000040);
    core0_timer_ctl.* = (1 << 3);
}

/// Timer tick handler: rearm timer and print a tick marker.
/// In a full system this would invoke context_switch; for Phase 1.6 demo
/// we just show that preemption is working.
var tick_count: u32 = 0;

fn timerTick() void {
    tick_count += 1;
    timer.ack();

    // Print a tick marker every 100 ticks (every ~1 second)
    if (tick_count % 100 == 0) {
        uart.puts("[tick] ");
        putDec(tick_count);
        uart.puts("\n");
    }
}

export fn kernel_main() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    uart.init();
    uart.puts("GaoOS v0.1\n");

    exception.init();

    // MMU is already enabled by boot.S with identity mapping.
    // RAM (0-0x3F000000) is Normal memory; peripherals are Device memory.
    uart.puts("MMU enabled (identity map from boot.S).\n");

    // Initialize scheduler
    uart.puts("Initializing scheduler...\n");
    const t0 = sched.global.spawn() catch {
        uart.puts("FATAL: failed to spawn thread 0\n");
        halt();
    };
    const t1 = sched.global.spawn() catch {
        uart.puts("FATAL: failed to spawn thread 1\n");
        halt();
    };
    uart.puts("  Thread 0: id=");
    putDec(t0);
    uart.puts("\n  Thread 1: id=");
    putDec(t1);
    uart.puts("\n");

    // Schedule first thread (demonstrates scheduler picks t0 first)
    if (sched.global.schedule()) |thread| {
        uart.puts("  Scheduled: thread ");
        putDec(thread.id);
        uart.puts("\n");
    }

    // Set up timer preemption
    uart.puts("Starting timer (10ms slice)...\n");
    exception.setTimerHandler(&timerTick);
    enableTimerIRQ();
    timer.armTimeSlice();
    enableIRQ();

    uart.puts("Phase 1.6 complete! Timer preemption active.\n");

    // Idle loop — timer IRQs will fire and show tick markers
    while (true) {
        asm volatile ("wfe");
    }
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
