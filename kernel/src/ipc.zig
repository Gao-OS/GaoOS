// Inter-Process Communication
//
// This is the BEAM hot path — every BEAM message flows through IPC.
//
// Design choices for BEAM:
// - Tagged messages: BEAM's `receive` does selective pattern matching.
//   The tag field enables first-pass filtering without inspecting payload.
// - Capability transfer: sending a message can transfer capabilities to
//   the receiver, enabling delegation patterns for BEAM process linking.
// - Bounded inline payload: most BEAM messages are small terms.
//   Large data uses shared-memory capabilities (future: cap_shmem).
//
// Phase 1: simple blocking model with ring buffer.
// Future: lock-free queue, batch delivery, zero-copy large messages.

const cap = @import("cap");

/// Maximum inline payload size in bytes.
pub const MAX_PAYLOAD = 256;

/// Maximum capabilities transferred per message.
pub const MAX_MSG_CAPS = 4;

/// Maximum messages queued per endpoint.
pub const QUEUE_SIZE = 16;

/// Tag value that matches any message (for unfiltered receive).
pub const TAG_ANY: u64 = 0;

/// A message: the unit of IPC communication.
pub const Message = struct {
    tag: u64 = 0, // For BEAM selective receive
    payload_len: u32 = 0,
    payload: [MAX_PAYLOAD]u8 = [_]u8{0} ** MAX_PAYLOAD,
    cap_count: u32 = 0,
    caps: [MAX_MSG_CAPS]cap.CapIndex = [_]cap.CapIndex{cap.CAP_NULL} ** MAX_MSG_CAPS,

    /// Create a message with a tag and byte payload.
    pub fn init(tag: u64, data: []const u8) Message {
        var msg = Message{ .tag = tag };
        const len = @min(data.len, MAX_PAYLOAD);
        @memcpy(msg.payload[0..len], data[0..len]);
        msg.payload_len = @intCast(len);
        return msg;
    }

    /// Attach a capability to transfer with this message.
    pub fn attachCap(self: *Message, cap_index: cap.CapIndex) error{TooManyCaps}!void {
        if (self.cap_count >= MAX_MSG_CAPS) return error.TooManyCaps;
        self.caps[self.cap_count] = cap_index;
        self.cap_count += 1;
    }

    /// Get the payload as a byte slice.
    pub fn getPayload(self: *const Message) []const u8 {
        return self.payload[0..self.payload_len];
    }
};

