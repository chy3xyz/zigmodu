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
//! `Runtime.shutdown()` (and `Application.stop()`) stops the **ticker first**,
//! then requests every worker to stop, closes its mailbox so a blocked `recv`
//! wakes, and joins. The order is deliberate: the ticker is the one thread that
//! can still run a timer's `post`, and that callback writes into the handle
//! being torn down (see `shutdown`). Workers that never return still block
//! shutdown: that is deliberate — a runtime that silently abandons threads hides
//! the bug.

const std = @import("std");
const mbox = @import("mailbox.zig");
const wheel_mod = @import("timer_wheel.zig");
const clock_mod = @import("clock.zig");
const ring_mod = @import("ring.zig");
const sequencer_mod = @import("sequencer.zig");
const scheduler_mod = @import("scheduler.zig");

pub const Clock = clock_mod.Clock;
pub const Wheel = wheel_mod.Wheel;
pub const Mailbox = mbox.Mailbox;
/// The pool behind `.mode = .pooled` (docs/RUNTIME.md §12).
pub const Scheduler = scheduler_mod.Scheduler;
/// How the pool is declared: `Runtime.InitOptions.scheduler`.
pub const SchedulerConfig = scheduler_mod.SchedulerConfig;

/// Who runs a worker's `handle`.
pub const SpawnMode = enum {
    /// Its own OS thread. The default, and the v0.16 behaviour: a message wakes
    /// the worker's thread directly. Latency chains stay here.
    dedicated,
    /// A thread from the runtime's pool (docs/RUNTIME.md §12). The worker keeps
    /// its own mailbox and contract; what changes is who guarantees §12.3's state
    /// exclusivity — an explicit claim instead of thread identity.
    pooled,
};

/// `spawn`'s last argument, in either of the two shapes `spawnConfig` accepts.
pub const SpawnConfig = struct {
    /// Mailbox capacity in messages. Comptime, because the mailbox is a
    /// fixed-capacity ring.
    capacity: usize,
    mode: SpawnMode = .dedicated,
};

/// Normalise `spawn`'s last parameter, so the two call shapes are one entry
/// point (§12.8 D1) and one implementation:
///
/// ```zig
/// const a = try rt.spawn(Book, .{}, 256);                                  // v0.16 form
/// const b = try rt.spawn(Audit, .{}, .{ .capacity = 64, .mode = .pooled }); // + pool
/// ```
///
/// The positional capacity is kept for the ~30 call sites that already have it —
/// the mode is additive, so upgrading is a choice rather than a migration.
pub fn spawnConfig(comptime arg: anytype) SpawnConfig {
    const T = @TypeOf(arg);
    switch (@typeInfo(T)) {
        .int, .comptime_int => return .{ .capacity = arg },
        .@"struct" => {
            if (!@hasField(T, "capacity")) @compileError(
                "spawn's last parameter is a mailbox capacity (`256`) or a `SpawnConfig` " ++
                    "(`.{ .capacity = 256, .mode = .pooled }`); " ++ @typeName(T) ++ " has no `capacity` field",
            );
            var config: SpawnConfig = .{ .capacity = @field(arg, "capacity") };
            if (@hasField(T, "mode")) config.mode = @field(arg, "mode");
            return config;
        },
        else => @compileError(
            "spawn's last parameter is a mailbox capacity (`256`) or a `SpawnConfig`, not " ++ @typeName(T),
        ),
    }
}

