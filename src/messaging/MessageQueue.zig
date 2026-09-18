//! Message queue abstraction over pluggable backends.
//!
//! Positioning: user-facing primitive; no in-tree consumer. The framework's own
//! messaging paths are the transactional `outbox` and the typed event buses, so
//! nothing under `src/` constructs a `MessageQueue`.
//!
//! Backend status:
//! - `in_memory` — publish and consume implemented (per-topic FIFO in process).
//! - `nats` — publish implemented; requires a live NATS server.
//! - `redis` — **publish not implemented**: `Producer.publish` returns
//!   `error.BackendUnimplemented` (the backend carries no client). Nothing is
//!   sent, and the failure is explicit rather than a silently dropped message.
//! - `kafka` — **publish not implemented**, same contract as `redis`.
//!
//! `Consumer.subscribe` only records topic names on every backend; there is no
//! delivery loop here.

const std = @import("std");
const Nats = @import("Nats.zig");

/// Message queue abstraction over pluggable in-memory, NATS, Redis and Kafka backends.
pub const MessageQueue = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: QueueBackend,

    pub const Message = struct {
        id: []const u8,
        topic: []const u8,
        payload: []const u8,
        headers: std.StringHashMap([]const u8),
        timestamp: i64,
        delivery_count: u32 = 0,
        priority: u8 = 0,
    };

    pub const QueueBackend = union(enum) {
        in_memory: *InMemoryBackend,
        nats: *NatsBackend,
        redis: RedisBackend,
        kafka: KafkaBackend,
    };

    /// Producer handle: publishes messages to the queue backend.
    pub const Producer = struct {
        backend: *QueueBackend,

        /// Publishes `msg` through the configured backend.
        ///
        /// The `redis` and `kafka` backends are not implemented: they return
        /// `error.BackendUnimplemented` and the message is *not* delivered. The
        /// error is propagated, never swallowed, so a caller cannot mistake a
        /// dropped message for a delivered one.
        pub fn publish(self: *Producer, msg: Message) !void {
            switch (self.backend.*) {
                .in_memory => |backend| try backend.publish(msg),
                .nats => |backend| try backend.publish(msg),
                .redis => |*backend| try backend.publish(msg),
                .kafka => |*backend| try backend.publish(msg),
            }
        }
    };

    /// Consumer handle: tracks the topics subscribed on the queue backend.
    pub const Consumer = struct {
        allocator: std.mem.Allocator,
        backend: *QueueBackend,
        topics: std.ArrayList([]const u8),

        pub fn init(allocator: std.mem.Allocator, backend: *QueueBackend) Consumer {
            return .{
                .allocator = allocator,
                .backend = backend,
                .topics = std.ArrayList([]const u8).empty,
            };
        }

        pub fn deinit(self: *Consumer) void {
            for (self.topics.items) |topic| {
                self.allocator.free(topic);
            }
            self.topics.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn subscribe(self: *Consumer, topic: []const u8) !void {
            const topic_copy = try self.allocator.dupe(u8, topic);
            try self.topics.append(self.allocator, topic_copy);
        }
    };

    /// In-memory backend: one FIFO queue (ArrayList) per topic.
    pub const InMemoryBackend = struct {
        allocator: std.mem.Allocator,
        queues: std.StringHashMap(std.ArrayList(Message)),

        pub fn init(allocator: std.mem.Allocator) InMemoryBackend {
            return .{
                .allocator = allocator,
                .queues = std.StringHashMap(std.ArrayList(Message)).init(allocator),
            };
        }

        pub fn deinit(self: *InMemoryBackend) void {
            var iter = self.queues.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.queues.deinit();
            self.* = undefined;
        }

        pub fn publish(self: *InMemoryBackend, msg: Message) !void {
            const queue = self.queues.getPtr(msg.topic) orelse blk: {
                const new_queue = std.ArrayList(Message).empty;
                try self.queues.put(msg.topic, new_queue);
                break :blk self.queues.getPtr(msg.topic).?;
            };
            try queue.append(self.allocator, msg);
        }

        pub fn consume(self: *InMemoryBackend, topic: []const u8) !?Message {
            const queue = self.queues.getPtr(topic) orelse return null;
            if (queue.items.len == 0) return null;
            return queue.orderedRemove(0);
        }
    };

    /// Redis queue backend — declared but has no client.
    ///
    /// `publish` always fails with `error.BackendUnimplemented`; sending is not
    /// supported yet, and this backend never silently drops a message.
    pub const RedisBackend = struct {
        host: []const u8,
        port: u16,

        pub fn publish(self: *RedisBackend, msg: Message) !void {
            _ = self;
            _ = msg;
            return error.BackendUnimplemented;
        }
    };

    /// Kafka queue backend — declared but has no client.
    ///
    /// `publish` always fails with `error.BackendUnimplemented`; sending is not
    /// supported yet, and this backend never silently drops a message.
    pub const KafkaBackend = struct {
        brokers: []const []const u8,

        pub fn publish(self: *KafkaBackend, msg: Message) !void {
            _ = self;
            _ = msg;
            return error.BackendUnimplemented;
        }
    };

    /// NATS message queue backend (default: localhost:4222).
    pub const NatsBackend = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        client: Nats.NatsClient,

        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Nats.NatsConfig) !NatsBackend {
            var client = Nats.NatsClient.init(allocator, io, config);
            try client.connect();
            return .{ .allocator = allocator, .io = io, .client = client };
        }

        pub fn deinit(self: *NatsBackend) void {
            self.client.deinit();
            self.* = undefined;
        }

        pub fn publish(self: *NatsBackend, msg: Message) !void {
            try self.client.publish(msg.topic, msg.payload);
        }
    };

    pub fn init(allocator: std.mem.Allocator, backend: QueueBackend) Self {
        return .{
            .allocator = allocator,
            .backend = backend,
        };
    }

    pub fn createProducer(self: *Self) Producer {
        return .{ .backend = &self.backend };
    }

    pub fn createConsumer(self: *Self) Consumer {
        return Consumer.init(self.allocator, &self.backend);
    }
};

