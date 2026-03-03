## ADR-004: Capability Revocation Strategy

**Status**: Partially implemented (Phase 3.2)

### Context

When a capability is delegated (e.g., Process A grants a read-only frame cap
to Process B via IPC), the delegator may later need to revoke access. This is
critical for BEAM supervision: when a supervised process is restarted, the old
process's capabilities must be invalidated even if they were delegated further.

Phase 1 uses immediate invalidation on delete (the slot is cleared and the
generation counter prevents stale lookups). This works within a single
capability table but does not handle cross-table delegation chains.

### Decision

Defer the full revocation mechanism to Phase 3. Phase 1 uses generation-based
slot invalidation within a single table. Phase 3 will implement one of the
options below based on empirical data from BEAM integration.

### Options Under Consideration

**Option A: Epoch-based revocation**
- Each capability carries an epoch number
- Revoker bumps the epoch; all capabilities from prior epochs become invalid
- Pro: O(1) revocation for the delegator
- Con: Revokes *all* capabilities from that epoch, not just specific ones
- Fits BEAM: process restart invalidates all caps from the old process

**Option B: Indirection table (cnode)**
- Capabilities point to an indirection slot, not directly to the object
- Revoking = clearing the indirection slot
- Pro: Fine-grained, immediate, and the standard seL4 approach
- Con: Extra indirection on every capability lookup (performance cost)
- Fits BEAM: fine-grained but adds latency to the IPC hot path

**Option C: Proxy objects**
- Delegated capabilities reference a proxy object
- Revoking = destroying the proxy
- Pro: Fine-grained, can be hierarchical (proxy chains)
- Con: Memory overhead per delegation, complex lifecycle
- Fits BEAM: natural hierarchy maps to supervision trees

### Current Implementation (Phase 3.2)

Phase 3.2 implemented capability delegation via IPC (SYS_IPC_SEND_CAP /
SYS_IPC_RECV_CAP). The chosen revocation mechanism is **generation-based
slot invalidation** (closest to Option A characteristics):

- Each capability slot carries a generation counter (u32, wrapping)
- On `delete()`, the slot is marked invalid and the generation increments
- Stale handles (cached indices) fail lookup because generation mismatches
- Capability transfer via IPC is a **move** (not copy): the source slot is
  deleted after send, preventing aliasing across tables
- Thread death closes endpoints and triggers fault notification to supervisors
- Supervisors reap dead threads via SYS_THREAD_REAP, which resets the
  thread's capability table

This approach is sufficient for the multi-runtime demo (M3.3) and avoids
the complexity of cross-table revocation chains. Full hierarchical
revocation (Option B or C) is deferred to Phase 4 (BEAM integration)
where empirical data will guide the choice.

### Consequences

The generation-based approach has proven sufficient for Phases 1-3:
- Within-table revocation is O(1) and zero-allocation
- Move semantics on IPC transfer prevent capability aliasing
- Supervisor-based reaping provides cleanup for crashed runtimes
- The capability table interface (create/lookup/delete/derive) remains
  stable and can accommodate future revocation strategies

The remaining gap is **hierarchical revocation**: if Process A delegates
a cap to Process B, and B delegates to C, revoking A's cap does not
automatically invalidate B's or C's derived copies. This requires
cross-table tracking (Options B or C) and is deferred to BEAM integration.

### Alternatives Considered

**Implement full cross-table revocation now**: premature — move semantics
eliminate most aliasing scenarios, and the BEAM integration will reveal
which patterns actually need hierarchical revocation.

**No revocation**: unacceptable — BEAM supervision requires the ability
to invalidate a crashed process's delegated capabilities.