/// An IPC endpoint: a bounded message queue.
/// Each endpoint is a kernel object referenced by capabilities.
pub const Endpoint = struct {
    queue: [QUEUE_SIZE]Message = undefined,
    head: u32 = 0, // Next slot to read
    tail: u32 = 0, // Next slot to write
    count: u32 = 0, // Messages currently queued
    closed: bool = false,

    /// Send a message to this endpoint.
    /// Capability transfer: caps listed in the message are moved from
    /// sender_table to receiver_table (remove from sender, add to receiver).
    pub fn send(
        self: *Endpoint,
        msg: Message,
        sender_table: ?*cap.CapabilityTable,
        receiver_table: ?*cap.CapabilityTable,
    ) error{ QueueFull, EndpointClosed, InvalidCapability, TableFull }!void {
        if (self.closed) return error.EndpointClosed;
        if (self.count >= QUEUE_SIZE) return error.QueueFull;

        var queued_msg = msg;

        // Transfer capabilities: remove from sender, create in receiver
        if (sender_table != null and receiver_table != null) {
            var i: u32 = 0;
            while (i < msg.cap_count) : (i += 1) {
                const src_idx = msg.caps[i];
                if (src_idx == cap.CAP_NULL) continue;

                const src_cap = sender_table.?.lookup(src_idx) orelse
                    return error.InvalidCapability;

                // Create in receiver table
                const new_idx = receiver_table.?.create(
                    src_cap.cap_type,
                    src_cap.object,
                    src_cap.rights,
                ) catch return error.TableFull;

                // Remove from sender
                sender_table.?.delete(src_idx);

                // Update message with new index (receiver's perspective)
                queued_msg.caps[i] = new_idx;
            }
        }

        self.queue[self.tail] = queued_msg;
        self.tail = (self.tail + 1) % QUEUE_SIZE;
        self.count += 1;
    }

    /// Receive a message from this endpoint.
    /// If tag_filter != TAG_ANY, only return messages with matching tag.
    /// Returns null if no matching message is available (non-blocking).
    pub fn recv(self: *Endpoint, tag_filter: u64) ?Message {
        if (self.count == 0) return null;

        if (tag_filter == TAG_ANY) {
            // Take the first message
            const msg = self.queue[self.head];
            self.head = (self.head + 1) % QUEUE_SIZE;
            self.count -= 1;
            return msg;
        }

        // Selective receive: scan for matching tag
        // Phase 1: linear scan with compaction (not optimal, but correct)
        var scan: u32 = 0;
        while (scan < self.count) : (scan += 1) {
            const idx = (self.head + scan) % QUEUE_SIZE;
            if (self.queue[idx].tag == tag_filter) {
                const msg = self.queue[idx];

                // Compact: shift remaining messages forward
                var shift: u32 = scan;
                while (shift + 1 < self.count) : (shift += 1) {
                    const from = (self.head + shift + 1) % QUEUE_SIZE;
                    const to = (self.head + shift) % QUEUE_SIZE;
                    self.queue[to] = self.queue[from];
                }
                self.count -= 1;
                self.tail = (self.head + self.count) % QUEUE_SIZE;

                return msg;
            }
        }

        return null; // No matching message
    }

    /// Close the endpoint. No more messages can be sent.
    /// Pending messages can still be received.
    pub fn close(self: *Endpoint) void {
        self.closed = true;
    }

    /// Check if the queue is empty.
    pub fn isEmpty(self: *const Endpoint) bool {
        return self.count == 0;
    }

    /// Check if the queue is full.
    pub fn isFull(self: *const Endpoint) bool {
        return self.count >= QUEUE_SIZE;
    }
};

// ─── Tests ──────────────────────────────────────────────────────────

const testing = @import("std").testing;

test "send and receive message" {
    var ep = Endpoint{};

    const msg = Message.init(42, "hello");
    try ep.send(msg, null, null);

    const received = ep.recv(TAG_ANY).?;
    try testing.expectEqual(@as(u64, 42), received.tag);
    try testing.expectEqualSlices(u8, "hello", received.getPayload());
}

test "FIFO ordering" {
    var ep = Endpoint{};

    try ep.send(Message.init(1, "first"), null, null);
    try ep.send(Message.init(2, "second"), null, null);
    try ep.send(Message.init(3, "third"), null, null);

    try testing.expectEqual(@as(u64, 1), ep.recv(TAG_ANY).?.tag);
    try testing.expectEqual(@as(u64, 2), ep.recv(TAG_ANY).?.tag);
    try testing.expectEqual(@as(u64, 3), ep.recv(TAG_ANY).?.tag);
    try testing.expect(ep.recv(TAG_ANY) == null);
}

test "selective receive with tag filter" {
    var ep = Endpoint{};

    try ep.send(Message.init(10, "a"), null, null);
    try ep.send(Message.init(20, "b"), null, null);
    try ep.send(Message.init(10, "c"), null, null);

    // Receive only tag=20
    const msg = ep.recv(20).?;
    try testing.expectEqual(@as(u64, 20), msg.tag);
    try testing.expectEqualSlices(u8, "b", msg.getPayload());

    // Remaining: tag=10 "a", tag=10 "c"
    try testing.expectEqual(@as(u32, 2), ep.count);
}

test "full queue returns error" {
    var ep = Endpoint{};

    for (0..QUEUE_SIZE) |i| {
        try ep.send(Message.init(@intCast(i), "x"), null, null);
    }

    const result = ep.send(Message.init(99, "overflow"), null, null);
    try testing.expectError(error.QueueFull, result);
}

