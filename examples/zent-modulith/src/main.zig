const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");
const zent_helpers = @import("zent_helpers");
const zent_crud = @import("zent_crud.zig");
const outbox_demo = @import("outbox_demo.zig");
const data_scope_demo = @import("data_scope_demo.zig");
const features_demo = @import("features_demo.zig");
const tx_demo = @import("tx_demo.zig");

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
    // (real deployments switch to .attr with the JWT middleware). The client
    // carries a privacy context so AuditMixin auto-fills created_by/updated_by.
    const ProductCrud = zent.crud.CrudService(catalog.persistence.infos, catalog.persistence.ProductInfo, "tenant_id");
    var product_crud = ProductCrud.init(allocator, store.client.product.withContext(.{ .user_id = 1 }));
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

    // Commerce + social demos: Inventory (atomic stock decrement) and a
    // two-level feed (Author -> posts -> comments).
    const alice_id = id: {
        var b = try env.client.author.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", "alice");
        var row = try b.Save();
        defer zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.AuthorInfo, &row, allocator);
        break :id row.id;
    };
    const post_a = id: {
        var b = try env.client.post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("author_id", alice_id);
        _ = try b.setFieldValue("title", "hello-zent");
        var row = try b.Save();
        defer zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.PostInfo, &row, allocator);
        break :id row.id;
    };
    const post_b = id: {
        var b = try env.client.post.Create();
        defer b.deinit();
        _ = try b.setFieldValue("author_id", alice_id);
        _ = try b.setFieldValue("title", "nested-edges");
        var row = try b.Save();
        defer zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.PostInfo, &row, allocator);
        break :id row.id;
    };
    // Comments carry explicit created_at values so the keyset-cursor demo has
    // same-second ties, and one hidden "spam" comment so the eager edge
    // filter (WhereRaw hidden=false) is observable.
    inline for (.{ .{ post_a, "nice post", 100, false }, .{ post_a, "thanks", 100, false }, .{ post_b, "cool", 200, false } }) |seed| {
        var b = try env.client.comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", seed[0]);
        _ = try b.setFieldValue("body", seed[1]);
        _ = try b.setFieldValue("created_at", @as(i64, seed[2]));
        _ = try b.setFieldValue("hidden", @as(bool, seed[3]));
        var row = try b.Save();
        zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.CommentInfo, &row, allocator);
    }
    // Third visible comment on post_a so the edge Limit(2) is observable
    // (newest two visible only)…
    {
        var b = try env.client.comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", post_a);
        _ = try b.setFieldValue("body", "third");
        _ = try b.setFieldValue("created_at", @as(i64, 300));
        _ = try b.setFieldValue("hidden", @as(bool, false));
        var row = try b.Save();
        zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.CommentInfo, &row, allocator);
    }
    // …and a hidden "spam" comment that must never be eager-loaded.
    {
        var b = try env.client.comment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("post_id", post_a);
        _ = try b.setFieldValue("body", "spam");
        _ = try b.setFieldValue("created_at", @as(i64, 400));
        _ = try b.setFieldValue("hidden", @as(bool, true));
        var row = try b.Save();
        zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.CommentInfo, &row, allocator);
    }
    {
        var b = try env.client.inventory.Create();
        defer b.deinit();
        _ = try b.setFieldValue("product_id", @as(i64, 1));
        _ = try b.setFieldValue("stock", @as(i64, 100));
        var row = try b.Save();
        zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.InventoryInfo, &row, allocator);
    }
    // Distributed-id demo: account with a time-ordered uuidv7 primary key and
    // a Sensitive api_key (never serialized raw).
    {
        var uuid_buf: [36]u8 = undefined;
        const ts = std.Io.Timestamp.now(init.io, .real);
        const now_ms: i64 = @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
        const id_str = zent.core.id.format(zent.core.id.uuidv7(now_ms), &uuid_buf);
        var b = try env.client.account.Create();
        defer b.deinit();
        _ = try b.setFieldValue("id", id_str);
        _ = try b.setFieldValue("name", "alice-api");
        _ = try b.setFieldValue("api_key", "sk-live-secret-123");
        var row = try b.Save();
        zent.codegen.deinitEntity(catalog.persistence.infos, catalog.persistence.AccountInfo, &row, allocator);
        std.log.info("[seed] account id={s} (api_key masked on read)", .{id_str});
    }

    const InventoryApiT = features_demo.InventoryApi(@TypeOf(env.client));
    var inventory_api = InventoryApiT.init(&env.client);
    const FeedApiT = features_demo.FeedApi(@TypeOf(env.client));
    var feed_api = FeedApiT.init(&env.client);
    const SummaryApiT = features_demo.SummaryApi(@TypeOf(env.client));
    var summary_api = SummaryApiT.init(&env.client);
    const BatchApiT = features_demo.BatchApi(@TypeOf(product_crud));
    var batch_api = BatchApiT.init(&product_crud);
    const UpsertApiT = features_demo.UpsertApi(@TypeOf(env.client));
    var upsert_api = UpsertApiT.init(&env.client);
    const FeedModernApiT = features_demo.FeedModernApi(@TypeOf(env.client));
    var feed_modern_api = FeedModernApiT.init(&env.client);
    const OrderApiT = tx_demo.OrderApi(@TypeOf(env.client));
    var order_api = OrderApiT.init(&env.client);
    const AccountApiT = tx_demo.AccountApi(@TypeOf(env.client));
    var account_api = AccountApiT.init(&env.client, io);

    // Interceptor demo (zent v0.33): a DEDICATED client over the same driver
    // whose interceptor carries a fixed sentinel tenant — omitted tenant_id
    // is filled on create, queries are transparently scoped. The shared
    // client above keeps explicit-tenant semantics for the other routes.
    var injection_client = zent.codegen.client.makeClient(catalog.persistence.infos, allocator, env.driver());
    const injection_tenant: i64 = features_demo.InterceptorApi(@TypeOf(injection_client)).sentinel_tenant;
    try zent.codegen.client.UseInterceptor(
        catalog.persistence.infos,
        &injection_client,
        features_demo.InterceptorApi(@TypeOf(injection_client)).interceptor(&injection_tenant),
    );
    const InterceptorApiT = features_demo.InterceptorApi(@TypeOf(injection_client));
    var interceptor_api = InterceptorApiT.init(&injection_client);

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

    comptime zigmodu.http.assertNoDupes(.{ CatalogApiT, ProductApiT, OutboxApiT, DocApiT, InventoryApiT, FeedApiT, SummaryApiT, BatchApiT, UpsertApiT, FeedModernApiT, OrderApiT, AccountApiT });

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
        .{ .Mod = InventoryApiT, .state = &inventory_api },
        .{ .Mod = FeedApiT, .state = &feed_api },
        .{ .Mod = SummaryApiT, .state = &summary_api },
        .{ .Mod = BatchApiT, .state = &batch_api },
        .{ .Mod = UpsertApiT, .state = &upsert_api },
        .{ .Mod = FeedModernApiT, .state = &feed_modern_api },
        .{ .Mod = OrderApiT, .state = &order_api },
        .{ .Mod = AccountApiT, .state = &account_api },
        .{ .Mod = InterceptorApiT, .state = &interceptor_api },
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
    std.log.info("[main] POST /api/v1/inventory/decrement?product_id=1&qty= (atomic stock, oversell-safe)", .{});
    std.log.info("[main] GET  /api/v1/feed/authors (two-level WithEdge posts.comments)", .{});
    std.log.info("[main] GET  /api/v1/feed/comments?cursor_ts=&cursor_id=&page_size=&desc= (composite keyset)", .{});
    std.log.info("[main] POST /api/v1/feed/bulk-delete (body {{\"ids\":[...]}}) (bulk soft delete)", .{});
    std.log.info("[main] POST /api/v1/orders?product_id=1&qty= (tx: order + savepoint stock + afterCommit events)", .{});
    std.log.info("[main] GET  /api/v1/orders/<id>", .{});
    std.log.info("[main] POST /api/v1/accounts?name=&api_key= (uuidv7 id)", .{});
    std.log.info("[main] GET  /api/v1/accounts/<uuid> (toMaskedJson)", .{});
    std.log.info("[main] GET  /api/v1/events (SSE)", .{});
    std.log.info("[main] PUT  /api/v1/sku-stock (v0.30 SaveOrUpdateOn upsert + v0.31 field.Decimal)", .{});
    std.log.info("[main] GET  /api/v1/feed2/authors-with-posts (v0.31 WithEdgeOptions inner join, arena copies)", .{});
    std.log.info("[main] OpenAPI: http://127.0.0.1:{d}/openapi.json", .{port});
    try server.start();
}
