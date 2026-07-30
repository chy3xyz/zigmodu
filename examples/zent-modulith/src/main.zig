const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");
const zent_helpers = @import("zent_helpers");

const catalog_module = @import("modules/catalog/module.zig");
const catalog = @import("modules/catalog/root.zig");

// ═══════════════════════════════════════════════════
// ZigModu Application + zent (ent-style) data layer
// See docs/ZENT.md · ComptimeRouter: docs/ROUTE_TABLE.md
//
// Run (requires sibling checkout of chy3xyz/zent):
//   cd examples/zent-modulith && HTTP_PORT=18100 zig build run
// ═══════════════════════════════════════════════════

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("zent-modulith: ZigModu + zent demo starting (ComptimeRouter)", .{});

    // --- zent: open SQLite + migrate schema-as-code ---
    const sqlite_path = init.environ_map.get("ZENT_SQLITE") orelse ":memory:";
    var env = try zent_helpers.StoreEnv(zent.sql_sqlite.SQLiteDriver, catalog.persistence.infos).open(allocator, sqlite_path);
    defer env.deinit();
    std.log.info("[zent] migrated schema at {s}", .{sqlite_path});

    var store = catalog.persistence.CatalogStore.init(allocator, env.client);
    var catalog_svc = catalog.service.CatalogService.init(&store);
    const CatalogApiT = catalog.api.CatalogApi(@TypeOf(catalog_svc));
    var catalog_api = CatalogApiT.init(&catalog_svc);

    // --- ZigModu modules ---
    var modules = try zigmodu.scanModules(allocator, .{catalog_module});
    defer modules.deinit();
    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    const port: u16 = blk: {
        if (init.environ_map.get("HTTP_PORT")) |p| {
            break :blk std.fmt.parseInt(u16, p, 10) catch 18100;
        }
        break :blk 18100;
    };

    var server = zigmodu.http.Server.init(io, allocator, port);
    defer server.deinit();

    var catalog_slot: zigmodu.http.CatalogSlot = .{};
    defer catalog_slot.deinit();
    try server.addMiddleware(zigmodu.http.moduleGate(&catalog_slot, .{ .unknown = .allow }));

    comptime zigmodu.http.assertNoDupes(.{CatalogApiT});

    const AppState = struct {};
    var app_state: AppState = .{};
    var router = zigmodu.http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();
    router.default_auth = .public;

    var api_v1 = router.scope("/api/v1");
    try api_v1.mountAll(.{
        .{ .Mod = CatalogApiT, .state = &catalog_api },
    });
    catalog_slot.set(try router.finish());

    try server.addRoute(.{
        .method = .GET,
        .path = "openapi.json",
        .handler = zigmodu.http.openApiFromCatalog(&catalog_slot, .{
            .title = "zent-modulith",
            .version = "0.1.0",
            .description = "ComptimeRouter + zent catalog",
        }),
    });

    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"status\":\"UP\",\"data\":\"zent\"}");
            }
        }.handle,
    });

    std.log.info("[main] route catalog: {d} entries", .{catalog_slot.get().?.entries.len});
    std.log.info("[main] listening http://127.0.0.1:{d}", .{port});
    std.log.info("[main] POST /api/v1/tenants?name=&domain=", .{});
    std.log.info("[main] POST /api/v1/products?tenant_id=&name=&price_cents=", .{});
    std.log.info("[main] OpenAPI: http://127.0.0.1:{d}/openapi.json", .{port});
    try server.start();
}
