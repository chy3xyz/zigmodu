//! Risk: the stage that can say no — and says it once.
//!
//! It owns the size limits, so the `Order` that leaves here is already checked.
//! The drain marker is answered by arming the module's latch *after* the marker
//! has been accounted for, which is what lets `main` read `position` without a
//! lock: a waiter that observes the latch also observes everything the marker
//! followed.

const std = @import("std");
const c = @import("../../contracts.zig");
const model = @import("model.zig");

/// `ExecInbox` is exec's approved-order mailbox, supplied by `module.zig`.
pub fn Risk(comptime ExecInbox: type) type {
    return struct {
        pub const Message = c.Signal;

        exec: *ExecInbox,
        drained: *c.Latch,
        position: model.Position = .{},
        checked: u64 = 0,
        rejected: u64 = 0,
        shed: u64 = 0,

        pub fn handle(self: *@This(), s: c.Signal, ctx: anytype) anyerror!void {
            _ = ctx;
            if (s.shutdown) {
                std.log.info("[risk] drained: checked={d} rejected={d} position={d} shed={d}", .{
                    self.checked, self.rejected, self.position.net, self.shed,
                });
                self.drained.arm();
                // `sendBlocking`: the marker is the barrier and must not be the
                // one message that gets dropped on a full mailbox. The latch is
                // already armed, so a failure here is reported, not retried.
                self.exec.sendBlocking(.{ .shutdown = true }, 5_000) catch |err|
                    std.log.err("[risk] drain marker to exec not delivered: {s}", .{@errorName(err)});
                return;
            }

            self.checked += 1;
            const signed = model.Position.delta(s.side, s.qty);
            if (self.position.wouldBreach(signed)) {
                self.rejected += 1;
                return;
            }
            self.position.apply(signed);

            self.exec.send(.{
                .id = self.checked,
                .seq = s.seq,
                .side = s.side,
                .qty = s.qty,
                .price = s.price,
            }) catch |err| switch (err) {
                // Bounded queue: "exec is behind" is a decision (shed, count),
                // not an accident — and the queue never grows either way.
                error.Full, error.Timeout => self.shed += 1,
                error.Closed => {},
            };
        }
    };
}
