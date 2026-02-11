## ADR-002: ARM64 / Raspberry Pi as Primary Target

**Status**: Accepted

### Context

GaoOS needs a concrete hardware target for development. The choice affects
boot sequence, peripheral drivers, MMIO layout, and QEMU testing workflow.

### Decision

Target ARM64 (AArch64) exclusively, with Raspberry Pi 3B+ as the primary
hardware platform and `qemu-system-aarch64 -M raspi3b` as the development target.

### Consequences

**Positive:**
- **QEMU parity**: `raspi3b` machine in QEMU accurately models the BCM2837,
  so code developed in QEMU works on real hardware with minimal changes.
- **Simple boot**: the Raspberry Pi firmware loads `kernel8.img` to 0x80000
  and jumps to it. No bootloader (UEFI/GRUB) complexity.
- **Clean architecture**: ARMv8-A has a well-defined exception level model
  (EL0-EL3), standard page table format, and a single interrupt controller
  per SoC variant. No legacy x86 baggage (real mode, A20, PIC/APIC, etc.).
- **Embedded focus**: the RPi's GPIO, SPI, and I2C peripherals enable the
  e-ink display and other physical I/O — core to the GaoOS use case.
- **BEAM on ARM**: Erlang/OTP officially supports ARM64 Linux. The BEAM erts
  cross-compiles cleanly for aarch64.

**Negative:**
- **No x86 support**: rules out running on commodity PCs and most cloud VMs.
  Acceptable because GaoOS targets embedded BEAM workloads, not servers.
- **RPi firmware is closed-source**: the VideoCore GPU firmware blob is
  required for boot. We depend on it but don't control it.
- **Single-vendor SoC**: BCM2837 specifics (MMIO layout, mini UART, mailbox
  interface) are not portable. Future Pi 4/5 support will require platform
  abstraction. Deferred until Phase 5.

### Alternatives Considered

**x86_64**: Larger community, more QEMU/KVM tooling, but boot complexity
(UEFI, multiboot, legacy mode transitions) would dominate Phase 1 effort.
No GPIO/SPI for hardware peripherals without additional boards.

**RISC-V**: Clean ISA, open hardware, but QEMU support is less mature for
specific board models. Fewer physical board options at RPi's price point.
Could be a future secondary target.

**Multi-architecture from day one**: would force premature abstraction in
boot, MMU, and exception handling. Better to get one architecture solid
and abstract later.
