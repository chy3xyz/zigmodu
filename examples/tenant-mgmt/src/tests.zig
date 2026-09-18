//! Example tests — the module graph and the routed catalog that `main.zig`
//! wires, asserted without starting an HTTP server.
//!
//! Run with: `zig build test`

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

const tenant_module = @import("modules/tenant/module.zig");
const user_module = @import("modules/user/module.zig");
const subscription_module = @import("modules/subscription/module.zig");

const tenant_mod = @import("modules/tenant/root.zig");
const user_mod = @import("modules/user/root.zig");
const subscription_mod = @import("modules/subscription/root.zig");
const db_backend = @import("db/backend.zig");
const schema = @import("db/schema.zig");

test "module graph: three modules scan, validate and run their lifecycle" {
    const allocator = std.testing.allocator;

    var modules = try zigmodu.scanModules(allocator, .{ tenant_module, user_module, subscription_module });
    defer modules.deinit();

    try std.testing.expectEqual(@as(usize, 3), modules.modules.count());
    try zigmodu.validateModules(&modules);

    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);
}

test "route catalog: /api/v1 resources map to their module and RBAC meta" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try http.Testkit.openMemorySqlite(allocator, io);
    defer client.deinit();
    try schema.apply(&client);

    // Same chain as main.zig — the handlers are never invoked here, only mounted.
    const Backend = db_backend.Backend;
    const tenant_persist = tenant_mod.persistence.TenantPersistence(Backend).init(allocator, &client);
    const user_persist = user_mod.persistence.UserPersistence(Backend).init(&client);
    const sub_persist = subscription_mod.persistence.SubscriptionPersistence(Backend).init(&client);

    var tenant_svc = tenant_mod.service.TenantService(@TypeOf(tenant_persist)).init(allocator, tenant_persist);
    var user_svc = user_mod.service.UserService(@TypeOf(user_persist)).init(user_persist);
    var sub_svc = subscription_mod.service.SubscriptionService(@TypeOf(sub_persist)).init(sub_persist);

    var tenant_api = tenant_mod.api.TenantApi(@TypeOf(tenant_svc)).init(&tenant_svc);
    var user_api = user_mod.api.UserApi(@TypeOf(user_svc)).init(&user_svc);
    var sub_api = subscription_mod.api.SubscriptionApi(@TypeOf(sub_svc)).init(&sub_svc);

    var server = http.Server.init(io, allocator, 0);
    defer server.deinit();

    const AppState = struct {};
    var app_state: AppState = .{};
    comptime http.assertNoDupes(.{ @TypeOf(tenant_api), @TypeOf(user_api), @TypeOf(sub_api) });

    var catalog_slot: http.CatalogSlot = .{};
    defer catalog_slot.deinit();

    var router = http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();

    var api_v1 = router.scope("/api/v1");
    try api_v1.mountAll(.{
        .{ .Mod = @TypeOf(tenant_api), .state = &tenant_api },
        .{ .Mod = @TypeOf(user_api), .state = &user_api },
        .{ .Mod = @TypeOf(sub_api), .state = &sub_api },
    });
    catalog_slot.set(try router.finish());

    const catalog = catalog_slot.get().?;
    try std.testing.expectEqualStrings("tenant", catalog.moduleFor("/api/v1/tenants").?);
    try std.testing.expectEqualStrings("user", catalog.moduleFor("/api/v1/users").?);
    try std.testing.expectEqualStrings("subscription", catalog.moduleFor("/api/v1/plans").?);

    // Nothing here is anonymous: the JWT middleware chain decided that, not a per-route flag.
    try std.testing.expect(!catalog.isPublic(.GET, "/api/v1/tenants"));

    // The one route that carries a fine-grained gate, resolved through the `{id}` placeholder.
    const suspend_route = catalog.findEntry(.DELETE, "/api/v1/tenants/42").?;
    try std.testing.expectEqualStrings("tenant", suspend_route.module);
    try std.testing.expectEqualStrings("tenant:suspend", suspend_route.permission.?);
}
