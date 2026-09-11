//! Contract gate — the API promises a consumer depends on, verified against
//! the real route in CI.
//!
//! Unit tests prove a handler returns *something*; a contract gate proves it
//! still returns the shape a consumer relies on (status, body fragment,
//! headers). Register the promises, dispatch real requests through the router,
//! and fail the build on drift — before a consumer discovers it in production.
//!
//! ```zig
//! // In an app: same shape, but contracts describe your published endpoints.
//! var runner = zigmodu.ContractTestRunner.init(allocator);
//! defer runner.deinit();
//! try runner.registerContract(.{ .name = "orders.list", ... });
//! const result = try runner.verifyContract("orders.list", resp.status_code, resp.body, &.{});
//! if (!result.passed) return error.ContractViolated;
//! ```

const std = @import("std");
const http = @import("../http.zig");
const ContractTestRunner = @import("ContractTest.zig").ContractTestRunner;
const Contract = @import("ContractTest.zig").Contract;

/// Routes under contract: a JSON list, a JSON detail, and a "not found" path.
fn listOrders(ctx: *http.Context) anyerror!void {
    try ctx.jsonStruct(200, .{ .items = [_]u32{ 1, 2 }, .total = 2 });
}

fn getOrder(ctx: *http.Context) anyerror!void {
    const id = ctx.paramInt(i64, "id") catch 0;
    if (id == 0) {
        try ctx.jsonStruct(404, .{ .message = "order_not_found" });
        return;
    }
    try ctx.jsonStruct(200, .{ .id = id, .status = "paid" });
}

test "contract gate: published shapes hold for every consumer" {
    const allocator = std.testing.allocator;
    const Testkit = @import("../http/Testkit.zig");

    var server = http.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var group = server.group("");
    try group.get("orders", listOrders, null);
    try group.get("orders/{id}", getOrder, null);

    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    try runner.registerContract(.{
        .name = "orders.list",
        .consumer = "admin-ui",
        .provider = "orders",
        .version = "v1",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/orders" },
        .response = .{
            .status = 200,
            .headers = &.{.{ .key = "Content-Type", .value = "application/json" }},
            .body_contains = "\"total\":2",
        },
    });
    try runner.registerContract(.{
        .name = "orders.detail",
        .consumer = "mobile-app",
        .provider = "orders",
        .version = "v1",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/orders/{id}" },
        .response = .{ .status = 200, .body_contains = "\"status\":\"paid\"" },
    });
    try runner.registerContract(.{
        .name = "orders.detail.missing",
        .consumer = "mobile-app",
        .provider = "orders",
        .version = "v1",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/orders/0" },
        .response = .{ .status = 404, .body_contains = "order_not_found" },
    });

    // Dispatch the real routes and check them against the contracts.
    const cases = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "orders.list", .path = "/orders" },
        .{ .name = "orders.detail", .path = "/orders/7" },
        .{ .name = "orders.detail.missing", .path = "/orders/0" },
    };
    inline for (cases) |case| {
        var resp = try Testkit.dispatch(&server, .GET, case.path, null);
        defer resp.deinit(allocator);
        const headers = [_]Contract.HeaderMatcher{
            .{ .key = "Content-Type", .value = "application/json" },
        };
        var result = try runner.verifyContract(case.name, resp.status_code, resp.body, &headers);
        defer result.deinit(allocator);
        if (!result.passed) {
            std.debug.print("contract {s} violated: {d} failure(s)\n", .{ case.name, result.failures.len });
            return error.ContractViolated;
        }
    }
}

test "contract gate: drift is reported, not silently accepted" {
    const allocator = std.testing.allocator;
    var runner = ContractTestRunner.init(allocator);
    defer runner.deinit();

    try runner.registerContract(.{
        .name = "orders.list",
        .consumer = "admin-ui",
        .provider = "orders",
        .version = "v1",
        .interaction_type = .http,
        .request = .{ .method = "GET", .path = "/orders" },
        .response = .{ .status = 200, .body_contains = "\"total\":2" },
    });

    // A provider that changed its shape (500 + different body) must surface as
    // failures with the field that drifted, not as a passing check.
    var result = try runner.verifyContract("orders.list", 500, "{\"message\":\"boom\"}", &.{});
    defer result.deinit(allocator);
    try std.testing.expect(!result.passed);
    try std.testing.expect(result.failures.len >= 2);
    try std.testing.expectEqualStrings("status", result.failures[0].field);
}
