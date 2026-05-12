const std = @import("std");

/// ListenerSet 用于 O(1) 的订阅/取消订阅操作
/// ListenerSet 使用 ArrayList 存储回调，小数据量时比 HashMap 更高效
///
/// NOTE: This type is NOT thread-safe. For concurrent access, use ThreadSafeEventBus.
fn ListenerSet(comptime CallbackType: type) type {
    return struct {
        const Self = @This();

        // 使用 ArrayList 存储回调，实现更好的缓存局部性
        list: std.ArrayList(CallbackType),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .list = std.ArrayList(CallbackType).empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
        }

        pub fn add(self: *Self, callback: CallbackType) !void {
            try self.list.append(self.allocator, callback);
        }

        pub fn remove(self: *Self, callback: CallbackType) bool {
            for (self.list.items, 0..) |cb, i| {
                if (cb == callback) {
                    _ = self.list.swapRemove(i);
                    return true;
                }
            }
            return false;
        }

        pub fn contains(self: *Self, callback: CallbackType) bool {
            for (self.list.items) |cb| {
                if (cb == callback) return true;
            }
            return false;
        }

        pub fn count(self: *Self) usize {
            return self.list.items.len;
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator{ .items = self.list.items, .index = 0 };
        }

        pub const Iterator = struct {
            items: []const CallbackType,
            index: usize,

            pub fn next(self: *Iterator) ?*const CallbackType {
                if (self.index >= self.items.len) return null;
                const ptr = &self.items[self.index];
                self.index += 1;
                return ptr;
            }
        };
    };
}

pub fn EventBus(comptime EventType: type) type {
    return struct {
        const Self = @This();
        const CallbackType = *const fn (EventType, *anyopaque) void;

        allocator: std.mem.Allocator,
        listeners: std.AutoHashMap(EventType, ListenerSet(CallbackType)),

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .allocator = alloc,
                .listeners = std.AutoHashMap(EventType, ListenerSet(CallbackType)).init(alloc),
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.listeners.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.listeners.deinit();
        }

        pub fn subscribe(self: *Self, event_type: EventType, callback: CallbackType) !void {
            const result = try self.listeners.getOrPut(event_type);
            if (!result.found_existing) {
                result.value_ptr.* = ListenerSet(CallbackType).init(self.allocator);
            }
            try result.value_ptr.add(callback);
        }

        pub fn unsubscribe(self: *Self, event_type: EventType, callback: CallbackType) void {
            if (self.listeners.getPtr(event_type)) |set| {
                _ = set.remove(callback);
            }
        }

        pub fn publish(self: *Self, event_type: EventType, payload: *anyopaque) void {
            if (self.listeners.getPtr(event_type)) |set| {
                var iter = set.iterator();
                while (iter.next()) |callback| {
                    callback.*(event_type, payload);
                }
            }
        }

        pub fn subscriberCount(self: *Self, event_type: EventType) usize {
            if (self.listeners.getPtr(event_type)) |set| {
                return set.count();
            }
            return 0;
        }

        pub fn totalSubscriberCount(self: *Self) usize {
            var total: usize = 0;
            var iter = self.listeners.iterator();
            while (iter.next()) |entry| {
                total += entry.value_ptr.count();
            }
            return total;
        }
    };
}

pub fn TypedEventBus(comptime T: type) type {
    return struct {
        const Self = @This();
        const CallbackType = *const fn (T) void;

        allocator: std.mem.Allocator,
        listeners: ListenerSet(CallbackType),

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .allocator = alloc,
                .listeners = ListenerSet(CallbackType).init(alloc),
            };
        }

        pub fn subscribe(self: *Self, listener: CallbackType) !void {
            try self.listeners.add(listener);
        }

        pub fn unsubscribe(self: *Self, listener: CallbackType) void {
            _ = self.listeners.remove(listener);
        }

        pub fn publish(self: *Self, event: T) void {
            var iter = self.listeners.iterator();
            while (iter.next()) |callback| {
                callback.*(event);
            }
        }

        pub fn subscriberCount(self: *Self) usize {
            return self.listeners.count();
        }

        pub fn deinit(self: *Self) void {
            self.listeners.deinit();
        }
    };
}

