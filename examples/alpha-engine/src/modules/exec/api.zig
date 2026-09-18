//! The exec module's public surface: the numbers and the failure policy other
//! modules (and the framework) are allowed to depend on.
//!
//! This example has no HTTP surface, so there are no `routes` here; the numbers
//! below are the whole contract exec publishes. Were this module to grow an API,
//! `pub const routes` (ComptimeRouter) would live in this file.

const runtime = @import("zigmodu").runtime;

/// Approved orders arrive in a 256-slot mailbox. Bounded: a queue that is behind
/// sheds and counts, it never grows.
pub const order_capacity: usize = 256;

/// The desk's inbox is tiny on purpose: one day-end snapshot per run, and the
/// agent may hand over one proposal per leg it argued. A handful of slots is
/// already more than the loop can use, so a future agent that finds a way to
/// chatter is visible as backpressure instead of as a growing queue.
pub const desk_capacity: usize = 8;

/// The fill reporter gets a deliberately smaller box, because it is allowed to
/// miss reports: routing must not wait for an audit trail.
pub const reporter_capacity: usize = 32;

/// 3 errors inside the window means "stop and close the mailbox", not "log
/// forever".
pub const supervision: runtime.Supervision = .{ .max_errors = 3, .window_ms = 60_000 };
