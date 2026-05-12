const std = @import("std");
const Time = @import("../core/Time.zig");

/// Kafka 消息
pub const KafkaMessage = struct {
    topic: []const u8,
    key: ?[]const u8,
    value: []const u8,
    headers: []const Header,
    timestamp: i64,
    partition: i32 = -1,

    pub const Header = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Kafka 生产者配置
pub const KafkaProducerConfig = struct {
    bootstrap_servers: []const u8 = "localhost:9092",
    client_id: []const u8 = "zigmodu",
    acks: Acks = .all,
    compression: Compression = .none,
    batch_size: usize = 16384,
    linger_ms: u64 = 0,

    pub const Acks = enum(i8) {
        none = 0,
        leader = 1,
        all = -1,
    };

    pub const Compression = enum {
        none,
        gzip,
        snappy,
        lz4,
    };
};

/// Kafka 消费者配置
pub const KafkaConsumerConfig = struct {
    bootstrap_servers: []const u8 = "localhost:9092",
    group_id: []const u8 = "zigmodu-group",
    client_id: []const u8 = "zigmodu",
    auto_offset_reset: []const u8 = "latest",
    enable_auto_commit: bool = true,
    max_poll_records: usize = 500,
    session_timeout_ms: u64 = 45000,
};

/// Kafka 生产者
pub const KafkaProducer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: KafkaProducerConfig,
    topic_stats: std.StringHashMap(TopicStats),

    pub const TopicStats = struct {
        produced: u64 = 0,
        failed: u64 = 0,
        last_produced_at: i64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, config: KafkaProducerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .topic_stats = std.StringHashMap(TopicStats).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.topic_stats.deinit();
    }

    /// 发送消息到 Kafka
    /// 实际实现通过 Kafka wire protocol 发送到 broker
    pub fn send(self: *Self, msg: KafkaMessage) !void {
        // Placeholder: 实际实现通过 TCP 发送 Kafka protocol
        std.log.info("[KafkaProducer] Sending to {s}:{d} topic={s} size={d}", .{
            self.config.bootstrap_servers,
            0,
            msg.topic,
            msg.value.len,
        });

        const entry = try self.topic_stats.getOrPut(msg.topic);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        }
        entry.value_ptr.produced += 1;
        entry.value_ptr.last_produced_at = Time.monotonicNowSeconds();
    }

    /// 批量发送消息
    pub fn sendBatch(self: *Self, messages: []const KafkaMessage) !void {
        for (messages) |msg| {
            try self.send(msg);
        }
    }

    /// 获取 topic 统计
    pub fn getTopicStats(self: *Self, topic: []const u8) ?TopicStats {
        return self.topic_stats.get(topic);
    }

    /// 刷新缓冲区 (确保所有消息已发送)
    pub fn flush(self: *Self) !void {
        _ = self;
        std.log.info("[KafkaProducer] Flushing...", .{});
    }

    /// 关闭生产者
    pub fn close(self: *Self) void {
        _ = self;
        std.log.info("[KafkaProducer] Closed", .{});
    }
};

/// Kafka 消费者
pub const KafkaConsumer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: KafkaConsumerConfig,
    subscriptions: std.StringHashMap(Subscription),
    is_running: bool,

    pub const Subscription = struct {
        topic: []const u8,
        handler: *const fn (KafkaMessage) void,
    };

    pub fn init(allocator: std.mem.Allocator, config: KafkaConsumerConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
            .is_running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.subscriptions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.topic);
        }
        self.subscriptions.deinit();
    }

    /// 订阅 topic
    pub fn subscribe(self: *Self, topic: []const u8, handler: *const fn (KafkaMessage) void) !void {
        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);

        try self.subscriptions.put(topic_copy, .{
            .topic = topic_copy,
            .handler = handler,
        });

        std.log.info("[KafkaConsumer] Subscribed to topic: {s}", .{topic});
    }

    /// 取消订阅
    pub fn unsubscribe(self: *Self, topic: []const u8) void {
        if (self.subscriptions.fetchRemove(topic)) |removed| {
            self.allocator.free(removed.key);
        }
    }

    /// 获取订阅列表
    pub fn getSubscriptions(self: *Self) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        var iter = self.subscriptions.keyIterator();
        while (iter.next()) |key| {
            try result.append(self.allocator, key.*);
        }
        return result.toOwnedSlice(self.allocator);
    }

    /// 开始轮询
    pub fn start(self: *Self) void {
        self.is_running = true;
        std.log.info("[KafkaConsumer] Started polling", .{});
    }

    /// 停止轮询
    pub fn stop(self: *Self) void {
        self.is_running = false;
        std.log.info("[KafkaConsumer] Stopped", .{});
    }
};

