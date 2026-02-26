// Capability System
//
// Every kernel object is accessed exclusively through capabilities.
// No operation is permitted without presenting a valid capability index.
//
// BEAM design constraint: capability creation must be near-zero cost
// because BEAM spawns millions of lightweight processes, each needing
// its own capability table.
//
// Phase 1: fixed-size array (256 slots per table).
// Future: hash table → arena-based allocation for millions of entries.
// The interface is stable — only the backing store changes.

/// Maximum capabilities per table in Phase 1.
pub const MAX_CAPS = 256;

/// Index into a capability table. Opaque handle given to user space.
pub const CapIndex = u32;

/// Sentinel value for "no capability".
pub const CAP_NULL: CapIndex = 0xFFFFFFFF;

/// Types of kernel objects that capabilities can reference.
pub const CapabilityType = enum(u8) {
    frame, // Physical memory frame
    aspace, // Address space (page table root)
    thread, // Schedulable thread
    ipc_endpoint, // IPC message queue
    irq, // Hardware interrupt
    device, // MMIO device region
};

/// Access rights bitmask. Derived capabilities can only reduce these.
pub const Rights = packed struct {
    read: bool = false,
    write: bool = false,
    grant: bool = false, // Can delegate (send via IPC)
    revoke: bool = false, // Can invalidate derived capabilities
    _padding: u4 = 0,

    pub const NONE = Rights{};
    pub const READ_ONLY = Rights{ .read = true };
    pub const READ_WRITE = Rights{ .read = true, .write = true };
    pub const ALL = Rights{ .read = true, .write = true, .grant = true, .revoke = true };

    /// True if `self` is a subset of `other` (every right in self is also in other).
    pub fn isSubsetOf(self: Rights, other: Rights) bool {
        if (self.read and !other.read) return false;
        if (self.write and !other.write) return false;
        if (self.grant and !other.grant) return false;
        if (self.revoke and !other.revoke) return false;
        return true;
    }

    /// Bitwise AND: intersection of two rights sets.
    pub fn intersect(self: Rights, other: Rights) Rights {
        return .{
            .read = self.read and other.read,
            .write = self.write and other.write,
            .grant = self.grant and other.grant,
            .revoke = self.revoke and other.revoke,
        };
    }

    pub fn eql(self: Rights, other: Rights) bool {
        return self.read == other.read and
            self.write == other.write and
            self.grant == other.grant and
            self.revoke == other.revoke;
    }
};

/// A capability: unforgeable reference to a kernel object with rights.
pub const Capability = struct {
    cap_type: CapabilityType,
    object: usize, // Pointer-sized handle to the kernel object
    rights: Rights,
    generation: u32, // For revocation: matches table slot generation

    pub const INVALID = Capability{
        .cap_type = .frame,
        .object = 0,
        .rights = Rights.NONE,
        .generation = 0,
    };
};

/// Per-address-space capability storage.
/// Phase 1: fixed array. Interface designed for future scaling.
pub const CapabilityTable = struct {
    slots: [MAX_CAPS]Slot = [_]Slot{Slot{}} ** MAX_CAPS,
    count: u32 = 0,

    const Slot = struct {
        cap: Capability = Capability.INVALID,
        valid: bool = false,
        generation: u32 = 0, // Incremented on reuse (create) and delete; prevents stale handles
    };

    /// Create a new capability in the table.
    /// Returns the index, or error if table is full.
    pub fn create(
        self: *CapabilityTable,
        cap_type: CapabilityType,
        object: usize,
        rights: Rights,
    ) error{TableFull}!CapIndex {
        // Find first empty slot
        for (&self.slots, 0..) |*slot, i| {
            if (!slot.valid) {
                slot.generation +%= 1;
                slot.cap = .{
                    .cap_type = cap_type,
                    .object = object,
                    .rights = rights,
                    .generation = slot.generation,
                };
                slot.valid = true;
                self.count += 1;
                return @intCast(i);
            }
        }
        return error.TableFull;
    }

    /// Look up a capability by index.
    /// Returns null if index is invalid, slot is empty, or generation
    /// is inconsistent (kernel memory corruption guard).
    pub fn lookup(self: *const CapabilityTable, index: CapIndex) ?Capability {
        if (index >= MAX_CAPS) return null;
        const slot = &self.slots[index];
        if (!slot.valid) return null;
        if (slot.cap.generation != slot.generation) return null;
        return slot.cap;
    }

    /// Delete a capability, immediately invalidating it.
    /// Bumps the generation counter so that any future reuse of this slot
    /// produces a distinct generation value.
    pub fn delete(self: *CapabilityTable, index: CapIndex) void {
        if (index >= MAX_CAPS) return;
        const slot = &self.slots[index];
        if (!slot.valid) return;
        slot.generation +%= 1;
        slot.valid = false;
        slot.cap = Capability.INVALID;
        if (self.count > 0) self.count -= 1;
    }

    /// Derive a new capability from an existing one with reduced rights.
    /// The new rights must be a subset of the source rights (attenuation).
    /// Returns the new capability's index, or an error.
    pub fn derive(
        self: *CapabilityTable,
        src_index: CapIndex,
        new_rights: Rights,
    ) error{ InvalidCapability, RightsEscalation, TableFull }!CapIndex {
        // Look up source
        const src = self.lookup(src_index) orelse return error.InvalidCapability;

        // Attenuation check: new rights must be subset of source rights
        if (!new_rights.isSubsetOf(src.rights)) return error.RightsEscalation;

        // Create derived capability pointing to same object
        return self.create(src.cap_type, src.object, new_rights) catch |err| switch (err) {
            error.TableFull => error.TableFull,
        };
    }

    /// Check if a capability at the given index has the required rights.
    /// This is the fundamental access check — called on every kernel operation.
    pub fn check(self: *const CapabilityTable, index: CapIndex, required: Rights) bool {
        const cap = self.lookup(index) orelse return false;
        return required.isSubsetOf(cap.rights);
    }
};

