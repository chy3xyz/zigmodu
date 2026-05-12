const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

/// Compile-time module scanner that extracts module metadata and performs topological sort
pub fn scanModules(allocator: std.mem.Allocator, comptime modules: anytype) !ApplicationModules {
    var app_modules = ApplicationModules.init(allocator);

    // 1. Register all modules first (runtime registration for backward compat)
    inline for (modules) |mod| {
        const init_fn = if (@hasDecl(mod, "init"))
            struct {
                fn wrapper(ptr: ?*anyopaque) anyerror!void {
                    _ = ptr;
                    try mod.init();
                }
            }.wrapper
        else
            null;

        const deinit_fn = if (@hasDecl(mod, "deinit"))
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
    // This avoids runtime sorting in Lifecycle.startAll
    const sorted_names = comptime blk: {
        var result: []const []const u8 = &[_][]const u8{};
        for (modules) |mod| {
            result = visit(mod.info.name, modules, result);
        }
        break :blk result;
    };

    var sorted_list = try std.ArrayList([]const u8).initCapacity(allocator, sorted_names.len);
    inline for (sorted_names) |name| {
        sorted_list.appendAssumeCapacity(name);
    }
    app_modules.sorted_order = sorted_list;

    return app_modules;
}

/// Comptime helper to visit modules and order them
fn visit(comptime name: []const u8, comptime modules: anytype, comptime current_sorted: []const []const u8) []const []const u8 {
    // Check if already in current_sorted
    for (current_sorted) |existing| {
        if (std.mem.eql(u8, existing, name)) return current_sorted;
    }

    // Find module info
    const mod_info = comptime blk: {
        for (modules) |m| {
            if (std.mem.eql(u8, m.info.name, name)) break :blk m.info;
        }
        @compileError("Module not found: " ++ name);
    };

    var result = current_sorted;
    // Visit dependencies first
    for (mod_info.dependencies) |dep| {
        result = visit(dep, modules, result);
    }

    // Append self
    return result ++ [_][]const u8{name};
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