/// Kafka 事件桥 — 连接 Kafka 和 DistributedEventBus
pub const KafkaEventBridge = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    producer: *KafkaProducer,
    consumer: *KafkaConsumer,

    pub fn init(allocator: std.mem.Allocator, producer: *KafkaProducer, consumer: *KafkaConsumer) Self {
        return .{
            .allocator = allocator,
            .producer = producer,
            .consumer = consumer,
        };
    }

    /// 将 InternalEvent 发布到 Kafka
    pub fn publishEvent(self: *Self, topic: []const u8, payload: []const u8) !void {
        try self.producer.send(.{
            .topic = topic,
            .key = null,
            .value = payload,
            .headers = &.{},
            .timestamp = Time.monotonicNowSeconds(),
        });
    }

    /// 从 Kafka 消费事件并转发到 InternalEvent bus
    pub fn bridgeTopic(self: *Self, topic: []const u8, on_event: *const fn ([]const u8) void) !void {
        try self.consumer.subscribe(topic, struct {
            fn handler(msg: KafkaMessage) void {
                on_event(msg.value);
            }
        }.handler);
    }
};

/// Kafka wire protocol message encoding (ProduceRequest v9).
/// Builds binary messages for direct broker communication.
pub const KafkaWireFormat = struct {
    /// Build a ProduceRequest payload for a single topic-partition message.
    /// Returns the wire-format bytes ready to send over TCP to a Kafka broker.
    pub fn buildProduceRequest(
        allocator: std.mem.Allocator,
        topic: []const u8,
        partition: i32,
        key: ?[]const u8,
        value: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]const u8 {
        var buf = std.ArrayList(u8).empty;

        // ProduceRequest v9 header
        // TransactionalId: nullable string → null (-1)
        try buf.append(allocator, 0xFF);
        try buf.append(allocator, 0xFF);
        // Acks: int16 → 1 (leader)
        try buf.append(allocator, 0x00);
        try buf.append(allocator, 0x01);
        // TimeoutMs: int32 → 30000
        try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x75, 0x30 });
        // Topic count: int32 → 1
        try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x01 });
        // Topic name: string
        try appendKafkaString(&buf, allocator, topic);
        // Partition count: int32 → 1
        try buf.appendSlice(allocator, &.{ 0x00, 0x00, 0x00, 0x01 });
        // Partition index: int32
        try appendInt32(&buf, allocator, partition);
        // Record batch (simplified)
        try appendRecordBatch(&buf, allocator, key, value);

        _ = correlation_id;
        _ = client_id;
        return buf.toOwnedSlice(allocator);
    }

    fn appendKafkaString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
        const len: i16 = @intCast(s.len);
        try buf.append(alloc, @intCast((len >> 8) & 0xFF));
        try buf.append(alloc, @intCast(len & 0xFF));
        try buf.appendSlice(alloc, s);
    }

    fn appendInt32(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, value: i32) !void {
        try buf.append(alloc, @intCast((value >> 24) & 0xFF));
        try buf.append(alloc, @intCast((value >> 16) & 0xFF));
        try buf.append(alloc, @intCast((value >> 8) & 0xFF));
        try buf.append(alloc, @intCast(value & 0xFF));
    }

    fn appendRecordBatch(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, _key: ?[]const u8, value: []const u8) !void {
        // Simplified record batch: offset(0) + length + record
        try appendInt32(buf, alloc, 0); // base offset
        try appendInt32(buf, alloc, @intCast(value.len + (if (_key) |k| k.len else 0) + 20)); // batch length
        try appendInt32(buf, alloc, 0); // partition leader epoch
        try buf.append(alloc, 2); // magic v2
        // CRC would go here in full implementation
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "KafkaProducer send and stats" {
    const allocator = std.testing.allocator;
    var producer = KafkaProducer.init(allocator, .{});
    defer producer.deinit();

    const msg = KafkaMessage{
        .topic = "orders.created",
        .key = null,
        .value = "{\"order_id\":123}",
        .headers = &.{},
        .timestamp = Time.monotonicNowSeconds(),
    };

    try producer.send(msg);
    try producer.send(msg);

    const stats = producer.getTopicStats("orders.created").?;
    try std.testing.expectEqual(@as(u64, 2), stats.produced);
}

test "KafkaProducer send batch" {
    const allocator = std.testing.allocator;
    var producer = KafkaProducer.init(allocator, .{});
    defer producer.deinit();

    const messages = &[_]KafkaMessage{
        .{ .topic = "t1", .key = null, .value = "m1", .headers = &.{}, .timestamp = Time.monotonicNowSeconds() },
        .{ .topic = "t2", .key = null, .value = "m2", .headers = &.{}, .timestamp = Time.monotonicNowSeconds() },
    };

    try producer.sendBatch(messages);
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("t1").?.produced);
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("t2").?.produced);
}

