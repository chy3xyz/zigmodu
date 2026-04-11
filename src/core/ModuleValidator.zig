const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

pub const ValidationError = error{
    InvalidModuleName,
    SelfDependency,
    DependencyNotFound,
    CircularDependency,
};

/// Validates that all module dependencies exist and checks for circular dependencies
pub fn validateModules(modules: *ApplicationModules) !void {
    if (modules.modules.count() == 0) {
        std.log.warn("No modules registered for validation", .{});
        return;
    }

    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const module = entry.value_ptr.*;

        if (module.name.len == 0) {
            std.log.err("Module with empty name found", .{});
            return ValidationError.InvalidModuleName;
        }

        for (module.deps) |dep| {
            if (std.mem.eql(u8, module.name, dep)) {
                std.log.err("Module '{s}' depends on itself", .{module.name});
                return ValidationError.SelfDependency;
            }

            if (!modules.modules.contains(dep)) {
                std.log.err("Module '{s}' is missing dependency: '{s}'", .{ module.name, dep });
                return ValidationError.DependencyNotFound;
            }
        }
    }

    try checkCircularDependencies(modules);

    std.log.info("✅ All module dependencies validated successfully ({d} modules)", .{modules.modules.count()});
}

fn checkCircularDependencies(modules: *ApplicationModules) !void {
    var visited = std.StringHashMap(void).init(modules.allocator);
    defer visited.deinit();

    var in_stack = std.StringHashMap(void).init(modules.allocator);
    defer in_stack.deinit();

    var path = std.ArrayList([]const u8){};
    defer path.deinit(modules.allocator);

    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const module_name = entry.key_ptr.*;

        visited.clearRetainingCapacity();
        in_stack.clearRetainingCapacity();
        path.clearRetainingCapacity();

        if (try hasCircularDependency(modules, module_name, &visited, &in_stack, &path)) {
            std.log.err("Circular dependency detected: {s}", .{module_name});
            return ValidationError.CircularDependency;
        }
    }
}

fn hasCircularDependency(
    modules: *ApplicationModules,
    module_name: []const u8,
    visited: *std.StringHashMap(void),
    in_stack: *std.StringHashMap(void),
    path: *std.ArrayList([]const u8),
) !bool {
    if (in_stack.contains(module_name)) {
        try path.append(modules.allocator, module_name);
        return true;
    }

    if (visited.contains(module_name)) {
        return false;
    }

    try visited.put(module_name, {});
    try in_stack.put(module_name, {});
    try path.append(modules.allocator, module_name);

    const module_info = modules.get(module_name) orelse return false;

    for (module_info.deps) |dep| {
        if (try hasCircularDependency(modules, dep, visited, in_stack, path)) {
            return true;
        }
    }

    _ = in_stack.remove(module_name);
    if (path.items.len > 0) {
        _ = path.pop();
    }

    return false;
}