// ─── Tests (run on host via `zig test`) ──────────────────────────────

const testing = @import("std").testing;

test "create and lookup capability" {
    var table = CapabilityTable{};

    const idx = try table.create(.frame, 0x1000, Rights.READ_WRITE);
    const cap = table.lookup(idx).?;

    try testing.expectEqual(CapabilityType.frame, cap.cap_type);
    try testing.expectEqual(@as(usize, 0x1000), cap.object);
    try testing.expect(cap.rights.read);
    try testing.expect(cap.rights.write);
    try testing.expect(!cap.rights.grant);
}

test "derive with reduced rights (attenuation)" {
    var table = CapabilityTable{};

    const parent = try table.create(.frame, 0x2000, Rights.ALL);
    const child = try table.derive(parent, Rights.READ_ONLY);

    const child_cap = table.lookup(child).?;
    try testing.expect(child_cap.rights.read);
    try testing.expect(!child_cap.rights.write);
    try testing.expect(!child_cap.rights.grant);
    try testing.expect(!child_cap.rights.revoke);

    // Same object
    try testing.expectEqual(@as(usize, 0x2000), child_cap.object);
}

test "derive rejects expanded rights" {
    var table = CapabilityTable{};

    const parent = try table.create(.frame, 0x3000, Rights.READ_ONLY);
    const result = table.derive(parent, Rights.READ_WRITE);

    try testing.expectError(error.RightsEscalation, result);
}

test "delete invalidates capability" {
    var table = CapabilityTable{};

    const idx = try table.create(.ipc_endpoint, 0x4000, Rights.ALL);
    try testing.expect(table.lookup(idx) != null);

    table.delete(idx);
    try testing.expect(table.lookup(idx) == null);
}

test "deleted slot can be reused" {
    var table = CapabilityTable{};

    const idx1 = try table.create(.frame, 0x5000, Rights.ALL);
    table.delete(idx1);

    const idx2 = try table.create(.thread, 0x6000, Rights.READ_ONLY);
    // Should reuse the same slot
    try testing.expectEqual(idx1, idx2);

    // But the capability is different
    const cap = table.lookup(idx2).?;
    try testing.expectEqual(CapabilityType.thread, cap.cap_type);
    try testing.expectEqual(@as(usize, 0x6000), cap.object);
}

test "check verifies required rights" {
    var table = CapabilityTable{};

    const idx = try table.create(.device, 0x7000, Rights.READ_ONLY);

    try testing.expect(table.check(idx, Rights.READ_ONLY));
    try testing.expect(!table.check(idx, Rights.READ_WRITE));
    try testing.expect(!table.check(idx, Rights.ALL));
}

test "lookup invalid index returns null" {
    var table = CapabilityTable{};

    try testing.expect(table.lookup(0) == null);
    try testing.expect(table.lookup(255) == null);
    try testing.expect(table.lookup(CAP_NULL) == null);
    // MAX_CAPS (256) is the first out-of-bounds index
    try testing.expect(table.lookup(MAX_CAPS) == null);
    try testing.expect(table.lookup(MAX_CAPS + 1) == null);
}

