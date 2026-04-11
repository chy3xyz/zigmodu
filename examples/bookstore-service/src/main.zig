const std = @import("std");
const zigmodu = @import("zigmodu");
const modules = @import("modules");

// Module aliases for convenience
const config_module = modules.config;
const database_module = modules.database;
const repository_module = modules.repository;
const eventbus_module = modules.eventbus;
const catalog_module = modules.catalog;
const user_module = modules.user;
const inventory_module = modules.inventory;
const cart_module = modules.cart;
const order_module = modules.order;
const payment_module = modules.payment;
const notification_module = modules.notification;
const audit_module = modules.audit;
const api_module = modules.api;

/// ============================================
/// Bookstore Service Application - Complete Edition
/// Full-featured modular bookstore service backend with Event-Driven Architecture
/// ============================================
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    printBanner();

    // Initialize Config Module
    std.log.info("Step 1: Loading configuration...", .{});
    try config_module.ConfigModule.init();
    defer config_module.ConfigModule.deinit();
    try config_module.ConfigModule.loadFromFile("config/app.json");
    const cfg = config_module.ConfigModule.getConfig();
    std.log.info("  Config loaded - Server: {s}:{d}", .{ cfg.server.host, cfg.server.port });

    // Initialize Event Bus first
    std.log.info("Step 2: Initializing event bus...", .{});
    try eventbus_module.EventBusModule.init();
    defer eventbus_module.EventBusModule.deinit();
    std.log.info("  Event bus initialized", .{});

    // Setup event-driven cross-module communication
    std.log.info("Step 3: Setting up event-driven communication...", .{});
    try setupEventDrivenCommunication();
    std.log.info("  Event listeners registered", .{});

    // Scan and register all modules
    std.log.info("Step 4: Scanning modules...", .{});
    var app_modules = try zigmodu.scanModules(allocator, .{
        config_module.ConfigModule,
        database_module.DatabaseModule,
        catalog_module.CatalogModule,
        user_module.UserModule,
        inventory_module.InventoryModule,
        cart_module.CartModule,
        order_module.OrderModule,
        payment_module.PaymentModule,
        notification_module.NotificationModule,
        audit_module.AuditModule,
        api_module.ApiModule,
    });
    defer app_modules.deinit();
    std.log.info("  Registered {d} modules", .{app_modules.modules.count()});

    // Validate module dependencies
    std.log.info("Step 5: Validating dependencies...", .{});
    try zigmodu.validateModules(&app_modules);
    std.log.info("  All dependencies validated", .{});

    // Generate documentation
    std.log.info("Step 6: Generating documentation...", .{});
    try zigmodu.generateDocs(&app_modules, "bookstore_modules.puml", allocator);
    std.log.info("  Documentation generated: bookstore_modules.puml", .{});

    // Initialize all modules
    std.log.info("Step 7: Initializing modules...", .{});
    try zigmodu.startAll(&app_modules);
    std.log.info("  All modules initialized", .{});
    defer zigmodu.stopAll(&app_modules);

    // Initialize database
    std.log.info("Step 8: Setting up database...", .{});
    try database_module.DatabaseModule.connect(.{});
    std.log.info("  Database initialized", .{});

    // Seed sample data
    std.log.info("Step 9: Seeding sample data...", .{});
    try catalog_module.CatalogModule.seedData();
    try user_module.UserModule.seedData();
    std.log.info("  Sample data loaded", .{});

    // Initialize inventory
    std.log.info("Step 10: Initializing inventory...", .{});
    try inventory_module.InventoryModule.initBookStock(1, 100, "A-01-01");
    try inventory_module.InventoryModule.initBookStock(2, 150, "A-01-02");
    try inventory_module.InventoryModule.initBookStock(3, 80, "A-01-03");
    try inventory_module.InventoryModule.initBookStock(4, 200, "B-02-01");
    try inventory_module.InventoryModule.initBookStock(5, 120, "B-02-02");
    std.log.info("  Inventory initialized", .{});

    // Start API server
    std.log.info("Step 11: Starting API server...", .{});
    try api_module.ApiModule.startServer(cfg.server.port);
    std.log.info("  API server running on http://localhost:{d}", .{cfg.server.port});

    // Print system status
    try printSystemStatus();

    // Run comprehensive demos
    std.log.info("", .{});
    std.log.info("=== Running Comprehensive Demos ===", .{});

    try demoUserWorkflow();
    try demoCartWorkflow();
    try demoOrderWorkflow();
    try demoNotificationSystem();
    try demoAuditSystem();

    // Print final statistics
    try printFinalStats();

    std.log.info("", .{});
    std.log.info("Press Ctrl+C to stop the server", .{});

    std.Thread.sleep(2 * std.time.ns_per_s);

    std.log.info("", .{});
    std.log.info("Shutting down gracefully...", .{});
}

