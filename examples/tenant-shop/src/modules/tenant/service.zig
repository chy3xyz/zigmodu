const std = @import("std");
const zigmodu = @import("zigmodu");
const model = @import("model.zig");
const persistence = @import("persistence.zig");
const enums = @import("../../business/enums.zig");

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

        pub fn create(self: *Self, name: []const u8, domain: []const u8, tier_str: []const u8) !model.Tenant {
            if (name.len < 2) return error.InvalidInput;
            const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
            const tier = enums.TenantTier.fromString(tier_str);
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

        pub fn getById(self: *Self, id: i64) !?model.Tenant {
            return try self.persistence.findById(id);
        }

        pub fn listActive(self: *Self) ![]model.Tenant {
            return try self.persistence.findAll();
        }
    };
}
