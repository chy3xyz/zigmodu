//! Lock-free bounded queues — the transport under mailboxes, hot events and
//! worker hand-off.
//!
//! Two shapes, because the producer/consumer count is the whole design:
//!
//! | type | producers | consumers | algorithm |
//! |------|-----------|-----------|-----------|
//! | `RingBuffer(T, N)` | 1 | 1 | head/tail indices, no CAS at all |
//! | `MpscRing(T, N)` | many | 1 | Vyukov bounded queue (sequence per slot) |
//!
//! Both are **bounded and allocation-free after construction**: capacity is a
//! comptime power of two, values live in a fixed array, and a full queue reports
//! `false` instead of growing. That is the point — a hot path that allocates is
//! a hot path that stalls, and backpressure has to be visible to the caller so it
//! can drop, coalesce or block deliberately.
//!
//! Neither type owns `T`: `tryPop` returns a copy. Keep `T` a plain value
//! (indices, prices, small structs). If you need to move owned memory between
//! threads, move a pointer to it and hand ownership back explicitly.
//!
//! Ordering: a successful `tryPush` happens-before the matching `tryPop`
//! (release/acquire on the index the consumer reads), so anything the producer
//! wrote into the slot before pushing is visible to the consumer.

const std = @import("std");

/// Cache-line-separated index. Two counters in the same line make one core's
/// store invalidate the other's line on every operation — on a hot queue that
/// costs more than the operation itself.
fn Padded(comptime T: type) type {
    return struct {
        value: T align(std.atomic.cache_line),
    };
}

fn isPowerOfTwo(comptime n: usize) bool {
    return n != 0 and (n & (n - 1)) == 0;
}

/// Single-producer / single-consumer ring. One thread pushes, one pops.
///
/// No CAS: the producer owns `tail`, the consumer owns `head`, and each only
/// *reads* the other's index. That makes it the cheapest primitive here — and
/// the wrong one the moment a second producer appears (use `MpscRing`).
pub fn RingBuffer(comptime T: type, comptime capacity: usize) type {
    if (!isPowerOfTwo(capacity)) @compileError("RingBuffer capacity must be a power of two (mask-based indexing)");
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        /// Written by the consumer.
        head: Padded(std.atomic.Value(usize)) = .{ .value = std.atomic.Value(usize).init(0) },
        /// Written by the producer.
        tail: Padded(std.atomic.Value(usize)) = .{ .value = std.atomic.Value(usize).init(0) },
        slots: [capacity]T = undefined,
        /// Counters survive wrap-around; only `len` does the arithmetic.
        dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        high_water: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        /// Producer side. False when full — the caller decides what to do.
        pub fn tryPush(self: *Self, item: T) bool {
            const tail = self.tail.value.load(.monotonic);
            const head = self.head.value.load(.acquire);
            if (tail -% head == capacity) {
                _ = self.dropped.fetchAdd(1, .monotonic);
                return false;
            }
            self.slots[tail & mask] = item;
            self.tail.value.store(tail +% 1, .release);
            const depth = tail -% head + 1;
            if (depth > self.high_water.load(.monotonic)) self.high_water.store(depth, .monotonic);
            return true;
        }

        /// Consumer side. Null when empty.
        pub fn tryPop(self: *Self) ?T {
            const head = self.head.value.load(.monotonic);
            const tail = self.tail.value.load(.acquire);
            if (head == tail) return null;
            const item = self.slots[head & mask];
            self.head.value.store(head +% 1, .release);
            return item;
        }

        pub fn len(self: *const Self) usize {
            const tail = self.tail.value.load(.acquire);
            const head = self.head.value.load(.acquire);
            return tail -% head;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == capacity;
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .capacity = capacity,
                .len = self.len(),
                .dropped = self.dropped.load(.monotonic),
                .high_water = self.high_water.load(.monotonic),
            };
        }

        pub const Stats = struct {
            capacity: usize,
            len: usize,
            /// Pushes rejected because the ring was full.
            dropped: u64,
            high_water: usize,
        };
    };
}

