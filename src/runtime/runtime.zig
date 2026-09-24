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
//! | `pub fn init(self: *W, ctx: anytype) anyerror!void` (optional) | before either of the above | once per generation |
//! | `pub fn deinit(self: *W) void` (optional) | after either of the above | once per generation |
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
//!
//! STRUCTURE:
//!   §1  Re-exports, spawn config & TraceId —— Clock/Wheel/Mailbox/Scheduler/DeliveryLog · SpawnMode · StopPolicy · SpawnConfig · poolable
//!   §2  Timer wheel hand-off —— TimerAction · timer_command_capacity · TimerCommand
//!   §3  Supervision & stats —— Supervision · GroupPolicy/Group/Intensity · WorkerStats · RuntimeStats
//!   §4  Handle & WorkerContext —— Handle(W, capacity) · WorkerContext(W, capacity)
//!   §5  Runtime —— init/shutdown · spawn/stop · timers · metrics · MetricsBridge
//!   §6  Worker thread & supervision plumbing —— stopThunk · workerMain · deliver · pooledDispatch · supervise · rebuildWorker
//!   §7  Tests —— runtime / actor / pooled / trace / replay / supervision contracts
//!
//! Every section carries a matching `// ==== §N ... ====` anchor — `grep "==== §5"`
//! jumps there. §N *with* the `====` prefix is a section of this file; a bare `§N`
//! is `docs/RUNTIME.md`, and every reference of that kind below spells the file out
//! (`docs/RUNTIME.md §5`) so the two numberings can never be confused.

const std = @import("std");
const mbox = @import("mailbox.zig");
const wheel_mod = @import("timer_wheel.zig");
const clock_mod = @import("clock.zig");
const ring_mod = @import("ring.zig");
const sequencer_mod = @import("sequencer.zig");
const scheduler_mod = @import("scheduler.zig");
const recorder_mod = @import("recorder.zig");
const supervisor_mod = @import("supervisor.zig");

// ==== §1  Re-exports, spawn config & TraceId ====

pub const Clock = clock_mod.Clock;
pub const Wheel = wheel_mod.Wheel;
pub const Mailbox = mbox.Mailbox;
/// The pool behind `.mode = .pooled` (docs/RUNTIME.md §12).
pub const Scheduler = scheduler_mod.Scheduler;
/// How the pool is declared: `Runtime.InitOptions.scheduler`.
pub const SchedulerConfig = scheduler_mod.SchedulerConfig;
/// One worker's delivery track, and the log all of them merge into (§13):
/// `rt.deliveryLog().?.replayer(&manual)`.
pub const DeliveryLog = recorder_mod.DeliveryLog;
/// A `.record = …` declaration: the worker's stable id and the track's capacity.
pub const TrackSpec = recorder_mod.TrackSpec;

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

/// What a worker's `handle` does with the thread it is given, i.e. which pool may
/// run it (docs/RUNTIME.md §6: "a pooled worker must not block for long").
///
/// **This is a declaration, not a detection.** Zig cannot answer "will this code
/// wait on something outside the process?" in general — a `handle` may block on a
/// syscall, a lock, a channel, an allocator, or on a call three modules down — so
/// the runtime does not try. What the class buys is narrow and exact: a worker
/// that *declares* itself blocking runs on a **separate pool**, so its waits
/// cannot consume the threads the CPU-class pool needs to keep other workers
/// moving. It does not help a worker that forgot to declare, and it cannot
/// (nothing observes a block). The honest reading is "declared blocking = kept out
/// of the CPU pool", never "known not to block".
///
/// Declaring `.blocking` requires `.mode = .pooled`: a dedicated worker already
/// owns a thread of its own, so a class would be a no-op — and a *silently
/// ignored* declaration is the one failure mode worse than an undeclared one. It
/// also requires the runtime to have declared a blocking width
/// (`SchedulerConfig.blocking_threads`); without one, `spawn` returns
/// `error.BlockingPoolNotConfigured`, like `.pooled` without a pool.
pub const ExecutionClass = enum {
    /// The handler runs to completion without waiting on anything outside the
    /// process — computation, in-memory state, a `tryPush` that fails rather than
    /// waits. **The default**, because `.pooled` has always meant exactly this and
    /// an undeclared class must change nothing.
    ///
    /// The CPU pool is sized for *cores* (`pool_threads`): a handler here should
    /// hold a core for the length of one bounded batch, not for the length of a
    /// query.
    cpu,
    /// The handler may wait: a DB round trip, a blocking HTTP client, file IO, a
    /// third-party lock. Declared, it moves to the blocking pool — its own ring,
    /// its own threads (`blocking_threads`), its own admission bound
    /// (`max_blocking_workers`) — so a worker that blocks for a second holds a
    /// *blocking* thread and nothing else. That pool can be declared wider than
    /// any CPU pool would sensibly be, because its threads are waiting rather than
    /// computing.
    blocking,
};

/// What a **stop for good** does with the messages already accepted into a
/// worker's mailbox.
///
/// Before this declaration existed the answer was a side effect of `mode`: a
/// dedicated actor's supervisor stop broke the receive loop with a queue still
/// behind it (`immediate`), while the pool kept handing a pooled actor back while
/// its mailbox had anything in it (`drain`). Both answers are still reachable —
/// they are what `null` resolves to, per mode — but they are now a decision at the
/// spawn site rather than something to be discovered from `docs/RUNTIME.md`
/// §12.10. Declaring the other one moves a worker to the other behaviour.
///
/// **What this does not cover, said plainly:** `Handle.stop()` — the external
/// "finish what you have" request — drains the queue under *either* policy, in
/// both modes, exactly as it did before this field existed (a `close()` leaves
/// queued messages available, and neither receive loop stops while one is). The
/// policy governs the *stop for good*, i.e. where a worker ends its own service:
/// the supervisor's decision inside `handle`/`run`. Shutdown has its own,
/// structural answer (`docs/RUNTIME.md` §12.6: the pools go before the workers, so
/// a pooled worker's tail is unreachable rather than drained) and is deliberately
/// not redirected by this field.
pub const StopPolicy = enum {
    /// The worker stops now. Whatever is still in the mailbox is counted as
    /// abandoned (`WorkerStats.discarded_on_stop`,
    /// `RuntimeStats.messages_discarded_on_stop`) and never handled — docs/RUNTIME.md §5's "a
    /// drop has to be visible" applies to work that was accepted and then
    /// abandoned by a stop.
    immediate,
    /// The messages already accepted are worked off before the worker stops.
    /// Nothing is abandoned, so `discarded_on_stop` stays 0 for the tail (a
    /// producer that raced the stop can still add a message after the last
    /// count; see `countAbandoned`).
    drain,
};

/// `spawn`'s last argument, in either of the two shapes `spawnConfig` accepts.
pub const SpawnConfig = struct {
    /// Mailbox capacity in messages. Comptime, because the mailbox is a
    /// fixed-capacity ring.
    capacity: usize,
    mode: SpawnMode = .dedicated,
    /// Which pool may run this worker — see `ExecutionClass`. `.cpu` (the
    /// default) is the pool as it was before the class existed: undeclared, this
    /// field changes nothing at all, and a runtime that declares no blocking
    /// width cannot spawn a `.blocking` worker in the first place.
    execution_class: ExecutionClass = .cpu,
    /// How a stop for good treats the queue — see `StopPolicy`.
    ///
    /// `null` (the default) is **the mode's historical answer**, which is what
    /// keeps this declaration from changing any existing worker: `.dedicated`
    /// resolves to `.immediate`, `.pooled` to `.drain` (docs/RUNTIME.md §12.10's
    /// two rows, unchanged). Declare it to move one worker to the other
    /// behaviour; `handle.stop_policy` is the resolved value.
    stop_policy: ?StopPolicy = null,
    /// Declare a delivery track for this worker (docs/RUNTIME.md §13): every
    /// message that reaches its mailbox — from `send*`, from a `HotBus` fan-out,
    /// from `after(...)` — is then logged with a global sequence number, and the
    /// runtime's `DeliveryLog` can replay the run into a fresh graph.
    ///
    /// `null` (the default) is what §13.6 · 1 asks for: the memory bound is what
    /// was declared, never "however many workers exist".
    record: ?TrackSpec = null,
};

/// Normalise `spawn`'s last parameter, so the two call shapes are one entry
/// point (§12.8 D1) and one implementation:
///
/// ```zig
/// const a = try rt.spawn(Book, .{}, 256);                                  // v0.16 form
/// const b = try rt.spawn(Audit, .{}, .{ .capacity = 64, .mode = .pooled }); // + pool
/// const c = try rt.spawn(Tape, .{}, .{ .capacity = 8, .record = .{ .id = "tape", .capacity = 1024 } });
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
            // Unknown fields are refused rather than ignored. A misspelled
            // `.record` (or `.mode`) would otherwise be *silently* dropped — for
            // a delivery track that is the worst possible failure: the log would
            // be missing a worker while still claiming to be the run's log.
            for (@typeInfo(T).@"struct".field_names) |field_name| {
                if (!@hasField(SpawnConfig, field_name)) @compileError(
                    "unknown field `." ++ field_name ++ "` in spawn's config for `" ++ @typeName(T) ++
                        "`: the accepted fields are .capacity, .mode, .execution_class, .stop_policy and .record",
                );
            }
            var config: SpawnConfig = .{ .capacity = @field(arg, "capacity") };
            if (@hasField(T, "mode")) config.mode = @field(arg, "mode");
            if (@hasField(T, "execution_class")) config.execution_class = @field(arg, "execution_class");
            if (@hasField(T, "stop_policy")) config.stop_policy = @field(arg, "stop_policy");
            if (@hasField(T, "record")) {
                // Field by field: the literal at the call site is an anonymous
                // struct, so there is no `?TrackSpec` to assign from directly.
                const spec = @field(arg, "record");
                const ST = @TypeOf(spec);
                if (!@hasField(ST, "id") or !@hasField(ST, "capacity")) @compileError(
                    "`.record` takes the track declaration `.{ .id = \"worker-id\", .capacity = 1024 }` " ++
                        "(docs/RUNTIME.md §13.2), not `" ++ @typeName(ST) ++ "`",
                );
                config.record = .{ .id = @field(spec, "id"), .capacity = @field(spec, "capacity") };
            }
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

// ==== §2  Timer wheel hand-off ====

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

// ==== §3  Supervision & stats ====

/// How the runtime reacts to an error a worker's `handle`/`run` returned.
///
/// A plain worker (v0.16 behaviour) logs and carries on. An **actor** declares
/// intent instead: fail-fast, or tolerate a bounded number of errors inside a
/// window and then stop for good — the classic supervision "intensity", which
/// exists because an actor that errors on *every* message otherwise burns a core
/// forever while looking alive.
///
/// A member of a **supervision group** (§14) adds one more step: when its own
/// answer is "stop", it hands the decision to the group before anything is torn
/// down. The group may rebuild it instead — in place, `deinit` + `init` on the
/// member's own thread — which is what turns "this actor died" into "this actor
/// died and came back".
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
    /// The **supervision group** this worker belongs to, if any (docs/RUNTIME.md
    /// §14). A group member that is going down hands the decision to the group —
    /// which may rebuild it, rebuild its group-mates, or take the group down —
    /// instead of stopping where it stands. A worker with no group keeps the
    /// v0.16/v0.17 behaviour exactly: stop, log, count.
    ///
    /// Membership is declared here rather than inferred from spawn order so a
    /// group is a choice rather than a side effect, and so `spawn`'s signature
    /// does not change to carry it.
    group: ?*supervisor_mod.Group = null,
};

/// A supervision group's failure policy (docs/RUNTIME.md §14). Re-exported here
/// so a caller configuring supervision never has to name `runtime.supervisor`.
pub const GroupPolicy = supervisor_mod.Policy;
/// A group's restart budget: at most `max_restarts` rebuilds inside `window_ms`.
pub const Intensity = supervisor_mod.Intensity;
/// A supervision group: a set of workers that handle each other's failures.
pub const Group = supervisor_mod.Group;

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
    /// How many times this member has been **rebuilt** by its supervision group
    /// (§14): each one is a `deinit` + `init` on the member's own thread. 0 for a
    /// member in no group, and for one that has never failed.
    group_restarts: u64,
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
    /// Members stopped by supervision (§14) — the "counter" §3b's error budget
    /// was always meant to end in, which until now stopped at
    /// `WorkerStats.stopped_by_supervisor`: a per-worker reading only a poller
    /// could see, and one `shutdown` takes with it.
    ///
    /// Accumulated on the runtime rather than summed over the live workers, for
    /// the reason spelled out on `messages_discarded_on_stop` — and it matters
    /// more here: "a member died" is the reading you most want after a process
    /// has already stopped.
    supervised_stops: u64,
    /// Rebuilds supervision actually **executed** (§14): each is a `deinit` +
    /// `init` on the member's own thread, not merely a request another thread
    /// posted — a member that stops before it notices a request never becomes one.
    /// A member that keeps dying shows up here as a number climbing toward its
    /// group's `max_restarts`.
    group_restarts: u64,
    /// Worst lateness observed between a timer's deadline and its firing.
    timer_lag_max_ms: i64,
};

// ==== §4  Handle & WorkerContext ====

