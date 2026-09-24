//! Mailbox — the bounded, blocking hand-off between threads (later: between
//! actors).
//!
//! A `Mailbox(T, N)` is the queue half of a worker: many threads may `send`, the
//! owning thread `recv`s. It is bounded by construction, so the two failure modes
//! that matter are both *visible*:
//!
//! * **Full** — `send` returns `error.Full` (or `sendBlocking` waits, up to a
//!   budget). A hot producer decides whether to drop, coalesce or back off; the
//!   queue never silently grows until the process dies.
//! * **Closed** — `close()` wakes every waiter; `recv` drains what is left and
//!   then answers `null`. That is how a worker's loop ends without polling a flag.
//!
//! `recv` avoids the two classic mistakes: it spins briefly (most messages are
//! already there — a syscall would cost more than the message), and once it does
//! block it re-checks the queue *while holding the mutex* and producers signal
//! *while holding the same mutex*, so a message can never be published into the
//! gap between the check and the wait.

const std = @import("std");
const ring = @import("ring.zig");

/// Sub-millisecond wait budgets need nanoseconds, so this one stays local.
fn nanosDuration(nanoseconds: i96) std.Io.Clock.Duration {
    return .{ .raw = std.Io.Duration.fromNanoseconds(nanoseconds), .clock = .awake };
}

pub const SendError = error{
    /// Queue is full. The caller decides what to do — nothing was enqueued.
    Full,
    /// The mailbox was closed; the message was not enqueued.
    Closed,
    /// `sendBlocking` gave up waiting for space.
    Timeout,
};

/// How long `recv` spins before parking on the condition variable. Sized so the
/// common case (a message already queued, or arriving within a few microseconds)
/// never touches the kernel.
const spin_rounds = 64;

