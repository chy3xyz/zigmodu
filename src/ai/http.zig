//! HTTP → AI adapters.
//!
//! Kept out of `skill.zig` on purpose: the skill/registry layer is core (it is
//! what MCP stdio servers, workers and tests import), and pulling the HTTP
//! domain into it would make every one of those consumers depend on the server
//! to construct a context. The adapter converts a **verified** request into the
//! identity the AI stack acts on.

const std = @import("std");
const http = @import("../http.zig");
const SkillContext = @import("skill.zig").SkillContext;

/// Build a context from a **verified** HTTP request.
///
/// The ids come from the request *attributes* the catalog JWT middleware
/// writes (`user_id`, `tenant_id`), never from a header or the body: those are
/// client input and cannot say who the caller is (see the approval API's
/// `X-Tenant-ID` handling for the failure this rule prevents). `permissions` is
/// the CSV the permission gate writes.
///
/// Fail-closed: absent or non-numeric ids are errors, not silent `null`/`0`.
/// A deployment that genuinely runs without tenancy must build the struct
/// literally and say so; the default path does not guess.
///
/// Allocation: the permission strings and their slice live in `ctx.allocator`
/// (the request arena in production), so the context is valid for that request
/// — nothing here outlives it.
pub fn skillContext(ctx: *http.Context) !SkillContext {
    const tenant_raw = ctx.tenantId() orelse return error.TenantRequired;
    const tenant_id = std.fmt.parseInt(i64, tenant_raw, 10) catch return error.MalformedTenant;
    const user_raw = ctx.userId() orelse return error.UserRequired;
    const user_id = std.fmt.parseInt(i64, user_raw, 10) catch return error.MalformedUser;

    var perms = std.ArrayList([]const u8).empty;
    errdefer perms.deinit(ctx.allocator);
    if (ctx.permissionsCsv()) |csv| {
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t");
            if (p.len == 0) continue;
            const copy = try ctx.allocator.dupe(u8, p);
            errdefer ctx.allocator.free(copy);
            try perms.append(ctx.allocator, copy);
        }
    }
    return .{
        .allocator = ctx.allocator,
        .tenant_id = tenant_id,
        .user_id = user_id,
        .permissions = try perms.toOwnedSlice(ctx.allocator),
    };
}

test "skillContext takes verified attributes and ignores headers" {
    const allocator = std.testing.allocator;
    var ctx = try http.Context.init(allocator, .POST, "/agent/run");
    defer ctx.deinit();
    try ctx.setAttr("tenant_id", "7");
    try ctx.setAttr("user_id", "42");
    try ctx.setAttr("permissions", " order:read, ,order:write ");
    // Client input cannot say who the caller is: the header is not consulted.
    try ctx.headers.put(try allocator.dupe(u8, "x-tenant-id"), try allocator.dupe(u8, "9"));

    const sctx = try skillContext(&ctx);
    try std.testing.expectEqual(@as(?i64, 7), sctx.tenant_id);
    try std.testing.expectEqual(@as(?i64, 42), sctx.user_id);
    try std.testing.expectEqual(@as(usize, 2), sctx.permissions.len);
    try std.testing.expectEqualStrings("order:read", sctx.permissions[0]);
    try std.testing.expectEqualStrings("order:write", sctx.permissions[1]);

    // Production allocates these in the request arena; the test frees them.
    for (sctx.permissions) |p| allocator.free(p);
    allocator.free(sctx.permissions);
}

test "skillContext fails closed without a verified identity" {
    const allocator = std.testing.allocator;
    var ctx = try http.Context.init(allocator, .POST, "/agent/run");
    defer ctx.deinit();

    try std.testing.expectError(error.TenantRequired, skillContext(&ctx));
    try ctx.setAttr("tenant_id", "not-a-number");
    try std.testing.expectError(error.MalformedTenant, skillContext(&ctx));
    try ctx.setAttr("tenant_id", "7");
    try std.testing.expectError(error.UserRequired, skillContext(&ctx));
    // Numeric ids are the framework's convention (memory/audit/quota are i64);
    // a string subject is refused instead of being silently hashed or zeroed.
    try ctx.setAttr("user_id", "alice");
    try std.testing.expectError(error.MalformedUser, skillContext(&ctx));
}
