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
    pub fn bus(self: *Self, comptime T: type) !*EventBus.ThreadSafeEventBus(T) {
        const key = @typeName(T);
        self.mu.lock(self.io) catch return error.LockFailed;
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
