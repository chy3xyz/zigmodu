const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;
const ZigModuError = @import("./Error.zig").ZigModuError;

pub fn startAll(modules: *ApplicationModules) !void {
    if (modules.modules.count() == 0) {
        std.log.warn("No modules to start", .{});
        return;
    }

    var ordered_modules = try getSortedModules(modules);
    defer ordered_modules.deinit(modules.allocator);

    for (ordered_modules.items) |module_name| {
        const module = modules.get(module_name) orelse continue;

        if (module.init_fn) |init| {
            std.log.debug("Starting module: {s}", .{module_name});
            init(module.ptr) catch |err| {
                std.log.err("Failed to start module '{s}': {s}", .{ module_name, @errorName(err) });
                return ZigModuError.ModuleInitializationFailed;
            };
        }
    }

    std.log.info("All {d} modules started successfully", .{ordered_modules.items.len});
}

pub fn stopAll(modules: *ApplicationModules) void {
    if (modules.modules.count() == 0) return;

    var ordered_modules = getSortedModules(modules) catch {
        std.log.err("Failed to determine stop order, stopping in reverse registration order", .{});
        var iter = modules.modules.iterator();
        var names = std.ArrayList([]const u8).empty;
        defer names.deinit(modules.allocator);
        while (iter.next()) |entry| {
            names.append(modules.allocator, entry.key_ptr.*) catch continue;
        }
        var i: usize = names.items.len;
        while (i > 0) {
            i -= 1;
            const module_name = names.items[i];
            const module = modules.get(module_name) orelse continue;
            if (module.deinit_fn) |deinit| {
                std.log.debug("Stopping module: {s}", .{module_name});
                deinit(module.ptr);
            }
        }
        std.log.info("All modules stopped successfully", .{});
        return;
    };
    defer ordered_modules.deinit(modules.allocator);

    var i: usize = ordered_modules.items.len;
    while (i > 0) {
        i -= 1;
        const module_name = ordered_modules.items[i];
        const module = modules.get(module_name) orelse continue;

        if (module.deinit_fn) |deinit| {
            std.log.debug("Stopping module: {s}", .{module_name});
            deinit(module.ptr);
        }
    }

    std.log.info("All modules stopped successfully", .{});
}

fn getSortedModules(modules: *ApplicationModules) !std.ArrayList([]const u8) {
    if (modules.sorted_order) |cached| {
        return try cached.clone(modules.allocator);
    }

    var result = try topologicalSort(modules);
    modules.sorted_order = result;
    return try result.clone(modules.allocator);
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
