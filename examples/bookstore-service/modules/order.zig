const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Order Module - 订单处理模块
/// 提供订单创建、状态管理、支付处理等功能
/// ============================================
pub const OrderModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "order",
        .description = "Order processing with state machine and payment",
        .dependencies = &.{ "database", "catalog", "user", "inventory" },
    };

    var orders: std.ArrayList(Order) = undefined;
    var allocator: std.mem.Allocator = undefined;
    var order_id_counter: u64 = 1;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        orders = std.ArrayList(Order){};
        std.log.info("[order] Order module initialized", .{});
    }

    pub fn deinit() void {
        for (orders.items) |*order| {
            order.deinit(allocator);
        }
        orders.deinit(allocator);
        std.log.info("[order] Order module cleaned up", .{});
    }

    /// 订单实体
    pub const Order = struct {
        id: u64,
        user_id: u64,
        items: std.ArrayList(OrderItem),
        total_amount: f64,
        status: OrderStatus,
        shipping_address: Address,
        payment_info: ?PaymentInfo,
        created_at: i64,
        updated_at: i64,

        pub fn deinit(self: *Order, alloc: std.mem.Allocator) void {
            self.items.deinit(alloc);
            alloc.free(self.shipping_address.street);
            alloc.free(self.shipping_address.city);
            alloc.free(self.shipping_address.country);
            if (self.payment_info) |*payment| {
                alloc.free(payment.method);
            }
        }
    };

    /// 订单项
    pub const OrderItem = struct {
        book_id: u64,
        quantity: u32,
        unit_price: f64,
        subtotal: f64,
    };

    /// 订单状态
    pub const OrderStatus = enum {
        pending, // 待处理
        confirmed, // 已确认
        paid, // 已支付
        shipped, // 已发货
        delivered, // 已送达
        cancelled, // 已取消
        refunded, // 已退款

        pub fn toString(self: OrderStatus) []const u8 {
            return switch (self) {
                .pending => "pending",
                .confirmed => "confirmed",
                .paid => "paid",
                .shipped => "shipped",
                .delivered => "delivered",
                .cancelled => "cancelled",
                .refunded => "refunded",
            };
        }
    };

    /// 地址
    pub const Address = struct {
        street: []const u8,
        city: []const u8,
        zip_code: []const u8,
        country: []const u8,
    };

    /// 支付信息
    pub const PaymentInfo = struct {
        method: []const u8,
        transaction_id: ?[]const u8,
        paid_at: ?i64,
    };

    /// 创建订单请求
    pub const CreateOrderRequest = struct {
        user_id: u64,
        items: []const OrderItemRequest,
        shipping_address: Address,
    };

    /// 订单项请求
    pub const OrderItemRequest = struct {
        book_id: u64,
        quantity: u32,
    };

    /// 支付请求
    pub const PaymentRequest = struct {
        order_id: u64,
        payment_method: []const u8,
        amount: f64,
    };

    /// 创建订单
    pub fn createOrder(request: CreateOrderRequest) !Order {
        const now = std.time.timestamp();

        var order = Order{
            .id = order_id_counter,
            .user_id = request.user_id,
            .items = std.ArrayList(OrderItem){},
            .total_amount = 0,
            .status = .pending,
            .shipping_address = .{
                .street = try allocator.dupe(u8, request.shipping_address.street),
                .city = try allocator.dupe(u8, request.shipping_address.city),
                .zip_code = try allocator.dupe(u8, request.shipping_address.zip_code),
                .country = try allocator.dupe(u8, request.shipping_address.country),
            },
            .payment_info = null,
            .created_at = now,
            .updated_at = now,
        };

        // Add items and calculate total
        for (request.items) |item_req| {
            // In real implementation, fetch book price from catalog module
            const unit_price = getBookPrice(item_req.book_id);
            const subtotal = unit_price * @as(f64, @floatFromInt(item_req.quantity));

            try order.items.append(allocator, .{
                .book_id = item_req.book_id,
                .quantity = item_req.quantity,
                .unit_price = unit_price,
                .subtotal = subtotal,
            });

            order.total_amount += subtotal;
        }

        order_id_counter += 1;
        try orders.append(allocator, order);

        std.log.info("[order] Created order: {d} for user {d}, total: {d:.2}", .{ order.id, order.user_id, order.total_amount });

        return order;
    }

    /// 获取图书价格（模拟）
    fn getBookPrice(book_id: u64) f64 {
        _ = book_id;
        // In real implementation, query catalog module
        return 29.99;
    }

    /// 获取所有订单
    pub fn getAllOrders() []Order {
        return orders.items;
    }

    /// 根据 ID 获取订单
    pub fn getOrderById(id: u64) ?*Order {
        for (orders.items) |*order| {
            if (order.id == id) {
                return order;
            }
        }
        return null;
    }

    /// 获取用户订单
    pub fn getOrdersByUser(user_id: u64) ![]Order {
        var user_orders = std.ArrayList(Order){};
        for (orders.items) |order| {
            if (order.user_id == user_id) {
                try user_orders.append(allocator, order);
            }
        }
        return user_orders.toOwnedSlice(allocator);
    }

    /// 更新订单状态
    pub fn updateOrderStatus(id: u64, new_status: OrderStatus) !?Order {
        var order = getOrderById(id) orelse return null;

        // Validate state transition
        if (!isValidStatusTransition(order.status, new_status)) {
            return error.InvalidStatusTransition;
        }

        order.status = new_status;
        order.updated_at = std.time.timestamp();

        std.log.info("[order] Updated order {d} status: {s} -> {s}", .{ id, order.status.toString(), new_status.toString() });

        return order.*;
    }

    /// 验证状态转换
    fn isValidStatusTransition(current: OrderStatus, new: OrderStatus) bool {
        return switch (current) {
            .pending => new == .confirmed or new == .cancelled,
            .confirmed => new == .paid or new == .cancelled,
            .paid => new == .shipped or new == .refunded,
            .shipped => new == .delivered,
            .delivered => new == .refunded,
            .cancelled => false,
            .refunded => false,
        };
    }

    /// 处理支付
    pub fn processPayment(request: PaymentRequest) !?Order {
        var order = getOrderById(request.order_id) orelse return null;

        if (order.status != .confirmed) {
            return error.OrderNotConfirmed;
        }

        if (order.total_amount != request.amount) {
            return error.InvalidPaymentAmount;
        }

        // Simulate payment processing
        const payment = PaymentInfo{
            .method = try allocator.dupe(u8, request.payment_method),
            .transaction_id = try std.fmt.allocPrint(allocator, "TXN-{d}-{d}", .{ order.id, std.time.timestamp() }),
            .paid_at = std.time.timestamp(),
        };

        order.payment_info = payment;
        order.status = .paid;
        order.updated_at = std.time.timestamp();

        std.log.info("[order] Payment processed for order {d}, method: {s}", .{ order.id, request.payment_method });

        return order.*;
    }

    /// 取消订单
    pub fn cancelOrder(id: u64, reason: []const u8) !?Order {
        _ = reason;

        var order = getOrderById(id) orelse return null;

        if (order.status == .shipped or order.status == .delivered) {
            return error.OrderCannotBeCancelled;
        }

        if (order.status == .paid) {
            // Initiate refund process
            order.status = .refunded;
            std.log.info("[order] Order {d} cancelled and refunded", .{id});
        } else {
            order.status = .cancelled;
            std.log.info("[order] Order {d} cancelled", .{id});
        }

        order.updated_at = std.time.timestamp();
        return order.*;
    }

    /// 获取订单统计
    pub fn getOrderStats() !OrderStats {
        var stats = OrderStats{};

        for (orders.items) |order| {
            stats.total_orders += 1;
            stats.total_revenue += order.total_amount;

            switch (order.status) {
                .pending => stats.pending_count += 1,
                .confirmed => stats.confirmed_count += 1,
                .paid => stats.paid_count += 1,
                .shipped => stats.shipped_count += 1,
                .delivered => stats.delivered_count += 1,
                .cancelled => stats.cancelled_count += 1,
                .refunded => stats.refunded_count += 1,
            }
        }

        return stats;
    }

    /// 订单统计
    pub const OrderStats = struct {
        total_orders: u32 = 0,
        total_revenue: f64 = 0,
        pending_count: u32 = 0,
        confirmed_count: u32 = 0,
        paid_count: u32 = 0,
        shipped_count: u32 = 0,
        delivered_count: u32 = 0,
        cancelled_count: u32 = 0,
        refunded_count: u32 = 0,
    };
};

