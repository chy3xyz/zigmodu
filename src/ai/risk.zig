//! Risk review: SQL rules score a subject (order/user); the score maps to a
//! level and a decision (approve / reject / escalate to a human). The outcome
//! is written to the outbox for audit and downstream automation.

const std = @import("std");
const SqlxBackend = @import("../data.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const sqlx = @import("../data.zig").sqlx;
const skill = @import("skill.zig");

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
            if ((try cursor.next()) != null) score += rule.score;
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
            // Encoder-escaped: `subject` is caller/LLM-authored, so one quote
            // used to make the audit event unparseable.
            const payload = try skill.encodeJsonObject(allocator, &.{
                .{ .key = "subject", .value = .{ .string = subject } },
                .{ .key = "score", .value = .{ .integer = score } },
                .{ .key = "level", .value = .{ .string = @tagName(level) } },
                .{ .key = "decision", .value = .{ .string = @tagName(decision) } },
            });
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
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
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
    const row = (try cursor.next()) orelse return error.NoOutboxRow;
    try std.testing.expectEqualStrings("ai.risk", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "reject") != null);
}

test "RiskReview outbox payload escapes a quoted subject" {
    const allocator = std.testing.allocator;
    var client = @import("../data.zig").sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    var review = RiskReview.init(allocator, &backend);
    review.outbox = &outbox;

    const subject = "order \"7\" \\ draft";
    var ctx = SkillContext{ .allocator = allocator };
    const res = try review.review(allocator, &ctx, subject);
    try std.testing.expectEqualStrings(subject, res.subject);

    var cursor = try client.queryCursorEx("SELECT payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = (try cursor.next()) orelse return error.NoOutboxRow;
    // A hand-interpolated `"subject":"{s}"` produced `{"subject":"order "7" \ draft",…}`,
    // which no consumer can parse.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, row.get("payload").?.string, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(subject, parsed.value.object.get("subject").?.string);
    try std.testing.expectEqual(@as(i64, 0), parsed.value.object.get("score").?.integer);
    try std.testing.expectEqualStrings("low", parsed.value.object.get("level").?.string);
    try std.testing.expectEqualStrings("approve", parsed.value.object.get("decision").?.string);
}
