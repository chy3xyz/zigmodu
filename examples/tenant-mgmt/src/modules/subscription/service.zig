const std = @import("std");
const model = @import("model.zig");
const enums = @import("../../business/enums.zig");

pub fn SubscriptionService(comptime Persistence: type) type {
    return struct {
        const Self = @This();
        persistence: Persistence,

        pub fn init(p: Persistence) Self {
            return .{ .persistence = p };
        }

        /// 为租户创建订阅
        pub fn subscribe(self: *Self, tenant_id: i64, plan_id: i64) !model.Subscription {
            const now = 0;
            const sub = model.Subscription{
                .id = 0,
                .tenant_id = tenant_id,
                .plan_id = plan_id,
                .status = "active",
                .started_at = now,
                .expires_at = now + 365 * 24 * 3600,
                .created_at = now,
            };
            _ = try self.persistence.create(sub);
            return sub;
        }

        /// 获取租户当前订阅
        pub fn getByTenant(self: *Self, tenant_id: i64) !?model.Subscription {
            return try self.persistence.findByTenant(tenant_id);
        }

        /// 取消订阅
        pub fn cancel(self: *Self, subscription_id: i64) !void {
            try self.persistence.updateStatus(subscription_id, enums.SubscriptionStatus.cancelled.toString());
        }

        /// 列出所有可用套餐（调用方 `defer result.deinit(allocator)`）
        pub fn listPlans(self: *Self) !@import("zigmodu").data.sqlx.QueryResult(model.Plan) {
            return try self.persistence.findAllPlans();
        }
    };
}