test "Order module" {
    try OrderModule.init();
    defer OrderModule.deinit();

    // Create an order
    const order = try OrderModule.createOrder(.{
        .user_id = 1,
        .items = &.{
            .{ .book_id = 1, .quantity = 2 },
            .{ .book_id = 2, .quantity = 1 },
        },
        .shipping_address = .{
            .street = "123 Main St",
            .city = "Beijing",
            .zip_code = "100000",
            .country = "China",
        },
    });

    try std.testing.expectEqual(@as(u64, 1), order.id);
    try std.testing.expect(order.total_amount > 0);
    try std.testing.expectEqual(OrderModule.OrderStatus.pending, order.status);

    // Confirm order
    const confirmed = try OrderModule.updateOrderStatus(order.id, .confirmed);
    try std.testing.expect(confirmed != null);
    try std.testing.expectEqual(OrderModule.OrderStatus.confirmed, confirmed.?.status);

    // Process payment
    const paid = try OrderModule.processPayment(.{
        .order_id = order.id,
        .payment_method = "credit_card",
        .amount = order.total_amount,
    });
    try std.testing.expect(paid != null);
    try std.testing.expectEqual(OrderModule.OrderStatus.paid, paid.?.status);

    // Ship order
    const shipped = try OrderModule.updateOrderStatus(order.id, .shipped);
    try std.testing.expect(shipped != null);

    // Get stats
    const stats = try OrderModule.getOrderStats();
    try std.testing.expectEqual(@as(u32, 1), stats.total_orders);
    try std.testing.expectEqual(@as(u32, 1), stats.shipped_count);
}
