//! The market module's public surface: how long the feed is willing to wait for
//! its drain marker to be accepted.

/// The marker must not be the message a full mailbox eats, so it is sent
/// blocking — but not forever: a runaway wait would turn into a hung example.
pub const marker_timeout_ms: u32 = 5_000;
