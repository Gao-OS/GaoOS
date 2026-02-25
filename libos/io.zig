// Formatted I/O over SYS_WRITE
//
// Every output function requires a UART device capability index.
// This is the exokernel way — no ambient I/O authority.

const sys = @import("syscall.zig");

pub fn print(uart_cap: u32, str: []const u8) void {
    _ = sys.write(uart_cap, str.ptr, str.len);
}

pub fn println(uart_cap: u32, str: []const u8) void {
    print(uart_cap, str);
    print(uart_cap, "\n");
}

pub fn putDec(uart_cap: u32, val: u64) void {
    if (val == 0) {
        print(uart_cap, "0");
        return;
    }
    var buf: [20]u8 = undefined;
    var n = val;
    var i: usize = 0;
    while (n > 0) {
        buf[i] = @intCast((n % 10) + '0');
        n /= 10;
        i += 1;
    }
    // Reverse in place
    var lo: usize = 0;
    var hi: usize = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    _ = sys.write(uart_cap, &buf, i);
}

pub fn putHex(uart_cap: u32, val: u64) void {
    const hex = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var v = val;
    var i: usize = 16;
    while (i > 0) {
        i -= 1;
        buf[i] = hex[@truncate(v & 0xF)];
        v >>= 4;
    }
    // Skip leading zeros
    var start: usize = 0;
    while (start < 15 and buf[start] == '0') start += 1;
    _ = sys.write(uart_cap, buf[start..].ptr, 16 - start);
}
