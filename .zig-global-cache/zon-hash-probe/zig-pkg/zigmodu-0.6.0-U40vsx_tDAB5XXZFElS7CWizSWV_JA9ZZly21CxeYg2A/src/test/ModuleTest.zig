const std = @import("std");
const ApplicationModules = @import("../core/Module.zig").ApplicationModules;
const ModuleInfo = @import("../core/Module.zig").ModuleInfo;

/// Test context for module-level testing
pub const ModuleTestContext = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    module_name: []const u8,
    modules: ApplicationModules,

    pub fn init(allocator: std.mem.Allocator, module_name: []const u8) !Self {
        return .{
            .allocator = allocator,
            .module_name = module_name,
            .modules = ApplicationModules.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.modules.deinit();
    }

    /// Register a mock module for testing
    pub fn registerMockModule(self: *Self, info: ModuleInfo) !void {
        try self.modules.register(info);
    }

    /// Start the test module
    pub fn start(self: *Self) !void {
        const module = self.modules.get(self.module_name) orelse {
            std.log.err("Module {s} not found", .{self.module_name});
            return error.ModuleNotFound;
        };

        if (module.init_fn) |init_fn| {
            try init_fn(module.ptr);
        }

        std.log.info("✅ Test module {s} started", .{self.module_name});
    }

    /// Stop the test module
    pub fn stop(self: *Self) void {
        const module = self.modules.get(self.module_name) orelse return;

        if (module.deinit_fn) |deinit_fn| {
            deinit_fn(module.ptr);
        }

        std.log.info("✅ Test module {s} stopped", .{self.module_name});
    }
};

/// Helper to create a mock module for testing
pub fn createMockModule(
    name: []const u8,
    description: []const u8,
    dependencies: []const []const u8,
) ModuleInfo {
    return .{
        .name = name,
        .desc = description,
        .deps = dependencies,
        .ptr = undefined,
        .init_fn = null,
        .deinit_fn = null,
    };
}
