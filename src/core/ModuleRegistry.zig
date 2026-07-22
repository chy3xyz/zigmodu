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
    pub fn initFromModules(self: *Self, io: std.Io, modules: *ApplicationModules) !void {
        var iter = modules.modules.iterator();
        while (iter.next()) |entry| {
            const info = entry.value_ptr.*;
            const options = info.runtime_options;

            if (!hasAnyProtection(options)) continue;

            const runtime = try self.allocator.create(ModuleRuntime);
            var initialized = false;
            errdefer {
                if (initialized) runtime.deinit();
                self.allocator.destroy(runtime);
            }
            runtime.* = try ModuleRuntime.init(self.allocator, io, info.name, options);
            initialized = true;
            try self.runtimes.put(runtime.module_name, runtime);
        }
    }

    pub fn get(self: *Self, name: []const u8) ?*ModuleRuntime {
        return self.runtimes.get(name);
    }

    /// Optional global validation hook.
    pub fn validateQuotas(self: *Self, global_max_open: u32) !void {
        var total_max_concurrent: u32 = 0;
        var iter = self.runtimes.iterator();
        while (iter.next()) |entry| {
            const rt = entry.value_ptr.*;
            if (rt.options.max_concurrent > 0) {
                total_max_concurrent = std.math.add(u32, total_max_concurrent, rt.options.max_concurrent) catch return error.ConfigurationError;
            }
        }
        if (global_max_open > 0 and total_max_concurrent > global_max_open) {
            std.log.warn("ModuleRuntime quota exceeds global capacity: {d} > {d}", .{ total_max_concurrent, global_max_open });
            return error.ConfigurationError;
        }
    }

    fn hasAnyProtection(options: api.RuntimeOptions) bool {
        return options.max_concurrent > 0 or
            options.max_qps > 0 or
            options.cb_failure_threshold > 0 or
            options.worker_count > 0;
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

    try registry.initFromModules(std.testing.io, &modules);

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
    try registry.initFromModules(std.testing.io, &modules);

    try std.testing.expectError(error.ConfigurationError, registry.validateQuotas(50));
    try registry.validateQuotas(100);
}

test "ModuleRegistry validateQuotas rejects u32 overflow" {
    const allocator = std.testing.allocator;
    const half_plus_one = std.math.maxInt(u32) / 2 + 1;

    const ModuleA = struct {
        pub const info = api.Module{
            .name = "a",
            .description = "A",
            .runtime = .{ .max_concurrent = half_plus_one },
        };
    };

    const ModuleB = struct {
        pub const info = api.Module{
            .name = "b",
            .description = "B",
            .runtime = .{ .max_concurrent = half_plus_one },
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{ ModuleA, ModuleB });
    defer modules.deinit();

    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();
    try registry.initFromModules(std.testing.io, &modules);

    // Overflow itself must be reported as a configuration error even when no
    // global limit is enforced.
    try std.testing.expectError(error.ConfigurationError, registry.validateQuotas(0));
}

test "ModuleRegistry initFromModules cleans up on put failure" {
    const allocator = std.testing.allocator;

    const Module = struct {
        pub const info = api.Module{
            .name = "protected",
            .description = "Protected",
            .runtime = .{ .max_concurrent = 3 },
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{Module});
    defer modules.deinit();

    // First, discover how many allocations a successful run performs. Then fail
    // the final allocation (currently the StringHashMap.put). This is robust
    // against changes in the number of allocations that precede the put.
    var counter = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    {
        var registry = ModuleRegistry.init(counter.allocator());
        defer registry.deinit();
        try registry.initFromModules(std.testing.io, &modules);
    }
    const successful_alloc_count = counter.alloc_index;
    try std.testing.expect(successful_alloc_count > 0);

    var failing = std.testing.FailingAllocator.init(allocator, .{
        .fail_index = successful_alloc_count - 1,
    });
    var registry = ModuleRegistry.init(failing.allocator());
    defer registry.deinit();

    try std.testing.expectError(error.OutOfMemory, registry.initFromModules(std.testing.io, &modules));
}

test "ModuleRegistry creates runtime for worker_count-only module" {
    const allocator = std.testing.allocator;

    const WorkerModule = struct {
        pub const info = api.Module{
            .name = "worker-only",
            .description = "Worker only",
            .runtime = .{ .worker_count = 3 },
        };
    };

    var modules = try @import("ModuleScanner.zig").scanModules(allocator, .{WorkerModule});
    defer modules.deinit();

    var registry = ModuleRegistry.init(allocator);
    defer registry.deinit();
    try registry.initFromModules(std.testing.io, &modules);

    try std.testing.expect(registry.get("worker-only") != null);
}
