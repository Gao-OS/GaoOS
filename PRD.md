# PRD: GaoOS Phase 2 (LibOS Prototype) + Phase 3 (Multi-Runtime)

This document specifies the implementation plan for Phases 2 and 3 of GaoOS.
It is structured for consumption by loki-mode (autonomous multi-agent implementation).

## Current State (Phase 1 — Complete)

**Kernel**: ~2,400 lines of Zig + ARM64 assembly, 24 host unit tests passing.

**Implemented:**
- Boot (EL3→EL2→EL1), UART, identity-mapped MMU (2MB blocks in boot.S)
- Capability system: 256-slot table, 6 types, 4 rights, generation-based invalidation
- IPC: 16-message ring buffer, tagged messages, 256-byte payload, 4 cap transfer slots
- Scheduler: 64-thread round-robin, timer preemption (10ms), block/unblock
- Syscalls: SYS_WRITE(0), SYS_EXIT(1), SYS_YIELD(2), SYS_CAP_READ(3)
- First EL0 user program (position-independent ASM, copied to 0x200000)

**Memory Map:**
| Range | Use |
|-------|-----|
| `0x70000-0x71FFF` | L1+L2 page tables (boot.S) |
| `0x80000+` | Kernel image |
| `0x200000-0x3FFFFF` | User-space (single 2MB block, AP=01) |
| `0x3F000000+` | BCM2837 peripheral MMIO |
| `0x40000000+` | QA7 local peripherals |

**Module Dependency Chain (build.zig):**
```
Platform:  mmio ← gpio ← uart
Kernel:    cap → ipc → sched → syscall
                              → exception (also depends on uart, syscall, sched)
           mmu (standalone), timer (standalone)
```

---

## Milestone Overview

```
M2.0  Update README ──────────────────────────────────────┐
M2.1  Frame allocator ────────────────────────────────────┤
M2.2  Memory syscalls ──── depends on M2.1 ───────────────┤
M2.3  LibOS library ────── depends on M2.2 ───────────────┤
M2.4  IPC syscalls ─────── depends on M2.3 ───────────────┤
M2.5  Thread creation ──── depends on M2.3 ───────────────┤
M2.6  SPI + e-ink ──────── depends on M2.4, M2.5 ────────┤
M2.7  Per-process aspace ─ depends on M2.5 (stretch) ────┤
M3.1  Fault notification ─ depends on M2.5 ───────────────┤
M3.2  Cap delegation ───── depends on M2.4, M3.1 ────────┤
M3.3  Multi-runtime demo ─ depends on M3.1, M3.2 ────────┘
```

**Dependency rules:** M2.0 and M2.1 are independent. Everything else chains as shown. M2.4 and M2.5 are independent of each other but both depend on M2.3. M2.7 is a stretch goal.

---

## Full Syscall Table

After Phase 3, the kernel exposes 19 syscalls. Convention: `x8`=number, `x0-x5`=args, `x0`=return.

| # | Name | Args | Returns | Phase |
|---|------|------|---------|-------|
| 0 | `SYS_WRITE` | `cap_idx, buf_ptr, buf_len` | bytes written | 1 (done) |
| 1 | `SYS_EXIT` | — | noreturn | 1 (done) |
| 2 | `SYS_YIELD` | — | 0 | 1 (done) |
| 3 | `SYS_CAP_READ` | `cap_idx` | cap_type as u64 | 1 (done) |
| 4 | `SYS_FRAME_ALLOC` | — | frame cap_idx | 2.2 |
| 5 | `SYS_FRAME_FREE` | `cap_idx` | 0 | 2.2 |
| 6 | `SYS_CAP_DERIVE` | `src_cap_idx, new_rights` | new cap_idx | 2.2 |
| 7 | `SYS_CAP_DELETE` | `cap_idx` | 0 | 2.2 |
| 8 | `SYS_FRAME_PHYS` | `cap_idx` | phys_addr | 2.2 |
| 9 | `SYS_IPC_SEND` | `ep_cap_idx, msg_ptr, msg_len` | 0 | 2.4 |
| 10 | `SYS_IPC_RECV` | `ep_cap_idx, buf_ptr, tag_filter` | msg_len | 2.4 |
| 11 | `SYS_EP_CREATE` | — | ep cap_idx | 2.4 |
| 12 | `SYS_THREAD_CREATE` | `entry_pc, stack_ptr` | thread cap_idx | 2.5 |
| 13 | `SYS_THREAD_GRANT` | `thread_cap_idx, cap_idx` | 0 | 2.5 |
| 14 | `SYS_IPC_SEND_WITH_TAG` | `ep_cap_idx, msg_ptr, msg_len, tag` | 0 | 2.4 |
| 15 | `SYS_EP_GRANT` | `ep_cap_idx, thread_cap_idx` | new ep_cap_idx | 2.4 |
| 16 | `SYS_SUPERVISOR_SET` | `thread_cap_idx, ep_cap_idx` | 0 | 3.1 |
| 17 | `SYS_IPC_SEND_CAP` | `ep_cap_idx, msg_ptr, msg_len, cap_to_send` | 0 | 3.2 |
| 18 | `SYS_IPC_RECV_CAP` | `ep_cap_idx, buf_ptr, tag_filter` | msg_len (cap in x1) | 3.2 |

