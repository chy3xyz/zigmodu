const std = @import("std");
const zigmodu = @import("zigmodu");

/// ============================================
/// Notification Module - 通知模块
/// 提供邮件、短信、站内信等通知服务
/// ============================================
pub const NotificationModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "notification",
        .description = "Multi-channel notification service (email, SMS, in-app)",
        .dependencies = &.{"database"},
    };

    var notifications: std.ArrayList(Notification) = undefined;
    var templates: std.StringHashMap(Template) = undefined;
    var notification_id_counter: u64 = 1;
    var allocator: std.mem.Allocator = undefined;

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        notifications = std.ArrayList(Notification){};
        templates = std.StringHashMap(Template).init(allocator);

        // 初始化通知模板
        try initializeTemplates();

        std.log.info("[notification] Notification module initialized", .{});
    }

    pub fn deinit() void {
        for (notifications.items) |*notification| {
            notification.deinit(allocator);
        }
        notifications.deinit(allocator);

        var template_iter = templates.iterator();
        while (template_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        templates.deinit();

        std.log.info("[notification] Notification module cleaned up", .{});
    }

    /// 通知
    pub const Notification = struct {
        id: u64,
        user_id: u64,
        type: NotificationType,
        channel: Channel,
        subject: []const u8,
        content: []const u8,
        status: NotificationStatus,
        retry_count: u32,
        max_retries: u32,
        metadata: ?std.StringHashMap([]const u8),
        created_at: i64,
        sent_at: ?i64,
        read_at: ?i64,

        pub fn deinit(self: *Notification, alloc: std.mem.Allocator) void {
            alloc.free(self.subject);
            alloc.free(self.content);
            if (self.metadata) |*meta| {
                var iter = meta.iterator();
                while (iter.next()) |entry| {
                    alloc.free(entry.key_ptr.*);
                    alloc.free(entry.value_ptr.*);
                }
                meta.deinit();
            }
        }
    };

    /// 通知类型
    pub const NotificationType = enum {
        order_created,
        order_confirmed,
        order_shipped,
        order_delivered,
        order_cancelled,
        payment_received,
        payment_failed,
        low_stock_alert,
        welcome,
        password_reset,
        promotional,
    };

    /// 通知渠道
    pub const Channel = enum {
        email,
        sms,
        push,
        in_app,

        pub fn toString(self: Channel) []const u8 {
            return switch (self) {
                .email => "email",
                .sms => "sms",
                .push => "push",
                .in_app => "in_app",
            };
        }
    };

    /// 通知状态
    pub const NotificationStatus = enum {
        pending,
        sent,
        delivered,
        failed,
        read,
    };

    /// 通知模板
    pub const Template = struct {
        name: []const u8,
        subject_template: []const u8,
        content_template: []const u8,
        channel: Channel,

        pub fn deinit(self: *Template, alloc: std.mem.Allocator) void {
            alloc.free(self.name);
            alloc.free(self.subject_template);
            alloc.free(self.content_template);
        }
    };

    /// 初始化模板
    fn initializeTemplates() !void {
        const template_data = .{
            .{
                "order_created",
                "Order Confirmation - Order #{order_id}",
                "Thank you for your order! Your order #{order_id} has been received. Total: ${total}",
                .email,
            },
            .{
                "order_shipped",
                "Your Order Has Shipped - Order #{order_id}",
                "Good news! Your order #{order_id} has been shipped. Track your package at: {tracking_url}",
                .email,
            },
            .{
                "order_delivered",
                "Order Delivered - Order #{order_id}",
                "Your order #{order_id} has been delivered. We hope you enjoy your purchase!",
                .email,
            },
            .{
                "payment_received",
                "Payment Confirmation",
                "We have received your payment of ${amount}. Thank you!",
                .email,
            },
            .{
                "welcome",
                "Welcome to Bookstore!",
                "Welcome {username}! Your account has been created successfully.",
                .email,
            },
            .{
                "low_stock_alert",
                "Low Stock Alert",
                "Book '{book_title}' is running low on stock. Current quantity: {quantity}",
                .email,
            },
        };

        inline for (template_data) |data| {
            const template = Template{
                .name = try allocator.dupe(u8, data[0]),
                .subject_template = try allocator.dupe(u8, data[1]),
                .content_template = try allocator.dupe(u8, data[2]),
                .channel = data[3],
            };
            try templates.put(try allocator.dupe(u8, data[0]), template);
        }
    }

    /// 发送通知
    pub fn sendNotification(user_id: u64, notif_type: NotificationType, channel: Channel, params: anytype) !Notification {
        // 获取模板
        const template_name = getTemplateName(notif_type);
        const template = templates.get(template_name) orelse {
            // 使用默认模板
            return try createNotification(user_id, notif_type, channel, "Notification", "You have a new notification");
        };

        // 渲染模板
        const subject = try renderTemplate(template.subject_template, params);
        const content = try renderTemplate(template.content_template, params);

        return try createNotification(user_id, notif_type, channel, subject, content);
    }

    /// 获取模板名称
    fn getTemplateName(notif_type: NotificationType) []const u8 {
        return switch (notif_type) {
            .order_created => "order_created",
            .order_shipped => "order_shipped",
            .order_delivered => "order_delivered",
            .payment_received => "payment_received",
            .welcome => "welcome",
            .low_stock_alert => "low_stock_alert",
            else => "default",
        };
    }

    /// 渲染模板
    fn renderTemplate(template: []const u8, params: anytype) ![]const u8 {
        // 简化实现：直接返回模板
        // 实际实现应该使用模板引擎替换参数
        _ = params;
        return try allocator.dupe(u8, template);
    }

    /// 创建通知
    fn createNotification(user_id: u64, notif_type: NotificationType, channel: Channel, subject: []const u8, content: []const u8) !Notification {
        const notification = Notification{
            .id = notification_id_counter,
            .user_id = user_id,
            .type = notif_type,
            .channel = channel,
            .subject = try allocator.dupe(u8, subject),
            .content = try allocator.dupe(u8, content),
            .status = .pending,
            .retry_count = 0,
            .max_retries = 3,
            .metadata = null,
            .created_at = std.time.timestamp(),
            .sent_at = null,
            .read_at = null,
        };

        notification_id_counter += 1;
        try notifications.append(allocator, notification);

        // 模拟发送
        try processNotification(notification.id);

        std.log.info("[notification] Created notification {d} for user {d}, type: {any}", .{ notification.id, user_id, notif_type });

        return notification;
    }

    /// 处理通知（模拟发送）
    fn processNotification(notification_id: u64) !void {
        for (notifications.items) |*notification| {
            if (notification.id == notification_id) {
                // 模拟发送延迟
                // 实际实现会调用邮件服务、短信网关等
                notification.status = .sent;
                notification.sent_at = std.time.timestamp();

                std.log.info("[notification] Sent {any} notification to user {d} via {s}", .{ notification.type, notification.user_id, notification.channel.toString() });
                return;
            }
        }
    }

    /// 获取用户的通知
    pub fn getUserNotifications(user_id: u64) ![]Notification {
        var result = std.ArrayList(Notification){};
        for (notifications.items) |notification| {
            if (notification.user_id == user_id) {
                try result.append(allocator, notification);
            }
        }
        return result.toOwnedSlice(allocator);
    }

    /// 标记通知为已读
    pub fn markAsRead(notification_id: u64) !bool {
        for (notifications.items) |*notification| {
            if (notification.id == notification_id) {
                notification.status = .read;
                notification.read_at = std.time.timestamp();
                return true;
            }
        }
        return false;
    }

    /// 发送欢迎邮件
    pub fn sendWelcomeEmail(user_id: u64, username: []const u8) !void {
        _ = try sendNotification(user_id, .welcome, .email, .{
            .username = username,
        });
    }

    /// 发送订单确认
    pub fn sendOrderConfirmation(user_id: u64, order_id: u64, total: f64) !void {
        _ = try sendNotification(user_id, .order_created, .email, .{
            .order_id = order_id,
            .total = total,
        });
    }

    /// 发送发货通知
    pub fn sendShippingNotification(user_id: u64, order_id: u64, tracking_url: []const u8) !void {
        _ = try sendNotification(user_id, .order_shipped, .email, .{
            .order_id = order_id,
            .tracking_url = tracking_url,
        });
    }

    /// 获取通知统计
    pub fn getNotificationStats() NotificationStats {
        var stats = NotificationStats{};

        for (notifications.items) |notification| {
            stats.total_notifications += 1;

            switch (notification.status) {
                .sent => stats.sent_count += 1,
                .delivered => stats.delivered_count += 1,
                .read => stats.read_count += 1,
                .failed => stats.failed_count += 1,
                else => {},
            }

            switch (notification.channel) {
                .email => stats.email_count += 1,
                .sms => stats.sms_count += 1,
                .push => stats.push_count += 1,
                .in_app => stats.in_app_count += 1,
            }
        }

        return stats;
    }

    /// 通知统计
    pub const NotificationStats = struct {
        total_notifications: u32 = 0,
        sent_count: u32 = 0,
        delivered_count: u32 = 0,
        read_count: u32 = 0,
        failed_count: u32 = 0,
        email_count: u32 = 0,
        sms_count: u32 = 0,
        push_count: u32 = 0,
        in_app_count: u32 = 0,
    };
};

test "Notification module" {
    try NotificationModule.init();
    defer NotificationModule.deinit();

    // Send welcome email
    try NotificationModule.sendWelcomeEmail(1, "testuser");

    // Send order confirmation
    try NotificationModule.sendOrderConfirmation(1, 123, 99.99);

    // Get user notifications
    const user_notifications = try NotificationModule.getUserNotifications(1);
    try std.testing.expectEqual(@as(usize, 2), user_notifications.len);

    // Mark as read
    const marked = try NotificationModule.markAsRead(user_notifications[0].id);
    try std.testing.expect(marked);

    // Get stats
    const stats = NotificationModule.getNotificationStats();
    try std.testing.expectEqual(@as(u32, 2), stats.total_notifications);
}
