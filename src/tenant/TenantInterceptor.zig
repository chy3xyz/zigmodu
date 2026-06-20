const std = @import("std");
const TenantContext = @import("TenantContext.zig");

/// Tenant SQL interceptor — auto-injects tenant_id into ORM queries
pub const TenantInterceptor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TenantInterceptor {
        return .{ .allocator = allocator };
    }

    /// Check if struct declares tenant-ignore marker
    pub fn isTenantIgnored(comptime T: type) bool {
        if (@hasDecl(T, "zigmodu_ignore_tenant")) {
            return T.zigmodu_ignore_tenant;
        }
        if (@hasDecl(T, "is_global")) {
            return T.is_global;
        }
        return false;
    }

    /// Check if struct has tenant_id field
    pub fn hasTenantField(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        inline for (info.@"struct".field_names, info.@"struct".field_types, info.@"struct".field_attrs, 0..) |field_name, field_typ, field_attr, fi| {
            _ = field_typ; _ = field_attr; _ = fi;
            if (std.mem.eql(u8, field_name, TenantContext.TENANT_COLUMN)) return true;
        }
        return false;
    }

    /// Wrap SELECT query, auto-append AND tenant_id = ?
    pub fn wrapSelect(
        self: *TenantInterceptor,
        ctx: *const TenantContext,
        sql: []const u8,
    ) ![]const u8 {
        if (!ctx.isActive()) return sql;

        return try std.fmt.allocPrint(
            self.allocator,
            "{s} AND {s} = ?",
            .{ sql, TenantContext.TENANT_COLUMN },
        );
    }

    /// Build tenant condition fragment for WHERE clause
    pub fn tenantWhere(ctx: *const TenantContext) ?[]const u8 {
        if (!ctx.isActive()) return null;
        return "WHERE " ++ TenantContext.TENANT_COLUMN ++ " = ?";
    }

    /// Build AND tenant condition fragment
    pub fn tenantAnd(ctx: *const TenantContext) ?[]const u8 {
        if (!ctx.isActive()) return null;
        return "AND " ++ TenantContext.TENANT_COLUMN ++ " = ?";
    }

    /// Get current tenant ID
    pub fn tenantId(ctx: *const TenantContext) i64 {
        return ctx.tenant_id;
    }
};

/// Tenant-aware ORM Repository helper — comptime checks
pub fn TenantRepository(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Auto-append tenant condition before query
        pub fn buildTenantWhere(comptime base_where: []const u8) []const u8 {
            if (TenantInterceptor.isTenantIgnored(T)) return base_where;
            if (!TenantInterceptor.hasTenantField(T)) return base_where;

            if (base_where.len == 0) {
                return "WHERE " ++ TenantContext.TENANT_COLUMN ++ " = ?";
            }
            return base_where ++ " AND " ++ TenantContext.TENANT_COLUMN ++ " = ?";
        }
    };
}

test "TenantInterceptor tenant field detection" {
    const T1 = struct { tenant_id: i64, name: []const u8 };
    const T2 = struct { id: i64, name: []const u8 };

    try std.testing.expect(TenantInterceptor.hasTenantField(T1));
    try std.testing.expect(!TenantInterceptor.hasTenantField(T2));
}

test "TenantInterceptor isTenantIgnored" {
    const Admin = struct { pub const is_global = true; };
    const User = struct {};

    try std.testing.expect(TenantInterceptor.isTenantIgnored(Admin));
    try std.testing.expect(!TenantInterceptor.isTenantIgnored(User));
}

