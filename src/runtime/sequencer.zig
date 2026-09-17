//! Sequencer — a lock-free monotonic sequence, for ordering without a clock.
//!
//! Two threads that both "stamp" an event need a total order that is *not*
//! wall-clock time (which can go backwards) and not a mutex (which serialises
//! them). One atomic increment gives both: every caller gets a distinct number,
//! and the numbers agree with the order in which the increments happened.
//!
//! Used for: event sequence numbers, "this is newer than that" comparisons,
//! version stamps on a lock-free write, correlating a hot event with the
//! snapshot that followed it.
//!
//! Not a clock: values are only meaningful (and comparable) within one process
//! lifetime. Persist a snapshot of `peek()` if you need them to survive a
//! restart.

const std = @import("std");

pub const Sequencer = struct {
    counter: std.atomic.Value(u64),

    pub fn init(start: u64) Sequencer {
        return .{ .counter = std.atomic.Value(u64).init(start) };
    }

    /// Next value. Unique per call, monotonic across threads, never blocks.
    pub fn next(self: *Sequencer) u64 {
        return self.counter.fetchAdd(1, .monotonic);
    }

    /// Reserve `count` values, returning the first. Use this to stamp a batch
    /// atomically ("these N events are consecutive") instead of calling `next`
    /// N times and hoping nobody interleaves.
    pub fn nextBatch(self: *Sequencer, count: u64) u64 {
        return self.counter.fetchAdd(count, .monotonic);
    }

    /// The value the next `next()` will return. A read, not a reservation.
    pub fn peek(self: *const Sequencer) u64 {
        return self.counter.load(.monotonic);
    }

    /// Move the counter forward to at least `value` (e.g. after replaying a
    /// snapshot). Never moves backwards, so a stale replay cannot reissue
    /// numbers that were already handed out.
    pub fn advanceTo(self: *Sequencer, value: u64) void {
        var observed = self.counter.load(.monotonic);
        while (value > observed) {
            observed = self.counter.cmpxchgWeak(observed, value, .monotonic, .monotonic) orelse return;
        }
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "Sequencer hands out unique, monotonic values" {
    var seq = Sequencer.init(1);
    try std.testing.expectEqual(@as(u64, 1), seq.peek());
    try std.testing.expectEqual(@as(u64, 1), seq.next());
    try std.testing.expectEqual(@as(u64, 2), seq.next());
    try std.testing.expectEqual(@as(u64, 3), seq.peek());
}

test "Sequencer peers are consecutive even under concurrency" {
    const threads_n = 8;
    const per_thread = 20_000;

    var seq = Sequencer.init(0);
    const Shared = struct {
        fn run(s: *Sequencer, first: *std.atomic.Value(u64)) void {
            // Each thread reserves one block: the blocks partition the range, so
            // the union of all taken values must be exactly 0..N-1.
            const base = s.nextBatch(per_thread);
            first.store(base, .monotonic);
        }
    };

    var starts: [threads_n]std.atomic.Value(u64) = @splat(std.atomic.Value(u64).init(0));
    var threads: [threads_n]std.Thread = undefined;
    for (&threads, &starts) |*t, *s| t.* = try std.Thread.spawn(.{}, Shared.run, .{ &seq, s });
    for (threads) |t| t.join();

    var seen: [threads_n * per_thread]bool = @splat(false);
    for (starts) |s| {
        const base = s.load(.monotonic);
        try std.testing.expect(base + per_thread <= seen.len);
        for (base..base + per_thread) |i| {
            try std.testing.expect(!seen[i]); // no value handed out twice
            seen[i] = true;
        }
    }
    try std.testing.expectEqual(@as(u64, threads_n * per_thread), seq.peek());
}

test "Sequencer advanceTo never goes backwards" {
    var seq = Sequencer.init(100);
    seq.advanceTo(50); // stale replay: ignored
    try std.testing.expectEqual(@as(u64, 100), seq.peek());
    seq.advanceTo(250);
    try std.testing.expectEqual(@as(u64, 250), seq.peek());
    try std.testing.expectEqual(@as(u64, 250), seq.next());
}
