const std = @import("std");
const Nats = @import("Nats.zig");

/// 消息队列抽象接口
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

    /// 生产者
    pub const Producer = struct {
        backend: *QueueBackend,

        pub fn publish(self: *Producer, msg: Message) !void {
            switch (self.backend.*) {
                .in_memory => |backend| try backend.publish(msg),
                .nats => |backend| try backend.publish(msg),
                .redis => {},
                .kafka => {},
            }
        }
    };

    /// 消费者
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
        }

        pub fn subscribe(self: *Consumer, topic: []const u8) !void {
            const topic_copy = try self.allocator.dupe(u8, topic);
            try self.topics.append(self.allocator, topic_copy);
        }
    };

    /// 内存后端
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

    pub const RedisBackend = struct {
        host: []const u8,
        port: u16,
    };

    pub const KafkaBackend = struct {
        brokers: []const []const u8,
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