test "table full returns error" {
    var table = CapabilityTable{};

    // Fill all slots
    for (0..MAX_CAPS) |i| {
        _ = try table.create(.frame, i, Rights.ALL);
    }

    // Next create should fail
    const result = table.create(.frame, 0, Rights.ALL);
    try testing.expectError(error.TableFull, result);
}

test "rights intersection" {
    const rw = Rights.READ_WRITE;
    const ro = Rights.READ_ONLY;
    const result = rw.intersect(ro);
    try testing.expect(result.read);
    try testing.expect(!result.write);
}

test "generation prevents stale index reuse" {
    var table = CapabilityTable{};

    const idx = try table.create(.frame, 0xA000, Rights.ALL);
    const gen1 = table.lookup(idx).?.generation;

    table.delete(idx);

    // Re-create at same slot
    const idx2 = try table.create(.frame, 0xB000, Rights.READ_ONLY);
    try testing.expectEqual(idx, idx2);

    // Generation has incremented
    const gen2 = table.lookup(idx2).?.generation;
    try testing.expect(gen2 > gen1);
}

test "derive from deleted cap returns error" {
    var table = CapabilityTable{};

    const idx = try table.create(.frame, 0xC000, Rights.ALL);
    table.delete(idx);

    const result = table.derive(idx, Rights.READ_ONLY);
    try testing.expectError(error.InvalidCapability, result);
}

test "derive preserves cap type" {
    var table = CapabilityTable{};

    const idx = try table.create(.ipc_endpoint, 0xD000, Rights.ALL);
    const derived = try table.derive(idx, Rights.READ_WRITE);

    const d = table.lookup(derived).?;
    try testing.expectEqual(CapabilityType.ipc_endpoint, d.cap_type);
    try testing.expectEqual(@as(usize, 0xD000), d.object);
}

test "check on deleted cap returns false" {
    var table = CapabilityTable{};

    const idx = try table.create(.frame, 0xE000, Rights.ALL);
    try testing.expect(table.check(idx, Rights.READ_ONLY));

    table.delete(idx);
    try testing.expect(!table.check(idx, Rights.READ_ONLY));
}

test "count tracks creates and deletes" {
    var table = CapabilityTable{};
    try testing.expectEqual(@as(u32, 0), table.count);

    const a = try table.create(.frame, 0, Rights.ALL);
    const b = try table.create(.frame, 1, Rights.ALL);
    try testing.expectEqual(@as(u32, 2), table.count);

    table.delete(a);
    try testing.expectEqual(@as(u32, 1), table.count);

    table.delete(b);
    try testing.expectEqual(@as(u32, 0), table.count);
}

test "rights eql and isSubsetOf" {
    try testing.expect(Rights.NONE.isSubsetOf(Rights.ALL));
    try testing.expect(!Rights.ALL.isSubsetOf(Rights.NONE));
    try testing.expect(Rights.READ_ONLY.isSubsetOf(Rights.READ_WRITE));
    try testing.expect(!Rights.READ_WRITE.isSubsetOf(Rights.READ_ONLY));
    try testing.expect(Rights.ALL.eql(Rights.ALL));
    try testing.expect(!Rights.ALL.eql(Rights.READ_ONLY));
}

test "derive when table full returns TableFull" {
    var table = CapabilityTable{};
    // Fill all slots
    for (0..MAX_CAPS) |i| {
        _ = try table.create(.frame, i, Rights.ALL);
    }
    // derive should fail with TableFull, not InvalidCapability
    const result = table.derive(0, Rights.READ_ONLY);
    try testing.expectError(error.TableFull, result);
}

test "double delete is safe" {
    var table = CapabilityTable{};
    const idx = try table.create(.frame, 0xF000, Rights.ALL);
    try testing.expectEqual(@as(u32, 1), table.count);
    table.delete(idx);
    try testing.expectEqual(@as(u32, 0), table.count);
    // Second delete on same slot should be a no-op (slot already invalid)
    table.delete(idx);
    try testing.expectEqual(@as(u32, 0), table.count);
}

