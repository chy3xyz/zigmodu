//! The book module's domain: the touch, and the one number that shapes it.

/// Half-spread the book quotes around the last print, in price units.
pub const half_spread: i64 = 1;

pub const TopOfBook = struct {
    best_bid: i64 = 0,
    best_ask: i64 = 0,

    /// A print moves the touch to `price ± half_spread`. The book is a filter,
    /// not a matcher: this example's venue is the paper exchange downstream.
    pub fn quote(self: *TopOfBook, price: i64) void {
        self.best_bid = price - half_spread;
        self.best_ask = price + half_spread;
    }

    pub fn mid(self: *const TopOfBook) i64 {
        return @divTrunc(self.best_bid + self.best_ask, 2);
    }
};

/// The day's own reference: what every accepted print averaged out to.
///
/// The day-end snapshot carries it so the agent's proposal is a statement about
/// the tape ("the mid is below the day's average") rather than a number this
/// module decided to hand over — the agent still gets no vote on what the
/// signal is.
pub const Tape = struct {
    notional: i64 = 0,
    volume: i64 = 0,

    pub fn record(self: *Tape, price: i64, qty: i64) void {
        self.notional += price * qty;
        self.volume += qty;
    }

    pub fn vwap(self: *const Tape) i64 {
        if (self.volume == 0) return 0;
        return @divTrunc(self.notional, self.volume);
    }
};
