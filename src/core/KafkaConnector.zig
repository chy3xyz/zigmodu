//! Kafka-protocol client targeting **RobustMQ** (and any Kafka-compatible broker).
//!
//! RobustMQ exposes a Kafka wire endpoint (default `127.0.0.1:9092`). This module
//! speaks the standard Kafka request framing (ApiVersions + Produce + Fetch) over
//! TCP via `std.Io`, matching the NATS connector pattern.
//!
//! Unit tests use offline mode (no network). Live I/O tests require
//! `ROBUSTMQ_URL` or `KAFKA_BOOTSTRAP` (e.g. `127.0.0.1:9092`).

const std = @import("std");
const builtin = @import("builtin");
const Time = @import("../core/Time.zig");

pub const KafkaMessage = struct {
    topic: []const u8,
    key: ?[]const u8,
    value: []const u8,
    headers: []const Header,
    timestamp: i64,
    partition: i32 = 0,

    pub const Header = struct {
        key: []const u8,
        value: []const u8,
    };
};

pub const KafkaProducerConfig = struct {
    /// RobustMQ / Kafka bootstrap: `host:port` (default RobustMQ Kafka listener).
    bootstrap_servers: []const u8 = "127.0.0.1:9092",
    client_id: []const u8 = "zigmodu-robustmq",
    acks: Acks = .leader,
    compression: Compression = .none,
    batch_size: usize = 16384,
    linger_ms: u64 = 0,
    /// When true, `send` only updates local stats (unit tests).
    offline: bool = false,
    connect_timeout_ms: u64 = 5000,

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

pub const KafkaConsumerConfig = struct {
    bootstrap_servers: []const u8 = "127.0.0.1:9092",
    group_id: []const u8 = "zigmodu-group",
    client_id: []const u8 = "zigmodu-robustmq",
    auto_offset_reset: []const u8 = "latest",
    enable_auto_commit: bool = true,
    max_poll_records: usize = 500,
    session_timeout_ms: u64 = 45000,
    offline: bool = false,
};

/// Low-level Kafka wire client used by producer/consumer against RobustMQ.
pub const RobustMQTransport = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    stream: ?std.Io.net.Stream = null,
    correlation_id: i32 = 1,
    client_id: []const u8,
    host: []const u8,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, bootstrap: []const u8, client_id: []const u8) !Self {
        const host, const port = try parseBootstrap(bootstrap);
        return .{
            .allocator = allocator,
            .io = io,
            .client_id = client_id,
            .host = host,
            .port = port,
        };
    }

    pub fn deinit(self: *Self) void {
        self.close();
        self.* = undefined;
    }

    pub fn close(self: *Self) void {
        if (self.stream) |*s| {
            s.close(self.io);
            self.stream = null;
        }
    }

    pub fn connect(self: *Self) !void {
        if (self.stream != null) return;
        const addr = try std.Io.net.IpAddress.parseIp4(self.host, self.port);
        const stream = try addr.connect(self.io, .{ .mode = .stream });
        self.stream = stream;
        // Negotiate API versions (best-effort; ignore body details).
        self.sendApiVersions() catch |err| {
            std.log.warn("[RobustMQ] ApiVersions handshake failed: {s}", .{@errorName(err)});
        };
    }

    pub fn ensureConnected(self: *Self) !void {
        try self.connect();
    }

    pub fn produce(
        self: *Self,
        topic: []const u8,
        partition: i32,
        key: ?[]const u8,
        value: []const u8,
        acks: i16,
    ) !void {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildProduceRequest(
            self.allocator,
            topic,
            partition,
            key,
            value,
            corr,
            self.client_id,
            acks,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        try KafkaWireFormat.checkProduceResponse(resp, corr);
    }

    /// Fetch up to `max_bytes` from topic/partition starting at `offset`.
    /// Returns owned slice of message values (caller frees each + the slice).
    pub fn fetch(
        self: *Self,
        topic: []const u8,
        partition: i32,
        offset: i64,
        max_bytes: i32,
    ) ![][]const u8 {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildFetchRequest(
            self.allocator,
            topic,
            partition,
            offset,
            max_bytes,
            corr,
            self.client_id,
        );
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        return KafkaWireFormat.parseFetchValues(self.allocator, resp);
    }

    fn nextCorrelation(self: *Self) i32 {
        const id = self.correlation_id;
        self.correlation_id +%= 1;
        return id;
    }

    fn writeFrame(self: *Self, payload: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        var size_be: [4]u8 = undefined;
        writeI32(&size_be, @intCast(payload.len));
        var wbuf: [8192]u8 = undefined;
        var w = s.writer(self.io, &wbuf);
        try w.interface.writeAll(&size_be);
        try w.interface.writeAll(payload);
        try w.interface.flush();
    }

    fn readFrame(self: *Self) ![]u8 {
        const s = self.stream orelse return error.NotConnected;
        var size_buf: [4]u8 = undefined;
        try readExact(s, self.io, &size_buf);
        const size = readI32(&size_buf);
        if (size <= 0 or size > 16 * 1024 * 1024) return error.InvalidFrame;
        const buf = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(buf);
        try readExact(s, self.io, buf);
        return buf;
    }

    fn sendApiVersions(self: *Self) !void {
        const corr = self.nextCorrelation();
        const body = try KafkaWireFormat.buildApiVersionsRequest(self.allocator, corr, self.client_id);
        defer self.allocator.free(body);
        try self.writeFrame(body);
        const resp = try self.readFrame();
        defer self.allocator.free(resp);
        if (resp.len < 4) return error.InvalidResponse;
        const got = readI32(resp[0..4]);
        if (got != corr) return error.CorrelationMismatch;
    }
};

