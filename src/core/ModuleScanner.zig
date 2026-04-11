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
