const std = @import("std");

/// Request-scoped tenant context — set in HTTP middleware, read in SQL interceptor
pub const TenantContext = struct {
    tenant_id: i64 = 0,
    ignore: bool = false, // Skip tenant filtering

    /// Set tenant ID from request path or JWT
    pub fn set(self: *TenantContext, id: i64) void {
        self.tenant_id = id;
    }

    pub fn get(self: *const TenantContext) i64 {
        return self.tenant_id;
    }

    /// Temporarily ignore tenant filtering (like @TenantIgnore annotation)
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

/// Global default tenant context (non-concurrent use)
var default_context = TenantContext{};

pub fn getDefault() *TenantContext {
    return &default_context;
}

/// SQL column name for tenant ID (configurable)
pub const TENANT_COLUMN = "tenant_id";

/// comptime marker: struct declares this field to skip tenant filtering
pub const IGNORE_TENANT_FIELD = "zigmodu_ignore_tenant";
