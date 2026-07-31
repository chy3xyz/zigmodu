const std = @import("std");
const zigmodu = @import("zigmodu");

// ═══════════════════════════════════════════════════
// Multi-Tenant Shop (Modulith scaffold)
// See docs/MODULITH_TENANT_SHOP.md
//
// Week 1–2: tenant + user + product + inventory
// Week 3:   cart + order checkout (reserve + outbox)
// Week 4:   payment (idempotent) + shop_bff orchestration
// Week 4b:  outbox poller → RobustMQ (offline if unset)
//
// Run:
//   cd examples/tenant-shop && HTTP_PORT=18090 zig build run
// Optional:
//   ROBUSTMQ_URL=127.0.0.1:9092  # online produce
//   OUTBOX_POLL_MS=500           # background poll (file SQLite)
// ═══════════════════════════════════════════════════

const tenant_module = @import("modules/tenant/module.zig");
const user_module = @import("modules/user/module.zig");
const product_module = @import("modules/product/module.zig");
const inventory_module = @import("modules/inventory/module.zig");
const cart_module = @import("modules/cart/module.zig");
const order_module = @import("modules/order/module.zig");
const payment_module = @import("modules/payment/module.zig");
const shop_bff_module = @import("modules/shop_bff/module.zig");
const admin_bff_module = @import("modules/admin_bff/module.zig");

const tenant_mod = @import("modules/tenant/root.zig");
const user_mod = @import("modules/user/root.zig");
const product_mod = @import("modules/product/root.zig");
const inventory_mod = @import("modules/inventory/root.zig");
const cart_mod = @import("modules/cart/root.zig");
const order_mod = @import("modules/order/root.zig");
const payment_mod = @import("modules/payment/root.zig");
const shop_bff_mod = @import("modules/shop_bff/root.zig");
const admin_bff_mod = @import("modules/admin_bff/root.zig");