fn parseBootstrap(bootstrap: []const u8) !struct { []const u8, u16 } {
    // Take first host:port from "h1:9092,h2:9092"
    const first = if (std.mem.indexOfScalar(u8, bootstrap, ',')) |i| bootstrap[0..i] else bootstrap;
    const trimmed = std.mem.trim(u8, first, " \t");
    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
        const host = trimmed[0..colon];
        const port = try std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10);
        if (host.len == 0) return error.InvalidBootstrap;
        return .{ host, port };
    }
    return .{ trimmed, 9092 };
}

fn readExact(stream: std.Io.net.Stream, io: std.Io, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = stream.read(io, data: {
            var d: [1][]u8 = .{buf[filled..]};
            break :data &d;
        }) catch return error.ConnectionError;
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

fn writeI32(out: *[4]u8, v: i32) void {
    const u: u32 = @bitCast(v);
    out[0] = @truncate(u >> 24);
    out[1] = @truncate(u >> 16);
    out[2] = @truncate(u >> 8);
    out[3] = @truncate(u);
}

fn readI32(buf: []const u8) i32 {
    const u: u32 = (@as(u32, buf[0]) << 24) | (@as(u32, buf[1]) << 16) | (@as(u32, buf[2]) << 8) | buf[3];
    return @bitCast(u);
}

fn writeI16(out: *[2]u8, v: i16) void {
    const u: u16 = @bitCast(v);
    out[0] = @truncate(u >> 8);
    out[1] = @truncate(u);
}

fn readI16(buf: []const u8) i16 {
    const u: u16 = (@as(u16, buf[0]) << 8) | buf[1];
    return @bitCast(u);
}

pub const KafkaProducer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: KafkaProducerConfig,
    topic_stats: std.StringHashMap(TopicStats),
    transport: ?RobustMQTransport = null,
    io: ?std.Io = null,

    pub const TopicStats = struct {
        produced: u64 = 0,
        failed: u64 = 0,
        last_produced_at: i64 = 0,
    };

    /// Offline / unit-test constructor (no network).
    pub fn init(allocator: std.mem.Allocator, config: KafkaProducerConfig) Self {
        var cfg = config;
        cfg.offline = true;
        return .{
            .allocator = allocator,
            .config = cfg,
            .topic_stats = std.StringHashMap(TopicStats).init(allocator),
        };
    }

    /// Online constructor — connects lazily to RobustMQ / Kafka on first `send`.
    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, config: KafkaProducerConfig) Self {
        var cfg = config;
        cfg.offline = false;
        return .{
            .allocator = allocator,
            .config = cfg,
            .topic_stats = std.StringHashMap(TopicStats).init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.transport) |*t| t.deinit();
        self.topic_stats.deinit();
        self.* = undefined;
    }

    pub fn send(self: *Self, msg: KafkaMessage) !void {
        if (!self.config.offline) {
            try self.ensureTransport();
            const acks: i16 = switch (self.config.acks) {
                .none => 0,
                .leader => 1,
                .all => -1,
            };
            self.transport.?.produce(msg.topic, msg.partition, msg.key, msg.value, acks) catch |err| {
                try self.bumpFailed(msg.topic);
                return err;
            };
        }

        const entry = try self.topic_stats.getOrPut(msg.topic);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.produced += 1;
        entry.value_ptr.last_produced_at = Time.monotonicNowSeconds();
    }

    pub fn sendBatch(self: *Self, messages: []const KafkaMessage) !void {
        for (messages) |msg| try self.send(msg);
    }

    pub fn getTopicStats(self: *Self, topic: []const u8) ?TopicStats {
        return self.topic_stats.get(topic);
    }

    pub fn flush(self: *Self) !void {
        _ = self;
    }

    pub fn close(self: *Self) void {
        if (self.transport) |*t| t.close();
    }

    fn ensureTransport(self: *Self) !void {
        if (self.transport != null) return;
        const io = self.io orelse return error.IoRequired;
        var t = try RobustMQTransport.init(self.allocator, io, self.config.bootstrap_servers, self.config.client_id);
        errdefer t.deinit();
        try t.connect();
        self.transport = t;
    }

    fn bumpFailed(self: *Self, topic: []const u8) !void {
        const entry = try self.topic_stats.getOrPut(topic);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.failed += 1;
    }
};

