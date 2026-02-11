## ADR-001: Zig as Kernel Implementation Language

**Status**: Accepted

### Context

GaoOS is a capability-based exokernel targeting ARM64 bare metal. The kernel must:
- Run freestanding (no OS, no libc)
- Interact with hardware via MMIO and inline assembly
- Be auditable (small, readable codebase)
- Interoperate with existing C code (Waveshare drivers, potentially BEAM erts)
- Cross-compile to aarch64 from any development host

### Decision

Use Zig as the primary kernel language.

### Consequences

**Positive:**
- **No hidden allocations**: Zig has no hidden control flow or memory allocation.
  Every allocation is explicit, which is critical for a kernel that must never
  unexpectedly run out of memory.
- **Comptime**: compile-time evaluation replaces C macros and code generation.
  Page table setup, MMIO register definitions, and capability type tables can be
  computed at compile time with full type safety.
- **C interop**: Zig can import C headers and compile C files directly.
  Waveshare's C drivers can be included without a separate build step.
- **Built-in cross-compilation**: `zig build -Dtarget=aarch64-freestanding-none`
  works out of the box — no separate cross-toolchain setup.
- **Freestanding target support**: Zig's standard library has a freestanding mode
  that provides data structures without OS dependencies.
- **Inline assembly**: first-class `asm volatile` for MSR/MRS, barrier instructions,
  and exception vector setup.
- **Error unions**: enforce error handling at every call site without exceptions.
  Kernel code cannot accidentally ignore errors.
- **Safety in debug builds**: bounds checking, undefined behavior detection help
  catch bugs during QEMU development.

**Negative:**
- **Nightly/unstable**: Zig hasn't reached 1.0. Language and stdlib may change.
  Mitigated by pinning a specific version in devenv.nix.
- **Smaller ecosystem**: fewer libraries and less community tooling than C or Rust.
  Acceptable because kernel code is small and self-contained.
- **BEAM erts is C**: integrating BEAM will require C interop at the LibOS boundary.
  Zig's C compilation support makes this tractable.

### Alternatives Considered

**C**: Maximum hardware ecosystem support, but no safety guarantees, macro-heavy
code is hard to audit, no built-in cross-compilation story.

**Rust**: Strong safety guarantees, but `#![no_std]` kernel development requires
fighting the borrow checker in contexts where it doesn't help (MMIO, page tables).
No built-in C compilation — would need bindgen + separate C toolchain.

**Assembly only**: Maximum control, but unmaintainable beyond boot stubs.
Used only for the minimal boot path and context switch.