pub fn Mailbox(comptime T: type, comptime capacity: usize) type {
    // A 1-message mailbox is a legitimate idea (a command slot) but the ring
    // underneath cannot express it — see `MpscRing`'s capacity guard. Say so at
    // the call site rather than losing messages at runtime.
    if (capacity < 2) @compileError("Mailbox requires capacity >= 2 (the underlying MpscRing cannot represent a 1-slot queue; use capacity 2 or a RingBuffer + SpinLock)");
    return struct {
        const Self = @This();

        io: std.Io,
        ring: ring.MpscRing(T, capacity) = .init(),
        mu: std.Io.Mutex = .init,
        not_empty: std.Io.Condition = .init,
        not_full: std.Io.Condition = .init,
        closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        dropped_full: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        wait_spins: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Bumped by `wake` to make a parked `recvWakeable` return early.
        ///
        /// The mailbox normally has exactly two reasons for a receiver to stop
        /// waiting: a message, or `close`. That is enough for as long as an
        /// external "please come back" only ever means "stop for good" — but a
        /// supervision group asking one of its members to rebuild itself (§14)
        /// is a third reason, it arrives from another thread, and it is not a
        /// message the (typed) mailbox could carry. The epoch gives `recvWakeable`
        /// something to compare against; `recv` passes the current value and
        /// therefore never returns for it, which is what keeps the ordinary
        /// receive path exactly as it was.
        wake_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn init(io: std.Io) Self {
            return .{ .io = io };
        }

        /// Non-blocking. `error.Full` leaves the queue untouched.
        pub fn send(self: *Self, message: T) SendError!void {
            if (self.closed.load(.acquire)) return error.Closed;
            if (!self.ring.tryPush(message)) {
                _ = self.dropped_full.fetchAdd(1, .monotonic);
                return error.Full;
            }
            _ = self.sent.fetchAdd(1, .monotonic);
            // Signal under the mutex: a consumer that already found the queue
            // empty is either about to wait (and will be woken) or still holds
            // the mutex (and will re-check before waiting).
            //
            // Uncancelable: the message is already in the ring and counted;
            // abandoning the signal here is a lost wake-up, not a skipped
            // bookkeeping update — a consumer parked in `recv(0)` stays parked
            // until some *later* send happens to signal it. Senders are the
            // handler path (`Handle.send`), i.e. cancelable tasks. There is no
            // error channel (`SendError` has no `Canceled`) and the critical
            // section is one signal. Red: `Mailbox: send signals even when the
            // sender's lock is canceled`.
            self.mu.lockUncancelable(self.io);
            self.not_empty.signal(self.io);
            self.mu.unlock(self.io);
        }

        /// Wait for room, then enqueue. `timeout_ms = 0` waits indefinitely.
        ///
        /// Spins briefly first: under load a slot usually frees within
        /// nanoseconds, and parking on a condition variable costs more than the
        /// message. Only the retries *inside* this call are uncounted — a
        /// message this returns successfully was never dropped, so it must not
        /// appear in `stats().dropped_full` (that counter means "a non-blocking
        /// `send` refused a message").
        pub fn sendBlocking(self: *Self, message: T, timeout_ms: u32) SendError!void {
            var spins: u32 = 0;
            while (true) {
                if (self.closed.load(.acquire)) return error.Closed;
                if (self.ring.tryPush(message)) {
                    _ = self.sent.fetchAdd(1, .monotonic);
                    // Uncancelable, for the same reason as `send`'s: the message
                    // is in the ring and the wake-up is not optional. Red:
                    // `Mailbox: sendBlocking signals even when the sender's lock
                    // is canceled`.
                    self.mu.lockUncancelable(self.io);
                    self.not_empty.signal(self.io);
                    self.mu.unlock(self.io);
                    return;
                }
                if (spins < spin_rounds) {
                    spins += 1;
                    std.atomic.spinLoopHint();
                    continue;
                }
                return self.sendWaiting(message, timeout_ms);
            }
        }

        fn sendWaiting(self: *Self, message: T, timeout_ms: u32) SendError!void {
            self.mu.lock(self.io) catch return error.Closed;
            defer self.mu.unlock(self.io);
            const deadline = if (timeout_ms == 0) null else blk: {
                const start = std.Io.Clock.Timestamp.now(self.io, .awake);
                break :blk start;
            };
            while (true) {
                if (self.closed.load(.acquire)) return error.Closed;
                if (self.ring.tryPush(message)) {
                    _ = self.sent.fetchAdd(1, .monotonic);
                    self.not_empty.signal(self.io);
                    return;
                }
                if (deadline) |start| {
                    const elapsed_ns = start.untilNow(self.io).raw.nanoseconds;
                    const budget_ns = @as(i96, timeout_ms) * std.time.ns_per_ms;
                    if (elapsed_ns >= budget_ns) return error.Timeout;
                    self.not_full.waitTimeout(self.io, &self.mu, .{
                        .duration = nanosDuration(budget_ns - elapsed_ns),
                    }) catch |err| switch (err) {
                        error.Timeout => return error.Timeout,
                        else => return error.Closed,
                    };
                } else {
                    self.not_full.wait(self.io, &self.mu) catch return error.Closed;
                }
            }
        }

        /// Non-blocking drain. Null when empty.
        pub fn tryRecv(self: *Self) ?T {
            const message = self.ring.tryPop() orelse return null;
            _ = self.received.fetchAdd(1, .monotonic);
            // Uncancelable: the slot this pop just freed is only reachable
            // through the signal, and a `sendBlocking(msg, 0)` producer parked on
            // `not_full` has no timeout to save it — the lost wake-up is
            // permanent. Red: `Mailbox: tryRecv signals not_full even when the
            // drainer's lock is canceled`.
            self.mu.lockUncancelable(self.io);
            self.not_full.signal(self.io);
            self.mu.unlock(self.io);
            return message;
        }

        /// Receive, spinning briefly then blocking. `timeout_ms = 0` waits until a
        /// message arrives or the mailbox is closed. Null means "no message"
        /// (timeout, or closed and drained) — check `isClosed()` to tell them
        /// apart when it matters.
        ///
        /// Never returns early for a `wake`: it snapshots the epoch on entry, so
        /// the plain receive path is exactly the path it always was.
        pub fn recv(self: *Self, timeout_ms: u32) ?T {
            return self.recvWakeable(timeout_ms, self.wakeEpoch());
        }

        /// The value to pass to `recvWakeable` so that a `wake` arriving *after
        /// this call* is noticed. A caller checks whatever it needs to check and
        /// then waits — and it must read this **before** that check, or a wake
        /// landing in between would be compared against a stale picture and lost.
        pub fn wakeEpoch(self: *const Self) u32 {
            return self.wake_epoch.load(.acquire);
        }

        /// Wake a parked `recvWakeable` without closing the mailbox: the receiver
        /// returns null at its next opportunity and its caller re-checks whatever
        /// it woke up for. A "spurious" wake by design — nothing is enqueued and
        /// nothing is consumed.
        ///
        /// Bumps the epoch *before* taking the mutex, so a receiver that is
        /// between "found the queue empty" and "parked" either sees the new epoch
        /// on its way in or is woken by the broadcast.
        pub fn wake(self: *Self) void {
            _ = self.wake_epoch.fetchAdd(1, .release);
            // Uncancelable: the epoch bump only helps a receiver that has not yet
            // read it. One that is *already parked* is reachable through the
            // broadcast alone, so a canceled lock here leaves a supervision
            // member waiting to rebuild itself with nothing left to wake it —
            // `wake`'s own doc calls out this window. Red: `Mailbox: wake
            // broadcasts even when the waker's lock is canceled`.
            self.mu.lockUncancelable(self.io);
            self.not_empty.broadcast(self.io);
            self.mu.unlock(self.io);
        }

        /// `recv` that also returns null once the wake epoch has moved past
        /// `wake_from`. Null is then ambiguous between "timeout", "closed" and
        /// "woken" — callers of this one are expected to re-check their own
        /// condition and come back, which is the whole point.
        pub fn recvWakeable(self: *Self, timeout_ms: u32, wake_from: u32) ?T {
            var spins: u32 = 0;
            while (spins < spin_rounds) : (spins += 1) {
                if (self.tryRecv()) |message| return message;
                if (self.closed.load(.acquire) and self.ring.isEmpty()) return null;
                if (self.wake_epoch.load(.acquire) != wake_from) return null;
                std.atomic.spinLoopHint();
            }
            _ = self.wait_spins.fetchAdd(1, .monotonic);

            self.mu.lock(self.io) catch return null;
            defer self.mu.unlock(self.io);
            const start = std.Io.Clock.Timestamp.now(self.io, .awake);
            while (true) {
                if (self.tryRecvUnlocked()) |message| return message;
                if (self.closed.load(.acquire)) return null; // drained by the check above
                if (self.wake_epoch.load(.acquire) != wake_from) return null;
                if (timeout_ms == 0) {
                    self.not_empty.wait(self.io, &self.mu) catch return null;
                    continue;
                }
                const elapsed_ns = start.untilNow(self.io).raw.nanoseconds;
                const budget_ns = @as(i96, timeout_ms) * std.time.ns_per_ms;
                if (elapsed_ns >= budget_ns) return null;
                self.not_empty.waitTimeout(self.io, &self.mu, .{
                    .duration = nanosDuration(budget_ns - elapsed_ns),
                }) catch |err| switch (err) {
                    error.Timeout => return null,
                    else => return null,
                };
            }
        }

        /// `tryRecv` for callers that already hold `mu`.
        fn tryRecvUnlocked(self: *Self) ?T {
            const message = self.ring.tryPop() orelse return null;
            _ = self.received.fetchAdd(1, .monotonic);
            self.not_full.signal(self.io);
            return message;
        }

        /// No further sends; wake every waiter. Messages already queued stay
        /// available until drained.
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
            // Uncancelable: `closed` is already published, so a canceled lock here
            // returns "closed" to every future caller while the receivers that
            // were parked *before* it never hear about it — `send` refuses
            // (error.Closed) and therefore cannot signal them either, so they
            // stay parked forever and a join behind them never returns. This is
            // the same shape `WorkerPool.signalShutdown` was changed to fix.
            // Red: `Mailbox: close broadcasts even when the closer's lock is
            // canceled`.
            self.mu.lockUncancelable(self.io);
            self.not_empty.broadcast(self.io);
            self.not_full.broadcast(self.io);
            self.mu.unlock(self.io);
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed.load(.acquire);
        }

        pub fn len(self: *const Self) usize {
            return self.ring.len();
        }

        /// Queue capacity (comptime `capacity` parameter, exposed for stats).
        pub fn maxMessages(self: *const Self) usize {
            _ = self;
            return capacity;
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .capacity = capacity,
                .len = self.ring.len(),
                .sent = self.sent.load(.monotonic),
                .received = self.received.load(.monotonic),
                .dropped_full = self.dropped_full.load(.monotonic),
                .blocked_receives = self.wait_spins.load(.monotonic),
                .high_water = self.ring.stats().high_water,
            };
        }

        pub const Stats = struct {
            capacity: usize,
            len: usize,
            sent: u64,
            received: u64,
            /// `send` calls that returned `error.Full`.
            dropped_full: u64,
            /// `recv` calls that had to park on the condition variable.
            blocked_receives: u64,
            high_water: usize,
        };
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "Mailbox: FIFO, bounded, and Full is reported without loss" {
    const M = Mailbox(u32, 2);
    var mb = M.init(std.testing.io);

    try mb.send(1);
    try mb.send(2);
    try std.testing.expectError(error.Full, mb.send(3));
    try std.testing.expectEqual(@as(u32, 1), mb.tryRecv().?); // refused send did not clobber
    try std.testing.expectEqual(@as(u32, 2), mb.tryRecv().?);
    try std.testing.expect(mb.tryRecv() == null);
    try std.testing.expectEqual(@as(u64, 1), mb.stats().dropped_full);
}

