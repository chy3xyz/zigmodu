const std = @import("std");
const Time = @import("Time.zig");
const sockread = @import("sockread.zig");
const TypedEventBus = @import("EventBus.zig").TypedEventBus;
const ArrayList = std.array_list.Managed;

const WAL = @import("eventbus/WAL.zig").WAL;
const WALConfig = @import("eventbus/WAL.zig").WALConfig;
const DLQ = @import("eventbus/DLQ.zig").DLQ;
const DLQConfig = @import("eventbus/DLQ.zig").DLQConfig;
const RequeuedMessage = @import("eventbus/DLQ.zig").RequeuedMessage;
const Partitioner = @import("eventbus/Partitioner.zig").ConsistentHashPartitioner;

/// Distributed Event Bus for cross-node communication
/// Allows events to be published and subscribed across multiple processes/machines
pub const DistributedEventBus = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    local_bus: TypedEventBus(NetworkEvent),
    topic_callbacks: std.StringHashMap(std.ArrayList(TopicHandler)),
    nodes: ArrayList(Node),
    listener: ?std.Io.net.Server,
    is_running: bool,
    node_id: []const u8,
    heartbeat_thread: ?std.Thread,
    /// Owns accept/handle/heartbeat fibers; awaited in `stop()`.
    fiber_group: std.Io.Group,

    /// Optional distributed components
    partitioner: ?*Partitioner = null,
    wal: ?*WAL = null,
    dlq: ?*DLQ = null,

    /// Soft backpressure: skip fan-out after this many consecutive send failures per node.
    max_send_failures: u32 = 8,

    /// True while the DLQ retry fiber is running.
    dlq_retry_running: bool = false,

    pub const NetworkEvent = struct {
        topic: []const u8,
        payload: []const u8,
        source_node: []const u8,
        timestamp: i64,
    };

    /// Topic subscription handler — plain fn or context-carrying callback.
    pub const TopicHandler = union(enum) {
        plain: *const fn (NetworkEvent) void,
        with_ctx: struct {
            ctx: *anyopaque,
            func: *const fn (*anyopaque, NetworkEvent) void,
        },

        fn invoke(self: TopicHandler, event: NetworkEvent) void {
            switch (self) {
                .plain => |f| f(event),
                .with_ctx => |w| w.func(w.ctx, event),
            }
        }
    };

    const Node = struct {
        id: []const u8,
        address: std.Io.net.IpAddress,
        socket: ?std.Io.net.Stream,
        last_seen: i64,
        send_failures: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, node_id: []const u8) !Self {
        const id_copy = try allocator.dupe(u8, node_id);
        errdefer allocator.free(id_copy);
        return .{
            .allocator = allocator,
            .io = io,
            .local_bus = TypedEventBus(NetworkEvent).init(allocator),
            .topic_callbacks = std.StringHashMap(std.ArrayList(TopicHandler)).init(allocator),
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
        self.* = undefined;
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

        // Start DLQ retry fiber if a DLQ has been configured.
        if (self.dlq != null and !self.dlq_retry_running) {
            self.dlq_retry_running = true;
            self.fiber_group.async(self.io, dlqRetryLoop, .{self});
        }
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

                // Handle connection in the shared group. Use `concurrent` (not
                // `async`): handleConnection blocks on peer reads, and `async`'s
                // eager fallback at async_limit would run it on the accept
                // thread and freeze the accept loop.
                self.fiber_group.concurrent(self.io, handleConnection, .{ self, conn }) catch |err| {
                    std.log.warn("[DistributedEventBus] connection rejected (concurrent limit): {}", .{err});
                    conn.close(self.io);
                    continue;
                };
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

        // Use an Arena for parsing-related allocations that can be cleared per message
        var msg_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer msg_arena.deinit();

        while (self.is_running) {
            const ma = msg_arena.allocator();

            // Raw read: io-based socket reads can hang when the io is shared
            // across threads (see core/sockread.zig).
            var read_buf: [8192]u8 = undefined;
            const n = sockread.readSome(conn, &read_buf) catch |err| {
                if (self.is_running) std.log.debug("[DEB] Read error: {}", .{err});
                break;
            };

            if (n == 0) break;
            const data = read_buf[0..n];

            // Parse using our arena to avoid multiple tiny heap allocations
            if (parseEvent(ma, data)) |event| {
                // Topic callback lookup is fast with StringHashMap
                if (std.mem.eql(u8, event.topic, "__heartbeat")) {
                    continue;
                }

                self.publishToTopic(event);

                // Local bus dispatch
                self.local_bus.publish(event);
            } else if (self.dlq) |_| {
                // Deserialization failed — push to DLQ for later inspection
                self.pushParseFailureToDlq(data);
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
        // Write to WAL for crash recovery if configured
        if (self.wal) |w| {
            _ = w.append(.{
                .topic = topic,
                .payload = payload,
                .source_node = self.node_id,
                .timestamp_ms = Time.monotonicNowMilliseconds(),
            }) catch |err| {
                std.log.err("[DistributedEventBus] WAL append failed: {}", .{err});
            };
        }

        const event = NetworkEvent{
            .topic = topic,
            .payload = payload,
            .source_node = self.node_id,
            .timestamp = Time.monotonicNowSeconds(),
        };

        // Serialize event
        var buf: [4096]u8 = undefined;
        const serialized = serializeEvent(event, &buf);

        // Route via partitioner if configured; otherwise broadcast.
        var routed = false;
        if (self.partitioner) |p| {
            if (p.route(topic)) |target_node| {
                if (std.mem.eql(u8, target_node, self.node_id)) {
                    // This node owns the partition — skip network fan-out.
                    routed = true;
                } else {
                    for (self.nodes.items) |*node| {
                        if (std.mem.eql(u8, node.id, target_node)) {
                            routed = self.sendToNode(node, topic, payload, serialized);
                            break;
                        }
                    }
                }
                if (routed) {
                    std.log.info("[DistributedEventBus] Partitioned event '{s}' -> node {s}", .{ topic, target_node });
                } else {
                    std.log.warn("[DistributedEventBus] Partition target '{s}' -> {s} unreachable, falling back to broadcast", .{ topic, target_node });
                }
            } else {
                std.log.warn("[DistributedEventBus] No partition target for '{s}'", .{topic});
            }
        }

        if (!routed) {
            // Broadcast to all connected nodes with soft backpressure on failing sockets
            for (self.nodes.items) |*node| {
                _ = self.sendToNode(node, topic, payload, serialized);
            }
        }

        // Also publish locally
        self.publishToTopic(event);
        self.local_bus.publish(event);
    }

    /// Send a serialized event to a single node. Returns true on success.
    /// On failure, increments the node failure counter. The message is pushed to
    /// the DLQ only when the cumulative failures reach `max_send_failures`
    /// (immediately before the node is quarantined).
    fn sendToNode(self: *Self, node: *Node, topic: []const u8, payload: []const u8, serialized: []const u8) bool {
        if (node.send_failures >= self.max_send_failures) return false;
        if (node.socket) |sock| {
            var write_buf: [4096]u8 = undefined;
            var w = sock.writer(self.io, &write_buf);
            w.interface.writeAll(serialized) catch |err| {
                self.recordSendFailure(node, sock, topic, payload, err);
                return false;
            };
            w.interface.flush() catch |err| {
                self.recordSendFailure(node, sock, topic, payload, err);
                return false;
            };
            node.send_failures = 0;
            return true;
        }
        return false;
    }

    fn recordSendFailure(self: *Self, node: *Node, sock: std.Io.net.Stream, topic: []const u8, payload: []const u8, err: anyerror) void {
        node.send_failures += 1;
        std.log.err("[DistributedEventBus] Failed to send to node {s} (failures={d}): {}", .{ node.id, node.send_failures, err });
        if (node.send_failures >= self.max_send_failures) {
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "Send failed: {}", .{err}) catch "Send failed";
            self.pushToDlq(topic, payload, "SendError", err_msg);
            std.log.warn("[DistributedEventBus] Quarantining node {s} after {d} send failures", .{ node.id, node.send_failures });
            sock.close(self.io);
            node.socket = null;
        }
    }

    fn publishToTopic(self: *Self, event: NetworkEvent) void {
        if (self.topic_callbacks.get(event.topic)) |callbacks| {
            for (callbacks.items) |handler| {
                handler.invoke(event);
            }
        }
    }

    /// Subscribe to events on a specific topic (no context).
    pub fn subscribe(self: *Self, topic: []const u8, callback: *const fn (NetworkEvent) void) !void {
        try self.subscribeHandler(topic, .{ .plain = callback });
    }

    /// Subscribe with an opaque context pointer — used by ClusterMembership etc.
    pub fn subscribeWithContext(
        self: *Self,
        topic: []const u8,
        ctx: *anyopaque,
        callback: *const fn (*anyopaque, NetworkEvent) void,
    ) !void {
        try self.subscribeHandler(topic, .{ .with_ctx = .{ .ctx = ctx, .func = callback } });
    }

    fn subscribeHandler(self: *Self, topic: []const u8, handler: TopicHandler) !void {
        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);

        const gop = try self.topic_callbacks.getOrPut(topic_copy);
        if (!gop.found_existing) {
            gop.key_ptr.* = topic_copy;
            gop.value_ptr.* = std.ArrayList(TopicHandler).empty;
        } else {
            self.allocator.free(topic_copy);
        }
        try gop.value_ptr.append(self.allocator, handler);
    }

    /// Unsubscribe a plain callback from a topic
    pub fn unsubscribe(self: *Self, topic: []const u8, callback: *const fn (NetworkEvent) void) void {
        if (self.topic_callbacks.getPtr(topic)) |callbacks| {
            for (callbacks.items, 0..) |h, i| {
                switch (h) {
                    .plain => |f| if (f == callback) {
                        _ = callbacks.swapRemove(i);
                        return;
                    },
                    .with_ctx => {},
                }
            }
        }
    }

    pub fn unsubscribeContext(self: *Self, topic: []const u8, ctx: *anyopaque) void {
        if (self.topic_callbacks.getPtr(topic)) |callbacks| {
            for (callbacks.items, 0..) |h, i| {
                switch (h) {
                    .with_ctx => |w| if (w.ctx == ctx) {
                        _ = callbacks.swapRemove(i);
                        return;
                    },
                    .plain => {},
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

    /// Connect to a remote node. The node is registered for routing immediately;
    /// the outbound socket is established opportunistically and may remain null.
    pub fn connectToNode(self: *Self, node_id: []const u8, address: std.Io.net.IpAddress) !void {
        // Prevent duplicate entries.
        for (self.nodes.items) |node| {
            if (std.mem.eql(u8, node.id, node_id)) {
                // Reconcile partitioner state in case the node was removed
                // from the ring while still being tracked here.
                if (self.partitioner) |p| {
                    if (!p.nodes.contains(node_id)) {
                        p.addNode(node_id) catch |err| {
                            std.log.err("[DistributedEventBus] Failed to re-add duplicate node {s} to partitioner: {}", .{ node_id, err });
                        };
                    }
                }
                return;
            }
        }

        const id_copy = try self.allocator.dupe(u8, node_id);
        errdefer self.allocator.free(id_copy);

        var stream: ?std.Io.net.Stream = null;
        stream = address.connect(self.io, .{ .mode = .stream }) catch |err| blk: {
            std.log.warn("[DistributedEventBus] Connection to {s} at {any} failed: {}", .{ node_id, address, err });
            break :blk null;
        };
        errdefer if (stream) |s| s.close(self.io);

        try self.nodes.append(.{
            .id = id_copy,
            .address = address,
            .socket = stream,
            .last_seen = Time.monotonicNowSeconds(),
            .send_failures = 0,
        });

        if (self.partitioner) |p| {
            if (!p.nodes.contains(node_id)) {
                p.addNode(node_id) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to add node {s} to partitioner: {}", .{ node_id, err });
                };
            }
        }
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
                if (self.partitioner) |p| {
                    p.removeNode(node_id);
                }
                std.log.info("[DistributedEventBus] Disconnected from node {s}", .{node_id});
                return;
            }
        }
    }

    /// Return this node's identifier.
    pub fn nodeId(self: *Self) []const u8 {
        return self.node_id;
    }

    /// Total cluster size including this node.
    pub fn clusterSize(self: *Self) usize {
        return 1 + self.nodes.items.len;
    }

    /// Set the consistent-hash partitioner for event routing
    pub fn setPartitioner(self: *Self, p: *Partitioner) void {
        self.partitioner = p;
        // Ensure the ring reflects the current topology.
        if (!p.nodes.contains(self.node_id)) {
            p.addNode(self.node_id) catch |err| {
                std.log.err("[DistributedEventBus] Failed to add self to partitioner: {}", .{err});
            };
        }
        for (self.nodes.items) |node| {
            if (!p.nodes.contains(node.id)) {
                p.addNode(node.id) catch |err| {
                    std.log.err("[DistributedEventBus] Failed to add node {s} to partitioner: {}", .{ node.id, err });
                };
            }
        }
    }

    /// Set the write-ahead log for crash recovery
    pub fn setWal(self: *Self, w: *WAL) void {
        self.wal = w;
    }

    /// Set the dead-letter queue for failed messages and start the retry loop
    /// if the bus is already running.
    pub fn setDlq(self: *Self, d: *DLQ) void {
        self.dlq = d;
        if (self.is_running and !self.dlq_retry_running) {
            self.dlq_retry_running = true;
            self.fiber_group.async(self.io, dlqRetryLoop, .{self});
        }
    }

    /// Periodic fiber that purges expired DLQ entries and requeues retryable ones.
    fn dlqRetryLoop(self: *Self) void {
        defer self.dlq_retry_running = false;
        while (self.is_running) {
            if (self.dlq) |dlq| {
                _ = dlq.purgeExpired() catch |err| {
                    std.log.err("[DistributedEventBus] DLQ purgeExpired failed: {}", .{err});
                };
                _ = dlq.requeue(self, &dlqRequeueCallback) catch |err| {
                    std.log.err("[DistributedEventBus] DLQ requeue failed: {}", .{err});
                };
            } else break;
            std.Io.sleep(self.io, .{ .nanoseconds = 1_000_000_000 }, .real) catch break; // 1 second
        }
    }

    fn dlqRequeueCallback(ctx: *anyopaque, msg: RequeuedMessage) void {
        const bus: *Self = @ptrCast(@alignCast(ctx));
        bus.publish(msg.topic, msg.payload) catch |err| {
            std.log.err("[DistributedEventBus] DLQ requeue republish failed: {}", .{err});
        };
    }

    /// Manually trigger a DLQ requeue cycle. Useful for tests and for callers
    /// that want to retry failed messages on demand instead of waiting for the fiber.
    pub fn requeueDlqEntries(self: *Self) !usize {
        const dlq = self.dlq orelse return 0;
        return dlq.requeue(self, &dlqRequeueCallback);
    }

    /// Replay events from WAL starting after the last committed position.
    /// Republishes each recovered event through the local bus.
    pub fn replayFromWal(self: *Self) !void {
        const w = self.wal orelse return;
        const from_seq = w.lastCommittedIndex() + 1;
        const entries = try w.readFrom(from_seq);
        defer {
            for (entries) |entry| {
                self.allocator.free(entry.topic);
                self.allocator.free(entry.payload);
                self.allocator.free(entry.source_node);
            }
            self.allocator.free(entries);
        }
        for (entries) |entry| {
            const event = NetworkEvent{
                .topic = entry.topic,
                .payload = entry.payload,
                .source_node = entry.source_node,
                .timestamp = entry.timestamp_ms,
            };
            self.publishToTopic(event);
            self.local_bus.publish(event);
        }
        std.log.info("[DistributedEventBus] Replayed {d} events from WAL (start={d})", .{ entries.len, from_seq });
    }

    /// Push raw data that failed deserialization into the DLQ.
    /// Used internally by handleConnection; also callable from tests.
    fn pushParseFailureToDlq(self: *Self, raw_data: []const u8) void {
        self.pushToDlq("unknown", raw_data, "ParseError", "Failed to deserialize event");
    }

    /// Push a failed message to the DLQ if one is configured.
    fn pushToDlq(self: *Self, topic: []const u8, payload: []const u8, error_type: []const u8, error_message: []const u8) void {
        const dlq = self.dlq orelse return;
        dlq.push(.{
            .topic = topic,
            .payload = payload,
            .error_type = error_type,
            .error_message = error_message,
            .retry_count = 0,
        }) catch |err| {
            std.log.err("[DistributedEventBus] DLQ push failed: {}", .{err});
        };
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

test "DistributedEventBus with WAL persistence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wal_config = WALConfig{ .dir_path = "wal_test_deb", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, wal_config);
    defer wal.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node-wal");
    defer bus.deinit();

    bus.setWal(&wal);

    try bus.publish("test-topic", "msg-1");
    try bus.publish("test-topic", "msg-2");
    try bus.publish("test-topic", "msg-3");

    // Verify events were written to WAL
    try std.testing.expectEqual(@as(u64, 3), wal.lastIndex());

    // replayFromWal should not error (may return empty if readFrom is stub)
    try bus.replayFromWal();
}

test "DistributedEventBus DLQ on parse failure" {
    const allocator = std.testing.allocator;

    const dlq_config = DLQConfig{
        .max_age_seconds = 60,
        .retry_cooldown_seconds = 1,
        .max_retries = 3,
        .storage = .memory,
    };
    var dlq = try DLQ.init(allocator, dlq_config);
    defer dlq.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "test-node-dlq");
    defer bus.deinit();

    bus.setDlq(&dlq);

    try std.testing.expectEqual(@as(usize, 0), dlq.size());

    // Simulate parse failure by pushing malformed data through the internal helper
    bus.pushParseFailureToDlq("garbage-non-json-data");

    try std.testing.expectEqual(@as(usize, 1), dlq.size());
}

test "DistributedEventBus partitioner adds and removes nodes" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var partitioner = Partitioner.init(allocator, .{ .virtual_nodes_per_node = 10 });
    defer partitioner.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "node-1");
    defer bus.deinit();

    bus.setPartitioner(&partitioner);

    // Self is registered automatically.
    try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19001);
    try bus.connectToNode("node-2", addr);

    try std.testing.expectEqual(@as(usize, 2), bus.clusterSize());
    try std.testing.expectEqual(@as(usize, 2), partitioner.nodeCount());

    bus.disconnectNode("node-2");

    try std.testing.expectEqual(@as(usize, 1), bus.clusterSize());
    try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());

    // Routing falls back to broadcast when the ring is empty.
    try bus.publish("orders.created", "payload");
}

