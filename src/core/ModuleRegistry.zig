//! Global registry of ModuleRuntime instances keyed by module name.
//! Validates that per-module resource quotas do not exceed system capacity.

const std = @import("std");
const ApplicationModules = @import("Module.zig").ApplicationModules;
const ModuleInfo = @import("Module.zig").ModuleInfo;
const ModuleRuntime = @import("ModuleRuntime.zig").ModuleRuntime;
const api = @import("../api/Module.zig");

pub const ModuleRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    runtimes: std.StringHashMap(*ModuleRuntime),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .runtimes = std.StringHashMap(*ModuleRuntime).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.runtimes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.runtimes.deinit();
        self.* = undefined;
    }

    /// Build runtimes for every module that declares runtime options.
    pub fn initFromModules(self: *Self, modules: *ApplicationModules) !void {
        var iter = modules.modules.iterator();
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;
            const options = info.runtime_options;

            if (!hasAnyProtection(options)) continue;

            const runtime = try self.allocator.create(ModuleRuntime);
            errdefer self.allocator.destroy(runtime);
            runtime.* = try ModuleRuntime.init(self.allocator, info.name, options);
            try self.runtimes.put(runtime.module_name, runtime);
        }
    }

    pub fn get(self: *Self, name: []const u8) ?*ModuleRuntime {
        return self.runtimes.get(name);
    }

    /// Optional global validation hook.
    pub fn validateQuotas(self: *Self, global_max_open: u32) !void {
        var total_db_max_open: u32 = 0;
        var iter = self.runtimes.iterator();
        while (iter.next()) |entry| {
            const rt = entry.value_ptr.*;
            if (rt.options.max_concurrent > 0) {
                total_db_max_open += rt.options.max_concurrent;
            }
        }
        if (global_max_open > 0 and total_db_max_open > global_max_open) {
            std.log.warn("ModuleRuntime quota exceeds global capacity: {d} > {d}", .{ total_db_max_open, global_max_open });
            return error.ConfigurationError;
        }
    }

    fn hasAnyProtection(options: api.RuntimeOptions) bool {
        return options.max_concurrent > 0 or
            options.max_qps > 0 or
            options.cb_failure_threshold > 0;
    }
};

test "ModuleRegistry creates runtimes for protected modules" {
    const allocator = std.testing.allocator;

    const ProtectedModule = struct {
        pub const info = api.Module{
            .name = "protected",
            .description = "Protected",
            .runtime = .{ .max_concurrent = 3 },
        };
    };

    const UnprotectedModule = struct {
        pub const info = api.Module{
            .name = "unprotected",
            .description = "Unprotected",
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{ ProtectedModule, UnprotectedModule });
    defer modules.deinit();

    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();

    try registry.initFromModules(&modules);

    try std.testing.expect(registry.get("protected") != null);
    try std.testing.expect(registry.get("unprotected") == null);

    const info = modules.get("protected").?;
    try std.testing.expect(info.runtime_options.max_concurrent == 3);
}

test "ModuleRegistry validateQuotas rejects overcommit" {
    const allocator = std.testing.allocator;

    const Module = struct {
        pub const info = api.Module{
            .name = "big",
            .description = "Big",
            .runtime = .{ .max_concurrent = 100 },
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{Module});
    defer modules.deinit();

    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();
    try registry.initFromModules(&modules);

    try std.testing.expectError(error.ConfigurationError, registry.validateQuotas(50));
    try registry.validateQuotas(100);
}
