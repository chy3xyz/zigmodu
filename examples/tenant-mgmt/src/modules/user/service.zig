const std = @import("std");
const model = @import("model.zig");
const enums = @import("../../business/enums.zig");

pub fn UserService(comptime Persistence: type) type {
    return struct {
        const Self = @This();
        persistence: Persistence,

        pub fn init(p: Persistence) Self {
            return .{ .persistence = p };
        }

        pub fn create(self: *Self, tenant_id: i64, username: []const u8, email: []const u8, role_str: []const u8) !model.User {
            if (username.len < 2) return error.InvalidUsername;
            if (!std.mem.containsAtLeast(u8, email, 1, "@")) return error.InvalidEmail;

            const role = enums.UserRole.fromString(role_str);
            const now = 0;

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
            _ = try self.persistence.insert(user);
            return user;
        }

        pub fn listByTenant(self: *Self, tenant_id: i64) !@import("zigmodu").data.sqlx.QueryResult(model.User) {
            return try self.persistence.findByTenant(tenant_id);
        }

        pub fn getById(self: *Self, tenant_id: i64, user_id: i64) !?model.User {
            return try self.persistence.findById(tenant_id, user_id);
        }
    };
}