test "DistributedEventBus DLQ send failure and requeue republish" {
    const allocator = std.testing.allocator;

    var dlq = try DLQ.init(allocator, .{
        .max_age_seconds = 60,
        .retry_cooldown_seconds = 0,
        .max_retries = 3,
        .storage = .memory,
    });
    defer dlq.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "dlq-replay");
    defer bus.deinit();

    bus.setDlq(&dlq);

    var received: bool = false;
    const Listener = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "retry.topic") and std.mem.eql(u8, evt.payload, "retry-payload")) {
                flag.* = true;
            }
        }
    };
    Listener.flag = &received;
    try bus.subscribe("retry.topic", Listener.cb);

    // Simulate a send failure landing in the DLQ.
    bus.pushToDlq("retry.topic", "retry-payload", "SendError", "simulated send failure");
    try std.testing.expectEqual(@as(usize, 1), dlq.size());

    // Manually trigger a DLQ requeue; the context-backed callback should republish through this bus.
    const requeued = try bus.requeueDlqEntries();
    try std.testing.expectEqual(@as(usize, 1), requeued);
    try std.testing.expect(received);
}

test "DistributedEventBus WAL replay triggers local subscribers" {
    const allocator = std.testing.allocator;

    const wal_config = WALConfig{ .dir_path = "wal_test_deb", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, wal_config);
    defer wal.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "wal-replay-bus");
    defer bus.deinit();
    bus.setWal(&wal);

    var received: usize = 0;
    const Listener = struct {
        var count: *usize = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "replay.topic")) {
                count.* += 1;
            }
        }
    };
    Listener.count = &received;
    try bus.subscribe("replay.topic", Listener.cb);

    try bus.publish("replay.topic", "msg-1");
    try bus.publish("replay.topic", "msg-2");

    // Reset counter and replay only uncommitted entries.
    received = 0;
    wal.markCommitted(1);
    try bus.replayFromWal();

    try std.testing.expectEqual(@as(usize, 1), received);
}

