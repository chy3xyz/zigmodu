//! Recorder — a bounded, zero-allocation log of the runtime's **delivery**
//! stream, plus replay in seq order against a `Clock.Manual`.
//!
//! The runtime is deliberately lossy (`HotBus` drops on a full mailbox and
//! counts it) and its ordering is only defined per mailbox, so "what did this
//! run actually deliver, in what order, at what time?" cannot be answered from
//! the runtime after the fact. `Recorder` answers it by taking a copy on the
//! way through:
//!
//! ```zig
//! var rt = runtime.Runtime.init(allocator, io, clock); // the same clock…
//! var rec = runtime.Recorder(Trade, 4096).init(clock); // …stamps the log
//! try bus.attachRecorder(&rec);   // before bus.freeze()
//! ...
//! rec.replay(&manual_clock, &harness, Harness.sink);  // no sleeping
//! ```
//!
//! Three properties, each a deliberate choice:
//!
//! 1. **Overflow is an error, not a drop.** `record` returns `error.Full` once
//!    the log has no room. That is the opposite of `HotBus`, on purpose: a log
//!    with a hole in it *looks* complete, so a replay built on it would be
//!    silently wrong. Nothing is ever overwritten, so `entries()` stays a
//!    prefix in `seq` order.
//! 2. **Zero allocation, lock-free.** Capacity is comptime, storage is a fixed
//!    array, and a record's sequence number *is* its slot index — one atomic
//!    increment claims order and space together. No allocator is threaded
//!    through `Mailbox` / `RingBuffer` / `send` for this.
//! 3. **Off costs one null check.** A bus with no recorder attached behaves
//!    exactly as it did before this file existed.
//!
//! ## Division of labour with `core/EventStore.zig`
//!
//! `EventStore` is **domain event sourcing**: application code appends *business*
//! events to a named `stream_id` with a version, may snapshot, and expects them
//! to survive a restart. It is the record of what the business decided.
//!
//! `Recorder` records the **runtime delivery stream**: what the hot path
//! actually handed over, in the order the runtime ordered it, stamped with the
//! injected clock — in memory, bounded, and opt-in. It is a debugging/replay
//! tool, not a system of record. Use neither in place of the other: appending
//! ticks to an `EventStore` misuses streams/versions, and using `Recorder` for
//! durability loses everything on exit.
//!
//! ## What v1 is not (`docs/RUNTIME.md` §11.4)
//!
//! - **Single event type.** A `Recorder(E, capacity)` logs one `E`. Recording the
//!   heterogeneous messages of several workers at once is not in v1 — and
//!   neither are `Handle.send` direct sends, `after` timer deliveries or
//!   `MpscRing` cross-producer interleavings. v1 logs the `HotBus` publish
//!   stream, whose order is defined at the record point.
//! - **Not a `HotBus` subscriber.** A sink consumes a comptime subscriber slot,
//!   and a recorder too small for the traffic would come back as `deliver ==
//!   false` → counted as a *drop* while the event kept flowing. The record point
//!   is therefore inside `HotBus.publish`, before the sink loop (see
//!   `HotBus.attachRecorder`).
//! - **No process-level determinism.** `spawn`/`init` side effects, sockets, the
//!   wall clock and drop-on-full delivery are not replayed. Replay reproduces
//!   what the log holds, not the interleaving a given run happened to observe.
//! - **Only clock-reading code replays.** Time is injected (`Clock`); code that
//!   calls `core/Time.zig` directly reads real time and is outside the replay.

const std = @import("std");
const Sequencer = @import("sequencer.zig").Sequencer;
const Clock = @import("clock.zig").Clock;

/// Errors `record` reports.
pub const RecordError = error{
    /// The log is full. Deliberately loud (see the file doc comment): the caller
    /// must decide to stop, resize or discard the log — continuing would produce
    /// a plausible-looking replay with a hole in it.
    Full,
};

