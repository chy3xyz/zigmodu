//! HotBus — the L0 publish/subscribe view: one producer, many worker mailboxes,
//! bounded and drop-on-full.
//!
//! `MpscRing`/`Mailbox` move messages to *one* consumer. A hot path usually has
//! several independent consumers of the same event (order book, risk, audit,
//! metrics) and cannot stop to fan out with allocation. `HotBus` is that fan-out:
//!
//! ```zig
//! var bus = HotBus(Trade, 8).init();
//! try bus.subscribe(book);     // *Handle(OrderBook, 256)
//! try bus.subscribe(risk);     // *Handle(Risk, 256)
//! bus.freeze();                // startup wiring done
//! if (!bus.publish(trade)) { /* every subscriber was full */ }
//! ```
//!
//! Two rules make it L0 rather than "an EventBus with a different name":
//!
//! 1. **Frozen before traffic.** Subscribers are wired during startup and then
//!    frozen, so `publish` reads a plain slice with no lock and no allocation.
//!    Publishing to an unfrozen bus is `error.NotFrozen` — a startup wiring bug
//!    that should fail loudly, not race.
//! 2. **Drop, never grow.** Each subscriber is a bounded mailbox; a full one is
//!    dropped for this event and counted. A slow consumer therefore cannot
//!    slow down the publisher, and cannot grow memory either.
//!
//! That last rule is the difference from `app.eventBus(T)`: the L1 bus is for
//! *business* events where "everyone eventually sees it" matters, so it is
//! allowed to allocate and to be slower. Use L0 where a missed event is
//! acceptable and a stalled publisher is not. See `docs/RUNTIME.md` §6.
//!
//! To replay a run later, attach a `Recorder` (default: off, one null check per
//! publish) with `attachRecorder` before `freeze()`. It is *not* a subscriber —
//! a sink would occupy a subscriber slot and a full log would be counted as a
//! dropped delivery while the event flowed on, which is exactly the "lost but
//! looks complete" log a replay must never have.
//!
//! Positioning: `HotBus` is a **user-facing** L0 primitive. The framework
//! itself has no internal consumer — deliberately. The in-framework hot paths
//! that exist today are all single-consumer or pull-based (runtime stats are
//! aggregated on demand by `Runtime.stats()`, `im.ConnectionRegistry` is a
//! point-to-point routing table, `AgentWorker.on_result` is one callback whose
//! `Done` borrows memory that is freed right after it returns). Wiring a
//! fan-out into any of them would manufacture a subscriber nobody needs and
//! change that path's semantics, so L0 fan-out stays an opt-in application
//! tool; `examples/runtime-workers` shows the intended use.

const std = @import("std");

pub const Error = error{
    /// `publish` before `freeze()` — wire subscribers during startup, then freeze.
    NotFrozen,
    /// `freeze()` was already called; the subscriber list is immutable.
    Frozen,
    /// More subscribers than the bus was sized for.
    TooManySubscribers,
    /// `subscribe` was given a handle whose message type is not this bus's event.
    TypeMismatch,
};

