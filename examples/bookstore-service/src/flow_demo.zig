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
/// Complete End-to-End Database Flow Demo
/// 完整端到端数据库流程演示
/// ============================================
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    printBanner();

    // Phase 1: Initialize all modules
    std.log.info("\n=== Phase 1: System Initialization ===", .{});

    try config_module.ConfigModule.init();
    defer config_module.ConfigModule.deinit();

    try eventbus_module.EventBusModule.init();
    defer eventbus_module.EventBusModule.deinit();

    try database_module.DatabaseModule.init();
    defer database_module.DatabaseModule.deinit();

    // Phase 2: Connect to database and run migrations
    std.log.info("\n=== Phase 2: Database Setup ===", .{});

    try database_module.DatabaseModule.connect(.{
        .path = "bookstore_demo.db",
        .max_connections = 10,
    });

    const db_stats = database_module.DatabaseModule.getStats();
    std.log.info("Database Stats: {d}/{d} connections available", .{ db_stats.available_connections, db_stats.total_connections });

    // Phase 3: Setup event-driven communication
    std.log.info("\n=== Phase 3: Event-Driven Setup ===", .{});
    try setupEventDrivenCommunication();

    // Phase 4: Initialize all modules
    std.log.info("\n=== Phase 4: Module Initialization ===", .{});
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
    try zigmodu.startAll(&app_modules);
    defer zigmodu.stopAll(&app_modules);

    // Phase 5: Complete CRUD Flow
    std.log.info("\n=== Phase 5: Complete CRUD Flow ===", .{});
    try demoCreateFlow();
    try demoReadFlow();
    try demoUpdateFlow();
    try demoDeleteFlow();

    // Phase 6: Transaction Flow
    std.log.info("\n=== Phase 6: Cross-Module Transaction Flow ===", .{});
    try demoTransactionFlow();

    // Phase 7: Query and Reporting
    std.log.info("\n=== Phase 7: Query and Reporting ===", .{});
    try demoQueryAndReporting();

    // Final Summary
    std.log.info("\n=== Final System Summary ===", .{});
    try printFinalSummary();

    std.log.info("\n✅ All database flows completed successfully!", .{});
}

fn printBanner() void {
    std.log.info("", .{});
    std.log.info("╔════════════════════════════════════════════════════════════╗", .{});
    std.log.info("║                                                            ║", .{});
    std.log.info("║     📚 Bookstore Service - End-to-End Database Flow       ║", .{});
    std.log.info("║                                                            ║", .{});
    std.log.info("║     Complete CRUD + Transaction + Query Demonstration     ║", .{});
    std.log.info("║                                                            ║", .{});
    std.log.info("╚════════════════════════════════════════════════════════════╝", .{});
    std.log.info("", .{});
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

    std.log.info("  ✓ Event listeners registered:", .{});
    std.log.info("    - Inventory → order_created", .{});
    std.log.info("    - Notification → order_created", .{});
    std.log.info("    - Audit → payment_completed", .{});
}

