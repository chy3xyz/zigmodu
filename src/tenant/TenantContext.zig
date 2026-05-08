const std = @import("std");

/// 请求级租户上下文 — 在 HTTP 中间件中设置，在 SQL 拦截器中读取
pub const TenantContext = struct {
    tenant_id: i64 = 0,
    ignore: bool = false, // 是否跳过租户过滤

    /// 从请求路径或 JWT 中设置租户 ID
    pub fn set(self: *TenantContext, id: i64) void {
        self.tenant_id = id;
    }

    pub fn get(self: *const TenantContext) i64 {
        return self.tenant_id;
    }

    /// 临时忽略租户过滤（对标 @TenantIgnore 注解）
    pub fn ignoreTenant(self: *TenantContext) void {
        self.ignore = true;
    }

    pub fn restoreTenant(self: *TenantContext) void {
        self.ignore = false;
    }

    pub fn isActive(self: *const TenantContext) bool {
        return self.tenant_id > 0 and !self.ignore;
    }
};

/// 全局默认租户上下文（非并发场景使用）
var default_context = TenantContext{};

pub fn getDefault() *TenantContext {
    return &default_context;
}

/// 租户 ID 的 SQL 列名（可配置）
pub const TENANT_COLUMN = "tenant_id";

/// comptime marker: struct 如果声明了这个字段，表示忽略租户过滤
pub const IGNORE_TENANT_FIELD = "zigmodu_ignore_tenant";