/// Many-producer / single-consumer bounded queue (Vyukov).
///
/// Each slot carries its own sequence number, so a producer claims a slot with
/// one CAS on `enqueue_pos` and a consumer releases it with one CAS on
/// `dequeue_pos` — no global lock and no false sharing between the two ends.
/// Messages from a *single* producer are delivered in order; across producers
/// there is no ordering guarantee.
pub fn MpscRing(comptime T: type, comptime capacity: usize) type {
    if (!isPowerOfTwo(capacity)) @compileError("MpscRing capacity must be a power of two (mask-based indexing)");
    // Vyukov's algorithm distinguishes "slot free for round pos" from "slot still
    // holds the previous round" by the slot sequence: a producer writes `pos + 1`
    // and a consumer writes `pos + capacity`. At capacity 1 those are the same
    // number, so a second push into the only slot looks free and *overwrites an
    // unconsumed message* (measured: len grew to 2 with capacity 1). Require ≥ 2.
    if (capacity < 2) @compileError("MpscRing requires capacity >= 2: at capacity 1 the slot sequence cannot tell 'free' from 'not consumed yet'. Use RingBuffer for a 1-slot hand-off.");
    return struct {
        const Self = @This();
        const mask = capacity - 1;

        const Slot = struct {
            sequence: std.atomic.Value(usize),
            value: T = undefined,
        };

        slots: [capacity]Slot,
        enqueue_pos: Padded(std.atomic.Value(usize)) = .{ .value = std.atomic.Value(usize).init(0) },
        dequeue_pos: Padded(std.atomic.Value(usize)) = .{ .value = std.atomic.Value(usize).init(0) },
        dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        high_water: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init() Self {
            var self: Self = .{ .slots = undefined };
            for (&self.slots, 0..) |*slot, i| slot.sequence = std.atomic.Value(usize).init(i);
            return self;
        }

        /// Any thread. False when full.
        pub fn tryPush(self: *Self, item: T) bool {
            var pos = self.enqueue_pos.value.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @bitCast(seq -% pos));
                if (diff == 0) {
                    if (self.enqueue_pos.value.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        pos = actual;
                        continue;
                    }
                    slot.value = item;
                    slot.sequence.store(pos +% 1, .release);
                    const depth = (pos +% 1) -% self.dequeue_pos.value.load(.monotonic);
                    if (depth > self.high_water.load(.monotonic)) self.high_water.store(depth, .monotonic);
                    return true;
                } else if (diff < 0) {
                    // Slot still holds the previous round's value: queue is full.
                    _ = self.dropped.fetchAdd(1, .monotonic);
                    return false;
                } else {
                    pos = self.enqueue_pos.value.load(.monotonic);
                }
            }
        }

        /// **Single consumer only.** Null when empty.
        pub fn tryPop(self: *Self) ?T {
            const pos = self.dequeue_pos.value.load(.monotonic);
            const slot = &self.slots[pos & mask];
            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @bitCast(seq -% (pos +% 1)));
            if (diff != 0) return null; // empty (diff < 0) or a producer mid-write (diff > 0)
            const item = slot.value;
            self.dequeue_pos.value.store(pos +% 1, .monotonic);
            slot.sequence.store(pos +% capacity, .release);
            return item;
        }

        pub fn len(self: *const Self) usize {
            return self.enqueue_pos.value.load(.acquire) -% self.dequeue_pos.value.load(.acquire);
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len() == capacity;
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .capacity = capacity,
                .len = self.len(),
                .dropped = self.dropped.load(.monotonic),
                .high_water = self.high_water.load(.monotonic),
            };
        }

        pub const Stats = struct {
            capacity: usize,
            len: usize,
            dropped: u64,
            high_water: usize,
        };
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "RingBuffer is FIFO, reports fullness and wraps around" {
    var ring: RingBuffer(u32, 4) = .{};

    try std.testing.expect(ring.isEmpty());
    for (0..4) |i| try std.testing.expect(ring.tryPush(@intCast(i)));
    try std.testing.expect(ring.isFull());
    try std.testing.expect(!ring.tryPush(99)); // full: refused, not grown
    try std.testing.expectEqual(@as(u64, 1), ring.stats().dropped);

    for (0..4) |i| try std.testing.expectEqual(@as(u32, @intCast(i)), ring.tryPop().?);
    try std.testing.expect(ring.tryPop() == null);

    // Wrap: push/pop interleaved well past capacity.
    var next_in: u32 = 100;
    var next_out: u32 = 100;
    for (0..50) |_| {
        try std.testing.expect(ring.tryPush(next_in));
        try std.testing.expectEqual(next_out, ring.tryPop().?);
        next_in += 1;
        next_out += 1;
    }
    try std.testing.expect(ring.isEmpty());
}

test "RingBuffer moves values between two threads without loss" {
    const N = 200_000;
    const Ring = RingBuffer(u64, 1024);
    const Shared = struct {
        ring: *Ring,
        fn produce(r: *Ring) void {
            var i: u64 = 0;
            while (i < N) {
                if (r.tryPush(i)) i += 1 else std.atomic.spinLoopHint();
            }
        }
    };
    var ring: Ring = .{};
    const producer = try std.Thread.spawn(.{}, Shared.produce, .{&ring});

    var expected: u64 = 0;
    var sum: u64 = 0;
    while (expected < N) {
        if (ring.tryPop()) |v| {
            try std.testing.expectEqual(expected, v); // SPSC: strict order
            sum +%= v;
            expected += 1;
        } else std.atomic.spinLoopHint();
    }
    producer.join();
    try std.testing.expectEqual(@as(u64, N), expected);
    try std.testing.expectEqual(@as(u64, 0) + (N - 1) * N / 2, sum);
}

test "MpscRing accepts many producers and keeps each producer's order" {
    const per_producer = 20_000;
    const producers = 4;
    const Ring = MpscRing(u64, 512);
    const Shared = struct {
        ring: *Ring,
        fn produce(r: *Ring, tag: u64) void {
            var i: u64 = 0;
            while (i < per_producer) {
                // Encode tag in the high bits so we can check per-producer order.
                const msg = (tag << 32) | i;
                if (r.tryPush(msg)) i += 1 else std.atomic.spinLoopHint();
            }
        }
    };
    var ring = Ring.init();
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Shared.produce, .{ &ring, @as(u64, i) });

    var seen: [producers]u64 = @splat(0);
    var total: usize = 0;
    while (total < producers * per_producer) {
        if (ring.tryPop()) |v| {
            const tag = v >> 32;
            const seq = v & 0xffff_ffff;
            try std.testing.expectEqual(seen[tag], seq); // this producer's messages stay in order
            seen[tag] += 1;
            total += 1;
        } else std.atomic.spinLoopHint();
    }
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, producers * per_producer), total);
    try std.testing.expect(ring.isEmpty());
}

test "MpscRing reports full instead of overwriting" {
    var ring = MpscRing(u8, 2).init();
    try std.testing.expect(ring.tryPush(1));
    try std.testing.expect(ring.tryPush(2));
    try std.testing.expect(!ring.tryPush(3)); // full
    try std.testing.expectEqual(@as(u8, 1), ring.tryPop().?); // the refused push did not clobber slot 0
    try std.testing.expectEqual(@as(u8, 2), ring.tryPop().?);
    try std.testing.expect(ring.tryPop() == null);
}