test "DistributedEventBus DLQ requeue routes to owning bus" {
    const allocator = std.testing.allocator;

    const config = DLQConfig{
        .max_age_seconds = 60,
        .retry_cooldown_seconds = 0,
        .max_retries = 3,
        .storage = .memory,
    };

    var dlq_a = try DLQ.init(allocator, config);
    defer dlq_a.deinit();
    var dlq_b = try DLQ.init(allocator, config);
    defer dlq_b.deinit();

    var bus_a = try DistributedEventBus.init(allocator, std.testing.io, "bus-a");
    defer bus_a.deinit();
    bus_a.setDlq(&dlq_a);

    var bus_b = try DistributedEventBus.init(allocator, std.testing.io, "bus-b");
    defer bus_b.deinit();
    bus_b.setDlq(&dlq_b);

    var received_a: bool = false;
    var received_b: bool = false;

    const ListenerA = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "topic.a") and std.mem.eql(u8, evt.payload, "payload-a")) {
                flag.* = true;
            }
        }
    };
    ListenerA.flag = &received_a;

    const ListenerB = struct {
        var flag: *bool = undefined;
        fn cb(evt: DistributedEventBus.NetworkEvent) void {
            if (std.mem.eql(u8, evt.topic, "topic.b") and std.mem.eql(u8, evt.payload, "payload-b")) {
                flag.* = true;
            }
        }
    };
    ListenerB.flag = &received_b;

    try bus_a.subscribe("topic.a", ListenerA.cb);
    try bus_b.subscribe("topic.b", ListenerB.cb);

    bus_a.pushToDlq("topic.a", "payload-a", "SendError", "simulated");
    bus_b.pushToDlq("topic.b", "payload-b", "SendError", "simulated");

    const requeued_a = try bus_a.requeueDlqEntries();
    try std.testing.expectEqual(@as(usize, 1), requeued_a);
    try std.testing.expect(received_a);
    try std.testing.expect(!received_b);

    const requeued_b = try bus_b.requeueDlqEntries();
    try std.testing.expectEqual(@as(usize, 1), requeued_b);
    try std.testing.expect(received_b);
}

test "DistributedEventBus duplicate connect reconciles partitioner" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    var partitioner = Partitioner.init(allocator, .{ .virtual_nodes_per_node = 10 });
    defer partitioner.deinit();

    var bus = try DistributedEventBus.init(allocator, std.testing.io, "node-1");
    defer bus.deinit();

    bus.setPartitioner(&partitioner);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 19002);
    try bus.connectToNode("node-2", addr);
    try std.testing.expectEqual(@as(usize, 2), partitioner.nodeCount());

    // Simulate an external subsystem removing the node from the ring.
    partitioner.removeNode("node-2");
    try std.testing.expectEqual(@as(usize, 1), partitioner.nodeCount());

    // Reconnecting the same logical node should add it back to the ring.
    try bus.connectToNode("node-2", addr);
    try std.testing.expectEqual(@as(usize, 2), partitioner.nodeCount());
}
