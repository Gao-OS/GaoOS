// ARM Generic Timer (EL1 Virtual Timer)
//
// The Cortex-A53 provides a generic timer with virtual and physical
// counters. We use the EL1 virtual timer (CNTV) for scheduler ticks.
//
// On raspi3b, the timer frequency is 62.5 MHz (CNTFRQ_EL0 = 62500000).
// A 10ms time slice = 625000 ticks.

/// Read the timer frequency (ticks per second).
pub fn getFrequency() u64 {
    return asm ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}

/// Read the current virtual counter value.
pub fn getCount() u64 {
    return asm ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (-> u64),
    );
}

/// Set the virtual timer compare value (fires IRQ when counter >= value).
pub fn setCompareValue(val: u64) void {
    asm volatile ("msr cntv_cval_el0, %[val]"
        :
        : [val] "r" (val),
    );
}

/// Enable the virtual timer (unmask and start counting).
pub fn enable() void {
    // CNTV_CTL_EL0: bit 0 = ENABLE, bit 1 = IMASK (0 = not masked)
    asm volatile ("msr cntv_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, 1)),
    );
}

/// Disable the virtual timer.
pub fn disable() void {
    asm volatile ("msr cntv_ctl_el0, %[val]"
        :
        : [val] "r" (@as(u64, 0)),
    );
}

/// Arm the timer to fire after `ticks` from now.
pub fn armAfter(ticks: u64) void {
    const now = getCount();
    setCompareValue(now + ticks);
    enable();
}

/// Arm the timer for a 10ms time slice (standard BEAM reduction interval).
pub fn armTimeSlice() void {
    const freq = getFrequency();
    // 10ms = freq / 100
    const ticks = freq / 100;
    armAfter(ticks);
}

/// Acknowledge the timer interrupt by rearming for the next slice.
/// Call this from the IRQ handler to prevent continuous firing.
pub fn ack() void {
    armTimeSlice();
}