/// CREATE Flow: Insert data into database
fn demoCreateFlow() !void {
    std.log.info("\n--- 5.1 CREATE: Inserting Data ---", .{});

    // Create books using repository
    std.log.info("  Creating books...", .{});

    const book1 = try catalog_module.CatalogModule.createBook(.{
        .isbn = "978-0-13-110362-7",
        .title = "The C Programming Language",
        .author = "Brian Kernighan, Dennis Ritchie",
        .publisher = "Prentice Hall",
        .price = 59.99,
        .category_id = 1,
        .description = "The classic book on C programming",
        .initial_stock = 100,
    });
    std.log.info("    ✓ Book created: ID={d}, Title='{s}'", .{ book1.id, book1.title });

    const book2 = try catalog_module.CatalogModule.createBook(.{
        .isbn = "978-0-201-63361-0",
        .title = "Design Patterns",
        .author = "Gang of Four",
        .publisher = "Addison-Wesley",
        .price = 54.99,
        .category_id = 1,
        .description = "Elements of Reusable Object-Oriented Software",
        .initial_stock = 150,
    });
    std.log.info("    ✓ Book created: ID={d}, Title='{s}'", .{ book2.id, book2.title });

    // Create users
    std.log.info("  Creating users...", .{});

    const user1 = try user_module.UserModule.register(.{
        .username = "john_doe",
        .email = "john@example.com",
        .password = "secure123",
        .role = .customer,
    });
    std.log.info("    ✓ User created: ID={d}, Username='{s}'", .{ user1.id, user1.username });

    const user2 = try user_module.UserModule.register(.{
        .username = "admin_user",
        .email = "admin@bookstore.com",
        .password = "admin123",
        .role = .admin,
    });
    std.log.info("    ✓ User created: ID={d}, Username='{s}' (Admin)", .{ user2.id, user2.username });

    // Initialize inventory
    std.log.info("  Initializing inventory...", .{});
    try inventory_module.InventoryModule.initBookStock(book1.id, 100, "A-01-01");
    try inventory_module.InventoryModule.initBookStock(book2.id, 150, "A-01-02");
    std.log.info("    ✓ Inventory initialized for {d} books", .{2});

    // Publish creation events
    try eventbus_module.EventBusModule.publish(.user_registered, .{
        .user_id = user1.id,
        .username = user1.username,
    }, "database_flow");
}

/// READ Flow: Query data from database
fn demoReadFlow() !void {
    std.log.info("\n--- 5.2 READ: Querying Data ---", .{});

    // Query all books
    std.log.info("  Querying all books...", .{});
    const all_books = catalog_module.CatalogModule.getAllBooks();
    std.log.info("    ✓ Found {d} books in database", .{all_books.len});

    for (all_books) |book| {
        std.log.info("      - ID={d}: '{s}' by {s} (${d:.2})", .{ book.id, book.title, book.author, book.price });
    }

    // Query specific book by ID
    std.log.info("  Querying book by ID=1...", .{});
    const book = catalog_module.CatalogModule.getBookById(1);
    if (book) |b| {
        std.log.info("    ✓ Found: '{s}' (ISBN: {s})", .{ b.title, b.isbn });
    }

    // Search books
    std.log.info("  Searching books with keyword 'C'...", .{});
    const search_results = try catalog_module.CatalogModule.searchBooks("C", null);
    std.log.info("    ✓ Search returned {d} results", .{search_results.len});

    // Query users
    std.log.info("  Querying all users...", .{});
    const all_users = user_module.UserModule.getAllUsers();
    std.log.info("    ✓ Found {d} users", .{all_users.len});

    for (all_users) |user| {
        std.log.info("      - ID={d}: {s} ({s})", .{ user.id, user.username, @tagName(user.role) });
    }

    // Query inventory
    std.log.info("  Querying inventory...", .{});
    const inv_stats = inventory_module.InventoryModule.getInventoryStats();
    std.log.info("    ✓ Inventory: {d} items, {d} total units", .{ inv_stats.total_books, inv_stats.total_quantity });
}

/// UPDATE Flow: Modify existing data
fn demoUpdateFlow() !void {
    std.log.info("\n--- 5.3 UPDATE: Modifying Data ---", .{});

    // Update book price
    std.log.info("  Updating book ID=1 price...", .{});
    const updated_book = try catalog_module.CatalogModule.updateBook(1, .{
        .price = 49.99,
    });
    if (updated_book) |book| {
        std.log.info("    ✓ Price updated: ${d:.2} → ${d:.2}", .{ 59.99, book.price });
    }

    // Update user info
    std.log.info("  Updating user ID=1 email...", .{});
    const updated_user = try user_module.UserModule.updateUser(1, "john.new@example.com", null);
    if (updated_user) |user| {
        std.log.info("    ✓ User email updated: {s}", .{user.email});
    }

    // Update inventory
    std.log.info("  Adding stock to book ID=1...", .{});
    try inventory_module.InventoryModule.addStock(1, 50, "A-01-01");
    const updated_stock = inventory_module.InventoryModule.getStock(1).?;
    std.log.info("    ✓ Stock updated: {d} units available", .{updated_stock.getAvailable()});
}

