//! Runtime — the opt-in second lane: threads, mailboxes, timers and metrics
//! that live *beside* `Application`, not on top of it.
//!
//! ## Where this fits
//!
//! `Application` is the architecture unit: modules, DI, lifecycle, HTTP. The
//! runtime is the *execution* unit: a worker owns state, a mailbox owns the
//! hand-off, a timer wheel owns the delays. Both live in one process and share
//! the same `io`, config and observability — nothing about the module API
//! changes:
//!
//! ```zig
//! var b = zmodu.builder(allocator, io);          // bind first: a temporary is `*const`
//! defer b.deinit();
//! var app = try b.build(.{OrderModule});
//! try app.start();
//! const rt = app.runtime();                   // created on first use
//! const worker = try rt.spawn(OrderBook, .{ .symbol = "BTC/USDT" });
//! try worker.send(.{ .price = 101 });
//! ```
//!
//! ## Worker contracts
//!
//! A worker is a plain struct. Which of these it declares decides how the
//! runtime drives it — checked at comptime, no registration, no vtable on the
//! hot path:
//!
//! | declares | driven as | called |
//! |---|---|---|
//! | `pub const Message = T;` + `pub fn handle(self: *W, msg: T, ctx: anytype) anyerror!void` | message loop | once per message, until `stop()`/`close()` |
//! | `pub fn run(self: *W, ctx: anytype) anyerror!void` | loop-owned | once; the worker loops itself until `ctx.stopped()` |
//! | `pub fn init(self: *W, ctx: anytype) anyerror!void` (optional) | before either of the above | once |
//! | `pub fn deinit(self: *W) void` (optional) | after either of the above | once |
//!
//! `ctx` is a `WorkerContext(W, capacity)` value — passed as `anytype` so a
//! worker never has to name the mailbox capacity. It exposes `runtime`, `io`,
//! `allocator`, `name`, `handle` (the typed handle, for self-sends and timers),
//! `clock()`, `stopped()` and `schedule()`.
//!
//! ## Bounded by construction
//!
//! Every mailbox has a comptime capacity, so a slow worker turns into
//! `error.Full` at the *producer* — visible backpressure — instead of unbounded
//! memory growth. `sendBlocking` trades the drop for latency when the producer
//! prefers waiting.
//!
//! ## Lifecycle
//!
//! `Runtime.shutdown()` (and `Application.stop()`) requests every worker to stop,
//! closes its mailbox so a blocked `recv` wakes, then joins. Workers that never
//! return still block shutdown: that is deliberate — a runtime that silently
//! abandons threads hides the bug.

const std = @import("std");
const mbox = @import("mailbox.zig");
const wheel_mod = @import("timer_wheel.zig");
const clock_mod = @import("clock.zig");

pub const Clock = clock_mod.Clock;
pub const Wheel = wheel_mod.Wheel;
pub const Mailbox = mbox.Mailbox;

/// Deferred work handed to the timer wheel. Type-erased so one wheel serves
/// workers with different message types; the runtime owns `ctx` (it drops it on
/// fire *and* on cancel — see `cancelTimer`).
const TimerAction = struct {
    ctx: *anyopaque,
    post: *const fn (ctx: *anyopaque) void,
    drop: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
    /// When this action was due, so firing can measure how late it is —
    /// `timer_lag_max_ms` is the metric that says whether the ticker is keeping
    /// up, and it has to come from somewhere. `scheduleAction` fills it in; a
    /// caller-built action leaves it 0.
    deadline_ms: i64 = 0,
};

/// How the runtime reacts to an error a worker's `handle`/`run` returned.
///
/// A plain worker (v0.16 behaviour) logs and carries on. An **actor** declares
/// intent instead: fail-fast, or tolerate a bounded number of errors inside a
/// window and then stop for good — the classic supervision "intensity", which
/// exists because an actor that errors on *every* message otherwise burns a core
/// forever while looking alive.
pub const Supervision = struct {
    pub const Strategy = enum {
        /// Log the error, keep serving. The v0.16 worker contract.
        restart,
        /// Stop the actor on this error (fail fast, mailboxes close, thread exits).
        stop,
    };

    strategy: Strategy = .restart,
    /// Errors tolerated inside `window_ms` before the actor is stopped anyway.
    /// 0 = unlimited (plain-worker behaviour: never stop on errors).
    max_errors: u32 = 0,
    window_ms: i64 = 10_000,
};

