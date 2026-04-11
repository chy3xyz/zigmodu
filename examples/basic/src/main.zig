const std = @import("std");
const zigmodu = @import("zigmodu");

// ============================================
// Example 1: Basic E-commerce - Core Features
// ============================================

const UserModule = @import("modules/user.zig");
const OrderModule = @import("modules/order.zig");
const PaymentModule = @import("modules/payment.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== ZigModu Basic Example ===", .{});
    std.log.info("Demonstrates: Module definition, dependency management, lifecycle\n", .{});

    // Method 1: Using the new Application API (Recommended)
    var app = try zigmodu.Application.init(
        allocator,
        "shop",
        .{ UserModule, OrderModule, PaymentModule },
        .{
            .validate_on_start = true,
            .auto_generate_docs = true,
            .docs_path = "modules.puml",
        },
    );
    defer app.deinit();

    try app.start();

    std.log.info("\n✅ Application '{s}' is running with {d} modules", .{
        app.config.name,
        app.modules.modules.count(),
    });

    // Check module access
    if (app.hasModule("order")) {
        std.log.info("✓ Order module is active", .{});
    }

    // Simulate work
    std.Thread.sleep(500 * std.time.ns_per_ms);

    std.log.info("\n👋 Application shutting down...", .{});
    // deinit() automatically stops modules in reverse dependency order
}
