//! Type-erased registry of per-event-type buses.
//!
//! `EventBus(T)` is generic over the event type, so an `Application` cannot
//! hold "the" bus — this registry keys buses by `@typeName(T)` and hands out
//! `*ThreadSafeEventBus(T)`. Framework-level guarantee: the registry only
//! ever creates the thread-safe variant, so concurrent publishers in HTTP
//! handlers are safe by construction (bare `EventBus`/`TypedEventBus` remain
//! available for explicitly single-threaded use).

const std = @import("std");
const EventBus = @import("EventBus.zig");

const BusEntry = struct {
    ptr: *anyopaque,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

pub const EventRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    mu: std.Io.Mutex = .init,
    buses: std.StringHashMap(BusEntry),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) EventRegistry {
        return .{
            .allocator = allocator,
            .io = io,
            .buses = std.StringHashMap(BusEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.buses.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.destroy(entry.value_ptr.ptr, self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.buses.deinit();
        self.* = undefined;
    }

    /// Get or create the shared bus for event type `T`. Creation is
    /// mutex-guarded; the returned pointer is stable for the registry's
    /// lifetime and may be published/subscribed from any thread.
    ///
    /// The lock wait is a cancelation point this signature can report:
    /// `std.Io.Mutex.lock` fails only with `error.Canceled`, so the old
    /// `catch return error.LockFailed` reported lock-machinery failure for a
    /// cancelation — a caller cannot tell "unwind, you were canceled" from "this
    /// registry's lock is broken". Nothing is at stake in the abandoned critical
    /// section (it is taken before any bus is created, so no half-built bus is
    /// left behind); the honest answer is the cancelation itself. Red:
    /// `core.EventRegistry.test.bus() reports a canceled lock wait as
    /// error.Canceled` reads `expected error.Canceled, found error.LockFailed`.
    pub fn bus(self: *Self, comptime T: type) !*EventBus.ThreadSafeEventBus(T) {
        const key = @typeName(T);
        try self.mu.lock(self.io);
        defer self.mu.unlock(self.io);

        if (self.buses.get(key)) |entry| {
            return @ptrCast(@alignCast(entry.ptr));
        }

        const b = try self.allocator.create(EventBus.ThreadSafeEventBus(T));
        errdefer self.allocator.destroy(b);
        b.* = EventBus.ThreadSafeEventBus(T).init(self.allocator, self.io);

        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);

        try self.buses.put(owned_key, .{
            .ptr = b,
            .destroy = struct {
                fn d(p: *anyopaque, a: std.mem.Allocator) void {
                    const typed: *EventBus.ThreadSafeEventBus(T) = @ptrCast(@alignCast(p));
                    typed.deinit();
                    a.destroy(typed);
                }
            }.d,
        });
        return b;
    }

    pub fn busCount(self: *Self) usize {
        return self.buses.count();
    }
};

test "EventRegistry get-or-create is identity-stable per type" {
    const allocator = std.testing.allocator;
    var reg = EventRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    const E1 = struct { id: i64 };
    const E2 = struct { name: []const u8 };

    const a1 = try reg.bus(E1);
    const a2 = try reg.bus(E1);
    const b1 = try reg.bus(E2);

    try std.testing.expect(a1 == a2); // same type → same bus
    try std.testing.expect(@as(*anyopaque, a1) != @as(*anyopaque, b1)); // distinct types isolated
    try std.testing.expectEqual(@as(usize, 2), reg.busCount());
}

test "EventRegistry bus delivers events to subscribers" {
    const allocator = std.testing.allocator;
    var reg = EventRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    const E = struct { id: i64 };
    const Ctx = struct {
        var received: i64 = 0;
        fn onEvent(e: E) void {
            received = e.id;
        }
    };

    const bus = try reg.bus(E);
    try bus.subscribe(Ctx.onEvent);
    bus.publish(.{ .id = 42 });
    try std.testing.expectEqual(@as(i64, 42), Ctx.received);
}

// `bus()` answered a canceled lock with `error.LockFailed`. Nothing is fabricated
// by that name — no bus is created behind the caller's back — but it is the wrong
// fact: `std.Io.Mutex.lock` fails only with `error.Canceled`, so a cancelation was
// reported as lock-machinery failure, and the caller cannot tell "unwind, you were
// canceled" from "this registry's lock is broken". The error set is inferred, so
// naming the truth costs no call site (`Application.eventBus` and
// `ModuleContext.eventBus` just `try` it).
test "EventRegistry bus() reports a canceled lock wait as error.Canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const E = struct { id: i64 };

    const Task = struct {
        var err: ?anyerror = null;
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn get(reg: *EventRegistry) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            _ = reg.bus(E) catch |e| {
                err = e;
                return;
            };
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var reg = EventRegistry.init(allocator, io);
    defer reg.deinit();

    Task.err = null;
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    // The test thread holds the registry mutex, so the task parks on the lock
    // wait and the cancelation is delivered there. Same idiom as the
    // canceled-lock-wait tests in `core/EventBus.zig` / `core/EventStore.zig`.
    try reg.mu.lock(io);

    var task_fut = try io.concurrent(Task.get, .{&reg});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (reg.mu.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    reg.mu.unlock(io);

    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Task.err);
    // The failure was real: no bus was created behind the caller's back.
    try std.testing.expectEqual(@as(usize, 0), reg.busCount());
}