pub const WorkerStats = struct {
    name: []const u8,
    running: bool,
    mailbox_capacity: usize,
    mailbox_len: usize,
    sent: u64,
    received: u64,
    dropped_full: u64,
    /// Panics inside `handle`/`run` do not reach here (they abort the process);
    /// this counts returned errors.
    handler_errors: u64,
    /// Errors inside the current supervision window.
    errors_in_window: u32,
    /// True when the supervisor stopped this actor (fail-fast or over budget).
    stopped_by_supervisor: bool,
};

pub const RuntimeStats = struct {
    workers: usize,
    running: usize,
    messages_sent: u64,
    messages_received: u64,
    messages_dropped: u64,
    handler_errors: u64,
    timer_fires: u64,
    /// Worst lateness observed between a timer's deadline and its firing.
    timer_lag_max_ms: i64,
};

/// A runtime-owned worker. `*Handle(W, capacity)` is what `spawn` returns; the
/// type-erased `WorkerHandle` view is what the runtime keeps for shutdown.
pub fn Handle(comptime W: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        pub const Message = if (@hasDecl(W, "Message")) W.Message else void;
        const MailboxType = mbox.Mailbox(Message, capacity);

        /// The worker's own values, moved in at `spawn`.
        state: W,
        mailbox: MailboxType,
        runtime: *Runtime,
        context: WorkerContext(W, capacity),
        thread: ?std.Thread = null,
        stop_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        handler_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        supervision: Supervision = .{},
        /// Supervisor bookkeeping. Owned by the worker's own thread (only it
        /// handles messages), so plain fields — no atomics.
        errors_in_window: u32 = 0,
        window_start_ms: i64 = 0,
        stopped_by_supervisor: bool = false,
        joined: bool = false,

        pub fn send(self: *Self, message: Message) mbox.SendError!void {
            return self.mailbox.send(message);
        }

        pub fn sendBlocking(self: *Self, message: Message, timeout_ms: u32) mbox.SendError!void {
            return self.mailbox.sendBlocking(message, timeout_ms);
        }

        /// Ask the worker to finish: its mailbox stops accepting and a blocked
        /// `recv` wakes up. The thread is joined by `Runtime.shutdown()` (or
        /// `join()`), never by `stop()` — callers must be able to decide how long
        /// to wait.
        pub fn stop(self: *Self) void {
            self.stop_requested.store(true, .release);
            self.mailbox.close();
        }

        /// Deliver `message` to this worker after `delay_ms`, via the runtime's
        /// timer wheel (one wheel for the whole runtime, O(1) insert).
        pub fn after(self: *Self, delay_ms: i64, message: Message) !wheel_mod.Wheel(TimerAction).Id {
            const Delivery = struct {
                handle: *Self,
                message: Message,
                fn post(ctx: *anyopaque) void {
                    const d: *@This() = @ptrCast(@alignCast(ctx));
                    // A timer must not be able to stall the ticker, so a full or
                    // closed mailbox drops the message. Surfaced at debug: under
                    // sustained backpressure this is the line that tells you the
                    // timer fired but its worker never saw it.
                    d.handle.send(d.message) catch |err| std.log.debug(
                        "[runtime] timer delivery to {s} dropped: {s}",
                        .{ d.handle.context.name, @errorName(err) },
                    );
                }
                fn drop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                    const d: *@This() = @ptrCast(@alignCast(ctx));
                    allocator.destroy(d);
                }
            };
            const delivery = try self.runtime.allocator.create(Delivery);
            delivery.* = .{ .handle = self, .message = message };
            return self.runtime.scheduleAction(delay_ms, .{
                .ctx = @ptrCast(delivery),
                .post = Delivery.post,
                .drop = Delivery.drop,
            });
        }

        pub fn stats(self: *Self) WorkerStats {
            const ms = self.mailbox.stats();
            return .{
                .name = self.context.name,
                .running = self.thread != null and !self.joined,
                .mailbox_capacity = capacity,
                .mailbox_len = ms.len,
                .sent = ms.sent,
                .received = ms.received,
                .dropped_full = ms.dropped_full,
                .handler_errors = self.handler_errors.load(.monotonic),
                .errors_in_window = self.errors_in_window,
                .stopped_by_supervisor = self.stopped_by_supervisor,
            };
        }

        pub fn join(self: *Self) void {
            if (self.joined) return;
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
            self.joined = true;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.join();
            allocator.destroy(self);
        }
    };
}