**Error codes** (returned in x0, negative = error):
| Code | Name | Meaning |
|------|------|---------|
| 0 | `E_OK` | Success |
| -1 | `E_BADCAP` | Invalid or insufficient capability |
| -2 | `E_BADARG` | Invalid argument |
| -3 | `E_BADSYS` | Unknown syscall number |
| -4 | `E_NOMEM` | Out of memory (frame allocator exhausted) |
| -5 | `E_FULL` | Queue full (IPC) or table full (caps/threads) |
| -6 | `E_CLOSED` | Endpoint closed |
| -7 | `E_AGAIN` | No matching message (non-blocking recv) |

---

## Milestone Details

### M2.0: Update README

**Goal:** Mark Phase 1 complete in README.md.

**Changes:**
- `README.md` line 75: `- [ ] Phase 1` → `- [x] Phase 1`

**Acceptance criteria:**
- [x] Checkbox is checked
- [x] No other changes

---

### M2.1: Kernel Frame Allocator

**Goal:** Bitmap-based physical frame allocator managing user-space memory pool (0x400000–0x3FFFFFF, ~60MB). This provides the mechanism for user-space memory allocation — LibOS decides policy.

**Why 0x400000?** The first 4MB (0x0–0x3FFFFF) is reserved: 0x0–0x7FFFF for page tables and boot data, 0x80000+ for the kernel image, 0x200000–0x3FFFFF for the initial user program. The allocatable pool starts at 0x400000 (the third 2MB block).

**Data structures:**
```zig
// kernel/src/frame.zig
pub const FRAME_SIZE = 4096;           // 4KB frames
pub const USER_POOL_START = 0x400000;  // Start of allocatable memory
pub const USER_POOL_END = 0x3FFFFFF;   // End (inclusive), ~60MB
pub const TOTAL_FRAMES = (USER_POOL_END - USER_POOL_START + 1) / FRAME_SIZE; // 15104 frames

pub const FrameAllocator = struct {
    bitmap: [TOTAL_FRAMES / 64 + 1]u64,  // ~236 u64s, statically allocated
    free_count: u32,

    pub fn init() FrameAllocator;
    pub fn alloc(self: *FrameAllocator) error{OutOfMemory}!u64;  // returns phys addr
    pub fn free(self: *FrameAllocator, paddr: u64) error{InvalidFrame}!void;
    pub fn isAllocated(self: *const FrameAllocator, paddr: u64) bool;
};
```

**Key decisions:**
- Static bitmap array (no heap allocation needed in kernel)
- Frame addresses are absolute physical addresses (not indices)
- The allocator validates frame addresses are within the user pool
- Singleton instance: `pub var global: FrameAllocator = FrameAllocator.init();`

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `kernel/src/frame.zig` | **Create** | Bitmap frame allocator + unit tests |
| `build.zig` | **Modify** | Add `frame` module to kernel dependency chain |

**build.zig pattern:** Add as standalone module (no dependencies), similar to how `timer` is added. Also add to host test step.

**Tests (host):** ~6 tests
1. `alloc returns valid frame address` — address is within pool and page-aligned
2. `alloc exhausts pool` — after TOTAL_FRAMES allocs, next returns OutOfMemory
3. `free and realloc` — freed frame can be reallocated
4. `free invalid address` — returns InvalidFrame for out-of-range or unaligned
5. `double free` — returns InvalidFrame
6. `isAllocated reports correctly` — true after alloc, false after free

**Acceptance criteria:**
- `zig build test` passes with new frame allocator tests
- `zig build` cross-compiles for aarch64 without errors
- Allocator uses no dynamic memory (all static arrays)
- Frame addresses are within USER_POOL_START..USER_POOL_END

---

### M2.2: Expanded Syscalls (Memory + Capability Management)

**Goal:** Expose frame allocation, frame freeing, capability derivation, capability deletion, and frame physical address query to user space.

**New syscalls:**

**SYS_FRAME_ALLOC (4):** `frame_alloc() → cap_idx`
- Allocates a physical frame via `frame.global.alloc()`
- Creates a `frame` capability with `READ_WRITE` rights in the calling thread's cap table
- The cap's `object` field stores the physical address
- Returns the new cap index, or `E_NOMEM` / `E_FULL`

**SYS_FRAME_FREE (5):** `frame_free(cap_idx) → 0`
- Looks up cap at `cap_idx`, verifies it's a `frame` type
- Frees the physical frame via `frame.global.free()`
- Deletes the capability from the thread's table
- Returns 0, or `E_BADCAP`

**SYS_CAP_DERIVE (6):** `cap_derive(src_cap_idx, new_rights) → new_cap_idx`
- Calls `cap_table.derive(src_cap_idx, new_rights)`
- Returns new cap index, or `E_BADCAP` (invalid/escalation) / `E_FULL`

**SYS_CAP_DELETE (7):** `cap_delete(cap_idx) → 0`
- Calls `cap_table.delete(cap_idx)`
- Returns 0, or `E_BADCAP`

