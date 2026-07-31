//! Thread-safe event bus with typed event dispatch, infallible subscription model.

const std = @import("std");
const Time = @import("Time.zig");
const WorkerPool = @import("WorkerPool.zig").WorkerPool;

const log = std.log.scoped(.event_bus);

/// ListenerSet for O(1) [...]/[...]
/// ListenerSet [...] ArrayList [...] HashMap [...]
///
/// NOTE: This type is NOT thread-safe. For concurrent access, use ThreadSafeEventBus.
fn ListenerSet(comptime CallbackType: type) type {
    return struct {
        const Self = @This();

        // [...] ArrayList [...]Achieve better cache locality
        list: std.ArrayList(CallbackType),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            var list = std.ArrayList(CallbackType).empty;
            list.ensureTotalCapacity(allocator, 4) catch |err| std.log.warn("[EventBus] listener capacity prealloc failed: {}", .{err});
            return .{
                .list = list,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn add(self: *Self, callback: CallbackType) !void {
            try self.list.append(self.allocator, callback);
        }

        pub fn addAssumeCapacity(self: *Self, callback: CallbackType) void {
            self.list.appendAssumeCapacity(callback);
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
            return initCapacity(alloc, 32);
        }

        /// Init with capacity hint (max distinct event types). Pre-allocates
        /// HashMap storage so runtime subscribe() is infallible.
        pub fn initCapacity(alloc: std.mem.Allocator, capacity: usize) Self {
            var listeners = std.AutoHashMap(EventType, ListenerSet(CallbackType)).init(alloc);
            listeners.ensureTotalCapacity(@intCast(capacity)) catch |err| std.log.warn("[EventBus] listeners capacity prealloc failed: {}", .{err});
            return .{
                .allocator = alloc,
                .listeners = listeners,
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.listeners.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.listeners.deinit();
            self.* = undefined;
        }

        /// Infallible subscribe — capacity pre-allocated in initCapacity.
        pub fn subscribe(self: *Self, event_type: EventType, callback: CallbackType) void {
            const result = self.listeners.getOrPutAssumeCapacity(event_type);
            if (!result.found_existing) {
                result.value_ptr.* = ListenerSet(CallbackType).init(self.allocator);
            }
            result.value_ptr.addAssumeCapacity(callback);
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

        const AsyncSubscriber = struct {
            pool: *WorkerPool,
            handler: CallbackType,
        };

        const AsyncDelivery = struct {
            allocator: std.mem.Allocator,
            handler: CallbackType,
            event: T,

            fn run(ctx: ?*anyopaque, io_arg: std.Io) void {
                _ = io_arg;
                const delivery: *AsyncDelivery = @ptrCast(@alignCast(ctx.?));
                delivery.handler(delivery.event);
                delivery.allocator.destroy(delivery);
            }
        };

        allocator: std.mem.Allocator,
        listeners: ListenerSet(CallbackType),
        async_subscribers: std.ArrayList(AsyncSubscriber),
        published_total: std.atomic.Value(u64),
        dropped_async_total: std.atomic.Value(u64),

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .allocator = alloc,
                .listeners = ListenerSet(CallbackType).init(alloc),
                .async_subscribers = std.ArrayList(AsyncSubscriber).empty,
                .published_total = std.atomic.Value(u64).init(0),
                .dropped_async_total = std.atomic.Value(u64).init(0),
            };
        }

        pub fn subscribe(self: *Self, listener: CallbackType) !void {
            try self.listeners.add(listener);
        }

        pub fn subscribeAsync(self: *Self, pool: *WorkerPool, handler: CallbackType) !void {
            try self.async_subscribers.append(self.allocator, .{ .pool = pool, .handler = handler });
        }

        pub fn unsubscribe(self: *Self, listener: CallbackType) void {
            _ = self.listeners.remove(listener);
        }

        pub fn publish(self: *Self, event: T) void {
            _ = self.published_total.fetchAdd(1, .monotonic);
            var iter = self.listeners.iterator();
            while (iter.next()) |callback| {
                callback.*(event);
            }

            for (self.async_subscribers.items, 0..) |async_sub, index| {
                const delivery = self.allocator.create(AsyncDelivery) catch |err| {
                    _ = self.dropped_async_total.fetchAdd(1, .monotonic);
                    log.warn("dropped async event for subscriber {d} (pool '{s}'): failed to allocate delivery for event type {s}: {s}", .{
                        index, async_sub.pool.name, @typeName(T), @errorName(err),
                    });
                    continue;
                };
                delivery.* = .{
                    .allocator = self.allocator,
                    .handler = async_sub.handler,
                    .event = event,
                };
                const dispatched = async_sub.pool.dispatch(.{
                    .run = AsyncDelivery.run,
                    .ctx = delivery,
                });
                if (!dispatched) {
                    _ = self.dropped_async_total.fetchAdd(1, .monotonic);
                    log.warn("dropped async event for subscriber {d} (pool '{s}'): dispatch rejected for event type {s}", .{
                        index, async_sub.pool.name, @typeName(T),
                    });
                    self.allocator.destroy(delivery);
                }
            }
        }

        pub fn subscriberCount(self: *Self) usize {
            return self.listeners.count();
        }

        /// Total number of times `publish` was called.
        pub fn publishedCount(self: *Self) u64 {
            return self.published_total.load(.monotonic);
        }

        /// Total number of async events dropped because allocation or dispatch failed.
        pub fn droppedAsyncCount(self: *Self) u64 {
            return self.dropped_async_total.load(.monotonic);
        }

        pub fn deinit(self: *Self) void {
            self.listeners.deinit();
            self.async_subscribers.deinit(self.allocator);
            self.* = undefined;
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
            self.* = undefined;
        }

        pub fn subscribe(self: *Self, listener: TypedEventBus(T).CallbackType) !void {
            self.mu.lock(self.io) catch return;
            defer self.mu.unlock(self.io);
            try self.bus.subscribe(listener);
        }

        pub fn subscribeAsync(self: *Self, pool: *WorkerPool, listener: TypedEventBus(T).CallbackType) !void {
            self.mu.lock(self.io) catch return;
            defer self.mu.unlock(self.io);
            try self.bus.subscribeAsync(pool, listener);
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
        fn cb1(event: Event) void {
            sum += event.value;
        }
        fn cb2(event: Event) void {
            sum += event.value * 2;
        }
        fn cb3(event: Event) void {
            sum += event.value * 3;
        }
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

test "TypedEventBus async subscriber" {
    const allocator = std.testing.allocator;
    const Event = struct { value: i32 };

    const Ctx = struct {
        var received: std.atomic.Value(i32) = .init(0);
        fn cb(event: Event) void {
            _ = @This().received.fetchAdd(event.value, .monotonic);
        }
    };

    var pool = try WorkerPool.init(allocator, std.testing.io, "bus", 2, 8);
    defer pool.deinit();

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    try bus.subscribeAsync(&pool, Ctx.cb);
    bus.publish(.{ .value = 7 });
    bus.publish(.{ .value = 3 });

    const deadline = Time.monotonicNowMilliseconds() + 5000;
    while (Ctx.received.load(.monotonic) != 10) {
        if (Time.monotonicNowMilliseconds() >= deadline) return error.Timeout;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(i32, 10), Ctx.received.load(.monotonic));
}

test "TypedEventBus async drop is observed and consistent" {
    const allocator = std.testing.allocator;
    const Event = struct { value: i32 };

    const Ctx = struct {
        var received: std.atomic.Value(i32) = .init(0);
        fn cb(event: Event) void {
            _ = @This().received.fetchAdd(event.value, .monotonic);
        }
    };

    // Pool with zero queue capacity rejects every dispatch, exercising the
    // drop log path without actually allocating a worker task.
    var pool = try WorkerPool.init(allocator, std.testing.io, "drop", 1, 0);
    defer pool.deinit();

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    try bus.subscribeAsync(&pool, Ctx.cb);
    try std.testing.expectEqual(@as(usize, 1), bus.async_subscribers.items.len);

    bus.publish(.{ .value = 5 });

    // The subscriber list and delivered-event count must remain consistent
    // even though the event was dropped by the saturated pool.
    try std.testing.expectEqual(@as(usize, 1), bus.async_subscribers.items.len);
    try std.testing.expectEqual(@as(i32, 0), Ctx.received.load(.monotonic));
}

test "TypedEventBus publishedCount and droppedAsyncCount track publish and drops" {
    const allocator = std.testing.allocator;
    const Event = struct { value: i32 };

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    // A pool that rejects every dispatch (zero queue capacity) forces the
    // "dispatch rejected" drop path.
    var pool = try WorkerPool.init(allocator, std.testing.io, "metrics-drop", 1, 0);
    defer pool.deinit();

    try bus.subscribeAsync(&pool, struct {
        fn cb(_: Event) void {}
    }.cb);

    try std.testing.expectEqual(@as(u64, 0), bus.publishedCount());
    try std.testing.expectEqual(@as(u64, 0), bus.droppedAsyncCount());

    bus.publish(.{ .value = 1 });
    bus.publish(.{ .value = 2 });
    bus.publish(.{ .value = 3 });

    try std.testing.expectEqual(@as(u64, 3), bus.publishedCount());
    try std.testing.expectEqual(@as(u64, 3), bus.droppedAsyncCount());
}

const ModuleRuntime = @import("ModuleRuntime.zig").ModuleRuntime;

test "TypedEventBus async subscribers on separate ModuleRuntime worker pools" {
    const allocator = std.testing.allocator;
    const Event = struct { order_id: u32 };

    const Ctx = struct {
        var inventory_count: std.atomic.Value(u32) = .init(0);
        var payment_count: std.atomic.Value(u32) = .init(0);

        fn onInventory(event: Event) void {
            _ = event;
            _ = inventory_count.fetchAdd(1, .monotonic);
        }

        fn onPayment(event: Event) void {
            _ = event;
            _ = payment_count.fetchAdd(1, .monotonic);
        }
    };

    var inventory_rt = try ModuleRuntime.init(allocator, std.testing.io, "inventory", .{ .worker_count = 2 });
    defer inventory_rt.deinit();

    var payment_rt = try ModuleRuntime.init(allocator, std.testing.io, "payment", .{ .worker_count = 2 });
    defer payment_rt.deinit();

    var bus = TypedEventBus(Event).init(allocator);
    defer bus.deinit();

    try bus.subscribeAsync(&inventory_rt.worker_pool.?, Ctx.onInventory);
    try bus.subscribeAsync(&payment_rt.worker_pool.?, Ctx.onPayment);

    bus.publish(.{ .order_id = 1 });
    bus.publish(.{ .order_id = 2 });

    const deadline = Time.monotonicNowMilliseconds() + 5000;
    while (Ctx.inventory_count.load(.monotonic) < 2 or Ctx.payment_count.load(.monotonic) < 2) {
        if (Time.monotonicNowMilliseconds() >= deadline) return error.Timeout;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }

    try std.testing.expectEqual(@as(u32, 2), Ctx.inventory_count.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), Ctx.payment_count.load(.monotonic));
}
