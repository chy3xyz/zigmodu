const std = @import("std");
const Time = @import("Time.zig");
const TypedEventBus = @import("EventBus.zig").TypedEventBus;
const ArrayList = std.array_list.Managed;

// Optional distributed components (can be enabled via config)
// const WAL = @import("eventbus/WAL.zig").WAL;
// const DLQ = @import("eventbus/DLQ.zig").DLQ;
// const Partitioner = @import("eventbus/Partitioner.zig").ConsistentHashPartitioner;

/// Distributed Event Bus for cross-node communication
/// Allows events to be published and subscribed across multiple processes/machines
pub const DistributedEventBus = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    local_bus: TypedEventBus(NetworkEvent),
    topic_callbacks: std.StringHashMap(std.ArrayList(*const fn (NetworkEvent) void)),
    nodes: ArrayList(Node),
    listener: ?std.Io.net.Server,
    is_running: bool,
    node_id: []const u8,
    heartbeat_thread: ?std.Thread,
    /// Owns accept/handle/heartbeat fibers; awaited in `stop()`.
    fiber_group: std.Io.Group,

    pub const NetworkEvent = struct {
        topic: []const u8,
        payload: []const u8,
        source_node: []const u8,
        timestamp: i64,
    };

    const Node = struct {
        id: []const u8,
        address: std.Io.net.IpAddress,
        socket: ?std.Io.net.Stream,
        last_seen: i64,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, node_id: []const u8) !Self {
        const id_copy = try allocator.dupe(u8, node_id);
        errdefer allocator.free(id_copy);
        return .{
            .allocator = allocator,
            .io = io,
            .local_bus = TypedEventBus(NetworkEvent).init(allocator),
            .topic_callbacks = std.StringHashMap(std.ArrayList(*const fn (NetworkEvent) void)).init(allocator),
            .nodes = ArrayList(Node).init(allocator),
            .listener = null,
            .is_running = false,
            .node_id = id_copy,
            .heartbeat_thread = null,
            .fiber_group = .init,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.allocator.free(self.node_id);
        self.local_bus.deinit();

        var cb_iter = self.topic_callbacks.iterator();
        while (cb_iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.topic_callbacks.deinit();

        for (self.nodes.items) |*node| {
            if (node.socket) |sock| {
                sock.close(self.io);
            }
            self.allocator.free(node.id);
        }
        self.nodes.deinit();
    }

    /// Start listening for incoming connections
    pub fn start(self: *Self, port: u16) !void {
        if (self.is_running) return;

        const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
        self.listener = try address.listen(self.io, .{});
        self.is_running = true;

        std.log.info("[DistributedEventBus] Node '{s}' listening on port {d}", .{ self.node_id, port });

        // Start accept loop and heartbeat asynchronously as members of
        // `fiber_group` so their futures do not leak.
        self.fiber_group.async(self.io, acceptLoop, .{self});
        self.heartbeat_thread = null;
        self.fiber_group.async(self.io, heartbeatLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        self.heartbeat_thread = null;
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
        // Drain accept/handle/heartbeat fibers; idempotent.
        self.fiber_group.await(self.io) catch {};
    }

    fn acceptLoop(self: *Self) void {
        while (self.is_running) {
            if (self.listener) |*l| {
                const conn = l.accept(self.io) catch |err| {
                    if (self.is_running) {
                        std.log.err("[DistributedEventBus] Accept error: {}", .{err});
                    }
                    continue;
                };

                // Handle connection asynchronously in the shared group.
                self.fiber_group.async(self.io, handleConnection, .{ self, conn });
            }
        }
    }

    fn heartbeatLoop(self: *Self) void {
        while (self.is_running) {
            // Send heartbeat to all connected nodes (disabled)
            self.sendHeartbeat();
            std.Io.sleep(self.io, .{ .nanoseconds = 5_000_000_000 }, .real) catch break; // 5 seconds
        }
    }

    fn sendHeartbeat(self: *Self) void {
        const event = NetworkEvent{
            .topic = "__heartbeat",
            .payload = self.node_id,
            .source_node = self.node_id,
            .timestamp = Time.monotonicNowSeconds(),
        };
        var buf: [4096]u8 = undefined;
        const serialized = serializeEvent(event, &buf);

        for (self.nodes.items) |*node| {
            if (node.socket) |sock| {
                var write_buf: [4096]u8 = undefined;
                var w = sock.writer(self.io, &write_buf);
                _ = w.interface.writeAll(serialized) catch |err| {
                    std.log.warn("[DistributedEventBus] Heartbeat failed to node {s}: {}", .{ node.id, err });
                };
            }
        }
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) void {
        defer conn.close(self.io);

        var buf: [4096]u8 = undefined;
        var read_buf: [4096]u8 = undefined;
        var r = conn.reader(self.io, &read_buf);
        while (self.is_running) {
            const bytes_read = r.interface.readSliceShort(&buf) catch |err| {
                if (self.is_running) {
                    std.log.debug("[DistributedEventBus] Read error: {}", .{err});
                }
                break;
            };

            if (bytes_read == 0) break;

            // Parse and handle event
            if (parseEvent(self.allocator, buf[0..bytes_read])) |event| {
                defer self.allocator.free(event.topic);
                defer self.allocator.free(event.payload);
                defer self.allocator.free(event.source_node);

                // Update last_seen for source node
                for (self.nodes.items) |*node| {
                    if (std.mem.eql(u8, node.id, event.source_node)) {
                        node.last_seen = 0;
                        break;
                    }
                }

                // Handle heartbeat internally
                if (std.mem.eql(u8, event.topic, "__heartbeat")) {
                    std.log.debug("[DistributedEventBus] Heartbeat from {s}", .{event.source_node});
                    continue;
                }

                // Publish to matching topic subscribers
                self.publishToTopic(event);

                // Also publish to local bus for general subscribers
                self.local_bus.publish(.{
                    .topic = event.topic,
                    .payload = event.payload,
                    .source_node = event.source_node,
                    .timestamp = event.timestamp,
                });
            }
        }
    }

    /// Connect to a remote node
    pub fn connectToNode(self: *Self, node_id: []const u8, address: std.Io.net.IpAddress) !void {
        const stream = try address.connect(self.io, .{ .mode = .stream });

        const id_copy = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(id_copy);

        try self.nodes.append(.{
            .id = id_copy,
            .address = address,
            .socket = stream,
            .last_seen = 0,
        });

        std.log.info("[DistributedEventBus] Connected to node {s} at {}", .{ node_id, address });
    }

    /// Publish event to all connected nodes
    pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void {
        const event = NetworkEvent{
            .topic = topic,
            .payload = payload,
            .source_node = self.node_id,
            .timestamp = Time.monotonicNowSeconds(),
        };

        // Serialize event
        var buf: [4096]u8 = undefined;
        const serialized = serializeEvent(event, &buf);

        // Broadcast to all nodes
        for (self.nodes.items) |*node| {
            if (node.socket) |sock| {
                var write_buf: [4096]u8 = undefined;
                var w = sock.writer(self.io, &write_buf);
                _ = w.interface.writeAll(serialized) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to send to node {s}: {}", .{ node.id, err });
                };
            }
        }
        // Also publish locally
        self.publishToTopic(event);
        self.local_bus.publish(event);
    }

    fn publishToTopic(self: *Self, event: NetworkEvent) void {
        if (self.topic_callbacks.get(event.topic)) |callbacks| {
            for (callbacks.items) |callback| {
                callback(event);
            }
        }
    }

    /// Subscribe to events on a specific topic
    pub fn subscribe(self: *Self, topic: []const u8, callback: *const fn (NetworkEvent) void) !void {
        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);

        const gop = try self.topic_callbacks.getOrPut(topic_copy);
        if (!gop.found_existing) {
            gop.key_ptr.* = topic_copy;
            gop.value_ptr.* = std.ArrayList(*const fn (NetworkEvent) void).empty;
        } else {
            self.allocator.free(topic_copy);
        }
        try gop.value_ptr.append(self.allocator, callback);
    }

    /// Unsubscribe from a topic
    pub fn unsubscribe(self: *Self, topic: []const u8, callback: *const fn (NetworkEvent) void) void {
        if (self.topic_callbacks.getPtr(topic)) |callbacks| {
            for (callbacks.items, 0..) |cb, i| {
                if (cb == callback) {
                    _ = callbacks.orderedRemove(i);
                    break;
                }
            }
        }
    }

    fn parseEvent(allocator: std.mem.Allocator, data: []const u8) ?NetworkEvent {
        // Simple JSON parser for NetworkEvent
        // Format: {"topic":"...","payload":"...","source":"...","time":123}

        var topic: ?[]const u8 = null;
        var payload: ?[]const u8 = null;
        var source: ?[]const u8 = null;
        var timestamp: i64 = 0;

        // Parse topic
        if (extractJsonStringValue(data, "\"topic\"")) |val| {
            topic = allocator.dupe(u8, val) catch return null;
        }

        // Parse payload
        if (extractJsonStringValue(data, "\"payload\"")) |val| {
            payload = allocator.dupe(u8, val) catch {
                if (topic) |t| allocator.free(t);
                return null;
            };
        }

        // Parse source
        if (extractJsonStringValue(data, "\"source\"")) |val| {
            source = allocator.dupe(u8, val) catch {
                if (topic) |t| allocator.free(t);
                if (payload) |p| allocator.free(p);
                return null;
            };
        }

        // Parse timestamp (optional)
        if (extractJsonIntValue(data, "\"time\"")) |val| {
            timestamp = val;
        }

        if (topic == null or payload == null or source == null) {
            if (topic) |t| allocator.free(t);
            if (payload) |p| allocator.free(p);
            if (source) |s| allocator.free(s);
            return null;
        }

        return NetworkEvent{
            .topic = topic.?, 
            .payload = payload.?, 
            .source_node = source.?, 
            .timestamp = timestamp,
        };
    }

    fn extractJsonStringValue(data: []const u8, key: []const u8) ?[]const u8 {
        const key_idx = std.mem.indexOf(u8, data, key) orelse return null;
        const after_key = data[key_idx + key.len..];
        // Skip whitespace and colon
        var i: usize = 0;
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':' or after_key[i] == '"')) : (i += 1) {}
        // Now i points to start of value (after opening quote)
        const val_start = i;
        // Find closing quote
        while (i < after_key.len and after_key[i] != '"') : (i += 1) {}
        if (i == val_start) return null;
        return after_key[val_start..i];
    }

    fn extractJsonIntValue(data: []const u8, key: []const u8) ?i64 {
        const key_idx = std.mem.indexOf(u8, data, key) orelse return null;
        const after_key = data[key_idx + key.len..];
        var i: usize = 0;
        while (i < after_key.len and (after_key[i] == ' ' or after_key[i] == ':')) : (i += 1) {}
        const val_start = i;
        while (i < after_key.len and (after_key[i] == '-' or std.ascii.isDigit(after_key[i]))) : (i += 1) {}
        if (i == val_start) return null;
        return std.fmt.parseInt(i64, after_key[val_start..i], 10) catch null;
    }

    fn serializeEvent(event: NetworkEvent, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{{\"topic\":\"{s}\",\"payload\":\"{s}\",\"source\":\"{s}\",\"time\":{d}}}", .{
            event.topic,
            event.payload,
            event.source_node,
            event.timestamp,
        }) catch buf[0..0];
    }

    /// Get list of connected nodes
    pub fn getConnectedNodes(self: *Self) []const Node {
        return self.nodes.items;
    }

    /// Get node count
    pub fn getNodeCount(self: *Self) usize {
        return self.nodes.items.len;
    }

    /// Disconnect from a node
    pub fn disconnectNode(self: *Self, node_id: []const u8) void {
        for (self.nodes.items, 0..) |*node, i| {
            if (std.mem.eql(u8, node.id, node_id)) {
                if (node.socket) |sock| {
                    sock.close(self.io);
                }
                self.allocator.free(node.id);
                _ = self.nodes.orderedRemove(i);
                std.log.info("[DistributedEventBus] Disconnected from node {s}", .{node_id});
                return;
            }
        }
    }
};

