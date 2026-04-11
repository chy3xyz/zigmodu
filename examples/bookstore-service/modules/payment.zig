const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Payment Module - 支付模块
/// 提供多种支付方式、交易记录、退款等功能
/// ============================================
pub const PaymentModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "payment",
        .description = "Payment processing with multiple gateways and transaction tracking",
        .dependencies = &.{ "database", "order" },
    };

    var transactions: std.ArrayList(Transaction) = undefined;
    var payment_methods: std.ArrayList(PaymentMethod) = undefined;
    var transaction_id_counter: u64 = 1;
    var allocator: std.mem.Allocator = undefined;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        transactions = std.ArrayList(Transaction){};
        payment_methods = std.ArrayList(PaymentMethod){};

        // 初始化支持的支付方式
        try initializePaymentMethods();

        std.log.info("[payment] Payment module initialized", .{});
    }

    pub fn deinit() void {
        for (transactions.items) |*tx| {
            tx.deinit(allocator);
        }
        transactions.deinit(allocator);

        for (payment_methods.items) |*method| {
            method.deinit(allocator);
        }
        payment_methods.deinit(allocator);

        std.log.info("[payment] Payment module cleaned up", .{});
    }

    /// 交易记录
    pub const Transaction = struct {
        id: u64,
        order_id: u64,
        user_id: u64,
        amount: f64,
        currency: []const u8,
        payment_method: PaymentMethodType,
        status: TransactionStatus,
        gateway_response: ?[]const u8,
        gateway_transaction_id: ?[]const u8,
        error_message: ?[]const u8,
        created_at: i64,
        completed_at: ?i64,

        pub fn deinit(self: *Transaction, alloc: std.mem.Allocator) void {
            alloc.free(self.currency);
            if (self.gateway_response) |resp| alloc.free(resp);
            if (self.gateway_transaction_id) |id| alloc.free(id);
            if (self.error_message) |msg| alloc.free(msg);
        }
    };

    /// 交易状态
    pub const TransactionStatus = enum {
        pending, // 待处理
        processing, // 处理中
        completed, // 已完成
        failed, // 失败
        refunded, // 已退款
        cancelled, // 已取消

        pub fn toString(self: TransactionStatus) []const u8 {
            return switch (self) {
                .pending => "pending",
                .processing => "processing",
                .completed => "completed",
                .failed => "failed",
                .refunded => "refunded",
                .cancelled => "cancelled",
            };
        }
    };

    /// 支付方式类型
    pub const PaymentMethodType = enum {
        credit_card,
        debit_card,
        paypal,
        alipay,
        wechat_pay,
        bank_transfer,
        cash_on_delivery,

        pub fn toString(self: PaymentMethodType) []const u8 {
            return switch (self) {
                .credit_card => "credit_card",
                .debit_card => "debit_card",
                .paypal => "paypal",
                .alipay => "alipay",
                .wechat_pay => "wechat_pay",
                .bank_transfer => "bank_transfer",
                .cash_on_delivery => "cash_on_delivery",
            };
        }
    };

    /// 支付方式配置
    pub const PaymentMethod = struct {
        type: PaymentMethodType,
        name: []const u8,
        is_active: bool,
        fee_percentage: f64,
        fee_fixed: f64,
        min_amount: f64,
        max_amount: f64,

        pub fn deinit(self: *PaymentMethod, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
        }
    };

    /// 支付请求
    pub const PaymentRequest = struct {
        order_id: u64,
        user_id: u64,
        amount: f64,
        currency: []const u8 = "USD",
        payment_method: PaymentMethodType,
        card_token: ?[]const u8 = null, // 用于信用卡支付
        metadata: ?std.StringHashMap([]const u8) = null,
    };

    /// 支付响应
    pub const PaymentResponse = struct {
        success: bool,
        transaction_id: u64,
        status: TransactionStatus,
        message: []const u8,
        requires_action: bool = false,
        action_url: ?[]const u8 = null,
    };

    /// 退款请求
    pub const RefundRequest = struct {
        transaction_id: u64,
        amount: f64,
        reason: []const u8,
    };

    /// 初始化支付方式
    fn initializePaymentMethods() !void {
        const methods = [_]PaymentMethod{
            .{
                .type = .credit_card,
                .name = try allocator.dupe(u8, "Credit Card"),
                .is_active = true,
                .fee_percentage = 2.9,
                .fee_fixed = 0.30,
                .min_amount = 0.50,
                .max_amount = 99999.99,
            },
            .{
                .type = .paypal,
                .name = try allocator.dupe(u8, "PayPal"),
                .is_active = true,
                .fee_percentage = 2.9,
                .fee_fixed = 0.30,
                .min_amount = 0.50,
                .max_amount = 99999.99,
            },
            .{
                .type = .alipay,
                .name = try allocator.dupe(u8, "Alipay"),
                .is_active = true,
                .fee_percentage = 2.5,
                .fee_fixed = 0.0,
                .min_amount = 0.50,
                .max_amount = 99999.99,
            },
            .{
                .type = .cash_on_delivery,
                .name = try allocator.dupe(u8, "Cash on Delivery"),
                .is_active = true,
                .fee_percentage = 0.0,
                .fee_fixed = 5.0,
                .min_amount = 0.0,
                .max_amount = 99999.99,
            },
        };

        for (methods) |method| {
            try payment_methods.append(allocator, method);
        }
    }

    /// 处理支付
    pub fn processPayment(request: PaymentRequest) !PaymentResponse {
        // 验证支付方式
        const method = getPaymentMethod(request.payment_method) orelse {
            return error.InvalidPaymentMethod;
        };

        if (!method.is_active) {
            return error.PaymentMethodInactive;
        }

        // 验证金额
        if (request.amount < method.min_amount) {
            return error.AmountTooLow;
        }
        if (request.amount > method.max_amount) {
            return error.AmountTooHigh;
        }

        // 创建交易记录
        const transaction = try createTransaction(request);

        // 模拟支付网关处理
        const result = simulateGatewayProcessing(transaction);

        // 更新交易状态
        try updateTransactionStatus(transaction.id, result.status, result.gateway_response);

        std.log.info("[payment] Processed payment for order {d}, transaction {d}, status: {s}", .{ request.order_id, transaction.id, result.status.toString() });

        return PaymentResponse{
            .success = result.status == .completed,
            .transaction_id = transaction.id,
            .status = result.status,
            .message = if (result.status == .completed) "Payment successful" else "Payment failed",
        };
    }

    /// 创建交易记录
    fn createTransaction(request: PaymentRequest) !Transaction {
        const now = std.time.timestamp();
        const tx = Transaction{
            .id = transaction_id_counter,
            .order_id = request.order_id,
            .user_id = request.user_id,
            .amount = request.amount,
            .currency = try allocator.dupe(u8, request.currency),
            .payment_method = request.payment_method,
            .status = .pending,
            .gateway_response = null,
            .gateway_transaction_id = null,
            .error_message = null,
            .created_at = now,
            .completed_at = null,
        };

        transaction_id_counter += 1;
        try transactions.append(allocator, tx);

        return tx;
    }

    /// 模拟网关处理
    fn simulateGatewayProcessing(tx: Transaction) struct { status: TransactionStatus, gateway_response: ?[]const u8 } {
        _ = tx;
        // 模拟 95% 成功率
        const rand = std.crypto.random.int(u8);
        if (rand < 242) { // 95% of 255
            return .{
                .status = .completed,
                .gateway_response = allocator.dupe(u8, "{\"status\":\"success\",\"id\":\"txn_123\"}") catch null,
            };
        } else {
            return .{
                .status = .failed,
                .gateway_response = allocator.dupe(u8, "{\"status\":\"failed\",\"error\":\"card_declined\"}") catch null,
            };
        }
    }

    /// 更新交易状态
    fn updateTransactionStatus(tx_id: u64, status: TransactionStatus, gateway_response: ?[]const u8) !void {
        for (transactions.items) |*tx| {
            if (tx.id == tx_id) {
                tx.status = status;
                if (gateway_response) |resp| {
                    tx.gateway_response = try allocator.dupe(u8, resp);
                }
                if (status == .completed or status == .failed or status == .cancelled) {
                    tx.completed_at = std.time.timestamp();
                }
                return;
            }
        }
    }

    /// 处理退款
    pub fn processRefund(request: RefundRequest) !PaymentResponse {
        var tx = getTransaction(request.transaction_id) orelse {
            return error.TransactionNotFound;
        };

        if (tx.status != .completed) {
            return error.TransactionNotCompleted;
        }

        if (request.amount > tx.amount) {
            return error.RefundAmountExceedsOriginal;
        }

        // 模拟退款处理
        tx.status = .refunded;
        tx.completed_at = std.time.timestamp();

        std.log.info("[payment] Processed refund for transaction {d}, amount: {d:.2}", .{ request.transaction_id, request.amount });

        return PaymentResponse{
            .success = true,
            .transaction_id = tx.id,
            .status = .refunded,
            .message = "Refund processed successfully",
        };
    }

    /// 获取支付方式
    fn getPaymentMethod(method_type: PaymentMethodType) ?PaymentMethod {
        for (payment_methods.items) |method| {
            if (method.type == method_type) {
                return method;
            }
        }
        return null;
    }

    /// 获取交易记录
    pub fn getTransaction(id: u64) ?*Transaction {
        for (transactions.items) |*tx| {
            if (tx.id == id) {
                return tx;
            }
        }
        return null;
    }

    /// 获取订单的交易记录
    pub fn getTransactionsByOrder(order_id: u64) ![]Transaction {
        var result = std.ArrayList(Transaction){};
        for (transactions.items) |tx| {
            if (tx.order_id == order_id) {
                try result.append(allocator, tx);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// 获取支持的支付方式
    pub fn getActivePaymentMethods() ![]PaymentMethod {
        var result = std.ArrayList(PaymentMethod){};
        for (payment_methods.items) |method| {
            if (method.is_active) {
                try result.append(allocator, method);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// 获取支付统计
    pub fn getPaymentStats() PaymentStats {
        var stats = PaymentStats{};

        for (transactions.items) |tx| {
            stats.total_transactions += 1;
            stats.total_amount += tx.amount;

            switch (tx.status) {
                .completed => {
                    stats.successful_transactions += 1;
                    stats.successful_amount += tx.amount;
                },
                .failed => stats.failed_transactions += 1,
                .refunded => stats.refunded_transactions += 1,
                else => {},
            }
        }

        if (stats.total_transactions > 0) {
            stats.success_rate = @as(f64, @floatFromInt(stats.successful_transactions)) /
                @as(f64, @floatFromInt(stats.total_transactions)) * 100.0;
        }

        return stats;
    }

    /// 支付统计
    pub const PaymentStats = struct {
        total_transactions: u32 = 0,
        successful_transactions: u32 = 0,
        failed_transactions: u32 = 0,
        refunded_transactions: u32 = 0,
        total_amount: f64 = 0,
        successful_amount: f64 = 0,
        success_rate: f64 = 0,
    };
};

test "Payment module" {
    try PaymentModule.init();
    defer PaymentModule.deinit();

    // Process a payment
    const response = try PaymentModule.processPayment(.{
        .order_id = 1,
        .user_id = 1,
        .amount = 99.99,
        .payment_method = .credit_card,
    });

    try std.testing.expect(response.success);
    try std.testing.expectEqual(PaymentModule.TransactionStatus.completed, response.status);

    // Get transaction
    const tx = PaymentModule.getTransaction(response.transaction_id).?;
    try std.testing.expectEqual(@as(u64, 1), tx.order_id);
    try std.testing.expectApproxEqAbs(@as(f64, 99.99), tx.amount, 0.01);

    // Get stats
    const stats = PaymentModule.getPaymentStats();
    try std.testing.expectEqual(@as(u32, 1), stats.total_transactions);
}
