const std = @import("std");
const EventBus = @import("EventBus.zig").EventBus;

/// Distributed Event Bus for cross-node communication
/// Allows events to be published and subscribed across multiple processes/machines
pub const DistributedEventBus = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    local_bus: EventBus(NetworkEvent),
    nodes: std.ArrayList(Node),
    listener: ?std.net.Server,
    is_running: bool,

    const NetworkEvent = struct {
        topic: []const u8,
        payload: []const u8,
        source_node: []const u8,
        timestamp: i64,
    };

    const Node = struct {
        id: []const u8,
        address: std.net.Address,
        socket: ?std.net.Stream,
        last_seen: i64,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .local_bus = EventBus(NetworkEvent).init(allocator),
            .nodes = std.ArrayList(Node).init(allocator),
            .listener = null,
            .is_running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.local_bus.deinit();

        for (self.nodes.items) |*node| {
            if (node.socket) |sock| {
                sock.close();
            }
            self.allocator.free(node.id);
        }
        self.nodes.deinit();
    }

    /// Start listening for incoming connections
    pub fn start(self: *Self, port: u16) !void {
        if (self.is_running) return;

        const address = try std.net.Address.parseIp4("0.0.0.0", port);
        self.listener = try std.net.Server.init(address, .{});
        self.is_running = true;

        std.log.info("[DistributedEventBus] Listening on port {d}", .{port});

        // Start accept loop in a separate thread
        const thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        thread.detach();
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
    }

    fn acceptLoop(self: *Self) void {
        while (self.is_running) {
            if (self.listener) |*l| {
                const conn = l.accept() catch |err| {
                    if (self.is_running) {
                        std.log.err("[DistributedEventBus] Accept error: {}", .{err});
                    }
                    continue;
                };

                // Handle connection in new thread
                const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn }) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to spawn thread: {}", .{err});
                    conn.stream.close();
                    continue;
                };
                thread.detach();
            }
        }
    }

    fn handleConnection(self: *Self, conn: std.net.Server.Connection) void {
        defer conn.stream.close();

        var buf: [4096]u8 = undefined;
        while (self.is_running) {
            const bytes_read = conn.stream.read(&buf) catch |err| {
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
    pub fn connectToNode(self: *Self, node_id: []const u8, address: std.net.Address) !void {
        const stream = try std.net.tcpConnectToAddress(address);

        const id_copy = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(id_copy);

        try self.nodes.append(.{
            .id = id_copy,
            .address = address,
            .socket = stream,
            .last_seen = std.time.timestamp(),
        });

        std.log.info("[DistributedEventBus] Connected to node {s} at {}", .{ node_id, address });
    }

    /// Publish event to all connected nodes
    pub fn publish(self: *Self, topic: []const u8, payload: []const u8) !void {
        const event = NetworkEvent{
            .topic = topic,
            .payload = payload,
            .source_node = "self",
            .timestamp = std.time.timestamp(),
        };

        // Serialize event
        var buf: [4096]u8 = undefined;
        const serialized = serializeEvent(event, &buf);

        // Broadcast to all nodes
        for (self.nodes.items) |*node| {
            if (node.socket) |sock| {
                _ = sock.write(serialized) catch |err| {
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
        // Filter callback by topic
        const wrapped_callback = struct {
            fn wrapper(event: NetworkEvent) void {
                // In real implementation, filter by topic
                callback(event);
            }
        }.wrapper;

        try self.local_bus.subscribe(wrapped_callback);
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
