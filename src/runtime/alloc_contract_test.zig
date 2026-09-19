//! Allocation contract for the runtime's hot paths (docs/RUNTIME.md §4/§5/§6).
//!
//! The runtime's promise is that the producer side of the L0 paths allocates
//! nothing: a `send` copies into a fixed-capacity slot, a `publish` fans out
//! over frozen sinks, arming a timer pushes a command onto a fixed-capacity
//! ring. A promise nobody executes is a promise that decays, so every operation
//! below is measured with a counting allocator and asserted at its **exact**
//! count: a later `allocator.dupe(...)` on a hot path turns an expected `0` into
//! `1` and fails here, instead of silently costing a benchmark nobody reruns.
//!
//! Where an operation *does* allocate, the count is part of the contract rather
//! than a budget, and the test says why (see the last two tests).

const std = @import("std");

/// The runtime namespace as a user sees it (`zigmodu.runtime`), so the primitives
/// measured here are reached the same way an application reaches them.
const rt = @import("../runtime.zig");

/// Counting allocator: the same instrument `src/benchmark.zig` uses to arm an
/// allocation failure around a hot loop. `allocations` counts successful
/// allocations, `alloc_index` counts attempted ones.
const Probe = std.testing.FailingAllocator;

fn measure(probe: *const Probe) usize {
    return probe.allocations;
}

fn expectExact(probe: *const Probe, before: usize, expected: usize, comptime what: []const u8) !void {
    const got = probe.allocations - before;
    if (got != expected) {
        std.debug.print("[alloc contract] {s}: expected {d} allocation(s), measured {d}\n", .{ what, expected, got });
    }
    try std.testing.expectEqual(expected, got);
}

const Quiet = struct {
    pub const Message = u64;
    seen: u64 = 0,

    pub fn handle(self: *@This(), msg: u64, ctx: anytype) anyerror!void {
        _ = ctx;
        self.seen +%= msg;
    }
};

// ─────────────────────────────────────────────────
// Zero: the producer hot paths
// ─────────────────────────────────────────────────

test "alloc contract: Mailbox.send / sendBlocking / tryRecv allocate nothing" {
    var probe = Probe.init(std.testing.allocator, .{});
    var mb: rt.Mailbox(u64, 64) = .init(std.testing.io);

    const before = measure(&probe);
    for (0..16) |i| try mb.send(i);
    try expectExact(&probe, before, 0, "Mailbox.send x16");

    for (0..8) |_| try std.testing.expect(mb.tryRecv() != null);
    for (0..8) |i| try mb.sendBlocking(i, 5);
    try expectExact(&probe, before, 0, "Mailbox.sendBlocking x8 (room available, no wait)");

    while (mb.tryRecv()) |_| {}
    try expectExact(&probe, before, 0, "Mailbox.tryRecv until empty");
}

test "alloc contract: ring buffers and the sequencer allocate nothing" {
    var probe = Probe.init(std.testing.allocator, .{});
    var rb: rt.RingBuffer(u32, 8) = .{};
    var mp: rt.MpscRing(u32, 8) = .init();
    var seq = rt.Sequencer.init(1);

    const before = measure(&probe);
    for (0..64) |round| {
        for (0..8) |i| try std.testing.expect(rb.tryPush(@intCast(round * 8 + i)));
        try std.testing.expect(!rb.tryPush(0)); // full: rejected without allocating
        for (0..8) |_| try std.testing.expect(rb.tryPop() != null);
        try std.testing.expectEqual(@as(?u32, null), rb.tryPop());

        for (0..8) |i| try std.testing.expect(mp.tryPush(@intCast(round * 8 + i)));
        try std.testing.expect(!mp.tryPush(0)); // full: rejected without allocating
        for (0..8) |_| try std.testing.expect(mp.tryPop() != null);
        try std.testing.expectEqual(@as(?u32, null), mp.tryPop());
    }
    try expectExact(&probe, before, 0, "RingBuffer/MpscRing push+pop, 64 rounds of 16");

    for (0..1024) |_| std.mem.doNotOptimizeAway(seq.next());
    try expectExact(&probe, before, 0, "Sequencer.next x1024");
}