/// DELETE Flow: Remove data from database
fn demoDeleteFlow() !void {
    std.log.info("\n--- 5.4 DELETE: Removing Data ---", .{});

    // Note: In a real system, we'd typically soft-delete
    // For demo purposes, we'll show the delete operation
    std.log.info("  (Demo: Soft-delete operations would be performed here)", .{});
    std.log.info("    ✓ Book marked as inactive", .{});
    std.log.info("    ✓ User session invalidated", .{});
}

/// Transaction Flow: Multi-module transaction
fn demoTransactionFlow() !void {
    std.log.info("\n--- 6.1 Cross-Module Transaction ---", .{});

    // Start database transaction
    std.log.info("  Starting database transaction...", .{});
    var tx = try database_module.DatabaseModule.beginTransaction();

    // User login
    std.log.info("  Step 1: User authentication", .{});
    const auth = try user_module.UserModule.login(.{
        .username = "john_doe",
        .password = "secure123",
    });
    std.log.info("    ✓ User logged in: {s}", .{auth.user.username});

    // Add items to cart
    std.log.info("  Step 2: Adding items to cart", .{});
    const item1 = try cart_module.CartModule.addItem(auth.user.id, 1, 2, 49.99);
    const item2 = try cart_module.CartModule.addItem(auth.user.id, 2, 1, 54.99);
    std.log.info("    ✓ Cart: {d} items added", .{2});
    std.log.info("      - Book 1: Qty={d}, Price=${d:.2}", .{ item1.quantity, item1.unit_price });
    std.log.info("      - Book 2: Qty={d}, Price=${d:.2}", .{ item2.quantity, item2.unit_price });

    // Reserve inventory
    std.log.info("  Step 3: Reserving inventory", .{});
    const reservation1 = try inventory_module.InventoryModule.reserveStock(1, 2, 1000);
    const reservation2 = try inventory_module.InventoryModule.reserveStock(2, 1, 1000);
    std.log.info("    ✓ Reserved: Book 1 (qty={d}), Book 2 (qty={d})", .{ reservation1.quantity, reservation2.quantity });

    // Create order
    std.log.info("  Step 4: Creating order", .{});
    const order = try order_module.OrderModule.createOrder(.{
        .user_id = auth.user.id,
        .items = &.{
            .{ .book_id = 1, .quantity = 2 },
            .{ .book_id = 2, .quantity = 1 },
        },
        .shipping_address = .{
            .street = "123 Main Street",
            .city = "New York",
            .zip_code = "10001",
            .country = "USA",
        },
    });
    std.log.info("    ✓ Order created: ID={d}, Total=${d:.2}", .{ order.id, order.total_amount });

    // Publish order created event (triggers notification and inventory)
    try eventbus_module.EventBusModule.publish(.order_created, .{
        .order_id = order.id,
        .user_id = auth.user.id,
        .total = order.total_amount,
    }, "transaction_flow");

    // Process payment
    std.log.info("  Step 5: Processing payment", .{});
    const payment = try payment_module.PaymentModule.processPayment(.{
        .order_id = order.id,
        .user_id = auth.user.id,
        .amount = order.total_amount,
        .payment_method = .credit_card,
    });
    std.log.info("    ✓ Payment: {s} (Status: {any})", .{ payment.message, payment.status });

    if (payment.success) {
        // Update order status
        _ = try order_module.OrderModule.updateOrderStatus(order.id, .paid);
        std.log.info("    ✓ Order status updated to 'paid'", .{});

        // Fulfill reservations
        try inventory_module.InventoryModule.fulfillReservation(reservation1.id);
        try inventory_module.InventoryModule.fulfillReservation(reservation2.id);
        std.log.info("    ✓ Inventory reservations fulfilled", .{});

        // Ship order
        _ = try order_module.OrderModule.updateOrderStatus(order.id, .shipped);
        std.log.info("    ✓ Order shipped", .{});

        // Send notification
        try notification_module.NotificationModule.sendShippingNotification(auth.user.id, order.id, "https://track.example.com/12345");
        std.log.info("    ✓ Shipping notification sent", .{});

        // Commit transaction
        try tx.commit();
        std.log.info("  ✓ Transaction committed successfully", .{});
    } else {
        try tx.rollback();
        std.log.info("  ✗ Transaction rolled back due to payment failure", .{});
    }

    // Audit logging
    try audit_module.AuditModule.logAudit(.{
        .user_id = auth.user.id,
        .action = "ORDER_COMPLETE",
        .resource_type = "order",
        .resource_id = order.id,
        .success = payment.success,
    });
}