/// Whether `W` may be pooled (§12.5).
///
/// A message-driven worker is driven by the runtime one message at a time, so a
/// pool thread can run a bounded batch and hand it back. A `run`-owned worker
/// has a loop of its own: pooling it would occupy a pool thread for as long as
/// it runs, which is the one thing the pool cannot survive — `spawn` turns this
/// into a `@compileError` rather than a worker that quietly monopolises the pool.
pub fn poolable(comptime W: type) bool {
    return @hasDecl(W, "Message") and @hasDecl(W, "handle");
}

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
/// exactly once — on fire, on cancel, at shutdown (a timer that never fires is
/// released by `Runtime.drainWheel`), or, if the request never made it onto the
/// command queue, before `scheduleAction` returns the error.
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
    /// Messages this worker accepted and then abandoned at its stop: it was
    /// stopped by the supervisor (or the pool went down) with a queue still
    /// behind it, and whatever was left will never be handled.
    ///
    /// A different reason from `dropped_full`, and a separate counter on
    /// purpose: `dropped_full` is a producer being refused (`error.Full`, the
    /// message was never accepted, the caller knows), while this is work that
    /// was accepted and then thrown away by the *worker's* stop. Merging them
    /// would read "the producers are under backpressure" and "this actor's
    /// queue was abandoned" as the same event. See docs/RUNTIME.md §5.
    discarded_on_stop: u64,
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
    /// Messages accepted and then abandoned by a worker's stop, runtime-wide —
    /// what every worker's `WorkerStats.discarded_on_stop` counts, added up by
    /// the runtime as it happens. Read off that accumulator rather than summed
    /// over the live workers (the way `messages_dropped` is), because `shutdown`
    /// joins and destroys a worker in the same pass: a sum would be back to 0 by
    /// the time anyone could read the loss. `timers_discarded` is accumulated
    /// for the same reason. NOT a second reading of `messages_dropped` — see
    /// that field's sibling in `WorkerStats` and docs/RUNTIME.md §5.
    messages_discarded_on_stop: u64,
    handler_errors: u64,
    timer_fires: u64,
    /// Timers that were accepted but never fired, released when the runtime shut
    /// down instead — still in the command queue, or already a node in the
    /// wheel. Counted for the same reason `messages_dropped` is: work that was
    /// promised and then did not happen must not disappear without a number.
    timers_discarded: u64,
    /// Timers that **fired** and whose message the target mailbox refused
    /// (`error.Closed` because that worker had stopped, `error.Full` because its
    /// queue was still full). The timer never runs the ticker's callback chain
    /// past this point: `send` has no blocking variant on the fire path, by
    /// design — a timer must not be able to stall the wheel.
    ///
    /// A fourth reason, and a fourth number, because it is none of the other
    /// three: no producer was refused (`messages_dropped`), no message was ever
    /// accepted and then abandoned (`messages_discarded_on_stop`), and the timer
    /// did fire (`timers_discarded`). The `error.Full` half overlaps
    /// `messages_dropped` by construction — the same `send` bumps the mailbox's
    /// own counter — which is precisely why this one exists: only this reading
    /// separates "a producer is under backpressure" from "a fired timer's
    /// message never arrived". See docs/RUNTIME.md §5.
    timer_deliveries_dropped: u64,
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
        /// Messages counted instead of run when this worker stopped — see
        /// `countAbandoned`. Atomic because `stats()` reads it from another
        /// thread (a scrape, most of the time).
        discarded_on_stop: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Mailbox length `countAbandoned` has already reported. Bookkeeping for
        /// its delta (see there), not a second reading of the counter above.
        counted_at_stop: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        supervision: Supervision = .{},
        /// Supervisor bookkeeping. Owned by the worker's own thread (only it
        /// handles messages), so plain fields — no atomics.
        errors_in_window: u32 = 0,
        window_start_ms: i64 = 0,
        stopped_by_supervisor: bool = false,
        joined: bool = false,
        /// Set for `.pooled` workers only: the scheduler that runs this worker,
        /// plus the bits it shares with it (`claimed`/`queued`). Null for a
        /// dedicated worker, whose readiness the mailbox's own condition
        /// variable carries — `announceReady` is then one predictable branch and
        /// the ready ring sees nothing at all (docs/RUNTIME.md §12.4).
        pool: ?scheduler_mod.Ready = null,
        /// `.pooled` only: true while a pool thread is executing this worker.
        /// This is §12.3's state exclusivity — an exclusive declaration instead
        /// of thread identity (D4). Never set on a dedicated worker.
        claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// `.pooled` only: true while a token for this worker is in the ready
        /// ring. "At most one token per worker" is what bounds the ring's
        /// occupancy, and therefore what makes a push infallible (D4).
        queued: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// `.pooled` only: set when the worker's lifecycle started on the pool
        /// thread (`init` ran, or was attempted). A pooled worker has no thread
        /// that starts at `spawn`, so this is what the destroy path reads to
        /// decide whether a `deinit` is owed.
        started: bool = false,

        pub fn send(self: *Self, message: Message) mbox.SendError!void {
            try self.mailbox.send(.{ .message = message });
            self.announceReady();
        }

        pub fn sendBlocking(self: *Self, message: Message, timeout_ms: u32) mbox.SendError!void {
            try self.mailbox.sendBlocking(.{ .message = message }, timeout_ms);
            self.announceReady();
        }

        /// `send`, with the trace id of the work that produced the message
        /// attached. The worker reads it back with `ctx.traceId()` while it
        /// handles *this* message: the value travels in the mailbox slot, so two
        /// producers sending different traces cannot overwrite each other's.
        pub fn sendTraced(self: *Self, message: Message, trace: TraceId) mbox.SendError!void {
            try self.mailbox.send(.{ .trace = trace, .message = message });
            self.announceReady();
        }

        /// `sendBlocking`, with a trace attached — for the producer that would
        /// rather wait for room than drop. Backpressure is exactly when losing
        /// the trace hurts most: the messages that arrive late are the ones you
        /// want to attribute.
        pub fn sendBlockingTraced(self: *Self, message: Message, trace: TraceId, timeout_ms: u32) mbox.SendError!void {
            try self.mailbox.sendBlocking(.{ .trace = trace, .message = message }, timeout_ms);
            self.announceReady();
        }

        /// Producer side of the pooled hand-off, and the *only* difference
        /// between a dedicated `send` and a pooled one: a dedicated worker's
        /// readiness is its thread parked in `recv`, a pooled worker's is a token
        /// in the ready ring. Signature and backpressure are unchanged — a full
        /// mailbox still comes back as `error.Full` from `send`, before this
        /// line, and nothing here allocates (§4's zero-allocation contract).
        fn announceReady(self: *Self) void {
            const item = self.pool orelse return; // `.dedicated`: the mailbox signal is the whole story
            scheduler_mod.announce(item);
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
        ///
        /// **Delivery can still fail after all of this succeeded**, and `after`
        /// is long gone by then: the mailbox may be closed (the worker stopped)
        /// or full when the timer comes due, and the fire path cannot block on it
        /// without letting a timer stall the ticker. That is a lost *delivery*,
        /// not a lost timer, and it is counted — `RuntimeStats.timer_deliveries_dropped`,
        /// plus a debug line naming the worker. See `docs/RUNTIME.md` §5.
        pub fn after(self: *Self, delay_ms: i64, message: Message) !wheel_mod.Wheel(TimerAction).Id {
            const Delivery = struct {
                handle: *Self,
                message: Message,
                trace: ?TraceId,
                fn post(ctx: *anyopaque) void {
                    const d: *@This() = @ptrCast(@alignCast(ctx));
                    // A timer must not be able to stall the ticker, so a full or
                    // closed mailbox drops the message — but a lost *delivery*
                    // is not a lost *fire*: the timer ran, the message did not
                    // arrive, and that difference is what this counter keeps
                    // (see `RuntimeStats.timer_deliveries_dropped`). It goes on
                    // the runtime rather than on the worker, because the
                    // `error.Closed` half is "that worker is already gone" —
                    // the one place a per-worker number would be unreadable
                    // exactly when it matters. The debug line stays for the
                    // "which worker" half that a number cannot carry.
                    d.handle.mailbox.send(.{ .trace = d.trace, .message = d.message }) catch |err| {
                        _ = d.handle.runtime.timer_deliveries_dropped.fetchAdd(1, .monotonic);
                        std.log.debug(
                            "[runtime] timer delivery to {s} dropped: {s}",
                            .{ d.handle.context.name, @errorName(err) },
                        );
                    };
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

        /// Count — and deliberately *not* run — whatever is still in the mailbox
        /// at a point where this worker can never `recv` again: its own loop has
        /// returned (dedicated), or the pool that would have dispatched it has
        /// (`Runtime.shutdown`'s teardown). Nobody is going to handle those
        /// messages, so the least this can do is leave a number (§5's rule), on
        /// the worker *and* on the runtime — the handle is destroyed by the very
        /// `shutdown` that abandoned them, so a per-worker counter alone would be
        /// unreadable exactly when it matters.
        ///
        /// **Idempotent, by taking the increase since the last call.** The ring
        /// only ever loses messages to `recv`, which is over by the time anyone
        /// calls this, so "len went up" can only mean messages that arrived
        /// after a previous call — which is the `close()`-vs-`send` window (a
        /// producer that read `closed == false` just before the stop can still
        /// push). Counting the total every time would report the same loss twice;
        /// counting only the delta reports every loss once, including that one.
        ///
        /// The messages themselves stay parked rather than being drained out:
        /// they are plain values (the ring dies with the handle), and leaving
        /// them keeps `mailbox_len` honest about where the work went. Draining
        /// would also mean counting them as `received`, which they are not —
        /// `received` means "a worker pulled this out to handle it".
        fn countAbandoned(self: *Self) void {
            const left = self.mailbox.len();
            const counted = self.counted_at_stop.load(.monotonic);
            if (left <= counted) return;
            self.counted_at_stop.store(left, .monotonic);
            const increase = left - counted;
            _ = self.discarded_on_stop.fetchAdd(increase, .monotonic);
            _ = self.runtime.messages_discarded_on_stop.fetchAdd(increase, .monotonic);
        }

        pub fn stats(self: *Self) WorkerStats {
            const ms = self.mailbox.stats();
            return .{
                .name = self.context.name,
                // `running` means "this worker is being executed right now":
                // for a dedicated worker that is its thread having started (and
                // not yet joined), for a pooled one it is the claim — which is
                // also why the pooled total can never exceed the number of pool
                // threads (docs/RUNTIME.md §12.9).
                .running = if (self.pool != null)
                    self.claimed.load(.acquire)
                else
                    self.thread != null and !self.joined,
                .mailbox_capacity = capacity,
                .mailbox_len = ms.len,
                .sent = ms.sent,
                .received = ms.received,
                .dropped_full = ms.dropped_full,
                .discarded_on_stop = self.discarded_on_stop.load(.monotonic),
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
            } else if (self.pool) |link| {
                // A pooled worker has no thread of its own, so "joined" has to
                // mean both halves of "there is nothing left to run for it": no
                // pool thread is executing it, and no message is still waiting in
                // its mailbox. The second half is what a dedicated `join` gets for
                // free (the loop only returns once its mailbox is drained), and
                // without it `join` would report a worker finished while a whole
                // batch of its messages is still queued — the claim is released
                // between batches (D5).
                //
                // The `stopping` escape hatch is not an optimisation: `Runtime
                // .shutdown` stops the pool *first* (§12.6), so a worker can
                // legitimately still hold messages at that point, and there is
                // nobody left to drain them. Waiting for the mailbox there would
                // hang the shutdown. What those messages are is counted by
                // `Runtime.shutdown`, which owns the fact that the pool is gone
                // (`countAbandoned`, through the entry's `abandon` thunk).
                while (self.claimed.load(.acquire) or
                    (self.mailbox.len() != 0 and !link.scheduler.stopping.load(.acquire)))
                {
                    // Spins rather than parking: this is a startup/shutdown-path
                    // call, and a condition variable here would put a signal on
                    // the hand-back's hot path for nobody.
                    std.atomic.spinLoopHint();
                }
            }
            self.joined = true;
        }

        fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.join();
            // A pooled worker has no thread that ends its lifecycle, so its
            // `deinit` hook runs here: after the pool has been stopped and after
            // the claim was handed back (`Runtime.shutdown` fixes that order),
            // i.e. at the only moment `state` is provably unowned. `started`
            // keeps "deinit only what was initialised" true — a pooled worker
            // that never received a message never ran `init`, and gets no
            // `deinit`. A failed `init` still gets one, exactly as in
            // `workerMain`.
            if (self.pool != null and self.started and @hasDecl(W, "deinit")) W.deinit(&self.state);
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
    /// Timers released without firing at shutdown. Written from the shutdown
    /// path (the ticker's last act, or `shutdown` itself on the caller-driven
    /// configuration), read by `stats()` — hence an atomic.
    timers_discarded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Timer fires whose message the target mailbox refused (see
    /// `RuntimeStats.timer_deliveries_dropped`). Accumulated here rather than
    /// summed over the live workers, for the same reason
    /// `messages_discarded_on_stop` is: the `error.Closed` half is written while
    /// the worker is already stopped, so a per-worker sum would lose it.
    timer_deliveries_dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Messages accepted into a worker's mailbox and then abandoned when that
    /// worker stopped (see `Handle.countAbandoned`). Accumulated on the runtime
    /// rather than summed over the live workers — the shape `messages_dropped`
    /// has — because destroying the worker is part of what produced the loss:
    /// `shutdown` joins and destroys in one pass, so a per-worker sum would read
    /// 0 for exactly the loss this counter exists to make visible.
    messages_discarded_on_stop: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timer_lag_max_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// The pool behind `.mode = .pooled`, present only when it was declared at
    /// construction (`Runtime.initWithOptions`). Null — the default — means this
    /// runtime runs no pool thread at all and `.pooled` is a configuration error
    /// (docs/RUNTIME.md §12.8 D2).
    scheduler: ?*Scheduler = null,

    const Entry = struct {
        ptr: *anyopaque,
        name: []const u8,
        request_stop: *const fn (*anyopaque) void,
        join: *const fn (*anyopaque) void,
        /// Count whatever a worker still had queued once nothing can serve it
        /// any more — after every `join`, before every `destroy`. Idempotent
        /// with the dedicated loop's own call, so this is both the pooled
        /// counting point and the backstop for a message that raced the stop.
        abandon: *const fn (*anyopaque) void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
        stats: *const fn (*anyopaque) WorkerStats,
        /// Whether a pool thread still holds this worker's claim. Read once, at
        /// shutdown, between joining the pool and destroying the worker — the
        /// check §12.6 asks for ("confirm every ownership was handed back").
        claimed: *const fn (*anyopaque) bool,
    };

    /// How often the ticker wakes to fire timers. One level-0 spoke is 10 ms;
    /// ticking at half that keeps a 10 ms timer within ~5 ms of its deadline.
    ///
    /// A timer armed with `after(delay_ms)` therefore fires somewhere in
    /// `[delay_ms, delay_ms + enqueue latency + tick_interval_ms]` — see
    /// `docs/RUNTIME.md` §3.
    pub const tick_interval_ms: u32 = 5;

    /// How a runtime is constructed when it needs more than "a clock".
    pub const InitOptions = struct {
        clock: Clock = .monotonic,
        /// Declare the pool (docs/RUNTIME.md §12.8 D2). Left at its default the
        /// runtime owns no pool at all: no ring, no thread, and `.mode = .pooled`
        /// is a configuration error at `spawn` rather than a thread appearing
        /// behind the caller's back.
        scheduler: SchedulerConfig = .{},
    };

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

    /// `init` plus the pool declaration. Fallible because a declared pool
    /// allocates its ready ring here, sized from the declared bound — see the
    /// capacity invariant in `scheduler.zig` (that sizing is what makes a token
    /// push infallible, so it cannot be deferred to a constant).
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: InitOptions,
    ) !Self {
        var self = init(allocator, io, options.clock);
        if (options.scheduler.max_pooled_workers != 0) {
            self.scheduler = try Scheduler.init(allocator, io, options.scheduler);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.wheel.deinit();
        self.workers.deinit(self.allocator);
        // Last: `shutdown` stops the pool thread, but tokens that arrived while
        // it was winding down are still in the ring, and nothing reads them
        // again — the pool is the ring's only consumer.
        if (self.scheduler) |sched| sched.deinit();
        self.scheduler = null;
        self.* = undefined;
    }

    /// Start the ticker so timers fire without help. Optional: a caller that
    /// drives `tick()` itself (tests, an event loop that already has a clock)
    /// should not start it.
    ///
    /// The wheel's clock is *not* touched here: `start()` runs on the caller's
    /// thread, which is not the wheel's owner. The ticker aligns it when it
    /// takes the wheel (see `tickerMain`).
    ///
    /// The pool thread is *not* started here either: it appears with the first
    /// pooled `spawn`, so a runtime that declares a pool and never uses it still
    /// starts no thread (D2).
    pub fn start(self: *Self) !void {
        if (self.ticker_running.swap(true, .acquire)) return; // already started
        self.ticker = try std.Thread.spawn(.{}, tickerMain, .{self});
    }

    /// Stop the ticker, then the pool, then every worker (request + join +
    /// destroy). Idempotent.
    ///
    /// **The ticker goes first, and the order is load-bearing.** A timer's
    /// payload delivers into the `*Handle` that armed it (`Handle.after`'s
    /// `Delivery.post`), and the worker's teardown frees that handle. A ticker
    /// still running while the handles are being freed would therefore post into
    /// freed memory the moment a timer came due inside that window — and the
    /// window is not theoretical: it lasts as long as joining every worker takes.
    ///
    /// Joining the ticker first also settles what happens to the timers: its last
    /// act before returning is `drainWheel` (see `tickerMain`), so by the time
    /// the join returns the wheel is empty and those payloads were *dropped*, not
    /// posted to a handle the next lines are about to free. After `alive = false`
    /// a timer's message has no live owner anyway, so dropping is the honest
    /// answer — and it is counted (`RuntimeStats.timers_discarded`).
    ///
    /// **The pool goes second** (§12.6, §12.9): a pool thread can be inside a
    /// worker's `handle` right now, holding that worker's `claimed`. Destroying
    /// workers first would free a `*Handle` a pool thread is still running. The
    /// join is what makes "every claim is handed back" true, and the assertion
    /// after it is what keeps the claim from becoming a comment nobody checks.
    pub fn shutdown(self: *Self) void {
        self.alive.store(false, .release);

        // Stop the wheel's driver before touching anything `post` could reach.
        // See the doc comment above: the join is what makes "no timer can fire
        // after this line" true rather than likely.
        if (self.ticker_running.swap(false, .acquire)) {
            self.mu.lock(self.io) catch return;
            self.idle.broadcast(self.io);
            self.mu.unlock(self.io);
            if (self.ticker) |t| {
                t.join();
                self.ticker = null;
            }
        }

        // Then the pool: it can be running a worker whose handle the lines below
        // are about to free. `Scheduler.shutdown` waits for the batch in flight
        // to finish (a worker that never returns still blocks shutdown — §4's
        // rule, kept).
        if (self.scheduler) |sched| {
            sched.shutdown();
            for (self.workers.items) |entry| {
                // A pooled worker has no thread, so `join` cannot have waited for
                // anything; the claim is the only thing that says "a pool thread
                // still owns this state". It must be false here, and if it ever
                // is not, the next lines would free memory a live thread is
                // running. Debug/ReleaseSafe turn it into a call-site panic;
                // ReleaseFast keeps the destruction as-is (the same trade the
                // wheel's owner assertions make).
                std.debug.assert(!entry.claimed(entry.ptr));
            }
        }

        // Ask first, join after: a worker that is waiting on another worker's
        // message gets its stop signal before anyone blocks on a join.
        for (self.workers.items) |entry| entry.request_stop(entry.ptr);
        for (self.workers.items) |entry| entry.join(entry.ptr);
        // The joins above are what make this the last word: no thread is left to
        // `recv` (dedicated) and no pool is left to dispatch (pooled). Anything
        // still queued is therefore unreachable, and counted here rather than
        // walked past — this is the pooled half of the loss, which has no other
        // moment that could report it (a pooled worker's supervisor stop drains
        // the mailbox; the pool going down first is the case it cannot).
        // `countAbandoned` takes only the increase, so running it for a
        // dedicated worker that already counted at its loop exit changes nothing.
        for (self.workers.items) |entry| entry.abandon(entry.ptr);
        for (self.workers.items) |entry| entry.destroy(entry.ptr, self.allocator);
        self.workers.clearRetainingCapacity();

        // Nobody is driving the wheel any more, so commands still in flight will
        // never become timers — and their payloads are owned by this queue until
        // one of the two happens. Release them (the `drop` half of the fire/cancel
        // contract) so a shutdown with a full command queue is not a leak.
        // Then the same for what already made it onto the wheel: with a ticker
        // that is the ticker's own doing (see `tickerMain`), so this is a no-op
        // there and the real work on the caller-driven configuration.
        self.abandonTimerCommands();
        self.drainWheel();
        self.wakeTimerWaiters();
    }

    /// Spawn `W` with a mailbox capacity of `capacity` slots and `.mode =
    /// .dedicated`. `initial_state` is moved onto the heap (a worker's thread
    /// must never see a stack copy).
    ///
    /// The last parameter also accepts a `SpawnConfig`, which is the pooled form:
    ///
    /// ```zig
    /// const handle = try rt.spawn(AuditWorker, .{}, .{ .capacity = 64, .mode = .pooled });
    /// ```
    pub fn spawn(
        self: *Self,
        comptime W: type,
        initial_state: W,
        comptime config: anytype,
    ) !*Handle(W, spawnConfig(config).capacity) {
        return self.spawnSupervised(W, initial_state, config, .{});
    }

    /// Spawn an **actor**: same contract as a worker, but the runtime supervises
    /// it — a bounded error budget inside a window, and a stop when the budget is
    /// spent. Defaults differ from `spawn` on purpose: an actor that keeps
    /// failing is stopped rather than left burning a core.
    pub fn spawnActor(
        self: *Self,
        comptime W: type,
        initial_state: W,
        comptime config: anytype,
        supervision: Supervision,
    ) !*Handle(W, spawnConfig(config).capacity) {
        return self.spawnSupervised(W, initial_state, config, supervision);
    }

    pub fn spawnSupervised(
        self: *Self,
        comptime W: type,
        initial_state: W,
        comptime config: anytype,
        supervision: Supervision,
    ) !*Handle(W, spawnConfig(config).capacity) {
        const spawn_config = comptime spawnConfig(config);
        const capacity = comptime spawn_config.capacity;
        const pooled = comptime spawn_config.mode == .pooled;
        // `comptime (...)`, not `pooled and …`: a `@compileError` branch is
        // analysed unless the *condition* is a comptime expression — a plain
        // `if` over a comptime-known bool still reports the error (measured).
        if (comptime (pooled and !poolable(W))) @compileError(
            @typeName(W) ++ " cannot be pooled: it declares `run`, which owns a loop of its own — " ++
                "a pool thread running it would be occupied for as long as it runs (docs/RUNTIME.md §12.5). " ++
                "Declare `pub const Message` + `pub fn handle` to pool a worker, or leave it `.dedicated`.",
        );

        // A pool has to have been declared; `.pooled` without one is a
        // configuration mistake, not something to paper over by starting a
        // thread (D2).
        var sched: ?*Scheduler = null;
        if (pooled) sched = self.scheduler orelse return error.PoolNotConfigured;
        // ...and the declaration is a hard bound, not a hint: the ready ring's
        // capacity is derived from it, so admitting one worker more than it says
        // would make a token push fail — which strands a worker (see the
        // capacity invariant in `scheduler.zig`).
        if (sched) |s| try s.reserve();
        errdefer if (sched) |s| s.release();

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
        if (comptime pooled) {
            // Comptime-gated: a dedicated instantiation does not even analyse
            // this, which is what lets `pooledDispatch` assume `W.handle` exists
            // while `spawnSupervised` still serves `run`-owned workers.
            if (sched) |s| handle.pool = .{
                .scheduler = s,
                .ctx = @ptrCast(handle),
                .claimed = &handle.claimed,
                .queued = &handle.queued,
                .dispatch = pooledDispatch(W, H),
                .pending = pooledPending(H),
            };
        }

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
            .claimed = struct {
                fn f(p: *anyopaque) bool {
                    const h: *H = @ptrCast(@alignCast(p));
                    return h.claimed.load(.acquire);
                }
            }.f,
            .abandon = struct {
                fn f(p: *anyopaque) void {
                    const h: *H = @ptrCast(@alignCast(p));
                    h.countAbandoned();
                }
            }.f,
        });
        // From here the spawn owns a slot, an entry and a handle; every failure
        // path below gives all three back. (Keeping the cleanup in `errdefer`
        // rather than in each `catch` is what makes them run exactly once: a
        // `catch` that frees the handle *and* returns an error would free it
        // again here.)
        errdefer _ = self.workers.pop();

        if (sched) |s| {
            // Materialise the pool thread on first use (D2: declaring a pool you
            // never use costs no thread).
            try s.start();
        } else {
            handle.thread = try std.Thread.spawn(.{}, workerMain(W, capacity), .{handle});
        }
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
            // From the runtime's accumulator, not from the loop above: that
            // counter is written where the abandonment happens precisely so it
            // does not need the worker to still exist (see the field).
            .messages_discarded_on_stop = self.messages_discarded_on_stop.load(.monotonic),
            .handler_errors = errors,
            .timer_fires = self.timer_fires.load(.monotonic),
            .timers_discarded = self.timers_discarded.load(.monotonic),
            .timer_deliveries_dropped = self.timer_deliveries_dropped.load(.monotonic),
            .timer_lag_max_ms = self.timer_lag_max_ms.load(.monotonic),
        };
    }

    /// The pool's own counters: ring depth and high-water, claim misses, refused
    /// pushes, idle polls. Null when this runtime has no pool.
    ///
    /// `RuntimeStats` answers "how are the workers doing"; this answers "is the
    /// scheduler keeping up" — and one number in it is a contract rather than a
    /// metric: `ready_push_failures` must stay `0`. A refused token push does not
    /// lose a message, it loses a *worker* (see the capacity invariant in
    /// `scheduler.zig`), so a non-zero value here is a bug to fix, not a
    /// backpressure reading to tune.
    pub fn poolStats(self: *Self) ?Scheduler.Stats {
        const sched = self.scheduler orelse return null;
        return sched.stats();
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
    ///
    /// The pool's counters (`docs/RUNTIME.md` §12) come from `poolStats()` and
    /// are the half `RuntimeStats` cannot show: it counts *workers*, and after
    /// poolization "how many workers exist" no longer answers "how much work is
    /// in flight" — `pool_claimed` does, and `pool_ready_push_failures` is the
    /// one number here that is a contract rather than a reading. A runtime with
    /// no pool reports zeros for all of them rather than dropping the series:
    /// "0 = no pool declared" is the first question a dashboard asks.
    pub fn MetricsBridge(comptime MetricsT: type) type {
        return struct {
            const Bridge = @This();

            rt: *Runtime,
            workers: *MetricsT.Gauge,
            running: *MetricsT.Gauge,
            messages_sent: *MetricsT.Gauge,
            messages_received: *MetricsT.Gauge,
            messages_dropped: *MetricsT.Gauge,
            messages_discarded_on_stop: *MetricsT.Gauge,
            handler_errors: *MetricsT.Gauge,
            timer_fires: *MetricsT.Gauge,
            timers_discarded: *MetricsT.Gauge,
            timer_deliveries_dropped: *MetricsT.Gauge,
            timer_lag_ms: *MetricsT.Gauge,
            pool_declared: *MetricsT.Gauge,
            pool_threads: *MetricsT.Gauge,
            pool_ready_len: *MetricsT.Gauge,
            pool_claimed: *MetricsT.Gauge,
            pool_dispatches: *MetricsT.Gauge,
            pool_ready_push_failures: *MetricsT.Gauge,

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
                    .messages_discarded_on_stop = try metrics.createGauge("zigmodu_runtime_messages_discarded_on_stop", "Messages accepted and then abandoned when their worker stopped (not the same event as messages_dropped)"),
                    .handler_errors = try metrics.createGauge("zigmodu_runtime_handler_errors", "Worker handler errors observed"),
                    .timer_fires = try metrics.createGauge("zigmodu_runtime_timer_fires", "Timers fired"),
                    .timers_discarded = try metrics.createGauge("zigmodu_runtime_timers_discarded", "Timers released unfired at shutdown"),
                    .timer_deliveries_dropped = try metrics.createGauge("zigmodu_runtime_timer_deliveries_dropped", "Timers that fired but whose message the target mailbox refused (closed or full): a fire, not a delivery"),
                    .timer_lag_ms = try metrics.createGauge("zigmodu_runtime_timer_lag_ms", "Worst lateness between a timer deadline and its firing, in milliseconds"),
                    .pool_declared = try metrics.createGauge("zigmodu_runtime_pool_declared", "Declared upper bound on .pooled workers (0 = no pool: no ring, no pool thread)"),
                    .pool_threads = try metrics.createGauge("zigmodu_runtime_pool_threads", "Pool threads running (Phase 1: 0 or 1); the ceiling on pool_claimed"),
                    .pool_ready_len = try metrics.createGauge("zigmodu_runtime_pool_ready_len", "Ready-ring occupancy: workers waiting for a pool thread, at most one token per worker"),
                    .pool_claimed = try metrics.createGauge("zigmodu_runtime_pool_claimed", "Pooled workers a pool thread is executing right now (never above pool_threads)"),
                    .pool_dispatches = try metrics.createGauge("zigmodu_runtime_pool_dispatches", "Batches the pool thread ran (0 with pooled spawns means they never reached the pool)"),
                    .pool_ready_push_failures = try metrics.createGauge("zigmodu_runtime_pool_ready_push_failures", "MUST stay 0: a refused token push strands a worker (scheduler desync, not backpressure)"),
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
                self.messages_discarded_on_stop.set(@floatFromInt(s.messages_discarded_on_stop));
                self.handler_errors.set(@floatFromInt(s.handler_errors));
                self.timer_fires.set(@floatFromInt(s.timer_fires));
                self.timers_discarded.set(@floatFromInt(s.timers_discarded));
                self.timer_deliveries_dropped.set(@floatFromInt(s.timer_deliveries_dropped));
                self.timer_lag_ms.set(@floatFromInt(s.timer_lag_max_ms));

                // `null` pool = zeros, not absent: the series answering "did
                // anyone declare a pool here" is the same series that carries
                // the reading when they did.
                const p = self.rt.poolStats();
                self.pool_declared.set(@floatFromInt(if (p) |x| x.max_pooled_workers else 0));
                self.pool_threads.set(@floatFromInt(if (p) |x| x.pool_threads else 0));
                self.pool_ready_len.set(@floatFromInt(if (p) |x| x.ready_len else 0));
                self.pool_claimed.set(@floatFromInt(if (p) |x| x.claimed else 0));
                self.pool_dispatches.set(@floatFromInt(if (p) |x| x.dispatches else 0));
                self.pool_ready_push_failures.set(@floatFromInt(if (p) |x| x.ready_push_failures else 0));
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
    /// as a cancel would drop it, and counted exactly as `drainWheel` counts the
    /// ones that got further — from the caller's side both are "the timer I
    /// armed never ran". A queued cancel is answered "no" so a waiter does not
    /// hang on a wheel that is going away.
    fn abandonTimerCommands(self: *Self) void {
        while (self.timer_commands.tryPop()) |cmd| {
            switch (cmd) {
                .arm => |arm| {
                    arm.action.drop(arm.action.ctx, self.allocator);
                    _ = self.timers_discarded.fetchAdd(1, .monotonic);
                },
                .cancel => |cancel| {
                    if (cancel.result) |result| result.store(false, .monotonic);
                    if (cancel.done) |done| done.store(true, .release);
                },
            }
        }
    }

    /// Release every timer still pending in the wheel, and count them.
    ///
    /// The wheel's owner is the only thread allowed to write it, so which
    /// thread runs this is not a detail:
    ///
    /// * with a ticker, that thread runs it as its last act (`tickerMain`), and
    ///   the `join` in `shutdown` waits for it — so this call finds an empty
    ///   wheel;
    /// * without a ticker, whoever calls `tick()` owns the wheel, and `shutdown`
    ///   is expected to come from that same thread (the caller-driven
    ///   configuration of `docs/RUNTIME.md` §4).
    ///
    /// A wheel owned by some *other* thread is left alone: writing it from here
    /// is precisely the cross-thread violation the ownership contract exists to
    /// prevent. That combination is a misuse of `tick()`, and it is reported
    /// rather than dropped quietly.
    ///
    /// Idempotent: once nothing is pending it returns without touching the owner
    /// check, which is what keeps a second `shutdown()` free of side effects.
    fn drainWheel(self: *Self) void {
        const pending = self.wheel.pendingCount();
        if (pending == 0) return;
        const owner = self.wheel.ownerThread();
        if (owner != 0 and owner != std.Thread.getCurrentId()) {
            std.log.warn(
                "[runtime] shutdown: {d} timer payload(s) still pending in a wheel owned by another thread ({d}); only its owner may release them",
                .{ pending, owner },
            );
            return;
        }
        const discarded = self.wheel.drainAll(self, onTimerDiscard);
        _ = self.timers_discarded.fetchAdd(discarded, .monotonic);
    }

    /// The wheel's drop hook on the shutdown path — the same release the fire
    /// and cancel paths perform, for a timer that will never run.
    fn onTimerDiscard(self: *Runtime, id: u64, action: TimerAction) void {
        _ = id;
        action.drop(action.ctx, self.allocator);
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
        // A fire that lands while the runtime is going away must not reach
        // `post`: that callback delivers into the handle which armed the timer,
        // and `shutdown` frees those handles. `shutdown` itself stops the ticker
        // *before* it touches a worker (see its doc comment), so the primary
        // ordering guard lives there; this is the cheap second one, covering the
        // arrangements that ordering cannot cover — a `tick()` caller on another
        // thread racing a `shutdown()` (a misuse the ownership contract in
        // `docs/RUNTIME.md` §4 already forbids, but `post` into freed memory is
        // too expensive an answer to a misuse).
        //
        // A dropped fire is not a fire: it is released through the same `drop`
        // the cancel and shutdown paths use, and counted the same way, so a timer
        // that never ran never disappears without a number.
        if (!self.alive.load(.acquire)) {
            action.drop(action.ctx, self.allocator);
            _ = self.timers_discarded.fetchAdd(1, .monotonic);
            return;
        }

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

        // Whoever ends this loop — `shutdown()` setting `ticker_running`, or an
        // error on the way to the sleep — this thread is the wheel's owner, so
        // releasing what is still pending has to happen here: `shutdown` is
        // waiting in `join()` and could not do it without writing another
        // thread's wheel. `defer` rather than a trailing call so every exit path
        // gets it, including the `catch return`s below.
        defer self.drainWheel();

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

            startWorker(W, H, handle);

            if (@hasDecl(W, "Message") and @hasDecl(W, "handle")) {
                // Message-driven: the runtime owns the receive loop.
                while (true) {
                    if (handle.stop_requested.load(.acquire) and handle.mailbox.len() == 0) break;
                    const envelope = handle.mailbox.recv(0) orelse {
                        if (handle.mailbox.isClosed()) break;
                        continue;
                    };
                    if (!deliver(W, H, handle, envelope)) break;
                }
            } else if (@hasDecl(W, "run")) {
                // Loop-owned: the worker decides when to finish.
                W.run(&handle.state, &handle.context) catch |err| {
                    _ = supervise(W, H, handle, err);
                };
            } else {
                @compileError("worker " ++ @typeName(W) ++ " declares neither " ++
                    "`pub const Message` + `pub fn handle(self, msg, ctx)` nor `pub fn run(self, ctx)`");
            }

            // Anything still in the mailbox at this point is work that was
            // accepted and will never be handled. Both ways of getting here are
            // real: a supervisor stop breaks the receive loop with a queue still
            // behind it (a plain `stop()` drains first — the check at the top of
            // the loop — so it arrives here empty), and a `run`-owned worker
            // never recv's at all. Counted, not run: an actor on its way down is
            // not supposed to keep working, but it is not allowed to lose the
            // number either (docs/RUNTIME.md §5, §12.10).
            handle.countAbandoned();

            if (@hasDecl(W, "deinit")) W.deinit(&handle.state);
        }
    }.main;
}

/// The optional `init` hook, plus the bookkeeping around a failure. Called once
/// per worker lifecycle: by `workerMain` on the worker's own thread, and by
/// `pooledDispatch` on the pool thread that first runs a pooled worker — which is
/// the earliest moment a pooled worker owns a thread, and the only one at which
/// running `init` cannot race its own `handle`.
///
/// A failure here is fatal for the worker (there is no half-started state to
/// supervise), but it still counts and stops.
fn startWorker(comptime W: type, comptime H: type, handle: *H) void {
    if (!@hasDecl(W, "init")) return;
    W.init(&handle.state, &handle.context) catch |err| {
        var tag_buf: [trace_tag_len]u8 = undefined;
        // No message is being handled yet, so the tag is always empty here —
        // carried anyway so every runtime error line has the same shape and the
        // same grep.
        std.log.err("[runtime] {s}.init failed{s}: {s}", .{
            @typeName(W), traceTag(handle.context.traceId(), &tag_buf), @errorName(err),
        });
        _ = handle.handler_errors.fetchAdd(1, .monotonic);
        handle.stop();
    };
}

/// One message through `W.handle`: the trace is published for exactly as long as
/// *this* message runs (so a handler can neither see a previous message's trace
/// nor leak this one into whatever it schedules afterwards), and a returned error
/// goes through supervision. Returns false when the worker must stop serving.
///
/// Shared by the dedicated loop (`workerMain`) and the pooled batch
/// (`pooledDispatch`) on purpose: the two modes differ in *who* runs a worker,
/// never in what running it means.
fn deliver(comptime W: type, comptime H: type, handle: *H, envelope: H.Envelope) bool {
    var keep_serving = true;
    {
        defer handle.context.current_trace = null;
        handle.context.current_trace = envelope.trace;
        W.handle(&handle.state, envelope.message, &handle.context) catch |err| {
            if (supervise(W, H, handle, err)) keep_serving = false;
        };
    }
    return keep_serving;
}

/// `Ready.dispatch` for `H` — one bounded batch of a pooled worker's loop.
///
/// Returns true when the mailbox gave nothing (empty, or closed and drained) and
/// false when the batch bound ended the call, which is what tells the scheduler
/// whether there may still be work when it hands the worker back.
fn pooledDispatch(comptime W: type, comptime H: type) *const fn (*anyopaque, usize) bool {
    return struct {
        fn run(ctx: *anyopaque, max: usize) bool {
            const handle: *H = @ptrCast(@alignCast(ctx));

            // §4's owner contract, pooled flavour: *this* thread owns the worker
            // while it runs it. That is the answer `Handle.after`'s trace
            // inheritance needs ("am I the worker's thread?"), and 0 afterwards
            // says "no message is being handled here" — the same reading a
            // dedicated worker has between messages.
            handle.context.owner.store(std.Thread.getCurrentId(), .release);
            defer handle.context.owner.store(0, .release);

            // The lifecycle starts with the first batch, inside the claim: from
            // here on this worker is exclusively owned, exactly as a dedicated
            // worker's thread owns it when `workerMain` runs `init`.
            if (!handle.started) {
                // Set before the hook, so a failed `init` still gets its
                // `deinit` — the pairing `workerMain` has.
                handle.started = true;
                startWorker(W, H, handle);
            }

            var ran: usize = 0;
            while (ran < max) {
                const envelope = handle.mailbox.tryRecv() orelse return true;
                ran += 1;
                if (!deliver(W, H, handle, envelope)) break;
            }
            return false;
        }
    }.run;
}

/// `Ready.pending` for `H`: the hand-back's re-check, and nothing else. A length
/// read rather than a receive, so the runner never consumes what it is deciding
/// about.
fn pooledPending(comptime H: type) *const fn (*anyopaque) usize {
    return struct {
        fn count(ctx: *anyopaque) usize {
            const handle: *H = @ptrCast(@alignCast(ctx));
            return handle.mailbox.len();
        }
    }.count;
}

/// Record an error and decide whether the worker survives it.
/// Returns true when the caller must stop its loop.
fn supervise(comptime W: type, comptime H: type, handle: *H, err: anyerror) bool {
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

test "Runtime: after(delay) never fires early and lands on the first tick at or after it" {
    // The wheel's fine spokes are 10 ms wide and the ticker wakes every 5 ms, so
    // a deadline with an arbitrary offset falls inside the spoke the wheel is
    // already standing in. The regression: such a timer was reinserted into that
    // same spoke and waited a full rotation (640 ms) — and, on the other side,
    // the spoke walk fired the previous window's leftovers up to a spoke early.
    // Both halves of the documented envelope are asserted here: `>= deadline`
    // (never early) and within one tick (the arm is drained by the first tick,
    // so no enqueue latency is left to spend).
    const delays = [_]i64{ 20, 16, 14, 11, 9, 5 };
    for (delays) |delay| {
        var manual = Clock.Manual{ .now_ms = 1_000 };
        var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &manual });
        defer rt.deinit();

        const handle = try rt.spawn(CounterWorker, .{}, 8);
        _ = try handle.after(delay, 1);
        const deadline = 1_000 + delay;

        // Drive the wheel through `tick()` on the ticker's grid — the same
        // arrangement as a running ticker, without the sleep.
        var fired_at: ?i64 = null;
        var t: i64 = 1_000;
        const tick_interval: i64 = Runtime.tick_interval_ms;
        while (fired_at == null and t <= deadline + 5 * tick_interval) : (t += tick_interval) {
            manual.set(t);
            if (rt.tick() > 0) fired_at = t;
        }

        const at = fired_at orelse return error.TimerNeverFired;
        try std.testing.expect(at >= deadline); // the contract is "at least delay_ms"
        try std.testing.expect(at <= deadline + tick_interval); // and no later than the next tick
        try std.testing.expectEqual(@as(u64, 1), rt.stats().timer_fires);

        // The message — not just the wheel entry — reached the worker.
        var spins: usize = 0;
        while (handle.state.seen == 0 and spins < 4_000_000) : (spins += 1) std.atomic.spinLoopHint();
        try std.testing.expectEqual(@as(u32, 1), handle.state.seen);
        handle.stop();
    }
}

// ── a timer that fired and whose message could not be handed over ─────────
//
// The drop counter §5's list was missing: the timer *did* fire (`timer_fires`
// moved), and the mailbox refused the message anyway. Not a producer being
// refused (`messages_dropped`): there was no producer. Not a message abandoned
// by a stop (`messages_discarded_on_stop`): nothing was ever accepted. Not a
// timer released unfired (`timers_discarded`): the fire happened — that is the
// *other* timer-side number, and the two are complementary ("never fired" vs
// "fired, never arrived").
//
// `send` has exactly two failure modes here — `error.Closed` and `error.Full` —
// so both are exercised below.

test "Runtime: a timer that fires into a closed mailbox is accounted for" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const handle = try rt.spawn(CounterWorker, .{}, 8);
    _ = try handle.after(50, 7);
    _ = rt.tick(); // into the wheel, not due yet

    handle.stop(); // the mailbox closes; the receive loop drains nothing and returns
    handle.join();

    clk.advance(60);
    try std.testing.expectEqual(@as(usize, 1), rt.tick()); // due: fires, and cannot deliver

    const s = rt.stats();
    try std.testing.expectEqual(@as(u64, 1), s.timer_fires); // the timer fired ...
    try std.testing.expectEqual(@as(u32, 0), handle.state.seen); // ... and the message never arrived
    // None of the three existing counters owns it — no producer was refused, no
    // message was ever accepted, and the timer did fire — so the delivery has a
    // counter of its own:
    try std.testing.expectEqual(@as(u64, 0), s.messages_dropped);
    try std.testing.expectEqual(@as(u64, 0), s.messages_discarded_on_stop);
    try std.testing.expectEqual(@as(u64, 0), s.timers_discarded);
    try std.testing.expectEqual(@as(u64, 1), s.timer_deliveries_dropped);
}

test "Runtime: a timer that fires into a full mailbox is accounted for" {
    // The other error `send` can come back with. A `run`-owned worker never
    // recv's, so its mailbox only ever fills — nothing else can be draining it
    // and make this test a race.
    const Spinner = struct {
        pub fn run(self: *@This(), ctx: anytype) anyerror!void {
            _ = self;
            while (!ctx.stopped()) std.atomic.spinLoopHint();
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const handle = try rt.spawn(Spinner, .{}, 4);
    var full_seen = false;
    for (0..64) |_| handle.send({}) catch |err| switch (err) {
        error.Full => {
            full_seen = true;
            break;
        },
        else => return err,
    };
    try std.testing.expect(full_seen);

    _ = try handle.after(50, {});
    _ = rt.tick(); // into the wheel, not due yet
    clk.advance(60);
    try std.testing.expectEqual(@as(usize, 1), rt.tick()); // due: fires, mailbox still full

    const s = rt.stats();
    try std.testing.expectEqual(@as(u64, 1), s.timer_fires);
    // The mailbox's own counter moves too (it is the same `send` that refused a
    // producer a moment ago) — which is exactly why the timer side needs its
    // own: `messages_dropped` cannot tell "a producer was refused" from "a
    // timer's message was refused", and the two are different incidents.
    try std.testing.expectEqual(@as(u64, 1), s.timer_deliveries_dropped);
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

// ── what shutdown does with timers still in the wheel ────────────────────
//
// The runtime owns a timer's payload from the moment the arm command is applied
// until it fires or is cancelled. `shutdown()` is the third exit: everything
// still pending has to be released there, or a process that stops with timers
// armed leaks them. That release can only happen on the wheel's owner thread
// (see the ownership contract in `timer_wheel.zig`), which is why the ticker
// does it on its way out and a caller-driven runtime does it from `shutdown`.
//
// `std.testing.allocator` is the oracle: a payload that is not released is a
// leak the test runner reports on its own, without any assertion in the test.

/// Payload for the shutdown tests. Deliberately non-zero-sized: `create` of a
/// zero-sized type allocates nothing, so a leak would have nothing to leak and
/// the allocator oracle above would stay silent.
const WheelPayload = struct {
    marker: u64 = 0x5eed,

    fn post(ctx: *anyopaque) void {
        const payload: *@This() = @ptrCast(@alignCast(ctx));
        // These tests only observe whether the payload was *released*, never
        // whether it was delivered — touch the marker so the call is not
        // compiled away in a release build.
        std.mem.doNotOptimizeAway(payload.marker);
    }

    fn drop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const payload: *@This() = @ptrCast(@alignCast(ctx));
        allocator.destroy(payload);
    }
};

/// Arm `count` timers, each with a heap payload the runtime owns from here on,
/// all far enough out that none of them fires before the test's shutdown.
fn armStillPending(rt: *Runtime, count: usize, delay_ms: i64) !void {
    for (0..count) |_| {
        const payload = try std.testing.allocator.create(WheelPayload);
        payload.* = .{};
        _ = try rt.scheduleAction(delay_ms, .{
            .ctx = @ptrCast(payload),
            .post = WheelPayload.post,
            .drop = WheelPayload.drop,
        });
    }
}

test "Runtime: shutdown releases timers still in the wheel when the ticker drives it" {
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();
    try rt.start();

    const n = 64;
    try armStillPending(&rt, n, 60_000); // a minute out: none of them fires

    rt.shutdown(); // the ticker owns the wheel; it releases them before the join returns
    try std.testing.expectEqual(@as(u64, n), rt.stats().timers_discarded);
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timer_fires);
}

test "Runtime: shutdown releases timers still in the wheel on the caller-driven path" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const n = 16;
    try armStillPending(&rt, n, 5_000);
    _ = rt.tick(); // the arms become wheel nodes; nothing is due yet
    try std.testing.expectEqual(@as(usize, n), rt.wheel.pendingCount());

    rt.shutdown(); // no ticker: this call runs on the thread that owns the wheel
    try std.testing.expectEqual(@as(u64, n), rt.stats().timers_discarded);
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timer_fires);
}