**SYS_FRAME_PHYS (8):** `frame_phys(cap_idx) → phys_addr`
- Looks up cap at `cap_idx`, verifies it's a `frame` type with `read` right
- Returns the physical address stored in `cap.object`
- Returns `E_BADCAP` if invalid

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `kernel/src/syscall.zig` | **Modify** | Add 5 new syscall handlers + new error codes |
| `build.zig` | **Modify** | Add `frame` import to syscall module |

**build.zig change:** The `syscall` module needs a new import: `frame`. Add `.{ .name = "frame", .module = frame }` to syscall's imports list.

**Tests (QEMU integration):** 1 test
1. User program that calls SYS_FRAME_ALLOC, SYS_FRAME_PHYS, SYS_CAP_DERIVE, SYS_CAP_DELETE, SYS_FRAME_FREE in sequence, printing results via SYS_WRITE. Verify QEMU output.

**Acceptance criteria:**
- All 5 syscalls work from EL0 assembly program
- Frame alloc/free round-trips correctly
- Cap derive rejects escalation (returns E_BADCAP)
- Cap delete invalidates the capability
- No kernel panics on invalid arguments

---

### M2.3: User-Space LibOS Library + First Zig User Program

**Goal:** Create a user-space library (`libos/`) that wraps syscalls, provides a bump allocator over allocated frames, and offers formatted I/O. Replace the hand-coded ASM user program with a Zig program that imports this library.

**LibOS library structure:**
```
libos/
├── syscall.zig      # Raw syscall wrappers (inline asm SVC)
├── alloc.zig        # Bump allocator over SYS_FRAME_ALLOC'd frames
├── io.zig           # print(), println(), putDec(), putHex() over SYS_WRITE
└── start.zig        # _start entry point → calls user's main(), then SYS_EXIT
```

**syscall.zig** — inline assembly wrappers:
```zig
pub fn write(cap_idx: u32, buf: [*]const u8, len: usize) i64;
pub fn exit() noreturn;
pub fn yield() void;
pub fn capRead(cap_idx: u32) i64;
pub fn frameAlloc() i64;       // returns cap_idx or negative error
pub fn frameFree(cap_idx: u32) i64;
pub fn capDerive(src: u32, rights: u8) i64;
pub fn capDelete(cap_idx: u32) i64;
pub fn framePhys(cap_idx: u32) i64;
```

Each wrapper uses inline asm:
```zig
pub fn write(cap_idx: u32, buf: [*]const u8, len: usize) i64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> i64),
        : [x0] "{x0}" (cap_idx),
          [x1] "{x1}" (buf),
          [x2] "{x2}" (len),
          [x8] "{x8}" (@as(u64, 0)),  // SYS_WRITE
        : "memory"
    );
}
```

**alloc.zig** — bump allocator:
```zig
pub const BumpAllocator = struct {
    frames: [MAX_FRAMES]u32,  // cap indices of allocated frames
    frame_count: u32,
    current_frame_phys: u64,  // phys addr of current frame
    offset: u32,              // offset within current frame

    pub fn init() BumpAllocator;
    pub fn alloc(self: *BumpAllocator, size: u32, alignment: u32) ?[*]u8;
};
```

The bump allocator calls `SYS_FRAME_ALLOC` to get new 4KB frames as needed. Since Phase 2 uses the identity map (phys == virt), the physical address from `SYS_FRAME_PHYS` is directly usable as a pointer.

**io.zig** — formatted output:
```zig
pub fn print(uart_cap: u32, str: []const u8) void;
pub fn println(uart_cap: u32, str: []const u8) void;
pub fn putDec(uart_cap: u32, val: u64) void;
pub fn putHex(uart_cap: u32, val: u64) void;
```

**start.zig** — entry point:
```zig
extern fn main() void;  // user provides this

export fn _start() callconv(.naked) noreturn {
    asm volatile ("bl main");
    // SYS_EXIT
    asm volatile (
        \\mov x8, #1
        \\svc #0
    );
    unreachable;
}
```

**First Zig user program:**
```
user/
└── init/
    └── main.zig     # Imports libos, prints hello, allocates frame, prints addr
```

**build.zig changes:**
- Create `libos` module (target: aarch64-freestanding-none, no OS imports)
- Create user program executable: root = `user/init/main.zig`, imports `libos`
- User program gets its own linker script (`user/linker.ld`) placing `.text` at 0x200000
- Output user program as raw binary, embed or copy into kernel image
- Alternative: keep the memcpy approach — user binary is a separate `addObjCopy` output, kernel copies it at boot

**Key decision — user program loading:**
Keep the Phase 1 approach: user program is compiled separately, its raw binary is embedded in the kernel image via `.incbin` or Zig `@embedFile`, and `kernel_main()` copies it to 0x200000. This avoids linker script complexity.

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `libos/syscall.zig` | **Create** | Raw syscall wrappers |
| `libos/alloc.zig` | **Create** | Bump allocator over frames |
| `libos/io.zig` | **Create** | Formatted I/O |
| `libos/start.zig` | **Create** | EL0 entry point (_start → main → exit) |
| `user/init/main.zig` | **Create** | First Zig user program |
| `user/linker.ld` | **Create** | User-space linker script (base 0x200000) |
| `build.zig` | **Modify** | Add libos module + user program build + embed |
| `kernel/src/main.zig` | **Modify** | Load embedded user binary instead of ASM program |

