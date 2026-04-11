const std = @import("std");

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
        redis: RedisBackend,
        kafka: KafkaBackend,
    };

    /// 生产者
    pub const Producer = struct {
        backend: *QueueBackend,

        pub fn publish(self: *Producer, msg: Message) !void {
            switch (self.backend.*) {
                .in_memory => |backend| try backend.publish(msg),
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
                .topics = std.ArrayList([]const u8).init(allocator),
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
                const new_queue = std.ArrayList(Message).init(self.allocator);
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
