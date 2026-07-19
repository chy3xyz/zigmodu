//! RobustMQ / Kafka producer wrapper for tenant-shop.
//!
//! Env:
//!   ROBUSTMQ_URL or KAFKA_BOOTSTRAP — host:port → online produce
//!   otherwise → offline producer (stats + log only, no network)

const std = @import("std");
const zigmodu = @import("zigmodu");

pub const Publisher = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    producer: zigmodu.KafkaProducer,
    online: bool,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, bootstrap: ?[]const u8) Self {
        if (bootstrap) |bs| {
            std.log.info("[mq] RobustMQ online bootstrap={s}", .{bs});
            return .{
                .allocator = allocator,
                .producer = zigmodu.KafkaProducer.initWithIo(allocator, io, .{
                    .bootstrap_servers = bs,
                    .client_id = "tenant-shop",
                }),
                .online = true,
            };
        }
        std.log.info("[mq] offline mode (set ROBUSTMQ_URL or KAFKA_BOOTSTRAP to enable)", .{});
        return .{
            .allocator = allocator,
            .producer = zigmodu.KafkaProducer.init(allocator, .{
                .client_id = "tenant-shop",
            }),
            .online = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.producer.deinit();
    }

    /// Publish one outbox payload. Key is typically tenant_id string.
    pub fn publish(self: *Self, topic: []const u8, key: ?[]const u8, payload: []const u8) !void {
        const ts: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
        std.log.info("[mq] publish topic={s} key={s} bytes={d} online={}", .{
            topic,
            key orelse "-",
            payload.len,
            self.online,
        });
        try self.producer.send(.{
            .topic = topic,
            .key = key,
            .value = payload,
            .headers = &.{},
            .timestamp = ts,
        });
    }

    pub fn producedCount(self: *Self, topic: []const u8) u64 {
        if (self.producer.getTopicStats(topic)) |s| return s.produced;
        return 0;
    }
};
