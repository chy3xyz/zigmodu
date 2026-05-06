const std = @import("std");
const zigmodu = @import("zigmodu");

pub const PluginEntry = struct {
    name: []const u8,
    version: []const u8,
    license_key: ?[]const u8 = null,
    init_fn: *const fn () anyerror!void,
};

pub var registry: std.StringHashMap(PluginEntry) = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    registry = std.StringHashMap(PluginEntry).init(allocator);
}

pub fn register(name: []const u8, entry: PluginEntry) !void {
    try registry.put(name, entry);
    std.log.info("[Plugin] Registered: {s} v{s}", .{ name, entry.version });
}
