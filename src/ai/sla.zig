//! SLA / 时效管理: track deadlines on business items (tickets, approvals,
//! refunds) and fire escalating reminders — a warning before the deadline and
//! a breach event after it passes. `check()` is meant to run on a cron cadence
//! (`zigmodu.ai.trigger.registerCron`); violations go to a callback (e.g. push
//! into `ai.notify`) and the outbox (`ai.sla`) for audit/automation.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const Time = @import("../core/Time.zig");

pub const SlaLevel = enum { warn, breach };

pub const SlaItem = struct {
    /// Stable business identifier (ticket id / approval run id / ...).
    id: []const u8,
    /// Item category, e.g. "ticket", "approval", "refund".
    kind: []const u8,
    subject: []const u8,
    /// Monotonic deadline in seconds (`Time.monotonicNowSeconds()` + budget).
    deadline_s: i64,
    priority: u8 = 3,
};

/// Fired for each violated item (warn or breach).
pub const SlaFn = *const fn (
    userdata: *anyopaque,
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    item: SlaItem,
    level: SlaLevel,
    remaining_s: i64,
) anyerror!void;

pub const SlaTracker = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    items: []const SlaItem = &.{},
    /// Seconds before the deadline that triggers the warning level.
    warn_before_s: i64 = 3600,
    userdata: *anyopaque = undefined,
    on_sla: ?SlaFn = null,
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.sla",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend) SlaTracker {
        return .{ .allocator = allocator, .backend = backend };
    }

    /// Evaluate every item against the clock. Returns the number of fired
    /// events (warn + breach). Items are never modified; the app updates its
    /// own store and re-supplies the list next tick.
    pub fn check(self: *SlaTracker, allocator: std.mem.Allocator, ctx: *SkillContext) !usize {
        const now = Time.monotonicNowSeconds();
        var fired: usize = 0;
        for (self.items) |item| {
            const remaining_s = item.deadline_s - now;
            const level: SlaLevel = if (remaining_s < 0) .breach else if (remaining_s <= self.warn_before_s) .warn else continue;
            fired += 1;

            if (self.on_sla) |cb| try cb(self.userdata, allocator, ctx, item, level, remaining_s);
            if (self.outbox) |ob| {
                const payload = try std.fmt.allocPrint(
                    allocator,
                    "{{\"id\":\"{s}\",\"kind\":\"{s}\",\"subject\":\"{s}\",\"level\":\"{s}\",\"remaining_s\":{d},\"priority\":{d}}}",
                    .{ item.id, item.kind, item.subject, @tagName(level), remaining_s, item.priority },
                );
                defer allocator.free(payload);
                const insert = try ob.buildInsert(self.outbox_topic, payload);
                _ = try self.backend.exec(insert.sql, &.{
                    .{ .string = insert.params.topic },
                    .{ .string = insert.params.payload },
                    .{ .int = @intCast(insert.params.max_retries) },
                    .{ .int = insert.params.created_at },
                    .{ .int = insert.params.updated_at },
                });
            }
        }
        return fired;
    }
};

test "SlaTracker fires warn before deadline and breach after" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    const State = struct {
        var levels: [2]SlaLevel = undefined;
        var n: usize = 0;
    };
    const Handler = struct {
        fn call(_: *anyopaque, _: std.mem.Allocator, _: *SkillContext, item: SlaItem, level: SlaLevel, _: i64) anyerror!void {
            State.levels[State.n] = level;
            State.n += 1;
            _ = item;
        }
    };
    var dummy: u8 = 0;

    const now = Time.monotonicNowSeconds();
    const items = [_]SlaItem{
        .{ .id = "t-1", .kind = "ticket", .subject = "urgent refund", .deadline_s = now + 1800 }, // within 1h warn window
        .{ .id = "a-1", .kind = "approval", .subject = "large order", .deadline_s = now - 120 }, // breached
        .{ .id = "t-2", .kind = "ticket", .subject = "normal", .deadline_s = now + 86400 }, // healthy
    };

    var tracker = SlaTracker.init(allocator, &backend);
    tracker.items = &items;
    tracker.warn_before_s = 3600;
    tracker.userdata = &dummy;
    tracker.on_sla = Handler.call;
    tracker.outbox = &outbox;

    var ctx = SkillContext{ .allocator = allocator };
    const fired = try tracker.check(allocator, &ctx);
    try std.testing.expectEqual(@as(usize, 2), fired);
    try std.testing.expectEqual(SlaLevel.warn, State.levels[0]);
    try std.testing.expectEqual(SlaLevel.breach, State.levels[1]);

    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next().?;
    try std.testing.expectEqualStrings("ai.sla", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "warn") != null);
}
