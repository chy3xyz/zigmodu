const std = @import("std");
const zigmodu = @import("zigmodu");
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
            return self.db.queryRowPartial(
                model.Tenant,
                "SELECT id, name, domain, status, tier, created_at, updated_at FROM tenants WHERE id = ?",
                &.{.{ .int = id }},
            ) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
        }

        pub fn findAll(self: *Self) !zigmodu.data.sqlx.QueryResult(model.Tenant) {
            return try self.db.queryRowsPartial(
                model.Tenant,
                "SELECT id, name, domain, status, tier, created_at, updated_at FROM tenants WHERE status = 1 ORDER BY id",
                &.{},
            );
        }

        pub fn insert(self: *Self, tenant: model.Tenant) !i64 {
            const result = try self.db.exec(
                "INSERT INTO tenants (name, domain, status, tier, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
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
    };
}
