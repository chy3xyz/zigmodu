//! Alpha: the signal stage.
//!
//! It publishes a *view* — a side, a size, how stretched the price is — and
//! never an order. Whoever needs to be able to veto sits downstream, on the
//! other side of the mailbox.

const std = @import("std");
const c = @import("../../contracts.zig");
const model = @import("model.zig");

/// `RiskInbox` is risk's signal mailbox, supplied by `module.zig`.
pub fn Alpha(comptime RiskInbox: type) type {
    return struct {
        pub const Message = c.Quote;

        risk: *RiskInbox,
        window: model.Window = .{},
        signals: u64 = 0,
        shed: u64 = 0,

        pub fn handle(self: *@This(), q: c.Quote, ctx: anytype) anyerror!void {
            _ = ctx;
            if (q.shutdown) {
                std.log.info("[alpha] drained: signals={d} shed={d}", .{ self.signals, self.shed });
                // `sendBlocking`: the drain marker travels the same FIFO as the
                // data and must not be the message a full mailbox eats. If it
                // does not get through, the barrier downstream is broken — say so.
                self.risk.sendBlocking(.{ .shutdown = true }, 5_000) catch |err|
                    std.log.err("[alpha] drain marker to risk not delivered: {s}", .{@errorName(err)});
                return;
            }

            if (!self.window.push(q.mid)) return;
            const pull = self.window.pull(q.mid);
            if (pull == 0) return;

            self.signals += 1;
            self.risk.send(.{
                .seq = q.seq,
                .side = if (pull > 0) .buy else .sell,
                .qty = model.Window.sizeFor(pull),
                .price = q.mid,
                .pull = pull,
            }) catch |err| switch (err) {
                error.Full, error.Timeout => self.shed += 1,
                error.Closed => {},
            };
        }
    };
}