test "Runtime: shutdown twice with timers still in the wheel releases them once" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const n = 8;
    try armStillPending(&rt, n, 5_000);
    _ = rt.tick();

    rt.shutdown();
    try std.testing.expectEqual(@as(u64, n), rt.stats().timers_discarded);
    rt.shutdown(); // idempotent: nothing left to release, and nothing released twice
    try std.testing.expectEqual(@as(u64, n), rt.stats().timers_discarded);
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());
}

test "Runtime: timers that already fired are not released again at shutdown" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const n = 8;
    try armStillPending(&rt, n, 20);
    _ = rt.tick(); // into the wheel, not due yet
    clk.advance(30);
    try std.testing.expectEqual(n, rt.tick()); // all due: post + drop, exactly once
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());
    try std.testing.expectEqual(@as(u64, n), rt.stats().timer_fires);

    rt.shutdown(); // nothing left: a fired timer must not be released a second time
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timers_discarded);
    try std.testing.expectEqual(@as(usize, 0), rt.wheel.pendingCount());
}

// ── the shutdown window: no timer may reach a handle that is being freed ──
//
// A fire calls `post`, `post` writes into the `*Handle` that armed the timer,
// and `shutdown` frees that handle. So the promise is: past the point where
// handles can be freed, no fire reaches `post` any more. Two independent
// mechanisms carry it — `shutdown` stops the ticker *before* it touches a worker
// (so the fire cannot happen at all), and `onTimerFire` refuses to post once
// `alive` is false (so a fire arriving anyway, e.g. from a `tick()` caller on
// another thread, is dropped).
//
// Both are asserted below, and both assertions are **deterministic**. What is
// deliberately *not* here is a use-after-free reproduction: arranging a fire to
// land inside the free window means timing the wheel against a join, which
// either does not reproduce or corrupts the test process instead of failing an
// assertion. A test that only sometimes proves the point is worse than none.

