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
        self.* = undefined;
    }

    pub fn canPublish(self: *Self, event_type: []const u8) bool {
        if (self.published_events.items.len == 0) return true;
        for (self.published_events.items) |e| {
            if (std.mem.eql(u8, e, event_type)) return true;
        }
        return false;
    }

    pub fn canConsume(self: *Self, event_type: []const u8) bool {
        if (self.consumed_events.items.len == 0) return true;
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
        self.* = undefined;
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

    /// JSON snapshot of every module's declared event boundary — which events a
    /// module may publish/consume and the APIs it exposes. This is the
    /// machine-readable form of the "module boundaries are declared, not
    /// assumed" contract, for an admin endpoint or a CI drift check. Caller frees.
    pub fn generateApiBoundaryReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        const Entry = struct {
            module: []const u8,
            internal_only: bool,
            published_events: []const []const u8,
            consumed_events: []const []const u8,
            exposed_apis: []const []const u8,
        };

        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(allocator);

        var it = self.capabilities.iterator();
        while (it.next()) |kv| {
            const caps = kv.value_ptr;
            try entries.append(allocator, .{
                .module = caps.module_name,
                .internal_only = caps.internal_only,
                .published_events = caps.published_events.items,
                .consumed_events = caps.consumed_events.items,
                .exposed_apis = caps.exposed_apis.items,
            });
        }
        return std.json.Stringify.valueAlloc(allocator, entries.items, .{});
    }
};

test "generateApiBoundaryReport lists declared boundaries as JSON" {
    const allocator = std.testing.allocator;
    var registry = CapabilityRegistry.init(allocator);
    defer registry.deinit();

    var orders = ModuleCapabilities.init(allocator, "order");
    try orders.registerCapability(allocator, "publish", "order.created");
    try orders.registerCapability(allocator, "api", "GET /orders/{id}");
    try registry.register(orders);

    var billing = ModuleCapabilities.init(allocator, "billing");
    try billing.registerCapability(allocator, "consume", "order.created");
    billing.internal_only = true;
    try registry.register(billing);

    const report = try registry.generateApiBoundaryReport(allocator);
    defer allocator.free(report);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, report, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);

    // Find the order module and check the declared boundary survived the trip.
    var found_order = false;
    for (parsed.value.array.items) |item| {
        const obj = item.object;
        if (std.mem.eql(u8, obj.get("module").?.string, "order")) {
            found_order = true;
            try std.testing.expectEqualStrings("order.created", obj.get("published_events").?.array.items[0].string);
            try std.testing.expectEqualStrings("GET /orders/{id}", obj.get("exposed_apis").?.array.items[0].string);
            try std.testing.expect(!obj.get("internal_only").?.bool);
        }
    }
    try std.testing.expect(found_order);
}

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
