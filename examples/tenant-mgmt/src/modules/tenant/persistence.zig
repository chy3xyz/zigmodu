const std = @import("std");
const model = @import("model.zig");

pub fn TenantPersistence(comptime Backend: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        db: Backend,

        pub fn init(allocator: std.mem.Allocator, db: Backend) Self {
            return .{ .allocator = allocator, .db = db };
        }

        pub fn freeTenant(allocator: std.mem.Allocator, tenant: model.Tenant) void {
            allocator.free(tenant.name);
            allocator.free(tenant.domain);
            allocator.free(tenant.tier);
        }

        pub fn freeTenants(allocator: std.mem.Allocator, tenants: []model.Tenant) void {
            for (tenants) |t| freeTenant(allocator, t);
            allocator.free(tenants);
        }

        pub fn findById(self: *Self, id: i64) !?model.Tenant {
            const tenant = self.db.queryRowPartial(model.Tenant,
                "SELECT id, name, domain, status, tier, created_at, updated_at FROM tenants WHERE id = ?1",
                &.{.{ .int = id }},
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
            return tenant;
        }

        pub fn findByDomain(self: *Self, domain: []const u8) !?model.Tenant {
            const tenant = self.db.queryRowPartial(model.Tenant,
                "SELECT id, name, domain, status, tier, created_at, updated_at FROM tenants WHERE domain = ?1",
                &.{.{ .string = domain }},
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
            return tenant;
        }

        pub fn findAll(self: *Self) ![]model.Tenant {
            return try self.db.queryRowsPartial(model.Tenant,
                "SELECT id, name, domain, status, tier, created_at, updated_at FROM tenants WHERE status = 1 ORDER BY id",
                &.{},
            );
        }

        pub fn insert(self: *Self, tenant: model.Tenant) !i64 {
            const result = try self.db.exec(
                "INSERT INTO tenants (name, domain, status, tier, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                &.{
                    .{ .string = tenant.name },
                    .{ .string = tenant.domain },
                    .{ .int = tenant.status },
                    .{ .string = tenant.tier },
                    .{ .int = tenant.created_at },
                    .{ .int = tenant.updated_at },
                },
            );
            return result.last_insert_id orelse return error.DatabaseError;
        }

        pub fn update(self: *Self, tenant: model.Tenant) !void {
            _ = try self.db.exec(
                "UPDATE tenants SET name = ?1, domain = ?2, status = ?3, tier = ?4, updated_at = ?5 WHERE id = ?6",
                &.{
                    .{ .string = tenant.name },
                    .{ .string = tenant.domain },
                    .{ .int = tenant.status },
                    .{ .string = tenant.tier },
                    .{ .int = tenant.updated_at },
                    .{ .int = tenant.id },
                },
            );
        }

        pub fn countByTier(self: *Self, tier: []const u8) !usize {
            var rows = try self.db.query(
                "SELECT COUNT(*) AS cnt FROM tenants WHERE tier = ?1 AND status = 1",
                &.{.{ .string = tier }},
            );
            defer rows.deinit();
            const cnt_val = (rows.rows[0].get("cnt") orelse return error.DatabaseError);
            return @intCast(cnt_val.int);
        }
    };
}