/// Payload for the fire-path test: records which of the two hooks ran, so "did
/// it post or drop?" is an assertion rather than a guess.
const FireProbe = struct {
    post_calls: usize = 0,
    drop_calls: usize = 0,

    fn post(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.post_calls += 1;
    }

    fn drop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.drop_calls += 1;
    }

    fn action(self: *@This()) TimerAction {
        return .{ .ctx = @ptrCast(self), .post = post, .drop = drop };
    }
};

test "Runtime: a fire past alive=false drops its payload instead of posting it" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    var probe = FireProbe{};
    // Alive first: the ordinary contract is unchanged — post, then drop.
    rt.onTimerFire(1, probe.action());
    try std.testing.expectEqual(@as(usize, 1), probe.post_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.drop_calls);
    try std.testing.expectEqual(@as(u64, 1), rt.stats().timer_fires);

    rt.shutdown(); // alive = false: from here a timer's message has no live owner
    rt.onTimerFire(2, probe.action());
    try std.testing.expectEqual(@as(usize, 1), probe.post_calls); // not one more
    try std.testing.expectEqual(@as(usize, 2), probe.drop_calls);
    // Released, not fired, and *counted*: a payload that was handed to the
    // runtime and never ran shows up in `timers_discarded`, never in
    // `timer_fires`.
    try std.testing.expectEqual(@as(u64, 1), rt.stats().timer_fires);
    try std.testing.expectEqual(@as(u64, 1), rt.stats().timers_discarded);
}

