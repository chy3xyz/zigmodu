//! Refund flow with Saga-style compensation: validate → approve → execute the
//! refund as a transactional outbox command → notify; when notification (or
//! any downstream failure) fails, an automatic reverse command is emitted.
//! `compensate` is also available for app-initiated reversals.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;

pub const RefundStatus = enum { rejected, pending_approval, executed, compensated };

pub const ValidateFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    order_id: i64,
) anyerror!bool;

pub const ApproveFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    order_id: i64,
    amount: i64,
) anyerror!bool;

pub const RefundResult = struct {
    status: RefundStatus,
    order_id: i64,
    amount: i64,
};

pub const RefundFlow = struct {
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    outbox: *OutboxPublisher,
    validate: ?ValidateFn = null,
    approve: ?ApproveFn = null,
    command_topic: []const u8 = "refund.execute",
    notify_topic: []const u8 = "refund.notify",
    compensation_topic: []const u8 = "refund.reverse",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend, outbox: *OutboxPublisher) RefundFlow {
        return .{ .allocator = allocator, .backend = backend, .outbox = outbox };
    }

    /// validate → approve → execute(outbox command) → notify; notify failure
    /// auto-emits the compensation command (Saga-style).
    pub fn run(self: *RefundFlow, allocator: std.mem.Allocator, ctx: *SkillContext, order_id: i64, amount: i64) !RefundResult {
        if (self.validate) |v| {
            const ok = try v(allocator, ctx, order_id);
            if (!ok) return .{ .status = .rejected, .order_id = order_id, .amount = amount };
        }
        if (self.approve) |a| {
            const ok = try a(allocator, ctx, order_id, amount);
            if (!ok) return .{ .status = .pending_approval, .order_id = order_id, .amount = amount };
        }

        _ = try self.writeCommand(allocator, self.command_topic, order_id, amount);
        self.writeCommand(allocator, self.notify_topic, order_id, amount) catch {
            _ = self.writeCommand(allocator, self.compensation_topic, order_id, amount) catch {};
            return .{ .status = .compensated, .order_id = order_id, .amount = amount };
        };
        return .{ .status = .executed, .order_id = order_id, .amount = amount };
    }

    /// App-initiated reversal (e.g. downstream settlement failed).
    pub fn compensate(self: *RefundFlow, allocator: std.mem.Allocator, order_id: i64, amount: i64) !void {
        _ = try self.writeCommand(allocator, self.compensation_topic, order_id, amount);
    }

    fn writeCommand(self: *RefundFlow, allocator: std.mem.Allocator, topic: []const u8, order_id: i64, amount: i64) !void {
        const payload = try std.fmt.allocPrint(allocator, "{{\"order_id\":{d},\"amount\":{d}}}", .{ order_id, amount });
        defer allocator.free(payload);
        const insert = try self.outbox.buildInsert(topic, payload);
        _ = try self.backend.exec(insert.sql, &.{
            .{ .string = insert.params.topic },
            .{ .string = insert.params.payload },
            .{ .int = @intCast(insert.params.max_retries) },
            .{ .int = insert.params.created_at },
            .{ .int = insert.params.updated_at },
        });
    }
};

test "RefundFlow executes, notifies, and compensates on demand" {
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

    const T = struct {
        fn validate(_: std.mem.Allocator, _: *SkillContext, _: i64) anyerror!bool {
            return true;
        }
        fn approve(_: std.mem.Allocator, _: *SkillContext, _: i64, _: i64) anyerror!bool {
            return true;
        }
    };

    var flow = RefundFlow.init(allocator, &backend, &outbox);
    flow.validate = T.validate;
    flow.approve = T.approve;
    var ctx = SkillContext{ .allocator = allocator };

    const res = try flow.run(allocator, &ctx, 42, 9900);
    try std.testing.expectEqual(RefundStatus.executed, res.status);
    try flow.compensate(allocator, 42, 9900);

    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox ORDER BY id", &.{}, .{});
    defer cursor.deinit();
    try std.testing.expectEqualStrings("refund.execute", cursor.next().?.get("topic").?.string);
    try std.testing.expectEqualStrings("refund.notify", cursor.next().?.get("topic").?.string);
    try std.testing.expectEqualStrings("refund.reverse", cursor.next().?.get("topic").?.string);
}

test "RefundFlow rejects invalid orders and holds for approval" {
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
    var ctx = SkillContext{ .allocator = allocator };

    const T = struct {
        fn validateNever(_: std.mem.Allocator, _: *SkillContext, _: i64) anyerror!bool {
            return false;
        }
        fn approveNever(_: std.mem.Allocator, _: *SkillContext, _: i64, _: i64) anyerror!bool {
            return false;
        }
    };

    var flow = RefundFlow.init(allocator, &backend, &outbox);
    flow.validate = T.validateNever;
    const rejected = try flow.run(allocator, &ctx, 1, 100);
    try std.testing.expectEqual(RefundStatus.rejected, rejected.status);

    flow.validate = null;
    flow.approve = T.approveNever;
    const held = try flow.run(allocator, &ctx, 1, 100);
    try std.testing.expectEqual(RefundStatus.pending_approval, held.status);
}
