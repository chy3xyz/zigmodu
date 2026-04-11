const std = @import("std");
const zigmodu = @import("zigmodu");

// Define events
const OrderCreatedEvent = struct {
    order_id: u64,
    user_id: u64,
    amount: f64,
};

const PaymentProcessedEvent = struct {
    order_id: u64,
    status: PaymentStatus,
    timestamp: i64,
};

const PaymentStatus = enum {
    success,
    failed,
    pending,
};

// Event handlers
fn onOrderCreated(event: OrderCreatedEvent) void {
    std.log.info("📦 Order created: id={d}, user={d}, amount={d:.2}", .{
        event.order_id,
        event.user_id,
        event.amount,
    });
}

fn onPaymentProcessed(event: PaymentProcessedEvent) void {
    const status_str = switch (event.status) {
        .success => "✅ SUCCESS",
        .failed => "❌ FAILED",
        .pending => "⏳ PENDING",
    };
    std.log.info("💳 Payment processed: order={d}, status={s}", .{
        event.order_id,
        status_str,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== Event Bus Example ===", .{});

    // Create event buses
    var order_bus = zigmodu.EventBus(OrderCreatedEvent).init(allocator);
    defer order_bus.deinit();

    var payment_bus = zigmodu.EventBus(PaymentProcessedEvent).init(allocator);
    defer payment_bus.deinit();

    // Subscribe to events
    try order_bus.subscribe(onOrderCreated);
    try payment_bus.subscribe(onPaymentProcessed);

    std.log.info("📡 Event listeners registered", .{});

    // Simulate events
    std.log.info("\n🚀 Simulating events...\n", .{});

    order_bus.publish(.{
        .order_id = 1001,
        .user_id = 42,
        .amount = 99.99,
    });

    payment_bus.publish(.{
        .order_id = 1001,
        .status = .success,
        .timestamp = std.time.timestamp(),
    });

    order_bus.publish(.{
        .order_id = 1002,
        .user_id = 43,
        .amount = 149.50,
    });

    payment_bus.publish(.{
        .order_id = 1002,
        .status = .pending,
        .timestamp = std.time.timestamp(),
    });

    std.log.info("\n✅ Event processing complete!", .{});
}
