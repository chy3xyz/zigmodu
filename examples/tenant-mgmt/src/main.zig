const std = @import("std");
const zigmodu = @import("zigmodu");

// ═══════════════════════════════════════════════════
// Multi-Tenant Management System
// ZigModu v0.13.15 Best Practice Demo
//
// Architecture:
//   HTTP → Middleware (JWT/Tenant/DataPermission) → API (Tenant/User/Subscription) → Service → Persistence → DB
//
// Run:
//   cd examples/tenant-mgmt && zig build run
//
// API Endpoints:
//   GET  /api/v1/tenants              → List all tenants
//   POST /api/v1/tenants              → Create tenant (name, domain, tier)
//   GET  /api/v1/tenants/{id}         → Get tenant detail
//   PUT  /api/v1/tenants/{id}/tier    → Update tenant tier
//   DEL  /api/v1/tenants/{id}         → Suspend tenant
//   GET  /api/v1/users?tenant_id=X    → List users in tenant
//   POST /api/v1/users                → Create user in tenant
//   GET  /api/v1/users/{id}?tenant_id=X → Get user (isolated)
//   GET  /api/v1/plans                → List available plans
//   POST /api/v1/subscriptions        → Create subscription
//   GET  /api/v1/subscriptions/{id}   → Get tenant subscription
//   DEL  /api/v1/subscriptions/{id}   → Cancel subscription
//   GET  /health/live                 → Liveness probe
//   GET  /dashboard                   → HTMX dashboard
// ═══════════════════════════════════════════════════

// ── Module declarations (for scanModules) ──────────
const tenant_module = @import("modules/tenant/module.zig");
const user_module = @import("modules/user/module.zig");
const subscription_module = @import("modules/subscription/module.zig");