test "Mailbox: recv blocks until a producer sends" {
    const M = Mailbox(u32, 8);
    const Shared = struct {
        mb: *M,
        fn produce(m: *M) void {
            // Deliberately late: the consumer must park, not spin forever.
            var spins: usize = 0;
            while (spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
            m.send(99) catch unreachable;
        }
    };
    var mb = M.init(std.testing.io);
    const producer = try std.Thread.spawn(.{}, Shared.produce, .{&mb});

    const got = mb.recv(5_000);
    producer.join();
    try std.testing.expectEqual(@as(u32, 99), got.?);
    try std.testing.expect(mb.stats().blocked_receives >= 1); // it really did park
}

test "Mailbox: recv returns null on timeout" {
    const M = Mailbox(u32, 4);
    var mb = M.init(std.testing.io);
    const started = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    try std.testing.expect(mb.recv(30) == null);
    const elapsed = started.untilNow(std.testing.io).raw.nanoseconds;
    try std.testing.expect(elapsed >= 25 * std.time.ns_per_ms); // waited, did not return early
}

test "Mailbox: close wakes a blocked receiver and refuses further sends" {
    const M = Mailbox(u32, 8);
    const Shared = struct {
        result: ?u32 = null,
        fn consume(m: *M) void {
            _ = m; // hmm
        }
    };
    _ = Shared;
    var mb = M.init(std.testing.io);
    try std.testing.expect(!mb.isClosed());
    mb.close();
    try std.testing.expect(mb.isClosed());
    try std.testing.expect(mb.recv(50) == null); // closed and empty
    try std.testing.expectError(error.Closed, mb.send(1));

    // A message queued before close is still drained.
    var mb2 = M.init(std.testing.io);
    try mb2.send(7);
    mb2.close();
    try std.testing.expectEqual(@as(u32, 7), mb2.recv(50).?);
    try std.testing.expect(mb2.recv(50) == null);
}

test "Mailbox: close wakes a receiver parked on an empty queue" {
    const M = Mailbox(u32, 8);
    const Shared = struct {
        var result: ?u32 = null;
        fn consume(m: *M) void {
            result = m.recv(0); // blocks until close()
        }
    };
    var mb = M.init(std.testing.io);
    const consumer = try std.Thread.spawn(.{}, Shared.consume, .{&mb});

    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
    mb.close();
    consumer.join();
    try std.testing.expect(Shared.result == null); // woke up, found nothing, returned
    try std.testing.expect(mb.stats().blocked_receives >= 1);
}

test "Mailbox: sendBlocking waits for room instead of dropping" {
    // capacity 2: the producer needs one slot of headroom to block on.
    const M = Mailbox(u32, 2);
    var mb = M.init(std.testing.io);
    try mb.send(1);

    const Shared = struct {
        mb: *M,
        fn drain(m: *M) void {
            var spins: usize = 0;
            while (spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
            _ = m.recv(1_000);
        }
    };
    const consumer = try std.Thread.spawn(.{}, Shared.drain, .{&mb});

    try mb.sendBlocking(2, 5_000); // waits for the consumer, then succeeds
    consumer.join();
    try std.testing.expectEqual(@as(u64, 0), mb.stats().dropped_full);
    try std.testing.expectEqual(@as(u32, 2), mb.tryRecv().?);
}

test "Mailbox: many producers, one consumer, nothing lost" {
    const producers = 4;
    const per_producer = 5_000;
    const M = Mailbox(u64, 256);

    const Shared = struct {
        mb: *M,
        fn produce(m: *M, tag: u64) void {
            var i: u64 = 0;
            while (i < per_producer) : (i += 1) {
                m.sendBlocking((tag << 32) | i, 0) catch |err| switch (err) {
                    error.Full => continue,
                    else => unreachable,
                };
            }
        }
    };
    var mb = M.init(std.testing.io);
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Shared.produce, .{ &mb, @as(u64, i) });

    var seen: [producers]u64 = @splat(0);
    var total: usize = 0;
    while (total < producers * per_producer) {
        if (mb.recv(1_000)) |msg| {
            const tag: usize = @intCast(msg >> 32);
            try std.testing.expectEqual(seen[tag], msg & 0xffff_ffff);
            seen[tag] += 1;
            total += 1;
        }
    }
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(usize, producers * per_producer), total);
    try std.testing.expectEqual(@as(u64, 0), mb.stats().dropped_full);
}