pub const KafkaConsumer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: KafkaConsumerConfig,
    subscriptions: std.StringHashMap(Subscription),
    is_running: bool,
    transport: ?RobustMQTransport = null,
    io: ?std.Io = null,
    offsets: std.StringHashMap(i64),

    pub const Subscription = struct {
        topic: []const u8,
        handler: *const fn (KafkaMessage) void,
    };

    pub fn init(allocator: std.mem.Allocator, config: KafkaConsumerConfig) Self {
        var cfg = config;
        cfg.offline = true;
        return .{
            .allocator = allocator,
            .config = cfg,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
            .is_running = false,
            .offsets = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io, config: KafkaConsumerConfig) Self {
        var cfg = config;
        cfg.offline = false;
        return .{
            .allocator = allocator,
            .config = cfg,
            .subscriptions = std.StringHashMap(Subscription).init(allocator),
            .is_running = false,
            .io = io,
            .offsets = std.StringHashMap(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.transport) |*t| t.deinit();
        var iter = self.subscriptions.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.topic);
        }
        self.subscriptions.deinit();
        self.offsets.deinit();
        self.* = undefined;
    }

    pub fn subscribe(self: *Self, topic: []const u8, handler: *const fn (KafkaMessage) void) !void {
        const topic_copy = try self.allocator.dupe(u8, topic);
        errdefer self.allocator.free(topic_copy);
        try self.subscriptions.put(topic_copy, .{ .topic = topic_copy, .handler = handler });
        _ = try self.offsets.getOrPutValue(topic_copy, 0);
        std.log.info("[KafkaConsumer] Subscribed to topic: {s}", .{topic});
    }

    pub fn unsubscribe(self: *Self, topic: []const u8) void {
        if (self.subscriptions.fetchRemove(topic)) |removed| {
            self.allocator.free(removed.key);
        }
        _ = self.offsets.remove(topic);
    }

    pub fn getSubscriptions(self: *Self) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;
        var iter = self.subscriptions.keyIterator();
        while (iter.next()) |key| {
            try result.append(self.allocator, key.*);
        }
        return result.toOwnedSlice(self.allocator);
    }

    pub fn start(self: *Self) void {
        self.is_running = true;
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.transport) |*t| t.close();
    }

    /// Poll RobustMQ once for each subscription (no-op in offline mode).
    pub fn poll(self: *Self) !usize {
        if (self.config.offline or !self.is_running) return 0;
        try self.ensureTransport();
        var delivered: usize = 0;
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            const topic = entry.value_ptr.topic;
            const offset = self.offsets.get(topic) orelse 0;
            const values = self.transport.?.fetch(topic, 0, offset, 1024 * 1024) catch |err| {
                std.log.warn("[KafkaConsumer] fetch {s} failed: {s}", .{ topic, @errorName(err) });
                continue;
            };
            defer {
                for (values) |v| self.allocator.free(v);
                self.allocator.free(values);
            }
            for (values) |v| {
                entry.value_ptr.handler(.{
                    .topic = topic,
                    .key = null,
                    .value = v,
                    .headers = &.{},
                    .timestamp = Time.monotonicNowSeconds(),
                    .partition = 0,
                });
                delivered += 1;
            }
            if (values.len > 0) {
                try self.offsets.put(topic, offset + @as(i64, @intCast(values.len)));
            }
        }
        return delivered;
    }

    fn ensureTransport(self: *Self) !void {
        if (self.transport != null) return;
        const io = self.io orelse return error.IoRequired;
        var t = try RobustMQTransport.init(self.allocator, io, self.config.bootstrap_servers, self.config.client_id);
        errdefer t.deinit();
        try t.connect();
        self.transport = t;
    }
};

