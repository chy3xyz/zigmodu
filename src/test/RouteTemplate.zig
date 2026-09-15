//! `ctx.route_template` coverage.
//!
//! Metrics labels must use `route_template`, never `path` — `path` carries ids
//! and blows up Prometheus cardinality. That contract is only useful if *every*
//! registration path fills the field, so this file pins both of them:
//! `RouteGroup.get/post` (the common case) and a direct `Server.addRoute`
//! (how infra endpoints such as `/metrics` are registered).
//!
//! A `route_template == null` read means the route matched nothing — e.g. a
//! method or trailing-slash mismatch — and the label degrades to a single
//! bucket. These tests distinguish the two.

const std = @import("std");
const api = @import("../api/Server.zig");
const cr = @import("../api/ComptimeRouter.zig");
const Testkit = @import("../http/Testkit.zig");

const Capture = struct {
    var template: ?[]const u8 = null;
    var path: []const u8 = "";
    /// Owned copy: the Context arena dies with the request.
    var template_owned: ?[]const u8 = null;

    fn reset(allocator: std.mem.Allocator) void {
        if (template_owned) |t| allocator.free(t);
        template = null;
        template_owned = null;
        path = "";
    }

    fn record(allocator: std.mem.Allocator, ctx: *api.Context) void {
        template = ctx.route_template;
        path = ctx.path;
        template_owned = if (ctx.route_template) |t| allocator.dupe(u8, t) catch null else null;
        template = template_owned;
    }

    fn handler(ctx: *api.Context) anyerror!void {
        record(ctx.allocator, ctx);
        try ctx.json(200, "{}");
    }
};

test "route_template is filled for RouteGroup-registered routes" {
    const allocator = std.testing.allocator;
    defer Capture.reset(allocator);

    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var group = server.group("");
    try group.get("orders/{id}", Capture.handler, null);

    var resp = try Testkit.dispatch(&server, .GET, "/orders/42", null);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("/orders/{id}", Capture.template.?);
    // The id is in `path` — exactly why the label must come from the template.
    try std.testing.expectEqualStrings("/orders/42", Capture.path);
}

test "route_template is filled for Server.addRoute (the /metrics shape)" {
    const allocator = std.testing.allocator;
    defer Capture.reset(allocator);

    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    // `PrometheusMetrics.registerMetricsRoutePath` takes exactly this path:
    // a direct addRoute, not a RouteGroup.
    try server.addRoute(.{ .method = .GET, .path = "/metrics", .handler = Capture.handler });

    var resp = try Testkit.dispatch(&server, .GET, "/metrics", null);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("/metrics", Capture.template.?);
}

test "route_template is filled for ComptimeRouter catalog routes" {
    const allocator = std.testing.allocator;
    defer Capture.reset(allocator);

    const AppState = struct {};
    const Api = struct {
        pub const module_name = "catalog";
        pub const nest = .{};
        pub const State = @This();
        pub const routes = [_]cr.RouteSpec(State){
            .{ .method = .GET, .path = "{id}", .handler = hit, .meta = .{ .auth = .public } },
        };
        fn hit(ctx: *api.Context, _: *State) !void {
            Capture.record(ctx.allocator, ctx);
            try ctx.json(200, "{}");
        }
    };

    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var app_state: AppState = .{};
    var api_state: Api = .{};
    var router = cr.Router(AppState).init(std.testing.io, allocator, &server, &app_state);
    defer router.deinit();
    var root = router.scope("products");
    try root.mountAll(.{.{ .Mod = Api, .state = &api_state }});
    var slot: cr.CatalogSlot = .{};
    defer slot.deinit();
    slot.set(try router.finish());

    var resp = try Testkit.dispatch(&server, .GET, "/products/7", null);
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqualStrings("/products/{id}", Capture.template.?);
}

test "route_template is null only when nothing matched" {
    const allocator = std.testing.allocator;
    defer Capture.reset(allocator);

    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var group = server.group("");
    try group.get("known", Capture.handler, null);

    // Method mismatch: the handler never runs, so the label reads "no match".
    // This is the case a metrics middleware sees as `route_template == null`.
    var resp = try Testkit.dispatch(&server, .POST, "/known", null);
    defer resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
    try std.testing.expect(Capture.template == null);
}
