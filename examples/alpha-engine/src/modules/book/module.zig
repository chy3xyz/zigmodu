//! The book module: the top of book, its fan-out, and the snapshot timer.
//!
//! Three declared dependencies, all satisfied by type rather than by import:
//! `alpha` receives the quotes, `audit` owns the bus the prints are published
//! into, and `propose` is woken by the day-end snapshot. Initialization order
//! follows the declared graph, so all three handles exist by the time `initWith`
//! runs.

const runtime = @import("zigmodu").runtime;
const zmodu = @import("zigmodu");
const c = @import("../../contracts.zig");
const api = @import("api.zig");
const service = @import("service.zig");

pub fn Module(comptime Alpha: type, comptime Audit: type, comptime Propose: type) type {
    return struct {
        pub const info = zmodu.api.Module{
            .name = "book",
            .description = "Order book: top of book, L0 fan-out of accepted prints, snapshot timer",
            .dependencies = &.{ "alpha", "audit", "propose" },
        };

        pub const Worker = service.OrderBook(Alpha.Inbox, Audit.Bus, Propose.Inbox);
        /// The handle type the feed holds to push market data in.
        pub const Inbox = runtime.Handle(Worker, api.mailbox_capacity);

        pub var inbox: ?*Inbox = null;
        /// Armed when the snapshot timer message has been handled.
        pub var snapshot_taken: c.Latch = .{};

        pub fn initWith(ctx: *zmodu.ModuleContext) !void {
            const rt = try ctx.runtime();
            inbox = try rt.spawn(Worker, .{
                .alpha = Alpha.inbox.?,
                .bus = &Audit.bus,
                .propose = Propose.inbox.?,
                .snapshot_taken = &snapshot_taken,
            }, api.mailbox_capacity);

            // Deferred work is a message: the snapshot runs on the book's thread,
            // with the book's state, never on the ticker's.
            _ = try inbox.?.after(api.snapshot_after_ms, .{ .kind = .snapshot });
        }

        pub fn deinit() void {
            inbox = null;
        }
    };
}