/// Rounds `Handle.join` spins on a pooled worker before it starts polling. The
/// hand-back at the end of a batch is microseconds away in the intended case, so
/// a budget this size rides it out without a syscall; anything longer than that
/// is a handler still running, which is a wait and not a spin.
const join_spin_rounds = 1024;
/// How long `Handle.join` sleeps between polls once it is past that budget — the
/// same 1 ms shape the runtime's other "not yet, look again" waits use (the pool's
/// idle park, `RaftTransport`'s retry loops).
const join_poll_interval = std.Io.Duration.fromMilliseconds(1);

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
        /// The group's "rebuild yourself" request (§14) — the sibling of
        /// `stop_requested`, seen at the same points (the dedicated loop's top,
        /// a pool claim) and for the same reason: a member is never interrupted
        /// mid-message. Set by a group-mate's thread (a `mem.atomic` store, so
        /// any thread may do it); cleared by this member's own thread when it
        /// rebuilds. When both are set, `stop` wins — a thing on its way down
        /// must not be built back up.
        restart_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        handler_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Rebuilds this member has actually executed. Written by its own thread;
        /// atomic because `stats()` reads it from another one.
        group_restarts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Set by a group-mate *before* it calls `stop()` on this member, so the
        /// release in `stop()` publishes it and this member's own thread can count
        /// the stop on its way out. A plain `bool` would not do: the writer is
        /// another thread.
        stopped_by_group: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Idempotence for the supervised-stop count: the dedicated loop's exit
        /// and the pooled `abandon` both want to count it, and it must land once.
        supervised_stop_counted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// This member's position in its group's member list, or null when it is
        /// in no group. `rest_for_one` is the only reader: it is what tells
        /// "spawned after the failure" from "spawned before it" (§14.3).
        group_index: ?usize = null,
        /// Messages counted instead of run when this worker stopped — see
        /// `countAbandoned`. Atomic because `stats()` reads it from another
        /// thread (a scrape, most of the time).
        discarded_on_stop: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Mailbox length `countAbandoned` has already reported. Bookkeeping for
        /// its delta (see there), not a second reading of the counter above.
        counted_at_stop: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        supervision: Supervision = .{},
        /// Supervisor bookkeeping. Written by the worker's own thread (only it
        /// handles messages) — atomic anyway, because `stats()` is a *scrape*: a
        /// monitoring thread reads these while the worker is still serving, and a
        /// plain field written by one thread and read by another is a data race
        /// (the sanitizer build reports it), not merely a stale reading. The
        /// ordering follows this file's rule — `.monotonic` where the reader is
        /// the writer's own thread, `.acquire` where it is not — and `stats()`
        /// itself takes them relaxed: it publishes a *snapshot*, and nothing is
        /// concluded from a pair of these values.
        errors_in_window: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        window_start_ms: i64 = 0,
        stopped_by_supervisor: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// A dedicated worker's thread exists, and the join is over. Two atomics
        /// rather than the `?std.Thread` itself, because `?Thread` is a
        /// non-pointer optional with no guaranteed atomic form (`std.atomic
        /// .Value(?std.Thread)` does not compile — measured), and `stats()` has
        /// no business reading the thread handle anyway. `thread` stays plain and
        /// is written by `join` alone: it is set at spawn and cleared in `join`,
        /// and `thread_live` mirrors exactly those two moments, which is what
        /// keeps the pair from drifting.
        thread_live: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        joined: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
        /// What a stop for good does with the queue (see `StopPolicy`). Written
        /// once, at `spawn`, before any thread can run this worker — read by the
        /// receive loop, the pooled batch and the hand-back re-check, so it is a
        /// plain field rather than an atomic.
        stop_policy: StopPolicy = .immediate,
        /// `.pooled` only: the worker stopped for good under `.immediate`, so
        /// nothing in the mailbox will ever be run again. It exists because the
        /// refused work stays *parked* rather than being drained out (see
        /// `countAbandoned`), and two readers have to know that "still in the
        /// mailbox" no longer means "still waiting to run": the hand-back's
        /// re-check (`pooledPending`, which must not re-arm the worker) and
        /// `join` (which must not wait for a queue nobody will serve).
        abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Set only when this worker was spawned with `.record = …`: its delivery
        /// track (docs/RUNTIME.md §13), owned by the runtime's `DeliveryLog`. Null
        /// — the default — is what keeps `send` costing one null check, and the
        /// track is what the replay driver reads back.
        track: ?*recorder_mod.TrackRef = null,

        /// The funnel every delivery goes through — in two flavours, because the
        /// mailbox has two: `send*` and `Handle.after`'s timer delivery all arrive
        /// here, which is what makes the track "what this worker received" rather
        /// than "what some caller posted" (§13.1). A timer's message never passes
        /// through `HotBus.publish`, so a log taken there would be missing it.
        ///
        /// The record point is *after* the mailbox accepted the message on purpose:
        /// the track holds deliveries, so an `error.Full`/`error.Closed` from the
        /// mailbox must not produce an entry for a message nobody received.
        fn enqueue(self: *Self, envelope: Envelope) mbox.SendError!void {
            try self.mailbox.send(envelope);
            self.noteDelivery(envelope.message);
        }

        /// `enqueue` for the producer that would rather wait for room than drop.
        fn enqueueBlocking(self: *Self, envelope: Envelope, timeout_ms: u32) mbox.SendError!void {
            try self.mailbox.sendBlocking(envelope, timeout_ms);
            self.noteDelivery(envelope.message);
        }

        /// Log one delivered message. Zero allocation: the track copies the value
        /// into its pre-allocated ring (§13.2). A refusal does not fail the send —
        /// the message *is* in the mailbox — it marks the log incomplete, which the
        /// runtime counts and the replay refuses.
        fn noteDelivery(self: *Self, message: Message) void {
            const track = self.track orelse return;
            track.record(track, @ptrCast(&message)) catch |err| {
                std.log.warn(
                    "[runtime] delivery to {s} (track {s}) not recorded: {s} — the log is incomplete from here",
                    .{ self.context.name, track.id, @errorName(err) },
                );
            };
        }

        pub fn send(self: *Self, message: Message) mbox.SendError!void {
            try self.enqueue(.{ .message = message });
            self.announceReady();
        }

        pub fn sendBlocking(self: *Self, message: Message, timeout_ms: u32) mbox.SendError!void {
            try self.enqueueBlocking(.{ .message = message }, timeout_ms);
            self.announceReady();
        }

        /// `send`, with the trace id of the work that produced the message
        /// attached. The worker reads it back with `ctx.traceId()` while it
        /// handles *this* message: the value travels in the mailbox slot, so two
        /// producers sending different traces cannot overwrite each other's.
        pub fn sendTraced(self: *Self, message: Message, trace: TraceId) mbox.SendError!void {
            try self.enqueue(.{ .trace = trace, .message = message });
            self.announceReady();
        }

        /// `sendBlocking`, with a trace attached — for the producer that would
        /// rather wait for room than drop. Backpressure is exactly when losing
        /// the trace hurts most: the messages that arrive late are the ones you
        /// want to attribute.
        pub fn sendBlockingTraced(self: *Self, message: Message, trace: TraceId, timeout_ms: u32) mbox.SendError!void {
            try self.enqueueBlocking(.{ .trace = trace, .message = message }, timeout_ms);
            self.announceReady();
        }

        /// Producer side of the pooled hand-off, and the *only* difference
        /// between a dedicated `send` and a pooled one: a dedicated worker's
        /// readiness is its thread parked in `recv`, a pooled worker's is a token
        /// in the ready ring. Signature and backpressure are unchanged — a full
        /// mailbox still comes back as `error.Full` from `send`, before this
        /// line, and nothing here allocates (docs/RUNTIME.md §4's zero-allocation contract).
        fn announceReady(self: *Self) void {
            const item = self.pool orelse return; // `.dedicated`: the mailbox signal is the whole story
            scheduler_mod.announce(item);
        }

        /// Ask the worker to finish: its mailbox stops accepting and a blocked
        /// `recv` wakes up. The thread is joined by `Runtime.shutdown()` (or
        /// `join()`), never by `stop()` — callers must be able to decide how long
        /// to wait.
        ///
        /// **The queue in front of it is still worked off**, under either
        /// `StopPolicy` and in both modes: `close()` leaves what was accepted
        /// available, and neither receive loop stops while a message is there. What
        /// `stop_policy` governs is the *stop for good* — the supervisor's
        /// decision inside `handle` — see `StopPolicy`.
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
                    //
                    // Through `enqueue`, not `mailbox.send`: a timer's message is
                    // a delivery like any other, and §13.1's whole point is that
                    // these are in the track (they never pass `HotBus.publish`).
                    d.handle.enqueue(.{ .trace = d.trace, .message = d.message }) catch |err| {
                        _ = d.handle.runtime.timer_deliveries_dropped.fetchAdd(1, .monotonic);
                        std.log.debug(
                            "[runtime] timer delivery to {s} dropped: {s}",
                            .{ d.handle.context.name, @errorName(err) },
                        );
                        return;
                    };
                    // ...and then the *same* hand-off `send` does. A pooled
                    // worker's readiness is a token in the scheduler's ring, not a
                    // thread parked in `recv`: without this line the message sits
                    // in the mailbox until some unrelated `send` happens to push a
                    // token, which for a worker fed only by timers is never.
                    d.handle.announceReady();
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
        /// returned (dedicated, or a `.pooled` worker stopped under
        /// `.stop_policy = .immediate`), or the pool that would have dispatched it
        /// has (`Runtime.shutdown`'s teardown). Nobody is going to handle those
        /// messages, so the least this can do is leave a number (docs/RUNTIME.md §5's rule), on
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
                // threads (docs/RUNTIME.md §12.9). The dedicated half is read off
                // `thread_live`/`joined`, never off `thread`: this runs on
                // whatever thread asked, and `join` — another thread — is what
                // clears both flags.
                .running = if (self.pool != null)
                    self.claimed.load(.acquire)
                else
                    self.thread_live.load(.monotonic) and !self.joined.load(.monotonic),
                .mailbox_capacity = capacity,
                .mailbox_len = ms.len,
                .sent = ms.sent,
                .received = ms.received,
                .dropped_full = ms.dropped_full,
                .discarded_on_stop = self.discarded_on_stop.load(.monotonic),
                .handler_errors = self.handler_errors.load(.monotonic),
                .errors_in_window = self.errors_in_window.load(.monotonic),
                .stopped_by_supervisor = self.stopped_by_supervisor.load(.monotonic),
                .group_restarts = self.group_restarts.load(.monotonic),
            };
        }

        /// Count this member's supervised stop exactly once, whichever path got
        /// here first (the dedicated loop's exit, or the pooled `abandon`). Both
        /// reasons count and they are not the same reason: `stopped_by_supervisor`
        /// is "I decided my own stop" (§3b's budget), `stopped_by_group` is "a
        /// group-mate took me down with it" (§14) — but both are supervised stops
        /// on the same counter, because the reading is "this worker was stopped
        /// by the framework, not by `shutdown`".
        fn countSupervisedStop(self: *Self) void {
            // `acquire`, not `monotonic`, on the flag half that another thread may
            // have written last: this runs from the `abandon` thunk as well, i.e.
            // off `Runtime.shutdown`'s thread, and it is `stopped_by_supervisor`
            // (written by the worker, or by the pool on its behalf) that decides
            // what the count below means.
            if (!self.stopped_by_supervisor.load(.acquire) and !self.stopped_by_group.load(.acquire)) return;
            if (self.supervised_stop_counted.swap(true, .acq_rel)) return;
            // `release`, not `monotonic`: the `stopped_by_supervisor` flag written
            // above is what a reader of this counter wants to conclude from, so
            // the counter has to publish it. A relaxed atomic store is still a
            // write that this release orders, and an acquire load of the counter
            // (which is how `Published` in this file's tests reads it) then orders
            // the flag behind it.
            _ = self.runtime.supervised_stops.fetchAdd(1, .release);
        }

        /// Count one executed rebuild (§14). Called by the member's own thread,
        /// right before `deinit` + `init` — "executed", not "requested", because a
        /// request to a member that stops first never becomes one.
        fn countGroupRestart(self: *Self) void {
            _ = self.group_restarts.fetchAdd(1, .release);
            _ = self.runtime.group_restarts.fetchAdd(1, .release);
        }

        pub fn join(self: *Self) void {
            // Idempotent, and called concurrently (`shutdown` is documented as
            // re-entrant): the load is the reason the early return is not a race
            // either — with two callers, both may pass it, but the body below is
            // written to be safe for the one that gets there first (`shutdown`
            // serialises on its own mutex today).
            if (self.joined.load(.acquire)) return;
            if (self.thread) |t| {
                t.join();
                // The thread handle is the plain field; `thread_live` is what
                // `stats()` reads, and it goes down at the same moment — a scrape
                // never sees "running" after the join took the thread away.
                self.thread = null;
                self.thread_live.store(false, .release);
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
                //
                // `abandoned` is the third way of the same thing, and it is a
                // *decision* rather than a race: a `.immediate` worker stopped by
                // its supervisor left a queue nobody will ever run (that is what
                // the policy declares), so waiting for it empty would wait
                // forever. The messages are counted by the batch that abandoned
                // them; `join` returning here is what makes that count readable.
                var spins: u32 = 0;
                while (self.claimed.load(.acquire) or
                    (self.mailbox.len() != 0 and !self.abandoned.load(.acquire) and
                        !link.scheduler.stopping.load(.acquire)))
                {
                    // Spin briefly, then poll. The predicate can hold for as long
                    // as a handler takes: `claimed` is handed back only once the
                    // batch returns, and a long call inside it (an SDK round trip)
                    // is the case this has to tolerate — so an unbounded
                    // `spinLoopHint` loop is not "waiting", it is owning a core for
                    // the duration of somebody else's work. Polling the same
                    // predicate keeps the wait honest whatever the hold turns out
                    // to be.
                    //
                    // Not parked, which is what the alternative would be: a signal
                    // would have to be published on the hand-back's hot path (D5's
                    // claim release) for a wait that only ever happens on the
                    // startup/shutdown path. `std.Io.Event.set` would not cost a
                    // syscall with no waiter, but a latch is the wrong shape for
                    // *this* predicate: it can un-hold and re-hold itself (the pool
                    // re-claims the worker, a producer refills the mailbox), so a
                    // wait has to re-read all three conditions anyway — which is
                    // exactly what a poll does, at a cost of one syscall per round
                    // trip instead of one signal per hand-back.
                    if (spins < join_spin_rounds) {
                        spins += 1;
                        std.atomic.spinLoopHint();
                        continue;
                    }
                    std.Io.sleep(self.runtime.io, join_poll_interval, .awake) catch |err| {
                        // A failed sleep is benign — the next iteration re-checks
                        // the predicate — but it is still an error, so say so
                        // rather than swallowing it.
                        std.log.debug("[runtime] join of {s}: sleep failed ({s}), retrying", .{
                            self.context.name, @errorName(err),
                        });
                    };
                }
            }
            self.joined.store(true, .release);
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

// ==== §5  Runtime ====

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
    /// Supervision groups (§14), owned by the runtime because they outlive any
    /// one member: a group's whole point is to act on members that have stopped.
    /// Freed at `shutdown`, after the workers are gone (`Entry.destroy`), so no
    /// member can be asked to do anything on the way out.
    groups: std.ArrayList(*supervisor_mod.Group) = .empty,
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
    /// Serialises `shutdown`. Every caller is allowed to reach it (an admin
    /// endpoint, a signal handler, `Application.stop`, a worker winding itself
    /// down), and two of them at once used to tear the same threads down twice —
    /// a double `std.Thread.join` (`EINVAL` → `unreachable` → abort) and a double
    /// pass over `workers`. Idempotent has to mean "any number of callers, any
    /// interleaving", not just "calling it again afterwards".
    shutdown_mu: std.Io.Mutex = .init,
    /// Set by the caller that owns the teardown, once it is done. The others wait
    /// behind `shutdown_mu` and return without repeating any of it.
    shutdown_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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
    /// Members stopped by supervision (§14), and rebuilds actually executed.
    /// Accumulated here for the same reason `messages_discarded_on_stop` is:
    /// `shutdown` destroys the workers in the same pass it stops them, so a sum
    /// over them would read 0 for exactly the events these two exist to make
    /// visible — and a member's death is the thing you most want to see after a
    /// process has stopped.
    supervised_stops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    group_restarts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    timer_lag_max_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// The pool behind `.mode = .pooled`, present only when it was declared at
    /// construction (`Runtime.initWithOptions`). Null — the default — means this
    /// runtime runs no pool thread at all and `.pooled` is a configuration error
    /// (docs/RUNTIME.md §12.8 D2). This is the **`.cpu`** pool: the one that has
    /// always existed.
    scheduler: ?*Scheduler = null,
    /// The **blocking** pool behind `.execution_class = .blocking` (docs/RUNTIME.md
    /// §6), present only when a blocking width was declared. A second `Scheduler`,
    /// not a setting inside the first: the two share no ring, no thread and no
    /// admission counter, which is what makes "a blocked blocking worker cannot
    /// hold a CPU-pool thread" structural. Null — the default — means `.blocking`
    /// is refused at `spawn` rather than quietly falling back to the pool a
    /// blocking handler would hold down.
    blocking_scheduler: ?*Scheduler = null,
    /// The delivery log (docs/RUNTIME.md §13), present only once a worker
    /// declared `.record = …` — created on the first such `spawn`, so a runtime
    /// whose workers declare no track allocates nothing and holds no rings. It
    /// outlives `shutdown` on purpose: a replay normally happens *after* the run,
    /// with the handles gone and a fresh graph in their place.
    delivery_log: ?*DeliveryLog = null,

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
        /// Set the member's restart flag (§14). Same shape as `request_stop`
        /// because it is the same kind of thing: a request another thread posts,
        /// which only the member's own thread can act on.
        request_restart: *const fn (*anyopaque) void,
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
    ///
    /// A declared **blocking** width builds a second pool, with the same rules
    /// applied to its own bound (docs/RUNTIME.md §6): `max_blocking_workers`, or
    /// `max_pooled_workers` when that is left 0, sizes its ring and admits its
    /// workers. `blocking_threads` without any bound to size the ring from is a
    /// configuration mistake — refused here rather than asserted inside
    /// `Scheduler.init`, so it cannot depend on an optimisation mode.
    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        io: std.Io,
        options: InitOptions,
    ) !Self {
        var self = init(allocator, io, options.clock);
        errdefer self.deinit();
        if (options.scheduler.max_pooled_workers != 0) {
            self.scheduler = try Scheduler.init(allocator, io, options.scheduler);
        }
        if (options.scheduler.blocking_threads != 0) {
            const bound = if (options.scheduler.max_blocking_workers != 0)
                options.scheduler.max_blocking_workers
            else
                options.scheduler.max_pooled_workers;
            if (bound == 0) return error.BlockingPoolNotConfigured;
            self.blocking_scheduler = try Scheduler.init(allocator, io, .{
                .max_pooled_workers = bound,
                .pool_threads = options.scheduler.blocking_threads,
                .batch = options.scheduler.batch,
            });
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
        self.wheel.deinit();
        self.workers.deinit(self.allocator);
        // `shutdown` already freed the groups themselves; this frees the list
        // that held them (a runtime that never spawned one frees an empty list).
        self.groups.deinit(self.allocator);
        // Last: `shutdown` stops the pools' threads, but tokens that arrived while
        // they were winding down are still in the rings, and nothing reads them
        // again — a pool is its ring's only consumer.
        if (self.scheduler) |sched| sched.deinit();
        self.scheduler = null;
        if (self.blocking_scheduler) |sched| sched.deinit();
        self.blocking_scheduler = null;
        // After `shutdown` (the handles that point into it are already destroyed),
        // and only here: the log has to survive a `shutdown` so the run can be
        // replayed at all (docs/RUNTIME.md §13.4).
        if (self.delivery_log) |log| {
            log.deinit();
            self.allocator.destroy(log);
        }
        self.delivery_log = null;
        self.* = undefined;
    }

    /// The delivery log — the tracks declared with `.record = …` and the shared
    /// sequence that orders them — or `null` when no worker declared one
    /// (docs/RUNTIME.md §13).
    ///
    /// Replay reads from here:
    ///
    /// ```zig
    /// const log = rt.deliveryLog() orelse return;      // nothing was recorded
    /// var replayer = log.replayer(&manual_clock);      // the driver moves the clock
    /// try replayer.bind("book:0", fresh_book_handle);  // the caller supplies the map
    /// while (try replayer.step()) |step| { … }         // merged by global seq, never sleeps
    /// ```
    pub fn deliveryLog(self: *Self) ?*DeliveryLog {
        return self.delivery_log;
    }

    /// The log, created on first use. Only a `.record` spawn calls this, so the
    /// "discipline of the pool" (§12.8 D2) is kept for recording too: no
    /// declaration anywhere, no allocation at all.
    fn ensureDeliveryLog(self: *Self) !*DeliveryLog {
        if (self.delivery_log) |log| return log;
        const log = try self.allocator.create(DeliveryLog);
        // The runtime's own clock: the log's stamps are meant to line up with what
        // timers on this runtime saw (and a replay drives a `Manual` to them).
        log.* = DeliveryLog.init(self.allocator, self.clock);
        self.delivery_log = log;
        return log;
    }

    /// Start the ticker so timers fire without help. Optional: a caller that
    /// drives `tick()` itself (tests, an event loop that already has a clock)
    /// should not start it.
    ///
    /// The wheel's clock is *not* touched here: `start()` runs on the caller's
    /// thread, which is not the wheel's owner. The ticker aligns it when it
    /// takes the wheel (see `tickerMain`).
    ///
    /// The pool's threads are *not* started here either: they appear with the
    /// first pooled `spawn`, so a runtime that declares a pool and never uses it
    /// still starts no thread (D2). The whole declared set starts at once
    /// (`Scheduler.start`), which is what keeps "is the pool deployed" one fact
    /// rather than a count that N spawns race each other to widen.
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
    ///
    /// **One caller at a time.** "Idempotent" here means any number of callers in
    /// any interleaving, not just a second call after the first returned: two
    /// concurrent callers each tore everything down (the first `Scheduler.shutdown`
    /// they both entered joined the pool thread twice — `INVAL` inside
    /// `std.Thread.join` → `unreachable` → abort — and `workers` was walked and
    /// freed twice). So the body runs under `shutdown_mu`, and the caller that did
    /// not get there first returns as soon as the owner is done.
    pub fn shutdown(self: *Self) void {
        self.shutdown_mu.lockUncancelable(self.io);
        defer self.shutdown_mu.unlock(self.io);
        if (self.shutdown_done.load(.acquire)) return;

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

        // Then the pools: either can be running a worker whose handle the lines
        // below are about to free. `Scheduler.shutdown` waits for the batch in
        // flight to finish (a worker that never returns still blocks shutdown —
        // docs/RUNTIME.md §4's rule, kept).
        //
        // Both are stopped before the assertion that follows, because a worker's
        // class decides *which* pool holds its claim and the check below is about
        // the claim, not about the pool (docs/RUNTIME.md §6). A `.blocking` worker
        // whose pool was left running is exactly the shape §12.6's order exists to
        // rule out.
        if (self.scheduler) |sched| sched.shutdown();
        if (self.blocking_scheduler) |sched| sched.shutdown();
        if (self.scheduler != null or self.blocking_scheduler != null) {
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

        // Groups last, and only now: a group exists to act on members, so it must
        // not outlive them through a moment where `stopSubtree` could reach a
        // freed handle. Nothing above joins a group's member list, so this is
        // also the only place a member list is freed.
        for (self.groups.items) |group| group.deinit(self.allocator);
        for (self.groups.items) |group| self.allocator.destroy(group);
        self.groups.clearRetainingCapacity();

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
        // Last, so that a caller waiting on `shutdown_mu` sees a fully torn-down
        // runtime the moment it gets in — and never a half one.
        self.shutdown_done.store(true, .release);
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

    /// Create a **supervision group** (docs/RUNTIME.md §14): a set of workers
    /// whose failures are handled together, by `policy`, inside a restart budget.
    ///
    /// The group is owned by this runtime and freed at `shutdown` — it has to
    /// outlive the members it acts on, since a member stopping is exactly when it
    /// is needed. Members join by naming the group in their `Supervision`
    /// (`spawnActor(..., .{ .group = g })`), which is also what makes the
    /// membership a choice rather than a side effect of spawn order.
    ///
    /// `policy` and the budget are the whole configuration; see `GroupPolicy`
    /// for what each policy does, and `Intensity` for why `max_restarts = 0`
    /// means "never" rather than `max_errors`' "unlimited".
    pub fn spawnGroup(self: *Self, policy: supervisor_mod.Policy) !*supervisor_mod.Group {
        return self.spawnGroupWith(policy, .{});
    }

    /// `spawnGroup` with an explicit restart budget.
    pub fn spawnGroupWith(
        self: *Self,
        policy: supervisor_mod.Policy,
        intensity: supervisor_mod.Intensity,
    ) !*supervisor_mod.Group {
        const group = try self.allocator.create(supervisor_mod.Group);
        errdefer self.allocator.destroy(group);
        group.* = supervisor_mod.Group.init(policy, intensity);
        errdefer group.deinit(self.allocator);
        try self.groups.append(self.allocator, group);
        return group;
    }

    /// Make `parent` treat `child` as one of its members: a failure inside
    /// `child`'s subtree that `child` cannot handle is escalated to `parent`,
    /// which applies **its** policy (§14.5).
    ///
    /// The edge is stored parent-ward (on the child), so an action can walk down
    /// the member lists while the tree is still walkable upward.
    pub fn nestGroup(self: *Self, parent: *supervisor_mod.Group, child: *supervisor_mod.Group) !void {
        _ = try parent.addSubgroup(self.allocator, child);
    }

    /// Spawn an **actor**: same contract as a worker, but the runtime supervises
    /// it — a bounded error budget inside a window, and a stop when the budget is
    /// spent. Defaults differ from `spawn` on purpose: an actor that keeps
    /// failing is stopped rather than left burning a core. Pass
    /// `.{ .group = g }` to put it in a supervision group (§14).
    pub fn spawnActor(
        self: *Self,
        comptime W: type,
        initial_state: W,
        comptime config: anytype,
        supervision: Supervision,
    ) !*Handle(W, spawnConfig(config).capacity) {
        return self.spawnSupervised(W, initial_state, config, supervision);
    }

    /// The form `spawn` / `spawnActor` both funnel through: `spawn` with a
    /// supervision policy.
    ///
    /// Declaring `run` (`W.run` owns its own loop) makes a worker
    /// **unrestartable**: the runtime cannot reach into that loop to tear the
    /// state down, and nothing would ever read the group's request. Putting one
    /// in a group that rebuilds is `error.NotRestartable` at spawn — a wiring
    /// mistake said out loud, on the same principle as the
    /// `.pooled`-a-`run`-worker and `.record`-a-`run`-worker compile errors. A
    /// `.stop_group` group never rebuilds, so it accepts one.
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

        // `.blocking` is a declaration about *which pool runs the handler*, so it
        // needs a pool: a dedicated worker already owns a thread of its own, and a
        // `run`-owned worker is its own loop. Refusing this here (rather than
        // ignoring the class on a dedicated worker) is the whole reason the class
        // is a field instead of a comment: a declaration that silently does
        // nothing is worse than no declaration at all (docs/RUNTIME.md §6).
        const execution_class = comptime spawn_config.execution_class;
        if (comptime (execution_class == .blocking and !pooled)) @compileError(
            @typeName(W) ++ " declares `.execution_class = .blocking` but not `.mode = .pooled`: " ++
                "the class says *which pool* runs the handler, and a `.dedicated` worker has a " ++
                "thread of its own (docs/RUNTIME.md §6). Write " ++
                "`.{ .capacity = …, .mode = .pooled, .execution_class = .blocking }`, or leave the " ++
                "class at its default (`.cpu`).",
        );

        // A delivery track is declared at the spawn site (§13.6 · 1) and its
        // capacity is comptime by construction: the ring is a fixed array of the
        // worker's own `Message`.
        const track_capacity: ?usize = comptime if (spawn_config.record) |spec| spec.capacity else null;
        // A `run`-owned worker has no `Message` to record (docs/RUNTIME.md §3's contract: the
        // runtime hands it nothing), so `.record` on one is a wiring mistake
        // rather than a track that would sit empty and look like a quiet worker.
        if (comptime (track_capacity != null and !@hasDecl(W, "Message"))) @compileError(
            @typeName(W) ++ " declares `run` and has no `Message`: there is nothing for a delivery " ++
                "track to record (docs/RUNTIME.md §13). Declare `pub const Message` + `pub fn handle`, " ++
                "or drop `.record`.",
        );

        // A pool has to have been declared; `.pooled` without one is a
        // configuration mistake, not something to paper over by starting a
        // thread (D2). *Which* pool is the execution class's one job: it decides
        // here and nowhere else, so the rest of the spawn — the ready link, the
        // hand-back, the stop policy — never has to know a class exists.
        var sched: ?*Scheduler = null;
        if (pooled) sched = switch (execution_class) {
            .cpu => self.scheduler orelse return error.PoolNotConfigured,
            .blocking => self.blocking_scheduler orelse return error.BlockingPoolNotConfigured,
        };

        // A `run`-owned worker owns its own loop, so the runtime can neither
        // reach in to tear its state down nor get it to look at a restart
        // request. Refused at spawn rather than accepted-and-ignored: a member
        // that silently never rebuilds is a supervision tree that reads as
        // configured and behaves as absent (§14.4). `.stop_group` is fine — that
        // policy never rebuilds anything.
        if (supervision.group) |group| {
            if (comptime !@hasDecl(W, "handle")) {
                if (group.policy != .stop_group) return error.NotRestartable;
            }
        }
        // ...and the declaration is a hard bound, not a hint: each pool's ready
        // ring capacity is derived from *its* bound, so admitting one worker more
        // than it says would make a token push fail — which strands a worker (see
        // the capacity invariant in `scheduler.zig`).
        if (sched) |s| try s.reserve();
        errdefer if (sched) |s| s.release();

        const H = Handle(W, capacity);
        // The track exists before the handle, so a failure below can hand it back
        // exactly once (a ghost track would keep the id taken *and* be replayed as
        // a worker that never existed). The `errdefer` is at function scope on
        // purpose: the failures it must cover include the thread spawn far below.
        var track: ?*recorder_mod.TrackRef = null;
        errdefer if (track) |t| self.delivery_log.?.removeTrack(t);
        if (comptime track_capacity) |record_capacity| {
            const log = try self.ensureDeliveryLog();
            const typed = try log.addTrack(spawn_config.record.?, H.Message, record_capacity);
            track = &typed.ref;
        }

        const handle = try self.allocator.create(H);
        errdefer self.allocator.destroy(handle);

        handle.* = .{
            .state = initial_state,
            .mailbox = mbox.Mailbox(H.Envelope, capacity).init(self.io),
            .runtime = self,
            .context = undefined,
            .supervision = supervision,
            .window_start_ms = self.clock.nowMs(),
            .track = track,
            // `null` = "whatever this mode has always done", resolved here so the
            // policy is one value at one moment: `.dedicated` keeps the loop's
            // historical `immediate` stop, `.pooled` keeps the pool's `drain`
            // (docs/RUNTIME.md §12.10). An *undeclared* policy therefore changes
            // nothing at all, which is the compatibility requirement that made the
            // default per-mode instead of a single value.
            .stop_policy = spawn_config.stop_policy orelse if (pooled) .drain else .immediate,
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
            .request_stop = stopThunk(H),
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
                    // Also the pooled half of the supervised-stop count: a
                    // dedicated member counted at its loop exit, a pooled one has
                    // no exit of its own — the claim is handed back and that is
                    // all — so its stop is counted here, where every worker is
                    // already walked once. Idempotent, so the dedicated case is
                    // a no-op.
                    h.countSupervisedStop();
                }
            }.f,
            .request_restart = restartThunk(H),
        });
        // From here the spawn owns a slot, an entry and a handle; every failure
        // path below gives all three back. (Keeping the cleanup in `errdefer`
        // rather than in each `catch` is what makes them run exactly once: a
        // `catch` that frees the handle *and* returns an error would free it
        // again here.)
        errdefer _ = self.workers.pop();

        // Join the supervision group, if one was named (§14). After the entry
        // exists (a group acts on members through exactly this shape) and before
        // the member can run (it has no thread yet), so a failure can never
        // arrive at a group that does not know about it — and a failed spawn can
        // always take itself back out.
        if (supervision.group) |group| {
            const membership: supervisor_mod.Member = .{ .worker = .{
                .ptr = @ptrCast(handle),
                .name = @typeName(W),
                .request_restart = restartThunk(H),
                .request_stop = groupStopThunk(H),
            } };
            handle.group_index = try group.add(self.allocator, membership);
            // Only the tail can be removed: the member just appended *is* the
            // tail, and a hole in the middle would renumber `rest_for_one`'s
            // ordering. See `Group.removeLast`.
            errdefer group.removeLast(membership);
        }

        if (sched) |s| {
            // Materialise the pool's threads on first use (D2: declaring a pool
            // you never use costs no thread).
            try s.start();
        } else {
            handle.thread = try std.Thread.spawn(.{}, workerMain(W, capacity), .{handle});
            // Published *after* the handle exists, and cleared in `join` at the
            // same moment `thread` is: `stats()` reads this pair, never `thread`
            // (which another thread writes), so the two have to move together.
            handle.thread_live.store(true, .release);
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
            // From the runtime's accumulators, like `messages_discarded_on_stop`
            // above and for the same reason: `shutdown` stops and destroys in one
            // pass, so summing over the live workers would read 0 for exactly the
            // events these two exist to make visible.
            .supervised_stops = self.supervised_stops.load(.monotonic),
            .group_restarts = self.group_restarts.load(.monotonic),
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
    ///
    /// This is the **`.cpu`** pool. A runtime that declared a blocking width has a
    /// second, independent set of the same readings — `blockingPoolStats` — and
    /// the two are deliberately not summed: `pool_claimed ≤ pool_threads` is the
    /// reading that says "is the pool keeping up", and a total would hide which
    /// class is saturated.
    pub fn poolStats(self: *Self) ?Scheduler.Stats {
        const sched = self.scheduler orelse return null;
        return sched.stats();
    }

    /// The blocking pool's own counters (docs/RUNTIME.md §6), same shape as
    /// `poolStats`. Null when no blocking width was declared — which is also when
    /// `.execution_class = .blocking` is refused at `spawn`, so a null here and a
    /// `.blocking` worker cannot both exist.
    pub fn blockingPoolStats(self: *Self) ?Scheduler.Stats {
        const sched = self.blocking_scheduler orelse return null;
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
            supervised_stops: *MetricsT.Gauge,
            group_restarts: *MetricsT.Gauge,
            timer_lag_ms: *MetricsT.Gauge,
            pool_declared: *MetricsT.Gauge,
            pool_threads: *MetricsT.Gauge,
            pool_ready_len: *MetricsT.Gauge,
            pool_claimed: *MetricsT.Gauge,
            pool_dispatches: *MetricsT.Gauge,
            pool_ready_push_failures: *MetricsT.Gauge,
            // The blocking pool is a **second, independent** `Scheduler`
            // (docs/RUNTIME.md §12.13), so it gets its own set of the same six
            // readings rather than sharing one: a `.blocking` worker parked in a
            // DB round trip shows up as a full blocking pool, and the CPU pool's
            // six numbers stay what answers "is the scheduler keeping up". One
            // series with a label would read better and would also make every
            // existing dashboard query change shape; the six-plus-six is what an
            // app can adopt without touching its panels.
            blocking_pool_declared: *MetricsT.Gauge,
            blocking_pool_threads: *MetricsT.Gauge,
            blocking_pool_ready_len: *MetricsT.Gauge,
            blocking_pool_claimed: *MetricsT.Gauge,
            blocking_pool_dispatches: *MetricsT.Gauge,
            blocking_pool_ready_push_failures: *MetricsT.Gauge,

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
                    .supervised_stops = try metrics.createGauge("zigmodu_runtime_supervised_stops", "Workers stopped by supervision: their own error budget, a group taking them down with a mate, or a group out of restart budget"),
                    .group_restarts = try metrics.createGauge("zigmodu_runtime_group_restarts", "Worker rebuilds supervision executed (deinit + init on the worker's own thread), cumulative"),
                    .timer_lag_ms = try metrics.createGauge("zigmodu_runtime_timer_lag_ms", "Worst lateness between a timer deadline and its firing, in milliseconds"),
                    .pool_declared = try metrics.createGauge("zigmodu_runtime_pool_declared", "Declared upper bound on .pooled workers (0 = no pool: no ring, no pool thread)"),
                    .pool_threads = try metrics.createGauge("zigmodu_runtime_pool_threads", "Pool threads running (0 before the first pooled spawn; the declared width after); the ceiling on pool_claimed"),
                    .pool_ready_len = try metrics.createGauge("zigmodu_runtime_pool_ready_len", "Ready-ring occupancy: workers waiting for a pool thread, at most one token per worker"),
                    .pool_claimed = try metrics.createGauge("zigmodu_runtime_pool_claimed", "Pooled workers a pool thread is executing right now (never above pool_threads)"),
                    .pool_dispatches = try metrics.createGauge("zigmodu_runtime_pool_dispatches", "Batches the pool's threads ran (0 with pooled spawns means they never reached the pool)"),
                    .pool_ready_push_failures = try metrics.createGauge("zigmodu_runtime_pool_ready_push_failures", "MUST stay 0: a refused token push strands a worker (scheduler desync, not backpressure)"),
                    .blocking_pool_declared = try metrics.createGauge("zigmodu_runtime_blocking_pool_declared", "Declared upper bound on .execution_class = .blocking workers (0 = no blocking pool: blocking spawns are refused)"),
                    .blocking_pool_threads = try metrics.createGauge("zigmodu_runtime_blocking_pool_threads", "Blocking pool threads running (0 before the first .blocking spawn); the ceiling on blocking_pool_claimed"),
                    .blocking_pool_ready_len = try metrics.createGauge("zigmodu_runtime_blocking_pool_ready_len", "Blocking ready-ring occupancy: workers waiting for a blocking thread, at most one token per worker"),
                    .blocking_pool_claimed = try metrics.createGauge("zigmodu_runtime_blocking_pool_claimed", "Blocking workers a blocking thread is executing right now (never above blocking_pool_threads)"),
                    .blocking_pool_dispatches = try metrics.createGauge("zigmodu_runtime_blocking_pool_dispatches", "Batches the blocking pool's threads ran (0 with .blocking spawns means they never reached that pool)"),
                    .blocking_pool_ready_push_failures = try metrics.createGauge("zigmodu_runtime_blocking_pool_ready_push_failures", "MUST stay 0: a refused token push strands a blocking worker (scheduler desync, not backpressure)"),
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
                self.supervised_stops.set(@floatFromInt(s.supervised_stops));
                self.group_restarts.set(@floatFromInt(s.group_restarts));
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

                // Same six, same "0 = no pool declared" answer, for the second
                // pool. `blockingPoolStats()` is null unless the app declared a
                // blocking width, so an app that never asked for one graphs
                // zeros rather than losing the series.
                const bp = self.rt.blockingPoolStats();
                self.blocking_pool_declared.set(@floatFromInt(if (bp) |x| x.max_pooled_workers else 0));
                self.blocking_pool_threads.set(@floatFromInt(if (bp) |x| x.pool_threads else 0));
                self.blocking_pool_ready_len.set(@floatFromInt(if (bp) |x| x.ready_len else 0));
                self.blocking_pool_claimed.set(@floatFromInt(if (bp) |x| x.claimed else 0));
                self.blocking_pool_dispatches.set(@floatFromInt(if (bp) |x| x.dispatches else 0));
                self.blocking_pool_ready_push_failures.set(@floatFromInt(if (bp) |x| x.ready_push_failures else 0));
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

// ==== §6  Worker thread & supervision plumbing ====

/// The thread body. Comptime-specialised per worker type, so the `handle`/`run`
/// call the compiler generates is a direct call — no dispatch, no vtable.
/// `Handle(W, cap).stop()`, type-erased — what a supervision group calls to take
/// a member down (§14). The same function the runtime's own `Entry.request_stop`
/// uses: "stop this worker" has one meaning, whoever is asking.
fn stopThunk(comptime H: type) *const fn (*anyopaque) void {
    return struct {
        fn f(p: *anyopaque) void {
            const h: *H = @ptrCast(@alignCast(p));
            h.stop();
        }
    }.f;
}

/// Set a member's restart flag, type-erased. Deliberately *only* sets the flag:
/// the member's own thread does the teardown and the rebuild (§14.4), because
/// rebuilding another thread's state is the one thing the ownership contract
/// forbids.
fn restartThunk(comptime H: type) *const fn (*anyopaque) void {
    return struct {
        fn f(p: *anyopaque) void {
            const h: *H = @ptrCast(@alignCast(p));
            h.restart_requested.store(true, .release);
            // The flag alone is not enough: a member parked in `recv` has no
            // message to wake it (this request comes from a group-mate's thread,
            // not from a producer), and `stop()`'s trick — closing the mailbox —
            // is the opposite of what a rebuild wants. `wake` is the third
            // reason a receiver may come back (§14.4).
            h.mailbox.wake();
        }
    }.f;
}

/// `stopThunk`, but it marks the member as **taken down by its group** before
/// asking (§14). A separate function on purpose: `stopThunk` is what `shutdown`
/// uses through `Entry.request_stop`, and a shutdown is not a supervised stop —
/// merging them would make `RuntimeStats.supervised_stops` count every ordinary
/// teardown, which is precisely the reading it exists to isolate.
fn groupStopThunk(comptime H: type) *const fn (*anyopaque) void {
    return struct {
        fn f(p: *anyopaque) void {
            const h: *H = @ptrCast(@alignCast(p));
            // Before `stop()`: its release publishes this to the member's thread,
            // which reads it on the way out to decide whether to count a stop.
            h.stopped_by_group.store(true, .release);
            h.stop();
        }
    }.f;
}

fn workerMain(comptime W: type, comptime capacity: usize) fn (*Handle(W, capacity)) void {
    return struct {
        fn main(handle: *Handle(W, capacity)) void {
            const H = Handle(W, capacity);

            // Publish this thread's id before anything else runs: `Handle.after`
            // asks "am I on the worker's own thread?" to decide whether the
            // current message's trace may be inherited, and that question needs an
            // answer (0 = not this worker) even while `init` runs.
            handle.context.owner.store(std.Thread.getCurrentId(), .release);

            // An `init` failure is already fatal here: `startWorker` closes the
            // mailbox, so the loop below exits without running a message. There
            // is no half-started state to hand to a group (§14.4), so the answer
            // is deliberately not read.
            _ = startWorker(W, H, handle);

            if (@hasDecl(W, "Message") and @hasDecl(W, "handle")) {
                // Message-driven: the runtime owns the receive loop.
                //
                // A supervisor's stop (fail-fast, or the error budget) is where
                // `stop_policy` decides: `.immediate` — what `.dedicated` has
                // always done — ends the loop here and hands the queue behind it to
                // `countAbandoned` below; `.drain` keeps pulling until the mailbox
                // is empty, which is what a pooled worker does on every stop
                // (docs/RUNTIME.md §12.10). An external `stop()` drains the queue
                // under either policy: the check at the top of the loop only breaks
                // when nothing is left.
                while (true) {
                    // A rebuild request is read here, between messages — the same
                    // moment `stop_requested` is read, and for the same reason: a
                    // member is never interrupted mid-message. `stop` wins when
                    // both are set (§14.4) — a thing on its way down must not be
                    // built back up.
                    //
                    // A group member reads the epoch *before* the flag, so a
                    // request that lands in between is still noticed: the wait
                    // below compares against this value and returns early. A
                    // worker in no group reads `0` and takes the plain `recv(0)`
                    // it always did — no epoch load, no extra branch on the
                    // message path.
                    const in_group = handle.group_index != null;
                    const wake_from = if (in_group) handle.mailbox.wakeEpoch() else 0;
                    if (handle.restart_requested.load(.acquire) and !handle.stop_requested.load(.acquire)) {
                        rebuildWorker(W, H, handle);
                        if (handle.stopped_by_supervisor.load(.monotonic)) break;
                        continue;
                    }
                    if (handle.stop_requested.load(.acquire) and handle.mailbox.len() == 0) break;
                    const arrived = if (in_group)
                        handle.mailbox.recvWakeable(0, wake_from)
                    else
                        handle.mailbox.recv(0);
                    const envelope = arrived orelse {
                        if (handle.mailbox.isClosed()) break;
                        continue;
                    };
                    switch (deliver(W, H, handle, envelope)) {
                        .keep => {},
                        .rebuild => {
                            rebuildWorker(W, H, handle);
                            if (handle.stopped_by_supervisor.load(.monotonic)) break;
                        },
                        // A supervisor's stop. `.immediate` is what a dedicated
                        // worker has always done and `.drain` is what a pooled one
                        // has always done; both are now declarable rather than
                        // implied by the execution mode. Under `.drain` the loop
                        // simply keeps going: `stop_requested` is set, so it exits
                        // on its own once the tail is empty — the loop-top check is
                        // that drain.
                        .stop => if (handle.stop_policy == .immediate) break,
                    }
                }
            } else if (@hasDecl(W, "run")) {
                // Loop-owned: the worker decides when to finish. There is no
                // rebuild path here — the runtime cannot reach into a loop it
                // does not own, which is why one of these in a rebuilding group
                // is refused at spawn rather than accepted and ignored (§14.4).
                W.run(&handle.state, &handle.context) catch |err| {
                    _ = supervise(W, H, handle, err);
                };
            } else {
                @compileError("worker " ++ @typeName(W) ++ " declares neither " ++
                    "`pub const Message` + `pub fn handle(self, msg, ctx)` nor `pub fn run(self, ctx)`");
            }

            // Anything still in the mailbox at this point is work that was
            // accepted and will never be handled. Both ways of getting here are
            // real: a supervisor stop under `.immediate` breaks the receive loop
            // with a queue still behind it (a plain `stop()` drains first — the
            // check at the top of the loop — so it arrives here empty, and so does
            // a `.drain` stop), and a `run`-owned worker never recv's at all.
            // Counted, not run: an actor on its way down is not supposed to keep
            // working, but it is not allowed to lose the number either
            // (docs/RUNTIME.md §5, §12.10).
            handle.countAbandoned();
            // The dedicated half of the supervised-stop count; the pooled half
            // rides on `Entry.abandon`, and the swap makes the pair land once.
            handle.countSupervisedStop();

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
fn startWorker(comptime W: type, comptime H: type, handle: *H) bool {
    if (!@hasDecl(W, "init")) return true;
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
        return false;
    };
    return true;
}

/// One message through `W.handle`: the trace is published for exactly as long as
/// *this* message runs (so a handler can neither see a previous message's trace
/// nor leak this one into whatever it schedules afterwards), and a returned error
/// goes through supervision. Returns false when the worker must stop serving.
///
/// Shared by the dedicated loop (`workerMain`) and the pooled batch
/// (`pooledDispatch`) on purpose: the two modes differ in *who* runs a worker,
/// never in what running it means.
fn deliver(comptime W: type, comptime H: type, handle: *H, envelope: H.Envelope) Outcome {
    var outcome: Outcome = .keep;
    {
        defer handle.context.current_trace = null;
        handle.context.current_trace = envelope.trace;
        W.handle(&handle.state, envelope.message, &handle.context) catch |err| {
            outcome = supervise(W, H, handle, err);
        };
    }
    return outcome;
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

            // docs/RUNTIME.md §4's owner contract, pooled flavour: *this* thread owns the worker
            // while it runs it. That is the answer `Handle.after`'s trace
            // inheritance needs ("am I the worker's thread?"), and 0 afterwards
            // says "no message is being handled here" — the same reading a
            // dedicated worker has between messages.
            handle.context.owner.store(std.Thread.getCurrentId(), .release);
            defer handle.context.owner.store(0, .release);

            // A rebuild another member's failure asked for (§14). Done *before*
            // the lifecycle block below, so the claim that would have started
            // this worker is the same claim that rebuilds it — a pooled member
            // has no thread of its own to notice the request between batches.
            // The claim is exclusive by definition, so the teardown is as safe
            // here as `workerMain`'s rebuild is on a dedicated thread.
            //
            // `stop` wins, as it does everywhere else: a member on its way down
            // is not built back up.
            if (handle.restart_requested.load(.acquire) and !handle.stop_requested.load(.acquire)) {
                if (handle.started) {
                    // `rebuildWorker` clears the flag, which is load-bearing on
                    // this path: a rebuild that left it set would be *re-read by
                    // the next claim*, so every failure would rebuild twice. The
                    // claim is exclusive by definition, which is what makes the
                    // teardown as safe here as on a dedicated thread.
                    //
                    // `started` stays true across the rebuild — the destroy path
                    // reads it to decide whether a `deinit` is owed, and one is.
                    rebuildWorker(W, H, handle);
                    if (handle.stopped_by_supervisor.load(.monotonic)) return false;
                } else {
                    // Asked for before the first claim: there is no generation to
                    // tear down, so this is a no-op rather than a rebuild — but
                    // the flag still has to go, or the claim below would keep
                    // re-reading it.
                    handle.restart_requested.store(false, .release);
                }
            }

            // The lifecycle starts with the first batch, inside the claim: from
            // here on this worker is exclusively owned, exactly as a dedicated
            // worker's thread owns it when `workerMain` runs `init`.
            if (!handle.started) {
                // Set before the hook, so a failed `init` still gets its
                // `deinit` — the pairing `workerMain` has.
                handle.started = true;
                if (startWorker(W, H, handle)) handle.window_start_ms = handle.runtime.clock.nowMs();
            }

            var ran: usize = 0;
            while (ran < max) {
                const envelope = handle.mailbox.tryRecv() orelse return true;
                ran += 1;
                switch (deliver(W, H, handle, envelope)) {
                    .keep => {},
                    // Rebuild right here rather than handing the worker back
                    // with the flag set: the claim is already exclusive, so this
                    // is the same teardown the next claim would do, without a
                    // round trip through the ready ring that would have to be
                    // provoked (`pooledPending`) just to come back.
                    .rebuild => {
                        rebuildWorker(W, H, handle);
                        if (handle.stopped_by_supervisor.load(.monotonic)) return false;
                    },
                    // A supervisor's stop. `.drain` (the pooled default) is what
                    // the pool has always done: end the *batch* and let the
                    // hand-back re-arm the worker while its mailbox still holds
                    // something — the tail gets run, and `discarded_on_stop` stays
                    // 0. `.immediate` (the dedicated default, declarable here)
                    // means the queue is not going to be run at all: hand it to
                    // `countAbandoned` and return nothing left, so the hand-back
                    // does not re-arm a worker whose tail was just counted.
                    .stop => {
                        if (handle.stop_policy == .immediate) {
                            handle.abandoned.store(true, .release);
                            handle.countAbandoned();
                            return true;
                        }
                        break;
                    },
                }
            }
            return false;
        }
    }.run;
}

/// `Ready.pending` for `H`: the hand-back's re-check, and nothing else. A length
/// read rather than a receive, so the runner never consumes what it is deciding
/// about.
///
/// Two reasons a pooled worker reports "there is work" that its mailbox length
/// would not show:
///
/// A pending rebuild counts as work (§14.4): a pooled member asked to rebuild
/// while its mailbox is empty has nothing left to drain, so a length-only answer
/// would let the pool hand it back and never claim it again — the request would
/// sit unread for the rest of the run. Reporting 1 is what gets it claimed one
/// more time, and that claim is what rebuilds it.
///
/// A worker stopped for good under `.immediate` reports 0 even with a non-empty
/// mailbox: its tail was counted by the batch that stopped (`abandoned`), and
/// re-arming it — which is what a non-zero answer means — would run the work the
/// policy just declared abandoned. Checked first, because stop wins, the same
/// rule the receive loop and `rebuildWorker` follow.
fn pooledPending(comptime H: type) *const fn (*anyopaque) usize {
    return struct {
        fn count(ctx: *anyopaque) usize {
            const handle: *H = @ptrCast(@alignCast(ctx));
            if (handle.abandoned.load(.acquire)) return 0;
            if (handle.restart_requested.load(.acquire)) return 1;
            return handle.mailbox.len();
        }
    }.count;
}

/// Record an error and decide whether the worker survives it.
///
/// Returns what the caller's loop must do: keep serving, rebuild the state
/// (§14), or stop. A worker in a supervision group hands the decision to the
/// group *before* anything is torn down — that is the whole point of being in
/// one — so this is also where a group action is executed.
fn supervise(comptime W: type, comptime H: type, handle: *H, err: anyerror) Outcome {
    _ = handle.handler_errors.fetchAdd(1, .monotonic);

    // Windowed budget: reset the window when it has elapsed.
    const now = handle.runtime.clock.nowMs();
    if (handle.supervision.window_ms > 0 and now - handle.window_start_ms > handle.supervision.window_ms) {
        handle.window_start_ms = now;
        handle.errors_in_window.store(0, .monotonic);
    }
    // Own thread, so a relaxed read-modify-write — but atomic, because a scrape
    // may be reading this counter while the handler that just failed is being
    // accounted for.
    _ = handle.errors_in_window.fetchAdd(1, .monotonic);

    // The actor's own opinion wins when declared; otherwise the strategy.
    const decision: Supervision.Strategy = if (@hasDecl(W, "onError"))
        W.onError(&handle.state, err, &handle.context)
    else
        handle.supervision.strategy;

    const over_budget = handle.supervision.max_errors != 0 and
        handle.errors_in_window.load(.monotonic) > handle.supervision.max_errors;
    const must_stop = decision == .stop or over_budget;

    // The trace of the message whose handler just failed — this is what
    // turns "worker X errored" into "the work that request Y caused
    // errored". Read here, before the loop clears `current_trace`.
    var tag_buf: [trace_tag_len]u8 = undefined;
    const tag = traceTag(handle.context.traceId(), &tag_buf);
    const in_window = handle.errors_in_window.load(.monotonic);

    if (must_stop) {
        // In a group, the decision is not this member's to make (§14.4). The
        // group may rebuild it, rebuild its mates, or take the group down — and
        // only the last of those stops anything here. Not counted as a
        // `stopped_by_supervisor` unless it really stops: a rebuilt member was
        // never stopped, and saying otherwise would make the two readings
        // ("I died" / "I was rebuilt") indistinguishable.
        if (handle.supervision.group) |group| {
            if (handle.group_index) |index| {
                if (group.onMemberDown(index, now) == .rebuild) {
                    std.log.warn(
                        "[runtime] {s}{s} rebuilt by its supervision group after {d} error(s) in window ({s}{s}); last: {s}",
                        .{
                            @typeName(W),
                            tag,
                            in_window,
                            @tagName(decision),
                            if (over_budget) ", over budget" else "",
                            @errorName(err),
                        },
                    );
                    return .rebuild;
                }
            }
        }

        // `release`, not `monotonic`: this is the flag the *release* on
        // `supervised_stops` below publishes to whoever counts the stop (see
        // `countSupervisedStop`), and it says "I decided my own stop" — the other
        // half of that counter's meaning.
        handle.stopped_by_supervisor.store(true, .release);
        std.log.warn("[runtime] {s}{s} stopped by supervisor after {d} error(s) in window ({s}{s}); last: {s}", .{
            @typeName(W),
            tag,
            in_window,
            @tagName(decision),
            if (over_budget) ", over budget" else "",
            @errorName(err),
        });
        handle.stop();
        return .stop;
    }

    std.log.warn("[runtime] {s}{s} handler error ({d} in window): {s}", .{
        @typeName(W), tag, in_window, @errorName(err),
    });
    return .keep;
}

/// What a receive loop must do after one message.
const Outcome = enum {
    /// Keep serving this generation of the state.
    keep,
    /// Tear the state down and `init` it again, then keep serving (§14).
    rebuild,
    /// Stop the worker.
    stop,
};

/// Rebuild a member in place (§14.4): `deinit` + `init` on the member's **own
/// thread**, with the error window starting over.
///
/// The handle, the mailbox and the thread are untouched — a rebuild is a new
/// *generation of state*, not a new worker. That is what lets a producer keep
/// the handle it already has, and what keeps `shutdown`'s join list valid across
/// any number of rebuilds.
fn rebuildWorker(comptime W: type, comptime H: type, handle: *H) void {
    handle.countGroupRestart();
    if (@hasDecl(W, "deinit")) W.deinit(&handle.state);
    handle.errors_in_window.store(0, .monotonic);
    handle.restart_requested.store(false, .release);
    // An `init` failure on the way back up is fatal for this generation and is
    // *not* handed to the group again: there is no half-started state to
    // supervise, and asking the group would be exactly the "init loop" the
    // restart budget exists to prevent. It stops, and it says which stop it was.
    if (!startWorker(W, H, handle)) {
        handle.stopped_by_supervisor.store(true, .release);
        return;
    }
    handle.window_start_ms = handle.runtime.clock.nowMs();
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

// ==== §7  Tests ====

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
// The drop counter in docs/RUNTIME.md §5's list was missing: the timer *did* fire (`timer_fires`
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
    // Wait for the *pair* the assertions below read, not for `handled` alone.
    // The two counters are updated at different points of the run: `handled`
    // reaches 2 on msg 2 (the second good one), while msg 3's error is only
    // counted once the worker has pulled it out and `supervise` ran — one
    // delivery later, and after a `std.log.warn`. Leaving the loop on
    // `handled == 2` therefore reads `handler_errors` before its writer has
    // caught up, and the assertion becomes a race on the worker's progress.
    // `handler_errors` is the atomic of the pair, so the loop cannot be hoisted
    // into a single evaluation of it.
    var spins: usize = 0;
    while (spins < 4_000_000 and
        (h.state.handled < 2 or h.handler_errors.load(.monotonic) < 2)) : (spins += 1) std.atomic.spinLoopHint();

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

/// A worker that only counts what it was given: the probe for "did the queue get
/// worked off", with no failure to trigger the policy — the *external* stop case,
/// where the policy is not supposed to change anything.
const Counting = struct {
    pub const Message = u32;
    seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        _ = msg;
        _ = ctx;
        _ = self.seen.fetchAdd(1, .monotonic);
    }
};

test "Handle: an undeclared stop policy is the mode's historical answer" {
    // The compatibility half of `SpawnConfig.stop_policy = null`, as assertions:
    // both rows of §12.10's table stay reachable *without* writing the field, and
    // writing it moves a worker to the other row. The behaviour those rows
    // describe is pinned by the two tests below.
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 1 },
    });
    defer rt.deinit();

    const dedicated = try rt.spawn(Counting, .{}, .{ .capacity = 8 });
    try std.testing.expectEqual(StopPolicy.immediate, dedicated.stop_policy);

    const pooled = try rt.spawn(Counting, .{}, .{ .capacity = 8, .mode = .pooled });
    try std.testing.expectEqual(StopPolicy.drain, pooled.stop_policy);

    // ...and both are declarations, not derived from who runs the worker:
    const declared = try rt.spawn(Counting, .{}, .{ .capacity = 8, .stop_policy = .drain });
    try std.testing.expectEqual(StopPolicy.drain, declared.stop_policy);

    dedicated.stop();
    dedicated.join();
    pooled.stop();
    pooled.join();
    declared.stop();
    declared.join();
}