/// Passed to `init` / `handle` / `run` as `anytype`. Carries everything a worker
/// needs to cooperate with the runtime without naming its mailbox capacity.
pub fn WorkerContext(comptime W: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();
        runtime: *Runtime,
        io: std.Io,
        allocator: std.mem.Allocator,
        name: []const u8,
        handle: *Handle(W, capacity),

        pub fn clock(self: *Self) Clock {
            return self.runtime.clock;
        }

        /// True once `stop()` was called or the runtime is shutting down.
        pub fn stopped(self: *Self) bool {
            return self.handle.stop_requested.load(.acquire) or !self.runtime.alive.load(.acquire);
        }

        // Deferring work is `ctx.handle.after(delay_ms, message)` — the timer
        // posts a *message*, so the work runs on this worker's thread. A raw
        // callback would run on the ticker thread and violate the worker's
        // single-threaded state ownership.
    };
}

pub const Runtime = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    clock: Clock,
    wheel: Wheel(TimerAction),
    /// One entry per spawned worker (type-erased), plus its destroy thunk.
    workers: std.ArrayList(Entry) = .empty,
    /// The runtime is *alive* from construction until `shutdown`. Deliberately
    /// not the same thing as "the ticker is running": driving timers yourself
    /// (`tick()` + a Manual clock, or an event loop you already own) is a
    /// supported configuration, and a worker must not treat it as a shutdown
    /// signal.
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    ticker_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mu: std.Io.Mutex = .init,
    idle: std.Io.Condition = .init,
    ticker: ?std.Thread = null,
    timer_fires: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timer_lag_max_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    const Entry = struct {
        ptr: *anyopaque,
        name: []const u8,
        request_stop: *const fn (*anyopaque) void,
        join: *const fn (*anyopaque) void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
        stats: *const fn (*anyopaque) WorkerStats,
    };

    /// How often the ticker wakes to fire timers. One level-0 spoke is 10 ms;
    /// ticking at half that keeps a 10 ms timer within ~5 ms of its deadline.
    pub const tick_interval_ms: u32 = 5;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, clock: Clock) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            .wheel = Wheel(TimerAction).init(allocator, clock.nowMs()),
        };
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.wheel.deinit();
        self.workers.deinit(self.allocator);
        self.* = undefined;
    }

    /// Start the ticker so timers fire without help. Optional: a caller that
    /// drives `tick()` itself (tests, an event loop that already has a clock)
    /// should not start it.
    pub fn start(self: *Self) !void {
        if (self.ticker_running.swap(true, .acquire)) return; // already started
        self.wheel.now_ms = self.clock.nowMs();
        self.ticker = try std.Thread.spawn(.{}, tickerMain, .{self});
    }

    /// Stop every worker (request + join), then the ticker. Idempotent.
    pub fn shutdown(self: *Self) void {
        self.alive.store(false, .release);
        // Ask first, join after: a worker that is waiting on another worker's
        // message gets its stop signal before anyone blocks on a join.
        for (self.workers.items) |entry| entry.request_stop(entry.ptr);
        for (self.workers.items) |entry| entry.join(entry.ptr);
        for (self.workers.items) |entry| entry.destroy(entry.ptr, self.allocator);
        self.workers.clearRetainingCapacity();

        if (self.ticker_running.swap(false, .acquire)) {
            self.mu.lock(self.io) catch return;
            self.idle.broadcast(self.io);
            self.mu.unlock(self.io);
            if (self.ticker) |t| {
                t.join();
                self.ticker = null;
            }
        }
    }

    /// Spawn `W` with `capacity` mailbox slots. `init` is the worker's initial
    /// state, moved onto the heap (the thread must not see a stack copy).
    pub fn spawn(
        self: *Self,
        comptime W: type,
        initial_state: W,
        comptime capacity: usize,
    ) !*Handle(W, capacity) {
        return self.spawnSupervised(W, initial_state, capacity, .{});
    }

    /// Spawn an **actor**: same contract as a worker, but the runtime supervises
    /// it — a bounded error budget inside a window, and a stop when the budget is
    /// spent. Defaults differ from `spawn` on purpose: an actor that keeps
    /// failing is stopped rather than left burning a core.
    pub fn spawnActor(
        self: *Self,
        comptime W: type,
        initial_state: W,
        comptime capacity: usize,
        supervision: Supervision,
    ) !*Handle(W, capacity) {
        return self.spawnSupervised(W, initial_state, capacity, supervision);
    }

    pub fn spawnSupervised(
        self: *Self,
        comptime W: type,
        initial_state: W,
        comptime capacity: usize,
        supervision: Supervision,
    ) !*Handle(W, capacity) {
        const H = Handle(W, capacity);
        const handle = try self.allocator.create(H);
        errdefer self.allocator.destroy(handle);

        handle.* = .{
            .state = initial_state,
            .mailbox = mbox.Mailbox(H.Message, capacity).init(self.io),
            .runtime = self,
            .context = undefined,
            .supervision = supervision,
            .window_start_ms = self.clock.nowMs(),
        };
        handle.context = .{
            .runtime = self,
            .io = self.io,
            .allocator = self.allocator,
            .name = @typeName(W),
            .handle = handle,
        };

        try self.workers.append(self.allocator, .{
            .ptr = @ptrCast(handle),
            .name = @typeName(W),
            .request_stop = struct {
                fn f(p: *anyopaque) void {
                    const h: *H = @ptrCast(@alignCast(p));
                    h.stop();
                }
            }.f,
            .join = struct {
                fn f(p: *anyopaque) void {
                    const h: *H = @ptrCast(@alignCast(p));
                    h.join();
                }
            }.f,
            .destroy = struct {
                fn f(p: *anyopaque, allocator: std.mem.Allocator) void {
                    const h: *H = @ptrCast(@alignCast(p));
                    h.deinit(allocator);
                }
            }.f,
            .stats = struct {
                fn f(p: *anyopaque) WorkerStats {
                    const h: *H = @ptrCast(@alignCast(p));
                    return h.stats();
                }
            }.f,
        });

        handle.thread = std.Thread.spawn(.{}, workerMain(W, capacity), .{handle}) catch |err| {
            _ = self.workers.pop();
            self.allocator.destroy(handle);
            return err;
        };
        return handle;
    }

    /// Schedule a raw deferred action (used by `Handle.after`). Prefer
    /// `handle.after(...)`: a callback here runs on the **ticker thread**, so
    /// anything non-trivial must be handed off by message.
    pub fn scheduleAction(self: *Self, delay_ms: i64, action_in: TimerAction) !u64 {
        var action = action_in;
        action.deadline_ms = self.clock.nowMs() + delay_ms;
        return self.wheel.schedule(action.deadline_ms, action);
    }

    /// Cancel a scheduled action and release its payload (the same `drop` the
    /// fire path calls — cancelling must not leak what firing would free).
    pub fn cancelTimer(self: *Self, id: u64) bool {
        return self.wheel.cancelWith(id, self, onTimerCancel);
    }

    /// Fire due timers without waiting for the ticker (tests drive this with a
    /// `Manual` clock; a custom event loop can call it instead of `start()`).
    pub fn tick(self: *Self) usize {
        return self.wheel.advance(self.clock.nowMs(), self, onTimerFire);
    }

    pub fn stats(self: *Self) RuntimeStats {
        var sent: u64 = 0;
        var received: u64 = 0;
        var dropped: u64 = 0;
        var errors: u64 = 0;
        var running_count: usize = 0;
        for (self.workers.items) |entry| {
            const s = entry.stats(entry.ptr);
            sent += s.sent;
            received += s.received;
            dropped += s.dropped_full;
            errors += s.handler_errors;
            if (s.running) running_count += 1;
        }
        return .{
            .workers = self.workers.items.len,
            .running = running_count,
            .messages_sent = sent,
            .messages_received = received,
            .messages_dropped = dropped,
            .handler_errors = errors,
            .timer_fires = self.timer_fires.load(.monotonic),
            .timer_lag_max_ms = self.timer_lag_max_ms.load(.monotonic),
        };
    }

    // ── internals ────────────────────────────────────────────────────────

    fn onTimerCancel(self: *Runtime, id: u64, action: TimerAction) void {
        _ = id;
        action.drop(action.ctx, self.allocator);
    }

    fn onTimerFire(self: *Runtime, id: u64, action: TimerAction) void {
        _ = id;
        // Count first, then deliver: a caller that observes the effect (a worker
        // that saw the message) must never see `timer_fires` still at the old
        // value — a counter that lags its own effect is a race, not a metric.
        _ = self.timer_fires.fetchAdd(1, .monotonic);

        const lag = self.clock.nowMs() - action.deadline_ms;
        if (lag > 0) {
            var observed = self.timer_lag_max_ms.load(.monotonic);
            while (lag > observed) {
                observed = self.timer_lag_max_ms.cmpxchgWeak(observed, lag, .monotonic, .monotonic) orelse break;
            }
        }

        action.post(action.ctx);
        action.drop(action.ctx, self.allocator);
    }

    fn tickerMain(self: *Self) void {
        self.mu.lock(self.io) catch return;
        while (self.ticker_running.load(.acquire)) {
            self.idle.waitTimeout(self.io, &self.mu, .{
                .duration = clock_mod.duration(tick_interval_ms),
            }) catch |err| switch (err) {
                // Expected every tick: the timeout *is* the sleep.
                error.Timeout => {},
                // Anything else means the wait was cut short (cancelation, or an
                // io error): fall through to advance() rather than dropping the
                // tick, so timers still fire.
                else => {},
            };
            self.mu.unlock(self.io);

            const before = self.clock.nowMs();
            _ = self.wheel.advance(before, self, onTimerFire);

            self.mu.lock(self.io) catch return;
        }
        self.mu.unlock(self.io);
    }
};

