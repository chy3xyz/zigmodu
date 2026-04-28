const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

/// Compile-time module scanner that extracts module metadata
pub fn scanModules(allocator: std.mem.Allocator, comptime modules: anytype) !ApplicationModules {
    var app_modules = ApplicationModules.init(allocator);
    inline for (modules) |mod| {
        // Extract init function pointer if it exists
        const init_fn = if (@hasDecl(mod, "init"))
            struct {
                fn wrapper(ptr: *anyopaque) anyerror!void {
                    _ = ptr;
                    try mod.init();
                }
            }.wrapper
        else
            null;

        // Extract deinit function pointer if it exists
        const deinit_fn = if (@hasDecl(mod, "deinit"))
            struct {
                fn wrapper(ptr: *anyopaque) void {
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
    return app_modules;
}

test "scanModules extracts metadata" {
    const allocator = std.testing.allocator;

    const MockModule = struct {
        pub const info = @import("../api/Module.zig").Module{
            .name = "mock",
            .description = "Mock module for testing",
            .dependencies = &.{"dep1"},
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
    try std.testing.expectEqual(@as(usize, 1), info.deps.len);
    try std.testing.expectEqualStrings("dep1", info.deps[0]);
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
