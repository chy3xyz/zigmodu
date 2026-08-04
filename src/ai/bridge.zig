//! Outbox → workflow bridge ("事件驱动编排"): polls outbox events and routes
//! them into `ai.trigger` runs (whose `run_fn` typically drives a Workflow).
//! This unifies the three trigger sources — cron, in-process fire, and now
//! outbox events — so any `ai.*` writeback (approval/recon/notify/risk/alert)
//! can start an orchestration run. Run outcomes flow back through the
//! trigger's own outbox writeback, forming a closed loop.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const trigger_mod = @import("trigger.zig");
const consumer_mod = @import("../messaging/OutboxConsumer.zig");

pub const BridgeStats = struct {
    matched: usize,
    fired: usize,
    failed: usize,
};

/// Route an outbox entry to a `Trigger` when its topic matches.
pub const BridgeRoute = struct {
    /// Exact topic, or prefix when `prefix_match` is set.
    topic: []const u8,
    prefix_match: bool = false,
    trigger: *trigger_mod.Trigger,
};

pub const OutboxWorkflowBridge = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    consumer: consumer_mod.OutboxConsumer,
    routes: []const BridgeRoute,
    /// When set, the matched topic is written back to the outbox with the
    /// bridge's outcome (in addition to the trigger's own writeback).
    outbox: ?*@import("../messaging/OutboxPublisher.zig").OutboxPublisher = null,
    matched_count: usize = 0,
    fired_count: usize = 0,
    failed_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        backend: *SqlxBackend,
        consumer: consumer_mod.OutboxConsumer,
        routes: []const BridgeRoute,
    ) Self {
        return .{ .allocator = allocator, .backend = backend, .consumer = consumer, .routes = routes };
    }

    /// Poll one batch of outbox entries; each entry is dispatched to the first
    /// matching route via `Trigger.fire(input)` with the entry payload.
    pub fn pollOnce(self: *Self) !BridgeStats {
        self.consumer.handler = bridgeHandler;
        self.consumer.userdata = self;
        self.matched_count = 0;
        self.fired_count = 0;
        self.failed_count = 0;

        _ = try self.consumer.pollOnce();
        return .{ .matched = self.matched_count, .fired = self.fired_count, .failed = self.failed_count };
    }

    fn bridgeHandler(userdata: *anyopaque, allocator: std.mem.Allocator, entry: consumer_mod.OutboxEntry) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(userdata));

        var route: ?BridgeRoute = null;
        for (self.routes) |r| {
            if (r.prefix_match) {
                if (std.mem.startsWith(u8, entry.topic, r.topic)) {
                    route = r;
                    break;
                }
            } else if (std.mem.eql(u8, entry.topic, r.topic)) {
                route = r;
                break;
            }
        }
        const matched = route orelse return;
        self.matched_count += 1;

        // Clone the trigger's ctx template so per-run state stays isolated.
        _ = matched.trigger.fire(self.allocator, entry.payload) catch |err| {
            self.failed_count += 1;
            return err;
        };
        self.fired_count += 1;
        _ = allocator;
    }
};

test "OutboxWorkflowBridge routes events into a trigger run" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec(
        "INSERT INTO event_outbox (topic, payload, status, retry_count, max_retries, created_at, updated_at) VALUES ('ai.approval', '{\"run\":1}', 0, 0, 3, 1, 1), ('other.topic', '{}', 0, 0, 3, 2, 2)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };

    const State = struct {
        var runs: usize = 0;
        var last_input: []const u8 = "";
    };
    const Runner = struct {
        fn run(
            a: std.mem.Allocator,
            _: *SkillContext,
            input: []const u8,
            out: *trigger_mod.TriggerResult,
        ) anyerror!void {
            State.runs += 1;
            // Copies are call-scoped; the runner keeps its own.
            State.last_input = try a.dupe(u8, input);
            out.run_id = "run-1";
            out.ok = true;
            out.message = "ok";
        }
    };
    defer if (State.last_input.len > 0) allocator.free(State.last_input);

    const tctx = SkillContext{ .allocator = allocator };
    var trigger = trigger_mod.Trigger.init(allocator, std.testing.io, Runner.run, tctx);
    defer trigger.deinit();

    const consumer = consumer_mod.OutboxConsumer.init(allocator, &backend, .{}, undefined, undefined);
    const routes = [_]BridgeRoute{
        .{ .topic = "ai.", .prefix_match = true, .trigger = &trigger },
    };
    var bridge = OutboxWorkflowBridge.init(allocator, &backend, consumer, &routes);
    const stats = try bridge.pollOnce();

    try std.testing.expectEqual(@as(usize, 1), stats.matched);
    try std.testing.expectEqual(@as(usize, 1), stats.fired);
    try std.testing.expectEqual(@as(usize, 1), State.runs);
    try std.testing.expectEqualStrings("{\"run\":1}", State.last_input);
}
