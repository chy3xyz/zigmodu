//! Runtime domain: workers, mailboxes, timers, ring buffers, pools, clocks.
//!
//! ```zig
//! const rt = zigmodu.runtime;                 // or `@import("zigmodu").runtime`
//! const worker = try app.runtime().spawn(MyWorker, .{}, 256);
//! ```
//!
//! Everything here is **additive**: the module API, DI, `Application.eventBus`,
//! lifecycle and HTTP surface are untouched, and an application that never
//! touches `runtime` behaves exactly as it did before (no threads are started).
//! See `docs/RUNTIME.md` for the compatibility principles and when each
//! primitive is the right tool.

const std = @import("std");

pub const ring = @import("runtime/ring.zig");
pub const clock = @import("runtime/clock.zig");
pub const timer_wheel = @import("runtime/timer_wheel.zig");
pub const object_pool = @import("runtime/object_pool.zig");
pub const mailbox = @import("runtime/mailbox.zig");
pub const sequencer = @import("runtime/sequencer.zig");
pub const hot_bus = @import("runtime/hot_bus.zig");
pub const runtime_impl = @import("runtime/runtime.zig");

/// Single-producer / single-consumer lock-free ring.
pub const RingBuffer = ring.RingBuffer;
/// Many-producer / single-consumer bounded queue (Vyukov).
pub const MpscRing = ring.MpscRing;
/// Injectable time source (`Clock.monotonic` in production, `Manual` in tests).
pub const Clock = clock.Clock;
/// Hierarchical timer wheel (O(1) schedule/cancel, `timer_wheel.slot_ms` ticks).
pub const Wheel = timer_wheel.Wheel;
/// Fixed-capacity object pool — bounded reuse instead of allocator churn.
pub const ObjectPool = object_pool.ObjectPool;
/// Bounded blocking mailbox (the worker hand-off).
pub const Mailbox = mailbox.Mailbox;

/// Monotonic sequence (order without a clock, unique without a lock).
pub const Sequencer = sequencer.Sequencer;
/// L0 publish/subscribe fan-out over worker mailboxes (frozen, drop-on-full).
pub const HotBus = hot_bus.HotBus;
/// Worker failure policy (`restart` / `stop` + windowed error budget).
pub const Supervision = runtime_impl.Supervision;

/// The runtime itself, plus the worker contract.
pub const Runtime = runtime_impl.Runtime;
pub const WorkerContext = runtime_impl.WorkerContext;
pub const WorkerStats = runtime_impl.WorkerStats;
pub const RuntimeStats = runtime_impl.RuntimeStats;

/// Handle to a spawned worker: `send` / `stop` / `after` / `stats`.
pub fn Handle(comptime W: type, comptime capacity: usize) type {
    return runtime_impl.Handle(W, capacity);
}

test {
    std.testing.refAllDecls(@This());
}