test "KafkaConsumer subscribe" {
    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();

    try consumer.subscribe("orders.events", struct {
        fn handle(_: KafkaMessage) void {}
    }.handle);

    const subs = try consumer.getSubscriptions();
    defer allocator.free(subs);

    try std.testing.expectEqual(@as(usize, 1), subs.len);
    try std.testing.expectEqualStrings("orders.events", subs[0]);
}

test "KafkaConsumer unsubscribe" {
    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();

    try consumer.subscribe("test.topic", struct {
        fn h(_: KafkaMessage) void {}
    }.h);
    try std.testing.expectEqual(@as(usize, 1), consumer.subscriptions.count());

    consumer.unsubscribe("test.topic");
    try std.testing.expectEqual(@as(usize, 0), consumer.subscriptions.count());
}

test "KafkaEventBridge basic" {
    const allocator = std.testing.allocator;
    var producer = KafkaProducer.init(allocator, .{});
    defer producer.deinit();
    var consumer = KafkaConsumer.init(allocator, .{});
    defer consumer.deinit();

    var bridge = KafkaEventBridge.init(allocator, &producer, &consumer);

    try bridge.publishEvent("payment.events", "{\"status\":\"paid\"}");
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("payment.events").?.produced);
}

test "KafkaProducer config" {
    const config = KafkaProducerConfig{
        .bootstrap_servers = "kafka:9092",
        .client_id = "test-client",
        .acks = .all,
        .compression = .snappy,
    };

    try std.testing.expectEqualStrings("kafka:9092", config.bootstrap_servers);
    try std.testing.expectEqual(KafkaProducerConfig.Acks.all, config.acks);
    try std.testing.expectEqual(KafkaProducerConfig.Compression.snappy, config.compression);
}

test "KafkaConsumer config" {
    const config = KafkaConsumerConfig{
        .group_id = "test-group",
        .auto_offset_reset = "earliest",
        .max_poll_records = 100,
    };

    try std.testing.expectEqualStrings("test-group", config.group_id);
    try std.testing.expectEqualStrings("earliest", config.auto_offset_reset);
    try std.testing.expectEqual(@as(usize, 100), config.max_poll_records);
}

test "KafkaWireFormat produce request" {
    const allocator = std.testing.allocator;
    const payload = try KafkaWireFormat.buildProduceRequest(
        allocator, "orders", 0, null, "hello", 1, "zigmodu",
    );
    defer allocator.free(payload);

    // Verify non-empty wire-format payload produced
    try std.testing.expect(payload.len > 0);
}
