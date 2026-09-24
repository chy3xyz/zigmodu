//! In-memory event store for event sourcing: append domain events to a
//! per-aggregate stream, read/replay them, and combine with snapshots for
//! CQRS-style reconstruction. Events are serialized to JSON at append time;
//! replay invokes an application handler for every event. Thread-safe via
//! `std.Io.Mutex`.

const std = @import("std");
const Time = @import("Time.zig");

/// Event Store for event sourcing pattern
/// Stores all domain events for replay, audit, and CQRS
pub const EventStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .streams = std.StringHashMap(EventStream).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.streams.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.events.items) |event| {
                self.allocator.free(event.event_type);
                self.allocator.free(event.event_data);
                if (event.metadata.correlation_id) |v| self.allocator.free(v);
                if (event.metadata.causation_id) |v| self.allocator.free(v);
                if (event.metadata.user_id) |v| self.allocator.free(v);
            }
            entry.value_ptr.events.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.streams.deinit();
        self.* = undefined;
    }

    /// Append event to stream. The event is serialized to JSON; metadata
    /// strings are copied (the store owns them).
    pub fn append(
        self: *Self,
        stream_id: []const u8,
        event: anytype,
        metadata: EventStream.EventMetadata,
    ) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        const stream = try self.getOrCreateStreamLocked(stream_id);
        const event_type = @typeName(@TypeOf(event));
        const type_copy = try self.allocator.dupe(u8, event_type);
        errdefer self.allocator.free(type_copy);

        const data = try self.serializeEventLocked(event);
        errdefer self.allocator.free(data);

        const meta = try self.dupMetadataLocked(metadata);
        errdefer self.freeMetadataLocked(meta);

        stream.version += 1;
        try stream.events.append(self.allocator, .{
            .sequence = stream.version,
            .timestamp = Time.monotonicNowSeconds(),
            .event_type = type_copy,
            .event_data = data,
            .metadata = meta,
        });
    }

    fn getOrCreateStreamLocked(self: *Self, stream_id: []const u8) !*EventStream {
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

    fn serializeEventLocked(self: *Self, event: anytype) ![]const u8 {
        return std.json.Stringify.valueAlloc(self.allocator, event, .{});
    }

    fn dupMetadataLocked(self: *Self, m: EventStream.EventMetadata) !EventStream.EventMetadata {
        return .{
            .correlation_id = if (m.correlation_id) |v| try self.allocator.dupe(u8, v) else null,
            .causation_id = if (m.causation_id) |v| try self.allocator.dupe(u8, v) else null,
            .user_id = if (m.user_id) |v| try self.allocator.dupe(u8, v) else null,
        };
    }

    fn freeMetadataLocked(self: *Self, m: EventStream.EventMetadata) void {
        if (m.correlation_id) |v| self.allocator.free(v);
        if (m.causation_id) |v| self.allocator.free(v);
        if (m.user_id) |v| self.allocator.free(v);
    }

    /// Read events from stream starting at `from_version` (inclusive).
    pub fn readStream(
        self: *Self,
        stream_id: []const u8,
        from_version: u64,
        buf: []EventStream.StoredEvent,
    ) ![]EventStream.StoredEvent {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
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

    /// Replay every event to `handler` (in order). The handler receives the
    /// stored event; `event_data` is the JSON payload the application
    /// deserializes.
    pub fn replay(
        self: *Self,
        stream_id: []const u8,
        handler: *const fn (EventStream.StoredEvent) void,
    ) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        const stream = self.streams.get(stream_id) orelse return;
        for (stream.events.items) |event| handler(event);
    }

    /// Get current stream version.
    ///
    /// Uncancelable, and it has to be: `u64` has no room for "I could not read
    /// this", and `0` is a real answer — "this stream has no events". A canceled
    /// lock wait answered with `0` claimed an empty stream for a stream that has
    /// events, so this waits out the lock instead. The critical section is a hash
    /// lookup plus a load.
    pub fn getVersion(self: *Self, stream_id: []const u8) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const stream = self.streams.get(stream_id) orelse return 0;
        return stream.version;
    }
};

