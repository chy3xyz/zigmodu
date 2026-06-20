const std = @import("std");
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
                "SELECT id, tenant_id, username, email, password_hash, role, status, created_at, updated_at FROM users WHERE tenant_id = ?1 ORDER BY id",
                &.{.{ .int = tenant_id }},
            );
        }

        pub fn findById(self: *Self, tenant_id: i64, user_id: i64) !?model.User {
            return self.db.queryRowPartial(model.User,
                "SELECT id, tenant_id, username, email, password_hash, role, status, created_at, updated_at FROM users WHERE tenant_id = ?1 AND id = ?2",
                &.{ .{ .int = tenant_id }, .{ .int = user_id } },
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
        }

        pub fn insert(self: *Self, user: model.User) !i64 {
            const result = try self.db.exec(
                "INSERT INTO users (tenant_id, username, email, password_hash, role, status, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
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

        pub fn countByTenant(self: *Self, tenant_id: i64) !usize {
            var rows = try self.db.query(
                "SELECT COUNT(*) AS cnt FROM users WHERE tenant_id = ?1",
                &.{.{ .int = tenant_id }},
            );
            defer rows.deinit();
            const cnt_val = (rows.rows[0].get("cnt") orelse return error.DatabaseError);
            return @intCast(cnt_val.int);
        }
    };
}