test "Actor: an external stop() drains the queue under either policy, in both modes" {
    // The boundary `StopPolicy` draws, as an assertion rather than a footnote:
    // the policy governs the *stop for good* (the supervisor's decision inside
    // `handle`), while `stop()` is the caller's "finish what you have" request —
    // `close()` leaves what was accepted available and both receive loops keep
    // pulling while anything is there. So an undeclared/explicit policy cannot
    // lose a message that `stop()` was asked to drain.
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        // Two of the three shapes below are pooled, and the declared bound is
        // admission, not a hint (see the capacity invariant in `scheduler.zig`).
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer rt.deinit();

    // Three shapes, written out: `spawn`'s config is comptime and an anonymous
    // struct literal is the only shape `spawnConfig` normalises today.
    {
        const h = try rt.spawn(Counting, .{}, .{ .capacity = 8, .stop_policy = .immediate });
        for (0..4) |i| try h.send(@intCast(i));
        h.stop();
        // `join` is the deterministic wait for exactly this: dedicated waits for
        // the loop to end, pooled for the claim plus an empty mailbox.
        h.join();
        try expectDrainedByStop(h, 4);
    }
    {
        const h = try rt.spawn(Counting, .{}, .{ .capacity = 8, .mode = .pooled, .stop_policy = .immediate });
        for (0..4) |i| try h.send(@intCast(i));
        h.stop();
        h.join();
        try expectDrainedByStop(h, 4);
    }
    {
        const h = try rt.spawn(Counting, .{}, .{ .capacity = 8, .mode = .pooled, .stop_policy = .drain });
        for (0..4) |i| try h.send(@intCast(i));
        h.stop();
        h.join();
        try expectDrainedByStop(h, 4);
    }
    try std.testing.expectEqual(@as(u64, 0), rt.stats().messages_discarded_on_stop);
}

