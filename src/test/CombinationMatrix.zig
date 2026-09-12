//! Combination-matrix tests.
//!
//! Individually-tested components still fail on the *combinations* — the zent
//! incident that motivated this file was `eager-load × interceptor × same-named
//! columns on both sides`, where every piece was covered and the combination was
//! not. Each test here pins one interaction that a production app actually runs:
//!
//!   - `moduleGate(.unknown = .deny) × skip_prefixes`
//!   - `tenantResolver × JWT aud × override_existing`
//!   - `auth = .optional × valid/invalid/absent token` (Middleware.zig) —
//!     covered next to the middleware itself.

const std = @import("std");
const api = @import("../api/Server.zig");
const mw = @import("../api/Middleware.zig");
const cr = @import("../api/ComptimeRouter.zig");

fn runMiddleware(allocator: std.mem.Allocator, m: api.Middleware, ctx: *api.Context) !void {
    const S = struct {
        var reached: bool = false;
        fn exit(c: *api.Context) anyerror!void {
            _ = c;
            reached = true;
        }
    };
    S.reached = false;
    try m.func(ctx, S.exit, m.user_data);
    _ = allocator;
}

test "moduleGate(unknown = .deny) denies outside the catalog but honors skip_prefixes" {
    const allocator = std.testing.allocator;
    const AppState = struct {};

    const Api = struct {
        pub const module_name = "catalog";
        pub const nest = .{};
        pub const State = @This();
        pub const routes = [_]cr.RouteSpec(State){
            .{ .method = .GET, .path = "products", .handler = hit, .meta = .{ .auth = .public } },
        };
        fn hit(ctx: *api.Context, _: *State) !void {
            try ctx.json(200, "{}");
        }
    };

    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var app_state: AppState = .{};
    var api_state: Api = .{};
    var router = cr.Router(AppState).init(std.testing.io, allocator, &server, &app_state);
    defer router.deinit();
    var root = router.scope("");
    try root.mountAll(.{.{ .Mod = Api, .state = &api_state }});
    var slot: cr.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(try router.finish());

    const gate = mw.moduleGate(&slot, .{ .unknown = .deny });

    // 1) Known catalog route → module attr set, chain continues.
    {
        var ctx = try api.Context.init(allocator, .GET, "/products");
        defer ctx.deinit();
        try runMiddleware(allocator, gate, &ctx);
        try std.testing.expectEqualStrings("catalog", ctx.getAttr("module").?);
    }
    // 2) Unknown path → denied (default reject writes 403/404 … whatever the
    //    envelope is; the contract is "not passed through").
    {
        var ctx = try api.Context.init(allocator, .GET, "/not-in-catalog");
        defer ctx.deinit();
        try runMiddleware(allocator, gate, &ctx);
        try std.testing.expect(ctx.responded);
    }
    // 3) Unknown path **under a skip prefix** → allowed (infra routes live
    //    outside the catalog: probes, metrics, dashboard).
    {
        var ctx = try api.Context.init(allocator, .GET, "/health/live");
        defer ctx.deinit();
        try runMiddleware(allocator, gate, &ctx);
        try std.testing.expect(!ctx.responded);
    }
}

test "tenantResolver: JWT aud wins by default, header wins with override_existing" {
    const allocator = std.testing.allocator;

    // Default: an attr already set (JWT `aud`) is authoritative.
    {
        var ctx = try api.Context.init(allocator, .GET, "/x");
        defer ctx.deinit();
        try ctx.setAttr("tenant_id", "from-jwt");
        try ctx.headers.put(try allocator.dupe(u8, "appid"), try allocator.dupe(u8, "from-header"));
        try runMiddleware(allocator, mw.tenantResolver(.{}), &ctx);
        try std.testing.expectEqualStrings("from-jwt", ctx.tenantId().?);
    }
    // override_existing = true: the transport value is the explicit override.
    {
        var ctx = try api.Context.init(allocator, .GET, "/x");
        defer ctx.deinit();
        try ctx.setAttr("tenant_id", "from-jwt");
        try ctx.headers.put(try allocator.dupe(u8, "appid"), try allocator.dupe(u8, "from-header"));
        try runMiddleware(allocator, mw.tenantResolver(.{ .override_existing = true }), &ctx);
        try std.testing.expectEqualStrings("from-header", ctx.tenantId().?);
    }
    // No JWT and no header, `require = true` → rejected instead of proceeding
    // with an empty tenant (the failure mode that leaks across tenants).
    {
        var ctx = try api.Context.init(allocator, .GET, "/x");
        defer ctx.deinit();
        try runMiddleware(allocator, mw.tenantResolver(.{ .require = true }), &ctx);
        try std.testing.expect(ctx.responded);
    }
    // Query fallback still works when no header is present.
    {
        var ctx = try api.Context.init(allocator, .GET, "/x");
        defer ctx.deinit();
        try ctx.query.put("app_id", "from-query");
        try runMiddleware(allocator, mw.tenantResolver(.{}), &ctx);
        try std.testing.expectEqualStrings("from-query", ctx.tenantId().?);
    }
}
