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
//! const rt = try app.runtime();               // created (and started) on first use
//! const worker = try rt.spawn(OrderBook, .{ .symbol = "BTC/USDT" }, 256); // 256 = mailbox capacity (comptime)
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
//! `clock()`, `stopped()` and `traceId()`.
//!
//! ## Trace context
//!
//! A message can carry the trace id of the work that produced it — the HTTP
//! request, the upstream service — so a worker's logs and errors are
//! attributable to that work instead of being orphans in the trace:
//!
//! ```zig
//! try worker.sendTraced(.{ .id = 42 }, trace);   // producer side
//! // ...
//! pub fn handle(self: *T, msg: Msg, ctx: anytype) anyerror!void {
//!     if (ctx.traceId()) |t| { _ = t; }           // the trace of *this* message
//! }
//! ```
//!
//! The id rides in the mailbox slot — 16 bytes, a value type, no allocation — not
//! on the handle, so concurrent producers cannot overwrite each other's. It is
//! null for a plain `send`, and null during `init`/`run` (no message is being
//! handled then). `handle.after(...)` called from inside a handler carries the
//! current message's trace along to the timer, so deferred work stays
//! attributable to whoever scheduled it.
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
const ring_mod = @import("ring.zig");
const sequencer_mod = @import("sequencer.zig");

pub const Clock = clock_mod.Clock;
pub const Wheel = wheel_mod.Wheel;
pub const Mailbox = mbox.Mailbox;

/// The id a traced message carries: `{ high: u64, low: u64 }` — a 16-byte value
/// type with no allocation, which is what lets it ride in a mailbox slot.
///
/// Re-exported (it lives in `tracing/DistributedTracer.zig`) so a producer tags a
/// message as `zigmodu.runtime.TraceId` without reaching into the tracing module,
/// and so the framework keeps exactly one such shape rather than a parallel
/// runtime-local one.
pub const TraceId = @import("../tracing/DistributedTracer.zig").DistributedTracer.TraceId;

/// Deferred work handed to the timer wheel. Type-erased so one wheel serves
/// workers with different message types; the runtime owns `ctx` and releases it
/// exactly once — on fire, on cancel, or (if the request never made it onto the
/// command queue) before `scheduleAction` returns the error.
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

/// How many timer commands can be in flight between the producers and the one
/// thread that owns the wheel. Power of two (`MpscRing` indexes with a mask) and
/// deliberately small: the queue is a hand-off, not a buffer — the driver drains
/// it every tick, so a producer that finds it full is looking at a saturated
/// runtime and gets `error.Full`, which is the runtime's usual "backpressure is
/// visible" answer.
pub const timer_command_capacity: usize = 512;

