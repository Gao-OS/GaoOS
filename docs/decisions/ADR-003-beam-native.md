## ADR-003: BEAM-Native Integration as North Star

**Status**: Accepted

### Context

GaoOS could be a general-purpose exokernel, a POSIX-compatible microkernel, or
a purpose-built platform for a specific runtime. This decision defines the
project's reason for existence and drives every kernel design choice.

### Decision

Design the kernel specifically so that BEAM (Erlang VM) concepts map directly
to kernel primitives, eliminating the POSIX impedance mismatch.

### What This Drives

**IPC design:**
- Messages carry a `tag: u64` field — exists because BEAM's `receive` does
  selective pattern matching. Without tags, the kernel would need to inspect
  message payloads, violating the exokernel principle.
- Messages carry capability transfer slots — exists because BEAM processes
  communicate by sending references. Capability transfer in IPC means a BEAM
  `send` that includes a port or reference can transfer the underlying kernel
  capability in a single operation.
- Bounded inline payload (256 bytes) — most BEAM messages are small terms.
  Large binaries use shared-memory capabilities for zero-copy.

**Capability system:**
- Near-zero-cost creation — BEAM spawns millions of lightweight processes.
  Each process needs a capability table. If capability creation costs a
  syscall + allocation, BEAM's spawn rate becomes the bottleneck.
- Attenuation-only derivation — maps to BEAM's model where a child process
  can receive a subset of its parent's capabilities, never more.

**Fault notification:**
- Kernel delivers structured death messages to supervisor endpoints —
  maps directly to OTP supervisor `handle_info({:EXIT, pid, reason})`.
- Includes capability cleanup information — the supervisor knows exactly
  what resources were held by the dead process.

**Scheduler:**
- Kernel provides mechanism (context switch, timer preemption), not policy.
  The BEAM LibOS implements its own reduction-based scheduling on top of
  kernel threads, matching BEAM's existing scheduler architecture.

**Address space model:**
- Per-process page tables with user-controlled virtual memory layout.
  BEAM can implement its per-process heap model natively instead of
  using `mmap` to simulate it.

### Consequences

**Positive:**
- BEAM on GaoOS can be fundamentally more efficient than BEAM on Linux:
  no double-scheduling, no unnecessary copies, no POSIX translation layer.
- Fault isolation is real: a crashed BEAM node doesn't take down other
  runtimes running on the same hardware.
- The kernel stays small because BEAM-specific complexity lives in the
  BEAM LibOS, not in the kernel.

**Negative:**
- Non-BEAM workloads need their own LibOS (e.g., POSIX shim).
  This is by design but limits general-purpose use.
- BEAM erts modifications are needed — the upstream BEAM assumes POSIX.
  We'll need a platform abstraction layer in erts.
- The project's value proposition depends on successfully integrating
  BEAM — if that fails, the kernel alone has limited utility.

### Alternatives Considered

**General-purpose exokernel (no BEAM focus):** would work but produce
yet another research OS with no clear user. The BEAM focus gives every
design decision a concrete motivation.

**POSIX-compatible microkernel:** would make BEAM integration trivial
(just compile erts for the new OS) but wouldn't unlock any performance
or architecture benefits — just another slow POSIX.

**BEAM-only (no LibOS model):** tempting but fragile. The LibOS model
means other runtimes (POSIX shim for tooling, isolated drivers) can
coexist. BEAM is the primary citizen, not the only citizen.
