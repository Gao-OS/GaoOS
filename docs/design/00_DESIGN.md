# GaoOS Design Document

## 1. Vision

GaoOS is a capability-based exokernel that makes the BEAM virtual machine a first-class
citizen of the operating system. Instead of layering Erlang's process model on top of POSIX
abstractions, GaoOS provides kernel primitives that map directly to BEAM concepts:

| BEAM Concept | POSIX Translation | GaoOS Native |
|---|---|---|
| Process | OS thread + mailbox | Lightweight thread + IPC endpoint |
| Message passing | Shared memory + locks | Tagged IPC with capability transfer |
| Supervision | Signal handlers + PID files | Kernel fault notification |
| Process isolation | mmap + mprotect | Capability-gated address spaces |
| Distribution | TCP sockets | IPC channels (local) / network transport (remote) |

## 2. Architecture

### 2.1 Exokernel Principles

The kernel's job is hardware multiplexing and isolation — nothing more.

**Kernel provides:**
- Physical frame allocation (but not virtual memory policy)
- IPC message transport (but not message format or protocol)
- Thread scheduling mechanism (but not scheduling policy)
- Capability creation and validation (but not access control policy)
- Exception delivery (but not error handling policy)

**LibOS provides:**
- Memory allocation algorithms (bump, slab, buddy — whatever the runtime needs)
- Scheduling policy (priority, fairness, real-time — configured per runtime)
- Device driver logic (runs in isolated user space)
- Application protocols (built on IPC)
- BEAM-specific optimizations (shared-nothing heaps, GC coordination)

### 2.2 Capability Model

Every kernel object is accessed exclusively through capabilities. A capability is:

```
Capability {
    cap_type:   CapabilityType,  // frame, aspace, thread, ipc_endpoint, irq, device
    object:     usize,           // opaque handle: ThreadId, frame address, etc.
    rights:     Rights,          // read, write, grant, revoke (bitmask)
    generation: u32,             // monotonically increasing; prevents stale index reuse
}
```

**Invariants:**
1. No operation without a valid capability (no ambient authority)
2. Capabilities can only be attenuated (derived with fewer rights), never amplified
3. Capabilities are unforgeable (kernel-managed indices, not pointers)
4. Deleted capabilities are immediately invalidated

**Design for BEAM scale:** The capability table must support millions of entries because
BEAM spawns lightweight processes freely. Phase 1 uses a fixed-size array; the interface
is designed so the backing store can evolve to hash tables or arena-based allocation.

### 2.3 IPC

IPC is the hot path — every BEAM message flows through it.

```
Message {
    tag:     u64,              // for BEAM selective receive
    payload: [256]u8,          // inline small messages
    caps:    [4]CapIndex,      // capability transfer slots
}
```

**Design choices for BEAM:**
- **Tagged messages**: BEAM's `receive` can pattern-match on message shape. The `tag` field
  enables the kernel to do first-pass filtering without inspecting payload.
- **Capability transfer**: sending a message can transfer capabilities to the receiver,
  enabling delegation patterns that map to BEAM's process linking/monitoring.
- **Bounded inline payload**: most BEAM messages are small. Large data uses shared-memory
  capabilities (cap_shmem) for zero-copy transfer.

### 2.4 Fault Notification

When a thread dies, the kernel:
1. Closes the thread's IPC endpoint (no more sends accepted)
2. Wakes threads blocked on that endpoint (they receive E_CLOSED)
3. Sends a fault message to the thread's registered supervisor endpoint

The dead thread's cap table and resources are cleaned up lazily when the
supervisor calls SYS_THREAD_REAP. This is the exokernel policy: the kernel
provides the mechanism (death notification), the supervisor provides the
policy (what to do with the dead thread's resources).

This maps directly to BEAM supervision trees. An OTP supervisor is a thread whose
IPC endpoint receives death notifications from its children.

### 2.5 Address Space Model

- **Kernel (EL1)**: mapped via TTBR1_EL1 (upper half), shared across all address spaces
- **User (EL0)**: mapped via TTBR0_EL1 (lower half), per-process page tables
- **Device MMIO**: mapped into user space via capabilities (cap_device), not globally visible

LibOS controls virtual memory layout. The kernel only ensures isolation: a user-space
page table entry requires a capability for the underlying physical frame.

## 3. Hardware Platform

### 3.1 Primary Target: Raspberry Pi 3B+

- **SoC**: BCM2837B0 (4x Cortex-A53 @ 1.4GHz)
- **RAM**: 1GB LPDDR2
- **Peripherals**: UART, SPI, I2C, GPIO, USB, Ethernet
- **MMIO base**: 0x3F000000
- **Kernel load address**: 0x80000

### 3.2 QEMU Development Target

`qemu-system-aarch64 -M raspi3b` provides cycle-accurate emulation of the Pi 3B.
Primary development and testing happens here before hardware bring-up.

### 3.3 Planned Hardware

- **E-ink display**: Waveshare SPI display, driven as isolated user-space driver
- **Raspberry Pi 4/5**: future targets (different peripheral base, GICv2)

## 4. Phase Plan

### Phase 1: Minimal Kernel
Boot on QEMU, UART output, exception vectors, MMU with identity mapping,
capability system, IPC, round-robin scheduler, first user-space program.

### Phase 2: LibOS Prototype
User-space memory allocator, syscall interface, Waveshare e-ink driver as
isolated user-space process demonstrating the capability-based driver model.

### Phase 3: Multi-Runtime
Capability delegation between runtimes, fault notification/supervision protocol,
two independent LibOS instances sharing capabilities safely.

### Phase 4: BEAM Integration
POSIX-shim LibOS for BEAM erts bootstrap, BEAM process-to-IPC mapping,
supervision tree integration, distribution transport over IPC.

### Phase 5: Hardware & Polish
Physical Raspberry Pi bring-up, e-ink display demo, performance optimization,
multi-core support.

## 5. Non-Goals (Explicit)

- **POSIX compliance**: we provide a minimal shim for BEAM bootstrap, not full POSIX
- **Multi-architecture**: ARM64 only; x86 is not planned
- **General-purpose OS**: GaoOS is purpose-built for BEAM workloads on embedded ARM
- **Filesystem**: not in kernel; if needed, implemented as LibOS + block device caps
- **Network stack**: not in kernel; BEAM provides its own networking via driver caps
- **GUI**: the e-ink display is driven directly via SPI, no windowing system

## 6. Open Questions

- **Capability revocation**: epoch-based vs. indirection table vs. proxy objects
- **Multi-core scheduling**: per-core run queues vs. work stealing vs. BEAM-directed affinity
- **GC/capability interaction**: how BEAM GC interacts with capability lifecycle
- **Large message optimization**: shared-memory protocol for messages > 256 bytes
