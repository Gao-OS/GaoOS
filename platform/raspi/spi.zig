// SPI0 platform driver for BCM2837 (Raspberry Pi 3)
//
// BCM2837 SPI0 is at MMIO base + 0x204000.
// Provides register definitions, GPIO pin setup, and blocking transfer.
//
// QEMU raspi3b does NOT emulate SPI — this module is compiled but only
// exercised on real hardware. For testing, user-space drivers use a mock
// SPI that routes commands through UART (see user/eink/).

const mmio = @import("mmio");
const gpio = @import("gpio");

const SPI_BASE = mmio.PERIPHERAL_BASE + 0x204000;

// SPI0 registers (offsets from SPI_BASE)
pub const CS = SPI_BASE + 0x00; // Control and Status
pub const FIFO = SPI_BASE + 0x04; // TX/RX FIFO
pub const CLK = SPI_BASE + 0x08; // Clock Divider
pub const DLEN = SPI_BASE + 0x0C; // Data Length
pub const LTOH = SPI_BASE + 0x10; // LoSSI TOH
pub const DC = SPI_BASE + 0x14; // DMA DREQ Controls

// CS register bits
pub const CS_CLEAR_TX: u32 = 1 << 4;
pub const CS_CLEAR_RX: u32 = 1 << 5;
pub const CS_TA: u32 = 1 << 7; // Transfer Active
pub const CS_DONE: u32 = 1 << 16; // Transfer Done
pub const CS_TXD: u32 = 1 << 18; // TX FIFO has space
pub const CS_RXD: u32 = 1 << 17; // RX FIFO has data

// SPI GPIO pins (active when set to ALT0)
const SPI_CE0 = 8;
const SPI_MISO = 9;
const SPI_MOSI = 10;
const SPI_SCLK = 11;

/// Initialize SPI0: configure GPIO pins for ALT0 (SPI function),
/// clear FIFOs, and set clock divider.
pub fn init(clock_divider: u32) void {
    // Configure SPI GPIO pins to ALT0
    gpio.setFunction(SPI_CE0, .alt0);
    gpio.setFunction(SPI_MISO, .alt0);
    gpio.setFunction(SPI_MOSI, .alt0);
    gpio.setFunction(SPI_SCLK, .alt0);

    // Clear TX and RX FIFOs
    mmio.write(CS, CS_CLEAR_TX | CS_CLEAR_RX);

    // Set clock divider (SPI clock = core_clk / divider)
    // Default 250MHz core / 256 = ~976kHz — safe for most SPI devices
    mmio.write(CLK, clock_divider);
}

/// Blocking SPI transfer: simultaneously send tx and receive into rx.
/// Both slices must have the same length.
pub fn transfer(tx: []const u8, rx: []u8) void {
    // Assert: tx.len == rx.len
    mmio.write(DLEN, @intCast(tx.len));

    // Clear FIFOs and start transfer
    mmio.write(CS, CS_CLEAR_TX | CS_CLEAR_RX | CS_TA);

    var tx_idx: usize = 0;
    var rx_idx: usize = 0;

    while (rx_idx < rx.len) {
        // Fill TX FIFO when possible
        while (tx_idx < tx.len and (mmio.read(CS) & CS_TXD) != 0) {
            mmio.write(FIFO, tx[tx_idx]);
            tx_idx += 1;
        }

        // Drain RX FIFO when data available
        while (rx_idx < rx.len and (mmio.read(CS) & CS_RXD) != 0) {
            rx[rx_idx] = @truncate(mmio.read(FIFO));
            rx_idx += 1;
        }
    }

    // Wait for DONE, then deassert TA
    while ((mmio.read(CS) & CS_DONE) == 0) {}
    mmio.write(CS, 0); // Deassert TA, clear DONE
}
