//! The exec module: the adapter boundary, its paper venue, the supervised fill
//! reporter, and (P3) the desk that authorizes an agent's proposal.
//!
//! `initWith` is where the module's workers come to life: the app hands the
//! module its runtime through `ctx.runtime()`, so `app.stop()` joins them and no
//! caller has to remember to.

const runtime = @import("zigmodu").runtime;
const zmodu = @import("zigmodu");
const c = @import("../../contracts.zig");
const api = @import("api.zig");
const service = @import("service.zig");

pub const Module = struct {
    pub const info = zmodu.api.Module{
        .name = "exec",
        .description = "Execution + PaperExchange + supervised fill reporter + the proposal desk",
        .dependencies = &.{},
    };

    pub const Reporter = service.FaultyFillReporter;
    pub const ReporterInbox = runtime.Handle(Reporter, api.reporter_capacity);
    pub const Worker = service.Execution(ReporterInbox);
    /// The handle type downstream modules hold to route an order in.
    pub const Inbox = runtime.Handle(Worker, api.order_capacity);
    /// The desk: the type the `propose` module holds to hand a proposal over.
    pub const AuthorizerWorker = service.Authorizer(Inbox);
    pub const DeskInbox = runtime.Handle(AuthorizerWorker, api.desk_capacity);

    pub var inbox: ?*Inbox = null;
    pub var reporter: ?*ReporterInbox = null;
    pub var desk: ?*DeskInbox = null;
    /// Armed by the worker when it has accounted for the drain marker.
    pub var drained: c.Latch = .{};
    /// Armed by the worker when an authorized order has been filled.
    pub var authorized_done: c.Latch = .{};

    pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        const rt = try ctx.runtime();

        // Spawned first: the routing worker needs the reporter's handle, and the
        // reporter is the one that must not be able to hold routing hostage.
        reporter = try rt.spawnActor(Reporter, .{}, api.reporter_capacity, api.supervision);
        inbox = try rt.spawn(Worker, .{
            .exchange = .{},
            .reporter = reporter.?,
            .drained = &drained,
            .authorized_done = &authorized_done,
        }, api.order_capacity);
        // The desk comes last: it is downstream of the agent, and it needs the
        // router's handle — that mailbox is the only door to the exchange, and
        // the desk is where a proposal is allowed to walk through it.
        desk = try rt.spawn(AuthorizerWorker, .{ .orders = inbox.? }, api.desk_capacity);
    }

    pub fn deinit() void {
        inbox = null;
        reporter = null;
        desk = null;
    }
};
