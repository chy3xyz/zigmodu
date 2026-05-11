const std = @import("std");

pub const ModuleCapabilities = struct {
    const Self = @This();

    module_name: []const u8,
    published_events: std.ArrayList([]const u8),
    consumed_events: std.ArrayList([]const u8),
    exposed_apis: std.ArrayList([]const u8),
    internal_only: bool,

    pub fn init(_allocator: std.mem.Allocator, module_name: []const u8) Self {
        _ = _allocator;
        return .{
            .module_name = module_name,
            .published_events = std.ArrayList([]const u8).empty,
            .consumed_events = std.ArrayList([]const u8).empty,
            .exposed_apis = std.ArrayList([]const u8).empty,
            .internal_only = false,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.published_events.items) |event| {
            allocator.free(event);
        }
        for (self.consumed_events.items) |event| {
            allocator.free(event);
        }
        for (self.exposed_apis.items) |api| {
            allocator.free(api);
        }
        self.published_events.deinit(allocator);
        self.consumed_events.deinit(allocator);
        self.exposed_apis.deinit(allocator);
    }

    pub fn canPublish(self: *Self, event_type: []const u8) bool {
        for (self.published_events.items) |e| {
            if (std.mem.eql(u8, e, event_type)) return true;
        }
        return false;
    }

    pub fn canConsume(self: *Self, event_type: []const u8) bool {
        for (self.consumed_events.items) |e| {
            if (std.mem.eql(u8, e, event_type)) return true;
        }
        return false;
    }

    pub fn canAccessApi(self: *Self, api_name: []const u8) bool {
        for (self.exposed_apis.items) |api| {
            if (std.mem.eql(u8, api, api_name)) return true;
        }
        return false;
    }
};

pub const CapabilityRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    capabilities: std.StringHashMap(ModuleCapabilities),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .capabilities = std.StringHashMap(ModuleCapabilities).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.capabilities.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.capabilities.deinit();
    }

    pub fn register(self: *Self, caps: ModuleCapabilities) !void {
        try self.capabilities.put(caps.module_name, caps);
    }

    pub fn get(self: *Self, module_name: []const u8) ?*ModuleCapabilities {
        return self.capabilities.getPtr(module_name);
    }

    pub fn validateEventFlow(self: *Self, publisher: []const u8, consumer: []const u8, event_type: []const u8) bool {
        const pub_caps = self.get(publisher) orelse return false;
        const cons_caps = self.get(consumer) orelse return false;

        if (!pub_caps.canPublish(event_type)) {
            std.log.err("Module '{s}' is not allowed to publish event '{s}'", .{ publisher, event_type });
            return false;
        }

        if (!cons_caps.canConsume(event_type)) {
            std.log.err("Module '{s}' is not allowed to consume event '{s}'", .{ consumer, event_type });
            return false;
        }

        return true;
    }

    pub fn generateApiBoundaryReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        const writer = buf.writer(allocator);

        try writer.writeAll("# Module API Boundaries\n\n");

        var iter = self.capabilities.iterator();
        while (iter.next()) |entry| {
            const caps = entry.value_ptr.*;
            try writer.print("## {s}\n\n", .{caps.module_name});

            try writer.writeAll("### Published Events\n");
            if (caps.published_events.items.len == 0) {
                try writer.writeAll("None\n\n");
            } else {
                for (caps.published_events.items) |event| {
                    try writer.print("- {s}\n", .{event});
                }
                try writer.writeAll("\n");
            }

            try writer.writeAll("### Consumed Events\n");
            if (caps.consumed_events.items.len == 0) {
                try writer.writeAll("None\n\n");
            } else {
                for (caps.consumed_events.items) |event| {
                    try writer.print("- {s}\n", .{event});
                }
                try writer.writeAll("\n");
            }

            try writer.writeAll("### Exposed APIs\n");
            if (caps.exposed_apis.items.len == 0) {
                try writer.writeAll("None\n\n");
            } else {
                for (caps.exposed_apis.items) |api| {
                    try writer.print("- {s}\n", .{api});
                }
                try writer.writeAll("\n");
            }

            if (caps.internal_only) {
                try writer.writeAll("⚠️ **Internal Module Only**\n\n");
            }
        }

        return buf.toOwnedSlice(allocator);
    }
};

test "ModuleCapabilities canPublish canConsume" {
    const allocator = std.testing.allocator;
    var cap = ModuleCapabilities.init(allocator, "test-module");
    defer cap.deinit(allocator);

    // All capabilities are allowed by default
    try std.testing.expect(cap.canPublish("order.created"));
    try std.testing.expect(cap.canConsume("order.created"));
}

test "ModuleCapabilities register capability" {
    const allocator = std.testing.allocator;
    var cap = ModuleCapabilities.init(allocator, "test-module");
    defer cap.deinit(allocator);

    try cap.registerCapability("publish", "order.created");
    try cap.registerCapability("consume", "payment.*");
    try std.testing.expectEqual(@as(usize, 2), cap.count());
}