/// One shape of the test above: every message was handled, nothing was refused
/// and nothing was abandoned.
fn expectDrainedByStop(handle: anytype, want: u32) !void {
    const s = handle.stats();
    try std.testing.expectEqual(want, handle.state.seen.load(.monotonic));
    try std.testing.expectEqual(@as(u64, want), s.received);
    try std.testing.expectEqual(@as(usize, 0), s.mailbox_len);
    try std.testing.expectEqual(@as(u64, 0), s.discarded_on_stop);
}

test "Actor: `.stop_policy = .drain` gives a dedicated actor the pooled stop" {
    // The mirror of the test above it: the same `StopProbeActor`, the same
    // fail-fast supervision, the same 8 queued messages — declared `.drain`, so
    // the actor works the tail off instead of abandoning it. This is the
    // declaration that used to be unreachable without changing `mode`.
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    var released = std.atomic.Value(bool).init(false);
    const h = try rt.spawnActor(StopProbeActor, .{ .released = &released }, .{
        .capacity = 8,
        .stop_policy = .drain,
    }, .{ .strategy = .stop });
    for (0..8) |i| try h.send(@intCast(i));
    released.store(true, .release);
    h.join();

    const s = h.stats();
    try std.testing.expectEqual(StopPolicy.drain, h.stop_policy);
    // Where the dedicated default abandons 6 of 8, `.drain` invokes all 8.
    try std.testing.expectEqual(@as(u32, 8), h.state.handled.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 8), s.received);
    try std.testing.expectEqual(@as(usize, 0), s.mailbox_len);
    try std.testing.expectEqual(@as(u64, 0), s.dropped_full);
    try std.testing.expectEqual(@as(u64, 0), s.discarded_on_stop);
    try std.testing.expectEqual(@as(u64, 0), rt.stats().messages_discarded_on_stop);
    try std.testing.expectEqual(s.sent, s.received + s.dropped_full + s.discarded_on_stop);
}