/// A bounded, in-memory, zero-allocation log of `capacity` events of type `E`.
pub fn Recorder(comptime E: type, comptime capacity: usize) type {
    if (capacity < 1) @compileError("Recorder needs capacity >= 1");
    if (@sizeOf(E) == 0) @compileError("Recorder stores events by value; " ++ @typeName(E) ++ " has no size");
    return struct {
        const Self = @This();

        /// The event type this log holds — `HotBus.attachRecorder` checks it
        /// against the bus's own event type.
        pub const Event = E;

        /// One recorded delivery: the runtime sequence number, the injected
        /// clock reading at the record point, and the event itself.
        pub const Entry = struct {
            seq: u64,
            clock_ms: i64,
            event: E,
        };

        /// Comptime storage budget.
        pub const max_entries = capacity;

        /// Where `clock_ms` comes from at the record point. Use the same clock
        /// the runtime was built with (`Clock.monotonic` in production) so the
        /// timestamps line up with what timers saw; replay is then driven by a
        /// `Clock.Manual` set to those same values.
        clock: Clock,

        /// A record's sequence number *is* its slot index: `next()` hands out
        /// 0, 1, 2, …, so a value `>= capacity` is exactly "the log is full".
        /// One atomic increment therefore claims order and space together, and
        /// concurrent producers cannot collide on a slot.
        sequencer: Sequencer = Sequencer.init(0),

        /// Written before the slot is published; read only below `published`.
        entries_buf: [capacity]Entry = undefined,
        /// Per-slot publish flag. A producer sets its own slot with release; a
        /// reader that observed `published` with acquire only looks at slots
        /// whose flag it saw set. This keeps `entries()` a contiguous, complete
        /// prefix without a lock and without waiting.
        ready: [capacity]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false)),
        /// Length of the complete prefix of `entries_buf`, in seq order. A
        /// producer whose predecessor is still missing does not block: it
        /// publishes its slot and lets the predecessor's producer extend the
        /// prefix when it lands.
        published: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        overflowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        pub fn init(clock: Clock) Self {
            return .{ .clock = clock };
        }

        /// Append one event. Allocation-free and lock-free. `error.Full` when
        /// the log has no room left — the event is *not* silently discarded.
        pub fn record(self: *Self, event: E) RecordError!void {
            const n = self.sequencer.next();
            if (n >= capacity) {
                self.overflowed.store(true, .release);
                return RecordError.Full;
            }
            const slot: usize = @intCast(n);
            self.entries_buf[slot] = .{
                .seq = n,
                .clock_ms = self.clock.nowMs(),
                .event = event,
            };
            self.ready[slot].store(true, .release);
            self.advancePublished();
        }

        /// Extend `published` over every slot at the front that is now written.
        /// Cheap in the common case; a producer that runs ahead of a straggler
        /// simply stops here and returns.
        fn advancePublished(self: *Self) void {
            var next = self.published.load(.monotonic);
            while (next < capacity and self.ready[next].load(.acquire)) {
                if (self.published.cmpxchgWeak(next, next + 1, .release, .monotonic)) |actual| {
                    next = actual;
                    continue;
                }
                next += 1;
            }
        }

        /// The recorded events, in ascending `seq` — the replay order.
        pub fn entries(self: *const Self) []const Entry {
            return self.entries_buf[0..self.published.load(.acquire)];
        }

        /// How many events the log holds.
        pub fn len(self: *const Self) usize {
            return self.published.load(.acquire);
        }

        /// No further `record` will be accepted.
        pub fn full(self: *const Self) bool {
            return self.sequencer.peek() >= capacity;
        }

        /// The sequence number the next accepted record will carry (also the
        /// count of numbers handed out, so it keeps growing after an overflow).
        pub fn seq(self: *const Self) u64 {
            return self.sequencer.peek();
        }

        /// True once a `record` was refused. The log is incomplete from then on:
        /// discard it, or treat the replay as covering only `entries().len`
        /// events. There is no repair — the refused event is gone.
        pub fn hasOverflowed(self: *const Self) bool {
            return self.overflowed.load(.acquire);
        }

        /// Hand every entry to `sink` in seq order, moving `clock` to each
        /// entry's `clock_ms` first. Nothing sleeps and no wall-clock time is
        /// consulted: time comes from the log, so a three-hour recorded run
        /// replays at CPU speed and timers fire in the recorded relative order.
        ///
        /// `sink` is called as `sink(ctx, entry)` — pass `Harness.sink` for a
        /// `fn sink(self: *Harness, entry: Recorder(E, N).Entry) void`, or any
        /// plain `fn (ctx, entry)` with that shape.
        pub fn replay(self: *Self, clock: *Clock.Manual, ctx: anytype, sink: anytype) void {
            for (self.entries()) |entry| {
                clock.set(entry.clock_ms);
                sink(ctx, entry);
            }
        }
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const Time = @import("../core/Time.zig");
const hot_bus_mod = @import("hot_bus.zig");

/// Sink harness with fixed storage, so a test asserts after the replay without
/// an allocator on either side.
const Taken = struct {
    events: [16]u32 = @splat(0),
    times: [16]i64 = @splat(0),
    seen: usize = 0,

    fn sink(self: *@This(), entry: Recorder(u32, 16).Entry) void {
        self.events[self.seen] = entry.event;
        self.times[self.seen] = entry.clock_ms;
        self.seen += 1;
    }
};