/// The thread body. Comptime-specialised per worker type, so the `handle`/`run`
/// call the compiler generates is a direct call — no dispatch, no vtable.
fn workerMain(comptime W: type, comptime capacity: usize) fn (*Handle(W, capacity)) void {
    return struct {
        fn main(handle: *Handle(W, capacity)) void {
            const H = Handle(W, capacity);

            // Optional init. A failure here is fatal for the worker (there is no
            // half-started state to supervise), but it still counts and stops.
            if (@hasDecl(W, "init")) {
                W.init(&handle.state, &handle.context) catch |err| {
                    std.log.err("[runtime] {s}.init failed: {s}", .{ @typeName(W), @errorName(err) });
                    _ = handle.handler_errors.fetchAdd(1, .monotonic);
                    handle.stop();
                };
            }

            if (@hasDecl(W, "Message") and @hasDecl(W, "handle")) {
                // Message-driven: the runtime owns the receive loop.
                while (true) {
                    if (handle.stop_requested.load(.acquire) and handle.mailbox.len() == 0) break;
                    const message = handle.mailbox.recv(0) orelse {
                        if (handle.mailbox.isClosed()) break;
                        continue;
                    };
                    W.handle(&handle.state, message, &handle.context) catch |err| {
                        if (supervise(H, handle, err)) break;
                    };
                }
            } else if (@hasDecl(W, "run")) {
                // Loop-owned: the worker decides when to finish.
                W.run(&handle.state, &handle.context) catch |err| {
                    _ = supervise(H, handle, err);
                };
            } else {
                @compileError("worker " ++ @typeName(W) ++ " declares neither " ++
                    "`pub const Message` + `pub fn handle(self, msg, ctx)` nor `pub fn run(self, ctx)`");
            }

            if (@hasDecl(W, "deinit")) W.deinit(&handle.state);
        }

        /// Record an error and decide whether the worker survives it.
        /// Returns true when the caller must stop its loop.
        fn supervise(comptime HH: type, handle: *HH, err: anyerror) bool {
            _ = handle.handler_errors.fetchAdd(1, .monotonic);

            // Windowed budget: reset the window when it has elapsed.
            const now = handle.runtime.clock.nowMs();
            if (handle.supervision.window_ms > 0 and now - handle.window_start_ms > handle.supervision.window_ms) {
                handle.window_start_ms = now;
                handle.errors_in_window = 0;
            }
            handle.errors_in_window += 1;

            // The actor's own opinion wins when declared; otherwise the strategy.
            const decision: Supervision.Strategy = if (@hasDecl(W, "onError"))
                W.onError(&handle.state, err, &handle.context)
            else
                handle.supervision.strategy;

            const over_budget = handle.supervision.max_errors != 0 and
                handle.errors_in_window > handle.supervision.max_errors;
            const must_stop = decision == .stop or over_budget;

            if (must_stop) {
                handle.stopped_by_supervisor = true;
                std.log.warn("[runtime] {s} stopped by supervisor after {d} error(s) in window ({s}{s}); last: {s}", .{
                    @typeName(W),
                    handle.errors_in_window,
                    @tagName(decision),
                    if (over_budget) ", over budget" else "",
                    @errorName(err),
                });
                handle.stop();
                return true;
            }

            std.log.warn("[runtime] {s} handler error ({d} in window): {s}", .{
                @typeName(W), handle.errors_in_window, @errorName(err),
            });
            return false;
        }
    }.main;
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

const CounterWorker = struct {
    pub const Message = u32;
    total: u32 = 0,
    seen: u32 = 0,

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        _ = ctx;
        self.total +%= msg;
        self.seen += 1;
    }
};

