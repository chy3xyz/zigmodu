const std = @import("std");
const zigmodu = @import("zigmodu");

const order_module = @import("modules/order/module.zig");
const order_mod = @import("modules/order/root.zig");
const db_backend = @import("db/backend.zig");
const schema = @import("db/schema.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    std.log.info("╔══════════════════════════════════════════╗", .{});
    std.log.info("║  ShopDemo — Single Order Module           ║", .{});
    std.log.info("║  ZigModu Minimal Runnable Example         ║", .{});
    std.log.info("╚══════════════════════════════════════════╝", .{});

    const sqlite_path = init.environ_map.get("SHOPDEMO_SQLITE") orelse ":memory:";
    var db_client = zigmodu.data.Client.init(allocator, io, .{
        .driver = .sqlite,
        .sqlite_path = sqlite_path,
    });
    defer db_client.deinit();
    try db_client.connect();
    try schema.apply(&db_client);
    std.log.info("[main] SQLite ready at {s}", .{sqlite_path});

    var builder = zigmodu.builder(allocator, io);
    _ = builder.withName("shopdemo");
    _ = builder.withValidation(true);
    var app = try builder.build(.{order_module});
    defer app.deinit();
    try app.start();
    defer app.stop();
    std.log.info("[main] Application '{s}' started", .{app.config.name});

    // Shared event bus from the application registry (ThreadSafeEventBus):
    // the order service publishes, this listener handles side effects.
    const order_bus = try app.eventBus(order_mod.service.OrderEvent);
    try order_bus.subscribe(struct {
        fn onOrderEvent(e: order_mod.service.OrderEvent) void {
            switch (e) {
                .created => |c| std.log.info("[event] order created id={d}", .{c.id}),
                .updated => |u| std.log.info("[event] order updated id={d}", .{u.id}),
                .deleted => |d| std.log.info("[event] order deleted id={d}", .{d.id}),
            }
        }
    }.onOrderEvent);

    const Backend = db_backend.Backend;
    _ = Backend;

    const backend = zigmodu.data.SqlxBackend{
        .allocator = allocator,
        .client = &db_client,
    };
    var order_persist = order_mod.persistence.OrderPersistence.init(backend);
    var order_svc = order_mod.service.OrderService.init(&order_persist);
    order_svc.withEvents(order_bus);
    var order_api = order_mod.api.OrderApi.init(&order_svc);

    const port: u16 = blk: {
        if (init.environ_map.get("HTTP_PORT")) |p| {
            break :blk std.fmt.parseInt(u16, p, 10) catch 8080;
        }
        break :blk 8080;
    };

    var server = zigmodu.http.Server.init(io, allocator, port);
    defer server.deinit();
    server.withGracefulDrain(zigmodu.getInFlightCounter());

    var v1 = server.group("/api/v1");
    try order_api.registerRoutes(&v1);

    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"status\":\"UP\"}");
            }
        }.handle,
    });

    std.log.info("[main] HTTP server listening on http://0.0.0.0:{d}", .{port});
    std.log.info("[main] API v1: http://localhost:{d}/api/v1/orders", .{port});
    std.log.info("[main] Health: http://localhost:{d}/health/live", .{port});

    try server.start();
}
