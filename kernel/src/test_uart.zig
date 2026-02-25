// No-op UART stub for host-target unit tests.
// Provides the same interface as platform/raspi/uart.zig but does nothing.

pub fn init() void {}
pub fn putc(_: u8) void {}
pub fn puts(_: []const u8) void {}
