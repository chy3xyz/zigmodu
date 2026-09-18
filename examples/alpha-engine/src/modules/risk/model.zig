//! The risk module's domain: one net position and one limit.
//!
//! A real risk worker checks margin, symbol and strategy limits; one number is
//! enough to show the stage that says "no" — and the rules for moving it are
//! here, not in the worker, so they can be read (and tested) on their own.

const c = @import("../../contracts.zig");

/// Size limit per side, in contracts.
pub const max_position: i64 = 24;

pub const Position = struct {
    net: i64 = 0,

    /// What a signal does to the book, as a signed quantity.
    pub fn delta(side: c.Side, qty: i64) i64 {
        return if (side == .buy) qty else -qty;
    }

    pub fn wouldBreach(self: *const Position, signed: i64) bool {
        return @abs(self.net + signed) > max_position;
    }

    pub fn apply(self: *Position, signed: i64) void {
        self.net += signed;
    }
};
