const std = @import("std");

/// Event metadata for declarative publishing
pub const EventMetadata = struct {
    event_type: []const u8,
    description: []const u8 = "",
    transactional: bool = false,
    async_delivery: bool = false,
};

/// Trait for types that can be published as events
pub fn PublishableEvent(comptime T: type) type {
    return struct {
        pub const is_event = true;
        pub const metadata = EventMetadata{
            .event_type = @typeName(T),
            .description = "Auto-generated event metadata",
        };

        /// Get event metadata
        pub fn getMetadata() EventMetadata {
            if (@hasDecl(T, "event_metadata")) {
                return @field(T, "event_metadata");
            }
            return metadata;
        }
    };
}

/// Event bus type (forward declaration)
fn EventBus(comptime T: type) type {
    return @import("EventBus.zig").EventBus(T);
}

/// Event publisher mixin - provides event publishing capabilities
/// Usage:
/// ```zig
/// const MyService = struct {
///     pub usingnamespace EventPublisherMixin(&.{MyEvent});
///
///     pub fn doSomething(self: *@This(), bus: anytype) !void {
///         try self.publishEvent(MyEvent{...}, bus);
///     }
/// };
/// ```
pub fn EventPublisherMixin(comptime EventTypes: anytype) type {
    return struct {
        /// Publish an event to the configured event bus
        pub fn publishEvent(self: anytype, event: anytype, bus: anytype) !void {
            _ = self;
            const EventType = @TypeOf(event);
            const BusType = @TypeOf(bus);

            // Validate event type is registered
            comptime var found = false;
            inline for (EventTypes) |ET| {
                if (EventType == ET) found = true;
            }

            if (!comptime found) {
                @compileError("Event type not registered. Add to EventTypes tuple.");
            }

            // Validate bus type matches event type (TypedEventBus publishes a
            // single event value).
            const ExpectedBus = @import("EventBus.zig").TypedEventBus(EventType);
            if (BusType != ExpectedBus and BusType != *ExpectedBus) {
                @compileError("Event bus type mismatch for event");
            }

            bus.publish(event);
        }

        /// Validate that a type is a registered event
        pub fn isValidEvent(comptime T: type) bool {
            comptime var found = false;
            inline for (EventTypes) |ET| {
                if (T == ET) found = true;
            }
            return found;
        }
    };
}

/// Compile-time event registry
pub const EventRegistry = struct {
    /// Register an event type at compile time
    pub fn register(comptime T: type) void {
        _ = PublishableEvent(T);
    }

    /// Check if type is a registered event
    pub fn isRegistered(comptime T: type) bool {
        return @hasDecl(T, "is_event");
    }
};

test "EventPublisherMixin publishes registered events and validates" {
    const MyEvent = struct { id: u32 };
    var bus = @import("EventBus.zig").TypedEventBus(MyEvent).init(std.testing.allocator);
    defer bus.deinit();
    const State = struct {
        var seen: u32 = 0;
    };
    try bus.subscribe(struct {
        fn cb(e: MyEvent) void {
            State.seen = e.id;
        }
    }.cb);

    const Mixin = EventPublisherMixin(&.{MyEvent});
    try Mixin.publishEvent(&.{}, MyEvent{ .id = 42 }, &bus);
    try std.testing.expectEqual(@as(u32, 42), State.seen);
    try std.testing.expect(Mixin.isValidEvent(MyEvent));
    try std.testing.expect(!Mixin.isValidEvent(u32));
}

test "PublishableEvent metadata honors custom event_metadata" {
    const Custom = struct {
        pub const event_metadata = EventMetadata{
            .event_type = "custom.event",
            .transactional = true,
        };
    };
    const Plain = struct {};
    try std.testing.expectEqualStrings("custom.event", PublishableEvent(Custom).getMetadata().event_type);
    try std.testing.expect(PublishableEvent(Custom).getMetadata().transactional);
    try std.testing.expectEqualStrings(@typeName(Plain), PublishableEvent(Plain).getMetadata().event_type);
}