test "Runtime: a message-driven worker receives what was sent, in order" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const handle = try rt.spawn(CounterWorker, .{}, 64);
    for (1..5) |i| try handle.send(@intCast(i));
    handle.stop();
    handle.join();

    try std.testing.expectEqual(@as(u32, 10), handle.state.total);
    try std.testing.expectEqual(@as(u32, 4), handle.state.seen);
    const s = handle.stats();
    try std.testing.expectEqual(@as(u64, 4), s.sent);
    try std.testing.expectEqual(@as(u64, 4), s.received);
}

test "Runtime: full mailbox surfaces as error.Full at the producer" {
    const SlowWorker = struct {
        pub const Message = u32;
        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = self;
            _ = msg;
            _ = ctx;
            // Never returns quickly enough for the producer to keep up.
            var spins: usize = 0;
            while (spins < 500_000) : (spins += 1) std.atomic.spinLoopHint();
        }
    };
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const handle = try rt.spawn(SlowWorker, .{}, 2);
    var full_seen = false;
    for (0..1000) |i| {
        handle.send(@intCast(i)) catch |err| switch (err) {
            error.Full => {
                full_seen = true;
                break;
            },
            else => return err,
        };
    }
    try std.testing.expect(full_seen); // bounded: the producer learns, nothing grows silently
    try std.testing.expect(handle.stats().dropped_full > 0);
    handle.stop();
}

