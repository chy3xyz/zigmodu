//! The risk module: limits, the veto, and the position that survives it.
//!
//! The dependency on `exec` is declared by **name** in `info.dependencies` and
//! satisfied by **type**: this module is parameterised by the downstream module
//! type, so it reads exec's published inbox type without importing a single one
//! of exec's files.

const runtime = @import("zigmodu").runtime;
const zmodu = @import("zigmodu");
const c = @import("../../contracts.zig");
const api = @import("api.zig");
const service = @import("service.zig");

pub fn Module(comptime Exec: type) type {
    return struct {
        pub const info = zmodu.api.Module{
            .name = "risk",
            .description = "Risk limits: sizing veto between alpha and execution",
            .dependencies = &.{"exec"},
        };

        pub const Worker = service.Risk(Exec.Inbox);
        /// The handle type alpha holds to send a signal in.
        pub const Inbox = runtime.Handle(Worker, api.mailbox_capacity);

        pub var inbox: ?*Inbox = null;
        /// Armed when the worker has accounted for the drain marker.
        pub var drained: c.Latch = .{};

        pub fn initWith(ctx: *zmodu.ModuleContext) !void {
            const rt = try ctx.runtime();
            // Dependencies initialize first, so exec's handle already exists —
            // that ordering is the module graph doing the wiring.
            inbox = try rt.spawn(Worker, .{
                .exec = Exec.inbox.?,
                .drained = &drained,
            }, api.mailbox_capacity);
        }

        pub fn deinit() void {
            inbox = null;
        }
    };
}