test "record/replay round-trips every payload in seq order" {
    const payloads = [_]u32{ 7, 11, 13, 42 };
    var src = Clock.Manual{ .now_ms = 0 };
    var rec = Recorder(u32, 16).init(src.clock());

    for (payloads, 0..) |p, i| {
        src.set(100 + @as(i64, @intCast(i)) * 5);
        try rec.record(p);
    }
    try std.testing.expectEqual(payloads.len, rec.len());

    for (rec.entries(), 0..) |entry, i| {
        try std.testing.expectEqual(@as(u64, @intCast(i)), entry.seq);
        try std.testing.expectEqual(payloads[i], entry.event);
        try std.testing.expectEqual(@as(i64, 100 + @as(i64, @intCast(i)) * 5), entry.clock_ms);
    }

    var dst = Clock.Manual{ .now_ms = -1 };
    var taken = Taken{};
    rec.replay(&dst, &taken, Taken.sink);

    try std.testing.expectEqual(payloads.len, taken.seen);
    try std.testing.expectEqualSlices(u32, &payloads, taken.events[0..taken.seen]);
    try std.testing.expectEqualSlices(i64, &[_]i64{ 100, 105, 110, 115 }, taken.times[0..taken.seen]);
}

test "a full recorder reports error.Full instead of dropping silently" {
    var rec = Recorder(u32, 4).init(.monotonic);
    for (0..4) |i| try rec.record(@intCast(i));

    try std.testing.expect(rec.full());
    try std.testing.expectError(error.Full, rec.record(99));
    try std.testing.expectError(error.Full, rec.record(100));
    try std.testing.expect(rec.hasOverflowed());

    // The refused events are gone, but nothing was overwritten to make room.
    try std.testing.expectEqual(@as(usize, 4), rec.len());
    try std.testing.expectEqual(@as(usize, 4), rec.entries().len);
    var expected: u32 = 0;
    for (rec.entries()) |entry| {
        try std.testing.expectEqual(expected, entry.event);
        expected += 1;
    }
}

test "seq is strictly monotonic across records and refusals" {
    var rec = Recorder(u32, 3).init(.monotonic);
    try rec.record(1);
    try rec.record(2);
    try rec.record(3);
    try std.testing.expectEqual(@as(u64, 3), rec.seq());

    try std.testing.expectError(error.Full, rec.record(4));
    // The refused record still consumed a sequence number: seq never repeats.
    try std.testing.expectEqual(@as(u64, 4), rec.seq());

    var previous: u64 = 0;
    for (rec.entries(), 0..) |entry, i| {
        if (i > 0) try std.testing.expect(entry.seq > previous);
        previous = entry.seq;
    }
    try std.testing.expectEqual(@as(u64, 2), previous);
}

test "replay drives Clock.Manual to the recorded times — it never sleeps" {
    // A timer scenario: an event at t=0 schedules a 500 ms timer, the fire
    // arrives at t=500, and one more event follows at t=501. Recorded across a
    // half-second of *recorded* time; replay must not spend that time waiting.
    const R = Recorder(u32, 8);
    var src = Clock.Manual{ .now_ms = 0 };
    var rec = R.init(src.clock());
    try rec.record(0); // scheduled
    src.advance(500);
    try rec.record(500); // fired
    src.advance(1);
    try rec.record(501);

    const Harness = struct {
        clock: *Clock.Manual,
        due_ms: i64 = 500,
        fired: usize = 0,
        seen_clock: [8]i64 = @splat(0),
        seen: usize = 0,

        fn sink(self: *@This(), entry: R.Entry) void {
            self.seen_clock[self.seen] = self.clock.now_ms;
            self.seen += 1;
            if (entry.event >= self.due_ms) self.fired += 1;
        }
    };

    var dst = Clock.Manual{ .now_ms = -1 };
    var h = Harness{ .clock = &dst };
    const started = Time.monotonicNowMilliseconds();
    rec.replay(&dst, &h, Harness.sink);
    const elapsed = Time.monotonicNowMilliseconds() - started;

    try std.testing.expectEqual(@as(usize, 3), h.seen);
    // The clock the sink observed is the recorded one, per entry.
    try std.testing.expectEqualSlices(i64, &[_]i64{ 0, 500, 501 }, h.seen_clock[0..h.seen]);
    try std.testing.expectEqual(@as(usize, 2), h.fired);
    try std.testing.expectEqual(@as(i64, 501), dst.now_ms);
    // 501 ms of recorded time replayed in well under half a second of wall time:
    // the clock was moved by the log, not waited on.
    try std.testing.expect(elapsed < 500);
}

