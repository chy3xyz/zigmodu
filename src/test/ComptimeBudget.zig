//! Compile-time budget: a route table far larger than the framework's own
//! examples must still expand. If a comptime budget regresses (a fixed
//! `@setEvalBranchQuota` somewhere in the mount path, an O(n²) fold), this
//! file stops compiling — the gate is the build itself, with no timing
//! flakiness. `scripts/check-comptime-budget.sh` adds the wall-clock/RSS
//! numbers for a regression report.
const std = @import("std");
const http = @import("../http.zig");
const Router = @import("../api/ComptimeRouter.zig").Router;
const Server = @import("../api/Server.zig").Server;
const EvalQuota = @import("../core/EvalQuota.zig");

const route_count = 256;

fn BudgetMod(comptime n: usize) type {
    return struct {
        pub const module_name = "budget";
        pub const nest = .{"budget"};
        pub const State = struct {};

        fn h(_: *http.Context, _: *State) anyerror!void {}

        pub const routes = blk: {
            @setEvalBranchQuota(EvalQuota.forUnits(n));
            var specs: [n]http.RouteSpec(State) = undefined;
            for (0..n) |i| {
                specs[i] = .{
                    .method = .GET,
                    .path = std.fmt.comptimePrint("r{d}", .{i}),
                    .handler = h,
                };
            }
            break :blk specs;
        };
    };
}

test "comptime budget: a 256-route module mounts and catalogs" {
    const allocator = std.testing.allocator;
    const AppState = struct {};
    var app: AppState = .{};
    const Mod = BudgetMod(route_count);
    var state: Mod.State = .{};

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 18102 });
    defer server.deinit();
    var router = Router(AppState).init(std.testing.io, allocator, &server, &app);
    defer router.deinit();
    var scoped = router.scope("");
    try scoped.mount(Mod, &state);
    var catalog = try router.finish();
    defer catalog.deinit();

    try std.testing.expectEqual(@as(usize, route_count), catalog.entries.len);
    const trie = try server.listRoutes(allocator);
    defer {
        for (trie) |r| {
            allocator.free(r.method);
            allocator.free(r.path);
        }
        allocator.free(trie);
    }
    try std.testing.expectEqual(@as(usize, route_count), trie.len);
}