/// Worker for the ordering test: message-driven, so it lives until `shutdown`
/// stops it, and `deinit` is the last thing the runtime calls on it — the handle
/// is freed only after that returns. Whatever `deinit` sees about the wheel is
/// therefore what was true *before* this handle went away.
const OrderProbe = struct {
    pub const Message = void;

    shared: *Shared,

    const Shared = struct {
        /// Set by the pending timer's `drop`, i.e. when the wheel is emptied.
        wheel_emptied: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Set by the pending timer's `post`. Must stay false: a timer pending at
        /// shutdown is released, never delivered into a dying worker.
        posted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        exits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        exits_seeing_empty_wheel: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    };

    pub fn handle(self: *@This(), msg: void, ctx: anytype) anyerror!void {
        _ = self;
        _ = msg;
        _ = ctx;
    }

    pub fn deinit(self: *@This()) void {
        if (self.shared.wheel_emptied.load(.acquire)) {
            _ = self.shared.exits_seeing_empty_wheel.fetchAdd(1, .monotonic);
        }
        _ = self.shared.exits.fetchAdd(1, .monotonic);
    }
};

/// The pending timer of the ordering test. Heap-owned, so the testing allocator
/// doubles as the leak oracle, and its two hooks publish what the runtime did
/// with it.
const DrainProbe = struct {
    shared: *OrderProbe.Shared,

    fn post(ctx: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.shared.posted.store(true, .release);
    }

    fn drop(ctx: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        // Published before the allocation goes away: the worker's `deinit` reads
        // this, and it must not be reading a dangling pointer to find out.
        self.shared.wheel_emptied.store(true, .release);
        allocator.destroy(self);
    }
};