/// Collects whatever a `HotBus(u32, 2)` publishes.
const Gather = struct {
    buf: *[8]u32,
    n: usize = 0,

    fn sink(self: *@This()) hot_bus_mod.HotBus(u32, 2).Sink {
        return .{ .ctx = @ptrCast(self), .deliver = deliver };
    }

    fn deliver(ctx: *anyopaque, event: u32) bool {
        const self: *Gather = @ptrCast(@alignCast(ctx));
        self.buf[self.n] = event;
        self.n += 1;
        return true;
    }
};

test "HotBus publish behaves the same with and without a recorder attached" {
    const Bus = hot_bus_mod.HotBus(u32, 2);

    // One identical run of the bus — subscribe, (optionally) attach, freeze,
    // publish 1..3 — with the same assertions in both cases. An attached
    // recorder must not change what `publish` reports to its callers.
    const Case = struct {
        fn run(with_recorder: bool, rec: *Recorder(u32, 8)) !struct {
            returns: [3]bool,
            recorder: bool,
        } {
            var collected: [8]u32 = @splat(0);
            var gather = Gather{ .buf = &collected };
            var bus = Bus.init();
            try bus.subscribeSink(gather.sink());
            if (with_recorder) try bus.attachRecorder(rec);
            bus.freeze();

            var returns: [3]bool = undefined;
            for (0..3) |i| {
                returns[i] = try bus.publish(@intCast(i + 1));
                try std.testing.expect(returns[i]);
            }
            try std.testing.expectEqual(with_recorder, bus.hasRecorder());
            try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3 }, collected[0..gather.n]);
            try std.testing.expectEqual(@as(u64, 3), bus.stats().published);
            try std.testing.expectEqual(@as(u64, 0), bus.stats().record_dropped);
            return .{ .returns = returns, .recorder = bus.hasRecorder() };
        }
    };

    var rec = Recorder(u32, 8).init(.monotonic);
    const plain = try Case.run(false, &rec);
    try std.testing.expectEqual(@as(usize, 0), rec.len());

    const logged = try Case.run(true, &rec);
    try std.testing.expectEqualSlices(bool, &plain.returns, &logged.returns);
    try std.testing.expectEqualSlices(bool, &[_]bool{ true, true, true }, &logged.returns);
    try std.testing.expect(!plain.recorder);
    try std.testing.expect(logged.recorder);

    try std.testing.expectEqual(@as(usize, 3), rec.len());
    for (rec.entries(), 0..) |entry, i| try std.testing.expectEqual(@as(u32, @intCast(i + 1)), entry.event);
}

test "a recorder is wired before freeze — attachRecorder is error.Frozen after it" {
    const Bus = hot_bus_mod.HotBus(u32, 1);
    var rec = Recorder(u32, 4).init(.monotonic);

    var bus = Bus.init();
    bus.freeze();
    try std.testing.expectError(hot_bus_mod.Error.Frozen, bus.attachRecorder(&rec));
    try std.testing.expect(!bus.hasRecorder());

    var fresh = Bus.init();
    try fresh.attachRecorder(&rec);
    try std.testing.expect(fresh.hasRecorder());
}

test "a refused record is visible on the bus, not swallowed" {
    const Bus = hot_bus_mod.HotBus(u32, 1);
    var bus = Bus.init();
    var rec = Recorder(u32, 2).init(.monotonic);
    try bus.attachRecorder(&rec);
    bus.freeze();

    try std.testing.expect(try bus.publish(1));
    try std.testing.expect(try bus.publish(2));
    // Third publish: the log is full. The bus must say so — in the return value
    // and in the counter — rather than keep publishing an unlogged stream.
    try std.testing.expect(!try bus.publish(3));

    const s = bus.stats();
    try std.testing.expectEqual(@as(u64, 3), s.published);
    try std.testing.expectEqual(@as(u64, 1), s.record_dropped);
    try std.testing.expect(rec.hasOverflowed());
    try std.testing.expectEqual(@as(usize, 2), rec.len());
}

test "concurrent producers get distinct sequence numbers and lose nothing" {
    const producers = 4;
    const per_producer = 500;
    const total = producers * per_producer;
    const R = Recorder(u32, total);

    var rec = R.init(.monotonic);
    const Worker = struct {
        fn run(r: *R, tag: u32) void {
            var i: u32 = 0;
            while (i < per_producer) : (i += 1) r.record(tag) catch return;
        }
    };

    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &rec, @as(u32, @intCast(i)) });
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, total), rec.len());
    try std.testing.expect(!rec.hasOverflowed());
    var seen: [total]bool = @splat(false);
    for (rec.entries(), 0..) |entry, i| {
        // Slot == seq, so the log has no holes and is already in replay order.
        try std.testing.expectEqual(@as(u64, @intCast(i)), entry.seq);
        const slot: usize = @intCast(entry.seq);
        try std.testing.expect(!seen[slot]);
        seen[slot] = true;
    }
}