test "delete parent does not affect derived cap" {
    var table = CapabilityTable{};
    const parent = try table.create(.frame, 0x10000, Rights.ALL);
    const child = try table.derive(parent, Rights.READ_ONLY);
    // Delete parent
    table.delete(parent);
    try testing.expect(table.lookup(parent) == null);
    // Child is independent — still valid
    const c = table.lookup(child).?;
    try testing.expect(c.rights.read);
    try testing.expectEqual(@as(usize, 0x10000), c.object);
}

test "derive with NONE rights produces fully attenuated cap" {
    var table = CapabilityTable{};
    const parent = try table.create(.frame, 0x20000, Rights.ALL);
    const child = try table.derive(parent, Rights.NONE);
    const c = table.lookup(child).?;
    try testing.expect(!c.rights.read);
    try testing.expect(!c.rights.write);
    try testing.expect(!c.rights.grant);
    try testing.expect(!c.rights.revoke);
    try testing.expectEqual(@as(usize, 0x20000), c.object);
}

test "delete out-of-bounds index is silent" {
    var table = CapabilityTable{};
    const idx = try table.create(.frame, 0x1000, Rights.ALL);
    try testing.expectEqual(@as(u32, 1), table.count);

    // Delete at MAX_CAPS boundary — should be a no-op
    table.delete(MAX_CAPS);
    try testing.expectEqual(@as(u32, 1), table.count);

    // Delete at CAP_NULL (0xFFFFFFFF) — should be a no-op
    table.delete(CAP_NULL);
    try testing.expectEqual(@as(u32, 1), table.count);

    // Original cap still valid
    try testing.expect(table.lookup(idx) != null);
}

test "derive chain attenuation" {
    var table = CapabilityTable{};
    const root = try table.create(.ipc_endpoint, 0x30000, Rights.ALL);
    const mid = try table.derive(root, Rights.READ_WRITE);
    const leaf = try table.derive(mid, Rights.READ_ONLY);
    const c = table.lookup(leaf).?;
    try testing.expect(c.rights.read);
    try testing.expect(!c.rights.write);
    try testing.expectEqual(CapabilityType.ipc_endpoint, c.cap_type);
    // Cannot escalate back up
    try testing.expectError(error.RightsEscalation, table.derive(leaf, Rights.READ_WRITE));
}

test "derive from CAP_NULL returns InvalidCapability" {
    var table = CapabilityTable{};
    try testing.expectError(error.InvalidCapability, table.derive(CAP_NULL, Rights.READ_ONLY));
}

test "check on CAP_NULL returns false" {
    var table = CapabilityTable{};
    try testing.expect(!table.check(CAP_NULL, Rights.READ_ONLY));
    try testing.expect(!table.check(CAP_NULL, Rights.NONE));
}

test "generation counter increments on create and delete" {
    var table = CapabilityTable{};

    // Create at slot 0 — generation goes from 0 → 1
    const idx = try table.create(.frame, 0x1000, Rights.ALL);
    try testing.expectEqual(@as(u32, 0), idx);
    try testing.expectEqual(@as(u32, 1), table.slots[0].generation);

    // Delete — generation goes from 1 → 2
    table.delete(idx);
    try testing.expectEqual(@as(u32, 2), table.slots[0].generation);

    // Re-create at same slot — generation goes from 2 → 3
    const idx2 = try table.create(.frame, 0x2000, Rights.ALL);
    try testing.expectEqual(@as(u32, 0), idx2); // same slot
    try testing.expectEqual(@as(u32, 3), table.slots[0].generation);

    // Cap stored in lookup has matching generation
    const c = table.lookup(idx2).?;
    try testing.expectEqual(@as(u32, 3), c.generation);
}

test "derive with identical rights (no attenuation) succeeds" {
    var table = CapabilityTable{};
    const parent = try table.create(.frame, 0x5000, Rights.ALL);
    const child = try table.derive(parent, Rights.ALL);
    const c = table.lookup(child).?;
    try testing.expect(c.rights.read);
    try testing.expect(c.rights.write);
    try testing.expect(c.rights.grant);
    try testing.expect(c.rights.revoke);
    try testing.expectEqual(@as(usize, 0x5000), c.object);
}

test "check enforces grant and revoke rights individually" {
    var table = CapabilityTable{};
    // Grant-only cap
    const grant_cap = try table.create(.ipc_endpoint, 0, Rights{ .grant = true });
    try testing.expect(table.check(grant_cap, Rights{ .grant = true }));
    try testing.expect(!table.check(grant_cap, Rights{ .read = true }));
    try testing.expect(!table.check(grant_cap, Rights{ .revoke = true }));

    // Revoke-only cap
    const revoke_cap = try table.create(.ipc_endpoint, 0, Rights{ .revoke = true });
    try testing.expect(table.check(revoke_cap, Rights{ .revoke = true }));
    try testing.expect(!table.check(revoke_cap, Rights{ .grant = true }));
    try testing.expect(!table.check(revoke_cap, Rights.READ_WRITE));
}

