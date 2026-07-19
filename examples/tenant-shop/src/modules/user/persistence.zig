const model = @import("model.zig");

pub fn UserPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        db: Backend,

        pub fn init(db: Backend) Self {
            return .{ .db = db };
        }

        pub fn findByTenant(self: *Self, tenant_id: i64) ![]model.User {
            return try self.db.queryRowsPartial(model.User,
                "SELECT id, tenant_id, username, email, password_hash, role, status, created_at, updated_at FROM users WHERE tenant_id = ? ORDER BY id",
                &.{.{ .int = tenant_id }},
            );
        }

        pub fn insert(self: *Self, user: model.User) !i64 {
            const result = try self.db.exec(
                "INSERT INTO users (tenant_id, username, email, password_hash, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                &.{
                    .{ .int = user.tenant_id },
                    .{ .string = user.username },
                    .{ .string = user.email },
                    .{ .string = user.password_hash },
                    .{ .string = user.role },
                    .{ .int = user.status },
                    .{ .int = user.created_at },
                    .{ .int = user.updated_at },
                },
            );
            return result.last_insert_id orelse return error.DatabaseError;
        }
    };
}
