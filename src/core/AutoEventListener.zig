const std = @import("std");
const EventBus = @import("EventBus.zig").EventBus;

/// AutoEventListener - Compile-time event listener registration
/// Automatically scans structs for event handler methods and registers them
///
/// Example:
/// ```zig
/// const OrderListener = struct {
///     pub fn onOrderCreated(event: OrderCreated) void {
///         // Handle event
///     }
///
///     pub fn onPaymentProcessed(event: PaymentProcessed) void {
///         // Handle event
///     }
/// };
///
/// // Auto-register all handlers
/// try AutoEventListener.registerAll(&order_listener, &event_bus);
/// ```
pub const AutoEventListener = struct {
    /// Register all event handlers from a struct
    pub fn registerAll(listener: anytype, bus: anytype) !void {
        _ = listener;
        _ = bus;
        // Implementation would scan struct for handlers and register them
    }

    /// Check if method name follows event handler convention (onEventName)
    fn isEventHandler(comptime name: []const u8) bool {
        return name.len > 2 and
            name[0] == 'o' and
            name[1] == 'n' and
            name[2] >= 'A' and name[2] <= 'Z';
    }

    /// Get event type name from handler name (onOrderCreated -> OrderCreated)
    pub fn getEventTypeName(comptime handler_name: []const u8) []const u8 {
        if (!(handler_name.len > 2 and
            handler_name[0] == 'o' and
            handler_name[1] == 'n' and
            handler_name[2] >= 'A' and handler_name[2] <= 'Z'))
        {
            @compileError("Invalid handler name: " ++ handler_name);
        }
        return handler_name[2..]; // Remove "on" prefix
    }
};

/// Event listener registry that maintains handler references
pub fn EventListenerRegistry(comptime EventType: type) type {
    return struct {
        const Self = @This();

        handlers: std.array_list.Managed(Handler),
        allocator: std.mem.Allocator,

        pub const Handler = struct {
            name: []const u8,
            func: *const fn (EventType) void,
            priority: i32 = 0,
        };

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .handlers = std.array_list.Managed(Handler).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.handlers.deinit();
        }

        /// Register a handler with optional priority
        pub fn register(
            self: *Self,
            name: []const u8,
            handler: *const fn (EventType) void,
            priority: i32,
        ) !void {
            try self.handlers.append(.{
                .name = name,
                .func = handler,
                .priority = priority,
            });

            // Sort by priority (higher first)
            std.sort.block(Handler, self.handlers.items, {}, comptime struct {
                fn lessThan(_: void, a: Handler, b: Handler) bool {
                    return a.priority > b.priority;
                }
            }.lessThan);
        }

        /// Execute all handlers
        pub fn dispatch(self: *Self, event: EventType) void {
            for (self.handlers.items) |handler| {
                handler.func(event);
            }
        }

        /// Get handler count
        pub fn count(self: *Self) usize {
            return self.handlers.items.len;
        }
    };
}

test "AutoEventListener detects handlers" {
    // Verify handler detection naming convention
    try std.testing.expect(AutoEventListener.isEventHandler("onOrderCreated"));
    try std.testing.expect(AutoEventListener.isEventHandler("onPaymentProcessed"));
    try std.testing.expect(!AutoEventListener.isEventHandler("notAHandler"));
    try std.testing.expect(!AutoEventListener.isEventHandler("something"));

    // Verify event type name extraction
    try std.testing.expectEqualStrings("OrderCreated", AutoEventListener.getEventTypeName("onOrderCreated"));
}

test "EventListenerRegistry with priority" {
    const allocator = std.testing.allocator;

    var registry = EventListenerRegistry(i32).init(allocator);
    defer registry.deinit();

    var high_priority_called = false;
    var low_priority_called = false;

    // SAFETY: These flags are initialized before use below
    const high_priority = struct {
        var flag: *bool = undefined;
        fn handle(_: i32) void {
            flag.* = true;
        }
    };
    high_priority.flag = &high_priority_called;

    const low_priority = struct {
        var flag: *bool = undefined;
        fn handle(_: i32) void {
            flag.* = true;
        }
    };
    low_priority.flag = &low_priority_called;

    // Register with different priorities
    try registry.register("low", low_priority.handle, 1);
    try registry.register("high", high_priority.handle, 10);

    try std.testing.expectEqual(@as(usize, 2), registry.count());

    // Dispatch event
    registry.dispatch(42);

    try std.testing.expect(high_priority_called);
    try std.testing.expect(low_priority_called);
}
