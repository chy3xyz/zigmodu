//! The alpha module: the mean-reversion signal.
//!
//! Depends on `risk` by name, and is parameterised by the risk module type, so
//! the quote that leaves this module is a `contracts.Quote` and nothing here
//! knows what a risk worker looks like.

const runtime = @import("zigmodu").runtime;
const zmodu = @import("zigmodu");
const api = @import("api.zig");
const service = @import("service.zig");

pub fn Module(comptime Risk: type) type {
    return struct {
        pub const info = zmodu.api.Module{
            .name = "alpha",
            .description = "Alpha: fixed-window mean reversion, publishes unsized views",
            .dependencies = &.{"risk"},
        };

        pub const Worker = service.Alpha(Risk.Inbox);
        /// The handle type the book holds to send a quote in.
        pub const Inbox = runtime.Handle(Worker, api.mailbox_capacity);

        pub var inbox: ?*Inbox = null;

        pub fn initWith(ctx: *zmodu.ModuleContext) !void {
            const rt = try ctx.runtime();
            inbox = try rt.spawn(Worker, .{ .risk = Risk.inbox.? }, api.mailbox_capacity);
        }

        pub fn deinit() void {
            inbox = null;
        }
    };
}
