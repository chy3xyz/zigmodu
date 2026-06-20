const std = @import("std");
const model = @import("model.zig");

pub fn SubscriptionPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        db: Backend,

        pub fn init(db: Backend) Self {
            return .{ .db = db };
        }

        pub fn findByTenant(self: *Self, tenant_id: i64) !?model.Subscription {
            return self.db.queryRowPartial(model.Subscription,
                "SELECT id, tenant_id, plan_id, status, started_at, expires_at, created_at FROM subscriptions WHERE tenant_id = ?1 ORDER BY id DESC LIMIT 1",
                &.{.{ .int = tenant_id }},
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
        }

        pub fn create(self: *Self, sub: model.Subscription) !i64 {
            const result = try self.db.exec(
                "INSERT INTO subscriptions (tenant_id, plan_id, status, started_at, expires_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                &.{
                    .{ .int = sub.tenant_id },
                    .{ .int = sub.plan_id },
                    .{ .string = sub.status },
                    .{ .int = sub.started_at },
                    .{ .int = sub.expires_at },
                    .{ .int = sub.created_at },
                },
            );
            return result.last_insert_id orelse return error.DatabaseError;
        }

        pub fn updateStatus(self: *Self, id: i64, status: []const u8) !void {
            _ = try self.db.exec(
                "UPDATE subscriptions SET status = ?1 WHERE id = ?2",
                &.{ .{ .string = status }, .{ .int = id } },
            );
        }

        pub fn findAllPlans(self: *Self) ![]model.Plan {
            return try self.db.queryRowsPartial(model.Plan,
                "SELECT id, name, max_users, max_storage, price, created_at FROM plans ORDER BY id",
                &.{},
            );
        }
    };
}