// ── Full module APIs (for persistence/service/api) ──
const tenant_mod = @import("modules/tenant/root.zig");
const user_mod = @import("modules/user/root.zig");
const subscription_mod = @import("modules/subscription/root.zig");
const middleware = @import("middleware/root.zig");
const db_backend = @import("db/backend.zig");
const schema = @import("db/schema.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("╔══════════════════════════════════════════╗", .{});
    std.log.info("║  Multi-Tenant Management System          ║", .{});
    std.log.info("║  ZigModu — Best Practice Demo (ComptimeRouter: 3 modules)   ║", .{});
    std.log.info("╚══════════════════════════════════════════╝", .{});

    const sqlite_path = init.environ_map.get("TENANT_MGMT_SQLITE") orelse ":memory:";
    var db_client = zigmodu.data.Client.init(allocator, io, .{
        .driver = .sqlite,
        .sqlite_path = sqlite_path,
    });
    defer db_client.deinit();
    try db_client.connect();
    try schema.apply(&db_client);
    try zigmodu.security.CatalogPermDb.ensureSchema(&db_client);
    try zigmodu.security.CatalogPermDb.grant(&db_client, "admin", zigmodu.security.Rbac.Permissions.tenant_read);
    try zigmodu.security.CatalogPermDb.grant(&db_client, "admin", zigmodu.security.Rbac.Permissions.tenant_write);
    try zigmodu.security.CatalogPermDb.grant(&db_client, "admin", zigmodu.security.Rbac.Permissions.tenant_suspend);
    try zigmodu.security.CatalogPermDb.grant(&db_client, "owner", zigmodu.security.Rbac.Permissions.tenant_read);
    try zigmodu.security.CatalogPermDb.grant(&db_client, "owner", zigmodu.security.Rbac.Permissions.tenant_write);
    try zigmodu.security.CatalogPermDb.grant(&db_client, "owner", zigmodu.security.Rbac.Permissions.tenant_suspend);
    try zigmodu.security.CatalogPermDb.grant(&db_client, "user", zigmodu.security.Rbac.Permissions.tenant_read);
    std.log.info("[main] SQLite ready at {s}", .{sqlite_path});

    // ── 1. Scan modules ────────────────────────────
    var modules = try zigmodu.scanModules(allocator, .{
        tenant_module,
        user_module,
        subscription_module,
    });
    defer modules.deinit();

    // ── 2. Validate dependencies ────────────────────
    try zigmodu.validateModules(&modules);
    std.log.info("[main] Module validation passed", .{});

    // ── 3. Start lifecycle ─────────────────────────
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);
    std.log.info("[main] All modules started", .{});

    // ── 4. Assemble dependency chain ────────────────
    // Persistence → Service → API → HTTP Server

    const Backend = db_backend.Backend;
    const tenant_persist = tenant_mod.persistence.TenantPersistence(Backend).init(allocator, &db_client);
    const user_persist = user_mod.persistence.UserPersistence(Backend).init(&db_client);
    const sub_persist = subscription_mod.persistence.SubscriptionPersistence(Backend).init(&db_client);

    // Service layer
    var tenant_svc = tenant_mod.service.TenantService(@TypeOf(tenant_persist)).init(allocator, tenant_persist);
    var user_svc = user_mod.service.UserService(@TypeOf(user_persist)).init(user_persist);
    var sub_svc = subscription_mod.service.SubscriptionService(@TypeOf(sub_persist)).init(sub_persist);

    // API layer
    var tenant_api = tenant_mod.api.TenantApi(@TypeOf(tenant_svc)).init(&tenant_svc);
    var user_api = user_mod.api.UserApi(@TypeOf(user_svc)).init(&user_svc);
    var sub_api = subscription_mod.api.SubscriptionApi(@TypeOf(sub_svc)).init(&sub_svc);

    // ── 5. HTTP Server ──────────────────────────────
    const port: u16 = blk: {
        if (init.environ_map.get("HTTP_PORT")) |p| {
            break :blk std.fmt.parseInt(u16, p, 10) catch 18080;
        }
        break :blk 18080;
    };

    var server = zigmodu.http.Server.init(io, allocator, port);
    defer server.deinit();

    // ── 6. Global Middleware (catalog slot filled after mount) ──
    const jwt_secret = init.environ_map.get("JWT_SECRET") orelse "dev-secret";
    var app_sec = zigmodu.security.AppSecurity.init(allocator, io, .{ .jwt_secret = jwt_secret });
    var catalog_slot: zigmodu.http.CatalogSlot = .{};
    defer catalog_slot.deinit();
    // Order: tenant → JWT(from catalog) → ModuleGate → data permission
    try server.addMiddleware(middleware.tenantMiddleware());
    try server.addMiddleware(middleware.jwtAuthMiddleware(&app_sec.module, &catalog_slot, &db_client));
    try server.addMiddleware(middleware.moduleGateMiddleware(&catalog_slot));
    try server.addMiddleware(middleware.permissionGateMiddleware(&catalog_slot));
    try server.addMiddleware(middleware.dataPermissionMiddleware());

    // ── 7. API Routes (v1) — all modules via ComptimeRouter ──
    const AppState = struct {};
    var app_state: AppState = .{};
    const TenantApiT = @TypeOf(tenant_api);
    const UserApiT = @TypeOf(user_api);
    const SubApiT = @TypeOf(sub_api);
    comptime zigmodu.http.assertNoDupes(.{ TenantApiT, UserApiT, SubApiT });

    var router = zigmodu.http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();

    var api_v1 = router.scope("/api/v1");
    try api_v1.mountAll(.{
        .{ .Mod = TenantApiT, .state = &tenant_api },
        .{ .Mod = UserApiT, .state = &user_api },
        .{ .Mod = SubApiT, .state = &sub_api },
    });

    catalog_slot.set(try router.finish());
    std.log.info("[main] route catalog: {d} entries; tenants={s} users={s} plans={s}", .{
        catalog_slot.get().?.entries.len,
        catalog_slot.get().?.moduleFor("/api/v1/tenants") orelse "?",
        catalog_slot.get().?.moduleFor("/api/v1/users") orelse "?",
        catalog_slot.get().?.moduleFor("/api/v1/plans") orelse "?",
    });

    // OpenAPI live from catalog (regenerates each request)
    try server.addRoute(.{
        .method = .GET,
        .path = "openapi.json",
        .handler = zigmodu.http.openApiFromCatalog(&catalog_slot, .{
            .title = "tenant-mgmt",
            .version = "0.1.0",
            .description = "ComptimeRouter catalog (live)",
        }),
    });

    // ── 8. Health endpoints ─────────────────────────
    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"status\":\"UP\"}");
            }
        }.handle,
    });

    // ── 9. Dashboard ────────────────────────────────
    zigmodu.http.Dashboard.system_info.module_count = 3;
    zigmodu.http.Dashboard.system_info.test_passed = 413;
    zigmodu.http.Dashboard.system_info.started_at = zigmodu.time.monotonicNowSeconds();
    // Dashboard routes
    try server.addRoute(.{ .method = .GET, .path = "dashboard", .handler = struct {
        fn handle(ctx: *zigmodu.http.Context) !void { try ctx.text(200, "Dashboard"); }
    }.handle });

    // ── 10. Start server ────────────────────────────
    std.log.info("[main] HTTP server listening on http://0.0.0.0:{d}", .{port});
    std.log.info("[main] Dashboard: http://localhost:{d}/dashboard", .{port});
    std.log.info("[main] API v1:    http://localhost:{d}/api/v1/tenants", .{port});
    std.log.info("[main] Health:    http://localhost:{d}/health/live", .{port});

    try server.start();
}
