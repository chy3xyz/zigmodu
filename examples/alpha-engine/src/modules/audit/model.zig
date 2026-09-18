//! The audit module's domain: two ways of remembering a print.
//!
//! Both are plain counters — what makes them interesting is that they are
//! allowed to *disagree*. The trail is deliberately slow and may be dropped by
//! the bus; the tally does O(1) work and therefore never is. Keeping the two
//! rules together here is what makes that contrast readable.

const c = @import("../../contracts.zig");

/// The audit trail: keeps the count and the last print it saw.
pub const Trail = struct {
    kept: u64 = 0,
    last_price: i64 = 0,

    pub fn record(self: *Trail, d: c.Delta) void {
        self.kept += 1;
        self.last_price = d.price;
    }
};

/// The metrics tally: the O(1) control group that always accepts, which is what
/// proves the drops belong to the slow subscriber rather than to the bus.
pub const Tally = struct {
    deltas: u64 = 0,
    last_price: i64 = 0,

    pub fn record(self: *Tally, d: c.Delta) void {
        self.deltas += 1;
        self.last_price = d.price;
    }
};
