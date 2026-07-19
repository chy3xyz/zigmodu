const zigmodu = @import("zigmodu");
const model = @import("model.zig");

pub fn ProductService(comptime Persistence: type) type {
    return struct {
        const Self = @This();
        persistence: Persistence,

        pub fn init(p: Persistence) Self {
            return .{ .persistence = p };
        }

        pub fn listByTenant(self: *Self, tenant_id: i64) ![]model.Product {
            return try self.persistence.findByTenant(tenant_id);
        }

        pub fn create(self: *Self, tenant_id: i64, name: []const u8, price_cents: i64) !model.Product {
            const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
            const p = model.Product{
                .id = 0,
                .tenant_id = tenant_id,
                .name = name,
                .price_cents = price_cents,
                .status = 1,
                .created_at = now,
                .updated_at = now,
            };
            const id = try self.persistence.insert(p);
            var created = p;
            created.id = id;
            return created;
        }
    };
}