test "Rights NONE is subset of itself" {
    try testing.expect(Rights.NONE.isSubsetOf(Rights.NONE));
    try testing.expect(Rights.ALL.isSubsetOf(Rights.ALL));
    try testing.expect(Rights.READ_ONLY.isSubsetOf(Rights.READ_ONLY));
}

test "siblings from same parent have independent rights" {
    var table = CapabilityTable{};
    const parent = try table.create(.frame, 0x1000, Rights.ALL);
    const ro = try table.derive(parent, Rights.READ_ONLY);
    const rw = try table.derive(parent, Rights.READ_WRITE);
    const ro_cap = table.lookup(ro).?;
    const rw_cap = table.lookup(rw).?;
    // Same underlying object
    try testing.expectEqual(ro_cap.object, rw_cap.object);
    // Different rights
    try testing.expect(ro_cap.rights.read and !ro_cap.rights.write);
    try testing.expect(rw_cap.rights.read and rw_cap.rights.write);
}

test "Rights.intersect with NONE yields NONE" {
    try testing.expect(Rights.NONE.intersect(Rights.ALL).eql(Rights.NONE));
    try testing.expect(Rights.ALL.intersect(Rights.NONE).eql(Rights.NONE));
    try testing.expect(Rights.READ_WRITE.intersect(Rights.NONE).eql(Rights.NONE));
    try testing.expect(Rights.NONE.intersect(Rights.NONE).eql(Rights.NONE));
}

test "check with NONE required rights always succeeds for any valid cap" {
    var table = CapabilityTable{};
    const idx = try table.create(.frame, 0x1000, Rights.READ_ONLY);
    // NONE is a subset of every rights set — check always passes for a valid cap
    try testing.expect(table.check(idx, Rights.NONE));
    // A cap derived with NONE rights also passes check for NONE required
    const none_cap = try table.derive(idx, Rights.NONE);
    try testing.expect(table.check(none_cap, Rights.NONE));
}

test "derive error precedence: RightsEscalation wins over TableFull" {
    var table = CapabilityTable{};
    // Create a READ_ONLY parent cap at slot 0, fill remaining slots
    const parent = try table.create(.frame, 0x1000, Rights.READ_ONLY);
    for (1..MAX_CAPS) |_| {
        _ = try table.create(.frame, 0, Rights.ALL);
    }
    // Table is full AND rights would escalate → RightsEscalation is checked first
    try testing.expectError(error.RightsEscalation, table.derive(parent, Rights.READ_WRITE));
}

test "create with object=0 is valid and distinct from INVALID" {
    var table = CapabilityTable{};
    // object=0 is a legitimate value — must not be confused with Capability.INVALID
    const idx = try table.create(.frame, 0, Rights.ALL);
    const c = table.lookup(idx).?;
    try testing.expectEqual(@as(usize, 0), c.object);
    try testing.expectEqual(CapabilityType.frame, c.cap_type);
    try testing.expect(c.rights.read);
    try testing.expectEqual(@as(u32, 1), table.count);
}

test "create and lookup with aspace and irq cap types" {
    var table = CapabilityTable{};
    const as_idx = try table.create(.aspace, 0x1000, Rights.READ_WRITE);
    const irq_idx = try table.create(.irq, 42, Rights.READ_ONLY);

    const as_cap = table.lookup(as_idx).?;
    try testing.expectEqual(CapabilityType.aspace, as_cap.cap_type);
    try testing.expectEqual(@as(usize, 0x1000), as_cap.object);

    const irq_cap = table.lookup(irq_idx).?;
    try testing.expectEqual(CapabilityType.irq, irq_cap.cap_type);
    try testing.expectEqual(@as(usize, 42), irq_cap.object);

    // Derive from aspace cap preserves type
    const derived = try table.derive(as_idx, Rights.READ_ONLY);
    const d = table.lookup(derived).?;
    try testing.expectEqual(CapabilityType.aspace, d.cap_type);
    try testing.expect(d.rights.read and !d.rights.write);
}

