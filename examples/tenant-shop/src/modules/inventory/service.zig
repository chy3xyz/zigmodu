const zigmodu = @import("zigmodu");
const model = @import("model.zig");

pub fn InventoryService(comptime Persistence: type) type {
    return struct {
        const Self = @This();
        persistence: Persistence,

        pub fn init(p: Persistence) Self {
            return .{ .persistence = p };
        }

        pub fn listByTenant(self: *Self, tenant_id: i64) !zigmodu.data.sqlx.QueryResult(model.Inventory) {
            return try self.persistence.findByTenant(tenant_id);
        }

        pub fn setQty(self: *Self, tenant_id: i64, product_id: i64, qty: i64) !void {
            const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
            try self.persistence.upsert(.{
                .id = 0,
                .tenant_id = tenant_id,
                .product_id = product_id,
                .qty = qty,
                .reserved = 0,
                .updated_at = now,
            });
        }
    };
}
