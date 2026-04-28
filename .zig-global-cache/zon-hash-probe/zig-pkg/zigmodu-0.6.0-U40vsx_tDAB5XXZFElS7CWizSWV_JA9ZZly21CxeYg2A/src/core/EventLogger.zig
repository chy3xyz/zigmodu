const std = @import("std");

pub const EventLogger = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    events: std.ArrayList(LoggedEvent),
    max_events: usize,

    pub const LoggedEvent = struct {
        id: u64,
        timestamp: i64,
        event_type: []const u8,
        source_module: []const u8,
        payload: []const u8,
        correlation_id: ?[]const u8,
        causation_id: ?[]const u8,
    };

    var event_id_counter: u64 = 1;

    pub fn init(allocator: std.mem.Allocator, max_events: usize) Self {
        return .{
            .allocator = allocator,
            .events = std.ArrayList(LoggedEvent).empty,
            .max_events = max_events,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.events.items) |event| {
            self.allocator.free(event.event_type);
            self.allocator.free(event.source_module);
            self.allocator.free(event.payload);
            if (event.correlation_id) |cid| self.allocator.free(cid);
            if (event.causation_id) |caid| self.allocator.free(caid);
        }
        self.events.deinit(self.allocator);
    }

    pub fn log(self: *Self, event_type: []const u8, source_module: []const u8, payload: []const u8, correlation_id: ?[]const u8, causation_id: ?[]const u8) !void {
        const event = LoggedEvent{
            .id = event_id_counter,
            .timestamp = 0,
            .event_type = try self.allocator.dupe(u8, event_type),
            .source_module = try self.allocator.dupe(u8, source_module),
            .payload = try self.allocator.dupe(u8, payload),
            .correlation_id = if (correlation_id) |cid| try self.allocator.dupe(u8, cid) else null,
            .causation_id = if (causation_id) |caid| try self.allocator.dupe(u8, caid) else null,
        };

        event_id_counter += 1;
        try self.events.append(self.allocator, event);

        if (self.events.items.len > self.max_events) {
            self.pruneOldest(1);
        }
    }

    fn pruneOldest(self: *Self, count: usize) void {
        var i: usize = 0;
        while (i < count and self.events.items.len > 0) : (i += 1) {
            const event = self.events.items[0];
            self.allocator.free(event.event_type);
            self.allocator.free(event.source_module);
            self.allocator.free(event.payload);
            if (event.correlation_id) |cid| self.allocator.free(cid);
            if (event.causation_id) |caid| self.allocator.free(caid);
            _ = self.events.orderedRemove(0);
        }
    }

    pub fn getEventsByType(self: *Self, event_type: []const u8) ![]LoggedEvent {
        var results = std.ArrayList(LoggedEvent).empty;
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.event_type, event_type)) {
                try results.append(self.allocator, event);
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn getEventsByModule(self: *Self, source_module: []const u8) ![]LoggedEvent {
        var results = std.ArrayList(LoggedEvent).empty;
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.source_module, source_module)) {
                try results.append(self.allocator, event);
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn getEventsByCorrelationId(self: *Self, correlation_id: []const u8) ![]LoggedEvent {
        var results = std.ArrayList(LoggedEvent).empty;
        for (self.events.items) |event| {
            if (event.correlation_id) |cid| {
                if (std.mem.eql(u8, cid, correlation_id)) {
                    try results.append(self.allocator, event);
                }
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn getEventCount(self: *Self) usize {
        return self.events.items.len;
    }

    pub fn clear(self: *Self) void {
        self.pruneOldest(self.events.items.len);
    }

    pub fn generateCorrelationId(self: *Self) []const u8 {
        const id = 0;
        return std.fmt.allocPrint(self.allocator, "{d}-{d}", .{ id, event_id_counter }) catch "";
    }
};

pub const TestEventCollector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    collected_events: std.ArrayList(*anyopaque),
    event_types: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .collected_events = std.ArrayList(*anyopaque).empty,
            .event_types = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.collected_events.deinit(self.allocator);
        for (self.event_types.items) |t| {
            self.allocator.free(t);
        }
        self.event_types.deinit(self.allocator);
    }

    pub fn collect(self: *Self, event: anytype, event_type: []const u8) !void {
        const ptr: *anyopaque = @ptrCast(@constCast(&event));
        try self.collected_events.append(self.allocator, ptr);
        try self.event_types.append(self.allocator, try self.allocator.dupe(u8, event_type));
    }

    pub fn getEventCount(self: *Self) usize {
        return self.collected_events.items.len;
    }

    pub fn hasEvent(self: *Self, event_type: []const u8) bool {
        for (self.event_types.items) |t| {
            if (std.mem.eql(u8, t, event_type)) {
                return true;
            }
        }
        return false;
    }

    pub fn clear(self: *Self) void {
        self.collected_events.clearRetainingCapacity();
        for (self.event_types.items) |t| {
            self.allocator.free(t);
        }
        self.event_types.clearRetainingCapacity();
    }
};

test "EventLogger log and retrieve" {
    const allocator = std.testing.allocator;
    var logger = EventLogger.init(allocator, 10);
    defer logger.deinit();

    try logger.log("created", "order", "{\"id\":1}", "corr-1", null);
    try logger.log("updated", "order", "{\"id\":2}", "corr-2", "corr-1");
    try logger.log("created", "inventory", "{\"sku\":\"A\"}", null, null);

    try std.testing.expectEqual(@as(usize, 3), logger.getEventCount());

    const created_events = try logger.getEventsByType("created");
    defer allocator.free(created_events);
    try std.testing.expectEqual(@as(usize, 2), created_events.len);

    const order_events = try logger.getEventsByModule("order");
    defer allocator.free(order_events);
    try std.testing.expectEqual(@as(usize, 2), order_events.len);

    const corr_events = try logger.getEventsByCorrelationId("corr-1");
    defer allocator.free(corr_events);
    try std.testing.expectEqual(@as(usize, 1), corr_events.len);
}

test "EventLogger pruning" {
    const allocator = std.testing.allocator;
    var logger = EventLogger.init(allocator, 2);
    defer logger.deinit();

    try logger.log("evt", "mod", "1", null, null);
    try logger.log("evt", "mod", "2", null, null);
    try logger.log("evt", "mod", "3", null, null);

    try std.testing.expectEqual(@as(usize, 2), logger.getEventCount());
}

test "EventLogger clear" {
    const allocator = std.testing.allocator;
    var logger = EventLogger.init(allocator, 10);
    defer logger.deinit();

    try logger.log("evt", "mod", "data", null, null);
    logger.clear();
    try std.testing.expectEqual(@as(usize, 0), logger.getEventCount());
}

test "TestEventCollector basic operations" {
    const allocator = std.testing.allocator;
    var collector = TestEventCollector.init(allocator);
    defer collector.deinit();

    try collector.collect(@as(u32, 42), "test-event");
    try std.testing.expectEqual(@as(usize, 1), collector.getEventCount());
    try std.testing.expect(collector.hasEvent("test-event"));
    try std.testing.expect(!collector.hasEvent("other"));

    collector.clear();
    try std.testing.expectEqual(@as(usize, 0), collector.getEventCount());
    try std.testing.expect(!collector.hasEvent("test-event"));
}