test "Actor: `.stop_policy = .immediate` gives a pooled actor the dedicated stop" {
    // ...and the mirror of *that*: the pooled default drains, and `.immediate`
    // is what says "stop now, count the rest". The count is visible through the
    // same counters, and — because the tail stays parked — `join` has to be told
    // by `abandoned` that nothing will ever come along to drain it.
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
        .stop_policy = .immediate,
    }, .{ .strategy = .stop });
    for (0..8) |i| try h.send(@intCast(i));
    released.store(true, .release);

    // msg 0 runs, msg 1 fails: the batch stops for good. Waiting on the counter
    // the assertions read (rather than on `handled`) keeps the reading and the
    // assertion at the same moment — the count is written before the claim is
    // handed back.
    var spins: usize = 0;
    while (rt.stats().messages_discarded_on_stop < 6 and spins < 800_000_000) : (spins += 1) std.atomic.spinLoopHint();

    // `join` returns although the mailbox still holds 6 messages: that is the
    // whole point of counting them instead of draining them.
    h.join();
    const s = h.stats();
    try std.testing.expectEqual(StopPolicy.immediate, h.stop_policy);
    try std.testing.expectEqual(@as(u32, 2), h.state.handled.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), s.received);
    try std.testing.expectEqual(@as(usize, 6), s.mailbox_len);
    try std.testing.expectEqual(@as(u64, 8), s.sent);
    try std.testing.expectEqual(@as(u64, 0), s.dropped_full);
    try std.testing.expectEqual(@as(u64, 6), s.discarded_on_stop);
    try std.testing.expectEqual(@as(u64, 6), rt.stats().messages_discarded_on_stop);
    try std.testing.expectEqual(s.sent, s.received + s.dropped_full + s.discarded_on_stop);
    // The worker was not stranded by the early stop: the pool pushed no token it
    // had to give up on (`ready_push_failures` stays the must-be-0 reading).
    try std.testing.expectEqual(@as(u64, 0), rt.poolStats().?.ready_push_failures);
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
    // ...for the *worker's* claim. The pool's counter is decremented one step
    // later (and a token re-push lands between the two), so wait for the reading
    // this test compares against the scrape rather than for the join.
    try waitUntil(PoolUnclaimed(@TypeOf(rt)){ .rt = &rt }, 5_000);

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
        // The blocking pool's six, for the same reason: with no blocking pool
        // declared they are zeros a dashboard can graph, not absent lines.
        "zigmodu_runtime_blocking_pool_declared",
        "zigmodu_runtime_blocking_pool_threads",
        "zigmodu_runtime_blocking_pool_ready_len",
        "zigmodu_runtime_blocking_pool_claimed",
        "zigmodu_runtime_blocking_pool_dispatches",
        "zigmodu_runtime_blocking_pool_ready_push_failures",
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

/// Probe: the pool's *own* `claimed` counter — the number `poolStats()` and the
/// metrics bridge publish — is back to zero.
///
/// `Handle.join` waits on the worker's `claimed` **flag**, and `scheduler.zig`'s
/// hand-back clears that flag one step *before* it decrements this counter
/// (with a token re-push in between when the mailbox still held work). A reader
/// that goes straight from `join` to `poolStats()` therefore reads a counter its
/// writer has not reached yet; waiting on the counter the assertion reads is what
/// puts the reading and the assertion at the same moment.
fn PoolUnclaimed(comptime RT: type) type {
    return struct {
        rt: *RT,

        pub fn ready(self: @This()) bool {
            const s = self.rt.poolStats() orelse return true;
            return s.claimed == 0;
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

/// Probe: a boolean flag another thread **clears** — the negative of `Flag`.
///
/// `Runtime.alive` is the case it exists for: it is true from construction and
/// `shutdown` clears it, so "the teardown has begun" is a wait for *false*.
/// `Flag` would ask for true, which its initial value already satisfies: the
/// wait then means "until the other side stops doing anything", never "until it
/// has started". Both readings happen to end the wait, and they are not the
/// same one — the difference only shows up on the interleaving where the
/// clearer ran first, where true never comes back and the wait spins out its
/// whole budget.
fn Cleared(comptime V: type) type {
    return struct {
        value: *V,

        pub fn ready(self: @This()) bool {
            return !self.value.load(.acquire);
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

test "Runtime: a timer's delivery to a pooled worker arms its ready token" {
    // A pooled worker has no thread parked in `recv`: its readiness is a *token*
    // in the ready ring, and every delivery has to put one there. The timer path
    // is the one that did not (`Handle.after`'s `Delivery.post` enqueued straight
    // into the mailbox), so a message that arrived by timer sat there until some
    // other producer happened to `send` — the worker was alive, idle, and not
    // scheduled, which is the one failure mode the pool must not have.
    const TimerWorker = struct {
        const Shared = struct {
            seen: std.atomic.Value(u32) = .init(0),
            total: std.atomic.Value(u32) = .init(0),
        };
        pub const Message = u32;
        shared: *Shared = undefined,

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            _ = self.shared.seen.fetchAdd(1, .monotonic);
            // `total` carries the `release`: it is written *last*, so a reader that
            // acquire-loads it and sees its final value is also guaranteed to see
            // the `seen` bump. Waiting on `seen` and then reading `total` is not
            // equivalent — both were `monotonic`, so the reader could legally
            // observe the first increment while the second is still in flight
            // (this test did exactly that on a loaded Linux runner: `expected 41,
            // found 0`).
            _ = self.shared.total.fetchAdd(msg, .release);
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 1 },
    });
    defer rt.deinit();

    var shared = TimerWorker.Shared{};
    const handle = try rt.spawn(TimerWorker, .{ .shared = &shared }, .{ .capacity = 8, .mode = .pooled });
    _ = try handle.after(5, 41);

    // The caller drives the wheel (no ticker thread), so the fire is exact: after
    // this `tick` the message is in the mailbox and *nothing else* is going to
    // touch this worker — no `send` follows to paper over a missing token.
    clk.now_ms = 5;
    try std.testing.expectEqual(@as(usize, 1), rt.tick());

    try waitUntil(Published(@TypeOf(shared.total), u32){ .value = &shared.total, .want = 41 }, 2_000);
    try std.testing.expectEqual(@as(u32, 1), shared.seen.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), rt.stats().timer_deliveries_dropped);
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

test "Runtime: N pool threads conserve messages and never overlap on one worker" {
    // The same shape as the test above, with **more than one pool thread**
    // (docs/RUNTIME.md §12.12). Two things change and both are what this asserts:
    // §12.3's state exclusivity can no longer be explained away by "there is only
    // one thread", so the claim is the only thing holding it up (the overlap
    // witness below is the measurement), and the counters have to add up across
    // every producer, every worker and the pool's own ring.
    const workers = 3;
    const width = 2;
    const producers = 3;
    const per_producer = 300;
    const retry_budget: usize = 1 << 22;

    const Shared = struct {
        /// Bit `n` is set while a thread is inside worker `n`'s `handle`. Two
        /// threads inside one worker is the violation; it is counted, not
        /// assumed, because nothing else in the run would notice.
        busy: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        overlaps: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    };
    const OverlapWorker = struct {
        pub const Message = u64;
        shared: *Shared,
        slot: u5,
        /// Plain (non-atomic) state on purpose: §12.3's exclusivity is what makes
        /// touching it sound, and a torn count would show the violation a second
        /// way.
        count: u64 = 0,

        pub fn handle(self: *@This(), msg: u64, ctx: anytype) anyerror!void {
            _ = ctx;
            _ = msg;
            const bit = @as(u32, 1) << self.slot;
            if (self.shared.busy.fetchOr(bit, .acq_rel) & bit != 0) {
                _ = self.shared.overlaps.fetchAdd(1, .monotonic);
            }
            defer _ = self.shared.busy.fetchAnd(~bit, .acq_rel);
            self.count += 1;
            _ = self.shared.received.fetchAdd(1, .monotonic);
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = workers, .pool_threads = width, .batch = 1 },
    });
    defer rt.deinit();

    var shared = Shared{};
    const cap = 8;
    var handles: [workers]*Handle(OverlapWorker, cap) = undefined;
    for (&handles, 0..) |*h, i| {
        h.* = try rt.spawn(OverlapWorker, .{
            .shared = &shared,
            .slot = @intCast(i),
        }, .{ .capacity = cap, .mode = .pooled });
    }
    // The declared width is what the pool started.
    try std.testing.expectEqual(@as(usize, width), rt.poolStats().?.pool_threads);

    var calls = std.atomic.Value(u64).init(0);
    const Feed = struct {
        fn run(
            hs: []const *Handle(OverlapWorker, cap),
            base: u64,
            n: usize,
            calls_: *std.atomic.Value(u64),
        ) void {
            var c: u64 = 0;
            // Counted however this producer leaves: every `send` call below is one
            // mailbox attempt, and the identity the test asserts is over all of
            // them.
            defer _ = calls_.fetchAdd(c, .monotonic);
            for (0..n) |k| {
                const h = hs[k % hs.len];
                const msg = base + k;
                var spins: usize = 0;
                while (true) {
                    c += 1; // one `send` call = one mailbox attempt
                    h.send(msg) catch |err| {
                        if (err != error.Full) return;
                        spins += 1;
                        if (spins > retry_budget) return;
                        std.atomic.spinLoopHint();
                        continue;
                    };
                    break;
                }
            }
        }
    };
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, Feed.run, .{
            &handles, @as(u64, i * per_producer + 1), per_producer, &calls,
        });
    }
    for (threads) |t| t.join();

    // Everything the mailboxes accepted has to be handled before the workers are
    // stopped and joined — `join` is what makes reading `count` sound.
    const calls_made = calls.load(.acquire);
    const dropped = rt.stats().messages_dropped;
    try waitUntil(Published(std.atomic.Value(u64), u64){
        .value = &shared.received,
        .want = calls_made - dropped,
    }, 20_000);
    for (handles) |h| {
        h.stop();
        h.join();
    }

    const stats = rt.stats();
    var counted: u64 = 0;
    for (handles) |h| counted += h.state.count;

    // Every accepted message was handled exactly once, and no worker was entered
    // by two pool threads at the same time.
    try std.testing.expectEqual(counted, shared.received.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), shared.overlaps.load(.acquire));
    // The conservation identity: every `send` call either landed in a mailbox
    // (`messages_sent`) or was refused as backpressure (`messages_dropped`), and
    // what landed was received.
    try std.testing.expectEqual(calls_made, stats.messages_sent + stats.messages_dropped);
    try std.testing.expectEqual(stats.messages_sent, stats.messages_received);
    try std.testing.expectEqual(calls_made, stats.messages_received + stats.messages_dropped);
    try std.testing.expect(stats.messages_received > 0);

    const pool = rt.poolStats().?;
    try std.testing.expectEqual(@as(usize, workers), pool.spawned);
    try std.testing.expectEqual(@as(usize, width), pool.pool_threads);
    try std.testing.expect(pool.ready_capacity >= workers + width);
    // The pool never lost a token, and everything it took in came back out.
    try std.testing.expectEqual(@as(u64, 0), pool.ready_push_failures);
    try std.testing.expectEqual(@as(usize, 0), pool.ready_len);
    try std.testing.expectEqual(@as(usize, 0), pool.claimed);
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

test "Runtime: a blocked `.blocking` worker does not hold the cpu pool" {
    // What the class buys, measured instead of argued (docs/RUNTIME.md §6): while
    // a worker that *declared* itself `.blocking` sits inside its handler — the
    // shape of a DB round trip or a blocking HTTP call — a `.cpu` worker must
    // still be run. Both pools run exactly one thread here, which is the sharpest
    // form of the question: without the class, the blocked handler would be
    // occupying the only thread the CPU worker has.
    const Waiter = struct {
        pub const Message = u32;
        entered: *std.atomic.Value(bool),
        release: *std.atomic.Value(bool),
        handled: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = msg;
            _ = ctx;
            self.entered.store(true, .release);
            // A bounded spin stands in for the wait: this test releases it, and
            // the budget only exists so a broken run cannot hang the suite.
            var spins: usize = 0;
            while (!self.release.load(.acquire) and spins < 4_000_000_000) : (spins += 1) std.atomic.spinLoopHint();
            _ = self.handled.fetchAdd(1, .monotonic);
        }
    };
    const Cpu = struct {
        pub const Message = u32;
        handled: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = msg;
            _ = ctx;
            _ = self.handled.fetchAdd(1, .monotonic);
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2, .pool_threads = 1, .blocking_threads = 1 },
    });
    defer rt.deinit();

    var entered = std.atomic.Value(bool).init(false);
    var release = std.atomic.Value(bool).init(false);
    // Registered after `rt.deinit()`, so it runs *before* it (LIFO): the blocked
    // handler is always released, including on the path where an assertion below
    // fails.
    defer release.store(true, .release);

    const waiter = try rt.spawn(Waiter, .{ .entered = &entered, .release = &release }, .{
        .capacity = 4,
        .mode = .pooled,
        .execution_class = .blocking,
    });
    const cpu = try rt.spawn(Cpu, .{}, .{ .capacity = 4, .mode = .pooled });

    try waiter.send(1);
    try waitUntil(Flag(std.atomic.Value(bool)){ .value = &entered }, 5_000);

    // The blocking pool's only thread is inside `handle` right now, and stays
    // there until this test says otherwise. The CPU pool's only thread is a
    // different thread; the assertion is that it runs its worker anyway.
    for (0..4) |i| try cpu.send(@intCast(i));
    try waitUntil(Published(std.atomic.Value(u32), u32){
        .value = &cpu.state.handled,
        .want = 4,
    }, 5_000);
    try std.testing.expectEqual(@as(u32, 4), cpu.state.handled.load(.acquire));
    // ...and the blocked worker is *still* inside that one message: the line above
    // is a statement about isolation, not about a pause that happened to end.
    try std.testing.expectEqual(@as(u32, 0), waiter.state.handled.load(.acquire));

    release.store(true, .release);
    cpu.stop();
    cpu.join();
    waiter.stop();
    waiter.join();
    try std.testing.expectEqual(@as(u32, 1), waiter.state.handled.load(.acquire));

    // Two pools, two widths, two admissions — and neither lost a token (the one
    // reading that must stay 0 in both).
    const cpu_pool = rt.poolStats().?;
    const blocking = rt.blockingPoolStats().?;
    try std.testing.expectEqual(@as(usize, 1), cpu_pool.pool_threads);
    try std.testing.expectEqual(@as(usize, 1), blocking.pool_threads);
    try std.testing.expectEqual(@as(usize, 1), cpu_pool.spawned);
    try std.testing.expectEqual(@as(usize, 1), blocking.spawned);
    try std.testing.expect(blocking.dispatches >= 1);
    try std.testing.expectEqual(@as(u64, 0), cpu_pool.ready_push_failures);
    try std.testing.expectEqual(@as(u64, 0), blocking.ready_push_failures);
}