test "Runtime: run-owned worker stops on request" {
    const TickWorker = struct {
        ticks: u64 = 0,
        pub fn run(self: *@This(), ctx: anytype) anyerror!void {
            while (!ctx.stopped()) {
                self.ticks += 1;
                std.atomic.spinLoopHint();
            }
        }
    };
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const handle = try rt.spawn(TickWorker, .{}, 4);
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
    handle.stop();
    handle.join();
    try std.testing.expect(handle.state.ticks > 0);
}

test "Runtime: init and deinit run once around the worker's life" {
    const LifecycleWorker = struct {
        pub const Message = void;
        const Shared = struct {
            var inits: u32 = 0;
            var deinits: u32 = 0;
        };
        pub fn init(self: *@This(), ctx: anytype) anyerror!void {
            _ = self;
            _ = ctx;
            Shared.inits += 1;
        }
        pub fn handle(self: *@This(), msg: void, ctx: anytype) anyerror!void {
            _ = self;
            _ = msg;
            _ = ctx;
        }
        pub fn deinit(self: *@This()) void {
            _ = self;
            Shared.deinits += 1;
        }
    };
    LifecycleWorker.Shared.inits = 0;
    LifecycleWorker.Shared.deinits = 0;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();
    const handle = try rt.spawn(LifecycleWorker, .{}, 4);
    handle.stop();
    handle.join();
    try std.testing.expectEqual(@as(u32, 1), LifecycleWorker.Shared.inits);
    try std.testing.expectEqual(@as(u32, 1), LifecycleWorker.Shared.deinits);
}