/// Setup event-driven cross-module communication
fn setupEventDrivenCommunication() !void {
    // Inventory auto-reserves stock when order created
    try eventbus_module.EventBusModule.subscribe(.order_created, struct {
        fn handle(event: eventbus_module.EventBusModule.Event) !void {
            std.log.info("  [EVENT] Inventory: Auto-reserving stock for order", .{});
            _ = event;
        }
    }.handle, "inventory");

    // Notification sends email when order created
    try eventbus_module.EventBusModule.subscribe(.order_created, struct {
        fn handle(event: eventbus_module.EventBusModule.Event) !void {
            std.log.info("  [EVENT] Notification: Sending order confirmation email", .{});
            _ = event;
        }
    }.handle, "notification");

    // Audit logs all payment events
    try eventbus_module.EventBusModule.subscribe(.payment_completed, struct {
        fn handle(event: eventbus_module.EventBusModule.Event) !void {
            std.log.info("  [EVENT] Audit: Logging payment transaction", .{});
            _ = event;
        }
    }.handle, "audit");

    std.log.info("  Event listeners registered:", .{});
    std.log.info("    - Inventory → order_created", .{});
    std.log.info("    - Notification → order_created", .{});
    std.log.info("    - Audit → payment_completed", .{});
}

fn printBanner() void {
    std.log.info("", .{});
    std.log.info("==============================================", .{});
    std.log.info("  Bookstore Service - Complete Edition", .{});
    std.log.info("  Enterprise Modular Backend Service", .{});
    std.log.info("  Powered by ZigModu Framework", .{});
    std.log.info("==============================================", .{});
    std.log.info("", .{});
}

fn printSystemStatus() !void {
    std.log.info("", .{});
    std.log.info("=== System Status Overview ===", .{});

    const catalog_stats = try catalog_module.CatalogModule.getCategoryStats();
    std.log.info("Catalog: {d} books, ${d:.2} total value", .{ catalog_stats.total_books, catalog_stats.total_value });

    const users = user_module.UserModule.getAllUsers();
    std.log.info("Users: {d} registered users", .{users.len});

    const inventory_stats = inventory_module.InventoryModule.getInventoryStats();
    std.log.info("Inventory: {d} items, {d} units total, {d} reserved", .{ inventory_stats.total_books, inventory_stats.total_quantity, inventory_stats.total_reserved });

    const payment_methods = try payment_module.PaymentModule.getActivePaymentMethods();
    std.log.info("Payment: {d} active payment methods", .{payment_methods.len});

    std.log.info("", .{});
    std.log.info("Available API Endpoints:", .{});
    std.log.info("  GET    /api/health", .{});
    std.log.info("  GET    /api/books", .{});
    std.log.info("  GET    /api/books/:id", .{});
    std.log.info("  GET    /api/cart", .{});
    std.log.info("  POST   /api/auth/login", .{});
    std.log.info("  GET    /api/orders", .{});
    std.log.info("  GET    /api/inventory", .{});
    std.log.info("", .{});
}

fn demoUserWorkflow() !void {
    std.log.info("", .{});
    std.log.info("--- Demo 1: User Registration & Authentication ---", .{});

    const new_user = try user_module.UserModule.register(.{
        .username = "democustomer",
        .email = "demo@example.com",
        .password = "demo123",
        .role = .customer,
    });
    std.log.info("  Registered new user: {s} (id={d})", .{ new_user.username, new_user.id });

    const auth = try user_module.UserModule.login(.{
        .username = "democustomer",
        .password = "demo123",
    });
    std.log.info("  User logged in successfully (ID: {d})", .{auth.user.id});

    try audit_module.AuditModule.logAudit(.{
        .user_id = auth.user.id,
        .action = "USER_LOGIN",
        .resource_type = "session",
        .success = true,
    });
}

