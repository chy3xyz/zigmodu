//! Handler-side permission matching.
//!
//! The gate's OR syntax (`portal:user|portal:shop`) is a public contract, but
//! until now it existed only inside the gate: a handler that needed to know
//! which branch matched had to re-implement the check from `roles` /
//! `permissions`. The reported failure mode is real — a route declared to accept
//! both portals, with a handler reusing a shop-only check, 403s every C-end
//! user. These tests pin that one expression now has one meaning.

const std = @import("std");
const api = @import("../api/Server.zig");
const http = @import("../http.zig");
const Rbac = @import("../security/Rbac.zig");

fn ctxWith(allocator: std.mem.Allocator, attrs: []const [2][]const u8) !api.Context {
    var ctx = try api.Context.init(allocator, .GET, "/store/list");
    for (attrs) |pair| try ctx.setAttr(pair[0], pair[1]);
    return ctx;
}

test "permissionMatches reads the same OR expression the route declares" {
    const allocator = std.testing.allocator;

    // Identity: a C-end portal user.
    {
        var ctx = try ctxWith(allocator, &.{
            .{ "roles", "portal:user" },
            .{ "permissions", "portal:user,store:list" },
        });
        defer ctx.deinit();

        // The exact string a RouteMeta would carry.
        try std.testing.expect(ctx.permissionMatches("portal:user|portal:shop"));
        try std.testing.expect(http.permissionMatchesContext(&ctx, "portal:user|portal:shop"));
        // A single code, and a code that only appears in `permissions`.
        try std.testing.expect(ctx.permissionMatches("store:list"));
        // Shop-only must stay false for a C-end user — the point of asking.
        try std.testing.expect(!ctx.permissionMatches("portal:shop"));
        try std.testing.expect(!ctx.permissionMatches("store:update"));
    }

    // Identity: a supplier-portal user, same route.
    {
        var ctx = try ctxWith(allocator, &.{.{ "roles", "portal:shop" }});
        defer ctx.deinit();
        try std.testing.expect(ctx.permissionMatches("portal:user|portal:shop"));
        try std.testing.expect(ctx.permissionMatches("portal:shop"));
        try std.testing.expect(!ctx.permissionMatches("portal:user"));
    }

    // Whitespace and empty alternatives are tolerated; no identity → no match.
    {
        var ctx = try ctxWith(allocator, &.{.{ "roles", " a , b " }});
        defer ctx.deinit();
        try std.testing.expect(ctx.permissionMatches("a"));
        try std.testing.expect(ctx.permissionMatches("b"));
        try std.testing.expect(ctx.permissionMatches("|a|"));
        try std.testing.expect(!ctx.permissionMatches(""));
    }
    {
        var ctx = try api.Context.init(allocator, .GET, "/x");
        defer ctx.deinit();
        try std.testing.expect(!ctx.permissionMatches("portal:user|portal:shop"));
    }
}

test "permissionMatches also sees an attached RBAC AuthInfo" {
    const allocator = std.testing.allocator;

    var auth = Rbac.AuthInfo{
        .user_id = 7,
        .tenant_id = 1,
        .username = try allocator.dupe(u8, "u"),
        .role_ids = try allocator.alloc(i64, 0),
        .permissions = std.StringHashMap(bool).init(allocator),
    };
    defer auth.deinit(allocator);
    try auth.permissions.put(try allocator.dupe(u8, "portal:shop"), true);

    var ctx = try api.Context.init(allocator, .GET, "/x");
    defer ctx.deinit();
    // jwtAuthFromCatalogWithPermissions publishes `permissions` as an attr so
    // handlers need not read AuthInfo; `permissionMatches` covers both.
    ctx.setAuthInfo(@ptrCast(&auth));
    try std.testing.expect(ctx.permissionMatches("portal:shop"));
    try std.testing.expect(ctx.permissionMatches("portal:user|portal:shop"));
    try std.testing.expect(!ctx.permissionMatches("portal:user"));

    // `permissionMatchesWith(.rbac)` mirrors the gate: AuthInfo is authoritative
    // when attached, so a stale attr cannot broaden the answer.
    try ctx.setAttr("permissions", "portal:user");
    try std.testing.expect(!http.permissionMatchesWith(&ctx, "portal:user", .{ .mode = .rbac }));
    try std.testing.expect(http.permissionMatchesWith(&ctx, "portal:shop", .{ .mode = .rbac }));
}

test "permissionsCsv mirrors rolesCsv" {
    const allocator = std.testing.allocator;

    var ctx = try api.Context.init(allocator, .GET, "/x");
    defer ctx.deinit();
    try std.testing.expect(ctx.permissionsCsv() == null);
    try ctx.setAttr("permissions", "a,b");
    try std.testing.expectEqualStrings("a,b", ctx.permissionsCsv().?);
}

test "permissionMatchesWith(.roles) mirrors the roles-mode gate" {
    const allocator = std.testing.allocator;

    var ctx = try ctxWith(allocator, &.{
        .{ "roles", "portal:user" },
        .{ "permissions", "portal:shop" },
    });
    defer ctx.deinit();

    // `.roles` reads only the roles attr — same narrowness as the gate, which is
    // the point: the handler's answer matches the gate it sits behind.
    try std.testing.expect(http.permissionMatchesWith(&ctx, "portal:user", .{ .mode = .roles }));
    try std.testing.expect(!http.permissionMatchesWith(&ctx, "portal:shop", .{ .mode = .roles }));

    // `.rbac` with no AuthInfo attached falls back to the permissions attr.
    try std.testing.expect(http.permissionMatchesWith(&ctx, "portal:shop", .{ .mode = .rbac }));
    try std.testing.expect(!http.permissionMatchesWith(&ctx, "portal:user", .{ .mode = .rbac }));
}