**Tests (host):** ~4 tests (bump allocator)
1. `alloc returns aligned pointer` — mock syscall, verify alignment
2. `alloc spans multiple frames` — allocations beyond 4KB trigger new frame alloc
3. `alloc returns null when frames exhausted` — graceful failure
4. `zero-size alloc` — returns valid pointer (or null, document behavior)

**Tests (QEMU integration):** 1 test
1. Boot QEMU, verify user program prints expected output (hello + frame address)

**Acceptance criteria:**
- Zig user program boots, prints "Hello from GaoOS user space!", allocates a frame, prints its physical address
- Bump allocator correctly spans multiple frames
- `_start` calls `main()` then `SYS_EXIT` — clean shutdown
- `zig build` produces both kernel8.img and user program binary
- No literal pools in user code (verify with objdump or by successful execution at 0x200000)

---

### M2.4: IPC Syscalls

**Goal:** Expose IPC send/receive to user space so threads can exchange messages.

**New syscalls:**

**SYS_IPC_SEND (9):** `ipc_send(ep_cap_idx, msg_ptr, msg_len) → 0`
- Validates `ep_cap_idx` is an `ipc_endpoint` cap with `write` right
- Copies `msg_len` bytes (max 256) from user `msg_ptr` into a Message
- Tag defaults to 0; use SYS_IPC_SEND_WITH_TAG for tagged messages
- Calls `endpoint.send(msg, null, null)` (no cap transfer in this syscall)
- Returns 0, `E_BADCAP`, `E_BADARG`, `E_FULL`, or `E_CLOSED`

**SYS_IPC_RECV (10):** `ipc_recv(ep_cap_idx, buf_ptr, tag_filter) → msg_len`
- Validates `ep_cap_idx` is an `ipc_endpoint` cap with `read` right
- Calls `endpoint.recv(tag_filter)`
- If no message: returns `E_AGAIN` (non-blocking)
- Copies payload to user `buf_ptr`, returns payload length
- Tag is returned in `x1` (frame[32])

