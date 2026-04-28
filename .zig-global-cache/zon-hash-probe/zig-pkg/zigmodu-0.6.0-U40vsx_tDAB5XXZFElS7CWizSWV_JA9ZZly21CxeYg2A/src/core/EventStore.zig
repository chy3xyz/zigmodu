const std = @import("std");

/// Event Store for event sourcing pattern
/// Stores all domain events for replay, audit, and CQRS
pub const EventStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    streams: std.StringHashMap(EventStream),

    /// Individual event stream (per aggregate)
    pub const EventStream = struct {
        stream_id: []const u8,
        events: std.ArrayList(StoredEvent),
        version: u64 = 0,

        pub const StoredEvent = struct {
            sequence: u64,
            timestamp: i64,
            event_type: []const u8,
            event_data: []const u8,
            metadata: EventMetadata,
        };

        pub const EventMetadata = struct {
            correlation_id: ?[]const u8 = null,
            causation_id: ?[]const u8 = null,
            user_id: ?[]const u8 = null,
        };
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .streams = std.StringHashMap(EventStream).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.streams.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.events.items) |event| {
                self.allocator.free(event.event_type);
                self.allocator.free(event.event_data);
            }
            entry.value_ptr.events.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.streams.deinit();
    }

    /// Append event to stream
    pub fn append(
        self: *Self,
        stream_id: []const u8,
        event: anytype,
        metadata: EventStream.EventMetadata,
    ) !void {
        const stream = try self.getOrCreateStream(stream_id);

        const event_type = @typeName(@TypeOf(event));
        const type_copy = try self.allocator.dupe(u8, event_type);

        // Serialize event (simplified)
        const data = try self.serializeEvent(event);

        stream.version += 1;
        try stream.events.append(self.allocator, .{
            .sequence = stream.version,
            .timestamp = 0,
            .event_type = type_copy,
            .event_data = data,
            .metadata = metadata,
        });
    }

    fn getOrCreateStream(self: *Self, stream_id: []const u8) !*EventStream {
        if (self.streams.getPtr(stream_id)) |stream| {
            return stream;
        }

        const id_copy = try self.allocator.dupe(u8, stream_id);
        try self.streams.put(id_copy, .{
            .stream_id = id_copy,
            .events = std.ArrayList(EventStream.StoredEvent).empty,
        });

        return self.streams.getPtr(id_copy).?;
    }

    fn serializeEvent(self: *Self, event: anytype) ![]const u8 {
        // In real implementation, would use proper serialization
        // For now, return placeholder
        _ = event;
        return try self.allocator.alloc(u8, 0);
    }

    /// Read events from stream starting at version
    pub fn readStream(
        self: *Self,
        stream_id: []const u8,
        from_version: u64,
        buf: []EventStream.StoredEvent,
    ) ![]EventStream.StoredEvent {
        const stream = self.streams.get(stream_id) orelse return buf[0..0];

        var count: usize = 0;
        for (stream.events.items) |event| {
            if (event.sequence >= from_version and count < buf.len) {
                buf[count] = event;
                count += 1;
            }
        }
        return buf[0..count];
    }

    /// Replay events to reconstruct aggregate state
    pub fn replay(
        self: *Self,
        stream_id: []const u8,
        handler: fn (anytype) void,
    ) !void {
        const stream = self.streams.get(stream_id) orelse return;

        for (stream.events.items) |event| {
            // In real implementation, would deserialize and call handler
            _ = handler;
            _ = event;
        }
    }

    /// Get current stream version
    pub fn getVersion(self: *Self, stream_id: []const u8) u64 {
        const stream = self.streams.get(stream_id) orelse return 0;
        return stream.version;
    }
};

/// Snapshot management for performance
pub const SnapshotStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    snapshots: std.StringHashMap(Snapshot),

    const Snapshot = struct {
        stream_id: []const u8,
        version: u64,
        timestamp: i64,
        data: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .snapshots = std.StringHashMap(Snapshot).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.snapshots.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.data);
            self.allocator.free(entry.key_ptr.*);
        }
        self.snapshots.deinit();
    }

    /// Save snapshot
    pub fn save(self: *Self, stream_id: []const u8, version: u64, data: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, stream_id);
        const data_copy = try self.allocator.dupe(u8, data);

        // Remove old snapshot if exists
        if (self.snapshots.fetchRemove(id_copy)) |old| {
            self.allocator.free(old.value.data);
        }

        try self.snapshots.put(id_copy, .{
            .stream_id = id_copy,
            .version = version,
            .timestamp = 0,
            .data = data_copy,
        });
    }

    /// Load latest snapshot
    pub fn load(self: *Self, stream_id: []const u8) ?Snapshot {
        return self.snapshots.get(stream_id);
    }
};

/// Event replay utilities
pub const EventReplay = struct {
    /// Replay events from snapshot point
    pub fn replayFromSnapshot(
        event_store: *EventStore,
        snapshot_store: *SnapshotStore,
        stream_id: []const u8,
        apply_event: fn (anytype) void,
    ) !void {
        // Load snapshot
        const snapshot = snapshot_store.load(stream_id);
        const from_version = if (snapshot) |s| s.version + 1 else 1;

        // Apply snapshot state (placeholder for real implementation)
        if (snapshot) |s| {
            _ = s;
            // Would apply snapshot state here
        }

        // Replay remaining events
        var buf: [100]EventStore.EventStream.StoredEvent = undefined;
        const events = try event_store.readStream(stream_id, from_version, &buf);

        for (events) |event| {
            // Deserialize and apply
            _ = event;
            _ = apply_event;
        }
    }
};

test "EventStore basic operations" {
    const allocator = std.testing.allocator;

    var store = EventStore.init(allocator);
    defer store.deinit();

    const TestEvent = struct { value: i32 };

    // Append events
    try store.append("order-123", TestEvent{ .value = 1 }, .{});
    try store.append("order-123", TestEvent{ .value = 2 }, .{});
    try store.append("order-123", TestEvent{ .value = 3 }, .{});

    // Check version
    try std.testing.expectEqual(@as(u64, 3), store.getVersion("order-123"));

    // Read events
    // SAFETY: Buffer is immediately filled by readStream() before use
    var buf: [10]EventStore.EventStream.StoredEvent = undefined;
    const events = try store.readStream("order-123", 1, &buf);
    try std.testing.expectEqual(@as(usize, 3), events.len);
}

test "SnapshotStore" {
    const allocator = std.testing.allocator;

    var snapshots = SnapshotStore.init(allocator);
    defer snapshots.deinit();

    const data = "snapshot_data";
    try snapshots.save("order-123", 10, data);

    const loaded = snapshots.load("order-123").?;
    try std.testing.expectEqual(@as(u64, 10), loaded.version);
    try std.testing.expectEqualStrings(data, loaded.data);
}
