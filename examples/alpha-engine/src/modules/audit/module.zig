//! The audit module: the L0 fan-out every accepted print rides on, plus the two
//! subscribers that consume the book's `Delta` stream.
//!
//! This module **owns** the bus, because the module that wires the subscribers
//! is the only one that can freeze it at the right moment: between the last
//! `subscribe` and the first published print. `book` publishes into it and
//! declares the dependency by name.
//!
//! Nothing here is on the critical path. `publish` never blocks, never
//! allocates, and drops a full subscriber instead of waiting for it.

const runtime = @import("zigmodu").runtime;
const zmodu = @import("zigmodu");
const c = @import("../../contracts.zig");
const api = @import("api.zig");
const service = @import("service.zig");

pub const Module = struct {
    pub const info = zmodu.api.Module{
        .name = "audit",
        .description = "L0 fan-out: the HotBus the book publishes to + its audit and metrics subscribers",
        .dependencies = &.{},
    };

    pub const Bus = runtime.HotBus(c.Delta, api.subscriber_slots);
    pub const Worker = service.Audit;
    pub const Inbox = runtime.Handle(Worker, api.mailbox_capacity);
    pub const Sink = service.MetricsSink(Bus);

    pub var bus: Bus = undefined;
    /// The O(1) metrics subscriber's counters — read by `main` after the run.
    pub var sink: Sink = .{};
    pub var inbox: ?*Inbox = null;

    pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        const rt = try ctx.runtime();

        bus = Bus.init();
        inbox = try rt.spawn(Worker, .{}, api.mailbox_capacity);
        try bus.subscribe(inbox.?); // a real worker, slow by design
        try bus.subscribeSink(sink.sink()); // a plain sink, no worker needed
        // After this, `publish` is a lock-free slice walk with no allocation:
        // the subscriber list is final before the feed thread exists.
        bus.freeze();
    }

    pub fn deinit() void {
        inbox = null;
    }
};