pub fn HotBus(comptime E: type, comptime max_subscribers: usize) type {
    if (max_subscribers < 1) @compileError("HotBus needs room for at least one subscriber");
    return struct {
        const Self = @This();

        pub const Sink = struct {
            ctx: *anyopaque,
            /// True when the subscriber accepted the event; false means "full or
            /// closed", which the bus counts as a drop.
            deliver: *const fn (ctx: *anyopaque, event: E) bool,
        };

        subscribers: [max_subscribers]Sink = undefined,
        count: usize = 0,
        frozen: bool = false,
        /// Opt-in delivery log. `null` (the default) means `publish` behaves
        /// exactly as it did before recorders existed — one null check.
        recorder_ctx: ?*anyopaque = null,
        recorder_record: ?*const fn (ctx: *anyopaque, event: E) bool = null,
        published: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        delivered: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        record_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        pub fn init() Self {
            return .{};
        }

        /// Subscribe a worker handle: every `E` the bus publishes is offered to
        /// its mailbox (and dropped if that mailbox is full).
        pub fn subscribe(self: *Self, handle: anytype) Error!void {
            const H = @TypeOf(handle.*);
            if (!@hasField(H, "mailbox")) @compileError("HotBus.subscribe expects a runtime worker handle (*Handle(W, cap))");
            const Msg = H.Message;
            if (Msg != E) @compileError("HotBus(" ++ @typeName(E) ++ ").subscribe got a handle of " ++ @typeName(Msg) ++
                " — the bus event type and the worker's Message must match");
            try self.subscribeSink(.{
                .ctx = @ptrCast(handle),
                .deliver = struct {
                    fn deliver(ctx: *anyopaque, event: E) bool {
                        const h: *H = @ptrCast(@alignCast(ctx));
                        h.send(event) catch return false;
                        return true;
                    }
                }.deliver,
            });
        }

        /// Subscribe anything that can take an event — for sinks that are not
        /// runtime workers (a metrics collector, a test recorder).
        pub fn subscribeSink(self: *Self, sink: Sink) Error!void {
            if (self.frozen) return Error.Frozen;
            if (self.count == max_subscribers) return Error.TooManySubscribers;
            self.subscribers[self.count] = sink;
            self.count += 1;
        }

        /// Freeze the wiring. After this, `publish` is lock-free and allocation-free.
        pub fn freeze(self: *Self) void {
            self.frozen = true;
        }

        pub fn isFrozen(self: *const Self) bool {
            return self.frozen;
        }

        /// Attach a `runtime.Recorder(E, capacity)` (see `recorder.zig`): every
        /// `publish` is then logged *before* the fan-out. Wire it during
        /// startup — after `freeze()` this is `error.Frozen`, because the
        /// wiring is fixed at that point exactly like the subscribers are.
        ///
        /// Why a record point and not a subscriber: a sink consumes one of the
        /// comptime subscriber slots, and a recorder too small for the traffic
        /// would come back as `deliver == false` — counted as a *drop*, with the
        /// event still flowing on. A log with a hole in it looks complete, which
        /// is the one failure a replay tool must not have. Recording here also
        /// logs the published stream itself, whatever the subscribers do with
        /// it, and costs a bus with no recorder nothing but one null check.
        pub fn attachRecorder(self: *Self, rec: anytype) Error!void {
            const R = @TypeOf(rec.*);
            if (!@hasDecl(R, "Event") or !@hasField(R, "clock"))
                @compileError("HotBus.attachRecorder expects a *runtime.Recorder(E, capacity) from src/runtime/recorder.zig");
            if (R.Event != E) @compileError("HotBus(" ++ @typeName(E) ++ ").attachRecorder got a Recorder for " ++ @typeName(R.Event) ++
                " — the bus event type and the recorder's must match");
            if (self.frozen) return Error.Frozen;
            self.recorder_ctx = @ptrCast(rec);
            self.recorder_record = struct {
                fn record(ctx: *anyopaque, event: E) bool {
                    const rec_ptr: *R = @ptrCast(@alignCast(ctx));
                    rec_ptr.record(event) catch return false;
                    return true;
                }
            }.record;
        }

        /// Whether a delivery log is attached (recording costs one null check
        /// and one `record` call per published event).
        pub fn hasRecorder(self: *const Self) bool {
            return self.recorder_ctx != null;
        }

        /// Offer `event` to every subscriber. Returns false when *nothing* was
        /// delivered (an idle-but-wired bus stays quiet: with zero subscribers
        /// this returns true) — or when an attached recorder refused the event,
        /// because a log that is no longer complete must not read as success.
        /// That refusal is counted in `stats().record_dropped`; the recorder's
        /// own `hasOverflowed()` stays true for the rest of its life.
        pub fn publish(self: *Self, event: E) Error!bool {
            if (!self.frozen) return Error.NotFrozen;
            _ = self.published.fetchAdd(1, .monotonic);

            // Before the fan-out, not as a subscriber: see `attachRecorder`.
            var recorded = true;
            if (self.recorder_ctx) |ctx| {
                recorded = self.recorder_record.?(ctx, event);
                if (!recorded) _ = self.record_dropped.fetchAdd(1, .monotonic);
            }

            var any_delivered = false;
            for (self.subscribers[0..self.count]) |sink| {
                if (sink.deliver(sink.ctx, event)) {
                    any_delivered = true;
                    _ = self.delivered.fetchAdd(1, .monotonic);
                } else {
                    _ = self.dropped.fetchAdd(1, .monotonic);
                }
            }
            return recorded and (any_delivered or self.count == 0);
        }

        pub fn subscriberCount(self: *const Self) usize {
            return self.count;
        }

        pub fn stats(self: *const Self) Stats {
            return .{
                .subscribers = self.count,
                .published = self.published.load(.monotonic),
                .delivered = self.delivered.load(.monotonic),
                .dropped = self.dropped.load(.monotonic),
                .record_dropped = self.record_dropped.load(.monotonic),
            };
        }

        pub const Stats = struct {
            subscribers: usize,
            /// `publish` calls.
            published: u64,
            /// Subscriber acceptances (one per subscriber per event).
            delivered: u64,
            /// Subscriber refusals (full or closed mailbox) — the backpressure
            /// signal this bus exists to make visible.
            dropped: u64,
            /// Events an attached recorder refused (its log was full). Never
            /// silent: the corresponding `publish` also returned false, and any
            /// non-zero value means the recording is incomplete.
            record_dropped: u64,
        };
    };
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const Collector = struct {
    received: std.ArrayList(u32) = .empty,
    accept: bool = true,

    fn sink(self: *@This()) HotBus(u32, 4).Sink {
        return .{
            .ctx = @ptrCast(self),
            .deliver = struct {
                fn deliver(ctx: *anyopaque, event: u32) bool {
                    const c: *Collector = @ptrCast(@alignCast(ctx));
                    if (!c.accept) return false;
                    c.received.append(std.testing.allocator, event) catch return false;
                    return true;
                }
            }.deliver,
        };
    }

    fn deinit(self: *@This()) void {
        self.received.deinit(std.testing.allocator);
    }
};

test "HotBus fans one event out to every subscriber in order" {
    var bus = HotBus(u32, 2).init();
    var a = Collector{};
    defer a.deinit();
    var b = Collector{};
    defer b.deinit();
    try bus.subscribeSink(a.sink());
    try bus.subscribeSink(b.sink());
    bus.freeze();

    for (1..4) |i| {
        try std.testing.expect(try bus.publish(@intCast(i)));
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, a.received.items);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, b.received.items);

    const s = bus.stats();
    try std.testing.expectEqual(@as(u64, 3), s.published);
    try std.testing.expectEqual(@as(u64, 6), s.delivered);
    try std.testing.expectEqual(@as(u64, 0), s.dropped);
}

