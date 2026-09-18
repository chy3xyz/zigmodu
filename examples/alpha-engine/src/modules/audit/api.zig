//! The audit module's public surface: how big the slow traversal's mailbox is,
//! and how many subscribers the fan-out was sized for.

/// The audit worker is allowed to be behind — and it is *sized* to be: 16 slots
/// against the book's 64-slot intake means one drain burst of the book already
/// overflows it, so the shed is a property of the sizing rather than a race with
/// the scheduler. An audit trail that misses events is acceptable; a publisher
/// that waits for it is not.
pub const mailbox_capacity: usize = 16;

/// Two subscribers ride the bus (the audit worker and the metrics sink). A
/// comptime-sized array, so a third one has to be paid for at compile time.
pub const subscriber_slots: usize = 4;
