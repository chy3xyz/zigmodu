//! The book module's public surface: the mailbox the feed outruns, and when the
//! snapshot timer fires.

/// 64 slots against a 2,000-point replay: small enough that `error.Full` is a
/// certainty rather than a hope — backpressure you can count, not claim.
pub const mailbox_capacity: usize = 64;

/// The snapshot is a timer *message*, so it lands on the book's own thread after
/// the replay has been drained.
pub const snapshot_after_ms: i64 = 200;
