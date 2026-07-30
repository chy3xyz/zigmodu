const std = @import("std");
const tc_mod = @import("TenantContext.zig");
const TenantContext = tc_mod.TenantContext;

/// Tenant SQL interceptor — auto-injects tenant column into ORM queries.
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

    /// True if struct has a common tenant field (`tenant_id` or `app_id`).
    pub fn hasTenantField(comptime T: type) bool {
        return @hasField(T, "tenant_id") or @hasField(T, "app_id");
    }

    /// True if struct has the given tenant column field name.
    pub fn hasTenantFieldNamed(comptime T: type, comptime col: []const u8) bool {
        return @hasField(T, col);
    }

    /// Wrap SELECT query, auto-append AND {tenant_column} = ?
    pub fn wrapSelect(
        self: *TenantInterceptor,
        ctx: *const TenantContext,
        sql: []const u8,
    ) ![]const u8 {
        if (!ctx.isActive()) return sql;

        return try std.fmt.allocPrint(
            self.allocator,
            "{s} AND {s} = ?",
            .{ sql, tc_mod.tenantColumn() },
        );
    }

    /// Build tenant condition fragment for WHERE clause (uses active `tenantColumn()`).
    pub fn tenantWhere(ctx: *const TenantContext) ?[]const u8 {
        if (!ctx.isActive()) return null;
        return staticWhere(tc_mod.tenantColumn());
    }

    /// Build AND tenant condition fragment (uses active `tenantColumn()`).
    pub fn tenantAnd(ctx: *const TenantContext) ?[]const u8 {
        if (!ctx.isActive()) return null;
        return staticAnd(tc_mod.tenantColumn());
    }

    fn staticWhere(col: []const u8) []const u8 {
        if (std.mem.eql(u8, col, "app_id")) return "WHERE app_id = ?";
        return "WHERE tenant_id = ?";
    }

    fn staticAnd(col: []const u8) []const u8 {
        if (std.mem.eql(u8, col, "app_id")) return "AND app_id = ?";
        return "AND tenant_id = ?";
    }

    /// Get current tenant ID
    pub fn tenantId(ctx: *const TenantContext) i64 {
        return ctx.tenant_id;
    }
};

/// Tenant-aware ORM Repository helper — comptime checks.
/// `col` defaults to compile-time `TENANT_COLUMN` (`tenant_id`); pass `"app_id"` when needed.
pub fn TenantRepository(comptime T: type) type {
    return TenantRepositoryCol(T, tc_mod.TENANT_COLUMN);
}

pub fn TenantRepositoryCol(comptime T: type, comptime col: []const u8) type {
    return struct {
        /// Auto-append tenant condition before query
        pub fn buildTenantWhere(comptime base_where: []const u8) []const u8 {
            if (TenantInterceptor.isTenantIgnored(T)) return base_where;
            if (!TenantInterceptor.hasTenantFieldNamed(T, col)) return base_where;

            if (base_where.len == 0) {
                return "WHERE " ++ col ++ " = ?";
            }
            return base_where ++ " AND " ++ col ++ " = ?";
        }
    };
}

test "TenantInterceptor tenant field detection" {
    const T1 = struct { tenant_id: i64, name: []const u8 };
    const T2 = struct { id: i64, name: []const u8 };
    const T3 = struct { app_id: i64, name: []const u8 };

    try std.testing.expect(TenantInterceptor.hasTenantField(T1));
    try std.testing.expect(!TenantInterceptor.hasTenantField(T2));
    try std.testing.expect(TenantInterceptor.hasTenantField(T3));
    try std.testing.expect(TenantInterceptor.hasTenantFieldNamed(T3, "app_id"));
}

test "TenantInterceptor isTenantIgnored" {
    const Admin = struct {
        pub const is_global = true;
    };
    const User = struct {};

    try std.testing.expect(TenantInterceptor.isTenantIgnored(Admin));
    try std.testing.expect(!TenantInterceptor.isTenantIgnored(User));
}

test "TenantInterceptor wrapSelect uses configured column" {
    const allocator = std.testing.allocator;
    const prev = tc_mod.tenantColumn();
    defer tc_mod.setTenantColumn(prev);

    tc_mod.setTenantColumn("app_id");
    var ix = TenantInterceptor.init(allocator);
    var ctx = TenantContext{ .tenant_id = 7 };
    const wrapped = try ix.wrapSelect(&ctx, "SELECT * FROM products WHERE status = 1");
    defer allocator.free(wrapped);
    try std.testing.expectEqualStrings("SELECT * FROM products WHERE status = 1 AND app_id = ?", wrapped);
}

test "TenantRepositoryCol buildTenantWhere app_id" {
    const Row = struct { app_id: i64, name: []const u8 };
    const clause = TenantRepositoryCol(Row, "app_id").buildTenantWhere("");
    try std.testing.expectEqualStrings("WHERE app_id = ?", clause);
}
