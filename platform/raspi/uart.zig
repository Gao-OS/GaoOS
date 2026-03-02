// PL011 UART driver for BCM2837 (Raspberry Pi 3)
//
// QEMU raspi3b maps PL011 (UART0) to the first -serial device (stdio).
// PL011 is at PERIPHERAL_BASE + 0x201000, using GPIO 14 (TX) / 15 (RX) alt0.
// On real hardware, the RPi firmware may assign PL011 to Bluetooth;
// we'll handle that distinction at a higher level when needed.

const mmio = @import("mmio.zig");
const gpio = @import("gpio.zig");

const UART0_BASE = mmio.PERIPHERAL_BASE + 0x201000;

const UART0_DR = UART0_BASE + 0x00; // Data register
const UART0_FR = UART0_BASE + 0x18; // Flag register
const UART0_IBRD = UART0_BASE + 0x24; // Integer baud rate divisor
const UART0_FBRD = UART0_BASE + 0x28; // Fractional baud rate divisor
const UART0_LCRH = UART0_BASE + 0x2C; // Line control register
const UART0_CR = UART0_BASE + 0x30; // Control register
const UART0_ICR = UART0_BASE + 0x44; // Interrupt clear register

pub fn init() void {
    // Disable UART0 while configuring
    mmio.write(UART0_CR, 0);

    // Configure GPIO 14/15 for UART0 (alt0)
    gpio.setFunction(14, .alt0);
    gpio.setFunction(15, .alt0);
    gpio.setPull(14, .none);
    gpio.setPull(15, .none);

    // Clear pending interrupts
    mmio.write(UART0_ICR, 0x7FF);

    // Baud rate 115200 with 48MHz UART clock:
    //   divisor = 48000000 / (16 * 115200) = 26.041...
    //   integer part = 26, fractional part = round(0.041 * 64) = 3
    // Note: QEMU doesn't care about baud rate, but real hardware does.
    mmio.write(UART0_IBRD, 26);
    mmio.write(UART0_FBRD, 3);

    // 8 bits, no parity, 1 stop bit, enable FIFOs
    mmio.write(UART0_LCRH, (1 << 4) | (1 << 5) | (1 << 6)); // FEN | WLEN 8-bit

    // Enable UART0, TX, and RX
    mmio.write(UART0_CR, (1 << 0) | (1 << 8) | (1 << 9)); // UARTEN | TXE | RXE
}

pub fn putc(c: u8) void {
    // Wait until TX FIFO is not full (bit 5 of FR = TXFF)
    while (mmio.read(UART0_FR) & (1 << 5) != 0) {
        asm volatile ("nop");
    }
    mmio.write(UART0_DR, c);
}

pub fn puts(s: []const u8) void {
    for (s) |c| {
        if (c == '\n') putc('\r');
        putc(c);
    }
}
