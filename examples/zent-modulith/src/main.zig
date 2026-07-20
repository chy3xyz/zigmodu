const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");

const catalog_module = @import("modules/catalog/module.zig");
const catalog = @import("modules/catalog/root.zig");

// ═══════════════════════════════════════════════════
// ZigModu Application + zent (ent-style) data layer
// See docs/ZENT.md
//
// Run (requires sibling checkout of chy3xyz/zent):
//   cd examples/zent-modulith && HTTP_PORT=18100 zig build run
// ═══════════════════════════════════════════════════

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("zent-modulith: ZigModu + zent demo starting", .{});

    // --- zent: open SQLite + migrate schema-as-code ---
    const sqlite_path = init.environ_map.get("ZENT_SQLITE") orelse ":memory:";
    var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, sqlite_path);
    defer drv.close();
    try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), catalog.persistence.infos);
    std.log.info("[zent] migrated schema at {s}", .{sqlite_path});

    var store = catalog.persistence.CatalogStore.init(allocator, drv.asDriver());
    var catalog_svc = catalog.service.CatalogService.init(&store);
    var catalog_api = catalog.api.CatalogApi(@TypeOf(catalog_svc)).init(&catalog_svc);

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

    var v1 = server.group("/api/v1");
    try catalog_api.registerRoutes(&v1);

    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"status\":\"UP\",\"data\":\"zent\"}");
            }
        }.handle,
    });

    std.log.info("[main] listening http://127.0.0.1:{d}", .{port});
    std.log.info("[main] POST /api/v1/tenants?name=&domain=", .{});
    std.log.info("[main] POST /api/v1/products?tenant_id=&name=&price_cents=", .{});
    try server.start();
}
