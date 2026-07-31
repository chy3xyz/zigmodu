const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");

pub fn ProductPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        db: Backend,

        pub fn init(db: Backend) Self {
            return .{ .db = db };
        }

        pub fn findById(self: *Self, tenant_id: i64, product_id: i64) !?model.Product {
            return self.db.queryRowPartial(
                model.Product,
                "SELECT id, tenant_id, name, price_cents, status, created_at, updated_at FROM products WHERE tenant_id = ? AND id = ?",
                &.{ .{ .int = tenant_id }, .{ .int = product_id } },
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
        }

        pub fn findByTenant(self: *Self, tenant_id: i64) !data.sqlx.QueryResult(model.Product) {
            return try self.db.queryRowsPartial(
                model.Product,
                "SELECT id, tenant_id, name, price_cents, status, created_at, updated_at FROM products WHERE tenant_id = ? AND status = 1 ORDER BY id",
                &.{.{ .int = tenant_id }},
            );
        }

        pub fn insert(self: *Self, p: model.Product) !i64 {
            const result = try self.db.exec(
                "INSERT INTO products (tenant_id, name, price_cents, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                &.{
                    .{ .int = p.tenant_id },
                    .{ .string = p.name },
                    .{ .int = p.price_cents },
                    .{ .int = p.status },
                    .{ .int = p.created_at },
                    .{ .int = p.updated_at },
                },
            );
            return result.last_insert_id orelse return error.DatabaseError;
        }
    };
}

pub const Tx = struct {
    pub fn priceCents(
        tx: *data.sqlx.Transaction,
        allocator: std.mem.Allocator,
        tenant_id: i64,
        product_id: i64,
    ) !i64 {
        const product = try tx.queryRow(
            allocator,
            model.Product,
            "SELECT id, tenant_id, name, price_cents, status, created_at, updated_at FROM products WHERE tenant_id = ? AND id = ?",
            &.{ .{ .int = tenant_id }, .{ .int = product_id } },
        );
        defer allocator.free(product.name);
        return product.price_cents;
    }
};
