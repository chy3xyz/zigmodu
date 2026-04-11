const std = @import("std");
const zigmodu = @import("zigmodu");

pub const EventBusModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "eventbus",
        .description = "Cross-module event communication system",
        .dependencies = &.{"database"},
    };

    const SubList = @import("std").ArrayList(Subscription);
    const EvList = @import("std").ArrayList(Event);

    var subscriptions: SubList = undefined;
    var event_queue: EvList = undefined;
    var event_id_counter: u64 = 1;
    var allocator: std.mem.Allocator = undefined;
    var processing_mutex: std.Thread.Mutex = .{};

    pub fn init() !void {
        allocator = std.heap.page_allocator;
        subscriptions = .{};
        event_queue = .{};
        std.log.info("[eventbus] Event bus initialized", .{});
    }

    pub fn deinit() void {
        for (subscriptions.items) |*sub| {
            sub.deinit(allocator);
        }
        subscriptions.deinit(allocator);

        for (event_queue.items) |*event| {
            event.deinit(allocator);
        }
        event_queue.deinit(allocator);
        std.log.info("[eventbus] Event bus cleaned up", .{});
    }

    pub const EventType = enum {
        user_registered, user_logged_in, user_updated,
        cart_item_added, cart_item_removed, cart_checked_out,
        order_created, order_confirmed, order_paid, order_shipped, order_delivered, order_cancelled,
        payment_initiated, payment_completed, payment_failed, refund_processed,
        stock_reserved, stock_released, stock_updated, low_stock_alert,
        notification_sent, notification_read,
        audit_log_created,
    };

    pub const Event = struct {
        id: u64,
        event_type: EventType,
        payload: []const u8,
        source_module: []const u8,
        timestamp: i64,
        correlation_id: ?[]const u8,
        
        pub fn deinit(self: *Event, alloc: std.mem.Allocator) void {
            alloc.free(self.payload);
            alloc.free(self.source_module);
            if (self.correlation_id) |id| alloc.free(id);
        }
    };

    pub const Subscription = struct {
        id: u64,
        event_type: EventType,
        handler: EventHandler,
        target_module: []const u8,
        
        pub fn deinit(self: *Subscription, alloc: std.mem.Allocator) void {
            alloc.free(self.target_module);
        }
    };

    pub const EventHandler = *const fn (event: Event) anyerror!void;

    pub fn publish(event_type: EventType, payload: anytype, source_module: []const u8) !void {
        processing_mutex.lock();
        defer processing_mutex.unlock();

        const payload_json = try std.json.stringifyAlloc(allocator, payload, .{});
        
        const event = Event{
            .id = event_id_counter,
            .event_type = event_type,
            .payload = payload_json,
            .source_module = try allocator.dupe(u8, source_module),
            .timestamp = std.time.timestamp(),
            .correlation_id = null,
        };

        event_id_counter += 1;
        try event_queue.append(allocator, event);
        std.log.info("[eventbus] Published event {any} from {s}", .{ event_type, source_module });
        try processEvent(event);
    }

    pub fn subscribe(event_type: EventType, handler: EventHandler, target_module: []const u8) !void {
        const subscription = Subscription{
            .id = subscriptions.items.len + 1,
            .event_type = event_type,
            .handler = handler,
            .target_module = try allocator.dupe(u8, target_module),
        };
        try subscriptions.append(allocator, subscription);
        std.log.info("[eventbus] Module {s} subscribed to {any}", .{ target_module, event_type });
    }

    fn processEvent(event: Event) !void {
        for (subscriptions.items) |sub| {
            if (sub.event_type == event.event_type) {
                sub.handler(event) catch |err| {
                    std.log.err("[eventbus] Handler failed for event {d}: {any}", .{ event.id, err });
                };
            }
        }
    }

    pub fn getPendingEventCount() usize {
        return event_queue.items.len;
    }
};