test "Rights.intersect comprehensive combinations" {
    // intersect(READ_WRITE, READ_ONLY) → READ_ONLY
    const rw_ro = Rights.READ_WRITE.intersect(Rights.READ_ONLY);
    try testing.expect(rw_ro.eql(Rights.READ_ONLY));

    // intersect(ALL, READ_WRITE) → READ_WRITE
    const all_rw = Rights.ALL.intersect(Rights.READ_WRITE);
    try testing.expect(all_rw.eql(Rights.READ_WRITE));

    // intersect(grant-only, revoke-only) → NONE
    const g = Rights{ .grant = true };
    const r = Rights{ .revoke = true };
    try testing.expect(g.intersect(r).eql(Rights.NONE));

    // intersect is commutative
    try testing.expect(Rights.READ_ONLY.intersect(Rights.ALL).eql(Rights.ALL.intersect(Rights.READ_ONLY)));

    // intersect with self is identity
    try testing.expect(Rights.ALL.intersect(Rights.ALL).eql(Rights.ALL));
    try testing.expect(Rights.READ_WRITE.intersect(Rights.READ_WRITE).eql(Rights.READ_WRITE));
}

test "fill all 256 slots and verify count matches linear scan" {
    var table = CapabilityTable{};
    for (0..MAX_CAPS) |i| {
        _ = try table.create(.frame, i, Rights.ALL);
    }
    try testing.expectEqual(@as(u32, MAX_CAPS), table.count);

    // Verify every slot is valid via lookup
    var valid_count: u32 = 0;
    for (0..MAX_CAPS) |i| {
        if (table.lookup(@intCast(i)) != null) valid_count += 1;
    }
    try testing.expectEqual(@as(u32, MAX_CAPS), valid_count);

    // Table is full
    try testing.expectError(error.TableFull, table.create(.frame, 0, Rights.ALL));

    // Delete slot 127 (middle), re-create, verify count
    table.delete(127);
    try testing.expectEqual(@as(u32, MAX_CAPS - 1), table.count);
    const reused = try table.create(.frame, 0xBEEF, Rights.READ_ONLY);
    try testing.expectEqual(@as(u32, 127), reused);
    try testing.expectEqual(@as(u32, MAX_CAPS), table.count);
}

test "delete then reuse slot invalidates old handles via generation" {
    var table = CapabilityTable{};
    const idx = try table.create(.frame, 0x1000, Rights.ALL);
    const old_cap = table.lookup(idx).?;
    const old_gen = old_cap.generation;

    // Delete: generation bumps
    table.delete(idx);
    try testing.expect(table.lookup(idx) == null);

    // Reuse the same slot: generation bumps again
    const idx2 = try table.create(.device, 0x2000, Rights.READ_ONLY);
    try testing.expectEqual(idx, idx2); // same slot reused
    const new_cap = table.lookup(idx2).?;
    try testing.expect(new_cap.generation != old_gen);
    try testing.expectEqual(CapabilityType.device, new_cap.cap_type);
    try testing.expectEqual(@as(usize, 0x2000), new_cap.object);
}

test "generation increments on each create-delete cycle" {
    var table = CapabilityTable{};

    // Track generation through multiple create/delete cycles on slot 0
    var prev_gen: u32 = 0;
    for (0..10) |_| {
        const idx = try table.create(.frame, 0, Rights.ALL);
        try testing.expectEqual(@as(CapIndex, 0), idx); // always reuses slot 0
        const c = table.lookup(idx).?;
        try testing.expect(c.generation > prev_gen);
        prev_gen = c.generation;
        table.delete(idx);
    }
    // After 10 create/delete cycles: 10 creates + 10 deletes = 20 increments
    try testing.expectEqual(@as(u32, 20), table.slots[0].generation);
}

test "derive write-only cap" {
    var table = CapabilityTable{};
    const parent = try table.create(.frame, 0x1000, Rights.ALL);
    const wo = try table.derive(parent, Rights{ .write = true });
    const c = table.lookup(wo).?;
    try testing.expect(!c.rights.read);
    try testing.expect(c.rights.write);
    try testing.expect(!c.rights.grant);
    try testing.expect(!c.rights.revoke);

    // Cannot escalate from write-only to read
    try testing.expectError(error.RightsEscalation, table.derive(wo, Rights.READ_ONLY));
    // Can further attenuate to NONE
    const none = try table.derive(wo, Rights.NONE);
    try testing.expect(table.lookup(none).?.rights.eql(Rights.NONE));
}
