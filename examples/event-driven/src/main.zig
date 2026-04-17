const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example 2: Event-Driven Architecture
// ============================================
// Demonstrates: EventBus, publish-subscribe pattern

// 定义领域事件
const OrderCreated = struct {
    order_id: u64,
    user_id: u64,
    total_amount: f64,
    timestamp: i64,
};

const PaymentProcessed = struct {
    order_id: u64,
    payment_id: u64,
    status: enum { success, failed },
    amount: f64,
};

const InventoryReserved = struct {
    order_id: u64,
    product_id: u64,
    quantity: i32,
};

// 订单模块 - 发布事件
const OrderModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "order",
        .description = "Manages orders and publishes events",
        .dependencies = &.{},
    };

    // 事件总线将在启动时注入
    var event_bus: ?*zigmodu.TypedEventBus(OrderCreated) = null;

    pub fn init() !void {
        std.log.info("[order] Order module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("[order] Order module shut down", .{});
    }

    pub fn setEventBus(bus: *zigmodu.TypedEventBus(OrderCreated)) void {
        event_bus = bus;
    }

    pub fn createOrder(user_id: u64, total: f64) !u64 {
        const order_id = 12345; // 在实际应用中会生成唯一 ID

        std.log.info("[order] Creating order #{d} for user {d}", .{ order_id, user_id });

        // 发布 OrderCreated 事件
        if (event_bus) |bus| {
            bus.publish(.{
                .order_id = order_id,
                .user_id = user_id,
                .total_amount = total,
                .timestamp = 0,
            });
            std.log.info("[order] Published OrderCreated event", .{});
        }

        return order_id;
    }
};

// 库存模块 - 订阅订单事件
const InventoryModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "inventory",
        .description = "Manages inventory and reacts to order events",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("[inventory] Inventory module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("[inventory] Inventory module shut down", .{});
    }

    // 事件处理器
    pub fn onOrderCreated(event: OrderCreated) void {
        std.log.info("[inventory] Received OrderCreated event for order #{d}", .{event.order_id});
        std.log.info("[inventory] Reserving inventory for user {d}, amount: ${d:.2}", .{
            event.user_id, event.total_amount,
        });
        // 实际的库存预留逻辑
    }
};

// 支付模块 - 订阅订单事件
const PaymentModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "payment",
        .description = "Processes payments when orders are created",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("[payment] Payment module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("[payment] Payment module shut down", .{});
    }

    pub fn onOrderCreated(event: OrderCreated) void {
        std.log.info("[payment] Received OrderCreated event for order #{d}", .{event.order_id});
        std.log.info("[payment] Processing payment of ${d:.2}", .{event.total_amount});

        // 模拟支付处理
        // std.Thread.sleep(100 * std.time.ns_per_ms);

        std.log.info("[payment] Payment completed successfully", .{});
    }
};

// 通知模块 - 订阅多个事件
const NotificationModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "notification",
        .description = "Sends notifications based on events",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("[notification] Notification module initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("[notification] Notification module shut down", .{});
    }

    pub fn onOrderCreated(event: OrderCreated) void {
        std.log.info("[notification] Sending order confirmation to user {d}", .{event.user_id});
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    std.log.info("=== ZigModu Event-Driven Example ===", .{});
    std.log.info("Demonstrates: EventBus, publish-subscribe pattern\n", .{});

    // 创建事件总线
    var order_event_bus = zigmodu.TypedEventBus(OrderCreated).init(allocator);
    defer order_event_bus.deinit();

    // 订阅事件处理器
    try order_event_bus.subscribe(InventoryModule.onOrderCreated);
    try order_event_bus.subscribe(PaymentModule.onOrderCreated);
    try order_event_bus.subscribe(NotificationModule.onOrderCreated);

    std.log.info("✓ Event handlers registered:", .{});
    std.log.info("  - InventoryModule.onOrderCreated", .{});
    std.log.info("  - PaymentModule.onOrderCreated", .{});
    std.log.info("  - NotificationModule.onOrderCreated\n", .{});

    // 创建应用
    var app = try zigmodu.Application.init(init.io,
        allocator,
        "event-driven-shop",
        .{ OrderModule, InventoryModule, PaymentModule, NotificationModule },
        .{ .validate_on_start = true },
    );
    defer app.deinit();

    // 注入事件总线到订单模块
    OrderModule.setEventBus(&order_event_bus);

    try app.start();
    std.log.info("", .{});

    // 模拟业务场景：创建订单
    std.log.info("=== Scenario: Customer creates order ===", .{});
    const user_id: u64 = 1001;
    const order_total: f64 = 299.99;

    const order_id = try OrderModule.createOrder(user_id, order_total);

    std.log.info("", .{});
    std.log.info("✅ Order #{d} created successfully", .{order_id});
    std.log.info("   Notice how all subscribers were automatically notified!", .{});
    std.log.info("   - Inventory reserved", .{});
    std.log.info("   - Payment processed", .{});
    std.log.info("   - Notification sent", .{});

    std.log.info("\n=== Benefits of Event-Driven Architecture ===", .{});
    std.log.info("1. Decoupling: Order module doesn't know about Inventory/Payment", .{});
    std.log.info("2. Extensibility: Easy to add new subscribers", .{});
    std.log.info("3. Testability: Can test handlers independently", .{});
    std.log.info("4. Async potential: Events can be processed asynchronously", .{});
}