test "HotBus drops what a full subscriber cannot take, and counts it" {
    var bus = HotBus(u32, 2).init();
    var ok = Collector{};
    defer ok.deinit();
    var full = Collector{ .accept = false };
    defer full.deinit();

    try bus.subscribeSink(ok.sink());
    try bus.subscribeSink(full.sink());
    bus.freeze();

    try std.testing.expect(try bus.publish(7)); // one accepted → still "delivered"
    const s = bus.stats();
    try std.testing.expectEqual(@as(u64, 1), s.delivered);
    try std.testing.expectEqual(@as(u64, 1), s.dropped); // the slow subscriber missed it
    try std.testing.expectEqualSlices(u32, &.{7}, ok.received.items);
    try std.testing.expectEqual(@as(usize, 0), full.received.items.len);
}

test "HotBus refuses a publish before freeze and a subscribe after it" {
    var bus = HotBus(u32, 2).init();
    try std.testing.expectError(Error.NotFrozen, bus.publish(1));

    var a = Collector{};
    defer a.deinit();
    try bus.subscribeSink(a.sink());
    bus.freeze();
    try std.testing.expectError(Error.Frozen, bus.subscribeSink(a.sink()));

    // A wired-but-empty bus is not an error: nothing to deliver, nothing dropped.
    var empty = HotBus(u32, 2).init();
    empty.freeze();
    try std.testing.expect(try empty.publish(1));
    try std.testing.expectEqual(@as(u64, 0), empty.stats().dropped);
}

test "HotBus enforces its subscriber capacity" {
    var bus = HotBus(u32, 1).init();
    var a = Collector{};
    defer a.deinit();
    try bus.subscribeSink(a.sink());
    try std.testing.expectError(Error.TooManySubscribers, bus.subscribeSink(a.sink()));
}

test "HotBus feeds real worker mailboxes and drops when one is full" {
    const runtime_impl = @import("runtime.zig");
    const clock_mod = @import("clock.zig");

    const Slow = struct {
        pub const Message = u32;
        seen: u32 = 0,
        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = self;
            _ = msg;
            _ = ctx;
            var spins: usize = 0;
            while (spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
        }
    };

    var clk = clock_mod.Clock.Manual{ .now_ms = 0 };
    var rt = runtime_impl.Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const slow = try rt.spawn(Slow, .{}, 2);
    var bus = HotBus(u32, 2).init();
    try bus.subscribe(slow);
    bus.freeze();

    // The subscriber's mailbox is 2 and its handler is slow: the bus must drop
    // rather than grow, and say so.
    for (0..200) |i| _ = try bus.publish(@intCast(i));
    const s = bus.stats();
    try std.testing.expect(s.dropped > 0);
    try std.testing.expect(s.delivered + s.dropped == 200);
    slow.stop();
}