test "Mailbox: wake is only visible to a receiver that was watching the old epoch" {
    var mb = Mailbox(u32, 4).init(std.testing.io);
    const before = mb.wakeEpoch();

    // A receiver already past the wake comes back empty-handed...
    mb.wake();
    const after = mb.wakeEpoch();
    try std.testing.expect(after != before);
    try std.testing.expectEqual(@as(?u32, null), mb.recvWakeable(0, before));

    // ...and a wake enqueues nothing, consumes nothing, and leaves no trace that
    // a later receiver could trip over — which is what lets `recv` snapshot the
    // epoch on entry and be the same blocking receive it always was.
    try std.testing.expectEqual(@as(usize, 0), mb.len());
    try std.testing.expectEqual(@as(u64, 0), mb.received.load(.acquire));
    try std.testing.expect(!mb.isClosed());
    try std.testing.expectEqual(before + 1, after);
}

// ── Canceled callers ────────────────────────────────────────────────
//
// The tests below all share one shape, and it is the only shape that can make
// `Mutex.lock` return `error.Canceled`: `Mutex.lock`'s fast path does not check
// for cancelation at all (it returns the moment the `cmpxchg` succeeds), so the
// error can only come from the *contended* path — a task that is parked waiting
// for the mutex when a cancel request lands on its thread. Hence: the test holds
// the mailbox's mutex, drives the call under test into that park, waits until it
// is really parked (`at_call` plus a sleep — there is no cheaper proof that a
// task is inside `futexWait`), and only then cancels.
//
// What each test has to prove is that the cancelation did *not* cost the wake-up.
// Two readings are used, in this order:
//
// * the condition's own `epoch`, which `signal`/`broadcast` bump only when there
//   is a waiter to wake — a deterministic, immediate answer to "did the signal
//   happen" (no timing, no spin);
// * the parked receiver itself (`woke`), which is the consequence that matters.

