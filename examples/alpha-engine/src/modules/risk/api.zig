//! The risk module's public surface. Signals arrive in a 256-slot mailbox;
//! nothing else about risk is anybody's business.

/// Bounded: a full box sheds signals instead of growing.
pub const mailbox_capacity: usize = 256;
