//! Agent trigger orchestration: unify cron / event / webhook sources into a
//! single "run an agent workflow" entry point with optional outbox writeback.
//!
//! - `fire` is called by event handlers / webhook routes;
//! - `registerCron` attaches the trigger to a cron `Scheduler`;
//! - when `outbox` + `backend` are configured, every run appends
//!   `{run_id, ok, message}` to the transactional outbox for downstream
//!   consumers / pollers.

const std = @import("std");
const SkillContext = @import("skill.zig").SkillContext;
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const Scheduler = @import("../scheduler/Cron.zig").Scheduler;
const Expression = @import("../scheduler/Cron.zig").Expression;
const sqlx = @import("../sqlx/sqlx.zig");
const Time = @import("../core/Time.zig");

pub const TriggerResult = struct {
    ok: bool,
    /// Runner-provided; if allocated with the fire() allocator the caller owns
    /// it. Cron runners should keep these static/borrowed (fire-and-forget).
    run_id: []const u8,
    message: []const u8,
};

/// Runs the agent workflow for one trigger. `input` is the trigger payload
/// (cron: whatever registerCron captured; event/webhook: caller-provided).
pub const TriggerFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    input: []const u8,
    out: *TriggerResult,
) anyerror!void;

pub const Trigger = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    run_fn: TriggerFn,
    /// Template context copied per run (caller sets tenant/backend/userdata).
    ctx_template: SkillContext,
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.run",
    backend: ?*SqlxBackend = null,
    cron_ctxs: std.ArrayList(*CronCtx) = .empty,

    const CronCtx = struct {
        trigger: *Trigger,
        input: []const u8,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        run_fn: TriggerFn,
        ctx_template: SkillContext,
    ) Trigger {
        return .{ .allocator = allocator, .io = io, .run_fn = run_fn, .ctx_template = ctx_template };
    }

    pub fn deinit(self: *Trigger) void {
        for (self.cron_ctxs.items) |c| {
            self.allocator.free(c.input);
            self.allocator.destroy(c);
        }
        self.cron_ctxs.deinit(self.allocator);
        self.* = undefined;
    }

    /// Run the workflow now (event / webhook sources). When outbox + backend
    /// are configured the outcome is appended to the transactional outbox.
    pub fn fire(self: *Trigger, allocator: std.mem.Allocator, input: []const u8) !TriggerResult {
        var run_ctx = self.ctx_template;
        var result = TriggerResult{ .ok = false, .run_id = "", .message = "" };
        try self.run_fn(allocator, &run_ctx, input, &result);

        if (self.outbox) |ob| {
            if (self.backend) |b| {
                const payload = try std.fmt.allocPrint(
                    allocator,
                    "{{\"run_id\":\"{s}\",\"ok\":{s},\"message\":\"{s}\"}}",
                    .{ result.run_id, if (result.ok) "true" else "false", result.message },
                );
                defer allocator.free(payload);
                const insert = try ob.buildInsert(self.outbox_topic, payload);
                _ = try b.exec(insert.sql, &.{
                    .{ .string = insert.params.topic },
                    .{ .string = insert.params.payload },
                    .{ .int = @intCast(insert.params.max_retries) },
                    .{ .int = insert.params.created_at },
                    .{ .int = insert.params.updated_at },
                });
            }
        }
        return result;
    }

    /// Attach the trigger to a cron expression. Context is owned by the
    /// trigger and freed in `deinit`.
    pub fn registerCron(
        self: *Trigger,
        scheduler: *Scheduler,
        name: []const u8,
        expr: []const u8,
        input: []const u8,
    ) !void {
        const c = try self.allocator.create(CronCtx);
        errdefer self.allocator.destroy(c);
        c.* = .{ .trigger = self, .input = try self.allocator.dupe(u8, input) };
        try self.cron_ctxs.append(self.allocator, c);
        try scheduler.addJob(name, try Expression.parse(expr), cronTask, c);
    }
};

fn cronTask(ctx: *anyopaque) void {
    const c: *Trigger.CronCtx = @ptrCast(@alignCast(ctx));
    _ = c.trigger.fire(c.trigger.allocator, c.input) catch {};
}

test "trigger fire runs the workflow and returns the outcome" {
    const allocator = std.testing.allocator;
    var runs: usize = 0;
    const T = struct {
        fn run(alloc: std.mem.Allocator, ctx: *SkillContext, input: []const u8, out: *TriggerResult) anyerror!void {
            _ = alloc;
            _ = input;
            const r: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            r.* += 1;
            out.ok = true;
            out.run_id = "run-1";
            out.message = "done";
        }
    };
    const ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&runs) };
    var trigger = Trigger.init(allocator, std.testing.io, T.run, ctx);
    defer trigger.deinit();

    const result = try trigger.fire(allocator, "event");
    try std.testing.expect(result.ok);
    try std.testing.expectEqual(@as(usize, 1), runs);
    try std.testing.expectEqualStrings("done", result.message);
}

test "trigger writes run outcome to the outbox" {
    const allocator = std.testing.allocator;
    var sqlx_client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer sqlx_client.deinit();
    try sqlx_client.connect();
    // migrationSql() is MySQL-flavored; mirror the same columns for SQLite.
    _ = try sqlx_client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );

    var backend = SqlxBackend{ .allocator = allocator, .client = &sqlx_client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    const T = struct {
        fn run(alloc: std.mem.Allocator, ctx: *SkillContext, input: []const u8, out: *TriggerResult) anyerror!void {
            _ = alloc;
            _ = ctx;
            _ = input;
            out.ok = true;
            out.run_id = "run-1";
            out.message = "ok";
        }
    };
    const ctx = SkillContext{ .allocator = allocator };
    var trigger = Trigger.init(allocator, std.testing.io, T.run, ctx);
    defer trigger.deinit();
    trigger.outbox = &outbox;
    trigger.backend = &backend;

    _ = try trigger.fire(allocator, "webhook");

    var cursor = try sqlx_client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next() orelse return error.NoOutboxRow;
    try std.testing.expectEqualStrings("ai.run", row.get("topic").?.string);
    const payload = row.get("payload").?.string;
    try std.testing.expect(std.mem.indexOf(u8, payload, "run-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"ok\":true") != null);
}

test "trigger registerCron fires on scheduler tick" {
    const allocator = std.testing.allocator;
    var runs: usize = 0;
    const T = struct {
        fn run(alloc: std.mem.Allocator, ctx: *SkillContext, input: []const u8, out: *TriggerResult) anyerror!void {
            _ = alloc;
            _ = input;
            const r: *usize = @ptrCast(@alignCast(ctx.userdata.?));
            r.* += 1;
            out.ok = true;
            out.run_id = "";
            out.message = "";
        }
    };
    const ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&runs) };
    var trigger = Trigger.init(allocator, std.testing.io, T.run, ctx);
    defer trigger.deinit();

    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    try trigger.registerCron(&scheduler, "every-minute", "* * * * *", "cron-input");

    const now = Time.monotonicNowSeconds();
    scheduler.tick(now);
    try std.testing.expectEqual(@as(usize, 1), runs);
}
