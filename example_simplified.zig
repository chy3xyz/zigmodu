const std = @import("std");
const zigmodu = @import("zigmodu");

/// Example 1: Simple module with the new simplified API
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Create application
    var app = zigmodu.App.init(allocator);
    defer app.deinit();

    // Define business modules
    const UserModule = struct {
        _app: *zigmodu.App = undefined,

        pub fn name(self: *@This()) []const u8 {
            _ = self;
            return "user";
        }

        pub fn init(self: *@This(), a: *zigmodu.App) !void {
            self._app = a;
            std.log.info("[UserModule] Initialized", .{});
        }

        pub fn start(self: *@This()) !void {
            _ = self;
            std.log.info("[UserModule] Started", .{});
        }

        pub fn stop(self: *@This()) void {
            _ = self;
            std.log.info("[UserModule] Stopped", .{});
        }

        pub fn onEvent(self: *@This(), event: zigmodu.Event) void {
            _ = self;
            switch (event) {
                .module_start => |e| {
                    std.log.info("[UserModule] Saw module start: {s}", .{e.module_name});
                },
                else => {},
            }
        }
    };

    const OrderModule = struct {
        _app: *zigmodu.App = undefined,

        pub fn name(self: *@This()) []const u8 {
            _ = self;
            return "order";
        }

        pub fn init(self: *@This(), a: *zigmodu.App) !void {
            self._app = a;
            std.log.info("[OrderModule] Initialized", .{});
        }

        pub fn start(self: *@This()) !void {
            std.log.info("[OrderModule] Started", .{});
            // Publish an event
            self._app.publish(.{ .module_start = .{
                .module_name = "order-created",
                .timestamp = 0,
            } });
        }

        pub fn stop(self: *@This()) void {
            _ = self;
            std.log.info("[OrderModule] Stopped", .{});
        }

        pub fn onEvent(self: *@This(), event: zigmodu.Event) void {
            _ = self;
            switch (event) {
                .module_start => |e| {
                    std.log.info("[OrderModule] Saw module start: {s}", .{e.module_name});
                },
                else => {},
            }
        }
    };

    // Create module instances
    var user_mod = UserModule{};
    var order_mod = OrderModule{};

    // Register modules using ModuleImpl helper
    try app.register(zigmodu.ModuleImpl(UserModule).interface(&user_mod));
    try app.register(zigmodu.ModuleImpl(OrderModule).interface(&order_mod));

    // Start all modules
    try app.start();

    // Stop all modules
    app.stop();
}

/// Example 2: Module with dependencies
const InventoryModule = struct {
    _app: *zigmodu.App = undefined,

    pub fn name(self: *@This()) []const u8 {
        _ = self;
        return "inventory";
    }

    pub fn dependencies(self: *@This()) []const []const u8 {
        _ = self;
        return &.{
            "user", // Depends on user module
            "order", // Depends on order module
        };
    }

    pub fn init(self: *@This(), app: *zigmodu.App) !void {
        self._app = app;
        std.log.info("[InventoryModule] Initialized", .{});
    }

    pub fn start(self: *@This()) !void {
        _ = self;
        std.log.info("[InventoryModule] Started", .{});
    }

    pub fn stop(self: *@This()) void {
        _ = self;
        std.log.info("[InventoryModule] Stopped", .{});
    }

    pub fn onEvent(self: *@This(), event: zigmodu.Event) void {
        _ = self;
        _ = event;
    }
};

/// Example 3: Using old API (backward compatible)
const LegacyModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "legacy",
        .description = "Legacy style module",
        .dependencies = &.{},
    };

    pub fn init() !void {
        std.log.info("[LegacyModule] Initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("[LegacyModule] Deinitialized", .{});
    }
};

// Example 4: Full enterprise features
test "Enterprise example" {
    const allocator = std.testing.allocator;

    // Create app
    var app = zigmodu.App.init(allocator);
    defer app.deinit();

    // Add metrics
    var metrics = zigmodu.PrometheusMetrics.init(allocator);
    defer metrics.deinit();

    // Add tracing
    var tracer = try zigmodu.DistributedTracer.init(allocator, "test", "service");
    defer tracer.deinit();

    // Add auto instrumentation
    const auto_inst = try zigmodu.AutoInstrumentation.init(allocator, &metrics, &tracer);
    _ = auto_inst;

    // Use DI container
    var container = zigmodu.Container.init(allocator);
    defer container.deinit();

    var service: i32 = 42;
    try container.register("answer", &service, i32);

    const retrieved = container.get("answer", i32);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 42), retrieved.?.*);
}
