const std = @import("std");
const TenantContext = @import("TenantContext.zig");

/// 租户 SQL 拦截器 — 在 ORM 查询中自动注入 tenant_id 条件
pub const TenantInterceptor = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) TenantInterceptor {
        return .{ .allocator = allocator };
    }

    /// 检查 struct 是否声明了忽略租户标记
    pub fn isTenantIgnored(comptime T: type) bool {
        if (@hasDecl(T, "zigmodu_ignore_tenant")) {
            return T.zigmodu_ignore_tenant;
        }
        return false;
    }

    /// 检查 struct 是否有 tenant_id 字段
    pub fn hasTenantField(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        inline for (info.@"struct".fields) |field| {
            if (std.mem.eql(u8, field.name, TenantContext.TENANT_COLUMN)) return true;
        }
        return false;
    }

    /// 包装 SELECT 查询，自动追加 AND tenant_id = ?
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

    /// 构建 WHERE 子句的租户条件片段
    pub fn tenantWhere(ctx: *const TenantContext) ?[]const u8 {
        if (!ctx.isActive()) return null;
        return "WHERE " ++ TenantContext.TENANT_COLUMN ++ " = ?";
    }

    /// 构建 AND 租户条件片段
    pub fn tenantAnd(ctx: *const TenantContext) ?[]const u8 {
        if (!ctx.isActive()) return null;
        return "AND " ++ TenantContext.TENANT_COLUMN ++ " = ?";
    }

    /// 获取当前租户 ID
    pub fn tenantId(ctx: *const TenantContext) i64 {
        return ctx.tenant_id;
    }
};

/// ORM Repository 的租户感知 helper — 编译期检查
pub fn TenantRepository(comptime T: type) type {
    return struct {
        const Self = @This();

        /// 在查询前自动追加租户条件
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

