// Waveshare E-Ink Display Command Protocol
//
// Simplified command definitions for Waveshare e-paper displays.
// The full protocol involves LUT (look-up table) configuration,
// but for the Phase 2 demo we use the essential subset:
//   init → write RAM → refresh → deep sleep.
//
// This module is hardware-agnostic — it takes an SPI write function
// and produces the correct byte sequences.

/// E-ink display commands (Waveshare 2.13" / similar)
pub const CMD = struct {
    pub const SW_RESET: u8 = 0x12;
    pub const DRIVER_OUTPUT: u8 = 0x01;
    pub const DATA_ENTRY_MODE: u8 = 0x11;
    pub const SET_RAM_X: u8 = 0x44;
    pub const SET_RAM_Y: u8 = 0x45;
    pub const SET_RAM_X_COUNTER: u8 = 0x4E;
    pub const SET_RAM_Y_COUNTER: u8 = 0x4F;
    pub const WRITE_RAM: u8 = 0x24;
    pub const DISPLAY_UPDATE_CTRL2: u8 = 0x22;
    pub const MASTER_ACTIVATION: u8 = 0x20;
    pub const DEEP_SLEEP: u8 = 0x10;
};

/// Display dimensions (Waveshare 2.13" V2, 250x122)
pub const WIDTH: u16 = 122;
pub const HEIGHT: u16 = 250;
pub const RAM_WIDTH_BYTES: u16 = (WIDTH + 7) / 8; // 16 bytes per row

/// SPI writer function type: command/data byte + is_data flag.
/// Implementations decide how to assert DC pin or use 9-bit SPI.
pub const WriteFn = *const fn (byte: u8, is_data: bool) void;

/// Initialize the display with a minimal configuration.
/// After init, the display is ready to accept RAM writes.
pub fn init(writeByte: WriteFn) void {
    // Software reset
    writeByte(CMD.SW_RESET, false);
    // Normally wait ~10ms for reset; caller handles busy-wait

    // Driver output control: set gate count = HEIGHT - 1
    writeByte(CMD.DRIVER_OUTPUT, false);
    writeByte(@truncate(HEIGHT - 1), true);
    writeByte(@truncate((HEIGHT - 1) >> 8), true);
    writeByte(0x00, true); // GD=0, SM=0, TB=0

    // Data entry mode: X increment, Y increment
    writeByte(CMD.DATA_ENTRY_MODE, false);
    writeByte(0x03, true);

    // Set RAM X address range
    writeByte(CMD.SET_RAM_X, false);
    writeByte(0x00, true); // start
    writeByte(@truncate(RAM_WIDTH_BYTES - 1), true); // end

    // Set RAM Y address range
    writeByte(CMD.SET_RAM_Y, false);
    writeByte(0x00, true); // start low
    writeByte(0x00, true); // start high
    writeByte(@truncate(HEIGHT - 1), true); // end low
    writeByte(@truncate((HEIGHT - 1) >> 8), true); // end high

    // Set RAM counters to origin
    writeByte(CMD.SET_RAM_X_COUNTER, false);
    writeByte(0x00, true);
    writeByte(CMD.SET_RAM_Y_COUNTER, false);
    writeByte(0x00, true);
    writeByte(0x00, true);
}

/// Write a full-screen test pattern to display RAM.
/// Pattern: alternating black/white rows (0xFF = white, 0x00 = black).
pub fn writeTestPattern(writeByte: WriteFn) void {
    writeByte(CMD.WRITE_RAM, false);

    var y: u16 = 0;
    while (y < HEIGHT) : (y += 1) {
        const fill: u8 = if (y % 2 == 0) 0xFF else 0x00;
        var x: u16 = 0;
        while (x < RAM_WIDTH_BYTES) : (x += 1) {
            writeByte(fill, true);
        }
    }
}

/// Trigger a display refresh (full update).
pub fn refresh(writeByte: WriteFn) void {
    writeByte(CMD.DISPLAY_UPDATE_CTRL2, false);
    writeByte(0xF7, true); // Full update sequence
    writeByte(CMD.MASTER_ACTIVATION, false);
    // Normally wait for BUSY pin to go low
}

/// Enter deep sleep mode to conserve power.
pub fn deepSleep(writeByte: WriteFn) void {
    writeByte(CMD.DEEP_SLEEP, false);
    writeByte(0x01, true); // Mode 1: RAM retained
}