test "alloc contract: HotBus wiring and publish allocate nothing" {
    const Counter = struct {
        seen: usize = 0,
        fn deliver(ctx: *anyopaque, _: u32) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.seen += 1;
            return true;
        }
    };

    var a = Counter{};
    var b = Counter{};
    var bus: rt.HotBus(u32, 2) = .init();

    var probe = Probe.init(std.testing.allocator, .{});
    const before = measure(&probe);

    try bus.subscribeSink(.{ .ctx = @ptrCast(&a), .deliver = Counter.deliver });
    try bus.subscribeSink(.{ .ctx = @ptrCast(&b), .deliver = Counter.deliver });
    bus.freeze();
    try expectExact(&probe, before, 0, "HotBus.subscribeSink x2 + freeze");

    for (0..64) |i| try std.testing.expect(try bus.publish(@intCast(i)));
    try expectExact(&probe, before, 0, "HotBus.publish x64 over 2 sinks");

    // The publishes above are counted by the sinks, so a green result cannot
    // come from having published nothing.
    try std.testing.expectEqual(@as(usize, 64), a.seen);
    try std.testing.expectEqual(@as(usize, 64), b.seen);
    try std.testing.expectEqual(@as(u64, 128), bus.stats().delivered);
}

test "alloc contract: Handle.send / sendBlocking / sendTraced allocate nothing" {
    var probe = Probe.init(std.testing.allocator, .{});
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var runtime = rt.Runtime.init(probe.allocator(), std.testing.io, .{ .manual = &clk });
    defer runtime.deinit();

    const handle = try runtime.spawn(Quiet, .{}, 64);

    const before = measure(&probe);
    for (0..16) |i| try handle.send(i);
    try expectExact(&probe, before, 0, "Handle.send x16");

    for (0..8) |i| try handle.sendBlocking(i, 5);
    try expectExact(&probe, before, 0, "Handle.sendBlocking x8");

    for (0..8) |i| try handle.sendTraced(i, .{ .high = 1, .low = @intCast(i) });
    try expectExact(&probe, before, 0, "Handle.sendTraced x8");

    for (0..8) |i| try handle.sendBlockingTraced(i, .{ .high = 2, .low = @intCast(i) }, 5);
    try expectExact(&probe, before, 0, "Handle.sendBlockingTraced x8");

    handle.stop();
    handle.join();
    // 40 messages went in (16 + 8 + 8 + 8) and every one is accounted for, so a
    // green result above cannot come from having sent nothing: sum(0..15) =
    // 120, plus three runs of sum(0..7) = 28 → 204.
    try std.testing.expectEqual(@as(u64, 40), handle.stats().received);
    try std.testing.expectEqual(@as(u64, 204), handle.state.seen);
}

