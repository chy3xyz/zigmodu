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
        self.fiber_group.await(self.io) catch |err| std.log.err("[DEB] Fiber await failed: {}", .{err});
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

        // Pre-allocate a large reusable buffer for the life of the connection
        var read_buf: [8192]u8 = undefined;
        var r = conn.reader(self.io, &read_buf);
        
        // Use an Arena for parsing-related allocations that can be cleared per message
        var msg_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer msg_arena.deinit();

        while (self.is_running) {
            const ma = msg_arena.allocator();
            
            // Fast read: directly into buffer
            const data = r.interface.readSliceShort(&read_buf) catch |err| {
                if (self.is_running) std.log.debug("[DEB] Read error: {}", .{err});
                break;
            };

            if (data.len == 0) break;

            // Parse using our arena to avoid multiple tiny heap allocations
            if (parseEvent(ma, data)) |event| {
                // Topic callback lookup is fast with StringHashMap
                if (std.mem.eql(u8, event.topic, "__heartbeat")) {
                    continue;
                }

                self.publishToTopic(event);

                // Local bus dispatch
                self.local_bus.publish(event);
            }
            
            // Clear arena for next message - extremely fast
            _ = msg_arena.reset(.retain_capacity);
        }
    }

    /// Fast, non-duping JSON value extractor for internal protocol
    fn extractJsonValue(data: []const u8, key: []const u8) ?[]const u8 {
        const key_pos = std.mem.indexOf(u8, data, key) orelse return null;
        const remaining = data[key_pos + key.len ..];
        
        // Skip : and optional whitespace/quotes
        var val_start: usize = 0;
        while (val_start < remaining.len and (remaining[val_start] == ':' or remaining[val_start] == ' ' or remaining[val_start] == '"')) : (val_start += 1) {}
        
        var end = val_start;
        while (end < remaining.len and remaining[end] != '"' and remaining[end] != ',' and remaining[end] != '}') : (end += 1) {}
        
        if (val_start >= end) return null;
        return remaining[val_start..end];
    }

    fn parseEvent(allocator: std.mem.Allocator, data: []const u8) ?NetworkEvent {
        const topic = extractJsonValue(data, "\"topic\"") orelse return null;
        const payload = extractJsonValue(data, "\"payload\"") orelse return null;
        const source = extractJsonValue(data, "\"source\"") orelse return null;
        const time_str = extractJsonValue(data, "\"time\"") orelse "0";

        return NetworkEvent{
            .topic = allocator.dupe(u8, topic) catch return null,
            .payload = allocator.dupe(u8, payload) catch return null,
            .source_node = allocator.dupe(u8, source) catch return null,
            .timestamp = std.fmt.parseInt(i64, time_str, 10) catch 0,
        };
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
                    _ = callbacks.swapRemove(i);
                    break;
                }
            }
        }
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
                _ = self.nodes.swapRemove(i);
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