test "Runtime: `.blocking` needs a declared blocking width, and its bound is its own" {
    var clk = Clock.Manual{ .now_ms = 0 };

    // (a) `.blocking` with no blocking width declared: refused at the spawn, the
    // way `.pooled` without a pool is — not quietly put on the CPU pool, which is
    // the pool a handler that blocks would then hold down.
    var rt0 = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 2 },
    });
    defer rt0.deinit();
    try std.testing.expectError(error.BlockingPoolNotConfigured, rt0.spawn(
        CounterWorker,
        .{},
        .{ .capacity = 8, .mode = .pooled, .execution_class = .blocking },
    ));
    try std.testing.expect(rt0.blockingPoolStats() == null);
    // The refusal cost the CPU pool nothing: its reservation came back.
    try std.testing.expectEqual(@as(usize, 0), rt0.poolStats().?.spawned);
    const plain = try rt0.spawn(CounterWorker, .{}, .{ .capacity = 8, .mode = .pooled });
    try std.testing.expect(plain.pool != null);
    plain.stop();
    plain.join();

    // (b) The two bounds are two admissions: `max_pooled_workers` decides the
    // `.cpu` class only, `max_blocking_workers` the blocking one, and each pool
    // starts its own declared width.
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{
            .max_pooled_workers = 1,
            .pool_threads = 2,
            .blocking_threads = 1,
            .max_blocking_workers = 2,
        },
    });
    defer rt.deinit();

    _ = try rt.spawn(CounterWorker, .{}, .{ .capacity = 8, .mode = .pooled });
    try std.testing.expectError(error.PoolCapacityExceeded, rt.spawn(
        CounterWorker,
        .{},
        .{ .capacity = 8, .mode = .pooled },
    ));
    // ...while the blocking class still has its own two slots.
    const b1 = try rt.spawn(CounterWorker, .{}, .{
        .capacity = 8,
        .mode = .pooled,
        .execution_class = .blocking,
    });
    const b2 = try rt.spawn(CounterWorker, .{}, .{
        .capacity = 8,
        .mode = .pooled,
        .execution_class = .blocking,
    });
    try std.testing.expectError(error.PoolCapacityExceeded, rt.spawn(
        CounterWorker,
        .{},
        .{ .capacity = 8, .mode = .pooled, .execution_class = .blocking },
    ));

    const cpu_pool = rt.poolStats().?;
    const blocking = rt.blockingPoolStats().?;
    try std.testing.expectEqual(@as(usize, 1), cpu_pool.max_pooled_workers);
    try std.testing.expectEqual(@as(usize, 2), blocking.max_pooled_workers);
    try std.testing.expectEqual(@as(usize, 2), cpu_pool.pool_threads);
    try std.testing.expectEqual(@as(usize, 1), blocking.pool_threads);
    try std.testing.expectEqual(@as(usize, 1), cpu_pool.spawned);
    try std.testing.expectEqual(@as(usize, 2), blocking.spawned);
    // Each ring is sized from its own bound plus its own consumers.
    try std.testing.expect(cpu_pool.ready_capacity >= 1 + 2);
    try std.testing.expect(blocking.ready_capacity >= 2 + 1);

    b1.stop();
    b1.join();
    b2.stop();
    b2.join();
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
    //
    // `Cleared`, not `Flag`: `alive` is *true* until shutdown clears it, so
    // "the teardown has begun" is a wait for false. Asking `Flag` for true is
    // answered by the initial value — the wait returns before anything happened
    // when the teardown loses that race, and against a predicate that is never
    // true again when it wins: the spawn hands the CPU to the new thread, the
    // clear lands first, and the loop spins out its whole budget.
    waitUntil(Cleared(@TypeOf(rt.alive)){ .value = &rt.alive }, 5_000) catch |err| {
        // A wait that gave up still has to let the handler go, or the failure is
        // unreportable: the teardown is inside `shutdown`, whose pool join waits
        // for exactly this batch, and the `deinit` deferred above waits for the
        // teardown. Returning here without releasing turns "the wait timed out"
        // into a hang of the whole suite.
        shared.release.store(true, .release);
        return err;
    };
    shared.release.store(true, .release);
    thread.join();

    try std.testing.expectEqual(@as(u32, 41), shared.handled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), rt.stats().workers);
    try std.testing.expectEqual(@as(usize, 0), rt.stats().running);
}

test "Runtime: two threads calling shutdown at once are safe" {
    // `shutdown` is documented as idempotent, and every caller is allowed to
    // reach it: `Application.stop`, an admin endpoint, a signal handler, a worker
    // winding itself down. "Idempotent" used to mean "calling it *again* after it
    // returned does nothing" — two callers *at the same time* both ran the body,
    // both read `Scheduler.thread`, and both joined the same handle. The second
    // `std.Thread.join` on an already-joined handle is `EINVAL` →
    // `unreachable` → abort, from a function whose contract says that cannot
    // happen (and a torn-down `workers` list is a double free).
    const Trial = struct {
        fn run(r: *Runtime, gate: *std.atomic.Value(u32)) void {
            _ = gate.fetchAdd(1, .acq_rel);
            while (gate.load(.acquire) < 2) std.atomic.spinLoopHint();
            r.shutdown();
        }
    };

    for (0..16) |_| {
        var clk = Clock.Manual{ .now_ms = 0 };
        var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
            .clock = .{ .manual = &clk },
            .scheduler = .{ .max_pooled_workers = 1 },
        });
        // Both kinds of worker: the pooled one is the scheduler's thread to join,
        // the dedicated one owns a thread of its own.
        const pooled = try rt.spawn(CounterWorker, .{}, .{ .capacity = 8, .mode = .pooled });
        const dedicated = try rt.spawn(CounterWorker, .{}, 8);
        try pooled.send(1);
        try dedicated.send(1);

        var gate = std.atomic.Value(u32).init(0);
        const a = try std.Thread.spawn(.{}, Trial.run, .{ &rt, &gate });
        const b = try std.Thread.spawn(.{}, Trial.run, .{ &rt, &gate });
        gate.store(2, .release); // both callers enter `shutdown` together
        a.join();
        b.join();

        try std.testing.expectEqual(@as(usize, 0), rt.stats().workers);
        try std.testing.expectEqual(@as(usize, 0), rt.stats().running);
        rt.deinit(); // ...and a third, sequential call is still a no-op
    }
}

/// How long the pooled `join` test's handler holds its claim, and the CPU budget
/// a thread waiting for it may spend. The gap between the two is the assertion:
/// the handler sleeps, so a waiter that *waits* spends ~0 while one that spins
/// spends the whole hold.
const join_wait_hold_ms = 150;
const join_wait_cpu_budget_ns = 60 * std.time.ns_per_ms;

/// Process CPU time (`utime` + `stime`), in nanoseconds. Wall time cannot tell
/// "waiting" from "spinning" — both take the same hold — and `std` exposes no
/// per-thread reading here. `who = 0` is `RUSAGE_SELF` on every platform Zig
/// targets, which is the honest scope anyway: the test's other threads are
/// asleep, so the process's CPU *is* the waiter's.
fn processCpuNanos() u64 {
    const usage = std.posix.getrusage(0);
    const user_s: i64 = @intCast(usage.utime.sec);
    const user_us: i64 = @intCast(usage.utime.usec);
    const sys_s: i64 = @intCast(usage.stime.sec);
    const sys_us: i64 = @intCast(usage.stime.usec);
    return @intCast((user_s + sys_s) * std.time.ns_per_s + (user_us + sys_us) * std.time.ns_per_us);
}

test "Runtime: a pooled join waits for a claim without burning a core" {
    // The wait is the thing under test, so the handler *blocks* for a known span
    // and leaves the claim held for all of it (`join`'s predicate is
    // `claimed == true` until the batch hands it back). A wait on a handler that
    // is still running is exactly the case an unbounded `spinLoopHint` loop gets
    // wrong: a long handler — an SDK call, the reason `join` has to tolerate one —
    // turns "wait for it" into "own a core for as long as it takes".
    const Slow = struct {
        pub const Message = u32;
        started: *std.atomic.Value(bool),

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = msg;
            self.started.store(true, .release);
            try std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(join_wait_hold_ms), .awake);
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .clock = .{ .manual = &clk },
        .scheduler = .{ .max_pooled_workers = 1 },
    });
    defer rt.deinit();

    var started = std.atomic.Value(bool).init(false);
    const h = try rt.spawn(Slow, .{ .started = &started }, .{ .capacity = 4, .mode = .pooled });
    try h.send(1);
    // Measure from the moment the handler really owns the claim, so the window
    // is "waiting for a running handler" and not the microseconds before the
    // pool picked the message up.
    try waitUntil(Flag(@TypeOf(started)){ .value = &started }, 5_000);

    const before = processCpuNanos();
    h.join();
    const spent = processCpuNanos() - before;

    // Printed only when it is about to fail: a green run stays quiet, and a red
    // one says how far off it was instead of just "TestUnexpectedResult".
    if (spent >= join_wait_cpu_budget_ns) std.debug.print(
        "[join-wait] {d} us of CPU spent waiting for a handler that held its claim for {d} ms (budget {d} us)\n",
        .{ spent / 1000, join_wait_hold_ms, join_wait_cpu_budget_ns / 1000 },
    );
    try std.testing.expect(spent < join_wait_cpu_budget_ns);
}

