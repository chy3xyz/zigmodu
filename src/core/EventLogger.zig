const std = @import("std");

pub const EventLogger = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    events: std.ArrayListLoggedEvent,
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
            .events = std.ArrayList(LoggedEvent){},
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
            .timestamp = std.time.timestamp(),
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

    pub fn getEventsByType(self: *Self, event_type: []const u8) []LoggedEvent {
        var results = std.ArrayList(LoggedEvent){};
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.event_type, event_type)) {
                results.append(self.allocator, event) catch {};
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn getEventsByModule(self: *Self, source_module: []const u8) []LoggedEvent {
        var results = std.ArrayList(LoggedEvent){};
        for (self.events.items) |event| {
            if (std.mem.eql(u8, event.source_module, source_module)) {
                results.append(self.allocator, event) catch {};
            }
        }
        return results.toOwnedSlice(self.allocator);
    }

    pub fn getEventsByCorrelationId(self: *Self, correlation_id: []const u8) []LoggedEvent {
        var results = std.ArrayList(LoggedEvent){};
        for (self.events.items) |event| {
            if (event.correlation_id) |cid| {
                if (std.mem.eql(u8, cid, correlation_id)) {
                    results.append(self.allocator, event) catch {};
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
        const id = std.time.timestamp();
        return std.fmt.allocPrint(self.allocator, "{d}-{d}", .{ id, event_id_counter }) catch "";
    }
};

pub const TestEventCollector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    collected_events: std.ArrayList(anyopaque),
    event_types: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .collected_events = std.ArrayList(anyopaque){},
            .event_types = std.ArrayList([]const u8){},
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
        try self.collected_events.append(self.allocator, event);
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