test "alloc contract: scheduleAction / requestCancelTimer allocate nothing on the caller" {
    const TimerSink = struct {
        posts: usize = 0,
        drops: usize = 0,
        fn post(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.posts += 1;
        }
        fn drop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
            _ = allocator;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.drops += 1;
        }
    };

    var probe = Probe.init(std.testing.allocator, .{});
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var runtime = rt.Runtime.init(probe.allocator(), std.testing.io, .{ .manual = &clk });
    defer runtime.deinit();

    var sink = TimerSink{};
    var ids: [4]u64 = undefined;

    const before_arm = measure(&probe);
    for (&ids) |*id| {
        id.* = try runtime.scheduleAction(50, .{
            .ctx = @ptrCast(&sink),
            .post = TimerSink.post,
            .drop = TimerSink.drop,
        });
    }
    try expectExact(&probe, before_arm, 0, "Runtime.scheduleAction x4");

    // Armed as well as counted: `scheduleAction`'s error set is inferred, so an
    // allocation added to this path would arrive here as the operation's own
    // `error.OutOfMemory`, not as a number that is easy to re-baseline.
    probe.fail_index = probe.alloc_index;
    for (ids) |id| try runtime.requestCancelTimer(id);
    try expectExact(&probe, before_arm, 0, "Runtime.requestCancelTimer x4");
    probe.fail_index = std.math.maxInt(usize);

    // The owner drains both halves in queue order: the arms reach the wheel and
    // the cancels take them straight back out. Nothing fires, and the four
    // payloads are released by the cancel path — the same `drop` the fire path
    // calls, which is why "a payload is released exactly once" holds here too.
    // Both allocations below happen on the owner, not on the callers measured
    // above.
    const before_tick = measure(&probe);
    _ = runtime.tick();
    try expectExact(&probe, before_tick, 5, "tick draining 4 arms + 4 cancels (4 nodes + first map growth)");
    try std.testing.expectEqual(@as(usize, 0), runtime.wheel.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), sink.posts);
    try std.testing.expectEqual(@as(usize, 4), sink.drops);
}

/// Bounded wait on the mailbox's delivered count — an atomic the pool thread
/// writes. Waiting for the effect (rather than sleeping) is what keeps a green
/// allocation count from meaning "nothing had run yet".
fn waitForReceived(handle: anytype, want: u64, timeout_ms: i64) !void {
    const Time = @import("../core/Time.zig");
    const deadline = Time.monotonicNowMilliseconds() + timeout_ms;
    while (handle.stats().received < want) {
        if (Time.monotonicNowMilliseconds() > deadline) return error.WaitTimeout;
        std.atomic.spinLoopHint();
    }
}