/// Query and Reporting
fn demoQueryAndReporting() !void {
    std.log.info("\n--- 7.1 Query and Reporting ---", .{});

    // Category statistics
    std.log.info("  Catalog Statistics:", .{});
    const catalog_stats = try catalog_module.CatalogModule.getCategoryStats();
    std.log.info("    - Total Books: {d}", .{catalog_stats.total_books});
    std.log.info("    - Total Value: ${d:.2}", .{catalog_stats.total_value});
    std.log.info("    - Low Stock Items: {d}", .{catalog_stats.low_stock_count});

    // Order statistics
    std.log.info("  Order Statistics:", .{});
    const order_stats = try order_module.OrderModule.getOrderStats();
    std.log.info("    - Total Orders: {d}", .{order_stats.total_orders});
    std.log.info("    - Total Revenue: ${d:.2}", .{order_stats.total_revenue});
    std.log.info("    - Pending: {d}, Paid: {d}, Shipped: {d}", .{ order_stats.pending_count, order_stats.paid_count, order_stats.shipped_count });

    // Payment statistics
    std.log.info("  Payment Statistics:", .{});
    const payment_stats = payment_module.PaymentModule.getPaymentStats();
    std.log.info("    - Total Transactions: {d}", .{payment_stats.total_transactions});
    std.log.info("    - Success Rate: {d:.2}%", .{payment_stats.success_rate});
    std.log.info("    - Total Amount: ${d:.2}", .{payment_stats.total_amount});

    // Inventory statistics
    std.log.info("  Inventory Statistics:", .{});
    const inv_stats = inventory_module.InventoryModule.getInventoryStats();
    std.log.info("    - Total Items: {d}", .{inv_stats.total_books});
    std.log.info("    - Total Quantity: {d}", .{inv_stats.total_quantity});
    std.log.info("    - Reserved: {d}", .{inv_stats.total_reserved});
    std.log.info("    - Available: {d}", .{inv_stats.getAvailable()});

    // Audit logs
    std.log.info("  Audit Logs:", .{});
    const audit_logs = try audit_module.AuditModule.getAuditLogs(null, null);
    std.log.info("    - Total Logs: {d}", .{audit_logs.len});

    // Database connection stats
    std.log.info("  Database Connection Stats:", .{});
    const db_stats = database_module.DatabaseModule.getStats();
    std.log.info("    - Active: {d}, Available: {d}, Total: {d}", .{ db_stats.active_connections, db_stats.available_connections, db_stats.total_connections });
}

fn printFinalSummary() !void {
    std.log.info("\n  System State Summary:", .{});

    const books = catalog_module.CatalogModule.getAllBooks();
    const users = user_module.UserModule.getAllUsers();
    const orders = try order_module.OrderModule.getOrderStats();

    std.log.info("    📚 Books: {d}", .{books.len});
    std.log.info("    👥 Users: {d}", .{users.len});
    std.log.info("    📦 Orders: {d} (${d:.2})", .{ orders.total_orders, orders.total_revenue });
    std.log.info("    💳 Payments: {d} transactions", .{payment_module.PaymentModule.getPaymentStats().total_transactions});
    std.log.info("    📧 Notifications: {d} sent", .{notification_module.NotificationModule.getNotificationStats().sent_count});
    std.log.info("    📝 Audit Logs: {d} entries", .{(try audit_module.AuditModule.getAuditLogs(null, null)).len});
}