test "Runtime: timers deliver a message after the delay, not before" {
    var manual_clock = Clock.Manual{ .now_ms = 1_000 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &manual_clock });
    defer rt.deinit();

    const handle = try rt.spawn(CounterWorker, .{}, 8);
    _ = try handle.after(50, 7);

    _ = rt.tick(); // 1_000 ms: nothing due yet
    try std.testing.expectEqual(@as(u32, 0), handle.state.seen);

    manual_clock.advance(40);
    _ = rt.tick();
    try std.testing.expectEqual(@as(u32, 0), handle.state.seen); // 1_040 < 1_050

    manual_clock.advance(20);
    _ = rt.tick(); // due now
    // The delivery is a mailbox message and the *worker* owns the consuming end,
    // so wait on the worker's state — reading the mailbox from here would race
    // the worker for its own message.
    var spins: usize = 0;
    while (handle.state.seen == 0 and spins < 4_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u32, 7), handle.state.total);
    try std.testing.expectEqual(@as(u64, 1), rt.stats().timer_fires);

    handle.stop();
}

test "Runtime: cancelling a timer drops it and its payload" {
    var manual_clock = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &manual_clock });
    defer rt.deinit();

    const handle = try rt.spawn(CounterWorker, .{}, 4);
    const id = try handle.after(100, 5);
    try std.testing.expectEqual(@as(usize, 1), rt.wheel.pendingCount());
    // Through the runtime: it drops the payload, which `wheel.cancel` alone
    // cannot do (it does not know the payload's type).
    try std.testing.expect(rt.cancelTimer(id));
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());

    manual_clock.advance(1_000);
    _ = rt.tick();
    try std.testing.expectEqual(@as(u32, 0), handle.state.seen);
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timer_fires);
    handle.stop();
}

test "Runtime: shutdown joins every worker and reports stats" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const a = try rt.spawn(CounterWorker, .{}, 16);
    const b = try rt.spawn(CounterWorker, .{}, 16);
    try a.send(1);
    try b.send(2);

    const before = rt.stats();
    try std.testing.expectEqual(@as(usize, 2), before.workers);
    try std.testing.expectEqual(@as(u64, 2), before.messages_sent);

    // Read the workers' state while they are alive: `shutdown` destroys the
    // handles (a caller that needs post-mortem numbers should snapshot here).
    var spins: usize = 0;
    while (a.state.seen + b.state.seen < 2 and spins < 4_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u32, 1), a.state.seen);
    try std.testing.expectEqual(@as(u32, 1), b.state.seen);

    rt.shutdown();
    try std.testing.expectEqual(@as(usize, 0), rt.stats().workers);
}

test "Runtime: the ticker fires timers without help from the caller" {
    // This is the only test that compiles and exercises `tickerMain` — the
    // example caught a type error there that `tick()`-driven tests never
    // instantiated. Keep at least one test on the real thread.
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();

    const handle = try rt.spawn(CounterWorker, .{}, 8);
    try rt.start();

    _ = try handle.after(10, 5); // 10 ms from now, on the ticker's clock
    var spins: usize = 0;
    while (handle.state.seen == 0 and spins < 400_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u32, 5), handle.state.total);
    try std.testing.expect(rt.stats().timer_fires >= 1);

    rt.shutdown();
    try std.testing.expectEqual(@as(usize, 0), rt.stats().workers);
}

const FlakyActor = struct {
    pub const Message = u32;
    handled: u32 = 0,
    /// Errors on every odd message; the supervisor decides what that means.
    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        _ = ctx;
        if (msg % 2 == 1) return error.Boom;
        self.handled += 1;
    }
};

