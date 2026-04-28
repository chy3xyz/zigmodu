const std = @import("std");

pub const ModuleState = enum(u8) {
    INITIALIZING,
    RUNNING,
    STOPPING,
    STOPPED,
    FAILED,
};

pub const ApplicationView = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    module_states: std.StringHashMap(ModuleState),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .module_states = std.StringHashMap(ModuleState).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.module_states.deinit();
    }

    pub fn setState(self: *Self, name: []const u8, state: ModuleState) void {
        self.module_states.put(name, state) catch {};
    }

    pub fn getState(self: *Self, name: []const u8) ?ModuleState {
        return self.module_states.get(name);
    }

    pub fn isReady(self: *Self) bool {
        if (self.module_states.count() == 0) return false;
        var iter = self.module_states.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* != .RUNNING) return false;
        }
        return true;
    }

    pub fn printSummary(self: *Self) void {
        std.log.info("=== Application View ===", .{});
        var iter = self.module_states.iterator();
        while (iter.next()) |entry| {
            std.log.info("  {s}: {s}", .{ entry.key_ptr.*, @tagName(entry.value_ptr.*) });
        }
    }
};

test "ApplicationView" {
    const allocator = std.testing.allocator;
    var view = ApplicationView.init(allocator);
    defer view.deinit();

    view.setState("test-module", .RUNNING);
    try std.testing.expectEqual(ModuleState.RUNNING, view.getState("test-module"));
    try std.testing.expect(view.isReady());
}
