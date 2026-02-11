## ADR-004: Capability Revocation Strategy

**Status**: Proposed (open question for Phase 3+)

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

### Consequences

By deferring, Phase 1-2 development proceeds without the complexity of
cross-table revocation. The generation counter within a single table is
sufficient for the single-runtime Phase 1 scenario.

The risk is that the chosen revocation strategy may require restructuring
the capability table. The current interface (create/lookup/delete/derive)
is designed to be stable regardless of the backing implementation.

### Alternatives Considered

**Implement full revocation now**: premature — we don't yet know the
performance characteristics of the BEAM integration, which should drive
the choice.

**No revocation**: unacceptable — BEAM supervision requires the ability
to invalidate a crashed process's delegated capabilities.