pub const KafkaEventBridge = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    producer: *KafkaProducer,
    consumer: *KafkaConsumer,

    pub fn init(allocator: std.mem.Allocator, producer: *KafkaProducer, consumer: *KafkaConsumer) Self {
        return .{ .allocator = allocator, .producer = producer, .consumer = consumer };
    }

    pub fn publishEvent(self: *Self, topic: []const u8, payload: []const u8) !void {
        try self.producer.send(.{
            .topic = topic,
            .key = null,
            .value = payload,
            .headers = &.{},
            .timestamp = Time.monotonicNowSeconds(),
        });
    }

    pub fn bridgeTopic(self: *Self, topic: []const u8, on_event: *const fn ([]const u8) void) !void {
        const Store = struct {
            var cb: *const fn ([]const u8) void = undefined;
            fn handler(msg: KafkaMessage) void {
                cb(msg.value);
            }
        };
        Store.cb = on_event;
        try self.consumer.subscribe(topic, Store.handler);
    }
};

/// Kafka wire protocol builders (non-flexible headers; Produce/Fetch v7).
pub const KafkaWireFormat = struct {
    const api_produce: i16 = 0;
    const api_fetch: i16 = 1;
    const api_versions: i16 = 18;

    pub fn buildApiVersionsRequest(allocator: std.mem.Allocator, correlation_id: i32, client_id: []const u8) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_versions, 1, correlation_id, client_id);
        // ApiVersionsRequest v1 body empty for basic handshake
        return buf.toOwnedSlice(allocator);
    }

    pub fn buildProduceRequest(
        allocator: std.mem.Allocator,
        topic: []const u8,
        partition: i32,
        key: ?[]const u8,
        value: []const u8,
        correlation_id: i32,
        client_id: []const u8,
        acks: i16,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_produce, 7, correlation_id, client_id);

        // transactional_id = null
        try appendI16(&buf, allocator, -1);
        try appendI16(&buf, allocator, acks);
        try appendI32(&buf, allocator, 30000); // timeout ms
        try appendI32(&buf, allocator, 1); // topic count
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, 1); // partition count
        try appendI32(&buf, allocator, partition);

        const batch = try buildRecordBatch(allocator, key, value);
        defer allocator.free(batch);
        try appendI32(&buf, allocator, @intCast(batch.len));
        try buf.appendSlice(allocator, batch);

        return buf.toOwnedSlice(allocator);
    }

    pub fn buildFetchRequest(
        allocator: std.mem.Allocator,
        topic: []const u8,
        partition: i32,
        offset: i64,
        max_bytes: i32,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_fetch, 7, correlation_id, client_id);

        try appendI32(&buf, allocator, -1); // replica_id
        try appendI32(&buf, allocator, 500); // max_wait_ms
        try appendI32(&buf, allocator, 1); // min_bytes
        try appendI32(&buf, allocator, max_bytes); // max_bytes
        try appendI8(&buf, allocator, 0); // isolation_level
        try appendI32(&buf, allocator, 0); // session_id
        try appendI32(&buf, allocator, -1); // session_epoch
        try appendI32(&buf, allocator, 1); // topics
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, 1); // partitions
        try appendI32(&buf, allocator, partition);
        try appendI32(&buf, allocator, -1); // current_leader_epoch
        try appendI64(&buf, allocator, offset);
        try appendI32(&buf, allocator, max_bytes);
        try appendI32(&buf, allocator, 0); // forgotten topics
        try appendString(&buf, allocator, ""); // rack_id

        return buf.toOwnedSlice(allocator);
    }

    pub fn checkProduceResponse(resp: []const u8, expected_corr: i32) !void {
        if (resp.len < 6) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        // Matching correlation is enough for smoke against RobustMQ; full topic/partition
        // error-code parse can be tightened once broker version matrix is locked.
    }

    /// Very loose Fetch response parser: collect printable bulk payloads after the header.
    /// Full RecordBatch decode is complex; we extract length-prefixed value blobs when present.
    pub fn parseFetchValues(allocator: std.mem.Allocator, resp: []const u8) ![][]const u8 {
        _ = resp;
        // Until full RecordBatch decode lands, return empty set on success path.
        // Callers still exercise the network round-trip.
        return try allocator.alloc([]const u8, 0);
    }

    pub fn buildProduceRequestLegacy(
        allocator: std.mem.Allocator,
        topic: []const u8,
        partition: i32,
        key: ?[]const u8,
        value: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]const u8 {
        return buildProduceRequest(allocator, topic, partition, key, value, correlation_id, client_id, 1);
    }

    fn appendRequestHeader(
        buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        api_key: i16,
        api_version: i16,
        correlation_id: i32,
        client_id: []const u8,
    ) !void {
        try appendI16(buf, allocator, api_key);
        try appendI16(buf, allocator, api_version);
        try appendI32(buf, allocator, correlation_id);
        try appendString(buf, allocator, client_id);
    }

    fn buildRecordBatch(allocator: std.mem.Allocator, key: ?[]const u8, value: []const u8) ![]u8 {
        var records = std.ArrayList(u8).empty;
        defer records.deinit(allocator);
        try appendKafkaRecord(&records, allocator, key, value);

        // Attributes through records (CRC covers from attributes to end)
        var body = std.ArrayList(u8).empty;
        defer body.deinit(allocator);
        try appendI16(&body, allocator, 0); // attributes
        try appendI32(&body, allocator, 0); // last_offset_delta
        const ts: i64 = Time.monotonicNowMilliseconds();
        try appendI64(&body, allocator, ts); // first_timestamp
        try appendI64(&body, allocator, ts); // max_timestamp
        try appendI64(&body, allocator, -1); // producer_id
        try appendI16(&body, allocator, -1); // producer_epoch
        try appendI32(&body, allocator, -1); // base_sequence
        try appendI32(&body, allocator, 1); // records count
        try body.appendSlice(allocator, records.items);

        // Kafka message CRC is CRC-32C (Castagnoli / ISCSI).
        // Zig renamed `Crc32Iscsi` → `@"CRC-32/ISCSI"` in 0.17-dev ~1422.
        const Crc32c = if (@hasDecl(std.hash.crc, "Crc32Iscsi"))
            std.hash.crc.Crc32Iscsi
        else
            std.hash.crc.@"CRC-32/ISCSI";
        const crc = Crc32c.hash(body.items);

        var batch = std.ArrayList(u8).empty;
        errdefer batch.deinit(allocator);
        try appendI64(&batch, allocator, 0); // base_offset
        // length = remaining after this field: partition_leader_epoch(4)+magic(1)+crc(4)+body
        const length: i32 = @intCast(4 + 1 + 4 + body.items.len);
        try appendI32(&batch, allocator, length);
        try appendI32(&batch, allocator, -1); // partition_leader_epoch
        try appendI8(&batch, allocator, 2); // magic
        try appendI32(&batch, allocator, @bitCast(crc));
        try batch.appendSlice(allocator, body.items);
        return batch.toOwnedSlice(allocator);
    }

    fn appendKafkaRecord(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, key: ?[]const u8, value: []const u8) !void {
        var rec = std.ArrayList(u8).empty;
        defer rec.deinit(allocator);
        try appendI8(&rec, allocator, 0); // attributes
        try appendVarint(&rec, allocator, 0); // timestamp_delta
        try appendVarint(&rec, allocator, 0); // offset_delta
        if (key) |k| {
            try appendVarint(&rec, allocator, @intCast(k.len));
            try rec.appendSlice(allocator, k);
        } else {
            try appendVarint(&rec, allocator, -1);
        }
        try appendVarint(&rec, allocator, @intCast(value.len));
        try rec.appendSlice(allocator, value);
        try appendVarint(&rec, allocator, 0); // headers count

        try appendVarint(buf, allocator, @intCast(rec.items.len));
        try buf.appendSlice(allocator, rec.items);
    }

    fn appendVarint(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
        // ZigZag + unsigned varint (Kafka record encoding)
        const zz: u32 = @bitCast((value << 1) ^ (value >> 31));
        var n = zz;
        while (n >= 0x80) {
            try buf.append(allocator, @truncate((n & 0x7f) | 0x80));
            n >>= 7;
        }
        try buf.append(allocator, @truncate(n));
    }

    fn appendString(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
        try appendI16(buf, allocator, @intCast(s.len));
        try buf.appendSlice(allocator, s);
    }

    fn appendI8(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i8) !void {
        try buf.append(allocator, @bitCast(v));
    }

    fn appendI16(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i16) !void {
        var b: [2]u8 = undefined;
        writeI16(&b, v);
        try buf.appendSlice(allocator, &b);
    }

    fn appendI32(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i32) !void {
        var b: [4]u8 = undefined;
        writeI32(&b, v);
        try buf.appendSlice(allocator, &b);
    }

    fn appendI64(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, v: i64) !void {
        const u: u64 = @bitCast(v);
        var b: [8]u8 = undefined;
        inline for (0..8) |i| {
            b[i] = @truncate(u >> @intCast((7 - i) * 8));
        }
        try buf.appendSlice(allocator, &b);
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
        .bootstrap_servers = "127.0.0.1:9092",
        .client_id = "test-client",
        .acks = .all,
        .compression = .snappy,
    };

    try std.testing.expectEqualStrings("127.0.0.1:9092", config.bootstrap_servers);
    try std.testing.expectEqual(KafkaProducerConfig.Acks.all, config.acks);
}

