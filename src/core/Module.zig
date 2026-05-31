const std = @import("std");
const api = @import("../api/Module.zig");

pub const ModuleInfo = struct {
    name: []const u8,
    desc: []const u8,
    deps: []const []const u8,
    /// Module instance pointer. Null for metadata-only registrations (e.g. tests).
    ptr: ?*anyopaque = null,
    init_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    deinit_fn: ?*const fn (?*anyopaque) void = null,

    /// Create a metadata-only ModuleInfo (ptr defaults to null).
    /// Use scanModules() for full registrations with init/deinit function pointers.
    pub fn init(
        name: []const u8,
        desc: []const u8,
        deps: []const []const u8,
    ) ModuleInfo {
        return .{
            .name = name,
            .desc = desc,
            .deps = deps,
            .ptr = null,
            .init_fn = null,
            .deinit_fn = null,
        };
    }
};

pub const ApplicationModules = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(ModuleInfo),
    sorted_order: ?std.ArrayList([]const u8) = null,

    pub fn init(allocator: std.mem.Allocator) ApplicationModules {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(ModuleInfo).init(allocator),
            .sorted_order = null,
        };
    }

    pub fn register(self: *ApplicationModules, info: ModuleInfo) !void {
        try self.modules.put(info.name, info);
        // Invalidate cached topological sort when module set changes
        if (self.sorted_order) |*order| {
            order.deinit(self.allocator);
            self.sorted_order = null;
        }
    }

    pub fn get(self: *ApplicationModules, name: []const u8) ?ModuleInfo {
        return self.modules.get(name);
    }

    pub fn getPtr(self: *ApplicationModules, name: []const u8) ?*ModuleInfo {
        return self.modules.getPtr(name);
    }

    pub fn deinit(self: *ApplicationModules) void {
        if (self.sorted_order) |*order| {
            order.deinit(self.allocator);
        }
        self.modules.deinit();
        self.* = undefined;
    }
};

test "ModuleInfo init" {
    const info = ModuleInfo.init("order", "Order module", &.{"inventory"});
    try std.testing.expectEqualStrings("order", info.name);
    try std.testing.expectEqualStrings("Order module", info.desc);
    try std.testing.expectEqual(@as(usize, 1), info.deps.len);
    try std.testing.expectEqualStrings("inventory", info.deps[0]);
    try std.testing.expect(info.ptr == null);
}

test "ApplicationModules register and get" {
    const allocator = std.testing.allocator;
    var app = ApplicationModules.init(allocator);
    defer app.deinit();

    const info = ModuleInfo.init("user", "User module", &.{});
    try app.register(info);

    const retrieved = app.get("user").?;
    try std.testing.expectEqualStrings("user", retrieved.name);
    try std.testing.expectEqualStrings("User module", retrieved.desc);
    try std.testing.expect(app.getPtr("user") != null);
    try std.testing.expect(app.get("nonexistent") == null);
}