**SYS_EP_CREATE (11):** `ep_create() → ep_cap_idx`
- Creates a new IPC endpoint (uses thread's own endpoint slot, or allocates from global pool)
- Creates an `ipc_endpoint` capability with `READ_WRITE` rights
- Returns cap index, or `E_FULL`

**SYS_IPC_SEND_WITH_TAG (14):** `ipc_send_tag(ep_cap_idx, msg_ptr, msg_len, tag) → 0`
- Same as SYS_IPC_SEND but sets `msg.tag = tag` (arg in x3, frame[1])

**SYS_EP_GRANT (15):** `ep_grant(ep_cap_idx, thread_cap_idx) → new_ep_cap_idx`
- Derives a read-only endpoint cap and places it in the target thread's cap table
- Requires `grant` right on the endpoint cap and valid thread cap
- Returns the new cap index (in target's table), or `E_BADCAP`

**Implementation notes:**
- Endpoint resolution: `ep_cap.object` stores the endpoint index (0..63). Use `sched.getEndpoint(idx)` to get the endpoint.
- For M2.4, endpoints are the per-thread endpoints already allocated in `sched.zig` (`endpoints[64]`). SYS_EP_CREATE returns a cap pointing to the calling thread's own endpoint.
- SYS_EP_GRANT enables one thread to give another thread access to its endpoint (for message passing).

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `kernel/src/syscall.zig` | **Modify** | Add 5 IPC syscall handlers |
| `libos/syscall.zig` | **Modify** | Add IPC syscall wrappers |
| `libos/ipc.zig` | **Create** | High-level IPC helpers (send_string, recv_string, etc.) |

**Tests (QEMU integration):** 1 test
1. Two-thread test: thread A creates endpoint, grants to thread B, sends message, thread B receives and prints it.

**Acceptance criteria:**
- Send/recv round-trip works between two threads
- Tag-filtered receive correctly skips non-matching messages
- Non-blocking recv returns E_AGAIN when empty
- Endpoint grant works across thread boundaries

---

### M2.5: Thread Creation

**Goal:** Allow user-space programs to create new threads via syscall.

**New syscalls:**

**SYS_THREAD_CREATE (12):** `thread_create(entry_pc, stack_ptr) → thread_cap_idx`
- Calls `sched.global.spawn()` to allocate a thread slot
- Sets up the new thread's context: ELR_EL1 = `entry_pc`, SP_EL0 = `stack_ptr`, SPSR = 0 (EL0)
- Creates a `thread` capability with `ALL` rights in the caller's cap table
- The new thread starts in `ready` state and will be scheduled on next timer tick
- Returns cap index, or `E_FULL`

**SYS_THREAD_GRANT (13):** `thread_grant(thread_cap_idx, cap_idx) → 0`
- Copies a capability from the caller's table to the target thread's table
- Requires `grant` right on the thread capability
- The source cap must have `grant` right
- Returns 0, or `E_BADCAP`

**Implementation notes:**
- The new thread needs its own kernel stack. Use a dedicated frame from the frame allocator or a static array (`kernel_stacks[64][4096]`). Phase 1 already has kernel stack space — check if threads share stacks or have individual ones.
- EL0 entry: the new thread's context must be set up so that when the scheduler switches to it and does `eret`, it enters EL0 at `entry_pc` with `SP_EL0 = stack_ptr`.
- The caller must allocate user-space stack memory (via SYS_FRAME_ALLOC) and pass the stack top pointer.

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `kernel/src/syscall.zig` | **Modify** | Add SYS_THREAD_CREATE and SYS_THREAD_GRANT |
| `kernel/src/sched.zig` | **Modify** | Add `spawnAt(entry, sp)` variant that sets up EL0 context |
| `libos/syscall.zig` | **Modify** | Add thread syscall wrappers |

**Tests (QEMU integration):** 1 test
1. Init thread creates a child thread, grants it UART cap, child prints "Hello from child!", parent waits and prints "Child done."

**Acceptance criteria:**
- Child thread executes at specified entry point in EL0
- Child thread has its own stack and cap table
- SYS_THREAD_GRANT transfers capabilities correctly
- Timer preemption works with multiple user threads
- Parent and child can communicate via IPC (if M2.4 is also done)

---

### M2.6: SPI Platform Driver + E-Ink User-Space Driver

**Goal:** Demonstrate the exokernel driver model: kernel provides SPI MMIO access via device capabilities, user-space driver handles the Waveshare e-ink protocol.

**SPI Platform Module:**
```
platform/raspi/spi.zig    # BCM2837 SPI0 register definitions + init
```

BCM2837 SPI0 is at MMIO base + 0x204000. The platform module provides:
- `init()` — configure SPI0 GPIO pins (CE0=GPIO8, MISO=GPIO9, MOSI=GPIO10, SCLK=GPIO11), set clock divider
- `transfer(tx: []const u8, rx: []u8)` — blocking SPI transfer
- Register constants (CS, FIFO, CLK, DLEN, etc.)

**QEMU note:** QEMU raspi3b does NOT emulate SPI. For testing, the e-ink driver uses a mock SPI that sends SPI commands over UART (human-readable debug output). The mock is selected at compile time or runtime based on a capability type.

**User-space e-ink driver:**
```
user/eink/
├── main.zig          # Driver entry: init display, draw pattern, sleep
├── spi.zig           # SPI via MMIO cap (or mock via UART cap)
└── waveshare.zig     # Waveshare e-ink command protocol
```

The driver receives:
- A `device` capability for the SPI MMIO region (or UART cap for mock)
- Frame capabilities for display buffer memory

**Waveshare protocol (simplified for Phase 2):**
- Init sequence: hardware reset, SW reset (0x12), wait busy, configure (LUT, gate, source)
- Display update: write RAM (0x24), then trigger refresh (0x20)
- Sleep: deep sleep mode (0x10, 0x01)

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `platform/raspi/spi.zig` | **Create** | SPI0 register definitions and init |
| `user/eink/main.zig` | **Create** | E-ink driver entry point |
| `user/eink/spi.zig` | **Create** | SPI abstraction (real + UART mock) |
| `user/eink/waveshare.zig` | **Create** | Waveshare e-ink command protocol |
| `build.zig` | **Modify** | Add SPI module, e-ink driver build |
| `kernel/src/main.zig` | **Modify** | Spawn e-ink driver thread, grant SPI/UART caps |

**Tests (QEMU integration):** 1 test
1. Boot with e-ink driver, verify UART mock output shows correct SPI command sequence (init, write RAM, refresh, sleep).

**Acceptance criteria:**
- E-ink driver runs as isolated EL0 process
- Driver accesses hardware only through capabilities (no hardcoded MMIO addresses)
- Mock SPI over UART produces recognizable command trace in QEMU
- Driver does not crash the kernel on invalid SPI operations

---

### M2.7: Per-Process Address Spaces (Stretch Goal)

**Goal:** Each user thread gets its own virtual address space via TTBR0/TTBR1 split.

**Design:**
- Kernel mapped in upper half via TTBR1_EL1 (shared across all address spaces)
- Each thread has its own L0 page table for TTBR0_EL1 (lower half)
- On context switch, scheduler updates TTBR0_EL1 to the new thread's page table base
- Frame capabilities gate all page table mappings: to map a page at VA X, the thread must hold a frame cap for the underlying physical frame

**Data structures:**
```zig
// kernel/src/aspace.zig
pub const AddressSpace = struct {
    l0_table_phys: u64,    // Physical address of L0 page table
    frame_caps: [256]u32,  // Cap indices of frames mapped in this aspace
    frame_count: u32,
};
```

**New behavior:**
- `SYS_THREAD_CREATE` allocates an L0 page table frame, creates an AddressSpace
- `SYS_FRAME_ALLOC` + new `SYS_MAP_PAGE(19)` maps frames into the thread's address space
- Context switch in `sched.schedule()` writes TTBR0_EL1 and issues TLBI

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `kernel/src/aspace.zig` | **Create** | Address space management |
| `kernel/arch/aarch64/mmu.zig` | **Modify** | TTBR0 switching on context switch |
| `kernel/src/sched.zig` | **Modify** | Per-thread address space pointer |
| `kernel/src/syscall.zig` | **Modify** | Add SYS_MAP_PAGE |

**Tests (QEMU integration):** 1 test
1. Two threads with separate address spaces, each mapping different frames at the same VA. Verify isolation (thread A's write doesn't appear in thread B's read).

**Acceptance criteria:**
- Context switch correctly switches TTBR0
- Threads have isolated address spaces
- Mapping requires frame capability (no mapping without cap)
- TLB is properly invalidated on switch

---

### M3.1: Fault Notification Protocol

**Goal:** When a thread dies, the kernel sends a structured fault message to its supervisor's IPC endpoint. This is the foundation for BEAM-style supervision trees.

**Fault notification payload:**
```zig
// kernel/src/fault.zig
pub const FaultTag: u64 = 0xDEAD_DEAD_DEAD_DEAD;  // Distinguished tag for fault messages

pub const FaultReason = enum(u8) {
    exit,           // Thread called SYS_EXIT
    killed,         // Supervisor killed the thread
    exception,      // Unhandled exception (data abort, etc.)
    cap_violation,  // Capability violation
};

pub const FaultMessage = struct {
    reason: FaultReason,
    thread_id: u32,
    fault_addr: u64,   // For exceptions: the faulting address
    esr: u64,          // For exceptions: ESR_EL1 value
};
```

The fault message is sent as an IPC message with `tag = FaultTag` and the FaultMessage serialized in the payload. The supervisor can use selective receive with `FaultTag` to separate fault notifications from regular messages.

**New syscall:**

**SYS_SUPERVISOR_SET (16):** `supervisor_set(thread_cap_idx, ep_cap_idx) → 0`
- Sets the target thread's supervisor endpoint
- When the thread dies, the kernel sends a FaultMessage to this endpoint
- Requires `write` right on the thread cap and `write` right on the endpoint cap
- Returns 0, or `E_BADCAP`

**Integration with `sched.kill()`:**
- Before marking the thread as dead, check if it has a supervisor endpoint
- If so, construct a FaultMessage and send it to the supervisor endpoint
- The supervisor endpoint cap is stored in the thread's control block

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `kernel/src/fault.zig` | **Create** | Fault types, message construction, notification delivery |
| `kernel/src/sched.zig` | **Modify** | Add supervisor_ep field to Thread, call fault notify on kill |
| `kernel/src/syscall.zig` | **Modify** | Add SYS_SUPERVISOR_SET handler |
| `libos/syscall.zig` | **Modify** | Add supervisor_set wrapper |
| `libos/fault.zig` | **Create** | User-space fault message parsing |

**Tests (host):** ~4 tests
1. `fault message serialization` — FaultMessage round-trips through IPC payload
2. `kill sends fault to supervisor` — supervisor endpoint receives FaultMessage
3. `no supervisor = no fault message` — killing thread without supervisor is silent
4. `supervisor set requires caps` — rejects invalid caps

**Tests (QEMU integration):** 1 test
1. Supervisor thread creates child, sets itself as supervisor, child exits. Supervisor receives and prints the fault notification.

**Acceptance criteria:**
- Thread death produces a fault message on the supervisor endpoint
- FaultTag is distinguishable from normal messages via selective receive
- Fault reason correctly distinguishes exit vs. kill vs. exception
- Supervisor can receive fault notifications and print them

---

### M3.2: Capability Delegation via IPC

**Goal:** Allow threads to transfer capabilities through IPC messages. This enables the delegation patterns needed for BEAM's process linking and monitoring.

**New syscalls:**

**SYS_IPC_SEND_CAP (17):** `ipc_send_cap(ep_cap_idx, msg_ptr, msg_len, cap_to_send) → 0`
- Like SYS_IPC_SEND but also transfers `cap_to_send` from sender to receiver
- The cap is removed from the sender's table and added to the receiver's table
- Uses the existing `endpoint.send()` with cap transfer logic (already implemented in ipc.zig)
- The transferred cap index (in receiver's table) is stored in the message's `caps[0]`
- Returns 0, or `E_BADCAP`, `E_FULL`

**SYS_IPC_RECV_CAP (18):** `ipc_recv_cap(ep_cap_idx, buf_ptr, tag_filter) → msg_len`
- Like SYS_IPC_RECV but also retrieves transferred capability
- If the received message has a cap attached, its index (in receiver's table) is returned in x1
- If no cap attached, x1 = CAP_NULL (0xFFFFFFFF)
- Returns msg_len in x0, cap_idx in x1 (frame[32])

**Implementation notes:**
- The IPC layer (`ipc.zig`) already supports cap transfer in `Endpoint.send()`. The syscall layer needs to resolve the endpoint cap → endpoint, look up sender/receiver cap tables, and call `send()` with both tables.
- The receiver's thread ID must be determinable from the endpoint. Add an `owner: ThreadId` field to `Endpoint` (or derive from the endpoint index, since endpoints[i] belongs to thread i).

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `kernel/src/syscall.zig` | **Modify** | Add SYS_IPC_SEND_CAP and SYS_IPC_RECV_CAP |
| `kernel/src/ipc.zig` | **Modify** | Add `owner` field to Endpoint (if needed) |
| `libos/syscall.zig` | **Modify** | Add cap transfer wrappers |
| `libos/ipc.zig` | **Modify** | High-level send_with_cap / recv_with_cap |

**Tests (host):** ~3 tests
1. `send_cap transfers ownership` — cap removed from sender, added to receiver
2. `send_cap with invalid cap` — returns E_BADCAP
3. `recv_cap returns CAP_NULL when no cap` — graceful handling

**Tests (QEMU integration):** 1 test
1. Thread A sends a frame cap to thread B via IPC. Thread B reads the cap type and physical address. Verify B received a valid frame cap.

**Acceptance criteria:**
- Capability is atomically moved from sender to receiver
- Sender no longer holds the transferred capability
- Receiver can use the transferred capability
- Transfer failures don't leak capabilities

---

### M3.3: Multi-Runtime Demo

**Goal:** Demonstrate two independent LibOS instances running concurrently, sharing capabilities through a supervisor/orchestrator, with fault notification.

**Demo scenario:**
1. **Orchestrator** (thread 0): creates two worker threads, grants each a UART cap, sets itself as supervisor for both
2. **Worker A**: prints "Worker A: hello", creates a frame, sends it to Worker B via IPC cap transfer, then exits
3. **Worker B**: receives the frame cap from Worker A, prints its physical address, then exits
4. **Orchestrator**: receives two fault notifications (Worker A exit, Worker B exit), prints "All workers done. System shutting down."

This demonstrates:
- Multiple independent user-space programs
- Capability delegation (frame transfer from A to B)
- Fault supervision (orchestrator receives death notifications)
- Clean shutdown

**Files:**
| File | Action | Description |
|------|--------|-------------|
| `user/orchestrator/main.zig` | **Create** | Supervisor/orchestrator program |
| `user/worker_a/main.zig` | **Create** | Worker A program |
| `user/worker_b/main.zig` | **Create** | Worker B program |
| `build.zig` | **Modify** | Build all user programs, embed in kernel |
| `kernel/src/main.zig` | **Modify** | Load orchestrator as init program |

**Alternative simpler approach:** Single user binary that uses SYS_THREAD_CREATE to spawn children with different entry points (function pointers within the same binary). This avoids multi-binary linking complexity.

**Tests (QEMU integration):** 1 test
1. Full demo: boot → orchestrator → workers → cap transfer → fault notifications → shutdown. Verify complete UART output sequence.

**Acceptance criteria:**
- Two worker threads run concurrently and communicate via IPC
- Capability delegation works across thread boundaries
- Supervisor receives fault notifications for both workers
- System shuts down cleanly
- No kernel panics or resource leaks

---

## File Manifest

### New Files (20)

| File | Milestone | Description |
|------|-----------|-------------|
| `kernel/src/frame.zig` | M2.1 | Bitmap frame allocator |
| `libos/syscall.zig` | M2.3 | Raw syscall wrappers |
| `libos/alloc.zig` | M2.3 | Bump allocator |
| `libos/io.zig` | M2.3 | Formatted I/O |
| `libos/start.zig` | M2.3 | EL0 entry point |
| `user/init/main.zig` | M2.3 | First Zig user program |
| `user/linker.ld` | M2.3 | User-space linker script |
| `libos/ipc.zig` | M2.4 | High-level IPC helpers |
| `platform/raspi/spi.zig` | M2.6 | SPI0 platform driver |
| `user/eink/main.zig` | M2.6 | E-ink driver entry |
| `user/eink/spi.zig` | M2.6 | SPI abstraction |
| `user/eink/waveshare.zig` | M2.6 | Waveshare protocol |
| `kernel/src/aspace.zig` | M2.7 | Address space management |
| `kernel/src/fault.zig` | M3.1 | Fault notification |
| `libos/fault.zig` | M3.1 | User-space fault parsing |
| `user/orchestrator/main.zig` | M3.3 | Orchestrator program |
| `user/worker_a/main.zig` | M3.3 | Worker A program |
| `user/worker_b/main.zig` | M3.3 | Worker B program |
| `tests/qemu/run_test.sh` | M2.2+ | QEMU integration test runner |
| `tests/qemu/expected/` | M2.2+ | Expected QEMU output files |

### Modified Files (10)

| File | Milestones | Changes |
|------|------------|---------|
| `README.md` | M2.0 | Mark Phase 1 complete |
| `build.zig` | M2.1, M2.3, M2.4, M2.6, M3.3 | Add modules, user program builds |
| `kernel/src/syscall.zig` | M2.2, M2.4, M2.5, M3.1, M3.2 | Add 15 new syscall handlers |
| `kernel/src/sched.zig` | M2.5, M2.7, M3.1 | spawnAt(), supervisor_ep field |
| `kernel/src/main.zig` | M2.3, M2.6, M3.3 | User program loading, thread spawning |
| `kernel/src/ipc.zig` | M3.2 | owner field on Endpoint |
| `kernel/arch/aarch64/mmu.zig` | M2.7 | TTBR0 switching |
| `libos/syscall.zig` | M2.4, M2.5, M3.1, M3.2 | IPC + thread + fault wrappers |
| `libos/ipc.zig` | M3.2 | Cap transfer helpers |
| `CLAUDE.md` | M2.2+ | Update syscall list, add libos section |

---

## Test Summary

### Host Unit Tests (~43 new)

| Module | Count | Milestone |
|--------|-------|-----------|
| `kernel/src/frame.zig` | 6 | M2.1 |
| `libos/alloc.zig` | 4 | M2.3 |
| `kernel/src/fault.zig` | 4 | M3.1 |
| `kernel/src/ipc.zig` (additions) | 3 | M3.2 |
| Existing tests (24) must still pass | — | All |

Total host tests after Phase 3: ~67 (24 existing + 43 new).

### QEMU Integration Tests (~8)

| Test | Milestone | Verifies |
|------|-----------|----------|
| Memory syscalls round-trip | M2.2 | FRAME_ALLOC, FRAME_FREE, FRAME_PHYS, CAP_DERIVE, CAP_DELETE |
| Zig user program boots | M2.3 | LibOS library, bump allocator, formatted I/O |
| IPC send/recv between threads | M2.4 | SYS_IPC_SEND, SYS_IPC_RECV, SYS_EP_CREATE |
| Thread creation from user space | M2.5 | SYS_THREAD_CREATE, SYS_THREAD_GRANT |
| E-ink mock SPI output | M2.6 | SPI commands over UART |
| Address space isolation | M2.7 | TTBR0 switching, page mapping |
| Fault notification delivery | M3.1 | Supervisor receives death notification |
| Multi-runtime demo | M3.3 | Full end-to-end: cap delegation, IPC, faults |

---

## Implementation Notes for Loki-Mode

### build.zig Patterns

When adding a new kernel module (`frame`, `fault`, `aspace`):
1. Create the module with `b.createModule(...)` specifying target + optimize
2. Add it to the kernel executable's imports
3. Add it to any syscall/sched modules that need it
4. Create a host-target variant for tests: `b.createModule(.{ .root_source_file = ..., .target = b.graph.host })`
5. Add test step: `b.addTest(.{ .root_module = ... })` → `test_step.dependOn(...)`

When adding a user-space program:
1. Create the `libos` module (aarch64-freestanding-none, no host)
2. Create the user executable with `b.addExecutable(...)` importing `libos`
3. Set user linker script
4. Add `addObjCopy(.{ .format = .bin })` to get raw binary
5. Embed in kernel via `@embedFile` or linker `.incbin`

### Critical Gotchas (from CLAUDE.md)

1. **NEON/FP disabled**: target has `.cpu_features_sub = .{ .neon, .fp_armv8 }`. Never use `@memset` on Context structs — use field-by-field zeroing (`zeroContext()`).

2. **Exception frame layout**: `frame[31]` = x0, `frame[32]` = x1, `frame[0]` = x2, `frame[1]` = x3, `frame[2]` = x4, `frame[3]` = x5, `frame[6]` = x8. New syscalls using x3 read from `frame[1]`.

3. **User programs must be position-independent**: no literal pools. For Zig user programs, the linker script + freestanding target should handle this, but verify with objdump.

4. **Two mmu.zig files**: `kernel/src/mmu.zig` (portable, host-testable) and `kernel/arch/aarch64/mmu.zig` (register-level). M2.7 modifies the arch one.

5. **Identity map in Phase 2**: until M2.7, phys == virt. User-space pointers from SYS_FRAME_PHYS are directly dereferenceable.

6. **MMIO access pattern**: always `@as(*volatile u32, @ptrFromInt(addr))` for hardware registers.

7. **Static allocation only in kernel**: no heap, no hidden allocations. Frame allocator bitmap is a static array. Capability tables and endpoints are static arrays in `sched.zig`.

8. **Module dependency chain matters**: syscall depends on cap, sched, uart, and (new) frame. Adding new imports to syscall requires updating build.zig.

### Error Handling

- Kernel functions return Zig error unions, never panic (except truly unrecoverable boot failures)
- Syscalls translate Zig errors to negative integer error codes returned in x0
- User-space LibOS wrappers return i64 and let the caller check for negative values

### Testing Strategy

- Host tests: pure logic, no hardware dependencies. Mock MMIO where needed.
- QEMU tests: boot the kernel, run for N seconds, capture UART output, diff against expected.
- QEMU test runner (`tests/qemu/run_test.sh`): `timeout 10 qemu-system-aarch64 -M raspi3b -kernel $IMG -serial stdio -display none -no-reboot 2>/dev/null | diff - expected/$TEST.txt`