/// Thread-safe wrapper around TypedEventBus.
/// All operations are protected by a Mutex for concurrent access.
pub fn ThreadSafeEventBus(comptime T: type) type {
    return struct {
        const Self = @This();

        bus: TypedEventBus(T),
        io: std.Io,
        mu: std.Io.Mutex,

        pub fn init(alloc: std.mem.Allocator, ioo: std.Io) Self {
            return .{
                .bus = TypedEventBus(T).init(alloc),
                .io = ioo,
                .mu = .init,
            };
        }

        pub fn deinit(self: *Self) void {
            self.bus.deinit();
        }

        pub fn subscribe(self: *Self, listener: TypedEventBus(T).CallbackType) !void {
            self.mu.lock(self.io) catch return;
            defer self.mu.unlock(self.io);
            try self.bus.subscribe(listener);
        }

        pub fn unsubscribe(self: *Self, listener: TypedEventBus(T).CallbackType) void {
            self.mu.lock(self.io) catch return;
            defer self.mu.unlock(self.io);
            self.bus.unsubscribe(listener);
        }

        /// Publish an event to all subscribers.
        ///
        /// NOTE: The mutex is held for the duration of all listener callbacks.
        /// Keep listener handlers short (non-blocking). For long-running work,
        /// have listeners enqueue to a worker instead of processing inline.
        pub fn publish(self: *Self, event: T) void {
            self.mu.lock(self.io) catch return;
            defer self.mu.unlock(self.io);
            self.bus.publish(event);
        }

        pub fn subscriberCount(self: *Self) usize {
            self.mu.lock(self.io) catch return 0;
            defer self.mu.unlock(self.io);
            return self.bus.subscriberCount();
        }
    };
}

/// Unified event bus — always typed. For untyped usage, pass `void`.
/// Generated code should use `EventBus(MyEvent)` for type safety.
pub fn UnifiedEventBus(comptime T: type) type {
    return TypedEventBus(T);
}

test "TypedEventBus subscribe publish unsubscribe" {
    const allocator = std.testing.allocator;

    const Event = struct {
        value: i32,
    };

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    const Ctx = struct {
        var received: i32 = 0;
        fn cb(event: Event) void {
            received = event.value;
        }
    };

    try bus.subscribe(Ctx.cb);
    try std.testing.expectEqual(@as(usize, 1), bus.subscriberCount());

    bus.publish(.{ .value = 42 });
    try std.testing.expectEqual(@as(i32, 42), Ctx.received);

    bus.unsubscribe(Ctx.cb);
    try std.testing.expectEqual(@as(usize, 0), bus.subscriberCount());
}

test "TypedEventBus multi-subscriber" {
    const allocator = std.testing.allocator;
    const Event = struct { value: i32 };

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    const Ctx = struct {
        var sum: i32 = 0;
        fn cb1(event: Event) void { sum += event.value; }
        fn cb2(event: Event) void { sum += event.value * 2; }
        fn cb3(event: Event) void { sum += event.value * 3; }
    };

    try bus.subscribe(Ctx.cb1);
    try bus.subscribe(Ctx.cb2);
    try bus.subscribe(Ctx.cb3);
    try std.testing.expectEqual(@as(usize, 3), bus.subscriberCount());

    Ctx.sum = 0;
    bus.publish(.{ .value = 10 });
    // cb1 + cb2 + cb3 = 10 + 20 + 30 = 60
    try std.testing.expectEqual(@as(i32, 60), Ctx.sum);

    bus.unsubscribe(Ctx.cb2);
    try std.testing.expectEqual(@as(usize, 2), bus.subscriberCount());

    Ctx.sum = 0;
    bus.publish(.{ .value = 5 });
    // cb1 + cb3 = 5 + 15 = 20
    try std.testing.expectEqual(@as(i32, 20), Ctx.sum);
}
