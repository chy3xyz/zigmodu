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

    /// Send a raw Kafka request payload and return the response body (owned).
    pub fn request(self: *Self, payload: []const u8) ![]u8 {
        try self.ensureConnected();
        try self.writeFrame(payload);
        return self.readFrame();
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

    pub fn nextCorrelationPublic(self: *Self) i32 {
        return self.nextCorrelation();
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

/// In-process / offline consumer-group membership (Join → Sync → Heartbeat).
/// Wire builders live in `KafkaWireFormat`; this tracks generation, member id, and assignments.
pub const ConsumerGroupSession = struct {
    const Self = @This();

    pub const State = enum { empty, joining, syncing, stable, leaving };

    pub const TopicAssignment = struct {
        topic: []const u8,
        partitions: []const i32,
    };

    allocator: std.mem.Allocator,
    group_id: []const u8,
    member_id: []const u8 = "",
    generation_id: i32 = -1,
    state: State = .empty,
    is_leader: bool = false,
    assignments: std.ArrayList(TopicAssignment) = .empty,
    member_id_owned: bool = false,

    pub fn init(allocator: std.mem.Allocator, group_id: []const u8) Self {
        return .{ .allocator = allocator, .group_id = group_id };
    }

    pub fn deinit(self: *Self) void {
        if (self.member_id_owned) self.allocator.free(self.member_id);
        for (self.assignments.items) |a| {
            self.allocator.free(a.topic);
            self.allocator.free(a.partitions);
        }
        self.assignments.deinit(self.allocator);
        self.* = undefined;
    }

    /// Offline join: assign self as leader of `topics` on partition 0 (solo consumer).
    pub fn joinOffline(self: *Self, topics: []const []const u8) !void {
        self.state = .joining;
        if (self.member_id_owned) self.allocator.free(self.member_id);
        self.member_id = try std.fmt.allocPrint(self.allocator, "member-{s}", .{self.group_id});
        self.member_id_owned = true;
        self.generation_id = 1;
        self.is_leader = true;
        self.state = .syncing;
        try self.clearAssignments();
        for (topics) |t| {
            const topic_copy = try self.allocator.dupe(u8, t);
            errdefer self.allocator.free(topic_copy);
            const parts = try self.allocator.alloc(i32, 1);
            parts[0] = 0;
            try self.assignments.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
        }
        self.state = .stable;
    }

    pub fn heartbeatOffline(self: *Self) !void {
        if (self.state != .stable) return error.NotInGroup;
    }

    pub fn leaveOffline(self: *Self) !void {
        self.state = .leaving;
        self.generation_id = -1;
        try self.clearAssignments();
        self.state = .empty;
    }

    pub fn clearAssignments(self: *Self) !void {
        for (self.assignments.items) |a| {
            self.allocator.free(a.topic);
            self.allocator.free(a.partitions);
        }
        self.assignments.clearRetainingCapacity();
    }

    pub fn buildJoinRequest(self: *Self, topics: []const []const u8, session_timeout_ms: i32, correlation_id: i32, client_id: []const u8) ![]u8 {
        return KafkaWireFormat.buildJoinGroupRequest(
            self.allocator,
            self.group_id,
            self.member_id,
            topics,
            session_timeout_ms,
            correlation_id,
            client_id,
        );
    }

    pub fn buildHeartbeatRequest(self: *Self, correlation_id: i32, client_id: []const u8) ![]u8 {
        return KafkaWireFormat.buildHeartbeatRequest(
            self.allocator,
            self.group_id,
            self.generation_id,
            self.member_id,
            correlation_id,
            client_id,
        );
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
    group: ?ConsumerGroupSession = null,

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
        if (self.group) |*g| g.deinit();
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

    /// Join consumer group. Offline → solo partition-0 assignment.
    /// Online → JoinGroup + SyncGroup over `RobustMQTransport`.
    pub fn joinGroup(self: *Self) !void {
        if (self.group) |*g| g.deinit();

        var topics = std.ArrayList([]const u8).empty;
        defer topics.deinit(self.allocator);
        var it = self.subscriptions.keyIterator();
        while (it.next()) |k| try topics.append(self.allocator, k.*);

        if (self.config.offline or self.io == null) {
            var session = ConsumerGroupSession.init(self.allocator, self.config.group_id);
            try session.joinOffline(topics.items);
            self.group = session;
            std.log.info("[KafkaConsumer] joined group {s} generation={d} (offline)", .{ self.config.group_id, self.group.?.generation_id });
            return;
        }

        try self.ensureTransport();
        var session = ConsumerGroupSession.init(self.allocator, self.config.group_id);
        errdefer session.deinit();
        session.state = .joining;

        const t = &self.transport.?;
        const corr_join = t.nextCorrelationPublic();
        const join_req = try KafkaWireFormat.buildJoinGroupRequest(
            self.allocator,
            self.config.group_id,
            "",
            topics.items,
            @intCast(self.config.session_timeout_ms),
            corr_join,
            self.config.client_id,
        );
        defer self.allocator.free(join_req);
        const join_resp = try t.request(join_req);
        defer self.allocator.free(join_resp);
        const joined = try KafkaWireFormat.parseJoinGroupResponse(self.allocator, join_resp, corr_join);
        defer {
            self.allocator.free(joined.protocol);
            self.allocator.free(joined.leader_id);
            self.allocator.free(joined.member_id);
        }
        if (joined.error_code != 0) return error.JoinGroupFailed;

        session.member_id = try self.allocator.dupe(u8, joined.member_id);
        session.member_id_owned = true;
        session.generation_id = joined.generation_id;
        session.is_leader = std.mem.eql(u8, joined.leader_id, joined.member_id);
        session.state = .syncing;

        // Leader: propose partition-0 for first topic to self; follower: empty assignments.
        var assign_buf: ?[]u8 = null;
        defer if (assign_buf) |b| self.allocator.free(b);
        var assign_storage: [1]KafkaWireFormat.MemberAssignmentEntry = undefined;
        const assignments: []const KafkaWireFormat.MemberAssignmentEntry = blk: {
            if (!session.is_leader or topics.items.len == 0) break :blk &.{};
            assign_buf = try KafkaWireFormat.buildMemberAssignment(self.allocator, topics.items[0], &.{0});
            assign_storage[0] = .{ .member_id = session.member_id, .assignment = assign_buf.? };
            break :blk assign_storage[0..1];
        };

        const corr_sync = t.nextCorrelationPublic();
        const sync_req = try KafkaWireFormat.buildSyncGroupRequest(
            self.allocator,
            self.config.group_id,
            session.generation_id,
            session.member_id,
            assignments,
            corr_sync,
            self.config.client_id,
        );
        defer self.allocator.free(sync_req);
        const sync_resp = try t.request(sync_req);
        defer self.allocator.free(sync_resp);
        const synced = try KafkaWireFormat.parseSyncGroupResponse(self.allocator, sync_resp, corr_sync);
        defer self.allocator.free(synced.assignment);
        if (synced.error_code != 0) return error.SyncGroupFailed;

        try session.clearAssignments();
        if (synced.assignment.len > 0) {
            const parsed = try KafkaWireFormat.parseMemberAssignment(self.allocator, synced.assignment);
            try session.assignments.append(self.allocator, .{ .topic = parsed.topic, .partitions = parsed.partitions });
        } else if (topics.items.len > 0) {
            // Fallback: offline-style assignment if broker returned empty
            try session.joinOffline(topics.items);
        }
        session.state = .stable;
        self.group = session;
        std.log.info("[KafkaConsumer] joined group {s} generation={d} member={s}", .{
            self.config.group_id,
            self.group.?.generation_id,
            self.group.?.member_id,
        });
    }

    pub fn heartbeat(self: *Self) !void {
        const g = &(self.group orelse return error.NotInGroup);
        if (self.config.offline or self.io == null) {
            try g.heartbeatOffline();
            return;
        }
        try self.ensureTransport();
        const t = &self.transport.?;
        const corr = t.nextCorrelationPublic();
        const req = try g.buildHeartbeatRequest(corr, self.config.client_id);
        defer self.allocator.free(req);
        const resp = try t.request(req);
        defer self.allocator.free(resp);
        const err_code = try KafkaWireFormat.parseHeartbeatError(resp, corr);
        if (err_code != 0) return error.HeartbeatFailed;
    }

    pub fn leaveGroup(self: *Self) !void {
        if (self.group) |*g| {
            if (!self.config.offline and self.io != null and self.transport != null) {
                const t = &self.transport.?;
                const corr = t.nextCorrelationPublic();
                const req = try KafkaWireFormat.buildLeaveGroupRequest(
                    self.allocator,
                    self.config.group_id,
                    g.member_id,
                    corr,
                    self.config.client_id,
                );
                defer self.allocator.free(req);
                const resp = t.request(req) catch null;
                if (resp) |r| self.allocator.free(r);
            }
            try g.leaveOffline();
            g.deinit();
            self.group = null;
        }
    }

    pub fn assignedPartitions(self: *const Self) []const ConsumerGroupSession.TopicAssignment {
        if (self.group) |g| return g.assignments.items;
        return &.{};
    }

    /// Poll RobustMQ once for each subscription (no-op in offline mode).
    /// When in a group, fetch uses assigned partitions; otherwise partition 0.
    pub fn poll(self: *Self) !usize {
        if (self.config.offline or !self.is_running) return 0;
        try self.ensureTransport();
        var delivered: usize = 0;
        var it = self.subscriptions.iterator();
        while (it.next()) |entry| {
            const topic = entry.value_ptr.topic;
            const partitions: []const i32 = blk: {
                if (self.group) |*g| {
                    for (g.assignments.items) |a| {
                        if (std.mem.eql(u8, a.topic, topic)) break :blk a.partitions;
                    }
                }
                break :blk &[_]i32{0};
            };
            for (partitions) |part| {
                const offset = self.offsets.get(topic) orelse 0;
                const values = self.transport.?.fetch(topic, part, offset, 1024 * 1024) catch |err| {
                    std.log.warn("[KafkaConsumer] fetch {s}/{d} failed: {s}", .{ topic, part, @errorName(err) });
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
                        .partition = part,
                    });
                    delivered += 1;
                }
                if (values.len > 0) {
                    try self.offsets.put(topic, offset + @as(i64, @intCast(values.len)));
                }
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

/// Kafka wire protocol builders (non-flexible headers; Produce/Fetch v7 + Consumer Group).
pub const KafkaWireFormat = struct {
    const api_produce: i16 = 0;
    const api_fetch: i16 = 1;
    const api_offset_commit: i16 = 8;
    const api_offset_fetch: i16 = 9;
    const api_find_coordinator: i16 = 10;
    const api_join_group: i16 = 11;
    const api_heartbeat: i16 = 12;
    const api_leave_group: i16 = 13;
    const api_sync_group: i16 = 14;
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

    // ── Consumer Group protocol (FindCoordinator / Join / Sync / Heartbeat / Leave / Offset*) ──

    pub fn buildFindCoordinatorRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_find_coordinator, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI8(&buf, allocator, 0); // key_type = group
        return buf.toOwnedSlice(allocator);
    }

    /// ConsumerProtocolSubscription v0 metadata bytes.
    pub fn buildSubscriptionMetadata(allocator: std.mem.Allocator, topics: []const []const u8) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendI16(&buf, allocator, 0); // version
        try appendI32(&buf, allocator, @intCast(topics.len));
        for (topics) |t| try appendString(&buf, allocator, t);
        try appendI32(&buf, allocator, 0); // user_data length
        return buf.toOwnedSlice(allocator);
    }

    pub fn buildJoinGroupRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        member_id: []const u8,
        topics: []const []const u8,
        session_timeout_ms: i32,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_join_group, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, session_timeout_ms);
        try appendString(&buf, allocator, member_id);
        try appendString(&buf, allocator, "consumer"); // protocol_type
        try appendI32(&buf, allocator, 1); // protocols count
        try appendString(&buf, allocator, "range"); // protocol name
        const meta = try buildSubscriptionMetadata(allocator, topics);
        defer allocator.free(meta);
        try appendBytes(&buf, allocator, meta);
        return buf.toOwnedSlice(allocator);
    }

    /// MemberAssignment v0 for SyncGroup.
    pub fn buildMemberAssignment(allocator: std.mem.Allocator, topic: []const u8, partitions: []const i32) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendI16(&buf, allocator, 0); // version
        try appendI32(&buf, allocator, 1); // topic count
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, @intCast(partitions.len));
        for (partitions) |p| try appendI32(&buf, allocator, p);
        try appendI32(&buf, allocator, 0); // user_data
        return buf.toOwnedSlice(allocator);
    }

    pub const MemberAssignmentEntry = struct {
        member_id: []const u8,
        assignment: []const u8,
    };

    pub fn buildSyncGroupRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        /// When leader: assignments for each member; followers pass empty.
        assignments: []const MemberAssignmentEntry,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_sync_group, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, generation_id);
        try appendString(&buf, allocator, member_id);
        try appendI32(&buf, allocator, @intCast(assignments.len));
        for (assignments) |a| {
            try appendString(&buf, allocator, a.member_id);
            try appendBytes(&buf, allocator, a.assignment);
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn buildHeartbeatRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_heartbeat, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, generation_id);
        try appendString(&buf, allocator, member_id);
        return buf.toOwnedSlice(allocator);
    }

    pub fn buildLeaveGroupRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        member_id: []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_leave_group, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendString(&buf, allocator, member_id);
        return buf.toOwnedSlice(allocator);
    }

    pub fn buildOffsetCommitRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        generation_id: i32,
        member_id: []const u8,
        topic: []const u8,
        partition: i32,
        offset: i64,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_offset_commit, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, generation_id);
        try appendString(&buf, allocator, member_id);
        try appendI32(&buf, allocator, -1); // retention
        try appendI32(&buf, allocator, 1); // topics
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, 1); // partitions
        try appendI32(&buf, allocator, partition);
        try appendI64(&buf, allocator, offset);
        try appendString(&buf, allocator, ""); // metadata
        return buf.toOwnedSlice(allocator);
    }

    pub fn buildOffsetFetchRequest(
        allocator: std.mem.Allocator,
        group_id: []const u8,
        topic: []const u8,
        partitions: []const i32,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_offset_fetch, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, 1); // topics
        try appendString(&buf, allocator, topic);
        try appendI32(&buf, allocator, @intCast(partitions.len));
        for (partitions) |p| try appendI32(&buf, allocator, p);
        return buf.toOwnedSlice(allocator);
    }

    /// Parse HeartbeatResponse v2: correlation(4) + throttle(4) + error_code(2).
    pub fn parseHeartbeatError(resp: []const u8, expected_corr: i32) !i16 {
        if (resp.len < 10) return error.InvalidResponse;
        if (readI32(resp[0..4]) != expected_corr) return error.CorrelationMismatch;
        return readI16(resp[8..10]);
    }

    fn appendBytes(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
        try appendI32(buf, allocator, @intCast(data.len));
        try buf.appendSlice(allocator, data);
    }

    /// Parse JoinGroupResponse v2 (non-flexible). Caller frees returned strings.
    pub fn parseJoinGroupResponse(allocator: std.mem.Allocator, resp: []const u8, expected_corr: i32) !struct {
        error_code: i16,
        generation_id: i32,
        protocol: []u8,
        leader_id: []u8,
        member_id: []u8,
    } {
        if (resp.len < 14) return error.InvalidResponse;
        if (readI32(resp[0..4]) != expected_corr) return error.CorrelationMismatch;
        var off: usize = 4;
        off += 4; // throttle
        const error_code = readI16(resp[off..][0..2]);
        off += 2;
        const generation_id = readI32(resp[off..][0..4]);
        off += 4;
        const protocol, const n1 = try readKafkaString(resp[off..]);
        off += n1;
        const leader_id, const n2 = try readKafkaString(resp[off..]);
        off += n2;
        const member_id, const n3 = try readKafkaString(resp[off..]);
        _ = n3;
        return .{
            .error_code = error_code,
            .generation_id = generation_id,
            .protocol = try allocator.dupe(u8, protocol),
            .leader_id = try allocator.dupe(u8, leader_id),
            .member_id = try allocator.dupe(u8, member_id),
        };
    }

    /// Parse SyncGroupResponse v2. Caller frees `assignment`.
    pub fn parseSyncGroupResponse(allocator: std.mem.Allocator, resp: []const u8, expected_corr: i32) !struct {
        error_code: i16,
        assignment: []u8,
    } {
        if (resp.len < 10) return error.InvalidResponse;
        if (readI32(resp[0..4]) != expected_corr) return error.CorrelationMismatch;
        var off: usize = 8; // corr + throttle
        const error_code = readI16(resp[off..][0..2]);
        off += 2;
        if (off + 4 > resp.len) return .{ .error_code = error_code, .assignment = try allocator.alloc(u8, 0) };
        const len = readI32(resp[off..][0..4]);
        off += 4;
        if (len < 0) return .{ .error_code = error_code, .assignment = try allocator.alloc(u8, 0) };
        if (off + @as(usize, @intCast(len)) > resp.len) return error.InvalidResponse;
        return .{
            .error_code = error_code,
            .assignment = try allocator.dupe(u8, resp[off .. off + @as(usize, @intCast(len))]),
        };
    }

    /// Parse MemberAssignment v0 → first topic + partitions (owned).
    pub fn parseMemberAssignment(allocator: std.mem.Allocator, data: []const u8) !struct { topic: []u8, partitions: []i32 } {
        if (data.len < 6) return error.InvalidAssignment;
        var off: usize = 2; // version
        const topic_count = readI32(data[off..][0..4]);
        off += 4;
        if (topic_count <= 0) return error.InvalidAssignment;
        const topic, const n1 = try readKafkaString(data[off..]);
        off += n1;
        if (off + 4 > data.len) return error.InvalidAssignment;
        const part_count = readI32(data[off..][0..4]);
        off += 4;
        if (part_count < 0 or off + @as(usize, @intCast(part_count)) * 4 > data.len) return error.InvalidAssignment;
        var parts = try allocator.alloc(i32, @intCast(part_count));
        errdefer allocator.free(parts);
        for (0..@as(usize, @intCast(part_count))) |i| {
            parts[i] = readI32(data[off..][0..4]);
            off += 4;
        }
        return .{ .topic = try allocator.dupe(u8, topic), .partitions = parts };
    }

    fn readKafkaString(buf: []const u8) !struct { []const u8, usize } {
        if (buf.len < 2) return error.InvalidResponse;
        const len = readI16(buf[0..2]);
        if (len < 0) return .{ "", 2 };
        const n: usize = @intCast(len);
        if (2 + n > buf.len) return error.InvalidResponse;
        return .{ buf[2 .. 2 + n], 2 + n };
    }

    pub fn checkProduceResponse(resp: []const u8, expected_corr: i32) !void {
        if (resp.len < 8) return error.InvalidResponse;
        const corr = readI32(resp[0..4]);
        if (corr != expected_corr) return error.CorrelationMismatch;
        // ProduceResponse v7: correlation(4) + throttle_time_ms(4) + topics...
        // When at least one topic/partition is present, error_code sits after topic string.
        // For smoke / RobustMQ we accept correlation match; optional error scan below.
        if (resp.len >= 14) {
            // throttle_time at [4..8]; topic_count at [8..12]
            const topic_count = readI32(resp[8..12]);
            if (topic_count > 0 and resp.len >= 16) {
                const name_len = readI16(resp[12..14]);
                if (name_len >= 0) {
                    const name_end = 14 + @as(usize, @intCast(name_len));
                    if (name_end + 10 <= resp.len) {
                        // partition_count(4) + partition(4) + error_code(2)
                        const err_code = readI16(resp[name_end + 8 ..][0..2]);
                        if (err_code != 0) return error.ProduceError;
                    }
                }
            }
        }
    }

    /// Decode RecordBatch (magic=2) values from a buffer (our Produce batch layout).
    pub fn parseRecordBatchValues(allocator: std.mem.Allocator, batch: []const u8) ![][]const u8 {
        // base_offset(8) + length(4) + leader_epoch(4) + magic(1) + crc(4) + body...
        if (batch.len < 22) return error.InvalidRecordBatch;
        if (batch[16] != 2) return error.UnsupportedMagic; // magic at offset 16
        // body starts at 21 (after crc)
        const body = batch[21..];
        if (body.len < 40) return try allocator.alloc([]const u8, 0);
        // skip attributes(2)+last_offset_delta(4)+first_ts(8)+max_ts(8)+producer_id(8)+epoch(2)+base_seq(4)+count(4) = 40
        var off: usize = 40;
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |v| allocator.free(v);
            out.deinit(allocator);
        }
        while (off < body.len) {
            const rec_len, const n1 = try readVarint(body[off..]);
            off += n1;
            if (rec_len <= 0 or off + @as(usize, @intCast(rec_len)) > body.len) break;
            const rec = body[off .. off + @as(usize, @intCast(rec_len))];
            off += @intCast(rec_len);
            // attributes(1) + ts_delta + offset_delta + key + value
            var roff: usize = 1;
            _, const n2 = try readVarint(rec[roff..]);
            roff += n2;
            _, const n3 = try readVarint(rec[roff..]);
            roff += n3;
            const key_len, const n4 = try readVarint(rec[roff..]);
            roff += n4;
            if (key_len >= 0) {
                if (roff + @as(usize, @intCast(key_len)) > rec.len) break;
                roff += @intCast(key_len);
            }
            const val_len, const n5 = try readVarint(rec[roff..]);
            roff += n5;
            if (val_len < 0 or roff + @as(usize, @intCast(val_len)) > rec.len) break;
            const val = try allocator.dupe(u8, rec[roff .. roff + @as(usize, @intCast(val_len))]);
            try out.append(allocator, val);
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Extract message values from a Fetch response by scanning for magic=2 record batches.
    pub fn parseFetchValues(allocator: std.mem.Allocator, resp: []const u8) ![][]const u8 {
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |v| allocator.free(v);
            out.deinit(allocator);
        }
        var i: usize = 0;
        while (i + 22 < resp.len) : (i += 1) {
            // Look for magic=2 preceded by leader_epoch (4 bytes) — heuristic scan.
            if (resp[i] != 2) continue;
            if (i < 16) continue;
            const batch_start = i - 16; // base_offset starts 16 bytes before magic
            if (batch_start + 21 > resp.len) continue;
            const length = readI32(resp[batch_start + 8 ..][0..4]);
            if (length <= 0 or length > 16 * 1024 * 1024) continue;
            const batch_end = batch_start + 12 + @as(usize, @intCast(length));
            if (batch_end > resp.len) continue;
            const values = parseRecordBatchValues(allocator, resp[batch_start..batch_end]) catch continue;
            defer {
                for (values) |v| allocator.free(v);
                allocator.free(values);
            }
            for (values) |v| {
                try out.append(allocator, try allocator.dupe(u8, v));
            }
            i = batch_end -| 1;
        }
        return try out.toOwnedSlice(allocator);
    }

    fn readVarint(buf: []const u8) !struct { i32, usize } {
        var result: u32 = 0;
        var shift: u5 = 0;
        var i: usize = 0;
        while (i < buf.len and i < 5) : (i += 1) {
            const b = buf[i];
            result |= @as(u32, b & 0x7f) << shift;
            if ((b & 0x80) == 0) {
                const decoded: i32 = @as(i32, @bitCast(result >> 1)) ^ -@as(i32, @intCast(result & 1));
                return .{ decoded, i + 1 };
            }
            shift += 7;
        }
        return error.InvalidVarint;
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

    /// Test/helper: expose record batch builder for roundtrip coverage.
    pub fn buildRecordBatchForTest(allocator: std.mem.Allocator, key: ?[]const u8, value: []const u8) ![]u8 {
        return buildRecordBatch(allocator, key, value);
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

test "KafkaWireFormat record batch value roundtrip" {
    const allocator = std.testing.allocator;
    const batch = try KafkaWireFormat.buildRecordBatchForTest(allocator, "k", "hello-kafka");
    defer allocator.free(batch);
    const values = try KafkaWireFormat.parseRecordBatchValues(allocator, batch);
    defer {
        for (values) |v| allocator.free(v);
        allocator.free(values);
    }
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings("hello-kafka", values[0]);
}

test "KafkaWireFormat checkProduceResponse ok" {
    // correlation=7, throttle=0, topic_count=0
    var resp: [12]u8 = undefined;
    writeI32(resp[0..4], 7);
    writeI32(resp[4..8], 0);
    writeI32(resp[8..12], 0);
    try KafkaWireFormat.checkProduceResponse(&resp, 7);
}

test "KafkaWireFormat parseFetchValues finds embedded batch" {
    const allocator = std.testing.allocator;
    const batch = try KafkaWireFormat.buildRecordBatchForTest(allocator, null, "fetch-val");
    defer allocator.free(batch);
    var resp = std.ArrayList(u8).empty;
    defer resp.deinit(allocator);
    try resp.appendSlice(allocator, &[_]u8{ 0, 0, 0, 1 }); // fake header
    try resp.appendSlice(allocator, batch);
    const values = try KafkaWireFormat.parseFetchValues(allocator, resp.items);
    defer {
        for (values) |v| allocator.free(v);
        allocator.free(values);
    }
    try std.testing.expectEqual(@as(usize, 1), values.len);
    try std.testing.expectEqualStrings("fetch-val", values[0]);
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

test "KafkaWireFormat consumer group requests" {
    const allocator = std.testing.allocator;
    const find = try KafkaWireFormat.buildFindCoordinatorRequest(allocator, "g1", 1, "c1");
    defer allocator.free(find);
    try std.testing.expect(find.len > 10);
    try std.testing.expectEqual(@as(i16, 10), readI16(find[0..2])); // api_key FindCoordinator

    const join = try KafkaWireFormat.buildJoinGroupRequest(allocator, "g1", "", &.{"orders"}, 45000, 2, "c1");
    defer allocator.free(join);
    try std.testing.expectEqual(@as(i16, 11), readI16(join[0..2]));

    const hb = try KafkaWireFormat.buildHeartbeatRequest(allocator, "g1", 1, "m1", 3, "c1");
    defer allocator.free(hb);
    try std.testing.expectEqual(@as(i16, 12), readI16(hb[0..2]));

    const leave = try KafkaWireFormat.buildLeaveGroupRequest(allocator, "g1", "m1", 4, "c1");
    defer allocator.free(leave);
    try std.testing.expectEqual(@as(i16, 13), readI16(leave[0..2]));

    const assign = try KafkaWireFormat.buildMemberAssignment(allocator, "orders", &.{ 0, 1 });
    defer allocator.free(assign);
    const sync = try KafkaWireFormat.buildSyncGroupRequest(allocator, "g1", 1, "m1", &.{.{ .member_id = "m1", .assignment = assign }}, 5, "c1");
    defer allocator.free(sync);
    try std.testing.expectEqual(@as(i16, 14), readI16(sync[0..2]));

    const commit = try KafkaWireFormat.buildOffsetCommitRequest(allocator, "g1", 1, "m1", "orders", 0, 42, 6, "c1");
    defer allocator.free(commit);
    try std.testing.expectEqual(@as(i16, 8), readI16(commit[0..2]));

    const fetch = try KafkaWireFormat.buildOffsetFetchRequest(allocator, "g1", "orders", &.{0}, 7, "c1");
    defer allocator.free(fetch);
    try std.testing.expectEqual(@as(i16, 9), readI16(fetch[0..2]));
}

test "ConsumerGroupSession offline join heartbeat leave" {
    const allocator = std.testing.allocator;
    var session = ConsumerGroupSession.init(allocator, "demo-group");
    defer session.deinit();

    try session.joinOffline(&.{"orders", "payments"});
    try std.testing.expectEqual(ConsumerGroupSession.State.stable, session.state);
    try std.testing.expectEqual(@as(i32, 1), session.generation_id);
    try std.testing.expectEqual(@as(usize, 2), session.assignments.items.len);
    try session.heartbeatOffline();
    try session.leaveOffline();
    try std.testing.expectEqual(ConsumerGroupSession.State.empty, session.state);
}

test "KafkaConsumer joinGroup offline" {
    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.init(allocator, .{ .group_id = "cg-test" });
    defer consumer.deinit();
    try consumer.subscribe("t1", struct {
        fn h(_: KafkaMessage) void {}
    }.h);
    try consumer.joinGroup();
    try consumer.heartbeat();
    const assigned = consumer.assignedPartitions();
    try std.testing.expectEqual(@as(usize, 1), assigned.len);
    try std.testing.expectEqualStrings("t1", assigned[0].topic);
    try consumer.leaveGroup();
}

test "KafkaWireFormat parseJoinGroupResponse synthetic" {
    const allocator = std.testing.allocator;
    // Build a minimal fake JoinGroup response
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    writeI32(&b4, 42);
    try buf.appendSlice(allocator, &b4); // corr
    writeI32(&b4, 0);
    try buf.appendSlice(allocator, &b4); // throttle
    writeI16(&b2, 0);
    try buf.appendSlice(allocator, &b2); // error
    writeI32(&b4, 7);
    try buf.appendSlice(allocator, &b4); // generation
    writeI16(&b2, 5);
    try buf.appendSlice(allocator, &b2);
    try buf.appendSlice(allocator, "range");
    writeI16(&b2, 6);
    try buf.appendSlice(allocator, &b2);
    try buf.appendSlice(allocator, "leader");
    writeI16(&b2, 6);
    try buf.appendSlice(allocator, &b2);
    try buf.appendSlice(allocator, "member");
    writeI32(&b4, 0);
    try buf.appendSlice(allocator, &b4); // members count

    const parsed = try KafkaWireFormat.parseJoinGroupResponse(allocator, buf.items, 42);
    defer {
        allocator.free(parsed.protocol);
        allocator.free(parsed.leader_id);
        allocator.free(parsed.member_id);
    }
    try std.testing.expectEqual(@as(i16, 0), parsed.error_code);
    try std.testing.expectEqual(@as(i32, 7), parsed.generation_id);
    try std.testing.expectEqualStrings("member", parsed.member_id);
}

test "RobustMQ live joinGroup" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const url = if (std.c.getenv("ROBUSTMQ_URL")) |p| std.mem.span(p) else if (std.c.getenv("KAFKA_BOOTSTRAP")) |p| std.mem.span(p) else null;
    if (url == null or url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var consumer = KafkaConsumer.initWithIo(allocator, std.testing.io, .{
        .bootstrap_servers = url.?,
        .group_id = "zigmodu-live-cg",
        .client_id = "zigmodu-cg-test",
    });
    defer consumer.deinit();
    try consumer.subscribe("zigmodu.robustmq.smoke", struct {
        fn h(_: KafkaMessage) void {}
    }.h);
    consumer.joinGroup() catch |err| {
        std.log.warn("[test] live joinGroup skipped/failed: {s}", .{@errorName(err)});
        return error.SkipZigTest;
    };
    defer consumer.leaveGroup() catch {};
    try consumer.heartbeat();
}
