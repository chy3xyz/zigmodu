//! Runtime domain: workers, mailboxes, timers, ring buffers, pools, clocks.
//!
//! ```zig
//! const runtime = @import("zigmodu").runtime;   // the namespace: RingBuffer, Clock, HotBus, Runtime…
//! const rt = try app.runtime();                 // first call creates and starts it
//! const worker = try rt.spawn(MyWorker, .{}, 256); // 256 = mailbox capacity (comptime)
//! // The long tail can share one pool thread instead (§12):
//! const audit = try rt.spawn(AuditWorker, .{}, .{ .capacity = 64, .mode = .pooled });
//! ```
//!
//! Everything here is **additive**: the module API, DI, `Application.eventBus`,
//! lifecycle and HTTP surface are untouched, and an application that never
//! touches `runtime` behaves exactly as it did before (no threads are started).
//! See `docs/RUNTIME.md` for the compatibility principles and when each
//! primitive is the right tool.

const std = @import("std");

/// Ring module: `RingBuffer` (SPSC) and `MpscRing` (Vyukov).
pub const ring = @import("runtime/ring.zig");
/// Clock module: injectable time source (`Clock.monotonic` / `Clock.manual`).
pub const clock = @import("runtime/clock.zig");
/// Timer wheel module: `Wheel` plus its geometry constants (`slot_ms`).
pub const timer_wheel = @import("runtime/timer_wheel.zig");
/// Precision deadline timer: a pre-sized deadline queue with a sleep-then-spin
/// wait loop, for sub-millisecond lateness at a CPU cost (`precision_timer`).
pub const precision_timer = @import("runtime/precision_timer.zig");
/// Object pool module: `ObjectPool` for bounded reuse over allocator churn.
pub const object_pool = @import("runtime/object_pool.zig");
/// Mailbox module: the bounded hand-off queue between threads.
pub const mailbox = @import("runtime/mailbox.zig");
/// Sequencer module: monotonic sequence numbers without a clock or a lock.
pub const sequencer = @import("runtime/sequencer.zig");
/// HotBus module: L0 fan-out to worker mailboxes (frozen, drops when full).
pub const hot_bus = @import("runtime/hot_bus.zig");
/// Recorder module: bounded delivery log + replay against a manual clock.
pub const recorder = @import("runtime/recorder.zig");
/// Scheduler module: the pool behind `.mode = .pooled` (docs/RUNTIME.md §12).
pub const scheduler = @import("runtime/scheduler.zig");
/// Supervisor module: supervision groups — policies, restart budget, the tree
/// (docs/RUNTIME.md §14).
pub const supervisor = @import("runtime/supervisor.zig");
/// Runtime implementation: `Runtime`, the worker contract, stats, supervision.
pub const runtime_impl = @import("runtime/runtime.zig");

/// Single-producer / single-consumer lock-free ring.
pub const RingBuffer = ring.RingBuffer;
/// Many-producer / single-consumer bounded queue (Vyukov).
pub const MpscRing = ring.MpscRing;
/// Injectable time source (`Clock.monotonic` in production, `Manual` in tests).
pub const Clock = clock.Clock;
/// Hierarchical timer wheel (O(1) schedule/cancel, `timer_wheel.slot_ms` ticks).
pub const Wheel = timer_wheel.Wheel;
/// Precision deadline timer: sub-microsecond lateness, paid for in CPU
/// (`default_spin_window_ns` of busy-poll per wait). Not a wheel replacement —
/// see the module doc comment for when each one is the right tool.
pub const PrecisionTimer = precision_timer.PrecisionTimer;
/// Default spin window of `PrecisionTimer` (the last N ns before a deadline are
/// busy-polled), derived from a measured `nanosleep`-overshoot distribution.
pub const default_spin_window_ns = precision_timer.default_spin_window_ns;
/// Longest single sleep `PrecisionTimer` will take, likewise derived from the
/// measured overshoot ladder (the overshoot grows with the request).
pub const default_max_sleep_chunk_ns = precision_timer.default_max_sleep_chunk_ns;
/// Fixed-capacity object pool — bounded reuse instead of allocator churn.
pub const ObjectPool = object_pool.ObjectPool;
/// Bounded blocking mailbox (the worker hand-off).
pub const Mailbox = mailbox.Mailbox;

/// Monotonic sequence (order without a clock, unique without a lock).
pub const Sequencer = sequencer.Sequencer;
/// L0 publish/subscribe fan-out over worker mailboxes (frozen, drop-on-full).
pub const HotBus = hot_bus.HotBus;
/// Opt-in, zero-allocation log of the delivery stream; replay drives `Clock.Manual`.
pub const Recorder = recorder.Recorder;
/// Worker failure policy (`restart` / `stop` + windowed error budget).
pub const Supervision = runtime_impl.Supervision;
/// Supervision group: what a set of workers does about each other's failures
/// (`one_for_one` / `one_for_all` / `rest_for_one` / `stop_group`, §14).
pub const Group = runtime_impl.Group;
/// A group's failure policy (§14).
pub const GroupPolicy = runtime_impl.GroupPolicy;
/// A group's restart budget: `max_restarts` inside `window_ms` (§14).
pub const Intensity = runtime_impl.Intensity;
/// Who runs a worker's `handle`: its own thread (`.dedicated`) or the pool.
pub const SpawnMode = runtime_impl.SpawnMode;
/// What a worker's handler does with its thread — `.cpu` or `.blocking` — i.e.
/// which pool may run it. Declared, never detected (docs/RUNTIME.md §6).
pub const ExecutionClass = runtime_impl.ExecutionClass;
/// What a stop for good does with the queue: abandon it (`.immediate`) or work
/// it off first (`.drain`). Undeclared, a worker keeps its mode's answer.
pub const StopPolicy = runtime_impl.StopPolicy;
/// `spawn`'s last argument, in either shape: `256` or `.{ .capacity = 256, .mode = .pooled }`.
pub const SpawnConfig = runtime_impl.SpawnConfig;
/// How a pool is declared: `Runtime.initWithOptions(.{ .scheduler = ... })`.
pub const SchedulerConfig = runtime_impl.SchedulerConfig;
/// Trace id a worker message can carry (`sendTraced` → `ctx.traceId()`).
pub const TraceId = runtime_impl.TraceId;

/// The runtime itself, plus the worker contract.
pub const Runtime = runtime_impl.Runtime;
/// What a worker sees inside `handle`: sender handle, timers, stats.
pub const WorkerContext = runtime_impl.WorkerContext;
/// Per-worker counters: queue depth, sent/received, `dropped_full`, errors.
pub const WorkerStats = runtime_impl.WorkerStats;
/// Runtime-wide counters: workers alive, messages sent/dropped, timer lag.
pub const RuntimeStats = runtime_impl.RuntimeStats;

/// Handle to a spawned worker: `send` / `stop` / `after` / `stats`.
pub fn Handle(comptime W: type, comptime capacity: usize) type {
    return runtime_impl.Handle(W, capacity);
}

test {
    std.testing.refAllDecls(@This());
}