/// Snapshot management for performance.
pub const SnapshotStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    snapshots: std.StringHashMap(Snapshot),

    pub const Snapshot = struct {
        stream_id: []const u8,
        version: u64,
        timestamp: i64,
        data: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
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
        self.* = undefined;
    }

    /// Save snapshot (replaces any previous snapshot for the stream).
    pub fn save(self: *Self, stream_id: []const u8, version: u64, data: []const u8) !void {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        const id_copy = try self.allocator.dupe(u8, stream_id);
        errdefer self.allocator.free(id_copy);
        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);

        if (self.snapshots.fetchRemove(id_copy)) |old| {
            self.allocator.free(old.value.data);
            self.allocator.free(old.key);
        }
        try self.snapshots.put(id_copy, .{
            .stream_id = id_copy,
            .version = version,
            .timestamp = Time.monotonicNowSeconds(),
            .data = data_copy,
        });
    }

    /// Load latest snapshot (borrowed; valid until the next save).
    ///
    /// `null` means one thing only: this stream has no snapshot. The lock wait is
    /// therefore uncancelable — the old `catch return null` answered a canceled
    /// wait with "no snapshot", and `EventReplay.replayFromSnapshot` reads that
    /// as "replay this stream from version 1", which rebuilds state from a window
    /// the snapshot was supposed to have replaced.
    pub fn load(self: *Self, stream_id: []const u8) ?Snapshot {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.snapshots.get(stream_id);
    }
};

/// Event replay utilities.
pub const EventReplay = struct {
    /// Replay events from the snapshot point: applies the snapshot state
    /// (via `apply_snapshot`) then every event after it (via `apply_event`).
    ///
    /// Long streams are read in as many passes as they need: `readStream` fills
    /// at most one buffer, so a single pass applied the first `buf.len` events of
    /// a longer stream and dropped the tail without a word — state rebuilt from a
    /// truncated window, with nothing in the return value or the callbacks to say
    /// so. Each pass resumes at the sequence after the last event it saw.
    pub fn replayFromSnapshot(
        event_store: *EventStore,
        snapshot_store: *SnapshotStore,
        stream_id: []const u8,
        apply_snapshot: *const fn (SnapshotStore.Snapshot) void,
        apply_event: *const fn (EventStore.EventStream.StoredEvent) void,
    ) !void {
        const snapshot = snapshot_store.load(stream_id);
        var from_version: u64 = if (snapshot) |s| s.version + 1 else 1;
        if (snapshot) |s| apply_snapshot(s);

        var buf: [256]EventStore.EventStream.StoredEvent = undefined;
        while (true) {
            const events = try event_store.readStream(stream_id, from_version, &buf);
            for (events) |event| apply_event(event);
            // A short read is the end of the stream; a full one may not be.
            if (events.len < buf.len) break;
            from_version = events[events.len - 1].sequence + 1;
        }
    }
};

test "EventStore appends, serializes and replays" {
    const allocator = std.testing.allocator;
    var store = EventStore.init(allocator, std.testing.io);
    defer store.deinit();

    const OrderPlaced = struct { order_id: u32, amount: i64 };
    try store.append("order-123", OrderPlaced{ .order_id = 1, .amount = 9900 }, .{
        .correlation_id = "corr-1",
        .user_id = "u-7",
    });
    try store.append("order-123", OrderPlaced{ .order_id = 2, .amount = 100 }, .{});
    try store.append("order-123", OrderPlaced{ .order_id = 3, .amount = 500 }, .{});
    try std.testing.expectEqual(@as(u64, 3), store.getVersion("order-123"));

    // JSON serialization: event_data must be a parseable JSON string.
    var buf: [10]EventStore.EventStream.StoredEvent = undefined;
    const events = try store.readStream("order-123", 1, &buf);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, events[0].event_data, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(i64, 9900), parsed.value.object.get("amount").?.integer);

    // Replay invokes the handler for every event in order.
    const State = struct {
        var count: usize = 0;
        var last: u64 = 0;
    };
    try store.replay("order-123", struct {
        fn h(event: EventStore.EventStream.StoredEvent) void {
            State.count += 1;
            State.last = event.sequence;
        }
    }.h);
    try std.testing.expectEqual(@as(usize, 3), State.count);
    try std.testing.expectEqual(@as(u64, 3), State.last);
}

test "SnapshotStore and replay from snapshot" {
    const allocator = std.testing.allocator;
    var store = EventStore.init(allocator, std.testing.io);
    defer store.deinit();
    var snapshots = SnapshotStore.init(allocator, std.testing.io);
    defer snapshots.deinit();

    const Ev = struct { n: u32 };
    try store.append("agg-1", Ev{ .n = 1 }, .{});
    try store.append("agg-1", Ev{ .n = 2 }, .{});
    try store.append("agg-1", Ev{ .n = 3 }, .{});
    try snapshots.save("agg-1", 2, "{\"n\":2}");

    const State = struct {
        var applied_snapshot = false;
        var events_after: usize = 0;
    };
    try EventReplay.replayFromSnapshot(
        &store,
        &snapshots,
        "agg-1",
        struct {
            fn s(_: SnapshotStore.Snapshot) void {
                State.applied_snapshot = true;
            }
        }.s,
        struct {
            fn e(_: EventStore.EventStream.StoredEvent) void {
                State.events_after += 1;
            }
        }.e,
    );
    try std.testing.expect(State.applied_snapshot);
    // Only event 3 (sequence > snapshot version 2) is replayed.
    try std.testing.expectEqual(@as(usize, 1), State.events_after);
}

