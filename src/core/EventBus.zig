//! Typed event dispatch with infallible subscription model.
//!
//! `EventBus` / `TypedEventBus` are NOT thread-safe — use them from a single
//! thread (or a single fiber with no concurrent access). For concurrent
//! publishers/subscribers, use `ThreadSafeEventBus`, which guards every
//! operation with a mutex.

const std = @import("std");
const Time = @import("Time.zig");
const WorkerPool = @import("WorkerPool.zig").WorkerPool;

const log = std.log.scoped(.event_bus);

/// ListenerSet for O(1) append and linear scan over the listeners.
/// Listeners are kept in an ArrayList instead of a HashMap.
///
/// NOTE: This type is NOT thread-safe. For concurrent access, use ThreadSafeEventBus.
fn ListenerSet(comptime CallbackType: type) type {
    return struct {
        const Self = @This();

        // Listeners live in a flat ArrayList instead of a HashMap — better cache locality.
        list: std.ArrayList(CallbackType),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            var list = std.ArrayList(CallbackType).empty;
            // Hint, not a guarantee: the adders report their own allocation
            // failures. The `appendAssumeCapacity` this reservation used to feed
            // wrote past the list whenever the reservation had failed.
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

/// NOT thread-safe. For concurrent access, use `ThreadSafeEventBus`.
pub fn EventBus(comptime EventType: type) type {
    return struct {
        const Self = @This();
        const CallbackType = *const fn (EventType, *anyopaque) void;

        allocator: std.mem.Allocator,
        listeners: std.AutoHashMap(EventType, ListenerSet(CallbackType)),

        pub fn init(alloc: std.mem.Allocator) Self {
            return initCapacity(alloc, 32);
        }

        /// Init with a capacity hint (expected number of distinct event types).
        /// The reservation is a hint only: a failed `ensureTotalCapacity` is
        /// logged, and `subscribe` then grows the map or reports
        /// `error.OutOfMemory`. It cannot be a guarantee — nothing bounds how many
        /// distinct event types a caller subscribes, and the constructor has no
        /// error channel to report a short reservation through.
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

        /// Registers `callback` for `event_type`.
        ///
        /// Fallible, because both growth paths can need the allocator: the
        /// event-type map (nothing bounds how many distinct event types a caller
        /// subscribes, and `initCapacity`'s reservation only *logs* its failure)
        /// and the per-type listener list (its 4 slots are reserved the same
        /// way). The `getOrPutAssumeCapacity` / `addAssumeCapacity` pair this
        /// replaces wrote past unreserved storage in exactly those cases instead
        /// of reporting anything. `error.OutOfMemory` means the listener is NOT
        /// registered; a failed subscribe can leave an empty listener set behind
        /// for that event type, which reads the same as nobody having subscribed.
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

/// NOT thread-safe. For concurrent access, use `ThreadSafeEventBus`.
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
///
/// Cancelation policy: the entry points that have an error channel
/// (`subscribe`, `subscribeAsync` — both `!void`) report `error.Canceled` when
/// their lock wait is canceled, because the caller can act on that. The
/// `void`-returning and value-returning ones (`publish`, `unsubscribe`,
/// `subscriberCount`, `publishedCount`) wait uncancelably instead, because
/// skipping the critical section silently would either lose an event or a
/// subscription for good, or answer a fabricated `0` the caller reads as truth.
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

        /// The lock wait is a cancelation point this signature can report:
        /// `error.Canceled` means the listener is NOT registered. Swallowing it
        /// returned success without subscribing — a caller that later awaits an
        /// event that never arrives had been told the subscription was in place.
        pub fn subscribe(self: *Self, listener: TypedEventBus(T).CallbackType) !void {
            try self.mu.lock(self.io);
            defer self.mu.unlock(self.io);
            try self.bus.subscribe(listener);
        }

        /// Same contract as `subscribe`: a canceled wait is reported, never
        /// turned into a success.
        pub fn subscribeAsync(self: *Self, pool: *WorkerPool, listener: TypedEventBus(T).CallbackType) !void {
            try self.mu.lock(self.io);
            defer self.mu.unlock(self.io);
            try self.bus.subscribeAsync(pool, listener);
        }

        /// Uncancelable — this has no error channel, and a swallowed failure
        /// would leave the listener attached after the caller believes it is
        /// gone (the callback keeps firing, and its context may already be
        /// freed). The critical section is an O(1) list removal, so the wait is
        /// bounded by whichever callback is in flight.
        pub fn unsubscribe(self: *Self, listener: TypedEventBus(T).CallbackType) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.bus.unsubscribe(listener);
        }

        /// Publish an event to all subscribers.
        ///
        /// NOTE: The mutex is held for the duration of all listener callbacks.
        /// Keep listener handlers short (non-blocking). For long-running work,
        /// have listeners enqueue to a worker instead of processing inline.
        ///
        /// Uncancelable, and it has to be: this returns `void`, so a canceled
        /// lock wait can only answer one of two ways — block until the critical
        /// section is free, or return having delivered the event to nobody. The
        /// second is a fabricated success on the application event bus
        /// (`Application.eventBus` / `ModuleContext.eventBus`, and
        /// `CrudService`'s created/updated/deleted events), so this waits. The
        /// critical section is the callbacks themselves: the wait is bounded by
        /// the handlers, hence the note above.
        pub fn publish(self: *Self, event: T) void {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            self.bus.publish(event);
        }

        /// Uncancelable for the same reason as `publish`: a reader that gives up
        /// on the lock would report `0` subscribers while they exist, and a
        /// caller that reads `0` as "nobody will hear this" is being lied to.
        /// (The answer used to be a literal `0` on a canceled wait.)
        pub fn subscriberCount(self: *Self) usize {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            return self.bus.subscriberCount();
        }

        pub fn publishedCount(self: *Self) u64 {
            self.mu.lockUncancelable(self.io);
            defer self.mu.unlock(self.io);
            return self.bus.publishedCount();
        }
    };
}

/// Unified event bus — always typed. For untyped usage, pass `void`.
/// Single-threaded only; concurrent publishers must use `ThreadSafeEventBus`.
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

// The two tests below pin the shape of `ThreadSafeEventBus`'s critical section
// against cancelation. The lock wait is their cancelation point: the task is
// parked on the bus mutex (held by the test thread) with a cancel request
// already placed on its thread, and the gate before the call is pure spinning,
// which consumes nothing. Same idiom as `im.BufferPool`'s canceled-lock-wait
// tests, which is where the pattern is documented.
//
// `publish` has no error channel, so a canceled wait must not be able to answer
// it: a bus that returns from `publish` without entering the critical section
// reports "delivered" while the event went to nobody, and `CrudService` publishes
// its created/updated/deleted events exactly this way.
test "ThreadSafeEventBus publish does not lose the event to a canceled lock wait" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Event = struct { value: i32 };

    const Ctx = struct {
        var received = std.atomic.Value(i32).init(0);
        fn onEvent(event: Event) void {
            _ = received.fetchAdd(event.value, .monotonic);
        }
    };

    const Task = struct {
        var done = std.atomic.Value(bool).init(false);
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn publish(bus: *ThreadSafeEventBus(Event)) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            bus.publish(.{ .value = 7 });
            done.store(true, .release);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var bus = ThreadSafeEventBus(Event).init(allocator, io);
    defer bus.deinit();
    try bus.subscribe(Ctx.onEvent);

    Ctx.received.store(0, .monotonic);
    Task.done.store(false, .monotonic);
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    // The test thread holds the bus mutex, so the task cannot get past the lock
    // wait until told to.
    try bus.mu.lock(io);

    var task_fut = try io.concurrent(Task.publish, .{&bus});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    // Give the request time to land while the task is still gated.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    // The task is now inside `publish`: parked on the mutex (it swaps the state
    // to `contended` on its way to the wait), or already gone.
    while (bus.mu.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    // A cancelable wait gives up here; an uncancelable one is still parked.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake);
    try std.testing.expect(!Task.done.load(.acquire));

    bus.mu.unlock(io);
    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(i32, 7), Ctx.received.load(.monotonic));
}

// `subscribe` does have an error channel, so the honest answer to a canceled
// wait is `error.Canceled` — "returns success without registering" is a
// correctness bug the caller cannot see.
test "ThreadSafeEventBus subscribe reports a canceled lock wait as error.Canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Event = struct { value: i32 };

    const Ctx = struct {
        fn onEvent(_: Event) void {}
    };

    const Task = struct {
        var err: ?anyerror = null;
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn subscribe(bus: *ThreadSafeEventBus(Event)) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            bus.subscribe(Ctx.onEvent) catch |e| {
                err = e;
                return;
            };
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var bus = ThreadSafeEventBus(Event).init(allocator, io);
    defer bus.deinit();

    Task.err = null;
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    try bus.mu.lock(io);

    var task_fut = try io.concurrent(Task.subscribe, .{&bus});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (bus.mu.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    bus.mu.unlock(io);

    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Task.err);
    // The failure was real: nothing was registered behind the caller's back.
    try std.testing.expectEqual(@as(usize, 0), bus.subscriberCount());
}

// The untyped bus's `subscribe` was documented as infallible — "capacity
// pre-allocated in initCapacity" — and backed by `getOrPutAssumeCapacity` /
// `addAssumeCapacity`. The premise does not hold: `initCapacity` and
// `ListenerSet.init` only *log* a failed `ensureTotalCapacity`. Red evidence on
// that shape: this test aborted the binary with `panic: integer overflow` inside
// `subscribe` (the zero-capacity map's `capacity() - 1`) right after
// `[EventBus] listeners capacity prealloc failed: error.OutOfMemory`. Sweeping
// `fail_index` walks a failure through each allocation of `initCapacity` plus the
// first subscribe; the contract now is "the listener is registered, or you get
// `error.OutOfMemory`".
test "untyped EventBus subscribe registers the listener or reports OutOfMemory" {
    const allocator = std.testing.allocator;
    const E = enum { a };
    const Ctx = struct {
        var received = std.atomic.Value(u32).init(0);
        fn onEvent(event: E, _: *anyopaque) void {
            _ = event;
            _ = received.fetchAdd(1, .monotonic);
        }
    };

    var payload: u8 = 0;
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var bus = EventBus(E).initCapacity(failing.allocator(), 4);
        defer bus.deinit();

        Ctx.received.store(0, .monotonic);
        bus.subscribe(.a, Ctx.onEvent) catch |err| {
            try std.testing.expectEqual(@as(anyerror, error.OutOfMemory), err);
            // A failed subscribe registers nothing — there is no half
            // subscription that would fire the callback with the caller none the
            // wiser.
            try std.testing.expectEqual(@as(usize, 0), bus.subscriberCount(.a));
            continue;
        };
        try std.testing.expectEqual(@as(usize, 1), bus.subscriberCount(.a));
        bus.publish(.a, &payload);
        try std.testing.expectEqual(@as(u32, 1), Ctx.received.load(.monotonic));
    }
}