test "Actor: a plain worker survives handler errors (v0.16 contract)" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const h = try rt.spawn(FlakyActor, .{}, 8); // spawn, not spawnActor: no budget
    for (0..4) |i| try h.send(@intCast(i)); // 1 and 3 fail
    var spins: usize = 0;
    while (h.state.handled < 2 and spins < 4_000_000) : (spins += 1) std.atomic.spinLoopHint();

    try std.testing.expectEqual(@as(u32, 2), h.state.handled); // the good messages got through
    try std.testing.expectEqual(@as(u64, 2), h.stats().handler_errors);
    try std.testing.expect(!h.stats().stopped_by_supervisor);
    try std.testing.expect(!h.mailbox.isClosed()); // still serving
    h.stop();
}

test "Actor: fail-fast strategy stops on the first error" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const h = try rt.spawnActor(FlakyActor, .{}, 8, .{ .strategy = .stop });
    try h.send(1); // fails → stop
    var spins: usize = 0;
    while (!h.mailbox.isClosed() and spins < 4_000_000) : (spins += 1) std.atomic.spinLoopHint();

    try std.testing.expect(h.mailbox.isClosed());
    try std.testing.expect(h.stats().stopped_by_supervisor);
    // A stopped actor takes no new work, and says so rather than buffering.
    try std.testing.expectError(error.Closed, h.send(2));
    h.join();
}

test "Actor: an error budget stops a permanently broken actor" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    // Tolerate 2 errors in the window, then stop — rather than logging forever.
    const h = try rt.spawnActor(FlakyActor, .{}, 32, .{ .max_errors = 2, .window_ms = 60_000 });
    for (0..20) |i| h.send(@intCast(i)) catch break;
    var spins: usize = 0;
    while (!h.mailbox.isClosed() and spins < 8_000_000) : (spins += 1) std.atomic.spinLoopHint();

    try std.testing.expect(h.mailbox.isClosed());
    const s = h.stats();
    try std.testing.expect(s.stopped_by_supervisor);
    try std.testing.expectEqual(@as(u32, 3), s.errors_in_window); // stopped on the 3rd
    h.join();
}

test "Actor: an onError hook overrides the configured strategy" {
    const Decides = struct {
        pub const Message = u32;
        handled: u32 = 0,
        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            if (msg == 9) return error.Fatal;
            self.handled += 1;
        }
        pub fn onError(self: *@This(), err: anyerror, ctx: anytype) Supervision.Strategy {
            _ = self;
            _ = ctx;
            // Only the fatal one is worth stopping for; everything else is noise.
            return if (err == error.Fatal) .stop else .restart;
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    // Strategy says "stop on any error"; the hook says "except the fatal one".
    const h = try rt.spawnActor(Decides, .{}, 32, .{ .strategy = .stop, .max_errors = 0 });
    try h.send(9);

    var spins: usize = 0;
    while (!h.mailbox.isClosed() and spins < 8_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expect(h.mailbox.isClosed());
    try std.testing.expect(h.stats().stopped_by_supervisor);

    // And the hook can also do the opposite: tolerate everything while the
    // configured strategy says fail-fast.
    const Tolerant = struct {
        pub const Message = u32;
        handled: u32 = 0,
        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            if (msg == 9) return error.Noise;
            self.handled += 1;
        }
        pub fn onError(self: *@This(), err: anyerror, ctx: anytype) Supervision.Strategy {
            _ = self;
            _ = ctx;
            std.log.debug("tolerating {s}", .{@errorName(err)});
            return .restart;
        }
    };
    const h2 = try rt.spawnActor(Tolerant, .{}, 32, .{ .strategy = .stop, .max_errors = 0 });
    try h2.send(9); // errors, but the hook says keep going
    try h2.send(2); // processed normally
    spins = 0;
    while (h2.state.handled == 0 and spins < 8_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(u32, 1), h2.state.handled);
    try std.testing.expect(!h2.mailbox.isClosed());
    try std.testing.expect(!h2.stats().stopped_by_supervisor);
    h2.stop();
}