test "Runtime: shutdown drains the wheel before it tears a worker down" {
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();
    try rt.start();

    var shared = OrderProbe.Shared{};
    _ = try rt.spawn(OrderProbe, .{ .shared = &shared }, 4);
    _ = try rt.spawn(OrderProbe, .{ .shared = &shared }, 4);

    // A timer an hour out: pending, and it can only leave the wheel through the
    // fire path or through the shutdown drain. The leak oracle would complain if
    // neither released it.
    const pending = try std.testing.allocator.create(DrainProbe);
    pending.* = .{ .shared = &shared };
    _ = try rt.scheduleAction(3_600_000, .{
        .ctx = @ptrCast(pending),
        .post = DrainProbe.post,
        .drop = DrainProbe.drop,
    });

    // Fence, so the test does not rest on a sleep: arm and cancel share one
    // FIFO, and `cancelTimerSync` returns only after the owner applied the
    // cancel — which means the owner had already drained everything pushed
    // *before* it, this test's pending timer included. Reading the wheel from
    // here is not an option: this thread does not own it.
    const fence = try std.testing.allocator.create(WheelPayload);
    fence.* = .{};
    const fence_id = try rt.scheduleAction(3_600_000, .{
        .ctx = @ptrCast(fence),
        .post = WheelPayload.post,
        .drop = WheelPayload.drop,
    });
    // `true` = it was still pending when the cancel got applied. The payload is
    // released by the runtime on that path, so this allocation is accounted for.
    try std.testing.expect(try rt.cancelTimerSync(fence_id));

    rt.shutdown();

    // Every worker reached the end of its life, and reached it with an empty
    // wheel: the pending timer was released before the first handle was freed.
    try std.testing.expectEqual(@as(u32, 2), shared.exits.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), shared.exits_seeing_empty_wheel.load(.monotonic));
    try std.testing.expect(shared.wheel_emptied.load(.acquire));
    // …and it was *released*, not delivered into a worker that was going away.
    try std.testing.expect(!shared.posted.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timer_fires);
    try std.testing.expectEqual(@as(u64, 1), rt.stats().timers_discarded);
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

/// The probe `docs/RUNTIME.md` §12.10's lifecycle table is measured with.
/// `handled` counts *invocations*, so a message whose handler returns an error is
/// in it too — that is what makes the table's "2/8 vs 8/8" the number it carries.
///
/// `released` holds the *first* message until the test has published every
/// `send`. Without it the worker can close the mailbox mid-loop and "8 sent"
/// becomes whatever the scheduler happened to do — the numbers below would be a
/// race instead of the table.
const StopProbeActor = struct {
    pub const Message = u32;
    released: *const std.atomic.Value(bool),
    /// Published when `handle` is entered, so a test that has to act *while the
    /// worker is busy* has something to wait for instead of a sleep.
    entered: ?*std.atomic.Value(bool) = null,
    handled: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        _ = ctx;
        if (msg == 0) {
            if (self.entered) |e| e.store(true, .release);
            var spins: usize = 0;
            while (!self.released.load(.acquire) and spins < 800_000_000) : (spins += 1) std.atomic.spinLoopHint();
        }
        _ = self.handled.fetchAdd(1, .monotonic);
        if (msg % 2 == 1) return error.Boom;
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

test "Actor: a supervised stop abandons the mailbox's tail (dedicated)" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    var released = std.atomic.Value(bool).init(false);
    const h = try rt.spawnActor(StopProbeActor, .{ .released = &released }, 8, .{ .strategy = .stop });
    for (0..8) |i| try h.send(@intCast(i)); // all 8 are in the mailbox before msg 0 runs
    released.store(true, .release);
    h.join(); // the loop is gone: whatever is still queued will never be handled

    const s = h.stats();
    // §12.10's dedicated column, as assertions: 2 of the 8 ran (msg 0, then the
    // failing msg 1) ...
    try std.testing.expectEqual(@as(u32, 2), h.state.handled.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), s.received);
    try std.testing.expectEqual(@as(usize, 6), s.mailbox_len);
    try std.testing.expectEqual(@as(u64, 8), s.sent);
    // ... and *nothing* was refused at the producer's boundary: every `send`
    // returned successfully, so the 6 that did not run are not `error.Full`s.
    try std.testing.expectEqual(@as(u64, 0), s.dropped_full);
    // The 6 are therefore abandoned-by-stop, which has its own counter — a
    // *different* reason from `dropped_full`, and a different number.
    try std.testing.expectEqual(@as(u64, 6), s.discarded_on_stop);
    try std.testing.expectEqual(@as(u64, 6), rt.stats().messages_discarded_on_stop);
    // Which closes the accounting identity every accepted message has to
    // satisfy: it was received, or a counter explains where it went.
    try std.testing.expectEqual(s.sent, s.received + s.dropped_full + s.discarded_on_stop);

    // Shutting the runtime down walks every worker's mailbox once more on the
    // way out (that is where the pooled half is counted). The number the same
    // loss already produced must not move: a report of "12" here would be the
    // count running twice over one queue.
    rt.shutdown();
    try std.testing.expectEqual(@as(u64, 6), rt.stats().messages_discarded_on_stop);
}

test "Actor: the pooled stop path drains the mailbox, so nothing is abandoned (pooled)" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 1 },
    });
    defer rt.deinit();

    var released = std.atomic.Value(bool).init(false);
    const h = try rt.spawnActor(StopProbeActor, .{ .released = &released }, .{
        .capacity = 8,
        .mode = .pooled,
    }, .{ .strategy = .stop });
    for (0..8) |i| try h.send(@intCast(i));
    released.store(true, .release);

    // The pool keeps handing the worker back while its mailbox has anything in
    // it (§12.5's stop semantics), so the failing msg 1 stops the *batch*, not
    // the drain: all 8 end up invoked.
    var spins: usize = 0;
    while (h.state.handled.load(.monotonic) < 8 and spins < 800_000_000) : (spins += 1) std.atomic.spinLoopHint();
    h.join();

    const s = h.stats();
    try std.testing.expectEqual(@as(u32, 8), h.state.handled.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 8), s.received);
    try std.testing.expectEqual(@as(usize, 0), s.mailbox_len);
    try std.testing.expectEqual(@as(u64, 0), s.dropped_full);
    // The other half of §12.10's row: the same stop, in pooled mode, abandons
    // nothing — so the counter that reads 6 for a dedicated worker reads 0 here.
    try std.testing.expectEqual(@as(u64, 0), s.discarded_on_stop);
    try std.testing.expectEqual(@as(u64, 0), rt.stats().messages_discarded_on_stop);
    try std.testing.expectEqual(s.sent, s.received + s.dropped_full + s.discarded_on_stop);
}

test "Actor: the pool going down first counts what it leaves behind (pooled)" {
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        // `batch = 1`: one message per claim, so the hand-back happens with the
        // rest of the queue still in the mailbox — the window §12.6 opens by
        // shutting the pool down *before* the workers.
        .scheduler = .{ .max_pooled_workers = 1, .batch = 1 },
    });
    defer rt.deinit();

    var entered = std.atomic.Value(bool).init(false);
    var released = std.atomic.Value(bool).init(false);
    const h = try rt.spawnActor(StopProbeActor, .{
        .released = &released,
        .entered = &entered,
    }, .{ .capacity = 8, .mode = .pooled }, .{});

    for (0..4) |i| try h.send(@intCast(i));
    var spins: usize = 0;
    while (!entered.load(.acquire) and spins < 800_000_000) : (spins += 1) std.atomic.spinLoopHint();

    // The pool thread is inside msg 0 with 3 messages queued. `shutdown` blocks
    // on that thread (§12.6), so it runs on its own thread and this one only
    // releases msg 0 once the pool is stopping — which is when the queued 3
    // become unreachable rather than merely late.
    const Down = struct {
        fn go(r: *Runtime) void {
            r.shutdown();
        }
    };
    const down = try std.Thread.spawn(.{}, Down.go, .{&rt});
    spins = 0;
    while (!rt.scheduler.?.stopping.load(.acquire) and spins < 800_000_000) : (spins += 1) std.atomic.spinLoopHint();
    released.store(true, .release);
    down.join();

    // `h` is gone (`shutdown` destroyed it), so the reading has to come from the
    // runtime — the count must not die with the worker that produced it, which
    // is why it is accumulated here rather than summed over live workers.
    try std.testing.expectEqual(@as(u64, 3), rt.stats().messages_discarded_on_stop);
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