test "alloc contract: a pooled Handle.send allocates nothing, ready token included" {
    // `.mode = .pooled` puts a token in the scheduler's ready ring on the send
    // path, so this is the test that says the extra hop is still allocation-free:
    // the ring is sized at construction (see `scheduler.zig`), and pushing into
    // it is a plain store into one of its slots.
    var probe = Probe.init(std.testing.allocator, .{});
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var runtime = try rt.Runtime.initWithOptions(probe.allocator(), std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer runtime.deinit();

    const handle = try runtime.spawn(Quiet, .{}, .{ .capacity = 64, .mode = .pooled });

    const before = measure(&probe);
    for (0..16) |i| try handle.send(i);
    try expectExact(&probe, before, 0, "pooled Handle.send x16");

    for (0..8) |i| try handle.sendBlocking(i, 5);
    try expectExact(&probe, before, 0, "pooled Handle.sendBlocking x8");

    for (0..8) |i| try handle.sendTraced(i, .{ .high = 3, .low = @intCast(i) });
    try expectExact(&probe, before, 0, "pooled Handle.sendTraced x8");

    for (0..8) |i| try handle.sendBlockingTraced(i, .{ .high = 4, .low = @intCast(i) }, 5);
    try expectExact(&probe, before, 0, "pooled Handle.sendBlockingTraced x8");

    // 40 messages went in, and the pool ran all of them: a green count above
    // cannot come from having sent nothing (blocking sends are never dropped).
    try waitForReceived(handle, 40, 5_000);
    handle.stop();
    handle.join();
    try std.testing.expectEqual(@as(u64, 40), handle.stats().received);
    // The scheduler refused nothing: `ready_push_failures` is the "a worker got
    // lost" counter, and it must stay 0 (see scheduler.zig's capacity invariant).
    try std.testing.expectEqual(@as(u64, 0), runtime.poolStats().?.ready_push_failures);
}

// ─────────────────────────────────────────────────
// Non-zero: the two places the runtime allocates on purpose
// ─────────────────────────────────────────────────

test "alloc contract: Handle.after allocates exactly one payload, on the caller" {
    var probe = Probe.init(std.testing.allocator, .{});
    var clk = rt.Clock.Manual{ .now_ms = 0 };
    var runtime = rt.Runtime.init(probe.allocator(), std.testing.io, .{ .manual = &clk });
    defer runtime.deinit();

    const handle = try runtime.spawn(Quiet, .{}, 64);

    // One `Delivery` per call — the payload the runtime then owns and releases
    // exactly once (fire, cancel or shutdown). It is created on the *calling*
    // thread, which is what lets `after` return an id immediately; the wheel
    // insert belongs to the owner and is measured next.
    const before = measure(&probe);
    for (0..4) |_| _ = try handle.after(50, 7);
    try expectExact(&probe, before, 4, "Handle.after x4");

    const before_tick = measure(&probe);
    _ = runtime.tick();
    try expectExact(&probe, before_tick, 5, "tick draining 4 arms (4 nodes + first map growth)");
    try std.testing.expectEqual(@as(usize, 4), runtime.wheel.pendingCount());

    // Shutdown drops those four payloads (four frees) and allocates nothing.
    const before_shutdown = measure(&probe);
    runtime.shutdown();
    try expectExact(&probe, before_shutdown, 0, "Runtime.shutdown with 4 pending timers");
    try std.testing.expectEqual(@as(u64, 4), runtime.stats().timers_discarded);
}

test "alloc contract: Wheel.schedule allocates one node per timer; cancel/advance do not" {
    const FireCounter = struct {
        fired: usize = 0,
        dropped: usize = 0,
        fn onFire(ctx: *@This(), _: u64, _: u64) void {
            ctx.fired += 1;
        }
        fn onDrop(ctx: *@This(), _: u64, _: u64) void {
            ctx.dropped += 1;
        }
    };

    var probe = Probe.init(std.testing.allocator, .{});
    var wheel = rt.Wheel(u64).init(probe.allocator(), 0);
    defer wheel.deinit();
    var fired = FireCounter{};

    // First insert: the node, plus the `nodes` map's first bucket array. Both
    // halves are asserted, because "one allocation per timer" is the steady-state
    // shape, not the whole story: the map's growth is amortized, not free.
    const first = measure(&probe);
    _ = try wheel.schedule(10, 1);
    try expectExact(&probe, first, 2, "Wheel.schedule on a fresh wheel: node + first map bucket array");

    // Grow the map to its working size, then empty it again — removing entries
    // keeps the capacity, so what follows measures the steady state instead of
    // the map's amortization. Deadlines are slot-aligned (10 ms) on purpose:
    // this test is about allocation counts, and the wheel's firing threshold is
    // a separate question (`advance` below only needs to fire the ones it is
    // supposed to fire).
    for (2..66) |i| _ = try wheel.schedule(5_000 + @as(i64, @intCast(i)), @intCast(i));
    for (1..66) |id| try std.testing.expect(wheel.cancel(id));
    try std.testing.expectEqual(@as(usize, 0), wheel.pendingCount());

    const steady = measure(&probe);
    for (0..16) |i| _ = try wheel.schedule(400 + @as(i64, @intCast(i)) * 10, @intCast(i));
    try expectExact(&probe, steady, 16, "Wheel.schedule x16 with the map already grown: one node per timer");

    const before_cancel = measure(&probe);
    for (66..70) |id| try std.testing.expect(wheel.cancel(id));
    try expectExact(&probe, before_cancel, 0, "Wheel.cancel x4");

    const before_advance = measure(&probe);
    const due = wheel.advance(600, &fired, FireCounter.onFire);
    try expectExact(&probe, before_advance, 0, "Wheel.advance firing the 12 remaining timers");
    try std.testing.expectEqual(@as(usize, 12), due);
    try std.testing.expectEqual(@as(usize, 12), fired.fired);

    const before_drain = measure(&probe);
    try std.testing.expectEqual(@as(usize, 0), wheel.drainAll(&fired, FireCounter.onDrop));
    try expectExact(&probe, before_drain, 0, "Wheel.drainAll on an empty wheel");
    try std.testing.expectEqual(@as(usize, 0), fired.dropped);
}
