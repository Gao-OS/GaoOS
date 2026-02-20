# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Requires Nix with devenv (Zig nightly + QEMU). Minimum Zig version: 0.15.0.

```bash
devenv shell          # Enter development environment
gaoos-build           # Build kernel → zig-out/bin/kernel8.img
gaoos-run             # Boot in QEMU raspi3b with serial console
gaoos-test            # Run all unit tests on host
gaoos-validate        # Verify toolchain cross-compiles for aarch64
```

Without devenv (if Zig nightly is installed):
```bash
zig build             # Build kernel
zig build run         # Build + boot in QEMU
zig build test        # Run all unit tests
```

Running a single test module by name:
```bash
zig build test 2>&1 | head    # All tests (cap, ipc, sched)
zig test kernel/src/cap.zig   # Run only capability tests
zig test kernel/src/ipc.zig   # Run only IPC tests
zig test kernel/src/sched.zig # Run only scheduler tests
```

QEMU with debug flags:
```bash
gaoos-run zig-out/bin/kernel8.img -- -d int,cpu_reset
```

## Kernel Architecture

### Boot Sequence (boot.S → main.zig)

1. `_start` in `boot.S`: park non-primary cores, drop EL3→EL2→EL1, bootstrap MMU with identity-mapped 2MB blocks, clear BSS
2. `kernel_main()` in `main.zig`: init UART, install exception vectors, spawn thread 0 with UART capability, arm 10ms timer, copy user program to 0x200000, enter EL0

### Memory Map

| Address | Use |
|---------|-----|
| `0x70000-0x70FFF` | L1 page table (set up in boot.S) |
| `0x71000-0x71FFF` | L2 page table (512 entries, 2MB blocks) |
| `0x80000` | Kernel load address (`_start`) |
| `0x200000-0x3FFFFF` | User-space program (EL0-accessible, AP=01 set at runtime) |
| `0x3F000000` | BCM2837 peripheral MMIO base |
| `0x3F201000` | PL011 UART base |
| `0x40000000` | QA7 local peripherals (core timer, IRQ source) |
| `0x40000040` | Core 0 timer control (enables virtual timer IRQ) |
| `0x40000060` | Core 0 IRQ source register (bit 3 = CNTVIRQ) |

### Module Dependency Chain (build.zig)

```
Platform:  mmio ← gpio ← uart
Kernel:    cap → ipc → sched → syscall
                              → exception (also depends on uart, syscall, sched)
           mmu (standalone), timer (standalone)
```

### Core Kernel Modules

- **cap.zig**: 256-slot capability table per thread with generation-based invalidation. Types: frame, aspace, thread, ipc_endpoint, irq, device. Rights: read, write, grant, revoke. `derive()` can only attenuate (remove rights), never escalate.
- **ipc.zig**: Endpoints with 16-message ring buffer. Messages carry a tag (u64), 256-byte payload, and up to 4 capability slots. `recv()` supports tag-filtered selective receive (linear scan + reorder).
- **sched.zig**: 64-thread round-robin scheduler. Thread states: free/ready/running/blocked/dead. Global arrays: `cap_tables[64]`, `endpoints[64]`. Timer preemption via `schedule()` called from IRQ handler. Singleton at `sched.global` (package-level `pub var`).
- **syscall.zig**: SVC from EL0 dispatched via ESR_EL1 exception class 0x15. Syscall number in x8, args in x0-x2. Current syscalls: SYS_WRITE(0), SYS_EXIT(1), SYS_YIELD(2), SYS_CAP_READ(3). Error codes: `E_BADCAP(-1)`, `E_BADARG(-2)`, `E_BADSYS(-3)`.
- **kernel/src/mmu.zig**: Portable page table walker (4-level, 4KB granule) + bitmap frame allocator. Host-testable.
- **kernel/arch/aarch64/mmu.zig**: Register-level MMU control (MAIR/TCR/SCTLR/TTBR). Not currently used — boot.S handles bootstrap inline.

### Exception Handling

Exception vectors in `vectors.S` (2KB-aligned at VBAR_EL1, 16 entries × 128 bytes each). Common handler saves full context (31 GP regs + ELR + SPSR = 288 bytes), then dispatches in `exception.zig`:
- IRQ (types 5/9): check BCM2837 Core 0 IRQ source, bit 3 → timer → `schedule()`
- SVC from EL0 (type 8, EC 0x15): → `syscall.dispatch()`

### User-Space Programs

`user_entry.S` contains the first user program. Must be position-independent (no literal pools — only `movz`/`movk` immediates and PC-relative branches). Copied to 0x200000 at boot. Entered via `eret` with ELR_EL1=0x200000, SPSR=0 (EL0).

## Implementation Gotchas

- **Two `mmu.zig` files**: `kernel/src/mmu.zig` is the portable data-structure layer (page table walker, frame allocator, host-testable); `kernel/arch/aarch64/mmu.zig` is the register-level control layer. They serve different purposes.
- **NEON/FP disabled** in the Zig target (`.cpu_features_sub` in build.zig) to avoid 16-byte alignment faults from SIMD stores on naturally 8-byte aligned struct fields. Context zeroing uses field-by-field assignment (`zeroContext()`) for the same reason — never use `@memset` on Context structs.
- **Exception frame layout**: vectors.S saves x0 at `frame[31]`, x1 at `frame[32]` (relocated from mini-push at entry), x2-x29 at `frame[0..27]`. Syscall reads x8 at `frame[6]`.
- **User program must be position-independent**: only `movz`/`movk` immediates and PC-relative branches — no literal pools — because it is memcpy'd to 0x200000 at runtime.

## Project Status

Phase 1 (minimal kernel) is complete: boot, UART, MMU bootstrap, capabilities, IPC, scheduler, syscalls, first EL0 user program. Next phases: LibOS prototype, multi-runtime, BEAM integration. See `docs/design/00_DESIGN.md` for the full roadmap and `docs/decisions/ADR-*.md` for architecture decisions.

## Code Conventions

- **Language**: Zig (master/nightly, pinned in devenv.nix)
- **Target**: aarch64-freestanding-none (kernel), host target (tests)
- **Comments**: explain WHY, not WHAT — no doc comments on obvious code
- **Errors**: use Zig error unions, never panic in kernel (except unrecoverable)
- **MMIO**: always `@as(*volatile u32, @ptrFromInt(addr))` for hardware registers
- **No abstractions for their own sake**: three similar lines > premature abstraction
- **Tests**: unit tests run on host via `zig test`; integration tests via QEMU

## Git Conventions

- Conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:` (with optional scope like `feat(syscall):`)
- No "Generated with Claude Code" or "Co-Authored-By" trailers
- Keep commits atomic — one logical change per commit