test "send with capability transfer" {
    var ep = Endpoint{};
    var sender_table = cap.CapabilityTable{};
    var receiver_table = cap.CapabilityTable{};

    // Sender creates a capability
    const src_idx = try sender_table.create(.frame, 0xDEAD, cap.Rights.READ_WRITE);

    // Build message with cap transfer
    var msg = Message.init(1, "here's a cap");
    try msg.attachCap(src_idx);

    // Send with transfer
    try ep.send(msg, &sender_table, &receiver_table);

    // Sender no longer has the cap
    try testing.expect(sender_table.lookup(src_idx) == null);

    // Receive the message
    const received = ep.recv(TAG_ANY).?;

    // Receiver has the transferred cap
    const new_idx = received.caps[0];
    const transferred = receiver_table.lookup(new_idx).?;
    try testing.expectEqual(cap.CapabilityType.frame, transferred.cap_type);
    try testing.expectEqual(@as(usize, 0xDEAD), transferred.object);
    try testing.expect(transferred.rights.read);
    try testing.expect(transferred.rights.write);
}

test "closed endpoint rejects send" {
    var ep = Endpoint{};
    ep.close();

    const result = ep.send(Message.init(1, "nope"), null, null);
    try testing.expectError(error.EndpointClosed, result);
}

test "closed endpoint allows pending recv" {
    var ep = Endpoint{};
    try ep.send(Message.init(1, "before close"), null, null);
    ep.close();

    // Can still receive pending
    const msg = ep.recv(TAG_ANY).?;
    try testing.expectEqual(@as(u64, 1), msg.tag);
}

test "attach too many caps" {
    var msg = Message.init(1, "caps");
    for (0..MAX_MSG_CAPS) |_| {
        try msg.attachCap(0);
    }
    const result = msg.attachCap(0);
    try testing.expectError(error.TooManyCaps, result);
}

test "recv returns null on empty endpoint" {
    var ep = Endpoint{};
    try testing.expect(ep.recv(TAG_ANY) == null);
    try testing.expect(ep.recv(42) == null);
}

test "send_cap: transferred cap index updated in received message" {
    var ep = Endpoint{};
    var sender = cap.CapabilityTable{};
    var receiver = cap.CapabilityTable{};

    // Pre-populate receiver so transferred cap lands at a different index
    _ = try receiver.create(.device, 0, cap.Rights.READ_ONLY);
    const src_idx = try sender.create(.frame, 0xCAFE, cap.Rights.ALL);

    var msg = Message.init(99, "with cap");
    try msg.attachCap(src_idx);
    try ep.send(msg, &sender, &receiver);

    // Sender no longer holds the cap
    try testing.expect(sender.lookup(src_idx) == null);

    const received = ep.recv(TAG_ANY).?;
    try testing.expectEqual(@as(u32, 1), received.cap_count);
    const new_idx = received.caps[0];
    const transferred = receiver.lookup(new_idx).?;
    try testing.expectEqual(cap.CapabilityType.frame, transferred.cap_type);
    try testing.expectEqual(@as(usize, 0xCAFE), transferred.object);
}

test "send_cap with invalid cap index returns error" {
    var ep = Endpoint{};
    var sender = cap.CapabilityTable{};
    var receiver = cap.CapabilityTable{};

    var msg = Message.init(1, "bad cap");
    try msg.attachCap(42); // index 42 not in sender table
    const result = ep.send(msg, &sender, &receiver);
    try testing.expectError(error.InvalidCapability, result);
}

test "recv returns cap_count 0 when no cap sent" {
    var ep = Endpoint{};
    const msg = Message.init(7, "no cap");
    try ep.send(msg, null, null);

    const received = ep.recv(TAG_ANY).?;
    try testing.expectEqual(@as(u32, 0), received.cap_count);
}