// A stream longer than one read buffer used to be replayed only as far as
// `buf.len`: the tail was dropped without a word, so the rebuilt state was
// taken from a truncated window and nothing downstream could tell.
test "EventStore replay from snapshot drains streams longer than one read buffer" {
    const allocator = std.testing.allocator;
    var store = EventStore.init(allocator, std.testing.io);
    defer store.deinit();
    var snapshots = SnapshotStore.init(allocator, std.testing.io);
    defer snapshots.deinit();

    const Ev = struct { n: u32 };
    const total: u32 = 300; // more than the 256-event buffer
    var n: u32 = 0;
    while (n < total) : (n += 1) try store.append("agg-long", Ev{ .n = n }, .{});

    const State = struct {
        var applied: usize = 0;
        var last_sequence: u64 = 0;
    };
    State.applied = 0;
    State.last_sequence = 0;

    // No snapshot for this stream: every event is replayed, from version 1.
    try EventReplay.replayFromSnapshot(&store, &snapshots, "agg-long", struct {
        fn s(_: SnapshotStore.Snapshot) void {}
    }.s, struct {
        fn e(event: EventStore.EventStream.StoredEvent) void {
            State.applied += 1;
            State.last_sequence = event.sequence;
        }
    }.e);

    try std.testing.expectEqual(@as(usize, total), State.applied);
    try std.testing.expectEqual(@as(u64, total), State.last_sequence);
}

// The two tests below pin the read side against cancelation. `getVersion` and
// `SnapshotStore.load` have no error channel, so the answer a canceled wait
// must not produce is the fabricated one: `0` reads as "this stream has no
// events" and `null` reads as "there is no snapshot", which `replayFromSnapshot`
// turns into "replay from version 1". The lock wait is the cancelation point —
// the task is parked on the store mutex (held by the test thread) with a cancel
// request already placed on its thread, and the gate before the call is pure
// spinning, which consumes nothing. Same idiom as `im.BufferPool`'s tests.
test "EventStore getVersion waits out a canceled lock instead of reporting an empty stream" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Ev = struct { n: u32 };

    const Task = struct {
        var version = std.atomic.Value(u64).init(0);
        var done = std.atomic.Value(bool).init(false);
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn read(store: *EventStore) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            version.store(store.getVersion("agg-1"), .release);
            done.store(true, .release);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var store = EventStore.init(allocator, io);
    defer store.deinit();
    try store.append("agg-1", Ev{ .n = 1 }, .{});
    try store.append("agg-1", Ev{ .n = 2 }, .{});
    try store.append("agg-1", Ev{ .n = 3 }, .{});

    Task.version.store(0, .monotonic);
    Task.done.store(false, .monotonic);
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    try store.mutex.lock(io);

    var task_fut = try io.concurrent(Task.read, .{&store});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (store.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    // A cancelable wait gives up here; an uncancelable one is still parked.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake);
    try std.testing.expect(!Task.done.load(.acquire));

    store.mutex.unlock(io);
    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(u64, 3), Task.version.load(.acquire));
}

test "EventStore snapshot load waits out a canceled lock instead of reporting no snapshot" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Task = struct {
        var got: ?SnapshotStore.Snapshot = null;
        var done = std.atomic.Value(bool).init(false);
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn read(snapshots: *SnapshotStore) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            got = snapshots.load("agg-1");
            done.store(true, .release);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var snapshots = SnapshotStore.init(allocator, io);
    defer snapshots.deinit();
    try snapshots.save("agg-1", 2, "{\"n\":2}");

    Task.got = null;
    Task.done.store(false, .monotonic);
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    try snapshots.mutex.lock(io);

    var task_fut = try io.concurrent(Task.read, .{&snapshots});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (snapshots.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake);
    try std.testing.expect(!Task.done.load(.acquire));

    snapshots.mutex.unlock(io);
    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(u64, 2), Task.got.?.version);
}
