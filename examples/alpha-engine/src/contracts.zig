//! The pipeline's shared kernel: the messages that cross a module boundary, plus
//! the one synchronization primitive the drain barrier needs.
//!
//! It sits **outside** `src/modules/` on purpose. A module never imports another
//! module's files — that is exactly what `zmodu doctor` reports as an
//! entanglement — so a shape two modules exchange cannot live in either one of
//! them. Same place, same reason as `examples/tenant-mgmt`'s
//! `src/business/enums.zig`: shared vocabulary that nobody in particular owns.
//!
//! One type per hop, so each worker's input is a shape it can own outright:

const std = @import("std");
const runtime = @import("zigmodu").runtime;
const ai = @import("zigmodu").ai;

pub const Side = enum { buy, sell };

/// The vocabulary the P3 loop is written in — the framework's own, so the
/// example cannot drift from what `ai.ProposalPipeline` actually reports.
pub const ProposalVerdict = ai.ProposalVerdict;
pub const RiskLevel = ai.risk.RiskLevel;

/// market → book. `.snapshot` is the timer message, `.shutdown` the drain marker.
pub const MarketData = struct {
    kind: Kind = .tick,
    seq: u32 = 0,
    price: i64 = 0,
    qty: i64 = 0,
    side: Side = .buy,

    pub const Kind = enum { tick, snapshot, shutdown };
};

/// book → the L0 fan-out: every accepted print, by value.
pub const Delta = struct {
    seq: u32 = 0,
    price: i64 = 0,
    qty: i64 = 0,
    side: Side = .buy,
};

/// book → alpha: the top of book the alpha gets to see.
pub const Quote = struct {
    seq: u32 = 0,
    bid: i64 = 0,
    ask: i64 = 0,
    mid: i64 = 0,
    shutdown: bool = false,
};

/// alpha → risk: a directional *view*, still unsized for risk to veto.
pub const Signal = struct {
    seq: u32 = 0,
    side: Side = .buy,
    qty: i64 = 0,
    price: i64 = 0,
    /// How stretched the price is against the alpha's mean (signed).
    pull: i64 = 0,
    shutdown: bool = false,
};

/// risk → exec: an approved order; risk owns the size limits.
pub const Order = struct {
    id: u64 = 0,
    seq: u32 = 0,
    side: Side = .buy,
    qty: i64 = 0,
    price: i64 = 0,
    shutdown: bool = false,
    origin: Origin = .pipeline,

    /// Who asked for this order. The exchange does not care — it fills either
    /// way — but the *count* does: "an agent proposal was authorized and
    /// filled" and "the replay chain filled" are different facts, and only the
    /// first one is the P3 acceptance gate.
    pub const Origin = enum { pipeline, authorized };
};

/// exec → the supervised fill reporter.
pub const Fill = struct { order_id: u64, price: i64, qty: i64 };

/// book → propose: what the day-end snapshot says, and the *only* thing the
/// agent is woken by. It is a summary of the tape (the touch plus what the day
/// averaged to), not a handle: the agent gets numbers, never the book.
pub const DayEndSnapshot = struct {
    bid: i64 = 0,
    ask: i64 = 0,
    mid: i64 = 0,
    /// Volume-weighted average of the accepted prints — the day's own
    /// reference. Mean reversion against it is a claim about the tape rather
    /// than a number someone handed the agent.
    vwap: i64 = 0,
    prints: u64 = 0,
};

/// propose → exec (to its desk): the agent's *conclusion*, never an order. The
/// envelope is deliberately dumb data — no function pointer, no handle, no
/// `Slice`-shaped borrow — because it is the one artifact that crosses from the
/// agent's world to the authorized one, and it has to be inspectable.
pub const ProposalEnvelope = struct {
    id: u64 = 0,
    side: Side = .buy,
    qty: i64 = 0,
    price: i64 = 0,
    /// What the agent's own gate decided. `execute_not_permitted` is the
    /// normal ending: the agent may propose, it may not act.
    verdict: ProposalVerdict = .execute_not_permitted,
    risk_level: RiskLevel = .low,
};

/// One happens-before flag, owned by the module that finishes with the shutdown
/// marker and waited on by `main` — another thread, which is the only reason
/// this needs an acquire/release edge at all. Worker state stays single-owner:
/// this is the *only* synchronized cell in the example.
///
/// Waiting is a sleep loop with a deadline, so a stuck stage ends the run as a
/// truncated report instead of a hung example.
pub const Latch = struct {
    armed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn arm(self: *Latch) void {
        self.armed.store(true, .release);
    }

    pub fn isArmed(self: *const Latch) bool {
        return self.armed.load(.acquire);
    }

    pub fn await(self: *const Latch, io: std.Io, clock: runtime.Clock, deadline_ms: i64) void {
        while (!self.isArmed()) {
            if (clock.nowMs() > deadline_ms) return;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
        }
    }
};
