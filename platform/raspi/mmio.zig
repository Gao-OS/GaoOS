// MMIO helpers for BCM2837 (Raspberry Pi 3)
//
// All peripheral access on the Pi goes through memory-mapped I/O.
// Reads and writes must be volatile to prevent the compiler from
// reordering or eliding them.

pub const PERIPHERAL_BASE: u32 = 0x3F000000;

pub fn read(addr: u32) u32 {
    return @as(*volatile u32, @ptrFromInt(@as(usize, addr))).*;
}

pub fn write(addr: u32, val: u32) void {
    @as(*volatile u32, @ptrFromInt(@as(usize, addr))).* = val;
}

/// Spin-delay for approximately `count` CPU cycles.
/// Not calibrated — used only for hardware timing sequences (GPIO pull config).
pub fn delay(count: u32) void {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        asm volatile ("nop");
    }
}
