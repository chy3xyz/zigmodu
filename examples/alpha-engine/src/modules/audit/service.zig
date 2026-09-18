//! The audit module's two subscribers: a worker that is slow by design, and a
//! plain sink that is not a worker at all.

const std = @import("std");
const c = @import("../../contracts.zig");
const model = @import("model.zig");

/// Fan-out target: an "audit trail" that spins on every event, which is what
/// makes the bus's drop counter move. A slow subscriber is dropped, never
/// allowed to slow the publisher down.
pub const Audit = struct {
    pub const Message = c.Delta;

    trail: model.Trail = .{},

    pub fn handle(self: *@This(), d: c.Delta, ctx: anytype) anyerror!void {
        _ = ctx;
        self.trail.record(d);
        var spins: usize = 0;
        while (spins < 200_000) : (spins += 1) std.atomic.spinLoopHint(); // pretend work
    }
};

/// Anything with a `deliver` thunk can ride the bus (metrics today, a websocket
/// broadcaster tomorrow), so this one needs no thread and no mailbox: O(1) per
/// event means it always accepts.
pub fn MetricsSink(comptime Bus: type) type {
    return struct {
        const Self = @This();

        tally: model.Tally = .{},

        pub fn sink(self: *Self) Bus.Sink {
            return .{
                .ctx = @ptrCast(self),
                .deliver = struct {
                    fn deliver(ctx: *anyopaque, d: c.Delta) bool {
                        // Provenance for the cast below: the bus was handed
                        // `&Module.sink`, a file-scope value with static storage
                        // that nothing moves or frees, so it cannot tear.
                        const m: *Self = @ptrCast(@alignCast(ctx)); // audit: ignore b21
                        m.tally.record(d);
                        return true; // always accepts: it does O(1) work
                    }
                }.deliver,
            };
        }
    };
}