/// Cluster configuration for distributed event bus
pub const ClusterConfig = struct {
    node_id: []const u8,
    listen_port: u16,
    seed_nodes: []const SeedNode,
    heartbeat_interval_ms: u32 = 5000,

    pub const SeedNode = struct {
        id: []const u8,
        host: []const u8,
        port: u16,
    };
};

test "DistributedEventBus init subscribe publish" {
    const allocator = std.testing.allocator;
    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node");
    defer bus.deinit();

    try std.testing.expectEqual(@as(usize, 0), bus.getNodeCount());

    var received: bool = false;
    const listener = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "test")) {
                flag.* = true;
            }
        }
    };
    listener.flag = &received;

    try bus.subscribe("test", listener.cb);
    try bus.publish("test", "hello");

    try std.testing.expect(received);
}

test "DistributedEventBus serializeEvent" {
    const event = DistributedEventBus.NetworkEvent{
        .topic = "t1",
        .payload = "p1",
        .source_node = "n1",
        .timestamp = 123,
    };
    var buf: [256]u8 = undefined;
    const serialized = DistributedEventBus.serializeEvent(event, &buf);
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "\"topic\":\"t1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, serialized, 1, "\"time\":123"));
}

test "DistributedEventBus parseEvent" {
    const allocator = std.testing.allocator;
    const data = "{\"topic\":\"test\",\"payload\":\"hello\",\"source\":\"node1\",\"time\":456}";

    const event = DistributedEventBus.parseEvent(allocator, data) orelse {
        return error.ParseFailed;
    };
    defer allocator.free(event.topic);
    defer allocator.free(event.payload);
    defer allocator.free(event.source_node);

    try std.testing.expectEqualStrings("test", event.topic);
    try std.testing.expectEqualStrings("hello", event.payload);
    try std.testing.expectEqualStrings("node1", event.source_node);
    try std.testing.expectEqual(@as(i64, 456), event.timestamp);
}
