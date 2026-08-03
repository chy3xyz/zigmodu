const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");
const zent_helpers = @import("zent_helpers");
const zent_crud = @import("zent_crud.zig");
const outbox_demo = @import("outbox_demo.zig");
const data_scope_demo = @import("data_scope_demo.zig");

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

    // Generic CRUD: one declaration = the five standard routes over the zent
    // CrudService. Tenant comes from the query string in this public demo
    // (real deployments switch to .attr with the JWT middleware).
    const ProductCrud = zent.crud.CrudService(catalog.persistence.infos, catalog.persistence.ProductInfo, "tenant_id");
    var product_crud = ProductCrud.init(allocator, store.client.product);
    const ProductApiT = zent_crud.CrudApi(catalog.persistence.infos, catalog.persistence.ProductInfo, .{
        .module_name = "catalog",
        .nest = &.{"products"},
        .tenant_col = "tenant_id",
        .tenant_source = .query,
    });
    var product_api = ProductApiT.init(&product_crud);

    // Data-scope demo: Doc carries zent.data_scope.Policy, so creates need a
    // context (seed with an .all scope; real requests get one from the
    // scope middleware).
    var seed_scope = zent.data_scope.DataScopeFilter.init("dept_id", "owner_id", .all, .{});
    const seed_doc = env.client.doc.withContext(seed_scope.context(.{ .tenant_id = 1 }));
    inline for (.{ .{ 1, 1, 3, "alice-notes" }, .{ 1, 1, 3, "alice-roi" }, .{ 1, 2, 9, "bob-report" } }) |seed| {
        var b = try seed_doc.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", @as(i64, seed[0]));
        _ = try b.setFieldValue("owner_id", @as(i64, seed[1]));
        _ = try b.setFieldValue("dept_id", @as(i64, seed[2]));
        _ = try b.setFieldValue("title", seed[3]);
        var row = try b.Save();
        zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.DocInfo, &row, allocator);
    }

    // Outbox demo: transactional enqueue + on-demand/cron dispatch.
    var outbox_dispatcher = outbox_demo.Dispatcher{
        .allocator = allocator,
        .client = &env.client,
        .io = io,
    };
    const OutboxApiT = outbox_demo.OutboxDemoApi();
    var outbox_api = OutboxApiT.init(&outbox_dispatcher);

    // Data-scope demo API (scope middleware fills attrs; handler queries
    // through the scoped zent client).
    const DocApiT = data_scope_demo.DocApi(@TypeOf(env.client));
    var doc_api = DocApiT.init(&env.client);

    // Outbox cron: dispatch pending events every minute. The background
    // thread uses its OWN connection (file-backed SQLite only), so it never
    // shares a driver with request fibers.
    var cron_driver: ?zent.sql_sqlite.SQLiteDriver = null;
    var cron_client: ?catalog.persistence.Client = null;
    if (std.mem.eql(u8, sqlite_path, ":memory:")) {
        std.log.warn("[cron] in-memory DB: outbox cron disabled (set ZENT_SQLITE=/path/db.sqlite to enable)", .{});
    } else {
        cron_driver = try zent.sql_sqlite.SQLiteDriver.open(allocator, sqlite_path);
        cron_client = zent.codegen.client.makeClient(catalog.persistence.infos, allocator, cron_driver.?.asDriver());
    }
    const CronCtx = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        client: ?*catalog.persistence.Client,
    };
    var cron_ctx = CronCtx{
        .allocator = allocator,
        .io = io,
        .client = if (cron_client) |*c| c else null,
    };
    var cron = zigmodu.cron.Scheduler.init(allocator, io);
    defer cron.deinit();
    try cron.addJob("outbox-dispatch", try zigmodu.cron.Expression.parse("* * * * *"), struct {
        fn run(ctx: ?*anyopaque) void {
            const c: *CronCtx = @ptrCast(@alignCast(ctx.?));
            if (c.client) |cl| {
                var disp = outbox_demo.Dispatcher{ .allocator = c.allocator, .client = cl, .io = c.io };
                _ = disp.dispatchOnce() catch |err| std.log.err("[cron] outbox dispatch failed: {s}", .{@errorName(err)});
            }
        }
    }.run, &cron_ctx);
    try cron.start();

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

    var profile_state = zigmodu.http.HttpProfileState.init(allocator);
    defer profile_state.deinit(allocator);
    try zigmodu.http.applyHttpDefaults(&server, .{
        .security_basics = true,
        .access_log = false, // quieter for local demo
        .metrics = false,
    }, &profile_state);

    var catalog_slot: zigmodu.http.CatalogSlot = .{};
    defer catalog_slot.deinit();
    try server.addMiddleware(zigmodu.http.moduleGate(&catalog_slot, .{ .unknown = .allow }));

    comptime zigmodu.http.assertNoDupes(.{ CatalogApiT, ProductApiT, OutboxApiT, DocApiT });

    const AppState = struct {};
    var app_state: AppState = .{};
    var router = zigmodu.http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();
    router.default_auth = .public;

    var api_v1 = router.scope("/api/v1");
    try api_v1.mountAll(.{
        .{ .Mod = CatalogApiT, .state = &catalog_api },
        .{ .Mod = ProductApiT, .state = &product_api },
        .{ .Mod = OutboxApiT, .state = &outbox_api },
    });
    var docs_scope = try api_v1.use(.{ .func = data_scope_demo.scopeMiddleware });
    try docs_scope.mount(DocApiT, &doc_api);
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
    std.log.info("[main] CrudApi: GET/POST /api/v1/products?tenant_id= (paged list / create)", .{});
    std.log.info("[main] CrudApi: GET/PUT/DELETE /api/v1/products/<id>?tenant_id=", .{});
    std.log.info("[main] POST /api/v1/outbox/enqueue?aggregate_type=&aggregate_id=&event_type=&payload=", .{});
    std.log.info("[main] POST /api/v1/outbox/dispatch (manual; cron every minute when file-backed)", .{});
    std.log.info("[main] GET  /api/v1/docs?user_id=&tenant_id=&scope=self_|dept_only|dept_custom&dept_ids=", .{});
    std.log.info("[main] GET  /api/v1/events (SSE)", .{});
    std.log.info("[main] OpenAPI: http://127.0.0.1:{d}/openapi.json", .{port});
    try server.start();
}