test "Runtime: stats() reads soundly while another thread joins the worker" {
    // `stats()` is a scrape: a monitoring thread calls it while the runtime is
    // doing anything at all, `shutdown`'s joins included. For a dedicated worker
    // it reads `thread`/`joined`, and it reads the supervisor's bookkeeping
    // (`errors_in_window`/`stopped_by_supervisor`) — all four written by *other*
    // threads (the joining one, and the worker's own on its error path), which is
    // a data race no assertion here can see: the window is a handful of
    // instructions wide. What this pins is the part that is observable — the
    // reading on both sides of the join, taken from a thread that spends the join
    // inside `stats()` — and it is the shape the sanitizer build of this file
    // (`zig test -fsanitize-thread`) is pointed at.
    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .{ .manual = &clk });
    defer rt.deinit();

    const h = try rt.spawn(CounterWorker, .{}, 8);
    try h.send(1);
    try h.send(2);
    try std.testing.expect(h.stats().running); // the thread has started, no join yet

    const Reader = struct {
        fn run(
            handle: *Handle(CounterWorker, 8),
            stop: *std.atomic.Value(bool),
            calls: *std.atomic.Value(u32),
            torn: *std.atomic.Value(bool),
        ) void {
            var n: u32 = 0;
            while (!stop.load(.acquire)) {
                const s = handle.stats();
                // Whatever the interleaving, the reading has to stay *shape*-
                // sound: a mailbox length past its capacity cannot come from any
                // real state of this worker.
                if (s.mailbox_len > s.mailbox_capacity) torn.store(true, .release);
                n += 1;
                calls.store(n, .release);
                std.atomic.spinLoopHint();
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var calls = std.atomic.Value(u32).init(0);
    var torn = std.atomic.Value(bool).init(false);
    const reader = try std.Thread.spawn(.{}, Reader.run, .{ h, &stop, &calls, &torn });
    // Let the reader reach `stats()` *before* the join writes anything: that is
    // what puts the two accesses in the sanitizer's conflicting pair.
    try waitUntil(Published(@TypeOf(calls), u32){ .value = &calls, .want = 1 }, 5_000);

    h.stop(); // a dedicated `join` waits for the *thread*, which stops on this
    h.join(); // ...while the reader is calling `stats()`

    // The same reading after the join: nothing is running, the supervisor never
    // touched it, and the handle is still readable (it outlives the join).
    const after = h.stats();
    try std.testing.expect(!after.running);
    try std.testing.expectEqual(@as(u32, 0), after.errors_in_window);
    try std.testing.expect(!after.stopped_by_supervisor);
    try std.testing.expectEqual(@as(u32, 2), after.received); // both were handled

    stop.store(true, .release);
    reader.join();
    try std.testing.expect(!torn.load(.acquire));
    try std.testing.expect(calls.load(.acquire) >= 1);
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

// ─────────────────────────────────────────────────
// Runtime Replay (docs/RUNTIME.md §13)
// ─────────────────────────────────────────────────

/// One handler invocation as both phases observe it: which worker ran, what it
/// was handed (compressed to a fingerprint), and the time it read off its
/// injected clock. §13.4's assertion is that two runs produce the same sequence
/// of these — order included — so a comparison needs nothing else.
const Handled = struct {
    worker: []const u8 = "",
    fingerprint: u64 = 0,
    clock_ms: i64 = 0,
};

/// Where a phase writes its invocations. One atomic sequence hands out the slot,
/// so two worker threads cannot collide and neither needs a lock.
const HandlerLog = struct {
    order: sequencer_mod.Sequencer = sequencer_mod.Sequencer.init(0),
    slots: [16]Handled = @splat(.{}),

    fn note(self: *@This(), worker: []const u8, fingerprint: u64, clock_ms: i64) void {
        const slot: usize = @intCast(self.order.next());
        self.slots[slot] = .{ .worker = worker, .fingerprint = fingerprint, .clock_ms = clock_ms };
    }

    fn taken(self: *const @This()) []const Handled {
        return self.slots[0..@intCast(self.order.peek())];
    }
};

/// What a handler logs as "the payload": a hash of the value it received. Both
/// message types below are padding-free, so their bytes are a canonical encoding
/// — and a fingerprint is what makes the two phases comparable without replaying
/// the payload object itself (§13.4).
fn payloadFingerprint(comptime T: type, value: T) u64 {
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&value));
}

/// Bounded wait for the *handler* side of a delivery, by spinning. Both phases
/// wait here for the same reason — so that each observes deliveries in the order
/// the log holds them — and this is the harness's wait, never the replay
/// driver's: `Replayer.step` waits for nothing (§13.6 · 3).
fn awaitHandled(log: *const HandlerLog, want: u64) !void {
    var spins: usize = 0;
    while (log.order.peek() < want) : (spins += 1) {
        if (spins > 100_000_000) return error.HandlerNeverRan;
        std.atomic.spinLoopHint();
    }
}

const AlphaProbe = struct {
    pub const Message = u32;
    log: *HandlerLog,

    pub fn handle(self: *@This(), msg: Message, ctx: anytype) anyerror!void {
        self.log.note("alpha", payloadFingerprint(Message, msg), ctx.clock().nowMs());
    }
};

const BetaProbe = struct {
    pub const Message = struct { x: i32, y: i32 };
    log: *HandlerLog,

    pub fn handle(self: *@This(), msg: Message, ctx: anytype) anyerror!void {
        self.log.note("beta", payloadFingerprint(Message, msg), ctx.clock().nowMs());
    }
};

test "Runtime Replay (§13.4): a delivery track replays into the same handler sequence, without sleeping" {
    const Time = @import("../core/Time.zig");
    var recorded_log = HandlerLog{};
    var replayed_log = HandlerLog{};

    // ── phase 1: record ─────────────────────────────────────────────────
    var rec_clock = Clock.Manual{ .now_ms = 1_000_000 };
    var rt_rec = Runtime.init(std.testing.allocator, std.testing.io, rec_clock.clock());
    defer rt_rec.deinit();
    // The ticker is what delivers `after(...)`, and §13.1 is precisely about
    // those deliveries being part of the track.
    try rt_rec.start();

    const alpha = try rt_rec.spawn(AlphaProbe, .{ .log = &recorded_log }, .{
        .capacity = 8,
        .record = .{ .id = "alpha", .capacity = 4 },
    });
    const beta = try rt_rec.spawn(BetaProbe, .{ .log = &recorded_log }, .{
        .capacity = 8,
        .record = .{ .id = "beta", .capacity = 4 },
    });

    // Interleaved on purpose: two message types, one shared sequence, plus a
    // timer delivery in the middle — the one that never passes through
    // `HotBus.publish`, so a log taken there would be missing exactly this half.
    rec_clock.set(1_000_000);
    try alpha.send(7);
    try awaitHandled(&recorded_log, 1);

    rec_clock.set(6_000_000);
    try beta.send(.{ .x = 1, .y = 2 });
    try awaitHandled(&recorded_log, 2);

    rec_clock.set(11_000_000);
    _ = try alpha.after(50, 9);
    rec_clock.set(11_000_060); // past the deadline: the ticker fires on its next tick
    try awaitHandled(&recorded_log, 3);

    rec_clock.set(16_000_000);
    try alpha.send(13);
    try awaitHandled(&recorded_log, 4);

    rec_clock.set(21_000_000);
    try beta.send(.{ .x = 3, .y = 4 });
    try awaitHandled(&recorded_log, 5);

    const recorded = recorded_log.taken();
    try std.testing.expectEqual(@as(usize, 5), recorded.len);

    const log = rt_rec.deliveryLog() orelse return error.NoDeliveryLog;
    try std.testing.expectEqual(@as(usize, 2), log.trackCount());
    try std.testing.expect(!log.hasOverflowed());

    // ── phase 2: replay ─────────────────────────────────────────────────
    // A fresh graph — same worker types, new handles — on a runtime whose clock
    // *is* the one the driver moves, so a replayed handler reads the recorded
    // time and the two invocation logs are directly comparable. (`now_ms` starts
    // at 0, not at -1: the wheel indexes slots by time, so a negative manual
    // clock is not a thing `Runtime.init` can be handed.)
    var rep_clock = Clock.Manual{ .now_ms = 0 };
    var rt_rep = Runtime.init(std.testing.allocator, std.testing.io, rep_clock.clock());
    defer rt_rep.deinit();
    const replayed_alpha = try rt_rep.spawn(AlphaProbe, .{ .log = &replayed_log }, 8);
    const replayed_beta = try rt_rep.spawn(BetaProbe, .{ .log = &replayed_log }, 8);

    var replayer = log.replayer(&rep_clock);
    try replayer.bind("alpha", replayed_alpha);
    try replayer.bind("beta", replayed_beta);

    var ids: [8][]const u8 = @splat("");
    var stamps: [8]i64 = @splat(0);
    var seen: usize = 0;
    const started = Time.monotonicNowMilliseconds();
    while (true) {
        const step = (try replayer.step()) orelse break;
        try std.testing.expect(seen < ids.len);
        ids[seen] = step.id;
        stamps[seen] = step.clock_ms;
        seen += 1;
        try awaitHandled(&replayed_log, seen);
    }
    const elapsed = Time.monotonicNowMilliseconds() - started;

    try std.testing.expectEqual(recorded.len, seen);
    try std.testing.expectEqualSlices([]const u8, &.{ "alpha", "beta", "alpha", "alpha", "beta" }, ids[0..seen]);
    // The third entry is the timer's delivery, stamped when it *fired*
    // (11_000_060) rather than when it was armed (11_000_000): that is the
    // difference between a delivery log and a schedule log.
    try std.testing.expectEqualSlices(i64, &.{ 1_000_000, 6_000_000, 11_000_060, 16_000_000, 21_000_000 }, stamps[0..seen]);

    // §13.4 itself: same handlers, same order, same payload fingerprints.
    for (recorded, replayed_log.taken()) |want, got| {
        try std.testing.expectEqualStrings(want.worker, got.worker);
        try std.testing.expectEqual(want.fingerprint, got.fingerprint);
        try std.testing.expectEqual(want.clock_ms, got.clock_ms);
    }

    // "and it does not sleep": 20_000_000 ms of recorded time (~5.5 h) replayed
    // in a fraction of a second of wall time. A driver that waited out the
    // timestamps could not get anywhere near this, and the clock's final value
    // says the timestamps really were the ones it moved to.
    try std.testing.expectEqual(@as(i64, 21_000_000), rep_clock.now_ms);
    try std.testing.expect(elapsed < 1_000);
}

test "Runtime Replay: a track that ran out of room marks the log incomplete, and the replay refuses it" {
    const Taped = struct {
        pub const Message = u32;
        seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = msg;
            _ = ctx;
            _ = self.seen.fetchAdd(1, .monotonic);
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, clk.clock());
    defer rt.deinit();

    const handle = try rt.spawn(Taped, .{}, .{ .capacity = 8, .record = .{ .id = "tape", .capacity = 2 } });
    const log = rt.deliveryLog() orelse return error.NoDeliveryLog;
    try std.testing.expectEqual(@as(usize, 1), log.trackCount());
    try std.testing.expect(!log.hasOverflowed());

    // Three deliveries into a two-entry track: the third one *is* delivered — the
    // mailbox decides that, not the track — and is not recorded. The log has a
    // hole, and it says so (the send cannot: it succeeded).
    for (1..4) |i| try handle.send(@intCast(i));
    try waitUntil(Published(@TypeOf(handle.mailbox.received), u64){ .value = &handle.mailbox.received, .want = 3 }, 5_000);

    try std.testing.expectEqual(@as(u64, 3), handle.stats().received);
    try std.testing.expectEqual(@as(usize, 2), log.len());
    try std.testing.expectEqual(@as(u64, 1), log.refusedCount());
    try std.testing.expect(log.hasOverflowed());

    // A log with a hole is not replayed — not even partially, and not even when
    // the caller would be happy with a prefix (§11.6's rule, kept).
    const fresh = try rt.spawn(Taped, .{}, 8);
    var manual = Clock.Manual{ .now_ms = 0 };
    var replayer = log.replayer(&manual);
    try replayer.bind("tape", fresh);
    try std.testing.expect(replayer.isFullyBound());
    try std.testing.expectEqual(@as(usize, 2), replayer.remaining());
    try std.testing.expectError(error.LogIncomplete, replayer.step());
    try std.testing.expectError(error.LogIncomplete, replayer.replayAll());
    // Refused before moving anything: the clock is untouched, so a caller that
    // decides to inspect the log by hand still has the recorded stamps.
    try std.testing.expectEqual(@as(i64, 0), manual.now_ms);
    try std.testing.expectEqual(@as(u64, 0), fresh.stats().received);

    fresh.stop();
    fresh.join();
    handle.stop();
    handle.join();
}

test "Runtime Replay: binding is checked, and an unbound track is not silently skipped" {
    const Alpha = struct {
        pub const Message = u32;
        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = self;
            _ = msg;
            _ = ctx;
        }
    };
    const Beta = struct {
        pub const Message = u64;
        pub fn handle(self: *@This(), msg: u64, ctx: anytype) anyerror!void {
            _ = self;
            _ = msg;
            _ = ctx;
        }
    };

    var clk = Clock.Manual{ .now_ms = 0 };
    var rt = Runtime.init(std.testing.allocator, std.testing.io, clk.clock());
    defer rt.deinit();

    const alpha = try rt.spawn(Alpha, .{}, .{ .capacity = 4, .record = .{ .id = "alpha", .capacity = 4 } });
    _ = try rt.spawn(Beta, .{}, .{ .capacity = 4, .record = .{ .id = "beta", .capacity = 4 } });
    const log = rt.deliveryLog() orelse return error.NoDeliveryLog;

    // A taken id is refused at the declaration: two tracks under one identity
    // would split a worker's deliveries and replay them as one.
    try std.testing.expectError(error.DuplicateTrackId, rt.spawn(Alpha, .{}, .{
        .capacity = 4,
        .record = .{ .id = "alpha", .capacity = 4 },
    }));
    try std.testing.expectEqual(@as(usize, 2), log.trackCount());

    // The replay's own target: same worker type, *not* recorded into this log —
    // see `BindError.TargetIsInSourceLog`.
    const fresh = try rt.spawn(Alpha, .{}, 4);

    try alpha.send(1);

    var manual = Clock.Manual{ .now_ms = 0 };
    var replayer = log.replayer(&manual);
    try std.testing.expectError(error.UnknownTrack, replayer.bind("gamma", fresh));
    // A handle whose `Message` is not what the track recorded: handing the
    // payload over would reinterpret memory.
    try std.testing.expectError(error.MessageTypeMismatch, replayer.bind("beta", fresh));
    // The handle that produced the track: replaying into it would re-record
    // every replayed delivery, and `step` would find those new entries again.
    try std.testing.expectError(error.TargetIsInSourceLog, replayer.bind("alpha", alpha));
    try std.testing.expect(!replayer.isFullyBound());
    // Delivering what *is* bound while dropping the rest would look like a
    // complete replay of a run that had one more worker in it.
    try std.testing.expectError(error.UnboundTrack, replayer.step());

    try replayer.bind("alpha", fresh);
    try std.testing.expectEqual(@as(u64, 0), (try replayer.step()).?.seq);
    try std.testing.expectEqual(@as(?recorder_mod.Step, null), try replayer.step());
    // The replay did not grow the log it was reading.
    try std.testing.expectEqual(@as(usize, 1), log.len());

    fresh.stop();
    fresh.join();
    alpha.stop();
    alpha.join();
}

test "Runtime Replay: replayAll hands a whole log to a fresh graph, in order" {
    const Sink = struct {
        pub const Message = u32;
        seen: [16]u32 = @splat(0),
        len: usize = 0,

        pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
            _ = ctx;
            self.seen[self.len] = msg;
            self.len += 1;
        }
    };

    // Phase 1: a recorded worker, five deliveries.
    var rec_clock = Clock.Manual{ .now_ms = 100 };
    var rt_rec = Runtime.init(std.testing.allocator, std.testing.io, rec_clock.clock());
    defer rt_rec.deinit();
    const recorded = try rt_rec.spawn(Sink, .{}, .{ .capacity = 8, .record = .{ .id = "sink", .capacity = 8 } });
    for (1..6) |i| {
        rec_clock.set(100 * @as(i64, @intCast(i)));
        try recorded.send(@intCast(i * 10));
    }
    try waitUntil(Published(@TypeOf(recorded.mailbox.received), u64){ .value = &recorded.mailbox.received, .want = 5 }, 5_000);

    // Phase 2: a fresh graph and `replayAll` — the convenience driver, which is
    // `step` in a loop and therefore has the same "hands over, never waits"
    // contract.
    var replay_clock = Clock.Manual{ .now_ms = 0 };
    var rt_rep = Runtime.init(std.testing.allocator, std.testing.io, replay_clock.clock());
    defer rt_rep.deinit();
    const fresh = try rt_rep.spawn(Sink, .{}, 8);

    const log = rt_rec.deliveryLog() orelse return error.NoDeliveryLog;
    var replayer = log.replayer(&replay_clock);
    try replayer.bind("sink", fresh);
    try std.testing.expectEqual(@as(usize, 5), try replayer.replayAll());
    try std.testing.expectEqual(@as(usize, 0), replayer.remaining());
    try std.testing.expectEqual(@as(?recorder_mod.Step, null), try replayer.step());
    // The driver moved its clock to the last recorded stamp and stopped there.
    try std.testing.expectEqual(@as(i64, 500), replay_clock.now_ms);

    try waitUntil(Published(@TypeOf(fresh.mailbox.received), u64){ .value = &fresh.mailbox.received, .want = 5 }, 5_000);
    fresh.stop();
    fresh.join();
    try std.testing.expectEqualSlices(u32, &.{ 10, 20, 30, 40, 50 }, fresh.state.seen[0..fresh.state.len]);

    recorded.stop();
    recorded.join();
}

// ---------------------------------------------------------------------------
// Supervision groups (docs/RUNTIME.md §14)
//
// The group machinery — policy, budget, escalation — is unit-tested in
// `supervisor.zig`, where a member is a probe and no thread is involved. What is
// tested here is the part that file cannot reach: that a member's own thread
// actually performs the teardown and the rebuild, that a group-mate is reached
// through its handle, and that the two counters land where they are readable.
//
// A rebuild that stopped short of `init` would leave `inits == 1` below — which
// is what makes these tests the guard for the mechanism rather than a description
// of it.
// ---------------------------------------------------------------------------

/// An actor that fails on every message and counts its own generations, so a
/// rebuild is observable as `inits` going up and `handled` continuing past it.
const AlwaysBoom = struct {
    pub const Message = u32;

    inits: *std.atomic.Value(u32),
    handled: *std.atomic.Value(u32),

    pub fn init(self: *@This(), _: anytype) !void {
        _ = self.inits.fetchAdd(1, .release);
    }

    pub fn deinit(_: *@This()) void {}

    pub fn handle(self: *@This(), _: u32, _: anytype) !void {
        _ = self.handled.fetchAdd(1, .monotonic);
        return error.Boom;
    }
};

/// A `run`-owned worker: it owns its loop, so nothing outside it can tear its
/// state down. Refused in a rebuilding group (§14.4).
const LoopOwned = struct {
    pub fn run(_: *@This(), ctx: anytype) anyerror!void {
        while (!ctx.stopped()) std.atomic.spinLoopHint();
    }
};

/// The same shape as `AlwaysBoom` but failing only every other message, so a
/// group-mate can be healthy while its sibling dies.
const EveryOtherBoom = struct {
    pub const Message = u32;

    inits: *std.atomic.Value(u32),
    handled: *std.atomic.Value(u32),
    n: u32 = 0,

    pub fn init(self: *@This(), _: anytype) !void {
        _ = self.inits.fetchAdd(1, .release);
    }

    pub fn deinit(_: *@This()) void {}

    pub fn handle(self: *@This(), _: u32, _: anytype) !void {
        _ = self.handled.fetchAdd(1, .monotonic);
        self.n +%= 1;
        if (self.n % 2 == 0) return error.Boom;
    }
};

test "Supervision (§14): one_for_one rebuilds a dying actor in place and it keeps serving" {
    var inits = std.atomic.Value(u32).init(0);
    var handled = std.atomic.Value(u32).init(0);

    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();

    const group = try rt.spawnGroup(.one_for_one);
    // Budget of 1 error per window: two messages in, the actor's own supervision
    // says stop, and the group says rebuild.
    const h = try rt.spawnActor(AlwaysBoom, .{ .inits = &inits, .handled = &handled }, 8, .{
        .max_errors = 1,
        .window_ms = 60_000,
        .group = group,
    });

    // Two messages per rebuild: the first error is inside budget, the second
    // takes the window over. So four messages are two rebuilds.
    for (0..4) |i| try h.send(@intCast(i));
    try waitUntil(Published(@TypeOf(handled), u32){ .value = &handled, .want = 4 }, 5_000);
    try waitUntil(Published(@TypeOf(h.group_restarts), u64){ .value = &h.group_restarts, .want = 2 }, 5_000);
    // Wait on the counter this test *asserts*, not on `group_restarts`: a
    // rebuild bumps the latter *before* it runs `init` (`rebuildWorker`),
    // so waiting on it and then reading `inits` is a check-then-assert race.
    // It flaked once in a full-suite run before this.
    try waitUntil(Published(@TypeOf(inits), u32){ .value = &inits, .want = 3 }, 5_000);

    // The actor really came back: three generations ran (the original plus two
    // rebuilds) and every message was handled by one of them.
    try std.testing.expectEqual(@as(u32, 3), inits.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 4), handled.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), h.stats().group_restarts);
    // Rebuilt is not stopped: the two readings must stay distinguishable.
    try std.testing.expect(!h.stats().stopped_by_supervisor);
    try std.testing.expectEqual(@as(u64, 0), rt.stats().supervised_stops);
    try std.testing.expectEqual(@as(u64, 2), rt.stats().group_restarts);

    // ...and it is still taking work, on the same handle a producer already has.
    try h.send(99);
    try waitUntil(Published(@TypeOf(handled), u32){ .value = &handled, .want = 5 }, 5_000);
}

test "Supervision (§14): without a group an actor stops where it stands, unchanged" {
    var inits = std.atomic.Value(u32).init(0);
    var handled = std.atomic.Value(u32).init(0);

    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();

    const h = try rt.spawnActor(AlwaysBoom, .{ .inits = &inits, .handled = &handled }, 8, .{
        .max_errors = 1,
        .window_ms = 60_000,
    });

    for (0..2) |i| try h.send(@intCast(i));
    try waitUntil(Published(@TypeOf(handled), u32){ .value = &handled, .want = 2 }, 5_000);
    try waitUntil(Published(@TypeOf(rt.supervised_stops), u64){ .value = &rt.supervised_stops, .want = 1 }, 5_000);

    // The v0.16/v0.17 contract, untouched: one generation, a stop, and a closed
    // mailbox rather than a rebuild.
    try std.testing.expectEqual(@as(u32, 1), inits.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), h.stats().group_restarts);
    try std.testing.expect(h.stats().stopped_by_supervisor);
    try std.testing.expectError(error.Closed, h.send(7));
}

test "Supervision (§14): one_for_all reaches a healthy group-mate through its handle" {
    var a_inits = std.atomic.Value(u32).init(0);
    var a_handled = std.atomic.Value(u32).init(0);
    var b_inits = std.atomic.Value(u32).init(0);
    var b_handled = std.atomic.Value(u32).init(0);

    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();

    const group = try rt.spawnGroup(.one_for_all);
    const a = try rt.spawnActor(AlwaysBoom, .{ .inits = &a_inits, .handled = &a_handled }, 8, .{
        .max_errors = 1,
        .window_ms = 60_000,
        .group = group,
    });
    const b = try rt.spawnActor(EveryOtherBoom, .{ .inits = &b_inits, .handled = &b_handled }, 8, .{
        // Never fails on its own: any rebuild it has was asked for by `a`.
        .max_errors = 0,
        .group = group,
    });

    for (0..2) |i| try a.send(@intCast(i));
    try waitUntil(Published(@TypeOf(a.group_restarts), u64){ .value = &a.group_restarts, .want = 1 }, 5_000);
    // Wait on the counter this test *asserts*, not on `group_restarts`: a
    // rebuild bumps the latter *before* it runs `init` (`rebuildWorker`),
    // so waiting on it and then reading `a_inits` is a check-then-assert race.
    // It flaked once in a full-suite run before this.
    try waitUntil(Published(@TypeOf(a_inits), u32){ .value = &a_inits, .want = 2 }, 5_000);
    // `b` never errored, and was still rebuilt — that is `one_for_all`, and it
    // is the half that cannot be tested without a real handle behind the member.
    try waitUntil(Published(@TypeOf(b.group_restarts), u64){ .value = &b.group_restarts, .want = 1 }, 5_000);
    // Wait on the counter this test *asserts*, not on `group_restarts`: a
    // rebuild bumps the latter *before* it runs `init` (`rebuildWorker`),
    // so waiting on it and then reading `b_inits` is a check-then-assert race.
    // It flaked once in a full-suite run before this.
    try waitUntil(Published(@TypeOf(b_inits), u32){ .value = &b_inits, .want = 2 }, 5_000);

    try std.testing.expectEqual(@as(u32, 2), a_inits.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), b_inits.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), b.stats().handler_errors);
    try std.testing.expect(!b.stats().stopped_by_supervisor);
    try std.testing.expect(!a.stats().stopped_by_supervisor);

    // `b` is still live and still serving, on the handle its producers hold.
    try b.send(1);
    try waitUntil(Published(@TypeOf(b_handled), u32){ .value = &b_handled, .want = 1 }, 5_000);
}

