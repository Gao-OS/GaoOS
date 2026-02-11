// GPIO configuration for BCM2837 (Raspberry Pi 3)
//
// Each GPIO pin can be set to one of 8 functions (input, output, alt0-alt5).
// GPFSEL registers control function selection: 3 bits per pin, 10 pins per register.

const mmio = @import("mmio.zig");

const GPIO_BASE = mmio.PERIPHERAL_BASE + 0x200000;

// GPIO function select registers (3 bits per pin, 10 pins per 32-bit register)
const GPFSEL0 = GPIO_BASE + 0x00;
const GPFSEL1 = GPIO_BASE + 0x04;
// Pin pull-up/down control
const GPPUD = GPIO_BASE + 0x94;
const GPPUDCLK0 = GPIO_BASE + 0x98;

pub const Function = enum(u3) {
    input = 0b000,
    output = 0b001,
    alt0 = 0b100,
    alt1 = 0b101,
    alt2 = 0b110,
    alt3 = 0b111,
    alt4 = 0b011,
    alt5 = 0b010,
};

pub const Pull = enum(u2) {
    none = 0b00,
    up = 0b01,
    down = 0b10,
};

pub fn setFunction(pin: u32, func: Function) void {
    // Each GPFSEL register covers 10 pins, 3 bits each
    const reg = GPIO_BASE + (pin / 10) * 4;
    const shift: u5 = @intCast((pin % 10) * 3);

    var val = mmio.read(reg);
    val &= ~(@as(u32, 0x7) << shift); // clear 3-bit field
    val |= @as(u32, @intFromEnum(func)) << shift;
    mmio.write(reg, val);
}

pub fn setPull(pin: u32, pull: Pull) void {
    // BCM2837 pull-up/down sequence:
    // 1. Write to GPPUD to set the desired pull state
    // 2. Wait 150 cycles
    // 3. Write to GPPUDCLK0/1 to clock the control signal into the pin
    // 4. Wait 150 cycles
    // 5. Clear GPPUD and GPPUDCLK

    mmio.write(GPPUD, @intFromEnum(pull));
    mmio.delay(150);

    const clk_reg = GPPUDCLK0 + (pin / 32) * 4;
    mmio.write(clk_reg, @as(u32, 1) << @intCast(pin % 32));
    mmio.delay(150);

    mmio.write(GPPUD, 0);
    mmio.write(clk_reg, 0);
}
