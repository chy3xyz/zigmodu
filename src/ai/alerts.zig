//! Business alerting: run SQL rules periodically; any rule returning rows is a
//! violation that raises an alert (callback + optional transactional-outbox
//! writeback). Pair with `zigmodu.ai.trigger` for scheduled checks.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const sqlx = @import("../sqlx/sqlx.zig");

/// A rule whose SQL returns violation rows (e.g. failed orders, low stock).
pub const AlertRule = struct {
    name: []const u8,
    sql: []const u8,
    args: []const sqlx.Value = &.{},
    message_template: []const u8,
};

/// Optional callback fired for each violation (e.g. push to a channel).
pub const AlertFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    rule_name: []const u8,
    message: []const u8,
) anyerror!void;

pub const BusinessAlert = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    rules: []const AlertRule,
    on_alert: ?AlertFn = null,
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.alert",

    pub fn init(
        allocator: std.mem.Allocator,
        backend: *SqlxBackend,
        rules: []const AlertRule,
    ) BusinessAlert {
        return .{ .allocator = allocator, .backend = backend, .rules = rules };
    }

    /// Run all rules; returns the number of alerts raised.
    pub fn check(self: *BusinessAlert, allocator: std.mem.Allocator, ctx: *SkillContext) !usize {
        var alerts: usize = 0;
        for (self.rules) |rule| {
            var cursor = try self.backend.client.queryCursorEx(rule.sql, rule.args, .{});
            defer cursor.deinit();
            if (cursor.next() == null) continue;

            alerts += 1;
            const message = try std.fmt.allocPrint(
                allocator,
                "ALERT [{s}]: {s}",
                .{ rule.name, rule.message_template },
            );
            defer allocator.free(message);

            if (self.on_alert) |cb| try cb(allocator, ctx, rule.name, message);
            if (self.outbox) |ob| {
                const insert = try ob.buildInsert(self.outbox_topic, message);
                _ = try self.backend.exec(insert.sql, &.{
                    .{ .string = insert.params.topic },
                    .{ .string = insert.params.payload },
                    .{ .int = @intCast(insert.params.max_retries) },
                    .{ .int = insert.params.created_at },
                    .{ .int = insert.params.updated_at },
                });
            }
        }
        return alerts;
    }
};

test "BusinessAlert raises alerts for violation rows" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, status TEXT)", &.{});
    _ = try client.exec("INSERT INTO orders (status) VALUES ('paid'), ('failed')", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });

    const rules = [_]AlertRule{
        .{ .name = "failed orders", .sql = "SELECT id FROM orders WHERE status = 'failed'", .message_template = "orders in failed state" },
    };
    var alerts = BusinessAlert.init(allocator, &backend, &rules);
    alerts.outbox = &outbox;
    var ctx = SkillContext{ .allocator = allocator };
    const n = try alerts.check(allocator, &ctx);
    try std.testing.expectEqual(@as(usize, 1), n);

    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next() orelse return error.NoOutboxRow;
    try std.testing.expectEqualStrings("ai.alert", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "failed orders") != null);
}
