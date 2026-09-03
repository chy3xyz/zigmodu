const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;
const ModuleContext = @import("ModuleContext.zig").ModuleContext;
const ZigModuError = @import("./Error.zig").ZigModuError;

/// Classic startup path (no framework facilities handed to modules).
pub fn startAll(modules: *ApplicationModules) !void {
    return startAllWith(modules, null);
}

/// Startup with a `ModuleContext`: modules declaring `initWith(ctx)` receive
/// the shared EventRegistry + DI container; others fall back to `init()`.
/// A module that declares ONLY `initWith` cannot be started without a context.
pub fn startAllWith(modules: *ApplicationModules, ctx: ?*ModuleContext) !void {
    if (modules.modules.count() == 0) {
        std.log.warn("No modules to start", .{});
        return;
    }

    const ordered_modules = try getSortedModules(modules);

    var started_count: usize = 0;
    errdefer {
        // Stop already-started modules in REVERSE order on failure
        var i: usize = started_count;
        while (i > 0) {
            i -= 1;
            const module_name = ordered_modules[i];
            const module = modules.get(module_name) orelse continue;
            if (module.deinit_fn) |deinit| {
                std.log.warn("Rolling back module: {s}", .{module_name});
                deinit(module.ptr);
            }
        }
    }

    for (ordered_modules, 0..) |module_name, idx| {
        const module = modules.get(module_name) orelse continue;

        std.log.debug("Starting module: {s}", .{module_name});
        if (module.init_ctx_fn) |init_ctx| {
            const c = ctx orelse {
                if (module.init_fn) |init| {
                    init(module.ptr) catch |err| {
                        std.log.err("Failed to start module '{s}': {s}", .{ module_name, @errorName(err) });
                        return ZigModuError.ModuleInitializationFailed;
                    };
                    started_count = idx + 1;
                    continue;
                }
                std.log.warn("Module '{s}' declares only initWith(ctx) but no ModuleContext was provided", .{module_name});
                return ZigModuError.ModuleInitializationFailed;
            };
            init_ctx(module.ptr, c) catch |err| {
                std.log.err("Failed to start module '{s}': {s}", .{ module_name, @errorName(err) });
                return ZigModuError.ModuleInitializationFailed;
            };
        } else if (module.init_fn) |init| {
            init(module.ptr) catch |err| {
                std.log.err("Failed to start module '{s}': {s}", .{ module_name, @errorName(err) });
                return ZigModuError.ModuleInitializationFailed;
            };
        }
        started_count = idx + 1;
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
            .name = "base-s",
            .description = "B",
            .dependencies = &.{},
        };
        pub fn init() !void {}
        pub fn deinit() void {
            Ctx.deinit_order[Ctx.idx] = 'b';
            Ctx.idx += 1;
        }
    };
    const Middle = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "middle-s",
            .description = "M",
            .dependencies = &.{"base-s"},
        };
        pub fn init() !void {}
        pub fn deinit() void {
            Ctx.deinit_order[Ctx.idx] = 'm';
            Ctx.idx += 1;
        }
    };
    const Top = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "top-s",
            .description = "T",
            .dependencies = &.{"middle-s"},
        };
        pub fn init() !void {}
        pub fn deinit() void {
            Ctx.deinit_order[Ctx.idx] = 't';
            Ctx.idx += 1;
        }
    };

    var scanned = try @import("ModuleScanner.zig").scanModules(allocator, .{ Top, Middle, Base });
    defer scanned.deinit();

    try startAll(&scanned);
    Ctx.idx = 0;
    stopAll(&scanned);
    // Deinit order must be reverse of init: Top → Middle → Base
    try std.testing.expectEqualStrings("tmb", &Ctx.deinit_order);
}

test "startAllWith passes ModuleContext to initWith modules" {
    const allocator = std.testing.allocator;

    const E = struct { n: i64 };
    const Ctx = struct {
        var got_ctx: bool = false;
        var published: i64 = 0;
        fn onEvent(e: E) void {
            published = e.n;
        }
    };

    const Eventful = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "eventful",
            .description = "Uses ModuleContext",
            .dependencies = &.{},
        };
        pub fn initWith(ctx: *ModuleContext) !void {
            Ctx.got_ctx = true;
            const bus = try ctx.eventBus(E);
            try bus.subscribe(Ctx.onEvent);
            bus.publish(.{ .n = 7 });
        }
        pub fn deinit() void {}
    };

    var scanned = try @import("ModuleScanner.zig").scanModules(allocator, .{Eventful});
    defer scanned.deinit();

    var registry = @import("EventRegistry.zig").EventRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    var services = @import("../di/Container.zig").Container.init(allocator);
    defer services.deinit();

    var ctx = ModuleContext{
        .allocator = allocator,
        .io = std.testing.io,
        .events = &registry,
        .services = &services,
    };

    try startAllWith(&scanned, &ctx);
    try std.testing.expect(Ctx.got_ctx);
    try std.testing.expectEqual(@as(i64, 7), Ctx.published);
    stopAll(&scanned);
}

test "startAllWith falls back to init when module declares both hooks" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        var hook: u8 = 0;
    };

    const Both = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "both-hooks",
            .description = "Declares init and initWith",
            .dependencies = &.{},
        };
        pub fn init() !void {
            Ctx.hook = 1;
        }
        pub fn initWith(ctx: *ModuleContext) !void {
            _ = ctx;
            Ctx.hook = 2;
        }
        pub fn deinit() void {}
    };

    var scanned = try @import("ModuleScanner.zig").scanModules(allocator, .{Both});
    defer scanned.deinit();

    var registry = @import("EventRegistry.zig").EventRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    var services = @import("../di/Container.zig").Container.init(allocator);
    defer services.deinit();
    var ctx = ModuleContext{
        .allocator = allocator,
        .io = std.testing.io,
        .events = &registry,
        .services = &services,
    };

    // With context: initWith wins (init must not also run)
    try startAllWith(&scanned, &ctx);
    try std.testing.expectEqual(@as(u8, 2), Ctx.hook);
    stopAll(&scanned);

    // Without context: falls back to plain init
    Ctx.hook = 0;
    try startAll(&scanned);
    try std.testing.expectEqual(@as(u8, 1), Ctx.hook);
}

test "initWith-only module fails to start without a context" {
    const allocator = std.testing.allocator;

    const OnlyCtx = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "only-ctx",
            .description = "initWith only",
            .dependencies = &.{},
        };
        pub fn initWith(ctx: *ModuleContext) !void {
            _ = ctx;
        }
        pub fn deinit() void {}
    };

    var scanned = try @import("ModuleScanner.zig").scanModules(allocator, .{OnlyCtx});
    defer scanned.deinit();

    try std.testing.expectError(ZigModuError.ModuleInitializationFailed, startAll(&scanned));
}