/// Iterations the "the receiver should have come back" spins are bounded by, so
/// a lost wake-up *fails* the suite instead of hanging it.
const wait_for_receiver_rounds = 200_000_000;

/// Park `m.recv`/`recvWakeable` on an empty queue and return once it is really
/// inside the condition variable (`not_empty.state.waiters` is the mailbox's own
/// count of receivers that reached it).
fn parkedReceiverSpins(comptime M: type, m: *M, rounds: u32) void {
    var spins: u32 = 0;
    while (spins < rounds) : (spins += 1) {
        if (m.not_empty.state.load(.monotonic).waiters > 0) return;
        std.atomic.spinLoopHint();
    }
    @panic("no receiver ever parked on not_empty");
}

test "Mailbox: close broadcasts even when the closer's lock is canceled" {
    const M = Mailbox(u32, 8);
    var mb = M.init(std.testing.io);
    const io = std.testing.io;

    const Shared = struct {
        var at_call = std.atomic.Value(bool).init(false);
        var woke = std.atomic.Value(bool).init(false);

        fn consume(m: *M) void {
            _ = m.recv(0); // no timeout: only a wake-up ends this
            woke.store(true, .release);
        }
        fn close(m: *M) void {
            at_call.store(true, .release);
            m.close();
        }
        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Shared.woke.store(false, .monotonic);
    Shared.at_call.store(false, .monotonic);

    const receiver = try std.Thread.spawn(.{}, Shared.consume, .{&mb});
    parkedReceiverSpins(M, &mb, wait_for_receiver_rounds);
    const broadcasts_before = mb.not_empty.epoch.load(.acquire);

    // Hold the mutex: the canceled `close` below can only lose its broadcast if
    // its `lock` is the contended one.
    try mb.mu.lock(io);
    var close_fut = try io.concurrent(Shared.close, .{&mb});
    while (!Shared.at_call.load(.acquire)) std.atomic.spinLoopHint();
    var cancel_fut = try io.concurrent(Shared.cancel, .{ io, &close_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    mb.mu.unlock(io);

    cancel_fut.await(io);
    close_fut.await(io);

    const broadcasts_after = mb.not_empty.epoch.load(.acquire);
    var after: u32 = 0;
    while (!Shared.woke.load(.acquire) and after < wait_for_receiver_rounds) : (after += 1) std.atomic.spinLoopHint();
    const woke = Shared.woke.load(.acquire);
    // Release a receiver a lost broadcast left parked, so the join cannot hang
    // and the failure this test reports is the assertion, not the teardown.
    if (!woke) mb.wake();
    receiver.join();

    try std.testing.expect(mb.isClosed());
    try std.testing.expectEqual(broadcasts_before + 1, broadcasts_after);
    try std.testing.expect(woke);
}

test "Mailbox: send signals even when the sender's lock is canceled" {
    try sendSignalsUnderCancelation(false);
}

test "Mailbox: sendBlocking signals even when the sender's lock is canceled" {
    try sendSignalsUnderCancelation(true);
}

fn sendSignalsUnderCancelation(comptime blocking: bool) !void {
    const M = Mailbox(u32, 8);
    var mb = M.init(std.testing.io);
    const io = std.testing.io;

    const Shared = struct {
        var at_call = std.atomic.Value(bool).init(false);
        var woke = std.atomic.Value(bool).init(false);

        fn consume(m: *M) void {
            _ = m.recv(0);
            woke.store(true, .release);
        }
        fn send(m: *M, mode_blocking: bool) void {
            at_call.store(true, .release);
            // The message is enqueued *before* the lock either way; that is what
            // makes a lost signal a lost wake-up rather than a lost message.
            if (mode_blocking) {
                // `error.Closed` only after this test's own cleanup has closed
                // the mailbox; the other two cannot happen with an empty 8-slot
                // queue.
                m.sendBlocking(7, 1_000) catch |err| switch (err) {
                    error.Closed => {},
                    error.Full, error.Timeout => unreachable,
                };
            } else {
                m.send(7) catch |err| switch (err) {
                    error.Closed => {},
                    error.Full => unreachable,
                    error.Timeout => unreachable, // `send` never waits
                };
            }
        }
        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Shared.woke.store(false, .monotonic);
    Shared.at_call.store(false, .monotonic);

    const receiver = try std.Thread.spawn(.{}, Shared.consume, .{&mb});
    parkedReceiverSpins(M, &mb, wait_for_receiver_rounds);
    const signals_before = mb.not_empty.epoch.load(.acquire);

    try mb.mu.lock(io);
    var send_fut = try io.concurrent(Shared.send, .{ &mb, blocking });
    while (!Shared.at_call.load(.acquire)) std.atomic.spinLoopHint();
    var cancel_fut = try io.concurrent(Shared.cancel, .{ io, &send_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    mb.mu.unlock(io);

    cancel_fut.await(io);
    send_fut.await(io);

    const signals_after = mb.not_empty.epoch.load(.acquire);
    var after: u32 = 0;
    while (!Shared.woke.load(.acquire) and after < wait_for_receiver_rounds) : (after += 1) std.atomic.spinLoopHint();
    const woke = Shared.woke.load(.acquire);
    const left_queued = mb.len();
    if (!woke) mb.wake(); // delivers the message to the parked receiver
    receiver.join();

    // Enqueued either way — the acceptance is not what a canceled lock costs.
    try std.testing.expectEqual(@as(u64, 1), mb.stats().sent);
    try std.testing.expectEqual(signals_before + 1, signals_after);
    try std.testing.expect(woke);
    try std.testing.expectEqual(@as(usize, 0), left_queued);
}

test "Mailbox: tryRecv signals not_full even when the drainer's lock is canceled" {
    // capacity 2, both slots taken: the producer below has nowhere to go and
    // parks on `not_full` with no timeout, so the slot `tryRecv` frees is only
    // usable again if its signal survives.
    const M = Mailbox(u32, 2);
    var mb = M.init(std.testing.io);
    const io = std.testing.io;
    try mb.send(1);
    try mb.send(2);

    const Shared = struct {
        var at_call = std.atomic.Value(bool).init(false);

        fn produce(m: *M) void {
            // Frees the slot the canceled `tryRecv` hands back; `error.Closed`
            // is this test's own cleanup.
            m.sendBlocking(3, 0) catch |err| switch (err) {
                error.Closed => {},
                error.Full, error.Timeout => unreachable,
            };
        }
        fn drain(m: *M) void {
            at_call.store(true, .release);
            _ = m.tryRecv();
        }
        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Shared.at_call.store(false, .monotonic);

    const producer = try std.Thread.spawn(.{}, Shared.produce, .{&mb});
    var spins: u32 = 0;
    while (mb.not_full.state.load(.monotonic).waiters == 0 and spins < wait_for_receiver_rounds) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expect(mb.not_full.state.load(.monotonic).waiters > 0);

    try mb.mu.lock(io);
    var drain_fut = try io.concurrent(Shared.drain, .{&mb});
    while (!Shared.at_call.load(.acquire)) std.atomic.spinLoopHint();
    var cancel_fut = try io.concurrent(Shared.cancel, .{ io, &drain_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    mb.mu.unlock(io);

    cancel_fut.await(io);
    drain_fut.await(io);

    var after: u32 = 0;
    while (mb.stats().sent < 3 and after < wait_for_receiver_rounds) : (after += 1) std.atomic.spinLoopHint();
    const sent = mb.stats().sent;
    const left = mb.len();
    // Free a producer a lost signal left parked forever (`timeout_ms = 0`), and
    // let its `error.Closed` land in the `catch |err|` above.
    mb.close();
    producer.join();

    try std.testing.expectEqual(@as(u64, 3), sent); // the space was handed back
    try std.testing.expectEqual(@as(usize, 2), left);
}

test "Mailbox: wake broadcasts even when the waker's lock is canceled" {
    // `wake`'s own doc warns about exactly this window: the epoch is bumped
    // before the lock, so a receiver that is *already parked* is only reachable
    // through the broadcast.
    const M = Mailbox(u32, 4);
    var mb = M.init(std.testing.io);
    const io = std.testing.io;
    const epoch = mb.wakeEpoch();

    const Shared = struct {
        var at_call = std.atomic.Value(bool).init(false);
        var woke = std.atomic.Value(bool).init(false);

        fn receive(m: *M, watching: u32) void {
            _ = m.recvWakeable(0, watching); // nothing enqueues: only the wake ends this
            woke.store(true, .release);
        }
        fn wake(m: *M) void {
            at_call.store(true, .release);
            m.wake();
        }
        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Shared.woke.store(false, .monotonic);
    Shared.at_call.store(false, .monotonic);

    const receiver = try std.Thread.spawn(.{}, Shared.receive, .{ &mb, epoch });
    parkedReceiverSpins(M, &mb, wait_for_receiver_rounds);

    try mb.mu.lock(io);
    var wake_fut = try io.concurrent(Shared.wake, .{&mb});
    while (!Shared.at_call.load(.acquire)) std.atomic.spinLoopHint();
    var cancel_fut = try io.concurrent(Shared.cancel, .{ io, &wake_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);
    mb.mu.unlock(io);

    cancel_fut.await(io);
    wake_fut.await(io);

    try std.testing.expect(mb.wakeEpoch() != epoch); // the bump is the pre-lock half
    var after: u32 = 0;
    while (!Shared.woke.load(.acquire) and after < wait_for_receiver_rounds) : (after += 1) std.atomic.spinLoopHint();
    const woke = Shared.woke.load(.acquire);
    if (!woke) mb.wake(); // the second broadcast is what frees a receiver the first missed
    receiver.join();

    try std.testing.expect(woke);
}

test "Mailbox: wake unparks a receiver that had already blocked" {
    var mb = Mailbox(u32, 4).init(std.testing.io);
    const epoch = mb.wakeEpoch();
    var woke = std.atomic.Value(bool).init(false);

    const Shared = struct {
        fn receive(m: *Mailbox(u32, 4), watching: u32, flag: *std.atomic.Value(bool)) void {
            // There is no message coming: the only way this returns is the wake.
            _ = m.recvWakeable(0, watching);
            flag.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, Shared.receive, .{ &mb, epoch, &woke });

    // Wait for the receiver to be *parked*, not merely started. `wait_spins` is
    // the mailbox's own count of receivers that had to take the condition
    // variable — the state under test, rather than elapsed time.
    var spins: u32 = 0;
    while (mb.wait_spins.load(.acquire) == 0 and spins < 500_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expect(mb.wait_spins.load(.acquire) > 0);

    mb.wake();
    // Bounded: a lost wake must *fail*, not hang the suite.
    var after: u32 = 0;
    while (!woke.load(.acquire) and after < 500_000_000) : (after += 1) std.atomic.spinLoopHint();
    try std.testing.expect(woke.load(.acquire));
    t.join();

    // Woken, not fed: the wake delivered nothing and the mailbox is still open.
    try std.testing.expectEqual(@as(usize, 0), mb.len());
    try std.testing.expectEqual(@as(u64, 0), mb.received.load(.acquire));
    try std.testing.expect(!mb.isClosed());
}
