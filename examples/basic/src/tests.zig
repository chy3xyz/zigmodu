const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example 4: Testing with ZigModu
// ============================================
// Demonstrates: ModuleTestContext, mock modules, Application lifecycle and
// dependency validation. Run with: zig build test

// Module under test
const CalculatorModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "calculator",
        .description = "Simple calculator for testing demo",
        .dependencies = &.{},
    };

    var initialized = false;

    pub fn init() !void {
        initialized = true;
    }

    pub fn deinit() void {
        initialized = false;
    }

    pub fn add(a: i32, b: i32) i32 {
        return a + b;
    }

    pub fn subtract(a: i32, b: i32) i32 {
        return a - b;
    }

    pub fn multiply(a: i32, b: i32) i32 {
        return a * b;
    }

    pub fn divide(a: i32, b: i32) !i32 {
        if (b == 0) return error.DivisionByZero;
        return @divTrunc(a, b);
    }

    pub fn isInitialized() bool {
        return initialized;
    }
};

// Service layer depending on the module above
const CalculatorService = struct {
    pub const info = zigmodu.api.Module{
        .name = "calculator_service",
        .description = "Service layer using calculator",
        .dependencies = &.{"calculator"},
    };

    pub fn init() !void {}
    pub fn deinit() void {}
};

test "module lifecycle: start runs init, stop runs deinit" {
    try std.testing.expect(!CalculatorModule.isInitialized());

    var app = try zigmodu.Application.init(
        std.testing.io,
        std.testing.allocator,
        "lifecycle",
        .{CalculatorModule},
        .{ .validate_on_start = true },
    );
    defer app.deinit();

    try app.start();
    try std.testing.expect(CalculatorModule.isInitialized());

    app.stop();
    try std.testing.expect(!CalculatorModule.isInitialized());
}

test "mock module can be registered and looked up" {
    var ctx = try zigmodu.ModuleTestContext.init(std.testing.allocator, "mock_calculator");
    defer ctx.deinit();

    try ctx.registerMockModule(zigmodu.createMockModule(
        "mock_calculator",
        "Mock calculator for testing",
        &.{},
    ));

    const module = ctx.modules.get("mock_calculator");
    try std.testing.expect(module != null);
    try std.testing.expectEqualStrings("mock_calculator", module.?.name);
}

test "calculator basic operations" {
    var app = try zigmodu.Application.init(
        std.testing.io,
        std.testing.allocator,
        "test",
        .{CalculatorModule},
        .{},
    );
    defer app.deinit();

    try app.start();

    try std.testing.expectEqual(@as(i32, 15), CalculatorModule.add(10, 5));
    try std.testing.expectEqual(@as(i32, 5), CalculatorModule.subtract(10, 5));
    try std.testing.expectEqual(@as(i32, 50), CalculatorModule.multiply(10, 5));
    try std.testing.expectEqual(@as(i32, 2), try CalculatorModule.divide(10, 5));
}

test "calculator division by zero" {
    var app = try zigmodu.Application.init(
        std.testing.io,
        std.testing.allocator,
        "test",
        .{CalculatorModule},
        .{},
    );
    defer app.deinit();

    try app.start();

    const result = CalculatorModule.divide(10, 0);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "module dependency validation" {
    // Succeeds because calculator_service declares calculator as a dependency
    var app = try zigmodu.Application.init(
        std.testing.io,
        std.testing.allocator,
        "test",
        .{ CalculatorModule, CalculatorService },
        .{ .validate_on_start = true },
    );
    defer app.deinit();

    try app.start();
    try std.testing.expectEqual(zigmodu.Application.State.started, app.getState());
}