const middleware = @import("middleware/root.zig");
const db_backend = @import("db/backend.zig");
const schema = @import("db/schema.zig");
const mq = @import("foundation/mq.zig");
const outbox = @import("foundation/outbox.zig");
const outbox_api = @import("foundation/outbox_api.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("tenant-shop modulith scaffold starting", .{});

    const sqlite_path = init.environ_map.get("TENANT_SHOP_SQLITE") orelse ":memory:";
    const is_memory = std.mem.eql(u8, sqlite_path, ":memory:");
    var db_client = zigmodu.data.Client.init(allocator, io, .{
        .driver = .sqlite,
        .sqlite_path = sqlite_path,
        // :memory: must be single-conn; file DB can pool for outbox fiber.
        .max_open_conns = if (is_memory) 1 else 4,
        .max_idle_conns = if (is_memory) 1 else 2,
    });
    defer db_client.deinit();
    try db_client.connect();
    try schema.apply(&db_client);
    std.log.info("[main] SQLite ready at {s}", .{sqlite_path});

    var modules = try zigmodu.scanModules(allocator, .{
        tenant_module,
        user_module,
        product_module,
        inventory_module,
        cart_module,
        order_module,
        payment_module,
        shop_bff_module,
        admin_bff_module,
    });
    defer modules.deinit();

    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);
    std.log.info("[main] 9 modules validated and started", .{});

    const bootstrap = init.environ_map.get("ROBUSTMQ_URL") orelse init.environ_map.get("KAFKA_BOOTSTRAP");
    var mq_pub = mq.Publisher.init(allocator, io, bootstrap);
    defer mq_pub.deinit();

    const poll_ms: u64 = blk: {
        if (init.environ_map.get("OUTBOX_POLL_MS")) |p| {
            break :blk std.fmt.parseInt(u64, p, 10) catch 1000;
        }
        break :blk 1000;
    };
    var outbox_poller = outbox.Poller.init(allocator, io, &db_client, &mq_pub, 50, poll_ms);

    const Backend = db_backend.Backend;
    const tenant_persist = tenant_mod.persistence.TenantPersistence(Backend).init(allocator, &db_client);
    const user_persist = user_mod.persistence.UserPersistence(Backend).init(&db_client);
    const product_persist = product_mod.persistence.ProductPersistence(Backend).init(&db_client);
    const inventory_persist = inventory_mod.persistence.InventoryPersistence(Backend).init(&db_client);
    const cart_persist = cart_mod.persistence.CartPersistence(Backend).init(&db_client);

    var tenant_svc = tenant_mod.service.TenantService(@TypeOf(tenant_persist)).init(allocator, tenant_persist);
    var user_svc = user_mod.service.UserService(@TypeOf(user_persist)).init(user_persist);
    var product_svc = product_mod.service.ProductService(@TypeOf(product_persist)).init(product_persist);
    var inventory_svc = inventory_mod.service.InventoryService(@TypeOf(inventory_persist)).init(inventory_persist);
    var cart_svc = cart_mod.service.CartService(@TypeOf(cart_persist)).init(cart_persist);
    var order_svc = order_mod.service.OrderService.init(allocator, &db_client);
    var payment_svc = payment_mod.service.PaymentService.init(allocator, &db_client);

    var tenant_api = tenant_mod.api.TenantApi(@TypeOf(tenant_svc)).init(&tenant_svc);
    var user_api = user_mod.api.UserApi(@TypeOf(user_svc)).init(&user_svc);
    var product_api = product_mod.api.ProductApi(@TypeOf(product_svc)).init(&product_svc);
    var inventory_api = inventory_mod.api.InventoryApi(@TypeOf(inventory_svc)).init(&inventory_svc);
    var cart_api = cart_mod.api.CartApi(@TypeOf(cart_svc)).init(&cart_svc);
    var order_api = order_mod.api.OrderApi(@TypeOf(order_svc)).init(&order_svc);
    var payment_api = payment_mod.api.PaymentApi(@TypeOf(payment_svc)).init(&payment_svc);
    var shop_bff_api = shop_bff_mod.api.ShopBffApi(@TypeOf(order_svc), @TypeOf(payment_svc)).init(&order_svc, &payment_svc);
    var outbox_http = outbox_api.OutboxApi(@TypeOf(outbox_poller)).init(&outbox_poller);
    var admin_bff_api = admin_bff_mod.api.AdminBffApi(
        @TypeOf(product_svc),
        @TypeOf(inventory_svc),
        @TypeOf(order_svc),
        @TypeOf(outbox_poller),
    ).init(&product_svc, &inventory_svc, &order_svc, &outbox_poller);

    const port: u16 = blk: {
        if (init.environ_map.get("HTTP_PORT")) |p| {
            break :blk std.fmt.parseInt(u16, p, 10) catch 18090;
        }
        break :blk 18090;
    };

    var server = zigmodu.http.Server.init(io, allocator, port);
    defer server.deinit();

    const jwt_secret = init.environ_map.get("JWT_SECRET") orelse "dev-secret";
    var app_sec = zigmodu.security.AppSecurity.init(allocator, io, .{ .jwt_secret = jwt_secret });
    var catalog_slot: zigmodu.http.CatalogSlot = .{};
    defer catalog_slot.deinit();

    try server.addMiddleware(middleware.tenantMiddleware());
    try server.addMiddleware(middleware.jwtAuthMiddleware(&app_sec.module, &catalog_slot));
    try server.addMiddleware(middleware.moduleGateMiddleware(&catalog_slot));
    try server.addMiddleware(middleware.dataPermissionMiddleware());

    // ComptimeRouter — all modules via mountAll (smoke-friendly: default_auth = .public)
    const AppState = struct {};
    var app_state: AppState = .{};
    const TenantApiT = @TypeOf(tenant_api);
    const UserApiT = @TypeOf(user_api);
    const ProductApiT = @TypeOf(product_api);
    const InventoryApiT = @TypeOf(inventory_api);
    const CartApiT = @TypeOf(cart_api);
    const OrderApiT = @TypeOf(order_api);
    const PaymentApiT = @TypeOf(payment_api);
    const ShopBffApiT = @TypeOf(shop_bff_api);
    const OutboxApiT = @TypeOf(outbox_http);
    const AdminBffApiT = @TypeOf(admin_bff_api);
    comptime zigmodu.http.assertNoDupes(.{
        TenantApiT, UserApiT,    ProductApiT, InventoryApiT, CartApiT,
        OrderApiT,  PaymentApiT, ShopBffApiT, OutboxApiT,    AdminBffApiT,
    });

    var router = zigmodu.http.Router(AppState).init(io, allocator, &server, &app_state);
    defer router.deinit();
    router.default_auth = .public;

    var api_v1 = router.scope("/api/v1");
    try api_v1.mountAll(.{
        .{ .Mod = TenantApiT, .state = &tenant_api },
        .{ .Mod = UserApiT, .state = &user_api },
        .{ .Mod = ProductApiT, .state = &product_api },
        .{ .Mod = InventoryApiT, .state = &inventory_api },
        .{ .Mod = CartApiT, .state = &cart_api },
        .{ .Mod = OrderApiT, .state = &order_api },
        .{ .Mod = PaymentApiT, .state = &payment_api },
        .{ .Mod = ShopBffApiT, .state = &shop_bff_api },
        .{ .Mod = OutboxApiT, .state = &outbox_http },
        .{ .Mod = AdminBffApiT, .state = &admin_bff_api },
    });
    catalog_slot.set(try router.finish());
    std.log.info("[main] route catalog: {d} entries", .{catalog_slot.get().?.entries.len});

    try server.addRoute(.{
        .method = .GET,
        .path = "openapi.json",
        .handler = zigmodu.http.openApiFromCatalog(&catalog_slot, .{
            .title = "tenant-shop",
            .version = "0.1.0",
            .description = "ComptimeRouter catalog (live)",
        }),
    });

    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"status\":\"UP\"}");
            }
        }.handle,
    });

    // Background outbox fiber when using file SQLite (pool-safe).
    // :memory: uses POST /api/v1/outbox/drain from the request fiber instead.
    var bg_group: std.Io.Group = .init;
    defer {
        outbox_poller.stop();
        bg_group.await(io) catch |err| std.log.warn("[main] bg_group await: {}", .{err});
    }
    if (!is_memory) {
        bg_group.async(io, outbox.Poller.runLoop, .{&outbox_poller});
        std.log.info("[main] outbox background poller every {d}ms", .{poll_ms});
    } else {
        std.log.info("[main] :memory: — use POST /api/v1/outbox/drain to publish", .{});
    }

    std.log.info("[main] listening http://0.0.0.0:{d}", .{port});
    std.log.info("[main] health  http://127.0.0.1:{d}/health/live", .{port});
    std.log.info("[main] outbox  http://127.0.0.1:{d}/api/v1/outbox", .{port});
    try server.start();
}
