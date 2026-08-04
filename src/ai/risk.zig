//! Risk review: SQL rules score a subject (order/user); the score maps to a
//! level and a decision (approve / reject / escalate to a human). The outcome
//! is written to the outbox for audit and downstream automation.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const sqlx = @import("../sqlx/sqlx.zig");

/// A rule whose SQL returns a row when the risk factor applies; each match
/// adds `score` to the subject's risk score.
pub const RiskRule = struct {
    name: []const u8,
    sql: []const u8,
    score: i32,
    args: []const sqlx.Value = &.{},
};

pub const RiskLevel = enum { low, medium, high };
pub const RiskDecision = enum { approve, reject, escalate };

/// Optional final decision callback (wire to an LLM or policy); defaults to
/// thresholds when null.
pub const DecideFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    subject: []const u8,
    score: i32,
    level: RiskLevel,
) anyerror!RiskDecision;

pub const RiskResult = struct {
    subject: []const u8,
    score: i32,
    level: RiskLevel,
    decision: RiskDecision,
};

pub const RiskReview = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    rules: []const RiskRule = &.{},
    decide: ?DecideFn = null,
    high_threshold: i32 = 100,
    escalate_threshold: i32 = 50,
    outbox: ?*OutboxPublisher = null,
    outbox_topic: []const u8 = "ai.risk",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend) RiskReview {
        return .{ .allocator = allocator, .backend = backend };
    }

    pub fn review(self: *RiskReview, allocator: std.mem.Allocator, ctx: *SkillContext, subject: []const u8) !RiskResult {
        var score: i32 = 0;
        for (self.rules) |rule| {
            var cursor = try self.backend.client.queryCursorEx(rule.sql, rule.args, .{});
            defer cursor.deinit();
            if (cursor.next() != null) score += rule.score;
        }

        const level: RiskLevel = if (score >= self.high_threshold)
            .high
        else if (score >= self.escalate_threshold)
            .medium
        else
            .low;

        const decision = if (self.decide) |f|
            try f(allocator, ctx, subject, score, level)
        else switch (level) {
            .low => RiskDecision.approve,
            .medium => RiskDecision.escalate,
            .high => RiskDecision.reject,
        };

        if (self.outbox) |ob| {
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"subject\":\"{s}\",\"score\":{d},\"level\":\"{s}\",\"decision\":\"{s}\"}}",
                .{ subject, score, @tagName(level), @tagName(decision) },
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

        return .{ .subject = subject, .score = score, .level = level, .decision = decision };
    }
};

test "RiskReview scores rules and applies threshold decisions" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, amount INTEGER)", &.{});
    _ = try client.exec("INSERT INTO orders (amount) VALUES (5000)", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    const rules = [_]RiskRule{
        .{ .name = "large order", .sql = "SELECT id FROM orders WHERE amount >= 1000", .score = 60 },
        .{ .name = "new customer", .sql = "SELECT id FROM orders WHERE amount >= 5000", .score = 50 },
    };
    var review = RiskReview.init(allocator, &backend);
    review.rules = &rules;
    review.outbox = &outbox;

    var ctx = SkillContext{ .allocator = allocator };
    const res = try review.review(allocator, &ctx, "order-1");
    try std.testing.expectEqual(@as(i32, 110), res.score);
    try std.testing.expectEqual(RiskLevel.high, res.level);
    try std.testing.expectEqual(RiskDecision.reject, res.decision);

    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next() orelse return error.NoOutboxRow;
    try std.testing.expectEqualStrings("ai.risk", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "reject") != null);
}
