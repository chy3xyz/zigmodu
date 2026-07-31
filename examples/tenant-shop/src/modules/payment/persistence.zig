const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");

pub fn PaymentPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        db: Backend,

        pub fn init(db: Backend) Self {
            return .{ .db = db };
        }

        pub fn listByOrder(self: *Self, tenant_id: i64, order_id: i64) !data.sqlx.QueryResult(model.Payment) {
            return try self.db.queryRowsPartial(
                model.Payment,
                "SELECT id, tenant_id, order_id, idempotency_key, status, amount_cents, created_at FROM payments WHERE tenant_id = ? AND order_id = ? ORDER BY id",
                &.{ .{ .int = tenant_id }, .{ .int = order_id } },
            );
        }

        pub fn findByKey(self: *Self, key: []const u8) !?model.Payment {
            return self.db.queryRowPartial(
                model.Payment,
                "SELECT id, tenant_id, order_id, idempotency_key, status, amount_cents, created_at FROM payments WHERE idempotency_key = ? LIMIT 1",
                &.{.{ .string = key }},
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
        }
    };
}

pub const Tx = struct {
    pub fn findByKey(
        tx: *data.sqlx.Transaction,
        allocator: std.mem.Allocator,
        key: []const u8,
    ) !?model.Payment {
        return tx.queryRow(
            allocator,
            model.Payment,
            "SELECT id, tenant_id, order_id, idempotency_key, status, amount_cents, created_at FROM payments WHERE idempotency_key = ? LIMIT 1",
            &.{.{ .string = key }},
        ) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
    }

    pub fn insert(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        order_id: i64,
        idempotency_key: []const u8,
        status: []const u8,
        amount_cents: i64,
        now: i64,
    ) !i64 {
        const res = try tx.exec(
            "INSERT INTO payments (tenant_id, order_id, idempotency_key, status, amount_cents, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            &.{
                .{ .int = tenant_id },
                .{ .int = order_id },
                .{ .string = idempotency_key },
                .{ .string = status },
                .{ .int = amount_cents },
                .{ .int = now },
            },
        );
        return res.last_insert_id orelse return error.DatabaseError;
    }
};
