# GaoOS

A capability-based exokernel for ARM64, designed for native BEAM (Erlang VM) integration.

## Why

BEAM runs on top of POSIX, which means Erlang's powerful process model (lightweight processes,
supervision trees, message passing) is emulated on top of an OS that doesn't understand it.
GaoOS eliminates this impedance mismatch: kernel IPC *is* message passing, kernel fault
notification *is* supervision, kernel capabilities *are* process permissions.

## Architecture

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│  BEAM LibOS  │  │ POSIX Shim  │  │  E-Ink Drv  │   User space (EL0)
│  (Erlang VM) │  │   LibOS     │  │  (isolated) │   Each has own LibOS
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                 │
═══════╪═════════════════╪═════════════════╪═══════  Capability boundary
       │                 │                 │
┌──────┴─────────────────┴─────────────────┴───────┐
│                   GaoOS Kernel                    │  EL1
│  Capabilities · IPC · Scheduler · MMU · Frames   │  < few KLOC
└──────────────────────────────────────────────────┘
       │
┌──────┴──────────────────────────────────────────┐
│              ARM64 Hardware (RPi 3+)             │
│  Cortex-A53 · 1GB RAM · GPIO · SPI · UART       │
└──────────────────────────────────────────────────┘
```

**Exokernel model**: the kernel multiplexes hardware and enforces isolation via capabilities.
All policy (memory allocation, scheduling priority, driver logic) lives in user-space LibOS
implementations.

## Building

GaoOS uses [devenv](https://devenv.sh/) to manage the development environment.

### Prerequisites

- [Nix](https://nixos.org/download.html) with flakes enabled
- [devenv](https://devenv.sh/getting-started/)

### Setup

```bash
# Enter the development shell (installs Zig, QEMU, and tools)
devenv shell

# Build the kernel
gaoos-build

# Run in QEMU (Raspberry Pi 3B, serial on stdio)
gaoos-run

# Run unit tests on host
gaoos-test
```

### Manual (without devenv)

```bash
# Requires: zig (nightly), qemu-system-aarch64
zig build
qemu-system-aarch64 -M raspi3b -kernel zig-out/bin/kernel8.img -serial stdio -display none
```

## Project Status

GaoOS is in early development.

- [x] Phase 0 — Project scaffolding, toolchain validation
- [x] Phase 1 — Minimal kernel (boot, UART, MMU, capabilities, IPC, scheduler)
- [ ] Phase 2 — LibOS prototype (user-space allocator, e-ink driver)
- [ ] Phase 3 — Multi-runtime (capability delegation, fault supervision)
- [ ] Phase 4 — BEAM integration
- [ ] Phase 5 — Hardware bring-up on physical Raspberry Pi

## Documentation

- [Design Document](docs/design/00_DESIGN.md) — full system design
- [ADR-001: Why Zig](docs/decisions/ADR-001-zig.md)
- [ADR-002: ARM64 First](docs/decisions/ADR-002-arm64-first.md)
- [ADR-003: BEAM-Native](docs/decisions/ADR-003-beam-native.md)

## License

TBD
