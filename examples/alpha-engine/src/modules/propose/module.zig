//! The propose module: the day-end agent run, and the gate it runs behind.
//!
//! This is the P3 module. It owns everything on the *agent* side of the wall —
//! the trigger, the worker, the guard, the risk review — and none of the things
//! on the other side of it: there is no exchange handle here, no order type, no
//! route to the venue. The one object this module can reach out with is an
//! envelope of numbers addressed to `exec`'s desk.
//!
//! Declared dependency `exec` is satisfied by type: this module is instantiated
//! as `propose.Module(exec.Module)` and only ever spells `Exec.DeskInbox`.

const runtime = @import("zigmodu").runtime;
const zmodu = @import("zigmodu");
const ai = zmodu.ai;
const c = @import("../../contracts.zig");
const api = @import("api.zig");
const service = @import("service.zig");

pub fn Module(comptime Exec: type) type {
    return struct {
        pub const info = zmodu.api.Module{
            .name = "propose",
            .description = "Day-end agent run: snapshot → proposal → gate → risk → the desk's inbox",
            .dependencies = &.{"exec"},
        };

        pub const AgentHandle = runtime.Handle(ai.AgentWorker, api.agent_capacity);
        pub const TriggerWorker = service.Trigger(AgentHandle);
        /// The handle the book holds to wake the agent up.
        pub const Inbox = runtime.Handle(TriggerWorker, api.trigger_capacity);
        pub const Run = service.Run(Exec.DeskInbox);

        pub var inbox: ?*Inbox = null;
        /// The policy state: guard, risk engine, stage table, counters. One
        /// allocation, because its parts point at each other.
        pub var state: ?*service.State = null;
        /// Armed when the agent run has been fully accounted for: the gate ran,
        /// and every proposal that survived it has been handed to the desk. This
        /// is the edge `main` reads the report across.
        pub var agent_done: c.Latch = .{};

        /// The worker's contract needs an `Agent`, and the injected `executor`
        /// is what runs — so this one is never dereferenced (the framework's own
        /// `agent_worker` test does the same). Building a real `AiProvider` here
        /// would be the network dependency the spec refuses; the seam is the
        /// executor, not the provider.
        var agent = ai.Agent{ .provider = undefined, .registry = undefined, .name = "day-end-propose" };
        var run: Run = undefined;
        var agent_worker: ?*AgentHandle = null;

        pub fn initWith(ctx: *zmodu.ModuleContext) !void {
            const rt = try ctx.runtime();
            state = try service.State.create(ctx.allocator, ctx.io);

            // The run is DB-bound: every proposal is staged into the sqlite
            // table (`stageLeg`) and scored by risk rules that are SQL
            // (`RiskReview`), all inside `onResult` on this worker's thread.
            // So it is admitted to the blocking pool (docs/RUNTIME.md §12.13)
            // — `.mode = .pooled` + `.execution_class = .blocking` — which the
            // builder in `main` declares via `withBlockingThreads`.
            agent_worker = try rt.spawn(ai.AgentWorker, .{
                .allocator = ctx.allocator,
                .agent = &agent,
                .on_result = Run.onResult,
                .ud = &run,
                .executor = service.cannedAgent,
                // One run per day-end snapshot, so the ReAct bound is not the
                // interesting number here — but it is bounded, like everything
                // else in this example.
                .max_steps = 2,
            }, .{
                .capacity = api.agent_capacity,
                .mode = .pooled,
                .execution_class = .blocking,
            });
            // Assigned *after* the spawn, and safe because this worker's only
            // producer is the trigger spawned below: nothing can be posted to an
            // agent that nobody has a handle to yet. The order is worth keeping —
            // `run` cannot name `agent_worker` or `state` in one literal, since
            // both are produced by the calls around it.
            run = .{ .state = state.?, .desk = Exec.desk.?, .done = &agent_done };

            inbox = try rt.spawn(TriggerWorker, .{
                .agent = agent_worker.?,
                .allocator = ctx.allocator,
            }, api.trigger_capacity);
        }

        pub fn deinit() void {
            inbox = null;
            agent_worker = null;
            // Safe here: `Application.stop()` joins every runtime worker before
            // modules are torn down, so the guard/risk state no longer has a
            // thread behind it.
            if (state) |s| s.deinit();
            state = null;
        }
    };
}
