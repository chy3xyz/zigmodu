const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;
const ZigModuError = @import("./Error.zig").ZigModuError;

pub fn startAll(modules: *ApplicationModules) !void {
    if (modules.modules.count() == 0) {
        std.log.warn("No modules to start", .{});
        return;
    }

    const ordered_modules = try getSortedModules(modules);

    for (ordered_modules) |module_name| {
        const module = modules.get(module_name) orelse continue;

        if (module.init_fn) |init| {
            std.log.debug("Starting module: {s}", .{module_name});
            init(module.ptr) catch |err| {
                std.log.err("Failed to start module '{s}': {s}", .{ module_name, @errorName(err) });
                return ZigModuError.ModuleInitializationFailed;
            };
        }
    }

    std.log.info("All {d} modules started successfully", .{ordered_modules.len});
}

pub fn stopAll(modules: *ApplicationModules) void {
    if (modules.modules.count() == 0) return;

    const ordered_modules = getSortedModules(modules) catch {
        std.log.err("Failed to determine stop order, stopping in reverse registration order", .{});
        var iter = modules.modules.iterator();
        while (iter.next()) |entry| {
            const module = entry.value_ptr;
            if (module.deinit_fn) |deinit| {
                std.log.debug("Stopping module: {s}", .{module.name});
                deinit(module.ptr);
            }
        }
        std.log.info("All modules stopped successfully", .{});
        return;
    };

    var i: usize = ordered_modules.len;
    while (i > 0) {
        i -= 1;
        const module_name = ordered_modules[i];
        const module = modules.get(module_name) orelse continue;

        if (module.deinit_fn) |deinit| {
            std.log.debug("Stopping module: {s}", .{module_name});
            deinit(module.ptr);
        }
    }

    std.log.info("All modules stopped successfully", .{});
}

fn getSortedModules(modules: *ApplicationModules) ![]const []const u8 {
    if (modules.sorted_order) |cached| {
        return cached.items;
    }

    const result = try topologicalSort(modules);
    modules.sorted_order = result;
    return result.items;
}

fn topologicalSort(modules: *ApplicationModules) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(modules.allocator);

    var visited = std.StringHashMap(void).init(modules.allocator);
    defer visited.deinit();

    var temp_mark = std.StringHashMap(void).init(modules.allocator);
    defer temp_mark.deinit();

    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const module_name = entry.key_ptr.*;
        if (!visited.contains(module_name)) {
            try visitModule(modules, module_name, &visited, &temp_mark, &result);
        }
    }

    return result;
}

fn visitModule(
    modules: *ApplicationModules,
    module_name: []const u8,
    visited: *std.StringHashMap(void),
    temp_mark: *std.StringHashMap(void),
    result: *std.ArrayList([]const u8),
) !void {
    if (temp_mark.contains(module_name)) {
        std.log.warn("Circular dependency detected: {s}", .{module_name});
        return ZigModuError.CircularDependency;
    }

    if (visited.contains(module_name)) {
        return;
    }

    try temp_mark.put(module_name, {});

    const module_info = modules.get(module_name) orelse return;
    for (module_info.deps) |dep| {
        try visitModule(modules, dep, visited, temp_mark, result);
    }

    _ = temp_mark.remove(module_name);
    try visited.put(module_name, {});
    try result.append(modules.allocator, module_name);
}

test "startAll and stopAll order" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    const Ctx = struct {
        var order: [3]u8 = undefined;
        var idx: usize = 0;
    };
    Ctx.idx = 0;

    const Base = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "base",
            .description = "Base",
            .dependencies = &.{},
        };
        pub fn init() !void {
            Ctx.order[Ctx.idx] = 'b';
            Ctx.idx += 1;
        }
        pub fn deinit() void {}
    };

    const Middle = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "middle",
            .description = "Middle",
            .dependencies = &.{"base"},
        };
        pub fn init() !void {
            Ctx.order[Ctx.idx] = 'm';
            Ctx.idx += 1;
        }
        pub fn deinit() void {}
    };

    const Top = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "top",
            .description = "Top",
            .dependencies = &.{"middle"},
        };
        pub fn init() !void {
            Ctx.order[Ctx.idx] = 't';
            Ctx.idx += 1;
        }
        pub fn deinit() void {}
    };

    var scanned = try @import("ModuleScanner.zig").scanModules(allocator, .{ Top, Middle, Base });
    defer scanned.deinit();

    try startAll(&scanned);
    try std.testing.expectEqualStrings("bmt", &Ctx.order);
}

test "stopAll reverse dependency order" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    const Ctx = struct {
        var deinit_order: [3]u8 = undefined;
        var idx: usize = 0;
    };
    Ctx.idx = 0;

    const Base = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "base-s", .description = "B", .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void { Ctx.deinit_order[Ctx.idx] = 'b'; Ctx.idx += 1; }
    };
    const Middle = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "middle-s", .description = "M", .dependencies = &.{"base-s"},
        };
        pub fn init() !void {}
        pub fn deinit() void { Ctx.deinit_order[Ctx.idx] = 'm'; Ctx.idx += 1; }
    };
    const Top = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "top-s", .description = "T", .dependencies = &.{"middle-s"},
        };
        pub fn init() !void {}
        pub fn deinit() void { Ctx.deinit_order[Ctx.idx] = 't'; Ctx.idx += 1; }
    };

    var scanned = try @import("ModuleScanner.zig").scanModules(allocator, .{ Top, Middle, Base });
    defer scanned.deinit();

    try startAll(&scanned);
    Ctx.idx = 0;
    stopAll(&scanned);
    // Deinit order must be reverse of init: Top → Middle → Base
    try std.testing.expectEqualStrings("tmb", &Ctx.deinit_order);
}
