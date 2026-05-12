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

    pub fn registerCapability(self: *Self, allocator: std.mem.Allocator, kind: []const u8, value: []const u8) !void {
        const value_copy = try allocator.dupe(u8, value);
        if (std.mem.eql(u8, kind, "publish")) {
            try self.published_events.append(allocator, value_copy);
        } else if (std.mem.eql(u8, kind, "consume")) {
            try self.consumed_events.append(allocator, value_copy);
        } else if (std.mem.eql(u8, kind, "api")) {
            try self.exposed_apis.append(allocator, value_copy);
        } else {
            allocator.free(value_copy);
            return error.InvalidCapabilityKind;
        }
    }

    pub fn count(self: *Self) usize {
        return self.published_events.items.len + self.consumed_events.items.len + self.exposed_apis.items.len;
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
        _ = self;
        return allocator.dupe(u8, "generateApiBoundaryReport (pending Zig 0.16 allocPrint migration)");
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

    try cap.registerCapability(allocator, "publish", "order.created");
    try cap.registerCapability(allocator, "consume", "payment.*");
    try std.testing.expectEqual(@as(usize, 2), cap.count());
}

