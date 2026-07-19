const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");

pub fn InventoryPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        db: Backend,

        pub fn init(db: Backend) Self {
            return .{ .db = db };
        }

        pub fn findByTenant(self: *Self, tenant_id: i64) ![]model.Inventory {
            return try self.db.queryRowsPartial(model.Inventory,
                "SELECT id, tenant_id, product_id, qty, reserved, updated_at FROM inventory WHERE tenant_id = ? ORDER BY id",
                &.{.{ .int = tenant_id }},
            );
        }

        pub fn findByProduct(self: *Self, tenant_id: i64, product_id: i64) !?model.Inventory {
            return self.db.queryRowPartial(model.Inventory,
                "SELECT id, tenant_id, product_id, qty, reserved, updated_at FROM inventory WHERE tenant_id = ? AND product_id = ?",
                &.{ .{ .int = tenant_id }, .{ .int = product_id } },
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
        }

        pub fn upsert(self: *Self, row: model.Inventory) !void {
            _ = try self.db.exec(
                \\INSERT INTO inventory (tenant_id, product_id, qty, reserved, updated_at)
                \\VALUES (?, ?, ?, ?, ?)
                \\ON CONFLICT(tenant_id, product_id) DO UPDATE SET
                \\  qty = excluded.qty,
                \\  reserved = excluded.reserved,
                \\  updated_at = excluded.updated_at
            ,
                &.{
                    .{ .int = row.tenant_id },
                    .{ .int = row.product_id },
                    .{ .int = row.qty },
                    .{ .int = row.reserved },
                    .{ .int = row.updated_at },
                },
            );
        }
    };
}

/// Transaction-scoped SQL helpers for Unit-of-Work workflows (checkout / pay).
pub const Tx = struct {
    pub fn findByProduct(
        tx: *data.sqlx.Transaction,
        allocator: std.mem.Allocator,
        tenant_id: i64,
        product_id: i64,
    ) !model.Inventory {
        return try tx.queryRow(allocator, model.Inventory,
            "SELECT id, tenant_id, product_id, qty, reserved, updated_at FROM inventory WHERE tenant_id = ? AND product_id = ?",
            &.{ .{ .int = tenant_id }, .{ .int = product_id } },
        );
    }

    pub fn reserve(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        product_id: i64,
        qty: i64,
        now: i64,
    ) !void {
        const res = try tx.exec(
            "UPDATE inventory SET reserved = reserved + ?, updated_at = ? WHERE tenant_id = ? AND product_id = ? AND (qty - reserved) >= ?",
            &.{
                .{ .int = qty },
                .{ .int = now },
                .{ .int = tenant_id },
                .{ .int = product_id },
                .{ .int = qty },
            },
        );
        if (res.rows_affected != 1) return error.ConstraintViolation;
    }

    pub fn release(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        product_id: i64,
        qty: i64,
        now: i64,
    ) !void {
        const res = try tx.exec(
            "UPDATE inventory SET reserved = reserved - ?, updated_at = ? WHERE tenant_id = ? AND product_id = ? AND reserved >= ?",
            &.{
                .{ .int = qty },
                .{ .int = now },
                .{ .int = tenant_id },
                .{ .int = product_id },
                .{ .int = qty },
            },
        );
        if (res.rows_affected != 1) return error.ConstraintViolation;
    }

    pub fn commitSale(
        tx: *data.sqlx.Transaction,
        tenant_id: i64,
        product_id: i64,
        qty: i64,
        now: i64,
    ) !void {
        const res = try tx.exec(
            "UPDATE inventory SET qty = qty - ?, reserved = reserved - ?, updated_at = ? WHERE tenant_id = ? AND product_id = ? AND reserved >= ? AND qty >= ?",
            &.{
                .{ .int = qty },
                .{ .int = qty },
                .{ .int = now },
                .{ .int = tenant_id },
                .{ .int = product_id },
                .{ .int = qty },
                .{ .int = qty },
            },
        );
        if (res.rows_affected != 1) return error.ConstraintViolation;
    }
};
