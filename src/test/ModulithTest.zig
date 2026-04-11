const std = @import("std");
const Application = @import("../Application.zig").Application;
const EventBus = @import("../core/EventBus.zig").EventBus;
const ModuleInfo = @import("../core/Module.zig").ModuleInfo;

/// ModulithTest - Enhanced testing framework for ZigModu
/// Provides module isolation, event capture, and assertions
///
/// Example:
/// ```zig
/// test "order flow" {
///     var ctx = try ModulithTest(&.{OrderModule}).init(allocator);
///     defer ctx.deinit();
///
///     try ctx.start();
///
///     // Execute business logic
///     const order = try orderService.create(123);
///
///     // Verify events
///     const event = try ctx.expectEvent(OrderCreated);
///     try std.testing.expectEqual(order.id, event.order_id);
/// }
/// ```
pub fn ModulithTest(comptime modules: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        app: Application,
        event_captures: std.StringHashMap(*anyopaque),

        /// Initialize test context
        pub fn init(allocator: std.mem.Allocator) !Self {
            const app = try Application.init(
                allocator,
                "test",
                modules,
                .{ .validate_on_start = true },
            );

            return .{
                .allocator = allocator,
                .app = app,
                .event_captures = std.StringHashMap(*anyopaque).init(allocator),
            };
        }

        /// Clean up test context
        pub fn deinit(self: *Self) void {
            var iter = self.event_captures.iterator();
            while (iter.next()) |entry| {
                // Clean up captured events
                const Capture = entry.value_ptr.*;
                _ = Capture;
            }
            self.event_captures.deinit();
            self.app.deinit();
        }

        /// Start the test application
        pub fn start(self: *Self) !void {
            try self.app.start();
        }

        /// Stop the test application
        pub fn stop(self: *Self) void {
            self.app.stop();
        }

        /// Register event capture for a specific event type
        /// Call this before executing business logic
        pub fn captureEvents(self: *Self, comptime EventType: type) !void {
            const Capture = EventCapture(EventType);
            const capture = try self.allocator.create(Capture);
            capture.* = Capture.init(self.allocator);

            const key = @typeName(EventType);
            try self.event_captures.put(key, capture);
        }

        /// Get event capture for a type
        fn getCapture(self: *Self, comptime EventType: type) ?*EventCapture(EventType) {
            const key = @typeName(EventType);
            const ptr = self.event_captures.get(key) orelse return null;
            return @ptrCast(@alignCast(ptr));
        }

        /// Expect an event of specific type to have been captured
        /// Returns the first captured event
        pub fn expectEvent(self: *Self, comptime EventType: type) !EventType {
            const capture = self.getCapture(EventType) orelse {
                return error.NoEventCaptureConfigured;
            };

            if (capture.events.items.len == 0) {
                return error.EventNotCaptured;
            }

            return capture.events.items[0];
        }

        /// Expect specific number of events
        pub fn expectEventCount(self: *Self, comptime EventType: type, count: usize) !void {
            const capture = self.getCapture(EventType) orelse {
                return error.NoEventCaptureConfigured;
            };

            if (capture.events.items.len != count) {
                std.log.err("Expected {d} events, got {d}", .{
                    count, capture.events.items.len,
                });
                return error.UnexpectedEventCount;
            }
        }

        /// Check if module exists
        pub fn hasModule(self: *Self, name: []const u8) bool {
            return self.app.hasModule(name);
        }

        /// Get module info
        pub fn getModule(self: *Self, name: []const u8) ?ModuleInfo {
            return self.app.getModule(name);
        }
    };
}

/// Event capture buffer for testing
fn EventCapture(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        events: std.ArrayList(T),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .events = std.ArrayList(T).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.events.deinit();
        }

        pub fn capture(self: *Self, event: T) !void {
            try self.events.append(event);
        }

        pub fn getHandler(self: *Self) fn (T) void {
            return struct {
                fn handle(event: T) void {
                    self.capture(event) catch |err| {
                        std.log.err("Event capture failed: {s}", .{@errorName(err)});
                    };
                }
            }.handle;
        }
    };
}

/// Test utilities
pub const TestUtils = struct {
    /// Create a mock event bus for testing
    pub fn createMockEventBus(comptime T: type, allocator: std.mem.Allocator) !EventBus(T) {
        return EventBus(T).init(allocator);
    }

    /// Assert that a module is properly configured
    pub fn assertModuleValid(comptime Module: type) void {
        comptime {
            if (!@hasDecl(Module, "info")) {
                @compileError("Module must have 'info' declaration");
            }

            const info = @field(Module, "info");
            if (info.name.len == 0) {
                @compileError("Module name cannot be empty");
            }
        }
    }

    /// Wait for condition with timeout
    pub fn waitForCondition(
        condition: fn () bool,
        timeout_ms: u64,
    ) !void {
        const start = std.time.milliTimestamp();
        while (!condition()) {
            if (@as(u64, @intCast(std.time.milliTimestamp() - start)) > timeout_ms) {
                return error.Timeout;
            }
            std.time.sleep(1 * std.time.ns_per_ms);
        }
    }
};