/// A change to the timer set, handed from a producer thread to the wheel's
/// owner.
///
/// Arm and cancel travel on **one** queue, in that order, because that is what
/// makes their relative order well defined: `arm(A); cancel(A)` from one thread
/// linearises as arm-then-cancel (cancelled, never fires), and a cancel that
/// arrives before its arm is simply a cancel that finds nothing to remove.
/// Two queues would leave the pair unordered and the outcome a coin flip.
const TimerCommand = union(enum) {
    arm: struct {
        /// Minted by the producer (`Runtime.timer_ids`), so `after` can return it
        /// without waiting for the driver.
        id: u64,
        /// Absolute deadline, computed on the **producer's** clock reading, so
        /// `after(50)` means "50 ms from when I called", not "50 ms from
        /// whenever the ticker got round to it".
        deadline_ms: i64,
        action: TimerAction,
    },
    cancel: struct {
        id: u64,
        /// Filled in by the owner when the cancel has been applied. Letting the
        /// command carry the answer is what makes `cancelTimerSync` exact without
        /// any ordering assumptions beyond the queue's FIFO.
        done: ?*std.atomic.Value(bool) = null,
        result: ?*std.atomic.Value(bool) = null,
    },
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

        /// What actually travels through the mailbox: the message plus the trace
        /// of the work that produced it. Private on purpose — the runtime is the
        /// only reader and writer, so wrapping the message costs callers nothing
        /// and keeps `send`'s signature intact. Nullable, so a producer with no
        /// trace to offer (a cron tick, a plain `send`) is not forced to invent
        /// one.
        const Envelope = struct {
            trace: ?TraceId = null,
            message: Message,
        };
        const MailboxType = mbox.Mailbox(Envelope, capacity);

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
            return self.mailbox.send(.{ .message = message });
        }

        pub fn sendBlocking(self: *Self, message: Message, timeout_ms: u32) mbox.SendError!void {
            return self.mailbox.sendBlocking(.{ .message = message }, timeout_ms);
        }

        /// `send`, with the trace id of the work that produced the message
        /// attached. The worker reads it back with `ctx.traceId()` while it
        /// handles *this* message: the value travels in the mailbox slot, so two
        /// producers sending different traces cannot overwrite each other's.
        pub fn sendTraced(self: *Self, message: Message, trace: TraceId) mbox.SendError!void {
            return self.mailbox.send(.{ .trace = trace, .message = message });
        }

        /// `sendBlocking`, with a trace attached — for the producer that would
        /// rather wait for room than drop. Backpressure is exactly when losing
        /// the trace hurts most: the messages that arrive late are the ones you
        /// want to attribute.
        pub fn sendBlockingTraced(self: *Self, message: Message, trace: TraceId, timeout_ms: u32) mbox.SendError!void {
            return self.mailbox.sendBlocking(.{ .trace = trace, .message = message }, timeout_ms);
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
        ///
        /// The delay is measured from *this call*: the deadline is computed here
        /// and handed to the wheel's owner, which is what keeps a worker's
        /// `after(50)` independent of how busy the ticker is. The timer fires
        /// somewhere in `[delay_ms, delay_ms + enqueue latency + tick_interval_ms]`
        /// (see `docs/RUNTIME.md` §3).
        ///
        /// Callable from any thread, and it does not touch the wheel: the request
        /// goes onto a bounded queue that grows nothing. `error.Full` means that
        /// queue is saturated — the runtime is behind, and the caller decides.
        ///
        /// The delivered message keeps the trace of whatever this worker is
        /// handling *right now*, so work deferred to the timer stays attributable
        /// to the request that deferred it. That only has an answer on the
        /// worker's own thread (see `WorkerContext.inheritTrace`): scheduling from
        /// anywhere else delivers an untraced message, which is the honest
        /// reading — no message is being handled there.
        pub fn after(self: *Self, delay_ms: i64, message: Message) !wheel_mod.Wheel(TimerAction).Id {
            const Delivery = struct {
                handle: *Self,
                message: Message,
                trace: ?TraceId,
                fn post(ctx: *anyopaque) void {
                    const d: *@This() = @ptrCast(@alignCast(ctx));
                    // A timer must not be able to stall the ticker, so a full or
                    // closed mailbox drops the message. Surfaced at debug: under
                    // sustained backpressure this is the line that tells you the
                    // timer fired but its worker never saw it.
                    d.handle.mailbox.send(.{ .trace = d.trace, .message = d.message }) catch |err| std.log.debug(
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
            // The runtime owns the payload from here on: it releases it on the
            // fire path, on the cancel path, and when the request never made it
            // onto the queue (which is the only failure this line can see).
            errdefer self.runtime.allocator.destroy(delivery);
            delivery.* = .{
                .handle = self,
                .message = message,
                .trace = self.context.inheritTrace(),
            };
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
        /// The worker's own thread id, published by that thread before it runs
        /// anything. Atomic because a caller on another thread may ask "is this
        /// the worker?" while the worker is still starting; 0 = not started.
        owner: std.atomic.Value(std.Thread.Id) = std.atomic.Value(std.Thread.Id).init(0),
        /// Trace of the message being handled *right now*. A plain field on
        /// purpose: only the worker's own thread writes it, and `inheritTrace`
        /// is the check that keeps that claim true for readers. `workerMain` sets
        /// it around each `handle` call; it stays null in `init`/`run`, when
        /// nothing is being handled.
        current_trace: ?TraceId = null,

        pub fn clock(self: *Self) Clock {
            return self.runtime.clock;
        }

        /// True once `stop()` was called or the runtime is shutting down.
        pub fn stopped(self: *Self) bool {
            return self.handle.stop_requested.load(.acquire) or !self.runtime.alive.load(.acquire);
        }

        /// Trace id of the message this worker is handling — the value its
        /// producer attached with `sendTraced`/`sendBlockingTraced`. Null for an
        /// untraced message, and everywhere outside `handle` (`init`, `run`,
        /// between messages).
        ///
        /// This is **per message, not per worker**: two messages carrying two
        /// different traces are each seen with their own, whatever order the
        /// producers posted them in.
        pub fn traceId(self: *const Self) ?TraceId {
            return self.current_trace;
        }

        /// What `Handle.after` hands the timer: the current message's trace, but
        /// only when the scheduling call happens on the worker's own thread.
        /// Anywhere else it is null — no message is being handled there, and
        /// letting that caller read `current_trace` would be a cross-thread read
        /// of a plain field.
        fn inheritTrace(self: *const Self) ?TraceId {
            if (self.owner.load(.acquire) != std.Thread.getCurrentId()) return null;
            return self.current_trace;
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
    /// Hand-off from the producers to the wheel's owner. `after()` never touches
    /// the wheel — it mints an id, computes a deadline and pushes an `arm`
    /// command here; the owner pops it and does the (allocating, single-writer)
    /// wheel insert. That is what makes "the wheel is single-threaded" true
    /// rather than aspirational, and it keeps the producer path allocation-free
    /// for the queue itself.
    timer_commands: ring_mod.MpscRing(TimerCommand, timer_command_capacity),
    /// Ids for timers, minted on the producer side. A plain lock-free counter:
    /// two `after()` calls cannot get the same id, which is what lets the wheel
    /// take ids from outside without giving up its `nodes` keying.
    timer_ids: sequencer_mod.Sequencer = sequencer_mod.Sequencer.init(1),
    /// Threads blocked in `cancelTimerSync`. Kept as a counter so the ticker only
    /// pays for the signal when somebody is actually waiting.
    timer_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Dedicated to `cancelTimerSync`'s wait, so the control-plane waiters cannot
    /// interfere with the ticker's own `mu`/`idle` sleep.
    cmd_mu: std.Io.Mutex = .init,
    cmd_idle: std.Io.Condition = .init,
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
    ///
    /// A timer armed with `after(delay_ms)` therefore fires somewhere in
    /// `[delay_ms, delay_ms + enqueue latency + tick_interval_ms]` — see
    /// `docs/RUNTIME.md` §3.
    pub const tick_interval_ms: u32 = 5;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, clock: Clock) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .clock = clock,
            // `now_ms` here is pre-ownership initialization: no driver exists
            // yet, so nobody can be reading the wheel concurrently. A driver
            // that starts later re-aligns it on its own thread (`Wheel.alignNow`).
            .wheel = Wheel(TimerAction).init(allocator, clock.nowMs()),
            .timer_commands = ring_mod.MpscRing(TimerCommand, timer_command_capacity).init(),
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
    ///
    /// The wheel's clock is *not* touched here: `start()` runs on the caller's
    /// thread, which is not the wheel's owner. The ticker aligns it when it
    /// takes the wheel (see `tickerMain`).
    pub fn start(self: *Self) !void {
        if (self.ticker_running.swap(true, .acquire)) return; // already started
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

        // Nobody is driving the wheel any more, so commands still in flight will
        // never become timers — and their payloads are owned by this queue until
        // one of the two happens. Release them (the `drop` half of the fire/cancel
        // contract) so a shutdown with a full command queue is not a leak.
        self.abandonTimerCommands();
        self.wakeTimerWaiters();
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
            .mailbox = mbox.Mailbox(H.Envelope, capacity).init(self.io),
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
    ///
    /// Safe from any thread, and **allocation-free on the caller's side** (the
    /// queue is fixed-capacity; the wheel node is created by the owner when it
    /// drains this command). `error.Full` when the hand-off queue is saturated —
    /// the caller drops, coalesces or backs off, exactly as with a full mailbox.
    pub fn scheduleAction(self: *Self, delay_ms: i64, action_in: TimerAction) !u64 {
        var action = action_in;
        // Both of these belong to the *producer*: the deadline so `after(50)`
        // keeps meaning "50 ms from the call", the id so `after` can return
        // before the ticker has seen anything.
        action.deadline_ms = self.clock.nowMs() + delay_ms;
        const id = self.timer_ids.next();
        const accepted = self.timer_commands.tryPush(.{ .arm = .{
            .id = id,
            .deadline_ms = action.deadline_ms,
            .action = action,
        } });
        if (!accepted) return error.Full;
        return id;
    }

    /// Ask the runtime to cancel `id`, and return as soon as the request is in
    /// the runtime's hands.
    ///
    /// **This is a request, not a result**: the id belongs to the wheel's owner,
    /// so the cancel takes effect when the owner drains the queue (~one tick).
    /// Use `cancelTimerSync` when the answer matters now.
    ///
    /// The payload is released by the owner — with the same `drop` the fire path
    /// calls, so cancelling cannot leak what firing would have freed.
    pub fn requestCancelTimer(self: *Self, id: u64) !void {
        const accepted = self.timer_commands.tryPush(.{ .cancel = .{ .id = id } });
        if (!accepted) return error.Full;
    }

    /// Cancel `id` and report whether it was still pending.
    ///
    /// Control-plane: it waits for the owner to apply the cancel, so it must not
    /// be called from the owner's own thread *if that thread is the ticker* —
    /// and it does not have to be, because a caller that owns the wheel cancels
    /// inline (after first draining whatever the queue already holds, so the
    /// arm/cancel order is still the queue's order).
    ///
    /// Returns `error.Full` if the request could not be queued, and
    /// `error.RuntimeStopped` if the runtime is torn down while waiting.
    pub fn cancelTimerSync(self: *Self, id: u64) !bool {
        if (self.wheel.ownerThread() == std.Thread.getCurrentId()) {
            _ = self.drainTimerCommands();
            return self.wheel.cancelWith(id, self, onTimerCancel);
        }

        var done = std.atomic.Value(bool).init(false);
        var result = std.atomic.Value(bool).init(false);
        const accepted = self.timer_commands.tryPush(.{ .cancel = .{
            .id = id,
            .done = &done,
            .result = &result,
        } });
        if (!accepted) return error.Full;

        _ = self.timer_waiters.fetchAdd(1, .monotonic);
        defer _ = self.timer_waiters.fetchSub(1, .monotonic);
        while (!done.load(.acquire)) {
            if (!self.alive.load(.acquire)) return error.RuntimeStopped;
            // Waiting on the condition (rather than spinning) keeps the caller
            // off the CPU during the up-to-one-tick wait; the timeout is the
            // safety net, the owner's signal after a drain is the fast path.
            self.cmd_mu.lock(self.io) catch return error.RuntimeStopped;
            self.cmd_idle.waitTimeout(self.io, &self.cmd_mu, .{
                .duration = clock_mod.duration(tick_interval_ms),
            }) catch |err| switch (err) {
                // Expected: the timeout *is* the poll.
                error.Timeout => {},
                else => {},
            };
            self.cmd_mu.unlock(self.io);
        }
        return result.load(.acquire);
    }

    /// Fire due timers without waiting for the ticker (tests drive this with a
    /// `Manual` clock; a custom event loop can call it instead of `start()`).
    ///
    /// Drains the timer command queue first, then advances — in that order, so a
    /// timer armed just before the tick is considered by it. This makes the
    /// calling thread the wheel's owner: the ticker and `tick()` are two ways to
    /// be the one driver, and mixing them is a bug the wheel reports.
    pub fn tick(self: *Self) usize {
        self.wheel.claimOwner();
        _ = self.drainTimerCommands();
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

    /// Publishes `RuntimeStats` into a metrics registry, sampled once per scrape.
    /// Wire it once at startup:
    ///
    /// ```zig
    /// var bridge = try Runtime.MetricsBridge(PrometheusMetrics).init(rt, metrics);
    /// metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);
    /// ```
    ///
    /// The runtime is the one place where "is it healthy" cannot be read off an
    /// HTTP histogram: a flooded mailbox, dropped messages, worker handler
    /// errors and a starved ticker are all invisible from the request side —
    /// `timer_lag_ms` in particular is the signal `docs/RUNTIME.md` §8 calls out
    /// as more telling than any timer count. Everything here is **sampled**
    /// rather than accumulated, so the values are gauges and carry no `_total`
    /// suffix (`PrometheusMetrics.Counter` has no `set`, only `inc`/`add`).
    ///
    /// `MetricsT` is duck-typed (`createGauge` + `Gauge.set`) so this layer keeps
    /// no dependency on the observability layer; the bridge outlives the
    /// process, so keep it in a stable location (not a stack frame you return
    /// from).
    pub fn MetricsBridge(comptime MetricsT: type) type {
        return struct {
            const Bridge = @This();

            rt: *Runtime,
            workers: *MetricsT.Gauge,
            running: *MetricsT.Gauge,
            messages_sent: *MetricsT.Gauge,
            messages_received: *MetricsT.Gauge,
            messages_dropped: *MetricsT.Gauge,
            handler_errors: *MetricsT.Gauge,
            timer_fires: *MetricsT.Gauge,
            timer_lag_ms: *MetricsT.Gauge,

            /// Registers the gauges. Startup-time call: if a later `createGauge`
            /// fails, the earlier ones stay registered in `metrics`.
            pub fn init(rt: *Runtime, metrics: *MetricsT) !Bridge {
                return .{
                    .rt = rt,
                    .workers = try metrics.createGauge("zigmodu_runtime_workers", "Worker slots registered in this runtime"),
                    .running = try metrics.createGauge("zigmodu_runtime_running", "Workers currently running"),
                    .messages_sent = try metrics.createGauge("zigmodu_runtime_messages_sent", "Messages posted into worker mailboxes"),
                    .messages_received = try metrics.createGauge("zigmodu_runtime_messages_received", "Messages a worker pulled out of its mailbox"),
                    .messages_dropped = try metrics.createGauge("zigmodu_runtime_messages_dropped", "Messages rejected by a full mailbox (backpressure, not silent loss)"),
                    .handler_errors = try metrics.createGauge("zigmodu_runtime_handler_errors", "Worker handler errors observed"),
                    .timer_fires = try metrics.createGauge("zigmodu_runtime_timer_fires", "Timers fired"),
                    .timer_lag_ms = try metrics.createGauge("zigmodu_runtime_timer_lag_ms", "Worst lateness between a timer deadline and its firing, in milliseconds"),
                };
            }

            /// Matches `PrometheusMetrics.ScrapeHook`; `ud` must point at a live
            /// `Bridge`.
            pub fn sample(ud: ?*anyopaque) void {
                const self: *Bridge = @ptrCast(@alignCast(ud orelse return));
                self.publish();
            }

            pub fn publish(self: *Bridge) void {
                const s = self.rt.stats();
                self.workers.set(@floatFromInt(s.workers));
                self.running.set(@floatFromInt(s.running));
                self.messages_sent.set(@floatFromInt(s.messages_sent));
                self.messages_received.set(@floatFromInt(s.messages_received));
                self.messages_dropped.set(@floatFromInt(s.messages_dropped));
                self.handler_errors.set(@floatFromInt(s.handler_errors));
                self.timer_fires.set(@floatFromInt(s.timer_fires));
                self.timer_lag_ms.set(@floatFromInt(s.timer_lag_max_ms));
            }
        };
    }

    // ── internals ────────────────────────────────────────────────────────

    // ── the command queue: producer side in, owner side out ──────────────

    /// Pop every queued command and apply it. **Owner thread only** — it is the
    /// only caller of `Wheel.scheduleWithId` / `Wheel.cancelWith`.
    ///
    /// Drains to empty rather than one command per call: a producer that found
    /// the queue full should not have to wait for as many ticks as it pushed
    /// commands, and the drain is bounded by the queue's capacity.
    fn drainTimerCommands(self: *Self) usize {
        var applied: usize = 0;
        while (self.timer_commands.tryPop()) |cmd| {
            switch (cmd) {
                .arm => |arm| {
                    self.wheel.scheduleWithId(arm.id, arm.deadline_ms, arm.action) catch |err| {
                        // The wheel could not allocate its node, so this timer can
                        // never fire. Losing it silently is not an option: name the
                        // error and release the payload the caller handed us.
                        std.log.err("[runtime] timer arm dropped (id={d}): {s}", .{ arm.id, @errorName(err) });
                        arm.action.drop(arm.action.ctx, self.allocator);
                    };
                    applied += 1;
                },
                .cancel => |cancel| {
                    const removed = self.wheel.cancelWith(cancel.id, self, onTimerCancel);
                    if (cancel.result) |result| result.store(removed, .monotonic);
                    if (cancel.done) |done| done.store(true, .release);
                    applied += 1;
                },
            }
        }
        return applied;
    }

    /// Release everything still queued, without touching the wheel: shutdown
    /// runs on a thread that is *not* the owner (the owner has already been
    /// joined). A queued arm will never fire, so its payload is dropped exactly
    /// as a cancel would drop it; a queued cancel is answered "no" so a waiter
    /// does not hang on a wheel that is going away.
    fn abandonTimerCommands(self: *Self) void {
        while (self.timer_commands.tryPop()) |cmd| {
            switch (cmd) {
                .arm => |arm| arm.action.drop(arm.action.ctx, self.allocator),
                .cancel => |cancel| {
                    if (cancel.result) |result| result.store(false, .monotonic);
                    if (cancel.done) |done| done.store(true, .release);
                },
            }
        }
    }

    /// Wake everyone parked in `cancelTimerSync`. Only called when somebody is
    /// actually waiting, so the drain path's cost does not depend on it.
    fn wakeTimerWaiters(self: *Self) void {
        if (self.timer_waiters.load(.monotonic) == 0) return;
        self.cmd_mu.lock(self.io) catch return;
        self.cmd_idle.broadcast(self.io);
        self.cmd_mu.unlock(self.io);
    }

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
        // Take the wheel before touching it, and re-align its clock: time has
        // passed since `Runtime.init`. Both have to happen on *this* thread — the
        // wheel has one writer by contract, and `start()` runs on somebody else's.
        self.wheel.claimOwner();
        self.wheel.alignNow(self.clock.nowMs());

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

            // Commands first, then the clock: a timer armed during the previous
            // tick is already a wheel node when this tick advances over it.
            const applied = self.drainTimerCommands();
            const before = self.clock.nowMs();
            _ = self.wheel.advance(before, self, onTimerFire);
            if (applied > 0) self.wakeTimerWaiters();

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

            // Publish this thread's id before anything else runs: `Handle.after`
            // asks "am I on the worker's own thread?" to decide whether the
            // current message's trace may be inherited, and that question needs an
            // answer (0 = not this worker) even while `init` runs.
            handle.context.owner.store(std.Thread.getCurrentId(), .release);

            // Optional init. A failure here is fatal for the worker (there is no
            // half-started state to supervise), but it still counts and stops.
            if (@hasDecl(W, "init")) {
                W.init(&handle.state, &handle.context) catch |err| {
                    var tag_buf: [trace_tag_len]u8 = undefined;
                    // No message is being handled yet, so the tag is always empty
                    // here — carried anyway so every runtime error line has the
                    // same shape and the same grep.
                    std.log.err("[runtime] {s}.init failed{s}: {s}", .{
                        @typeName(W), traceTag(handle.context.traceId(), &tag_buf), @errorName(err),
                    });
                    _ = handle.handler_errors.fetchAdd(1, .monotonic);
                    handle.stop();
                };
            }

            if (@hasDecl(W, "Message") and @hasDecl(W, "handle")) {
                // Message-driven: the runtime owns the receive loop.
                while (true) {
                    if (handle.stop_requested.load(.acquire) and handle.mailbox.len() == 0) break;
                    const envelope = handle.mailbox.recv(0) orelse {
                        if (handle.mailbox.isClosed()) break;
                        continue;
                    };
                    // Per *message*, not per worker: the trace is published for
                    // exactly as long as this message's `handle` runs, so a handler
                    // can neither see a previous message's trace nor leak this one
                    // into whatever it schedules afterwards.
                    handle.context.current_trace = envelope.trace;
                    defer handle.context.current_trace = null;
                    W.handle(&handle.state, envelope.message, &handle.context) catch |err| {
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

            // The trace of the message whose handler just failed — this is what
            // turns "worker X errored" into "the work that request Y caused
            // errored". Read here, before the loop clears `current_trace`.
            var tag_buf: [trace_tag_len]u8 = undefined;
            const tag = traceTag(handle.context.traceId(), &tag_buf);

            if (must_stop) {
                handle.stopped_by_supervisor = true;
                std.log.warn("[runtime] {s}{s} stopped by supervisor after {d} error(s) in window ({s}{s}); last: {s}", .{
                    @typeName(W),
                    tag,
                    handle.errors_in_window,
                    @tagName(decision),
                    if (over_budget) ", over budget" else "",
                    @errorName(err),
                });
                handle.stop();
                return true;
            }

            std.log.warn("[runtime] {s}{s} handler error ({d} in window): {s}", .{
                @typeName(W), tag, handle.errors_in_window, @errorName(err),
            });
            return false;
        }
    }.main;
}

/// Longest `traceTag` output: `" trace="` + two 16-digit hex halves.
const trace_tag_len = " trace=".len + 32;

/// `" trace=<hex>"` when the worker is handling a traced message, `""` otherwise.
/// Stack-formatted and allocator-free — this runs on an error path, where an
/// allocation failure would swallow the very line that says what went wrong.
/// The hex shape matches `TraceId.toString` (and therefore the OTLP span), just
/// without the dash the HTTP middleware puts between the two halves.
fn traceTag(trace: ?TraceId, buf: []u8) []const u8 {
    const t = trace orelse return "";
    return std.fmt.bufPrint(buf, " trace={x:016}{x:016}", .{ t.high, t.low }) catch "";
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
    // The arm is a *request* until the owner drains it: this thread owns the
    // wheel here (it drives `tick()`), so the tick turns it into a wheel node.
    _ = rt.tick(); // deadline 100: drained, not due
    try std.testing.expectEqual(@as(usize, 1), rt.wheel.pendingCount());
    // Through the runtime: it drops the payload, which `wheel.cancel` alone
    // cannot do (it does not know the payload's type). Synchronous, because the
    // test wants the answer, not the request.
    try std.testing.expect(try rt.cancelTimerSync(id));
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());

    manual_clock.advance(1_000);
    _ = rt.tick();
    try std.testing.expectEqual(@as(u32, 0), handle.state.seen);
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timer_fires);
    handle.stop();
}

// ── the wheel's concurrency contract ─────────────────────────────────────
//
// Three tests, written against the *contract* rather than the internals:
// `after()` hands out unique ids, the arm/cancel accounting closes under a
// concurrent driver, and a timer armed from inside a handler arrives. They are
// the regression suite for "the wheel is owned by one thread at a time" — the
// property the command queue in front of it exists to preserve.

/// Request a cancel, retrying while the hand-off queue is full.
///
/// `error.Full` is the documented answer to a saturated command queue, and the
/// ticker is draining it — so for a test that needs the cancel *applied*, the
/// only honest handling is to wait and retry. (Production code gets to choose:
/// drop, coalesce or retry, see `docs/RUNTIME.md` §5.)
fn requestCancelRetry(rt: *Runtime, id: u64) !void {
    while (true) {
        rt.requestCancelTimer(id) catch |err| switch (err) {
            error.Full => {
                std.atomic.spinLoopHint();
                continue;
            },
        };
        return;
    }
}

/// `cancelTimerSync`, retried on a full queue. Used as a FIFO barrier: the queue
/// is in-order, so once this one is answered, every cancel pushed before it has
/// been applied.
fn cancelSyncRetry(rt: *Runtime, id: u64) !bool {
    while (true) {
        return rt.cancelTimerSync(id) catch |err| switch (err) {
            error.Full => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => return err,
        };
    }
}

/// T1 — `after()` must hand out a distinct id per call, from any thread.
///
/// 32 threads × 10_000 calls, released together by a spin barrier. The barrier
/// is the point: without it the threads stagger and the read-modify-write on the
/// id counter is only ever observed one call at a time. The scale is a
/// trade-off, not a preference — 320k calls is what made the race fire on every
/// run here, while staying small enough (~2 s in a Debug build, ~5 MB of ids)
/// not to dominate the suite. The timers are armed an hour out so none of them
/// fires: the assertion is about the ids, and 320k deliveries would only add
/// mailbox-drop noise.
const ArmSquad = struct {
    handle: *Handle(CounterWorker, 4),
    ids: []u64,
    barrier: *std.atomic.Value(u32),
    threads_n: u32,
    /// Non-zero ids only: a call that failed can never be cancelled, and the
    /// caller reports the count separately.
    failed: *std.atomic.Value(usize),

    fn run(self: *@This()) void {
        _ = self.barrier.fetchAdd(1, .acq_rel);
        while (self.barrier.load(.acquire) < self.threads_n) std.atomic.spinLoopHint();
        for (self.ids) |*id| {
            // The command queue is a bounded hand-off, so a saturated runtime
            // answers `error.Full` — that is the contract, not a failure. Retry
            // (the driver is draining); anything else ends the thread.
            while (true) {
                id.* = self.handle.after(3_600_000, 1) catch |err| switch (err) {
                    error.Full => {
                        std.atomic.spinLoopHint();
                        continue;
                    },
                    else => {
                        _ = self.failed.fetchAdd(1, .monotonic);
                        id.* = 0;
                        return;
                    },
                };
                break;
            }
        }
    }
};

test "T1 Runtime: concurrent after() hands out unique timer ids" {
    const threads_n = 32;
    const per_thread = 10_000;
    const total = threads_n * per_thread;

    // `std.heap.smp_allocator`, not `std.testing.allocator`: this test makes
    // 640k allocations (one `Delivery` per arm, one wheel node per drained arm)
    // from 33 threads at once, and the testing allocator's per-allocation stack
    // capture plus its per-thread rendezvous turned that into >10 minutes of
    // lock spinning on this machine. The scalable allocator makes the same work
    // take well under a second. What is given up is leak *accounting* — so the
    // release story is asserted structurally instead, at the end of the test
    // (every cancel applied, `pendingCount() == 0`).
    const alloc = std.heap.smp_allocator;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(alloc, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();
    // Whichever thread drives the wheel (here: the ticker) is the only one that
    // may touch it, so the ticker has to be the one that is running.
    try rt.start();
    const handle = try rt.spawn(CounterWorker, .{}, 4);
    defer handle.stop();

    const ids = try alloc.alloc(u64, total);
    defer alloc.free(ids);

    var barrier = std.atomic.Value(u32).init(0);
    var failed = std.atomic.Value(usize).init(0);
    var threads: [threads_n]std.Thread = undefined;
    var squads: [threads_n]ArmSquad = undefined;
    for (&squads, &threads, 0..) |*s, *t, i| {
        s.* = .{
            .handle = handle,
            .ids = ids[i * per_thread ..][0..per_thread],
            .barrier = &barrier,
            .threads_n = threads_n,
            .failed = &failed,
        };
        t.* = try std.Thread.spawn(.{}, ArmSquad.run, .{s});
    }
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(@as(usize, 0), failed.load(.monotonic));

    var seen = std.AutoHashMapUnmanaged(u64, void).empty;
    defer seen.deinit(alloc);
    var duplicates: usize = 0;
    for (ids) |id| {
        if ((try seen.getOrPut(alloc, id)).found_existing) duplicates += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), duplicates); // two timers sharing an id is the bug
    try std.testing.expectEqual(@as(usize, total), seen.count());

    // Release the timers. The payloads are heap-allocated `Delivery`s, and the
    // wheel does not run their `drop` when it is torn down, so leaving them
    // pending would be reported by the testing allocator rather than by the
    // assertion above — a failure for the wrong reason.
    //
    // The requests are asynchronous (the ticker owns the wheel), so the last
    // step is a `cancelTimerSync` on an id that cannot exist: the queue is FIFO,
    // so once that one is answered, every cancel pushed before it has been
    // applied.
    for (ids) |id| try requestCancelRetry(&rt, id);
    try std.testing.expect(!try cancelSyncRetry(&rt, std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());
}

/// T2 — the arm/cancel/fire accounting must close while a driver is advancing
/// the wheel underneath the producers.
///
/// Producers arm and cancel through `Runtime` while the test thread drives
/// `tick()`; each timer's payload points at its own counter, so "fired" is
/// observable per timer with no mailbox in the way (nothing to drop, no log
/// noise, no flakiness of the test's own making).
///
/// The invariant is `S = F + C + P`: every successful arm either fired, was
/// cancelled, or is still pending — and no timer does two of those.
const T2Slot = struct {
    fired: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

const T2Payload = struct {
    fn post(ctx: *anyopaque) void {
        const slot: *T2Slot = @ptrCast(@alignCast(ctx));
        _ = slot.fired.fetchAdd(1, .monotonic);
    }
    fn drop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        // The slots live in the test's own array: nothing to release. (The
        // runtime still calls this on the cancel path, which is what keeps the
        // payload's ownership contract honest.)
        _ = ctx;
        _ = allocator;
    }
};

const T2Producer = struct {
    rt: *Runtime,
    slots: []T2Slot,
    ids: []u64,
    cancelled: []bool,
    armed: *std.atomic.Value(usize),
    finished: *std.atomic.Value(usize),
    errors: *std.atomic.Value(usize),

    fn run(self: *@This()) void {
        defer _ = self.finished.fetchAdd(1, .release);
        for (self.ids, 0..) |*id, i| {
            const slot = &self.slots[i];
            const delay: i64 = 10 + @as(i64, @intCast(i % 40)) * 10;
            id.* = self.rt.scheduleAction(delay, .{
                .ctx = @ptrCast(slot),
                .post = T2Payload.post,
                .drop = T2Payload.drop,
            }) catch {
                _ = self.errors.fetchAdd(1, .monotonic);
                return;
            };
            _ = self.armed.fetchAdd(1, .monotonic);
            // Cancel a timer armed three calls ago: by now the driver may
            // already have fired it, which is exactly the interleaving the
            // accounting has to survive. Synchronous on purpose — the point of
            // the test is to count *applied* cancels, not requested ones.
            if (i >= 3 and i % 3 == 0) {
                self.cancelled[i - 3] = self.rt.cancelTimerSync(self.ids[i - 3]) catch failed: {
                    // A failed request must not be silently read as "not
                    // cancelled": the invariant below would still hold and hide
                    // it. Count it and assert on the count.
                    _ = self.errors.fetchAdd(1, .monotonic);
                    break :failed false;
                };
            }
        }
    }
};

test "T2 Runtime: concurrent arm/cancel/advance keeps scheduled = fired + cancelled + pending" {
    const producers_n = 4;
    const per_producer = 1_000;
    const total = producers_n * per_producer;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const slots = try std.testing.allocator.alloc(T2Slot, total);
    defer std.testing.allocator.free(slots);
    @memset(slots, T2Slot{});
    const ids = try std.testing.allocator.alloc(u64, total);
    defer std.testing.allocator.free(ids);
    @memset(ids, 0);
    const cancelled = try std.testing.allocator.alloc(bool, total);
    defer std.testing.allocator.free(cancelled);
    @memset(cancelled, false);

    var armed = std.atomic.Value(usize).init(0);
    var finished = std.atomic.Value(usize).init(0);
    var errors = std.atomic.Value(usize).init(0);
    var threads: [producers_n]std.Thread = undefined;
    var workers: [producers_n]T2Producer = undefined;
    for (&workers, &threads, 0..) |*w, *t, p| {
        w.* = .{
            .rt = &rt,
            .slots = slots[p * per_producer ..][0..per_producer],
            .ids = ids[p * per_producer ..][0..per_producer],
            .cancelled = cancelled[p * per_producer ..][0..per_producer],
            .armed = &armed,
            .finished = &finished,
            .errors = &errors,
        };
        t.* = try std.Thread.spawn(.{}, T2Producer.run, .{w});
    }

    // The driver: advance the clock and let the wheel do its work while the
    // producers are still arming. Bounded so a wedged producer fails the test
    // instead of hanging the suite.
    var spins: usize = 0;
    while (finished.load(.acquire) < producers_n and spins < 200_000_000) : (spins += 1) {
        clk.advance(5);
        _ = rt.tick();
    }
    try std.testing.expectEqual(@as(usize, producers_n), finished.load(.acquire));
    for (&threads) |*t| t.join();
    try std.testing.expectEqual(@as(usize, 0), errors.load(.monotonic));

    // One last tick with the clock past every deadline: drain, then advance.
    clk.set(10_000_000);
    _ = rt.tick();

    var fired: usize = 0;
    for (slots) |*slot| {
        const n = slot.fired.load(.monotonic);
        try std.testing.expect(n <= 1); // a timer fires once
        fired += n;
    }
    for (cancelled, slots) |was_cancelled, slot| {
        if (was_cancelled) try std.testing.expectEqual(@as(u32, 0), slot.fired.load(.monotonic)); // neither both
    }

    const scheduled = armed.load(.monotonic);
    const cancelled_n = rt.wheel.cancelled;
    const pending = rt.wheel.pendingCount();
    try std.testing.expectEqual(scheduled, fired + cancelled_n + pending);
    try std.testing.expectEqual(@as(usize, 0), pending); // the clock is past every deadline
}

/// T3 — the documented worker idiom: a handler arms a timer through its own
/// handle, and the runtime's ticker delivers the message later. This is the
/// path §3 of `docs/RUNTIME.md` tells workers to use, so it has to keep
/// working whatever the wheel's internals become.
const DeferProbe = struct {
    pub const Message = u32;
    deferred_seen: bool = false,
    armed: bool = false,

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        switch (msg) {
            1 => {
                self.armed = true;
                _ = try ctx.handle.after(10, 2);
            },
            else => self.deferred_seen = true,
        }
    }
};

test "T3 Runtime: a worker's own after() still fires with the ticker running" {
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();
    try rt.start();
    const handle = try rt.spawn(DeferProbe, .{}, 8);
    defer handle.stop();

    try handle.send(1);

    var spins: usize = 0;
    while (!handle.state.deferred_seen and spins < 400_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expect(handle.state.armed);
    try std.testing.expect(handle.state.deferred_seen);
}

// ── trace context ────────────────────────────────────────────────────────

/// What a producer tags a message with: derived from the producer's tag, so a
/// test can tell "the trace my message carried" from "some other producer's".
fn taggedTrace(tag: u64) TraceId {
    return .{ .high = tag +% 1, .low = ~tag };
}

fn traceEquals(a: ?TraceId, b: ?TraceId) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.high == b.?.high and a.?.low == b.?.low;
}

/// Records the message it got and the trace its handler saw, so assertions can
/// run after `join()` instead of racing the worker.
const TraceProbe = struct {
    pub const Message = u32;
    const max_seen = 16;

    traces: [max_seen]?TraceId = @splat(null),
    messages: [max_seen]u32 = @splat(0),
    count: usize = 0,
    /// Set before sending: the next message's handler defers through the timer.
    defer_next: bool = false,
    deferred_message: u32 = 0xF00D,

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        // Read the trace first: it describes *this* message, and `after` below
        // deliberately inherits it.
        const trace = ctx.traceId();
        if (self.defer_next) {
            self.defer_next = false;
            _ = try ctx.handle.after(10, self.deferred_message);
        }
        // Record last, so a test that sees the message also knows the handler ran
        // to completion (and, with `defer_next`, that the timer is really armed —
        // the wheel is not thread-safe, so the observer must not walk it while
        // this thread might still be scheduling).
        if (self.count < max_seen) {
            self.traces[self.count] = trace;
            self.messages[self.count] = msg;
            self.count += 1;
        }
    }
};

/// One producer thread of the cross-thread test: every message it posts carries
/// *its* trace.
const TraceProducer = struct {
    fn run(handle: anytype, tag: u64, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const msg = (tag << 32) | @as(u64, i);
            // Blocking, not dropping: the point of the test is which trace each
            // *delivered* message carries, so a retry loop would only add noise.
            handle.sendBlockingTraced(msg, taggedTrace(tag), 0) catch return;
            std.atomic.spinLoopHint();
        }
    }
};

/// Two producers, one worker. A trace kept on the handle instead of in the
/// mailbox slot would be clobbered by the other producer's next send — this is
/// the test that fails if someone "simplifies" the envelope away.
const CrossThreadProbe = struct {
    pub const Message = u64;

    seen: u32 = 0,
    mismatches: u32 = 0,

    pub fn handle(self: *@This(), msg: u64, ctx: anytype) anyerror!void {
        const tag = msg >> 32;
        const want = taggedTrace(tag);
        if (ctx.traceId()) |got| {
            if (got.high != want.high or got.low != want.low) self.mismatches += 1;
        } else {
            self.mismatches += 1;
        }
        self.seen += 1;
    }
};

test "Runtime: sendTraced tags the message, send leaves it untraced" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const handle = try rt.spawn(TraceProbe, .{}, 16);
    const tag = taggedTrace(7);
    try handle.sendTraced(1, tag);
    try handle.send(2);
    try handle.sendBlockingTraced(3, tag, 1_000);
    handle.stop();
    handle.join(); // the mailbox drains before it reports closed

    try std.testing.expectEqual(@as(usize, 3), handle.state.count);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, handle.state.messages[0..3]);
    try std.testing.expect(traceEquals(tag, handle.state.traces[0]));
    try std.testing.expect(handle.state.traces[1] == null);
    try std.testing.expect(traceEquals(tag, handle.state.traces[2]));
}

test "Runtime: interleaved traced and untraced messages each keep their own trace" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const first = taggedTrace(1);
    const second = taggedTrace(2);
    const handle = try rt.spawn(TraceProbe, .{}, 16);
    try handle.send(10);
    try handle.sendTraced(11, first);
    try handle.send(12);
    try handle.sendTraced(13, second);
    try handle.send(14);
    handle.stop();
    handle.join();

    try std.testing.expectEqual(@as(usize, 5), handle.state.count);
    try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12, 13, 14 }, handle.state.messages[0..5]);
    try std.testing.expect(handle.state.traces[0] == null);
    try std.testing.expect(traceEquals(first, handle.state.traces[1]));
    try std.testing.expect(handle.state.traces[2] == null);
    try std.testing.expect(traceEquals(second, handle.state.traces[3]));
    try std.testing.expect(handle.state.traces[4] == null);
}

