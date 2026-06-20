const std = @import("std");
const zigmodu = @import("zigmodu");
const model = @import("model.zig");
const persistence = @import("persistence.zig");
const enums = @import("../../business/enums.zig");

/// Tenant 服务层 — 业务逻辑
pub fn TenantService(comptime Persistence: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        persistence: Persistence,

        pub fn init(allocator: std.mem.Allocator, p: Persistence) Self {
            return .{ .allocator = allocator, .persistence = p };
        }

        pub fn freeTenantList(self: *Self, tenants: []model.Tenant) void {
            persistence.TenantPersistence(@TypeOf(self.persistence)).freeTenants(self.allocator, tenants);
        }

        /// 创建租户 (带验证和默认值)
        pub fn create(self: *Self, name: []const u8, domain: []const u8, tier_str: []const u8) !model.Tenant {
            if (name.len < 2 or name.len > 100) return error.InvalidName;
            if (domain.len < 3 or !std.mem.containsAtLeast(u8, domain, 1, ".")) return error.InvalidDomain;

            const tier = enums.TenantTier.fromString(tier_str);
            const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());

            const tenant = model.Tenant{
                .id = 0,
                .name = name,
                .domain = domain,
                .status = @intFromEnum(enums.TenantStatus.active),
                .tier = tier.toString(),
                .created_at = now,
                .updated_at = now,
            };

            const id = try self.persistence.insert(tenant);
            var created = tenant;
            created.id = id;
            return created;
        }

        /// 获取租户 (校验状态)
        pub fn getById(self: *Self, id: i64) !?model.Tenant {
            const tenant = try self.persistence.findById(id);
            if (tenant) |t| {
                if (t.status != @intFromEnum(enums.TenantStatus.active)) return error.TenantSuspended;
            }
            return tenant;
        }

        /// 更新租户套餐
        pub fn updateTier(self: *Self, id: i64, tier_str: []const u8) !void {
            var tenant = (try self.getById(id)) orelse return error.TenantNotFound;
            self.allocator.free(tenant.tier);
            const tier = enums.TenantTier.fromString(tier_str);
            tenant.tier = tier.toString();
            tenant.updated_at = @intCast(zigmodu.time.monotonicNowSeconds());
            try self.persistence.update(tenant);
        }

        /// 暂停租户
        pub fn suspendTenant(self: *Self, id: i64) !void {
            var tenant = (try self.getById(id)) orelse return error.TenantNotFound;
            tenant.status = @intFromEnum(enums.TenantStatus.suspended);
            tenant.updated_at = @intCast(zigmodu.time.monotonicNowSeconds());
            try self.persistence.update(tenant);
        }

        /// 获取所有活跃租户
        pub fn listActive(self: *Self) ![]model.Tenant {
            return try self.persistence.findAll();
        }

        /// 按套餐统计
        pub fn countByTier(self: *Self) !struct { free: usize, pro: usize, enterprise: usize } {
            return .{
                .free = try self.persistence.countByTier("free"),
                .pro = try self.persistence.countByTier("pro"),
                .enterprise = try self.persistence.countByTier("enterprise"),
            };
        }
    };
}
