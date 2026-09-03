const std = @import("std");

/// Request-scoped tenant context — set in HTTP middleware, read in SQL interceptor.
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

    /// Bridge from the HTTP attr pathway: build a context from the
    /// `tenant_id` attr value (JWT `aud` or tenant middleware output).
    /// Returns null when the attr is absent/invalid/non-positive — callers
    /// must treat null as "no verified tenant", never as "skip filtering".
    pub fn fromAttr(attr_value: ?[]const u8) ?TenantContext {
        const raw = attr_value orelse return null;
        const id = std.fmt.parseInt(i64, raw, 10) catch return null;
        if (id <= 0) return null;
        return .{ .tenant_id = id };
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

/// Compile-time default SQL column (`tenant_id`). Prefer `tenantColumn()` after `setTenantColumn`.
pub const TENANT_COLUMN = "tenant_id";

var configured_column: []const u8 = TENANT_COLUMN;

/// Configure the SQL/model tenant column for interceptors (e.g. `"app_id"`).
/// Call once at process start before serving requests. Column must be a simple SQL identifier.
/// Invalid names are ignored (column unchanged).
pub fn setTenantColumn(column: []const u8) void {
    if (!isSafeSqlIdent(column)) return;
    configured_column = column;
}

/// Active tenant SQL column (default `tenant_id`, or value from `setTenantColumn`).
pub fn tenantColumn() []const u8 {
    return configured_column;
}

fn isSafeSqlIdent(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    const c0 = name[0];
    if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_')) return false;
    for (name[1..]) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) return false;
    }
    return true;
}

/// comptime marker: struct declares this field to skip tenant filtering
pub const IGNORE_TENANT_FIELD = "zigmodu_ignore_tenant";

test "setTenantColumn switches active column" {
    const prev = tenantColumn();
    defer setTenantColumn(prev);

    setTenantColumn("app_id");
    try std.testing.expectEqualStrings("app_id", tenantColumn());
    setTenantColumn("tenant_id");
    try std.testing.expectEqualStrings("tenant_id", tenantColumn());
}

test "setTenantColumn rejects unsafe identifiers" {
    const prev = tenantColumn();
    defer setTenantColumn(prev);

    setTenantColumn("app_id; drop");
    try std.testing.expectEqualStrings(prev, tenantColumn());
}

test "TenantContext.fromAttr bridges the HTTP attr pathway" {
    const ctx = TenantContext.fromAttr("42").?;
    try std.testing.expectEqual(@as(i64, 42), ctx.get());
    try std.testing.expect(ctx.isActive());

    try std.testing.expect(TenantContext.fromAttr(null) == null);
    try std.testing.expect(TenantContext.fromAttr("") == null);
    try std.testing.expect(TenantContext.fromAttr("abc") == null);
    try std.testing.expect(TenantContext.fromAttr("0") == null);
    try std.testing.expect(TenantContext.fromAttr("-3") == null);
}