test "Runtime.MetricsBridge publishes the messages a stop abandoned" {
    const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
    const allocator = std.testing.allocator;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();
    var bridge = try Runtime.MetricsBridge(PrometheusMetrics).init(&rt, &metrics);
    metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);

    const check = struct {
        fn gauge(body: []const u8, name: []const u8, value: f64) !void {
            var buf: [160]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{s} {d:.6}", .{ name, value });
            try std.testing.expect(std.mem.indexOf(u8, body, line) != null);
        }
    }.gauge;

    // Registered from the start: a scrape of an idle runtime carries the series
    // at 0 rather than leaving a dashboard to special-case a missing line.
    try std.testing.expectEqual(@as(u64, 0), rt.stats().messages_discarded_on_stop);
    const cold_text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(cold_text);
    try check(cold_text, "zigmodu_runtime_messages_discarded_on_stop", 0);

    // Then it moves for the one reason it exists.
    var released = std.atomic.Value(bool).init(false);
    const h = try rt.spawnActor(StopProbeActor, .{ .released = &released }, 8, .{ .strategy = .stop });
    for (0..8) |i| try h.send(@intCast(i));
    released.store(true, .release);
    h.join();

    const after = rt.stats();
    try std.testing.expectEqual(@as(u64, 6), after.messages_discarded_on_stop);
    // And it is not a second reading of the backpressure counter: nothing was
    // refused here, 6 were abandoned.
    try std.testing.expectEqual(@as(u64, 0), after.messages_dropped);

    const text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(text);
    try check(text, "zigmodu_runtime_messages_discarded_on_stop", @floatFromInt(after.messages_discarded_on_stop));
    try check(text, "zigmodu_runtime_messages_dropped", @floatFromInt(after.messages_dropped));
}

test "Runtime.MetricsBridge publishes the timer deliveries that did not land" {
    const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
    const allocator = std.testing.allocator;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();
    var bridge = try Runtime.MetricsBridge(PrometheusMetrics).init(&rt, &metrics);
    metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);

    const check = struct {
        fn gauge(body: []const u8, name: []const u8, value: f64) !void {
            var buf: [160]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{s} {d:.6}", .{ name, value });
            try std.testing.expect(std.mem.indexOf(u8, body, line) != null);
        }
    }.gauge;

    // Registered from the start: a dashboard gets the series at 0 rather than a
    // missing line, the same way the other drop counters behave.
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timer_deliveries_dropped);
    const cold_text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(cold_text);
    try check(cold_text, "zigmodu_runtime_timer_deliveries_dropped", 0);

    // Then it moves for the one reason it exists: a fire whose message the
    // mailbox refused because the worker was already stopped.
    const handle = try rt.spawn(CounterWorker, .{}, 8);
    _ = try handle.after(50, 7);
    _ = rt.tick();
    handle.stop();
    handle.join();
    clk.advance(60);
    _ = rt.tick();

    const after = rt.stats();
    try std.testing.expectEqual(@as(u64, 1), after.timer_fires);
    try std.testing.expectEqual(@as(u64, 1), after.timer_deliveries_dropped);
    // Not a second reading of anything else: nothing was refused at a producer's
    // boundary and nothing was abandoned out of a queue.
    try std.testing.expectEqual(@as(u64, 0), after.messages_dropped);
    try std.testing.expectEqual(@as(u64, 0), after.messages_discarded_on_stop);

    bridge.publish(); // sampling is callable directly, not only from a scrape
    const text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(text);
    try check(text, "zigmodu_runtime_timer_deliveries_dropped", @floatFromInt(after.timer_deliveries_dropped));
    try check(text, "zigmodu_runtime_timer_fires", @floatFromInt(after.timer_fires));
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
    try check(text, "zigmodu_runtime_messages_discarded_on_stop", @floatFromInt(s.messages_discarded_on_stop));
    try check(text, "zigmodu_runtime_handler_errors", @floatFromInt(s.handler_errors));
    try check(text, "zigmodu_runtime_timer_fires", @floatFromInt(s.timer_fires));
    try check(text, "zigmodu_runtime_timers_discarded", @floatFromInt(s.timers_discarded));
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

test "Runtime.MetricsBridge publishes the pool's counters, and they move with the pool" {
    const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
    const allocator = std.testing.allocator;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer rt.deinit();

    const Pooled = struct {
        const Shared = struct { handled: std.atomic.Value(u32) = .init(0) };
        pub const Message = u32;
        shared: *Shared = undefined,

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = msg;
            _ = ctx;
            _ = self.shared.handled.fetchAdd(1, .monotonic);
        }
    };

    var shared = Pooled.Shared{};
    const pooled = try rt.spawn(Pooled, .{ .shared = &shared }, .{ .capacity = 8, .mode = .pooled });

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();
    var bridge = try Runtime.MetricsBridge(PrometheusMetrics).init(&rt, &metrics);
    metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);

    const check = struct {
        fn gauge(body: []const u8, name: []const u8, value: f64) !void {
            var buf: [128]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf, "{s} {d:.6}", .{ name, value });
            try std.testing.expect(std.mem.indexOf(u8, body, line) != null);
        }
    }.gauge;

    // Cold: spawning a pooled worker deploys the pool (a ring and a thread), so
    // the three structural gauges are already non-zero — while nothing has run
    // yet, which is what `dispatches` at 0 says.
    const cold = rt.poolStats().?;
    try std.testing.expectEqual(@as(usize, 2), cold.max_pooled_workers);
    try std.testing.expectEqual(@as(usize, 1), cold.pool_threads);
    try std.testing.expectEqual(@as(u64, 0), cold.dispatches);
    try std.testing.expectEqual(@as(usize, 0), cold.claimed);
    bridge.publish();
    const cold_text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(cold_text);
    try check(cold_text, "zigmodu_runtime_pool_declared", @floatFromInt(cold.max_pooled_workers));
    try check(cold_text, "zigmodu_runtime_pool_threads", @floatFromInt(cold.pool_threads));
    try check(cold_text, "zigmodu_runtime_pool_ready_len", @floatFromInt(cold.ready_len));
    try check(cold_text, "zigmodu_runtime_pool_claimed", @floatFromInt(cold.claimed));
    try check(cold_text, "zigmodu_runtime_pool_dispatches", @floatFromInt(cold.dispatches));
    try check(cold_text, "zigmodu_runtime_pool_ready_push_failures", @floatFromInt(cold.ready_push_failures));

    // Warm: messages reach the pool thread, so `pool_dispatches` moves — the
    // reading that says "the pooled path was actually taken" rather than merely
    // declared. The scrape is compared against `poolStats()` taken *after*
    // `join()`, when nothing else can be running, so the two cannot disagree.
    for (0..5) |i| try pooled.send(@intCast(i));
    try waitUntil(Published(@TypeOf(shared.handled), u32){ .value = &shared.handled, .want = 5 }, 5_000);
    pooled.stop();
    pooled.join(); // pooled join: waits for the claim to come back and the mailbox to drain

    const warm = rt.poolStats().?;
    try std.testing.expect(warm.dispatches >= 1);
    try std.testing.expectEqual(@as(usize, 0), warm.claimed);
    try std.testing.expectEqual(@as(usize, 0), warm.ready_len);
    try std.testing.expectEqual(@as(u64, 0), warm.ready_push_failures);

    bridge.publish();
    const warm_text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(warm_text);
    try check(warm_text, "zigmodu_runtime_pool_dispatches", @floatFromInt(warm.dispatches));
    try check(warm_text, "zigmodu_runtime_pool_claimed", @floatFromInt(warm.claimed));
    try check(warm_text, "zigmodu_runtime_pool_ready_len", @floatFromInt(warm.ready_len));
    try check(warm_text, "zigmodu_runtime_pool_ready_push_failures", @floatFromInt(warm.ready_push_failures));
}

test "Runtime.MetricsBridge reports no pool as zeros" {
    const PrometheusMetrics = @import("../metrics/PrometheusMetrics.zig").PrometheusMetrics;
    const allocator = std.testing.allocator;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(allocator, std.testing.io, .{ .manual = &clk }); // no pool declared
    defer rt.deinit();

    var metrics = PrometheusMetrics.init(allocator);
    defer metrics.deinit();
    var bridge = try Runtime.MetricsBridge(PrometheusMetrics).init(&rt, &metrics);
    metrics.setScrapeHook(@TypeOf(bridge).sample, &bridge);

    try std.testing.expect(rt.poolStats() == null);
    const text = try metrics.toPrometheusFormat(allocator);
    defer allocator.free(text);
    // The series exist and read 0: "this runtime has no pool" is an answer a
    // dashboard can graph, not a missing line it has to special-case.
    for ([_][]const u8{
        "zigmodu_runtime_pool_declared",
        "zigmodu_runtime_pool_threads",
        "zigmodu_runtime_pool_ready_len",
        "zigmodu_runtime_pool_claimed",
        "zigmodu_runtime_pool_dispatches",
        "zigmodu_runtime_pool_ready_push_failures",
    }) |name| {
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{s} {d:.6}", .{ name, @as(f64, 0) });
        try std.testing.expect(std.mem.indexOf(u8, text, line) != null);
    }
}

// ─────────────────────────────────────────────────
// Pooled workers (docs/RUNTIME.md §12, Phase 1)
// ─────────────────────────────────────────────────
//
// These tests use the *real* pool thread, which is what makes them end-to-end:
// a message goes through mailbox → ready token → pool thread → `handle`. The
// protocol itself is pinned down without a thread in `scheduler.zig`'s tests, so
// a failure here is about the wiring, not about a lucky interleaving.

/// Spin until `probe.ready()` holds, bounded by `timeout_ms`. Time-bounded
/// rather than "sleep long enough": a scheduler that never delivers has to
/// *fail* these tests, and a test that sleeps for a fixed while instead of
/// observing the condition can only pass or hang.
fn waitUntil(probe: anytype, timeout_ms: i64) !void {
    const Time = @import("../core/Time.zig");
    const deadline = Time.monotonicNowMilliseconds() + timeout_ms;
    while (!probe.ready()) {
        if (Time.monotonicNowMilliseconds() > deadline) return error.WaitTimeout;
        std.atomic.spinLoopHint();
    }
}

/// Probe: this pooled worker has nothing left to run — no pool thread is
/// executing it and its mailbox is empty. This is the condition `Handle.join`
/// waits for, bounded here so a scheduler that never delivers fails a test
/// instead of hanging the suite.
fn Drained(comptime H: type) type {
    return struct {
        handle: *H,

        pub fn ready(self: @This()) bool {
            return !self.handle.claimed.load(.acquire) and self.handle.mailbox.len() == 0;
        }
    };
}

/// Probe: an atomic *counter* another thread publishes, waiting for `>= want`.
fn Published(comptime V: type, comptime T: type) type {
    return struct {
        value: *V,
        want: T,

        pub fn ready(self: @This()) bool {
            return self.value.load(.acquire) >= self.want;
        }
    };
}

/// Probe: a boolean flag another thread publishes.
///
/// Both probes wait on something the worker (or the shutdown path) made visible,
/// never on elapsed time — a timeout only ever turns "not yet" into a failure.
fn Flag(comptime V: type) type {
    return struct {
        value: *V,

        pub fn ready(self: @This()) bool {
            return self.value.load(.acquire);
        }
    };
}

