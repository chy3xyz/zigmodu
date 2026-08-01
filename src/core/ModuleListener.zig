const std = @import("std");
const EventBus = @import("./EventBus.zig").EventBus;

/// @ApplicationModuleListener [...]
/// for[...]Module event[...]Transaction[...]Feature
pub fn ApplicationModuleListener(comptime EventType: type) type {
    return struct {
        const Self = @This();

        /// [...]
        pub const Config = struct {
            async_mode: bool = true,
            transactional: bool = false,
            condition: ?[]const u8 = null,
        };

        config: Config,
        handler: *const fn (EventType) anyerror!void,
        event_bus: *EventBus(EventType),
        event_type: EventType,

        pub fn init(
            event_bus: *EventBus(EventType),
            handler: *const fn (EventType) anyerror!void,
            config: Config,
            event_type: EventType,
        ) Self {
            return .{
                .event_bus = event_bus,
                .handler = handler,
                .config = config,
                .event_type = event_type,
            };
        }

        /// Subscribe event
        pub fn subscribe(self: *Self) !void {
            const handler_ptr = self.handler;

            const S = struct {
                var current_handler: ?*const fn (EventType) anyerror!void = null;
                fn wrapper(event: EventType, _: *anyopaque) void {
                    if (current_handler) |h| {
                        h(event) catch |err| std.log.err("Event handler failed: {}", .{err});
                    }
                }
            };
            S.current_handler = handler_ptr;
            _ = self.config.async_mode; // delivery mode is informational

            self.event_bus.subscribe(self.event_type, S.wrapper);
        }

        /// [...]
        pub fn unsubscribe(self: *Self) void {
            _ = self;
            // [...]
        }
    };
}

/// Module event[...]
/// [...]Event[...]
pub const ModuleListenerRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    listeners: std.StringHashMap(ListenerInfo),

    pub const ListenerInfo = struct {
        module_name: []const u8,
        event_type: []const u8,
        handler_ptr: *anyopaque,
        is_async: bool,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .listeners = std.StringHashMap(ListenerInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.listeners.deinit();
        self.* = undefined;
    }

    /// [...]
    pub fn registerListener(
        self: *Self,
        module_name: []const u8,
        event_type: []const u8,
        handler: *anyopaque,
        is_async: bool,
    ) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name, event_type });
        defer self.allocator.free(key);

        try self.listeners.put(key, .{
            .module_name = module_name,
            .event_type = event_type,
            .handler_ptr = handler,
            .is_async = is_async,
        });
    }

    /// Get all module listeners
    pub fn getModuleListeners(self: *Self, module_name: []const u8) !std.ArrayList(ListenerInfo) {
        // Validate input
        if (module_name.len == 0) return error.InvalidModuleName;

        var result = std.ArrayList(ListenerInfo).empty;
        errdefer result.deinit(self.allocator);

        var iter = self.listeners.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.module_name, module_name)) {
                try result.append(self.allocator, entry.value_ptr.*);
            }
        }

        return result;
    }
};

test "ApplicationModuleListener subscribes and receives published events" {
    const EventType = enum { order_created, order_cancelled };
    var bus = EventBus(EventType).init(std.testing.allocator);
    defer bus.deinit();
    const State = struct {
        var handled: ?EventType = null;
    };
    const Listener = ApplicationModuleListener(EventType);
    var listener = Listener.init(
        &bus,
        struct {
            fn h(event: EventType) anyerror!void {
                State.handled = event;
            }
        }.h,
        .{ .async_mode = false },
        .order_created,
    );
    try listener.subscribe();

    var payload: u8 = 0;
    bus.publish(.order_created, &payload);
    try std.testing.expectEqual(EventType.order_created, State.handled.?);

    // A different event type does not reach this listener.
    State.handled = null;
    bus.publish(.order_cancelled, &payload);
    try std.testing.expectEqual(@as(?EventType, null), State.handled);
}

/// Event[...]
/// [...]Eventpublish[...]Message queue[...]
pub const EventExternalization = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    externalizers: std.ArrayList(Externalizer),

    pub const Externalizer = struct {
        name: []const u8,
        can_handle: *const fn ([]const u8) bool,
        externalize: *const fn ([]const u8, []const u8) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .externalizers = std.ArrayList(Externalizer).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.externalizers.deinit(self.allocator);
        self.* = undefined;
    }

    /// [...]
    pub fn registerExternalizer(self: *Self, externalizer: Externalizer) !void {
        try self.externalizers.append(self.allocator, externalizer);
    }

    /// [...]Event
    pub fn externalize(self: *Self, event_type: []const u8, event_data: []const u8) !void {
        for (self.externalizers.items) |externalizer| {
            if (externalizer.can_handle(event_type)) {
                try externalizer.externalize(event_type, event_data);
                return;
            }
        }

        // No suitable externalizer found
        std.log.warn("No externalizer found for event type: {s}", .{event_type});
    }
};