fn demoCartWorkflow() !void {
    std.log.info("", .{});
    std.log.info("--- Demo 2: Shopping Cart Workflow ---", .{});

    const user_id: u64 = 2;

    const item1 = try cart_module.CartModule.addItem(user_id, 1, 2, 29.99);
    std.log.info("  Added book 1 to cart (qty={d})", .{item1.quantity});

    const item2 = try cart_module.CartModule.addItem(user_id, 3, 1, 44.99);
    std.log.info("  Added book 3 to cart (qty={d})", .{item2.quantity});

    const cart = cart_module.CartModule.getCart(user_id).?;
    std.log.info("  Cart contains {d} items", .{cart.items.items.len});

    const summary = try cart_module.CartModule.checkoutPreview(user_id);
    std.log.info("  Checkout total: ${d:.2}", .{summary.total});
}

fn demoOrderWorkflow() !void {
    std.log.info("", .{});
    std.log.info("--- Demo 3: Order Processing Workflow ---", .{});

    const auth = try user_module.UserModule.login(.{
        .username = "customer1",
        .password = "password123",
    });
    std.log.info("  User authenticated: {s}", .{auth.user.username});

    const reservation = try inventory_module.InventoryModule.reserveStock(1, 2, 100);
    std.log.info("  Reserved {d} units of book 1", .{reservation.quantity});

    const order = try order_module.OrderModule.createOrder(.{
        .user_id = auth.user.id,
        .items = &.{
            .{ .book_id = 1, .quantity = 2 },
            .{ .book_id = 2, .quantity = 1 },
        },
        .shipping_address = .{
            .street = "123 Demo Street",
            .city = "Shanghai",
            .zip_code = "200000",
            .country = "China",
        },
    });
    std.log.info("  Order created: #{d}, Total: ${d:.2}", .{ order.id, order.total_amount });

    const payment_response = try payment_module.PaymentModule.processPayment(.{
        .order_id = order.id,
        .user_id = auth.user.id,
        .amount = order.total_amount,
        .payment_method = .credit_card,
    });
    std.log.info("  Payment processed: {s}", .{payment_response.message});

    if (payment_response.success) {
        _ = try order_module.OrderModule.updateOrderStatus(order.id, .paid);
        try inventory_module.InventoryModule.fulfillReservation(reservation.id);
        _ = try order_module.OrderModule.updateOrderStatus(order.id, .shipped);
        std.log.info("  Order completed and shipped", .{});
    }
}

fn demoNotificationSystem() !void {
    std.log.info("", .{});
    std.log.info("--- Demo 4: Notification System ---", .{});

    try notification_module.NotificationModule.sendWelcomeEmail(1, "newuser");
    std.log.info("  Welcome email sent", .{});

    try notification_module.NotificationModule.sendOrderConfirmation(1, 100, 150.00);
    std.log.info("  Order confirmation sent", .{});

    const notifications = try notification_module.NotificationModule.getUserNotifications(1);
    std.log.info("  User has {d} notifications", .{notifications.len});
}

fn demoAuditSystem() !void {
    std.log.info("", .{});
    std.log.info("--- Demo 5: Audit & Logging System ---", .{});

    try audit_module.AuditModule.logAudit(.{
        .user_id = 1,
        .action = "BOOK_CREATE",
        .resource_type = "book",
        .success = true,
    });

    try audit_module.AuditModule.logError(.{
        .error_type = "DatabaseConnection",
        .message = "Connection timeout",
        .level = .warning,
    });

    const audit_logs = try audit_module.AuditModule.getAuditLogs(null, null);
    std.log.info("  Total audit logs: {d}", .{audit_logs.len});
}

fn printFinalStats() !void {
    std.log.info("", .{});
    std.log.info("=== Final System Statistics ===", .{});

    const order_stats = try order_module.OrderModule.getOrderStats();
    std.log.info("Orders: {d} | Revenue: ${d:.2}", .{ order_stats.total_orders, order_stats.total_revenue });

    const payment_stats = payment_module.PaymentModule.getPaymentStats();
    std.log.info("Payments: {d} transactions | Success: {d:.2}%", .{ payment_stats.total_transactions, payment_stats.success_rate });

    const notification_stats = notification_module.NotificationModule.getNotificationStats();
    std.log.info("Notifications: {d} sent", .{notification_stats.sent_count});

    const inventory_stats = inventory_module.InventoryModule.getInventoryStats();
    std.log.info("Inventory: {d} items, {d} available", .{ inventory_stats.total_books, inventory_stats.getAvailable() });

    std.log.info("", .{});
    std.log.info("=== All Demos Completed Successfully ===", .{});
}