test "Runtime: a pooled worker receives every message, in order" {
    const OrderWorker = struct {
        pub const Message = u32;
        seen: [64]u32 = undefined,
        len: usize = 0,

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            self.seen[self.len] = msg;
            self.len += 1;
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 1 },
    });
    defer rt.deinit();

    const handle = try rt.spawn(OrderWorker, .{}, .{ .capacity = 16, .mode = .pooled });
    try std.testing.expect(handle.pool != null); // this one is the pool's
    for (1..6) |i| try handle.send(@intCast(i));
    // Wait (bounded) for the drain, then stop and join: `join` is what makes
    // reading `state` from this thread sound — it waits for "nothing left to run",
    // which includes the mailbox being empty, not just the claim being free.
    try waitUntil(Drained(@TypeOf(handle.*)){ .handle = handle }, 5_000);
    handle.stop();
    handle.join();
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5 }, handle.state.seen[0..5]);

    const s = rt.poolStats().?;
    try std.testing.expectEqual(@as(usize, 1), s.spawned);
    try std.testing.expectEqual(@as(u64, 0), s.ready_push_failures);
    try std.testing.expect(s.dispatches >= 1);
    // Everything is handed back once the worker is stopped and drained.
    try std.testing.expectEqual(@as(usize, 0), s.ready_len);
    try std.testing.expect(!handle.claimed.load(.acquire));
    try std.testing.expect(!handle.queued.load(.acquire));
}

test "Runtime: a pooled worker loses nothing under concurrent producers" {
    // The D5 window, hit for real: `batch = 1` means the hand-back (and its
    // mailbox re-check) runs after *every* message, and three producers are
    // sending into that window continuously. `sendBlocking` means nothing is
    // dropped for backpressure either, so the expected count is exact.
    const SumWorker = struct {
        pub const Message = u64;
        sum: u64 = 0,
        count: u64 = 0,

        pub fn handle(self: *@This(), msg: u64, ctx: anytype) anyerror!void {
            _ = ctx;
            self.sum +%= msg;
            self.count += 1;
        }
    };
    const producers = 3;
    const per_producer = 200;

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 1, .batch = 1 },
    });
    defer rt.deinit();

    const handle = try rt.spawn(SumWorker, .{}, .{ .capacity = 8, .mode = .pooled });

    const Feed = struct {
        fn run(h: @TypeOf(handle), base: u64) void {
            for (0..per_producer) |i| {
                h.sendBlocking(base + i, 5_000) catch return;
            }
        }
    };
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Feed.run, .{ handle, @as(u64, i * per_producer + 1) });
    }
    for (threads) |t| t.join();

    try waitUntil(Drained(@TypeOf(handle.*)){ .handle = handle }, 10_000);
    handle.stop();
    handle.join();

    const expected_count: u64 = producers * per_producer;
    // Sum of 1..=600 in the order the three producers posted: their ranges are
    // contiguous, so the total is the same whatever the interleaving.
    try std.testing.expectEqual(expected_count, handle.state.count);
    try std.testing.expectEqual(expected_count * (expected_count + 1) / 2, handle.state.sum);
    const s = rt.poolStats().?;
    try std.testing.expectEqual(@as(u64, 0), s.ready_push_failures);
}

test "Runtime: `.pooled` without a declared pool is refused, and the bound is hard" {
    var clk = Clock.Manual{ .now_ms = 0 };

    // (a) No pool declared: a configuration error, reported at the spawn rather
    // than quietly starting a thread (D2).
    var rt0 = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt0.deinit();
    try std.testing.expectError(error.PoolNotConfigured, rt0.spawn(
        CounterWorker,
        .{},
        .{ .capacity = 8, .mode = .pooled },
    ));
    try std.testing.expect(rt0.poolStats() == null);

    // (b) A declared bound is a bound: the (N+1)-th pooled spawn is refused,
    // because the ready ring was sized for N — accepting it would make a token
    // push fail, which strands a worker (the capacity invariant).
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer rt.deinit();
    _ = try rt.spawn(CounterWorker, .{}, .{ .capacity = 8, .mode = .pooled });
    _ = try rt.spawn(CounterWorker, .{}, .{ .capacity = 8, .mode = .pooled });
    try std.testing.expectError(error.PoolCapacityExceeded, rt.spawn(
        CounterWorker,
        .{},
        .{ .capacity = 8, .mode = .pooled },
    ));

    const s = rt.poolStats().?;
    try std.testing.expect(s.ready_capacity >= s.max_pooled_workers);
    try std.testing.expect(s.ready_len <= s.max_pooled_workers);
    try std.testing.expectEqual(@as(usize, 2), s.spawned);
    try std.testing.expectEqual(@as(u64, 0), s.ready_push_failures);
}

test "Runtime: a dedicated worker puts nothing in the ready ring" {
    // A declared pool must not change anything for `.dedicated` workers — the
    // default, and every existing call site: no token, no thread, no counter.
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer rt.deinit();

    const handle = try rt.spawn(CounterWorker, .{}, 16); // positional capacity: dedicated
    try std.testing.expect(handle.pool == null);
    try std.testing.expect(handle.thread != null); // its own thread, as before
    for (1..8) |i| try handle.send(@intCast(i));
    handle.stop();
    handle.join();

    try std.testing.expectEqual(@as(u32, 28), handle.state.total);
    try std.testing.expect(handle.thread == null); // reaped by `join`, as before
    try std.testing.expect(!handle.queued.load(.acquire));
    try std.testing.expect(!handle.claimed.load(.acquire));

    const s = rt.poolStats().?;
    try std.testing.expectEqual(@as(usize, 0), s.spawned);
    try std.testing.expectEqual(@as(usize, 0), s.ready_len);
    try std.testing.expectEqual(@as(u64, 0), s.dispatches);
    try std.testing.expectEqual(@as(u64, 0), s.ready_push_failures);
    try std.testing.expect(!s.running); // declaring a pool that is never used starts no thread
}

test "Runtime: a pooled worker's init and deinit run around its life" {
    const Lifecycle = struct {
        /// Every field another thread writes is an atomic: the test waits on
        /// what the worker *published*, not on the mailbox having been emptied.
        const Shared = struct {
            inits: std.atomic.Value(u32) = .init(0),
            deinits: std.atomic.Value(u32) = .init(0),
            seen: std.atomic.Value(u32) = .init(0),
            init_thread: std.atomic.Value(std.Thread.Id) = .init(0),
            handle_thread: std.atomic.Value(std.Thread.Id) = .init(0),
        };
        pub const Message = u32;
        shared: *Shared = undefined,

        pub fn init(self: *@This(), ctx: anytype) anyerror!void {
            _ = ctx;
            self.shared.init_thread.store(std.Thread.getCurrentId(), .release);
            _ = self.shared.inits.fetchAdd(1, .monotonic);
        }

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            self.shared.handle_thread.store(std.Thread.getCurrentId(), .release);
            _ = self.shared.seen.fetchAdd(msg, .monotonic);
        }

        pub fn deinit(self: *@This()) void {
            _ = self.shared.deinits.fetchAdd(1, .monotonic);
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer rt.deinit(); // `shutdown` below is what the assertions are about; this is the cleanup

    var busy = Lifecycle.Shared{};
    var idle = Lifecycle.Shared{};
    const used = try rt.spawn(Lifecycle, .{ .shared = &busy }, .{ .capacity = 8, .mode = .pooled });
    _ = try rt.spawn(Lifecycle, .{ .shared = &idle }, .{ .capacity = 8, .mode = .pooled });

    // Lazy: a pooled worker owns no thread at spawn, so its `init` hook runs
    // with its first batch — the earliest moment it can own one.
    try std.testing.expectEqual(@as(u32, 0), busy.inits.load(.acquire));
    try used.send(41);
    try waitUntil(Published(@TypeOf(busy.seen), u32){ .value = &busy.seen, .want = 41 }, 5_000);

    // `shutdown` (idempotent) rather than `deinit`, so the assertions below can
    // still read the test's own `Shared` values.
    rt.shutdown();

    try std.testing.expectEqual(@as(u32, 1), busy.inits.load(.acquire));
    try std.testing.expectEqual(@as(u32, 41), busy.seen.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), busy.deinits.load(.acquire));
    // `init` and the first batch ran on the same thread, inside the claim: that
    // is the pooled form of "a worker's state belongs to one thread at a time".
    try std.testing.expectEqual(busy.init_thread.load(.acquire), busy.handle_thread.load(.acquire));
    try std.testing.expect(busy.init_thread.load(.acquire) != std.Thread.getCurrentId());
    // The worker that never received a message never started, so it owes no
    // `deinit` either — the pairing is "started", not "spawned".
    try std.testing.expectEqual(@as(u32, 0), idle.inits.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), idle.deinits.load(.acquire));
}

test "Runtime: shutdown with the pool mid-batch hands the claim back first" {
    const Blocker = struct {
        const Shared = struct {
            started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            handled: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        };
        pub const Message = u32;
        shared: *Shared = undefined,

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            self.shared.started.store(true, .release);
            while (!self.shared.release.load(.acquire)) std.atomic.spinLoopHint();
            _ = self.shared.handled.fetchAdd(msg, .monotonic);
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer rt.deinit(); // a second `shutdown` on an already-stopped runtime is a no-op

    var shared = Blocker.Shared{};
    const handle = try rt.spawn(Blocker, .{ .shared = &shared }, .{ .capacity = 8, .mode = .pooled });
    try handle.send(41);
    try waitUntil(Flag(@TypeOf(shared.started)){ .value = &shared.started }, 5_000);

    // Tear the runtime down *while the pool thread is inside `handle`: the pool
    // join has to wait for the batch, the claim has to be handed back before the
    // handle is freed (that is the assertion inside `shutdown`), and the message
    // in flight has to be finished rather than dropped. Under
    // `std.testing.allocator` a use-after-free or a double free fails the test.
    const Teardown = struct {
        fn run(r: *Runtime) void {
            r.shutdown();
        }
    };
    const thread = try std.Thread.spawn(.{}, Teardown.run, .{&rt});
    // Wait for the teardown to have actually begun (shutdown clears `alive`
    // first), then let the handler finish.
    try waitUntil(Flag(@TypeOf(rt.alive)){ .value = &rt.alive }, 5_000);
    shared.release.store(true, .release);
    thread.join();

    try std.testing.expectEqual(@as(u32, 41), shared.handled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), rt.stats().workers);
    try std.testing.expectEqual(@as(usize, 0), rt.stats().running);
}

test "Runtime: a `run`-owned worker cannot be pooled" {
    const LoopWorker = struct {
        pub fn run(self: *@This(), ctx: anytype) anyerror!void {
            _ = self;
            _ = ctx;
        }
    };

    // The guard itself is a `@compileError` inside `spawnSupervised`, gated by
    // exactly this predicate — and a test that *provoked* it could not live in a
    // green suite: the failure would be this file's compilation. So the
    // predicate is asserted here, and the compile error is exercised out of
    // band by `scripts/check-pool-guard.sh` (a fixture that must fail to build,
    // the same shape `check-tenant-scope.sh` uses for its own guard).
    try std.testing.expect(!poolable(LoopWorker));
    try std.testing.expect(poolable(CounterWorker));

    // And the reason: a pooled worker is driven one message at a time, so a
    // `run`-owned loop would occupy a pool thread for as long as it runs.
    try std.testing.expect(@hasDecl(LoopWorker, "run") and !@hasDecl(LoopWorker, "Message"));
}
