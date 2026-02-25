// E-Ink User-Space Driver for GaoOS
//
// Demonstrates the exokernel driver model: this user-space driver
// controls a Waveshare e-ink display using only capabilities.
// Under QEMU (no real SPI), it uses mock SPI over UART to produce
// a readable command trace.
//
// The driver:
//   1. Initializes mock SPI over UART
//   2. Runs the Waveshare init sequence
//   3. Writes a test pattern to display RAM
//   4. Triggers a display refresh
//   5. Enters deep sleep mode
//
// Entry point: eink_main() — called as a thread via SYS_THREAD_CREATE.

const libos = @import("libos");
const io = libos.io;
const sys = libos.syscall;
const waveshare = @import("waveshare");
const spi_mock = @import("spi_mock");

/// Entry point for the e-ink driver thread.
/// Expects cap[0] = UART device capability.
pub fn einkMain() callconv(.{ .aarch64_aapcs = .{} }) noreturn {
    const UART_CAP: u32 = 0;

    io.println(UART_CAP, "  [E-Ink] driver starting");

    // Initialize mock SPI (uses UART cap for output)
    spi_mock.init(UART_CAP);

    io.println(UART_CAP, "  [E-Ink] init sequence:");
    waveshare.init(&spi_mock.writeByte);

    io.println(UART_CAP, "  [E-Ink] writing test pattern:");
    waveshare.writeTestPattern(&spi_mock.writeByte);
    spi_mock.flush();

    io.println(UART_CAP, "  [E-Ink] refresh:");
    waveshare.refresh(&spi_mock.writeByte);

    io.println(UART_CAP, "  [E-Ink] deep sleep:");
    waveshare.deepSleep(&spi_mock.writeByte);

    io.println(UART_CAP, "  [E-Ink] driver done.");
    sys.exit();
}
