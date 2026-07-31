const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");

pub fn OrderPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        db: Backend,

        pub fn init(db: Backend) Self {
            return .{ .db = db };
        }

        pub fn listByTenant(self: *Self, tenant_id: i64) !data.sqlx.QueryResult(model.Order) {
            return try self.db.queryRowsPartial(
                model.Order,
                "SELECT id, tenant_id, user_id, status, total_cents, created_at, updated_at FROM orders WHERE tenant_id = ? ORDER BY id DESC",
                &.{.{ .int = tenant_id }},
            );
        }
    };
}

pub const Tx = struct {
    pub fn insertOrder(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        user_id: i64,
        status: []const u8,
        total_cents: i64,
        now: i64,
    ) !i64 {
        const res = try tx.exec(
            "INSERT INTO orders (tenant_id, user_id, status, total_cents, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            &.{
                .{ .int = tenant_id },
                .{ .int = user_id },
                .{ .string = status },
                .{ .int = total_cents },
                .{ .int = now },
                .{ .int = now },
            },
        );
        return res.last_insert_id orelse return error.DatabaseError;
    }

    pub fn insertItem(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        order_id: i64,
        product_id: i64,
        qty: i64,
        price_cents: i64,
    ) !void {
        _ = try tx.exec(
            "INSERT INTO order_items (tenant_id, order_id, product_id, qty, price_cents) VALUES (?, ?, ?, ?, ?)",
            &.{
                .{ .int = tenant_id },
                .{ .int = order_id },
                .{ .int = product_id },
                .{ .int = qty },
                .{ .int = price_cents },
            },
        );
    }

    pub fn get(
        tx: *data.sqlx.Transaction,
        allocator: std.mem.Allocator,
        tenant_id: i64,
        order_id: i64,
    ) !model.Order {
        return try tx.queryRow(
            allocator,
            model.Order,
            "SELECT id, tenant_id, user_id, status, total_cents, created_at, updated_at FROM orders WHERE tenant_id = ? AND id = ?",
            &.{ .{ .int = tenant_id }, .{ .int = order_id } },
        );
    }

    pub fn listItems(
        tx: *data.sqlx.Transaction,
        allocator: std.mem.Allocator,
        tenant_id: i64,
        order_id: i64,
    ) !data.sqlx.QueryResult(model.OrderItem) {
        return try tx.queryRows(
            allocator,
            model.OrderItem,
            "SELECT id, tenant_id, order_id, product_id, qty, price_cents FROM order_items WHERE tenant_id = ? AND order_id = ?",
            &.{ .{ .int = tenant_id }, .{ .int = order_id } },
        );
    }

    pub fn updateStatusIf(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        order_id: i64,
        from_status: []const u8,
        to_status: []const u8,
        now: i64,
    ) !void {
        _ = try tx.exec(
            "UPDATE orders SET status = ?, updated_at = ? WHERE tenant_id = ? AND id = ? AND status = ?",
            &.{
                .{ .string = to_status },
                .{ .int = now },
                .{ .int = tenant_id },
                .{ .int = order_id },
                .{ .string = from_status },
            },
        );
    }
};
