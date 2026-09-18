//! Execution: the adapter boundary.
//!
//! The worker routes; the exchange prices. Fills leave through exactly one
//! mailbox, to an upstream that is supervised — reporting is off the critical
//! path, so a full or closed reporter mailbox may never stall routing.
//!
//! P3 adds the second door into this mailbox: `Authorizer`, the desk, which is
//! where an agent's proposal turns into an order. It is a worker on the far side
//! of a mailbox from the agent, and it reaches the exchange the only way anything
//! else does — by sending an order to the router. The agent has no such handle,
//! which is what "the agent cannot trade" means in code.

const std = @import("std");
const c = @import("../../contracts.zig");
const model = @import("model.zig");

/// `ReporterInbox` is the reporter's mailbox type, supplied by `module.zig`: the
/// service layer knows the *contract* it sends into, never the module that
/// declared it.
pub fn Execution(comptime ReporterInbox: type) type {
    return struct {
        pub const Message = c.Order;

        exchange: model.PaperExchange,
        reporter: *ReporterInbox,
        /// Armed when the drain marker has been accounted for.
        drained: *c.Latch,
        /// Armed once an order the *desk* authorized has been filled. A second
        /// latch because it answers a different question: `drained` reports on
        /// the replay, this reports on a flow that starts later and ends later.
        authorized_done: *c.Latch,
        routed: u64 = 0,
        /// Fills that came from an authorized proposal, not from the replay
        /// chain. The P3 assertion is on this number, because
        /// `exchange.fills > 0` is already true for reasons P3 did not
        /// contribute to.
        authorized_fills: u64 = 0,
        report_shed: u64 = 0,
        last_fill: c.Fill = .{ .order_id = 0, .price = 0, .qty = 0 },

        pub fn handle(self: *@This(), o: c.Order, ctx: anytype) anyerror!void {
            _ = ctx;
            if (o.shutdown) {
                std.log.info("[exec] drained: routed={d} fills={d} last={d} position={d} pnl={d} report_shed={d}", .{
                    self.routed, self.exchange.fills, self.last_fill.price, self.exchange.position, self.exchange.pnl(), self.report_shed,
                });
                self.drained.arm();
                return;
            }

            self.routed += 1;
            self.last_fill = self.exchange.submit(o);
            if (o.origin == .authorized) {
                self.authorized_fills += 1;
                // After `submit`, never before: a reader that sees the latch
                // sees the fill it is asking about.
                self.authorized_done.arm();
            }
            self.reporter.send(self.last_fill) catch |err| switch (err) {
                error.Full, error.Timeout, error.Closed => self.report_shed += 1,
            };
        }
    };
}

/// The desk's worker: it reads an agent's proposal and decides.
///
/// Two properties worth keeping when this is copied: the decision is made here,
/// not by the agent (the agent's verdict is an *input* to `Desk.approves`, and
/// the only verdict that can pass is the one where the agent said it could not
/// act); and the resulting `Order` is built here, from the envelope's contents,
/// so the agent never composes a message the exchange understands.
pub fn Authorizer(comptime OrderInbox: type) type {
    return struct {
        pub const Message = c.ProposalEnvelope;

        orders: *OrderInbox,
        approved: u64 = 0,
        declined: u64 = 0,
        shed: u64 = 0,

        pub fn handle(self: *@This(), p: c.ProposalEnvelope, ctx: anytype) anyerror!void {
            _ = ctx;
            if (!model.Desk.approves(p)) {
                std.log.info("[desk] declined proposal #{d}: qty={d} verdict={s}", .{ p.id, p.qty, @tagName(p.verdict) });
                self.declined += 1;
                return;
            }
            self.approved += 1;
            std.log.info("[desk] authorized proposal #{d}: {s} {d} @ {d} (risk={s})", .{
                p.id, @tagName(p.side), p.qty, p.price, @tagName(p.risk_level),
            });
            self.orders.send(.{
                .id = p.id,
                .side = p.side,
                .qty = p.qty,
                .price = p.price,
                .origin = .authorized,
            }) catch |err| switch (err) {
                error.Full, error.Timeout => self.shed += 1,
                error.Closed => {},
            };
        }
    };
}

/// An actor whose upstream is *always* down: it errors on every message, so the
/// 3-error budget is what stands between this process and a thread that logs
/// forever while looking alive — the difference between `spawn` and `spawnActor`.
pub const FaultyFillReporter = struct {
    pub const Message = c.Fill;
    attempts: u32 = 0,

    pub fn handle(self: *@This(), f: c.Fill, ctx: anytype) anyerror!void {
        _ = f;
        _ = ctx;
        self.attempts += 1;
        return error.UpstreamUnavailable;
    }
};
