const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;
const model = @import("model.zig");

pub fn CartPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        db: Backend,

        pub fn init(db: Backend) Self {
            return .{ .db = db };
        }

        pub fn findCart(self: *Self, tenant_id: i64, user_id: i64) !?model.Cart {
            return self.db.queryRowPartial(
                model.Cart,
                "SELECT id, tenant_id, user_id, updated_at FROM carts WHERE tenant_id = ? AND user_id = ? LIMIT 1",
                &.{ .{ .int = tenant_id }, .{ .int = user_id } },
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
        }

        pub fn insertCart(self: *Self, cart: model.Cart) !i64 {
            const result = try self.db.exec(
                "INSERT INTO carts (tenant_id, user_id, updated_at) VALUES (?, ?, ?)",
                &.{
                    .{ .int = cart.tenant_id },
                    .{ .int = cart.user_id },
                    .{ .int = cart.updated_at },
                },
            );
            return result.last_insert_id orelse return error.DatabaseError;
        }

        pub fn listItems(self: *Self, tenant_id: i64, cart_id: i64) !data.sqlx.QueryResult(model.CartItem) {
            return try self.db.queryRowsPartial(
                model.CartItem,
                "SELECT id, tenant_id, cart_id, product_id, qty FROM cart_items WHERE tenant_id = ? AND cart_id = ? ORDER BY id",
                &.{ .{ .int = tenant_id }, .{ .int = cart_id } },
            );
        }

        pub fn upsertItem(self: *Self, tenant_id: i64, cart_id: i64, product_id: i64, qty: i64) !void {
            _ = try self.db.exec(
                \\INSERT INTO cart_items (tenant_id, cart_id, product_id, qty)
                \\VALUES (?, ?, ?, ?)
                \\ON CONFLICT(tenant_id, cart_id, product_id) DO UPDATE SET qty = excluded.qty
            ,
                &.{
                    .{ .int = tenant_id },
                    .{ .int = cart_id },
                    .{ .int = product_id },
                    .{ .int = qty },
                },
            );
        }

        pub fn clearItems(self: *Self, tenant_id: i64, cart_id: i64) !void {
            _ = try self.db.exec(
                "DELETE FROM cart_items WHERE tenant_id = ? AND cart_id = ?",
                &.{ .{ .int = tenant_id }, .{ .int = cart_id } },
            );
        }
    };
}

pub const Tx = struct {
    pub fn findCart(
        tx: *data.sqlx.Transaction,
        allocator: std.mem.Allocator,
        tenant_id: i64,
        user_id: i64,
    ) !model.Cart {
        return try tx.queryRow(
            allocator,
            model.Cart,
            "SELECT id, tenant_id, user_id, updated_at FROM carts WHERE tenant_id = ? AND user_id = ? LIMIT 1",
            &.{ .{ .int = tenant_id }, .{ .int = user_id } },
        );
    }

    pub fn listItems(
        tx: *data.sqlx.Transaction,
        allocator: std.mem.Allocator,
        tenant_id: i64,
        cart_id: i64,
    ) !data.sqlx.QueryResult(model.CartItem) {
        return try tx.queryRows(
            allocator,
            model.CartItem,
            "SELECT id, tenant_id, cart_id, product_id, qty FROM cart_items WHERE tenant_id = ? AND cart_id = ?",
            &.{ .{ .int = tenant_id }, .{ .int = cart_id } },
        );
    }

    pub fn clearItems(tx: *data.sqlx.Transaction, tenant_id: i64, cart_id: i64) !void {
        _ = try tx.exec(
            "DELETE FROM cart_items WHERE tenant_id = ? AND cart_id = ?",
            &.{ .{ .int = tenant_id }, .{ .int = cart_id } },
        );
    }
};
