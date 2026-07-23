const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");

const order_module = @import("modules/order/module.zig");
const order = @import("modules/order/root.zig");

// ═══════════════════════════════════════════════════
// ZigModu Application + zent (ent-style) data layer
// Parallel of `examples/shopdemo/`, but persistence is
// driven by zent (no sqlx, no Repository).
// See docs/ZENT.md for the orthogonality contract.
//
// Run (requires sibling checkout of chy3xyz/zent):
//   cd examples/shopdemo-zent && HTTP_PORT=18200 zig build run
// ═══════════════════════════════════════════════════

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("shopdemo-zent: ZigModu + zent parallel starting", .{});

    // --- zent: open SQLite + migrate schema-as-code ---
    const sqlite_path = init.environ_map.get("SHOPDEMO_ZENT_SQLITE") orelse ":memory:";
    var drv = try zent.sql_sqlite.SQLiteDriver.open(allocator, sqlite_path);
    defer drv.close();
    try zent.sql_schema.migrateSchema(allocator, drv.asDriver(), order.persistence.infos);
    std.log.info("[zent] migrated order schema at {s}", .{sqlite_path});

    var store = order.persistence.OrderStore.init(allocator, drv.asDriver());
    var order_svc = order.service.OrderService.init(&store);
    var order_api = order.api.OrderApi(@TypeOf(order_svc)).init(&order_svc);

    // --- ZigModu modules ---
    var modules = try zigmodu.scanModules(allocator, .{order_module});
    defer modules.deinit();
    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    const port: u16 = blk: {
        if (init.environ_map.get("HTTP_PORT")) |p| {
            break :blk std.fmt.parseInt(u16, p, 10) catch 18200;
        }
        break :blk 18200;
    };

    var server = zigmodu.http.Server.init(io, allocator, port);
    defer server.deinit();

    var v1 = server.group("/api/v1");
    try order_api.registerRoutes(&v1);

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
    std.log.info("[main] POST /api/v1/orders?order_no=&status=&amount_cents=&user_id=", .{});
    std.log.info("[main] GET  /api/v1/orders", .{});
    std.log.info("[main] GET  /api/v1/orders/{{order_no}}", .{});
    std.log.info("[main] POST /api/v1/orders/{{order_no}}/items?sku=&qty=&unit_price_cents=", .{});
    try server.start();
}
