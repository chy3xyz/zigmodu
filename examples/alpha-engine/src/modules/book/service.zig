//! OrderBook: the stage that fans out.
//!
//! Every accepted print does three things, in this order: it moves the touch,
//! it offers the top of book to alpha, and it publishes the print to the L0 bus.
//! None of those three may block — a full mailbox is a counted drop, and that is
//! the entire backpressure story in this example.
//!
//! The day-end snapshot is where P3 hangs off: the timer message that already
//! marked the end of the day now also *wakes the agent*, by handing the propose
//! module a summary of the tape. Same message, same thread that owns the state
//! the summary is made of — no second timer, no second source of truth.

const std = @import("std");
const c = @import("../../contracts.zig");
const model = @import("model.zig");

/// `AlphaInbox` is alpha's quote mailbox, `Bus` is the fan-out type and
/// `ProposeInbox` is the agent side's trigger mailbox, all supplied by
/// `module.zig`. The worker only needs to know how to push into them — the
/// trade-off for a module that never imports its neighbours.
pub fn OrderBook(comptime AlphaInbox: type, comptime Bus: type, comptime ProposeInbox: type) type {
    return struct {
        pub const Message = c.MarketData;

        top: model.TopOfBook = .{},
        tape: model.Tape = .{},
        bids: u64 = 0, // prints that came in on the bid side
        asks: u64 = 0, // prints that came in on the ask side
        snapshots: u64 = 0,
        snapshot_shed: u64 = 0,
        coalesced: u64 = 0,
        alpha: *AlphaInbox,
        bus: *Bus,
        propose: *ProposeInbox,
        /// Armed when the snapshot timer message has been handled.
        snapshot_taken: *c.Latch,

        pub fn handle(self: *@This(), md: c.MarketData, ctx: anytype) anyerror!void {
            _ = ctx;
            switch (md.kind) {
                .snapshot => {
                    self.snapshots += 1;
                    const snap = c.DayEndSnapshot{
                        .bid = self.top.best_bid,
                        .ask = self.top.best_ask,
                        .mid = self.top.mid(),
                        .vwap = self.tape.vwap(),
                        .prints = self.bids + self.asks,
                    };
                    std.log.info("[book] day-end snapshot #{d}: bid={d} ask={d} mid={d} vwap={d} prints={d}", .{
                        self.snapshots, snap.bid, snap.ask, snap.mid, snap.vwap, snap.prints,
                    });
                    // Fire-and-forget, like every other hop in this example: the
                    // agent side being behind is not a reason for the book to
                    // stall. A shed snapshot is counted, and `main` waits on the
                    // agent's own latch, so it can never read a report whose
                    // trigger was silently dropped.
                    self.propose.send(snap) catch |err| switch (err) {
                        error.Full, error.Timeout => self.snapshot_shed += 1,
                        error.Closed => {},
                    };
                    self.snapshot_taken.arm();
                },
                .shutdown => {
                    std.log.info("[book] marker in: prints={d} coalesced={d}", .{ self.bids + self.asks, self.coalesced });
                    // `sendBlocking`: the marker is the barrier and must not be
                    // the one message that gets dropped, or `main` waits for a
                    // marker that never comes. A timeout here is a *broken
                    // barrier*, so it is logged rather than swallowed.
                    self.alpha.sendBlocking(.{ .shutdown = true }, 5_000) catch |err|
                        std.log.err("[book] drain marker to alpha not delivered: {s}", .{@errorName(err)});
                    // The book does *not* stop here — its mailbox has to stay
                    // open for the snapshot timer. `app.stop()` owns shutdown.
                },
                .tick => {
                    if (md.side == .buy) self.bids += 1 else self.asks += 1;
                    self.top.quote(md.price);
                    self.tape.record(md.price, md.qty);

                    self.alpha.send(.{
                        .seq = md.seq,
                        .bid = self.top.best_bid,
                        .ask = self.top.best_ask,
                        .mid = self.top.mid(),
                    }) catch |err| switch (err) {
                        // Bounded queue: "alpha is behind" is a decision (shed
                        // this quote, count it), not an accident — and the queue
                        // never grows either way.
                        error.Full, error.Timeout => self.coalesced += 1,
                        error.Closed => {},
                    };

                    // L0 fan-out of every accepted print. `publish` never blocks
                    // and never allocates: a subscriber that cannot keep up (the
                    // audit worker, by design) is dropped and counted, never
                    // waited on. The *error* path is not load — it is an unfrozen
                    // bus, i.e. a wiring bug — so it is reported, not swallowed.
                    _ = self.bus.publish(.{ .seq = md.seq, .price = md.price, .qty = md.qty, .side = md.side }) catch |err|
                        std.log.err("[book] L0 fan-out not wired: {s}", .{@errorName(err)});
                },
            }
        }
    };
}
