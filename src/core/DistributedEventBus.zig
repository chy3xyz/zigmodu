const std = @import("std");
const TypedEventBus = @import("EventBus.zig").TypedEventBus;
const ArrayList = std.array_list.Managed;

// ⚠️ EXPERIMENTAL: This module is incomplete and not production-ready.
/// Distributed Event Bus for cross-node communication
/// Allows events to be published and subscribed across multiple processes/machines
pub const DistributedEventBus = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    local_bus: TypedEventBus(NetworkEvent),
    nodes: ArrayList(Node),
    listener: ?std.Io.net.Server,
    is_running: bool,

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

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .local_bus = TypedEventBus(NetworkEvent).init(allocator),
            .nodes = ArrayList(Node).init(allocator),
            .listener = null,
            .is_running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.local_bus.deinit();

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
        self.listener = try std.Io.net.listen(&address, self.io, .{});
        self.is_running = true;

        std.log.info("[DistributedEventBus] Listening on port {d}", .{port});

        // Start accept loop in a separate thread
        const thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        thread.detach();
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
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

                // Handle connection in new thread
                const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn }) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to spawn thread: {}", .{err});
                    conn.stream.close(self.io);
                    continue;
                };
                thread.detach();
            }
        }
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Server.Connection) void {
        defer conn.stream.close(self.io);

        var buf: [4096]u8 = undefined;
        var read_buf: [4096]u8 = undefined;
        var r = std.Io.net.Stream.reader(conn.stream, self.io, &read_buf);
        while (self.is_running) {
            const bytes_read = r.readSliceShort(&buf) catch |err| {
                if (self.is_running) {
                    std.log.err("[DistributedEventBus] Read error: {}", .{err});
                }
                break;
            };

            if (bytes_read == 0) break;

            // Parse and handle event
            if (parseEvent(buf[0..bytes_read])) |event| {
                // Publish to local bus
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
        const stream = try std.Io.net.Stream.connect(&address, self.io, .{ .mode = .stream });

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
            .source_node = "self",
            .timestamp = 0,
        };

        // Serialize event
        var buf: [4096]u8 = undefined;
        const serialized = serializeEvent(event, &buf);

        // Broadcast to all nodes
        for (self.nodes.items) |*node| {
            if (node.socket) |sock| {
                var write_buf: [4096]u8 = undefined;
                var w = std.Io.net.Stream.writer(sock, self.io, &write_buf);
                _ = w.interface.writeAll(serialized) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to send to node {s}: {}", .{ node.id, err });
                };
            }
        }

        // Also publish locally
        self.local_bus.publish(event);
    }

    /// Subscribe to events on a specific topic
    pub fn subscribe(self: *Self, topic: []const u8, callback: *const fn (NetworkEvent) void) !void {
        _ = topic;
        try self.local_bus.subscribe(callback);
    }

    fn parseEvent(data: []const u8) ?NetworkEvent {
        // Simple JSON-like parsing (in production, use proper serialization)
        // Format: {"topic":"...","payload":"...","source":"...","time":123}
        _ = data;
        return null; // Placeholder
    }

    fn serializeEvent(event: NetworkEvent, buf: []u8) []const u8 {
        // Simple JSON-like serialization
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
    var bus = DistributedEventBus.init(allocator, std.testing.io);
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
