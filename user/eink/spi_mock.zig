// Mock SPI over UART for QEMU Testing
//
// Since QEMU raspi3b does not emulate SPI, this mock replaces real SPI
// transfers with human-readable UART output. The e-ink driver uses this
// mock transparently — demonstrating the exokernel model where drivers
// access hardware only through capabilities.
//
// Output format:
//   "SPI CMD: 0xNN" for command bytes
//   "SPI DAT: 0xNN" for data bytes
//   "SPI DAT: ... (N bytes)" for bulk data transfers

const libos = @import("libos");
const io = libos.io;

var uart_cap: u32 = 0;
var data_count: u32 = 0; // Counts consecutive data bytes for bulk summary
const BULK_THRESHOLD: u32 = 8; // After this many data bytes, summarize

/// Initialize the mock SPI with a UART capability for output.
pub fn init(cap: u32) void {
    uart_cap = cap;
    data_count = 0;
}

/// Write a byte as command or data, producing readable UART output.
/// This is the WriteFn compatible with waveshare.zig.
pub fn writeByte(byte: u8, is_data: bool) void {
    if (is_data) {
        data_count += 1;
        if (data_count <= BULK_THRESHOLD) {
            io.print(uart_cap, "  SPI DAT: 0x");
            putHex8(byte);
            io.print(uart_cap, "\n");
        } else if (data_count == BULK_THRESHOLD + 1) {
            io.print(uart_cap, "  SPI DAT: ... (bulk data)\n");
        }
        // Beyond threshold: silently skip to avoid flooding UART
    } else {
        // Flush any pending bulk data count
        if (data_count > BULK_THRESHOLD) {
            io.print(uart_cap, "  SPI DAT: total ");
            io.putDec(uart_cap, data_count);
            io.print(uart_cap, " bytes\n");
        }
        data_count = 0;

        io.print(uart_cap, "  SPI CMD: 0x");
        putHex8(byte);
        io.print(uart_cap, "\n");
    }
}

/// Flush any pending bulk data summary.
pub fn flush() void {
    if (data_count > BULK_THRESHOLD) {
        io.print(uart_cap, "  SPI DAT: total ");
        io.putDec(uart_cap, data_count);
        io.print(uart_cap, " bytes\n");
    }
    data_count = 0;
}

fn putHex8(byte: u8) void {
    const hex = "0123456789abcdef";
    var buf: [2]u8 = undefined;
    buf[0] = hex[byte >> 4];
    buf[1] = hex[byte & 0x0F];
    io.print(uart_cap, &buf);
}
