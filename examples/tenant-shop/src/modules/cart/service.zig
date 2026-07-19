const zigmodu = @import("zigmodu");
const model = @import("model.zig");

pub fn CartService(comptime Persistence: type) type {
    return struct {
        const Self = @This();
        persistence: Persistence,

        pub fn init(p: Persistence) Self {
            return .{ .persistence = p };
        }

        pub fn getOrCreate(self: *Self, tenant_id: i64, user_id: i64) !model.Cart {
            if (try self.persistence.findCart(tenant_id, user_id)) |c| return c;
            const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
            const id = try self.persistence.insertCart(.{
                .id = 0,
                .tenant_id = tenant_id,
                .user_id = user_id,
                .updated_at = now,
            });
            return .{ .id = id, .tenant_id = tenant_id, .user_id = user_id, .updated_at = now };
        }

        pub fn listItems(self: *Self, tenant_id: i64, user_id: i64) ![]model.CartItem {
            const cart = try self.getOrCreate(tenant_id, user_id);
            return try self.persistence.listItems(tenant_id, cart.id);
        }

        pub fn addItem(self: *Self, tenant_id: i64, user_id: i64, product_id: i64, qty: i64) !void {
            if (qty <= 0) return error.InvalidInput;
            const cart = try self.getOrCreate(tenant_id, user_id);
            try self.persistence.upsertItem(tenant_id, cart.id, product_id, qty);
        }

        pub fn clear(self: *Self, tenant_id: i64, user_id: i64) !void {
            const cart = (try self.persistence.findCart(tenant_id, user_id)) orelse return;
            try self.persistence.clearItems(tenant_id, cart.id);
        }
    };
}