test "MessageQueue InMemoryBackend publish and consume" {
    const allocator = std.testing.allocator;
    var backend = MessageQueue.InMemoryBackend.init(allocator);
    defer backend.deinit();

    const msg = MessageQueue.Message{
        .id = "msg-1",
        .topic = "orders",
        .payload = "{\"order_id\":123}",
        .headers = std.StringHashMap([]const u8).init(allocator),
        .timestamp = 0,
    };

    try backend.publish(msg);
    const consumed = try backend.consume("orders");
    try std.testing.expect(consumed != null);
    try std.testing.expectEqualStrings("msg-1", consumed.?.id);
    try std.testing.expectEqualStrings("orders", consumed.?.topic);

    const empty = try backend.consume("orders");
    try std.testing.expect(empty == null);
}

test "MessageQueue Producer and Consumer" {
    const allocator = std.testing.allocator;
    var backend = MessageQueue.InMemoryBackend.init(allocator);
    defer backend.deinit();

    var mq = MessageQueue.init(allocator, .{ .in_memory = &backend });
    var producer = mq.createProducer();
    var consumer = mq.createConsumer();
    defer consumer.deinit();

    try consumer.subscribe("events");
    try std.testing.expectEqual(@as(usize, 1), consumer.topics.items.len);
    try std.testing.expectEqualStrings("events", consumer.topics.items[0]);

    const msg = MessageQueue.Message{
        .id = "evt-1",
        .topic = "events",
        .payload = "hello",
        .headers = std.StringHashMap([]const u8).init(allocator),
        .timestamp = 0,
    };

    try producer.publish(msg);
    const consumed = try backend.consume("events");
    try std.testing.expect(consumed != null);
    try std.testing.expectEqualStrings("hello", consumed.?.payload);
}

test "MessageQueue unimplemented backends fail publish explicitly" {
    const allocator = std.testing.allocator;

    const msg = MessageQueue.Message{
        .id = "msg-unimpl",
        .topic = "events",
        .payload = "must-not-be-dropped-silently",
        .headers = std.StringHashMap([]const u8).init(allocator),
        .timestamp = 0,
    };

    var redis_backend = MessageQueue.RedisBackend{ .host = "127.0.0.1", .port = 6379 };
    try std.testing.expectError(error.BackendUnimplemented, redis_backend.publish(msg));

    var redis_mq = MessageQueue.init(allocator, .{ .redis = redis_backend });
    var redis_producer = redis_mq.createProducer();
    try std.testing.expectError(error.BackendUnimplemented, redis_producer.publish(msg));

    var kafka_backend = MessageQueue.KafkaBackend{ .brokers = &.{"127.0.0.1:9092"} };
    try std.testing.expectError(error.BackendUnimplemented, kafka_backend.publish(msg));

    var kafka_mq = MessageQueue.init(allocator, .{ .kafka = kafka_backend });
    var kafka_producer = kafka_mq.createProducer();
    try std.testing.expectError(error.BackendUnimplemented, kafka_producer.publish(msg));
}
