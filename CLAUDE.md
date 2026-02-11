# GaoOS — CLAUDE.md

## Project Overview

GaoOS is a capability-based exokernel written in Zig, targeting ARM64 (Raspberry Pi 3+).
The north star is native BEAM (Erlang VM) integration — the kernel is designed so BEAM
processes map directly to kernel primitives instead of emulating them atop POSIX.

## Architecture Principles

1. **Exokernel**: kernel provides mechanisms (hardware multiplexing, isolation), never policy
2. **Capability-based security**: every operation requires a capability — no ambient authority
3. **LibOS model**: runtimes (BEAM, POSIX shim, etc.) run in user space with their own policies
4. **BEAM-native**: IPC, scheduling, and fault notification are designed for BEAM's patterns
5. **Fault isolation**: crashed runtimes cannot affect others; kernel notifies supervisors

## Key Design Constraints

- Capability creation must be near-zero cost (BEAM spawns millions of processes)
- IPC supports tagged messages (for BEAM selective receive) and capability transfer
- Kernel stays under a few thousand lines — complexity lives in LibOS
- No hidden allocations in kernel code — all memory is explicit
- No global mutable state without capabilities

## Build & Run

```bash
devenv shell          # Enter development environment (Zig + QEMU + tools)
gaoos-build           # Build kernel (alias defined in devenv.nix)
gaoos-run             # Boot in QEMU raspi3b with serial console
gaoos-test            # Run kernel unit tests on host
```

## Directory Structure

```
kernel/
  arch/aarch64/       # Boot, MMU, exception vectors, context switch
  src/                # Core kernel: capabilities, IPC, scheduler, memory
platform/raspi/       # Raspberry Pi drivers (UART, GPIO, SPI)
drivers/              # User-space device drivers (e-ink, etc.)
libos/                # LibOS implementations (minimal, beam, posix-shim)
tools/                # Scripts (QEMU runner, etc.)
docs/
  design/             # Design documents
  decisions/          # Architecture Decision Records (ADRs)
```

## Code Conventions

- **Language**: Zig (master/nightly, pinned in devenv.nix)
- **Target**: aarch64-freestanding-none (kernel), aarch64-linux (tests on host)
- **Comments**: explain WHY, not WHAT — no doc comments on obvious code
- **Errors**: use Zig error unions, never panic in kernel (except unrecoverable)
- **MMIO**: always `@as(*volatile u32, @ptrFromInt(addr))` for hardware registers
- **No abstractions for their own sake**: three similar lines > premature abstraction
- **Tests**: unit tests run on host via `zig test`; integration tests via QEMU

## Hardware Targets

| Target | Status | Notes |
|--------|--------|-------|
| QEMU raspi3b | Primary dev | ARM Cortex-A53, 1GB RAM |
| Raspberry Pi 3B+ | Primary HW | Same SoC as QEMU target |
| Raspberry Pi 4/5 | Future | Different MMIO base, GIC |

## Git Conventions

- Conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`
- No "Generated with Claude Code" or "Co-Authored-By" trailers
- Keep commits atomic — one logical change per commit