test "Runtime: a producer's trace stays on its own messages across threads" {
    const per_producer: u32 = 1_000;
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    // Room for both producers to be in flight at once, so the two traces really
    // do overlap in time. 256 (not more): `MpscRing.init` seeds every slot at
    // comptime, and a bigger capacity trips the comptime branch quota.
    const handle = try rt.spawn(CrossThreadProbe, .{}, 256);
    const a = try std.Thread.spawn(.{}, TraceProducer.run, .{ handle, @as(u64, 0), per_producer });
    const b = try std.Thread.spawn(.{}, TraceProducer.run, .{ handle, @as(u64, 1), per_producer });
    a.join();
    b.join();
    handle.stop();
    handle.join();

    try std.testing.expectEqual(@as(u32, 2 * per_producer), handle.state.seen);
    try std.testing.expectEqual(@as(u32, 0), handle.state.mismatches);
}

test "Runtime: a timer scheduled inside a handler keeps that message's trace" {
    var clk = Clock.Manual{ .now_ms = 1_000 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const tag = taggedTrace(9);
    const handle = try rt.spawn(TraceProbe, .{ .defer_next = true }, 8);
    try handle.sendTraced(7, tag);

    var spins: usize = 0;
    while (handle.state.count == 0 and spins < 8_000_000) : (spins += 1) std.atomic.spinLoopHint();
    try std.testing.expectEqual(@as(usize, 1), handle.state.count); // handled, timer armed
    _ = rt.tick(); // the arm is a queued request: this drains it into the wheel (1000 + 10, not due)
    try std.testing.expectEqual(@as(usize, 1), rt.wheel.pendingCount());

    clk.advance(10);
    _ = rt.tick(); // the timer posts into the same mailbox
    spins = 0;
    while (handle.state.count < 2 and spins < 8_000_000) : (spins += 1) std.atomic.spinLoopHint();
    handle.stop();
    handle.join();

    try std.testing.expectEqual(@as(usize, 2), handle.state.count);
    try std.testing.expectEqual(@as(u32, 7), handle.state.messages[0]);
    try std.testing.expect(traceEquals(tag, handle.state.traces[0]));
    try std.testing.expectEqual(handle.state.deferred_message, handle.state.messages[1]);
    // The deferred message was not sent by anyone — it inherited the trace of the
    // message whose handler armed the timer.
    try std.testing.expect(traceEquals(tag, handle.state.traces[1]));
}

test "Runtime: trace context exists only inside a message's handler" {
    const PhaseProbe = struct {
        pub const Message = u32;
        init_had_trace: bool = false,
        untraced_had_trace: bool = false,
        traced_had_trace: bool = false,

        pub fn init(self: *@This(), ctx: anytype) anyerror!void {
            self.init_had_trace = ctx.traceId() != null;
        }

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            if (msg == 1) {
                self.untraced_had_trace = ctx.traceId() != null;
            } else {
                self.traced_had_trace = ctx.traceId() != null;
            }
        }
    };

    const LoopProbe = struct {
        saw_trace: bool = false,

        pub fn run(self: *@This(), ctx: anytype) anyerror!void {
            self.saw_trace = ctx.traceId() != null;
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const handle = try rt.spawn(PhaseProbe, .{}, 8);
    try handle.send(1); // untraced
    try handle.sendTraced(2, taggedTrace(3));
    handle.stop();
    handle.join();

    try std.testing.expect(!handle.state.init_had_trace); // `init`: no message yet
    try std.testing.expect(!handle.state.untraced_had_trace);
    try std.testing.expect(handle.state.traced_had_trace);

    // A run-owned worker has no message at all, so there is nothing to attribute.
    const loop = try rt.spawn(LoopProbe, .{}, 4);
    loop.join(); // `run` returns immediately
    try std.testing.expect(!loop.state.saw_trace);
    loop.stop();
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

test "Runtime.MetricsBridge publishes RuntimeStats into a Prometheus scrape" {
    const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
    const allocator = std.testing.allocator;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const counter_handle = try rt.spawn(CounterWorker, .{}, 64);
    try counter_handle.send(1);
    try counter_handle.send(2);
    counter_handle.stop();
    counter_handle.join();

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    // Startup wiring: register the gauges once, then let the scrape hook sample
    // them. Nothing else in the framework watches the runtime's own health.
    var bridge = try Runtime.MetricsBridge(PrometheusMetrics).init(&rt, &metrics);
    metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);

    const text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(text);

    // Values are compared against `rt.stats()` rather than hardcoded: the point
    // is that the scrape reports what the runtime reports, not a fixed number.
    const s = rt.stats();
    const check = struct {
        fn gauge(body: []const u8, name: []const u8, value: f64) !void {
            var buf: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{s} {d:.6}", .{ name, value });
            try std.testing.expect(std.mem.indexOf(u8, body, line) != null);
        }
    }.gauge;

    try std.testing.expect(s.workers == 1);
    try check(text, "zigmodu_runtime_workers", @floatFromInt(s.workers));
    try check(text, "zigmodu_runtime_running", @floatFromInt(s.running));
    try check(text, "zigmodu_runtime_messages_sent", @floatFromInt(s.messages_sent));
    try check(text, "zigmodu_runtime_messages_received", @floatFromInt(s.messages_received));
    try check(text, "zigmodu_runtime_messages_dropped", @floatFromInt(s.messages_dropped));
    try check(text, "zigmodu_runtime_handler_errors", @floatFromInt(s.handler_errors));
    try check(text, "zigmodu_runtime_timer_fires", @floatFromInt(s.timer_fires));
    try check(text, "zigmodu_runtime_timer_lag_ms", @floatFromInt(s.timer_lag_max_ms));

    // The dropped/backpressure signal is the reason this bridge exists — make
    // sure a full mailbox actually moves it rather than staying at zero.
    const SlowWorker = struct {
        pub const Message = u32;
        pub fn handle(_: *@This(), _: u32, _: anytype) anyerror!void {
            var spins: usize = 0;
            while (spins < 500_000) : (spins += 1) std.atomic.spinLoopHint();
        }
    };
    const full = try rt.spawn(SlowWorker, .{}, 2);
    defer full.stop();
    for (0..1000) |i| {
        full.send(@intCast(i)) catch break; // capacity 2 → the producer sees error.Full
    }
    const after = rt.stats();
    try std.testing.expect(after.messages_dropped > 0);

    bridge.publish(); // sampling is callable directly, not only from a scrape
    const retext = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(retext);
    try check(retext, "zigmodu_runtime_messages_dropped", @floatFromInt(after.messages_dropped));
}
