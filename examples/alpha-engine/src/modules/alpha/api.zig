//! The alpha module's public surface. Quotes arrive in a 256-slot mailbox; the
//! window length is the strategy's business and stays in `model.zig`.

/// Bounded: a full box sheds quotes instead of growing.
pub const mailbox_capacity: usize = 256;