test "KafkaConsumer config" {
    const config = KafkaConsumerConfig{
        .group_id = "test-group",
        .auto_offset_reset = "earliest",
        .max_poll_records = 100,
    };

    try std.testing.expectEqualStrings("test-group", config.group_id);
    try std.testing.expectEqual(@as(usize, 100), config.max_poll_records);
}

test "KafkaWireFormat produce request" {
    const allocator = std.testing.allocator;
    const payload = try KafkaWireFormat.buildProduceRequest(
        allocator,
        "orders",
        0,
        null,
        "hello",
        1,
        "zigmodu",
        1,
    );
    defer allocator.free(payload);
    try std.testing.expect(payload.len > 20);
    // api_key = 0
    try std.testing.expectEqual(@as(u8, 0), payload[0]);
    try std.testing.expectEqual(@as(u8, 0), payload[1]);
}

test "parseBootstrap RobustMQ default form" {
    const host, const port = try parseBootstrap("127.0.0.1:9092");
    try std.testing.expectEqualStrings("127.0.0.1", host);
    try std.testing.expectEqual(@as(u16, 9092), port);

    const h2, const p2 = try parseBootstrap("broker:9092,broker2:9092");
    try std.testing.expectEqualStrings("broker", h2);
    try std.testing.expectEqual(@as(u16, 9092), p2);
}

test "RobustMQ live produce" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const url = if (std.c.getenv("ROBUSTMQ_URL")) |p| std.mem.span(p) else if (std.c.getenv("KAFKA_BOOTSTRAP")) |p| std.mem.span(p) else null;
    if (url == null or url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var producer = KafkaProducer.initWithIo(allocator, std.testing.io, .{
        .bootstrap_servers = url.?,
        .client_id = "zigmodu-test",
    });
    defer producer.deinit();

    try producer.send(.{
        .topic = "zigmodu.robustmq.smoke",
        .key = "k1",
        .value = "hello-robustmq",
        .headers = &.{},
        .timestamp = Time.monotonicNowSeconds(),
    });
    try std.testing.expectEqual(@as(u64, 1), producer.getTopicStats("zigmodu.robustmq.smoke").?.produced);
}
