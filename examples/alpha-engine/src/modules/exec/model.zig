//! The exec module's domain model: the paper venue's own books.
//!
//! Pure state plus the two rules that move it — no threading, no handles, no
//! message types. Everything here is reachable only from `service.zig`, which is
//! what makes "one thread owns the exchange" a property of the layout.

const c = @import("../../contracts.zig");

/// The adapter for Replay/Paper mode: fills instantly at the price the order
/// carried (the mid the book quoted), no slippage, no fees. It is an adapter,
/// not a backtester (`docs/dev/alpha-engine-spec.md` §5) — a real venue would
/// replace `submit` and nothing else in this example.
pub const PaperExchange = struct {
    fills: u64 = 0,
    filled_qty: i64 = 0,
    position: i64 = 0,
    cash: i64 = 0,
    last_mid: i64 = 0,

    pub fn submit(self: *PaperExchange, order: c.Order) c.Fill {
        self.fills += 1;
        self.filled_qty += order.qty;
        self.last_mid = order.price;
        switch (order.side) {
            .buy => {
                self.position += order.qty;
                self.cash -= order.qty * order.price;
            },
            .sell => {
                self.position -= order.qty;
                self.cash += order.qty * order.price;
            },
        }
        return .{ .order_id = order.id, .price = order.price, .qty = order.qty };
    }

    /// Mark-to-market: cash plus inventory valued at the last print.
    pub fn pnl(self: *const PaperExchange) i64 {
        return self.cash + self.position * self.last_mid;
    }
};

/// The desk: the authorized side of an agent proposal, and the reason this
/// example can say "the agent never executed".
///
/// Nothing here is the agent's. The rule below is a policy a person owns, it
/// lives in the module that owns the exchange, and it runs on its own thread on
/// the far side of a mailbox from the agent. The agent contributes an argument;
/// this decides what happens to it.
///
/// The first condition is the interesting one: an order only leaves the desk for
/// a proposal whose own gate said `execute_not_permitted`. Anything else would
/// mean the agent executed — `executed` never reaches a mailbox, and
/// `propose_refused` / `risk_rejected` / `needs_human` are not instructions.
pub const Desk = struct {
    /// The desk's own size limit, independent of the strategy's `max_position`
    /// and of the agent's sizing. If those two disagree with this one, this one
    /// is what the venue sees.
    pub const max_qty: i64 = 8;

    pub fn approves(p: c.ProposalEnvelope) bool {
        return p.verdict == .execute_not_permitted and p.qty > 0 and p.qty <= max_qty;
    }
};