test "Supervision (§14): spending the restart budget takes the group down, and it is counted" {
    var a_inits = std.atomic.Value(u32).init(0);
    var a_handled = std.atomic.Value(u32).init(0);
    var b_inits = std.atomic.Value(u32).init(0);
    var b_handled = std.atomic.Value(u32).init(0);

    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();

    // One rebuild, then the group gives up: with no parent to escalate to, the
    // whole subtree stops rather than looping on `init` forever (§14.3).
    const group = try rt.spawnGroupWith(.one_for_all, .{ .max_restarts = 1, .window_ms = 60_000 });
    const a = try rt.spawnActor(AlwaysBoom, .{ .inits = &a_inits, .handled = &a_handled }, 8, .{
        .max_errors = 1,
        .window_ms = 60_000,
        .group = group,
    });
    const b = try rt.spawnActor(EveryOtherBoom, .{ .inits = &b_inits, .handled = &b_handled }, 8, .{
        .max_errors = 0,
        .group = group,
    });

    // One failing member, one affordable action: `one_for_all` rebuilds both.
    for (0..2) |i| try a.send(@intCast(i));
    // Wait for *both* before going on: the second round stops the group, and a
    // member that is stopped first never gets to read the rebuild it was asked
    // for ("stop wins"), which would make the count below a race rather than a
    // reading.
    try waitUntil(Published(@TypeOf(a.group_restarts), u64){ .value = &a.group_restarts, .want = 1 }, 5_000);
    try waitUntil(Published(@TypeOf(b.group_restarts), u64){ .value = &b.group_restarts, .want = 1 }, 5_000);
    // The counter is per **member rebuilt**, not per action taken: one
    // `one_for_all` decision lands here as two.
    try std.testing.expectEqual(@as(u64, 2), rt.stats().group_restarts);

    // Two more: the group is out of budget now, so there is no second action.
    for (0..2) |i| try a.send(@intCast(i));
    try waitUntil(Published(@TypeOf(rt.supervised_stops), u64){ .value = &rt.supervised_stops, .want = 2 }, 5_000);

    // Both members stopped — the failing one and the healthy one — and both are
    // on the counter. Before §14 this number had nowhere to live: a member's
    // death was a per-worker bool and nothing else.
    try std.testing.expectEqual(@as(u64, 2), rt.stats().supervised_stops);
    // Still two: an action the budget refused is not a rebuild.
    try std.testing.expectEqual(@as(u64, 2), rt.stats().group_restarts);
    try std.testing.expect(a.stopped_by_supervisor.load(.acquire));
    // `b` was taken down *by the group*, which is the other reason a member can
    // stop — and it is why the two flags exist separately.
    try std.testing.expect(b.stopped_by_group.load(.acquire));
    try std.testing.expect(!b.stats().stopped_by_supervisor);

    // A dead member refuses work loudly rather than buffering it.
    try std.testing.expectError(error.Closed, a.send(9));
    try std.testing.expectError(error.Closed, b.send(9));
}

test "Supervision (§14): a run-owned worker is refused in a rebuilding group, accepted in stop_group" {
    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();

    const restarting = try rt.spawnGroup(.one_for_one);
    // Nothing outside `LoopOwned.run` can tear its state down, so a group that
    // promises to rebuild it would be lying. Refused at spawn, said out loud.
    try std.testing.expectError(
        error.NotRestartable,
        rt.spawnActor(LoopOwned, .{}, 8, .{ .group = restarting }),
    );
    // The failed spawn left nothing behind: the group is still empty.
    try std.testing.expectEqual(@as(usize, 0), restarting.len());

    // `.stop_group` never rebuilds, so it has nothing to promise.
    const stopping = try rt.spawnGroup(.stop_group);
    const h = try rt.spawnActor(LoopOwned, .{}, 8, .{ .group = stopping });
    try std.testing.expectEqual(@as(usize, 1), stopping.len());
    // ...and being in a group still means being stoppable, which for a
    // `run`-owned worker is `ctx.stopped()`.
    h.stop();
    h.join();
}

test "Supervision (§14): a pooled member is rebuilt by its next claim" {
    var inits = std.atomic.Value(u32).init(0);
    var handled = std.atomic.Value(u32).init(0);

    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        .scheduler = .{ .max_pooled_workers = 4 },
    });
    defer rt.deinit();

    const group = try rt.spawnGroup(.one_for_one);
    const h = try rt.spawnActor(AlwaysBoom, .{ .inits = &inits, .handled = &handled }, .{
        .capacity = 8,
        .mode = .pooled,
    }, .{ .max_errors = 1, .window_ms = 60_000, .group = group });

    for (0..4) |i| try h.send(@intCast(i));
    try waitUntil(Published(@TypeOf(handled), u32){ .value = &handled, .want = 4 }, 5_000);
    try waitUntil(Published(@TypeOf(h.group_restarts), u64){ .value = &h.group_restarts, .want = 2 }, 5_000);
    // Wait on the counter this test *asserts*, not on `group_restarts`: a
    // rebuild bumps the latter *before* it runs `init` (`rebuildWorker`),
    // so waiting on it and then reading `inits` is a check-then-assert race.
    // It flaked once in a full-suite run before this.
    try waitUntil(Published(@TypeOf(inits), u32){ .value = &inits, .want = 3 }, 5_000);

    // Same accounting as the dedicated case: a pooled rebuild is the same
    // `deinit` + `init` on whichever thread holds the claim.
    try std.testing.expectEqual(@as(u32, 3), inits.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 2), h.stats().group_restarts);
    try std.testing.expectEqual(@as(u64, 2), rt.stats().group_restarts);
    try std.testing.expect(!h.stats().stopped_by_supervisor);
}

// §14.5's tree edge, end to end. `supervisor.zig` pins the policy arithmetic with
// probes; what only this test can say is that the *wiring* carries a failure up a
// real escalation and back down through real handles — a child group's exhausted
// budget reaching its parent, and the parent's `one_for_all` landing on a worker
// that is not even in the failing subtree.
//
// Verified red: dropping the `rt.nestGroup(parent, child)` call leaves the child
// with no parent, so its exhaustion stops the subtree instead of escalating —
// `waitUntil(inner.group_restarts >= 1)` times out and the run logs
// `stopped by supervisor` rather than `rebuilt by its supervision group`. The red
// is that timeout, not a compile error, which is the difference between a
// mutation that says something and one that only looks red.
test "Supervision (§14.5): a nested group escalates to its parent, and the parent's policy decides" {
    var inner_inits = std.atomic.Value(u32).init(0);
    var inner_handled = std.atomic.Value(u32).init(0);
    var outer_inits = std.atomic.Value(u32).init(0);
    var outer_handled = std.atomic.Value(u32).init(0);

    var rt = Runtime.init(std.testing.allocator, std.testing.io, .monotonic);
    defer rt.deinit();

    // The child cannot rebuild anything on its own (`max_restarts = 0`), so its
    // first exhausted failure escalates — that is the tree edge, and the only
    // thing this test is about.
    const child = try rt.spawnGroupWith(.one_for_one, .{ .max_restarts = 0 });
    const parent = try rt.spawnGroupWith(.one_for_all, .{ .max_restarts = 3 });

    const inner = try rt.spawnActor(AlwaysBoom, .{ .inits = &inner_inits, .handled = &inner_handled }, 8, .{
        .max_errors = 1,
        .window_ms = 60_000,
        .group = child,
    });
    // A healthy member of the *parent*: it never fails, so any rebuild it gets
    // came from the parent's policy reaching down to it.
    const outer = try rt.spawnActor(EveryOtherBoom, .{ .inits = &outer_inits, .handled = &outer_handled }, 8, .{
        .max_errors = 0,
        .group = parent,
    });
    try rt.nestGroup(parent, child);

    // Two errors take the child's own budget over; it has none, so it escalates.
    for (0..2) |i| try inner.send(@intCast(i));

    // `inner` is rebuilt by the child — with a budget the *parent* reset on the
    // way down, so the next escalation is not immediate.
    try waitUntil(Published(@TypeOf(inner.group_restarts), u64){ .value = &inner.group_restarts, .want = 1 }, 5_000);
    // ...and `outer`, which never failed and is not even in the same group, is
    // rebuilt too: the parent's `one_for_all` applies to its whole member list,
    // which contains the child subtree as one entry.
    try waitUntil(Published(@TypeOf(outer.group_restarts), u64){ .value = &outer.group_restarts, .want = 1 }, 5_000);

    // Wait on the counter this test *asserts*, not on `group_restarts`: a
    // rebuild bumps the latter *before* it runs `init` (`rebuildWorker`),
    // so waiting on it and then reading the init counter is a check-then-assert
    // race. Both init counters below are asserted this way; the `inner` one used
    // to be read straight after the wait above, and that is what flaked on a
    // loaded macOS CI runner (`expected 2, found 1`).
    try waitUntil(Published(@TypeOf(inner_inits), u32){ .value = &inner_inits, .want = 2 }, 5_000);
    try std.testing.expectEqual(@as(u32, 2), inner_inits.load(.monotonic));

    // Wait on the counter this test *asserts*, not on `group_restarts`: a
    // rebuild bumps the latter *before* it runs `init` (`rebuildWorker`),
    // so waiting on it and then reading `outer_inits` is a check-then-assert race.
    // It flaked once in a full-suite run before this.
    try waitUntil(Published(@TypeOf(outer_inits), u32){ .value = &outer_inits, .want = 2 }, 5_000);
    try std.testing.expectEqual(@as(u32, 2), outer_inits.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), outer.stats().handler_errors);
    try std.testing.expect(!inner.stats().stopped_by_supervisor);
    try std.testing.expect(!outer.stats().stopped_by_supervisor);

    // The parent's budget was spent on the escalation the child handed it, and
    // the child's was cleared by the rebuild — one decision, two counters, and
    // the difference is what keeps a doubly-exhausted tree from escalating on
    // every message.
    try std.testing.expectEqual(@as(u32, 1), parent.restartsInWindow());
    try std.testing.expectEqual(@as(u32, 0), child.restartsInWindow());
    try std.testing.expectEqual(@as(u64, 2), rt.stats().group_restarts);

    // Still serving on the handles their producers hold, and the child is still
    // reachable through the parent.
    try inner.send(9);
    try waitUntil(Published(@TypeOf(inner_handled), u32){ .value = &inner_handled, .want = 3 }, 5_000);
}

/// A pooled worker that **tops its own mailbox back up**, so its backlog can be
/// unbounded: it hands itself one message per message it runs. That is the shape
/// a starved scheduler needs — a busy worker with finite work cannot starve
/// anyone for long, so `docs/RUNTIME.md` §12.3's "one token per worker in a FIFO
/// ring" only means something against a worker that never runs out.
///
/// One-for-one rather than a periodic refill is what makes "never runs out" a
/// property instead of arithmetic: the queue level is whatever it was when the
/// worker last ran, so a mailbox with one message in it keeps one message in it
/// forever, and the hand-back's re-check always finds work. (A batch-and-refill
/// shape can drain to empty between refills, and an empty mailbox is exactly the
/// case where the test's premise — "A is busy" — stops being true.)
///
/// It checks `ctx.stopped()` before re-arming, which is also what lets shutdown
/// finish: a self-feeding worker that ignored the stop would keep a pool thread
/// claimed forever and `shutdown` waits for the batch in flight.
///
/// It also carries the *reference point* the fairness bound is measured from.
/// The obvious reference — "read A's counter, then send to B, then compare" —
/// straddles two threads, and A keeps running while the test thread is off-CPU:
/// measured on this machine under load, A's counter was already 56_228 when the
/// test thread got around to reading it, which says nothing about how long B
/// waited (see the test). `probe_sent` is set by the test thread once the
/// hand-off to the other worker has happened, and the first message this worker
/// runs after it can see the flag records `ref_after_sent` — so the reading is
/// "how much work did A do *after* the hand-off", taken on the thread that does
/// that work, with no window for the test thread's own scheduling to enter it.
const SelfFeedingWorker = struct {
    pub const Message = u32;
    seen: *std.atomic.Value(u64),
    /// Set by the test thread after `send` to the other worker returned.
    probe_sent: *const std.atomic.Value(bool),
    /// This worker's counter at the first message it ran after it could see
    /// `probe_sent`. Written once, by the pool thread.
    ref_after_sent: *std.atomic.Value(u64),
    ref_taken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn handle(self: *@This(), _: u32, ctx: anytype) !void {
        const n = self.seen.fetchAdd(1, .monotonic);
        if (self.probe_sent.load(.acquire) and !self.ref_taken.swap(true, .acq_rel)) {
            self.ref_after_sent.store(n + 1, .release);
        }
        if (!ctx.stopped()) ctx.handle.send(@truncate(n)) catch |err| {
            std.log.debug("[test] self-feed refused: {s}", .{@errorName(err)});
        };
    }
};

/// One message ever, and it records how much work the *other* worker had done
/// when it finally arrived.
const ArrivalProbeWorker = struct {
    pub const Message = u32;
    seen: *std.atomic.Value(u64),
    a_at_arrival: *std.atomic.Value(u64),
    a_seen: *const std.atomic.Value(u64),

    pub fn handle(self: *@This(), _: u32, _: anytype) !void {
        if (self.seen.load(.acquire) == 0) self.a_at_arrival.store(self.a_seen.load(.acquire), .release);
        _ = self.seen.fetchAdd(1, .release);
    }
};

test "Pooled (§12.3): an endlessly busy worker cannot starve a ready one" {
    var a_seen = std.atomic.Value(u64).init(0);
    var b_seen = std.atomic.Value(u64).init(0);
    var a_when_b = std.atomic.Value(u64).init(0);
    var probe_sent = std.atomic.Value(bool).init(false);
    var ref_after_sent = std.atomic.Value(u64).init(0);

    var rt = try Runtime.initWithOptions(std.testing.allocator, std.testing.io, .{
        // **One** pool thread, so the two workers genuinely compete for the
        // execution resource rather than each getting their own.
        .scheduler = .{ .max_pooled_workers = 4, .pool_threads = 1 },
    });
    defer rt.deinit();

    const a = try rt.spawn(SelfFeedingWorker, .{
        .seen = &a_seen,
        .probe_sent = &probe_sent,
        .ref_after_sent = &ref_after_sent,
    }, .{ .capacity = 64, .mode = .pooled });
    const b = try rt.spawn(ArrivalProbeWorker, .{
        .seen = &b_seen,
        .a_at_arrival = &a_when_b,
        .a_seen = &a_seen,
    }, .{ .capacity = 8, .mode = .pooled });

    // Give A a backlog, wait until it is demonstrably mining it, and only then
    // ask for B — so B arrives behind a worker that is already busy and never
    // about to stop.
    for (0..64) |i| a.send(@intCast(i)) catch break;
    try waitUntil(Published(@TypeOf(a_seen), u64){ .value = &a_seen, .want = 64 }, 5_000);
    try b.send(1);
    // The reference point, published **after** the hand-off (see
    // `SelfFeedingWorker`): from here on, the number A records is the part of
    // its progress that is a *fairness* reading rather than "the test thread had
    // not got around to sending yet".
    probe_sent.store(true, .release);

    // Reaching the next line **at all** is the property: A had unbounded work and
    // B was still served. `no starvation` is stated in §12.3 and, until now, was
    // assumed rather than asserted — every other counter in the runtime looks the
    // same whether or not it holds.
    try waitUntil(Published(@TypeOf(b_seen), u64){ .value = &b_seen, .want = 1 }, 5_000);

    // The premise, and it is the part a finite backlog could not give: B was not
    // served because A ran dry. A keeps running after B's arrival.
    const a_at_b = a_when_b.load(.acquire);
    try waitUntil(Published(@TypeOf(a_seen), u64){ .value = &a_seen, .want = a_at_b + 64 }, 5_000);

    // The tight half: how much work A did **between the hand-off and B being
    // served**. The ring is FIFO and a worker holds at most one token, so the
    // design predicts one `batch` of A ahead of B (A's batch ends, it hands the
    // claim back, B is already queued behind it). 256 is 16 batches — far more
    // than the design allows.
    //
    // This bound is also what `SchedulerConfig.batch` *is*: at `batch = 16` B is
    // served before A has run 256 more, and at `batch = 1_000_000` this line is
    // the one that fails — B is still served, but only after A's batch finally
    // runs out. So `batch` is not a throughput knob with a fairness side effect;
    // **it is the fairness bound**, and a worker's worst-case wait behind a busy
    // peer is one batch. Smaller batches cost throughput, larger ones cost
    // latency for everyone else — the trade `docs/RUNTIME.md` §12.5 records.
    //
    // The *shape* of this reading is what flaked on a loaded macOS CI runner, and
    // the flake was the test's, not the scheduler's: the older form compared A's
    // absolute counter against 256, but A's counter is driven by the pool thread
    // and the test thread only samples it — a test thread descheduled between
    // "A is busy" and "send to B" lets A run thousands of messages that have
    // nothing to do with B's wait. Measured here under load: 30 of 700 runs
    // failed the absolute bound while this post-hand-off reading never exceeded
    // 16, in any run, loaded or not. `ref_after_sent` moves with A, so what is
    // left is the scheduling delay itself; the saturating subtract covers the
    // one benign case — B is served before A runs another message, so the
    // reference lands after B's arrival and the wait is zero by construction.
    const served_after = a_when_b.load(.acquire) -| ref_after_sent.load(.acquire);
    try std.testing.expect(served_after < 256);
}
