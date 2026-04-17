const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example 4: Testing with ZigModu
// ============================================
// Demonstrates: Module testing, mocking, event testing

// 被测试的模块
const CalculatorModule = struct {
    pub const info = zigmodu.api.Module{
        .name = "calculator",
        .description = "Simple calculator for testing demo",
        .dependencies = &.{},
    };

    var initialized = false;

    pub fn init() !void {
        initialized = true;
        std.log.info("[calculator] Initialized", .{});
    }

    pub fn deinit() void {
        initialized = false;
        std.log.info("[calculator] Deinitialized", .{});
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

// 依赖其他模块的服务
const CalculatorService = struct {
    pub const info = zigmodu.api.Module{
        .name = "calculator_service",
        .description = "Service layer using calculator",
        .dependencies = &.{"calculator"},
    };

    pub fn init() !void {
        std.log.info("[calculator_service] Initialized", .{});
    }

    pub fn deinit() void {
        std.log.info("[calculator_service] Deinitialized", .{});
    }

    pub fn calculateExpression(expr: []const u8) !i32 {
        // 简化的表达式解析器
        _ = expr;
        // 实际实现会解析表达式并调用 calculator
        return 42; // 占位符
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    std.log.info("=== ZigModu Testing Example ===", .{});
    std.log.info("Run with: zig build test\n", .{});

    // 运行测试
    try testModuleLifecycle(allocator);
    try testCalculatorOperations(init.io, allocator);
    try testWithMockModule(init.io, allocator);
}

fn testModuleLifecycle(allocator: std.mem.Allocator) !void {
    std.log.info("Test 1: Module Lifecycle", .{});

    // 使用 ModuleTestContext 测试模块
    var ctx = try zigmodu.extensions.ModuleTestContext.init(allocator, "calculator");
    defer ctx.deinit();

    // 注册模块
    const mock = zigmodu.extensions.createMockModule(
        "calculator",
        "Calculator for testing",
        &.{},
    );
    try ctx.registerMockModule(mock);

    // 测试启动前
    std.log.info("  Before start: initialized = {s}", .{if (CalculatorModule.isInitialized()) "true" else "false"});
    try std.testing.expect(!CalculatorModule.isInitialized());

    // 启动模块
    try ctx.start();
    std.log.info("  After start: initialized = {s}", .{if (CalculatorModule.isInitialized()) "true" else "false"});
    try std.testing.expect(CalculatorModule.isInitialized());

    // 停止模块
    ctx.stop();
    std.log.info("  After stop: initialized = {s}", .{if (CalculatorModule.isInitialized()) "true" else "false"});
    try std.testing.expect(!CalculatorModule.isInitialized());

    std.log.info("  ✓ Lifecycle test passed\n", .{});
}

fn testCalculatorOperations(io: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("Test 2: Calculator Operations", .{});

    var app = try zigmodu.Application.init(io,
        allocator,
        "test-app",
        .{CalculatorModule},
        .{ .validate_on_start = false },
    );
    defer app.deinit();

    try app.start();

    // 测试加法
    const sum = CalculatorModule.add(5, 3);
    try std.testing.expectEqual(@as(i32, 8), sum);
    std.log.info("  5 + 3 = {d} ✓", .{sum});

    // 测试减法
    const diff = CalculatorModule.subtract(10, 4);
    try std.testing.expectEqual(@as(i32, 6), diff);
    std.log.info("  10 - 4 = {d} ✓", .{diff});

    // 测试乘法
    const product = CalculatorModule.multiply(7, 6);
    try std.testing.expectEqual(@as(i32, 42), product);
    std.log.info("  7 * 6 = {d} ✓", .{product});

    // 测试除法
    const quotient = try CalculatorModule.divide(20, 4);
    try std.testing.expectEqual(@as(i32, 5), quotient);
    std.log.info("  20 / 4 = {d} ✓", .{quotient});

    // 测试除零错误
    const result = CalculatorModule.divide(10, 0);
    try std.testing.expectError(error.DivisionByZero, result);
    std.log.info("  10 / 0 = error ✓", .{});

    std.log.info("  ✓ All operations passed\n", .{});
}

fn testWithMockModule(_: std.Io, allocator: std.mem.Allocator) !void {
    std.log.info("Test 3: Mock Module", .{});

    var ctx = try zigmodu.extensions.ModuleTestContext.init(allocator, "mock_test");
    defer ctx.deinit();

    // 创建 mock 模块
    const mock_calc = zigmodu.extensions.createMockModule(
        "mock_calculator",
        "Mock calculator for testing",
        &.{},
    );

    try ctx.registerMockModule(mock_calc);

    const module = ctx.modules.get("mock_calculator");
    try std.testing.expect(module != null);
    try std.testing.expectEqualStrings("mock_calculator", module.?.name);

    std.log.info("  ✓ Mock module registered successfully\n", .{});
}

// 标准 Zig 测试
test "calculator basic operations" {
    const allocator = std.testing.allocator;

    var app = try zigmodu.Application.init(std.testing.io,
        allocator,
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
    const allocator = std.testing.allocator;

    var app = try zigmodu.Application.init(std.testing.io, allocator, "test", .{CalculatorModule}, .{});
    defer app.deinit();

    try app.start();

    const result = CalculatorModule.divide(10, 0);
    try std.testing.expectError(error.DivisionByZero, result);
}

test "module dependency validation" {
    const allocator = std.testing.allocator;

    // 这应该成功，因为 calculator_service 依赖 calculator
    var app = try zigmodu.Application.init(std.testing.io,
        allocator,
        "test",
        .{ CalculatorModule, CalculatorService },
        .{ .validate_on_start = true },
    );
    defer app.deinit();

    try app.start();
    try std.testing.expectEqual(zigmodu.Application.State.started, app.getState());
}
