const zigmodu = @import("zigmodu");
const model = @import("model.zig");
const enums = @import("../../business/enums.zig");

pub fn UserService(comptime Persistence: type) type {
    return struct {
        const Self = @This();
        persistence: Persistence,

        pub fn init(p: Persistence) Self {
            return .{ .persistence = p };
        }

        pub fn listByTenant(self: *Self, tenant_id: i64) ![]model.User {
            return try self.persistence.findByTenant(tenant_id);
        }

        pub fn create(self: *Self, tenant_id: i64, username: []const u8, email: []const u8, role_str: []const u8) !model.User {
            const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
            const role = enums.UserRole.fromString(role_str);
            const user = model.User{
                .id = 0,
                .tenant_id = tenant_id,
                .username = username,
                .email = email,
                .password_hash = "",
                .role = role.toString(),
                .status = 1,
                .created_at = now,
                .updated_at = now,
            };
            const id = try self.persistence.insert(user);
            var created = user;
            created.id = id;
            return created;
        }
    };
}
