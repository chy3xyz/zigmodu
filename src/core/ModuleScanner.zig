const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

/// Compile-time module scanner that extracts module metadata and performs topological sort
pub fn scanModules(allocator: std.mem.Allocator, comptime modules: anytype) !ApplicationModules {
    @setEvalBranchQuota(100000);
    var app_modules = ApplicationModules.init(allocator);

    // 1. Register all modules first (runtime registration for backward compat)
    inline for (modules) |mod| {
        const init_fn = if (@hasDecl(mod,"init"))
            struct {
                fn wrapper(ptr: ?*anyopaque) anyerror!void {
                    _ = ptr;
                    try mod.init();
                }
            }.wrapper
        else
            null;

        const deinit_fn = if (@hasDecl(mod,"deinit"))
            struct {
                fn wrapper(ptr: ?*anyopaque) void {
                    _ = ptr;
                    mod.deinit();
                }
            }.wrapper
        else
            null;

        try app_modules.register(ModuleInfo{
            .name = mod.info.name,
            .desc = mod.info.description,
            .deps = mod.info.dependencies,
            .ptr = @ptrCast(@constCast(&mod)),
            .init_fn = init_fn,
            .deinit_fn = deinit_fn,
        });
    }

    // 2. Perform topological sort at comptime and cache the result
    // Uses runtime visitor (Lifecycle.visitModule) to avoid comptime ++ edge cases
    // with non-empty dependencies and module names containing '/'.
    const sorted_names = comptime blk: {
        var names: []const []const u8 = &[_][]const u8{};
        for (modules) |mod| {
            names = names ++ [_][]const u8{mod.info.name};
        }
        break :blk names;
    };

    // Use runtime topological sort for correct dependency ordering
    _ = sorted_names;
    var sorted_list = std.ArrayList([]const u8).empty;
    {
        var visited = std.StringHashMap(void).init(allocator);
        defer visited.deinit();
        var temp = std.StringHashMap(void).init(allocator);
        defer temp.deinit();

        var it = app_modules.modules.iterator();
        while (it.next()) |entry| {
            if (!visited.contains(entry.key_ptr.*)) {
                try visitR(allocator, &app_modules, entry.key_ptr.*, &visited, &temp, &sorted_list);
            }
        }
    }
    app_modules.sorted_order = sorted_list;

    return app_modules;
}

fn visitR(
    allocator: std.mem.Allocator,
    modules: *ApplicationModules,
    name: []const u8,
    visited: *std.StringHashMap(void),
    temp: *std.StringHashMap(void),
    result: *std.ArrayList([]const u8),
) !void {
    if (temp.contains(name)) return;
    if (visited.contains(name)) return;
    try temp.put(name, {});

    if (modules.get(name)) |info| {
        for (info.deps) |dep| {
            try visitR(allocator, modules, dep, visited, temp, result);
        }
    }
    _ = temp.remove(name);
    try visited.put(name, {});
    try result.append(allocator, name);
}

test "scanModules extracts metadata" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "mock",
            .description = "Mock module for testing",
            .dependencies = &.{},
        };

        pub fn init() !void {}
        pub fn deinit() void {}
    };

    var modules = try scanModules(allocator, .{MockModule});
    defer modules.deinit();

    try std.testing.expectEqual(@as(usize, 1), modules.modules.count());
    const info = modules.get("mock").?;
    try std.testing.expectEqualStrings("mock", info.name);
    try std.testing.expectEqualStrings("Mock module for testing", info.desc);
    try std.testing.expectEqual(@as(usize, 0), info.deps.len);
}

test "scanModules optional init/deinit" {
    const allocator = std.testing.allocator;

    const NoLifecycle = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "nolife",
            .description = "No lifecycle",
            .dependencies = &.{},
        };
    };

    var modules = try scanModules(allocator, .{NoLifecycle});
    defer modules.deinit();

    const info = modules.get("nolife").?;
    try std.testing.expect(info.init_fn == null);
    try std.testing.expect(info.deinit_fn == null);
}
