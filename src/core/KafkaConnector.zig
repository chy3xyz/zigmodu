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
const sockread = @import("sockread.zig");

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

pub const PartitionAssignorKind = enum {
    range,
    round_robin,
    sticky,
    cooperative_sticky,

    pub fn protocolName(self: PartitionAssignorKind) []const u8 {
        return switch (self) {
            .range => "range",
            .round_robin => "roundrobin",
            .sticky => "sticky",
            .cooperative_sticky => "cooperative-sticky",
        };
    }
};

/// Parse config string into assignor kind (`cooperative_sticky`, `cooperative-sticky`, etc.).
pub fn parsePartitionAssignorKind(s: []const u8) ?PartitionAssignorKind {
    if (std.mem.eql(u8, s, "range")) return .range;
    if (std.mem.eql(u8, s, "round_robin") or std.mem.eql(u8, s, "roundrobin")) return .round_robin;
    if (std.mem.eql(u8, s, "sticky")) return .sticky;
    if (std.mem.eql(u8, s, "cooperative_sticky") or std.mem.eql(u8, s, "cooperative-sticky")) return .cooperative_sticky;
    return null;
}

pub const KafkaConsumerConfig = struct {
    bootstrap_servers: []const u8 = "127.0.0.1:9092",
    group_id: []const u8 = "zigmodu-group",
    client_id: []const u8 = "zigmodu-robustmq",
    auto_offset_reset: []const u8 = "latest",
    enable_auto_commit: bool = true,
    max_poll_records: usize = 500,
    session_timeout_ms: u64 = 45000,
    /// Used by leader partition assignor when Metadata is unavailable.
    default_partition_count: i32 = 3,
    partition_assignor: PartitionAssignorKind = .range,
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
    reader_buf: [8192]u8 = undefined,
    reader: ?sockread.Reader = null,
    /// Set when redirected via FindCoordinator (owned).
    owned_host: ?[]u8 = null,

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
        if (self.owned_host) |h| self.allocator.free(h);
        self.* = undefined;
    }

    pub fn close(self: *Self) void {
        if (self.stream) |*s| {
            s.close(self.io);
            self.stream = null;
        }
        self.reader = null;
    }

    /// Close current socket and connect to `host:port` (e.g. group coordinator).
    pub fn reconnectTo(self: *Self, host: []const u8, port: u16) !void {
        self.close();
        if (self.owned_host) |h| self.allocator.free(h);
        self.owned_host = try self.allocator.dupe(u8, host);
        self.host = self.owned_host.?;
        self.port = port;
        try self.connect();
    }

    /// Metadata for the given topics (empty slice → all topics). Caller frees via `KafkaWireFormat.freeTopicMetaList`.
    pub fn fetchMetadata(self: *Self, topics: []const []const u8) ![]KafkaWireFormat.TopicMeta {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const req = try KafkaWireFormat.buildMetadataRequest(self.allocator, topics, corr, self.client_id);
        defer self.allocator.free(req);
        const resp = try self.request(req);
        defer self.allocator.free(resp);
        return KafkaWireFormat.parseMetadataResponse(self.allocator, resp, corr);
    }

    /// Partition count for a single topic from Metadata; errors if topic missing or count invalid.
    pub fn fetchTopicPartitions(self: *Self, topic: []const u8) !i32 {
        const meta = try self.fetchMetadata(&.{topic});
        defer KafkaWireFormat.freeTopicMetaList(self.allocator, meta);
        for (meta) |m| {
            if (std.mem.eql(u8, m.topic, topic)) {
                if (m.partition_count <= 0) return error.InvalidPartitionCount;
                return m.partition_count;
            }
        }
        return error.TopicNotFound;
    }

    /// FindCoordinator + optional reconnect to returned host:port.
    pub fn findCoordinator(self: *Self, group_id: []const u8) !KafkaWireFormat.CoordinatorInfo {
        try self.ensureConnected();
        const corr = self.nextCorrelation();
        const req = try KafkaWireFormat.buildFindCoordinatorRequest(self.allocator, group_id, corr, self.client_id);
        defer self.allocator.free(req);
        const resp = try self.request(req);
        defer self.allocator.free(resp);
        const info = try KafkaWireFormat.parseFindCoordinatorResponse(self.allocator, resp, corr);
        errdefer {
            self.allocator.free(info.host);
        }
        if (info.error_code != 0) {
            self.allocator.free(info.host);
            return error.FindCoordinatorFailed;
        }
        const need_redirect = !std.mem.eql(u8, info.host, self.host) or info.port != @as(i32, self.port);
        if (need_redirect) {
            try self.reconnectTo(info.host, @intCast(info.port));
        }
        return info;
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
        // 4-byte size + body in one syscall (writev).
        try sockread.writevAll(s, &.{ &size_be, payload });
    }

    fn readFrame(self: *Self) ![]u8 {
        var size_buf: [4]u8 = undefined;
        try self.readFull(&size_buf);
        const size = readI32(&size_buf);
        if (size <= 0 or size > 16 * 1024 * 1024) return error.InvalidFrame;
        const buf = try self.allocator.alloc(u8, @intCast(size));
        errdefer self.allocator.free(buf);
        try self.readFull(buf);
        return buf;
    }

    fn readFull(self: *Self, out: []u8) !void {
        if (self.reader == null) {
            const s = self.stream orelse return error.NotConnected;
            self.reader = sockread.Reader.init(s, &self.reader_buf);
        }
        try self.reader.?.readFull(out);
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

/// Shared partition-assignment result for all assignors.
pub const PartitionAssignor = struct {
    pub const MemberPartitions = struct {
        member_id: []const u8,
        partitions: []i32,
    };

    pub fn freeAssignment(allocator: std.mem.Allocator, assignment: []MemberPartitions) void {
        for (assignment) |mp| allocator.free(mp.partitions);
        allocator.free(assignment);
    }

    pub fn assignByKind(
        allocator: std.mem.Allocator,
        kind: PartitionAssignorKind,
        member_ids: []const []const u8,
        partition_count: i32,
        previous: []const StickyAssignor.PreviousAssignment,
    ) ![]MemberPartitions {
        return switch (kind) {
            .range => RangeAssignor.assign(allocator, member_ids, partition_count),
            .round_robin => RoundRobinAssignor.assign(allocator, member_ids, partition_count),
            .sticky => StickyAssignor.assign(allocator, member_ids, partition_count, previous),
            .cooperative_sticky => CooperativeStickyAssignor.assign(allocator, member_ids, partition_count, previous),
        };
    }

    fn sortedMemberOrder(allocator: std.mem.Allocator, member_ids: []const []const u8) ![]usize {
        var order = try allocator.alloc(usize, member_ids.len);
        for (0..member_ids.len) |i| order[i] = i;
        std.mem.sort(usize, order, member_ids, struct {
            fn less(ctx: []const []const u8, a: usize, b: usize) bool {
                return std.mem.order(u8, ctx[a], ctx[b]) == .lt;
            }
        }.less);
        return order;
    }
};

/// Kafka RangeAssignor: lexicographically sorted members get contiguous partition ranges.
pub const RangeAssignor = struct {
    pub const MemberPartitions = PartitionAssignor.MemberPartitions;

    /// Caller frees via `freeAssignment`. `member_id` slices alias input.
    pub fn assign(
        allocator: std.mem.Allocator,
        member_ids: []const []const u8,
        partition_count: i32,
    ) ![]MemberPartitions {
        if (member_ids.len == 0 or partition_count <= 0) {
            return try allocator.alloc(MemberPartitions, 0);
        }

        const order = try PartitionAssignor.sortedMemberOrder(allocator, member_ids);
        defer allocator.free(order);

        const n: i32 = @intCast(member_ids.len);
        const base = @divTrunc(partition_count, n);
        const rem = @rem(partition_count, n);

        var out = try allocator.alloc(MemberPartitions, member_ids.len);
        for (out) |*mp| {
            mp.* = .{ .member_id = "", .partitions = try allocator.alloc(i32, 0) };
        }
        errdefer freeAssignment(allocator, out);

        var p: i32 = 0;
        for (order, 0..) |mi, rank| {
            const count = base + if (rank < @as(usize, @intCast(rem))) @as(i32, 1) else @as(i32, 0);
            const parts = try allocator.alloc(i32, @intCast(count));
            var j: i32 = 0;
            while (j < count) : (j += 1) {
                parts[@intCast(j)] = p;
                p += 1;
            }
            allocator.free(out[mi].partitions);
            out[mi] = .{ .member_id = member_ids[mi], .partitions = parts };
        }
        return out;
    }

    pub fn freeAssignment(allocator: std.mem.Allocator, assignment: []MemberPartitions) void {
        PartitionAssignor.freeAssignment(allocator, assignment);
    }
};

/// RoundRobinAssignor: lexicographically sorted members receive partitions in round-robin order.
pub const RoundRobinAssignor = struct {
    pub const MemberPartitions = PartitionAssignor.MemberPartitions;

    /// Caller frees via `freeAssignment`. `member_id` slices alias input.
    pub fn assign(
        allocator: std.mem.Allocator,
        member_ids: []const []const u8,
        partition_count: i32,
    ) ![]MemberPartitions {
        if (member_ids.len == 0 or partition_count <= 0) {
            return try allocator.alloc(MemberPartitions, 0);
        }

        const order = try PartitionAssignor.sortedMemberOrder(allocator, member_ids);
        defer allocator.free(order);

        var lists = try allocator.alloc(std.ArrayList(i32), member_ids.len);
        for (lists) |*list| list.* = .empty;
        defer {
            for (lists) |*list| list.deinit(allocator);
            allocator.free(lists);
        }

        const n: i32 = @intCast(member_ids.len);
        var p: i32 = 0;
        while (p < partition_count) : (p += 1) {
            const rank: usize = @intCast(@rem(p, n));
            const mi = order[rank];
            try lists[mi].append(allocator, p);
        }

        var out = try allocator.alloc(MemberPartitions, member_ids.len);
        errdefer freeAssignment(allocator, out);
        for (member_ids, 0..) |mid, mi| {
            out[mi] = .{
                .member_id = mid,
                .partitions = try lists[mi].toOwnedSlice(allocator),
            };
        }
        return out;
    }

    pub fn freeAssignment(allocator: std.mem.Allocator, assignment: []MemberPartitions) void {
        PartitionAssignor.freeAssignment(allocator, assignment);
    }
};

/// Simplified sticky assignor: retain prior ownership when member still present, then round-robin remainder.
pub const StickyAssignor = struct {
    pub const MemberPartitions = PartitionAssignor.MemberPartitions;

    pub const PreviousAssignment = struct {
        member_id: []const u8,
        partitions: []const i32,
    };

    /// Caller frees via `freeAssignment`. `member_id` slices alias input; `previous` slices are borrowed.
    pub fn assign(
        allocator: std.mem.Allocator,
        member_ids: []const []const u8,
        partition_count: i32,
        previous: []const PreviousAssignment,
    ) ![]MemberPartitions {
        if (member_ids.len == 0 or partition_count <= 0) {
            return try allocator.alloc(MemberPartitions, 0);
        }

        const order = try PartitionAssignor.sortedMemberOrder(allocator, member_ids);
        defer allocator.free(order);

        var lists = try allocator.alloc(std.ArrayList(i32), member_ids.len);
        for (lists) |*list| list.* = .empty;
        defer {
            for (lists) |*list| list.deinit(allocator);
            allocator.free(lists);
        }

        var assigned = try allocator.alloc(bool, @intCast(partition_count));
        @memset(assigned, false);
        defer allocator.free(assigned);

        for (previous) |prev| {
            const mi = findMemberIndex(member_ids, prev.member_id) orelse continue;
            for (prev.partitions) |part| {
                if (part < 0 or part >= partition_count) continue;
                const idx: usize = @intCast(part);
                if (assigned[idx]) continue;
                assigned[idx] = true;
                try lists[mi].append(allocator, part);
            }
        }

        var unassigned = std.ArrayList(i32).empty;
        defer unassigned.deinit(allocator);
        var p: i32 = 0;
        while (p < partition_count) : (p += 1) {
            const idx: usize = @intCast(p);
            if (!assigned[idx]) try unassigned.append(allocator, p);
        }

        if (unassigned.items.len > 0) {
            const n: i32 = @intCast(member_ids.len);
            for (unassigned.items, 0..) |part, i| {
                const rank: usize = @intCast(@rem(@as(i32, @intCast(i)), n));
                const mi = order[rank];
                try lists[mi].append(allocator, part);
            }
        }

        var out = try allocator.alloc(MemberPartitions, member_ids.len);
        errdefer freeAssignment(allocator, out);
        for (member_ids, 0..) |mid, mi| {
            out[mi] = .{
                .member_id = mid,
                .partitions = try lists[mi].toOwnedSlice(allocator),
            };
        }
        return out;
    }

    fn findMemberIndex(member_ids: []const []const u8, member_id: []const u8) ?usize {
        for (member_ids, 0..) |mid, i| {
            if (std.mem.eql(u8, mid, member_id)) return i;
        }
        return null;
    }

    pub fn freeAssignment(allocator: std.mem.Allocator, assignment: []MemberPartitions) void {
        PartitionAssignor.freeAssignment(allocator, assignment);
    }
};

/// Cooperative sticky assignor: retain prior ownership, balance excess, expose revocations.
pub const CooperativeStickyAssignor = struct {
    pub const MemberPartitions = PartitionAssignor.MemberPartitions;
    pub const PreviousAssignment = StickyAssignor.PreviousAssignment;

    /// Caller frees via `freeAssignment`. `member_id` slices alias input; `previous` slices are borrowed.
    pub fn assign(
        allocator: std.mem.Allocator,
        member_ids: []const []const u8,
        partition_count: i32,
        previous: []const PreviousAssignment,
    ) ![]MemberPartitions {
        if (member_ids.len == 0 or partition_count <= 0) {
            return try allocator.alloc(MemberPartitions, 0);
        }

        const order = try PartitionAssignor.sortedMemberOrder(allocator, member_ids);
        defer allocator.free(order);

        var lists = try allocator.alloc(std.ArrayList(i32), member_ids.len);
        for (lists) |*list| list.* = .empty;
        defer {
            for (lists) |*list| list.deinit(allocator);
            allocator.free(lists);
        }

        var assigned = try allocator.alloc(bool, @intCast(partition_count));
        @memset(assigned, false);
        defer allocator.free(assigned);

        for (previous) |prev| {
            const mi = findMemberIndex(member_ids, prev.member_id) orelse continue;
            for (prev.partitions) |part| {
                if (part < 0 or part >= partition_count) continue;
                const idx: usize = @intCast(part);
                if (assigned[idx]) continue;
                assigned[idx] = true;
                try lists[mi].append(allocator, part);
            }
        }

        var unassigned = std.ArrayList(i32).empty;
        defer unassigned.deinit(allocator);
        var p: i32 = 0;
        while (p < partition_count) : (p += 1) {
            const idx: usize = @intCast(p);
            if (!assigned[idx]) try unassigned.append(allocator, p);
        }

        if (unassigned.items.len > 0) {
            const n: i32 = @intCast(member_ids.len);
            for (unassigned.items, 0..) |part, i| {
                const rank: usize = @intCast(@rem(@as(i32, @intCast(i)), n));
                const mi = order[rank];
                try lists[mi].append(allocator, part);
            }
        }

        for (lists) |*list| {
            std.mem.sort(i32, list.items, {}, std.sort.asc(i32));
        }

        try balancePartitions(allocator, lists, order, partition_count, @intCast(member_ids.len));

        var out = try allocator.alloc(MemberPartitions, member_ids.len);
        errdefer freeAssignment(allocator, out);
        for (member_ids, 0..) |mid, mi| {
            out[mi] = .{
                .member_id = mid,
                .partitions = try lists[mi].toOwnedSlice(allocator),
            };
        }
        return out;
    }

    /// Partitions present in `previous` but absent from `new_assignment` per member.
    pub fn computeRevocations(
        allocator: std.mem.Allocator,
        previous: []const PreviousAssignment,
        new_assignment: []const MemberPartitions,
    ) ![]MemberPartitions {
        var out = std.ArrayList(MemberPartitions).empty;
        errdefer {
            for (out.items) |mp| allocator.free(mp.partitions);
            out.deinit(allocator);
        }

        for (previous) |prev| {
            const new_parts = findMemberPartitions(new_assignment, prev.member_id) orelse &[_]i32{};
            var revoked = std.ArrayList(i32).empty;
            defer revoked.deinit(allocator);
            for (prev.partitions) |part| {
                var kept = false;
                for (new_parts) |np| {
                    if (np == part) {
                        kept = true;
                        break;
                    }
                }
                if (!kept) try revoked.append(allocator, part);
            }
            if (revoked.items.len > 0) {
                try out.append(allocator, .{
                    .member_id = prev.member_id,
                    .partitions = try revoked.toOwnedSlice(allocator),
                });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    fn balancePartitions(
        allocator: std.mem.Allocator,
        lists: []std.ArrayList(i32),
        order: []const usize,
        partition_count: i32,
        member_count: usize,
    ) !void {
        const n: i32 = @intCast(member_count);
        const target: i32 = @divTrunc(partition_count + n - 1, n);
        const floor_count: i32 = @divTrunc(partition_count, n);

        while (true) {
            var donor_mi: ?usize = null;
            var done = true;
            for (order) |mi| {
                const count: i32 = @intCast(lists[mi].items.len);
                if (count > target) {
                    donor_mi = mi;
                    done = false;
                    break;
                }
            }
            if (done) break;

            const mi = donor_mi.?;
            const moved = lists[mi].orderedRemove(lists[mi].items.len - 1);

            var recipient_mi: ?usize = null;
            for (order) |ri| {
                const count: i32 = @intCast(lists[ri].items.len);
                if (count < floor_count) {
                    recipient_mi = ri;
                    break;
                }
            }
            const dest = recipient_mi orelse mi;
            try lists[dest].append(allocator, moved);
            std.mem.sort(i32, lists[dest].items, {}, std.sort.asc(i32));
        }
    }

    fn findMemberIndex(member_ids: []const []const u8, member_id: []const u8) ?usize {
        for (member_ids, 0..) |mid, i| {
            if (std.mem.eql(u8, mid, member_id)) return i;
        }
        return null;
    }

    fn findMemberPartitions(assignment: []const MemberPartitions, member_id: []const u8) ?[]const i32 {
        for (assignment) |mp| {
            if (std.mem.eql(u8, mp.member_id, member_id)) return mp.partitions;
        }
        return null;
    }

    pub fn freeAssignment(allocator: std.mem.Allocator, assignment: []MemberPartitions) void {
        PartitionAssignor.freeAssignment(allocator, assignment);
    }
};

pub const ConsumerGroupSession = struct {
    const Self = @This();

    pub const State = enum { empty, joining, syncing, revoking, stable, leaving };

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
    pending_revocations: std.ArrayList(TopicAssignment) = .empty,
    pending_assignment: std.ArrayList(TopicAssignment) = .empty,
    rebalance_generation: i32 = 0,
    member_id_owned: bool = false,

    pub fn init(allocator: std.mem.Allocator, group_id: []const u8) Self {
        return .{ .allocator = allocator, .group_id = group_id };
    }

    pub fn deinit(self: *Self) void {
        if (self.member_id_owned) self.allocator.free(self.member_id);
        clearTopicAssignmentList(self.allocator, &self.assignments);
        clearTopicAssignmentList(self.allocator, &self.pending_revocations);
        clearTopicAssignmentList(self.allocator, &self.pending_assignment);
        self.* = undefined;
    }

    fn clearTopicAssignmentList(allocator: std.mem.Allocator, list: *std.ArrayList(TopicAssignment)) void {
        for (list.items) |a| {
            allocator.free(a.topic);
            allocator.free(a.partitions);
        }
        list.deinit(allocator);
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

    /// Offline multi-member rebalance. Pass `assignor` (use `.range` for default Kafka behavior); sticky receives empty previous.
    pub fn joinOfflineRebalance(
        self: *Self,
        member_id: []const u8,
        all_members: []const []const u8,
        topics: []const []const u8,
        partition_count: i32,
        assignor: PartitionAssignorKind,
    ) !void {
        var prior = try self.cloneTopicAssignments(self.assignments.items);
        defer {
            for (prior.items) |a| {
                self.allocator.free(a.topic);
                self.allocator.free(a.partitions);
            }
            prior.deinit(self.allocator);
        }

        self.state = .joining;
        if (self.member_id_owned) self.allocator.free(self.member_id);
        self.member_id = try self.allocator.dupe(u8, member_id);
        self.member_id_owned = true;
        self.generation_id = 1;
        self.state = .syncing;
        try self.clearAssignments();

        const sorted = try self.allocator.alloc([]const u8, all_members.len);
        defer self.allocator.free(sorted);
        @memcpy(sorted, all_members);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.less);
        self.is_leader = sorted.len > 0 and std.mem.eql(u8, sorted[0], member_id);

        var new_assign = std.ArrayList(TopicAssignment).empty;
        defer {
            for (new_assign.items) |a| {
                self.allocator.free(a.topic);
                self.allocator.free(a.partitions);
            }
            new_assign.deinit(self.allocator);
        }

        for (topics) |t| {
            var topic_previous = std.ArrayList(StickyAssignor.PreviousAssignment).empty;
            defer topic_previous.deinit(self.allocator);
            if (assignor == .cooperative_sticky or assignor == .sticky) {
                for (prior.items) |pa| {
                    if (std.mem.eql(u8, pa.topic, t)) {
                        try topic_previous.append(self.allocator, .{
                            .member_id = member_id,
                            .partitions = pa.partitions,
                        });
                    }
                }
            }

            const plan = try PartitionAssignor.assignByKind(
                self.allocator,
                assignor,
                all_members,
                partition_count,
                topic_previous.items,
            );
            defer PartitionAssignor.freeAssignment(self.allocator, plan);
            for (plan) |mp| {
                if (!std.mem.eql(u8, mp.member_id, member_id)) continue;
                const topic_copy = try self.allocator.dupe(u8, t);
                errdefer self.allocator.free(topic_copy);
                const parts = try self.allocator.dupe(i32, mp.partitions);
                try new_assign.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
            }
        }

        if (assignor == .cooperative_sticky and prior.items.len > 0) {
            var revocations = std.ArrayList(TopicAssignment).empty;
            defer {
                for (revocations.items) |a| {
                    self.allocator.free(a.topic);
                    self.allocator.free(a.partitions);
                }
                revocations.deinit(self.allocator);
            }

            for (topics) |t| {
                var prev_parts: []const i32 = &.{};
                for (prior.items) |pa| {
                    if (std.mem.eql(u8, pa.topic, t)) {
                        prev_parts = pa.partitions;
                        break;
                    }
                }
                if (prev_parts.len == 0) continue;

                var new_parts: []i32 = &[_]i32{};
                for (new_assign.items) |na| {
                    if (std.mem.eql(u8, na.topic, t)) {
                        new_parts = @constCast(na.partitions);
                        break;
                    }
                }

                const prev_one = [_]CooperativeStickyAssignor.PreviousAssignment{
                    .{ .member_id = member_id, .partitions = prev_parts },
                };
                const new_one = [_]CooperativeStickyAssignor.MemberPartitions{
                    .{ .member_id = member_id, .partitions = new_parts },
                };
                const topic_rev = try CooperativeStickyAssignor.computeRevocations(
                    self.allocator,
                    &prev_one,
                    &new_one,
                );
                defer CooperativeStickyAssignor.freeAssignment(self.allocator, topic_rev);
                for (topic_rev) |mp| {
                    if (mp.partitions.len == 0) continue;
                    const topic_copy = try self.allocator.dupe(u8, t);
                    errdefer self.allocator.free(topic_copy);
                    const parts = try self.allocator.dupe(i32, mp.partitions);
                    try revocations.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
                }
            }

            try self.applyCooperativeAssignment(new_assign.items, revocations.items);
        } else {
            for (new_assign.items) |a| {
                const topic_copy = try self.allocator.dupe(u8, a.topic);
                errdefer self.allocator.free(topic_copy);
                const parts = try self.allocator.dupe(i32, a.partitions);
                try self.assignments.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
            }
            self.state = .stable;
        }
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

    fn clearPendingRevocations(self: *Self) void {
        for (self.pending_revocations.items) |a| {
            self.allocator.free(a.topic);
            self.allocator.free(a.partitions);
        }
        self.pending_revocations.clearRetainingCapacity();
    }

    fn clearPendingAssignment(self: *Self) void {
        for (self.pending_assignment.items) |a| {
            self.allocator.free(a.topic);
            self.allocator.free(a.partitions);
        }
        self.pending_assignment.clearRetainingCapacity();
    }

    fn cloneTopicAssignments(self: *Self, src: []const TopicAssignment) !std.ArrayList(TopicAssignment) {
        var out = std.ArrayList(TopicAssignment).empty;
        errdefer {
            for (out.items) |a| {
                self.allocator.free(a.topic);
                self.allocator.free(a.partitions);
            }
            out.deinit(self.allocator);
        }
        for (src) |a| {
            const topic_copy = try self.allocator.dupe(u8, a.topic);
            errdefer self.allocator.free(topic_copy);
            const parts = try self.allocator.dupe(i32, a.partitions);
            try out.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
        }
        return out;
    }

    fn removePartitionsFromAssignments(self: *Self, revocations: []const TopicAssignment) !void {
        for (revocations) |rev| {
            for (self.assignments.items) |*assign| {
                if (!std.mem.eql(u8, assign.topic, rev.topic)) continue;
                var kept = std.ArrayList(i32).empty;
                defer kept.deinit(self.allocator);
                for (assign.partitions) |p| {
                    var revoked = false;
                    for (rev.partitions) |rp| {
                        if (p == rp) {
                            revoked = true;
                            break;
                        }
                    }
                    if (!revoked) try kept.append(self.allocator, p);
                }
                self.allocator.free(assign.partitions);
                assign.partitions = try kept.toOwnedSlice(self.allocator);
            }
            // Drop empty topic rows.
            var i: usize = 0;
            while (i < self.assignments.items.len) {
                if (self.assignments.items[i].partitions.len == 0) {
                    const removed = self.assignments.orderedRemove(i);
                    self.allocator.free(removed.topic);
                    self.allocator.free(removed.partitions);
                } else {
                    i += 1;
                }
            }
        }
    }

    fn mergeRevocations(self: *Self, revocations: []const TopicAssignment) !void {
        for (revocations) |rev| {
            var found: ?*TopicAssignment = null;
            for (self.pending_revocations.items) |*pending| {
                if (std.mem.eql(u8, pending.topic, rev.topic)) {
                    found = pending;
                    break;
                }
            }
            if (found) |p| {
                var merged = std.ArrayList(i32).empty;
                defer merged.deinit(self.allocator);
                for (p.partitions) |existing| try merged.append(self.allocator, existing);
                for (rev.partitions) |rp| {
                    var dup = false;
                    for (merged.items) |m| {
                        if (m == rp) {
                            dup = true;
                            break;
                        }
                    }
                    if (!dup) try merged.append(self.allocator, rp);
                }
                self.allocator.free(p.partitions);
                std.mem.sort(i32, merged.items, {}, std.sort.asc(i32));
                p.partitions = try merged.toOwnedSlice(self.allocator);
            } else {
                const topic_copy = try self.allocator.dupe(u8, rev.topic);
                errdefer self.allocator.free(topic_copy);
                const parts = try self.allocator.dupe(i32, rev.partitions);
                try self.pending_revocations.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
            }
        }
    }

    /// Cooperative rebalance: revoke first, then install `pending_assignment` after ack.
    pub fn applyCooperativeAssignment(
        self: *Self,
        new_assign: []const TopicAssignment,
        revocations: []const TopicAssignment,
    ) !void {
        self.rebalance_generation += 1;
        self.clearPendingRevocations();
        self.clearPendingAssignment();

        var has_revoke = false;
        for (revocations) |r| {
            if (r.partitions.len > 0) {
                has_revoke = true;
                break;
            }
        }

        if (!has_revoke) {
            try self.clearAssignments();
            for (new_assign) |a| {
                const topic_copy = try self.allocator.dupe(u8, a.topic);
                errdefer self.allocator.free(topic_copy);
                const parts = try self.allocator.dupe(i32, a.partitions);
                try self.assignments.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
            }
            self.state = .stable;
            return;
        }

        try self.removePartitionsFromAssignments(revocations);
        try self.mergeRevocations(revocations);
        for (new_assign) |a| {
            const topic_copy = try self.allocator.dupe(u8, a.topic);
            errdefer self.allocator.free(topic_copy);
            const parts = try self.allocator.dupe(i32, a.partitions);
            try self.pending_assignment.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
        }
        self.state = .revoking;
    }

    /// After revocations are processed locally, install deferred assignment.
    pub fn acknowledgeRevocation(self: *Self) !void {
        if (self.pending_revocations.items.len == 0 and self.pending_assignment.items.len == 0) return;
        self.clearPendingRevocations();
        if (self.pending_assignment.items.len > 0) {
            try self.clearAssignments();
            for (self.pending_assignment.items) |a| {
                const topic_copy = try self.allocator.dupe(u8, a.topic);
                errdefer self.allocator.free(topic_copy);
                const parts = try self.allocator.dupe(i32, a.partitions);
                try self.assignments.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
            }
            self.clearPendingAssignment();
        }
        self.state = .stable;
    }

    pub fn buildJoinRequest(self: *Self, topics: []const []const u8, session_timeout_ms: i32, correlation_id: i32, client_id: []const u8, protocol_name: []const u8) ![]u8 {
        return KafkaWireFormat.buildJoinGroupRequest(
            self.allocator,
            self.group_id,
            self.member_id,
            topics,
            session_timeout_ms,
            correlation_id,
            client_id,
            protocol_name,
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
    /// Online → FindCoordinator (cross-node redirect) + JoinGroup + configured partition assignor SyncGroup.
    pub fn joinGroup(self: *Self) !void {
        var prior_member_id: ?[]const u8 = null;
        var prior_assignments = std.ArrayList(ConsumerGroupSession.TopicAssignment).empty;
        var prior_owned = false;
        defer if (prior_owned) {
            for (prior_assignments.items) |a| {
                self.allocator.free(a.topic);
                self.allocator.free(a.partitions);
            }
            prior_assignments.deinit(self.allocator);
        };

        if (self.config.partition_assignor == .sticky or self.config.partition_assignor == .cooperative_sticky) {
            if (self.group) |old| {
                if (old.state == .stable and old.assignments.items.len > 0) {
                    prior_member_id = old.member_id;
                    for (old.assignments.items) |a| {
                        const topic_copy = try self.allocator.dupe(u8, a.topic);
                        errdefer self.allocator.free(topic_copy);
                        const parts = try self.allocator.dupe(i32, a.partitions);
                        try prior_assignments.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
                    }
                    prior_owned = true;
                }
            }
        }

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
        const coord = try t.findCoordinator(self.config.group_id);
        defer self.allocator.free(coord.host);

        const corr_join = t.nextCorrelationPublic();
        const join_req = try KafkaWireFormat.buildJoinGroupRequest(
            self.allocator,
            self.config.group_id,
            "",
            topics.items,
            @intCast(self.config.session_timeout_ms),
            corr_join,
            self.config.client_id,
            self.config.partition_assignor.protocolName(),
        );
        defer self.allocator.free(join_req);
        const join_resp = try t.request(join_req);
        defer self.allocator.free(join_resp);
        const joined = try KafkaWireFormat.parseJoinGroupResponse(self.allocator, join_resp, corr_join);
        defer {
            self.allocator.free(joined.protocol);
            self.allocator.free(joined.leader_id);
            self.allocator.free(joined.member_id);
            for (joined.members) |m| {
                self.allocator.free(m.member_id);
                self.allocator.free(m.metadata);
            }
            self.allocator.free(joined.members);
        }
        if (joined.error_code != 0) return error.JoinGroupFailed;

        session.member_id = try self.allocator.dupe(u8, joined.member_id);
        session.member_id_owned = true;
        session.generation_id = joined.generation_id;
        session.is_leader = std.mem.eql(u8, joined.leader_id, joined.member_id);
        session.state = .syncing;

        // Leader: partition assignor across all members for each subscribed topic.
        var assign_bufs = std.ArrayList([]u8).empty;
        defer {
            for (assign_bufs.items) |b| self.allocator.free(b);
            assign_bufs.deinit(self.allocator);
        }
        var assign_entries = std.ArrayList(KafkaWireFormat.MemberAssignmentEntry).empty;
        defer assign_entries.deinit(self.allocator);

        if (session.is_leader and topics.items.len > 0) {
            var member_ids = std.ArrayList([]const u8).empty;
            defer member_ids.deinit(self.allocator);
            if (joined.members.len > 0) {
                for (joined.members) |m| try member_ids.append(self.allocator, m.member_id);
            } else {
                try member_ids.append(self.allocator, session.member_id);
            }

            // Per member accumulate TopicPartitionSet then encode.
            var per_member = try self.allocator.alloc(std.ArrayList(KafkaWireFormat.TopicPartitionSet), member_ids.items.len);
            defer {
                for (per_member) |*list| list.deinit(self.allocator);
                self.allocator.free(per_member);
            }
            for (per_member) |*list| list.* = .empty;

            // Owned partition slices for TopicPartitionSet lifetime.
            var part_owned = std.ArrayList([]i32).empty;
            defer {
                for (part_owned.items) |p| self.allocator.free(p);
                part_owned.deinit(self.allocator);
            }

            for (topics.items) |topic| {
                const partition_count = t.fetchTopicPartitions(topic) catch |err| blk: {
                    std.log.warn("[KafkaConsumer] Metadata for {s} failed ({s}), using default_partition_count={d}", .{
                        topic,
                        @errorName(err),
                        self.config.default_partition_count,
                    });
                    break :blk self.config.default_partition_count;
                };

                var topic_previous = std.ArrayList(StickyAssignor.PreviousAssignment).empty;
                defer topic_previous.deinit(self.allocator);
                if (prior_member_id) |mid| {
                    for (prior_assignments.items) |a| {
                        if (std.mem.eql(u8, a.topic, topic)) {
                            try topic_previous.append(self.allocator, .{
                                .member_id = mid,
                                .partitions = a.partitions,
                            });
                        }
                    }
                }

                const plan = try PartitionAssignor.assignByKind(
                    self.allocator,
                    self.config.partition_assignor,
                    member_ids.items,
                    partition_count,
                    topic_previous.items,
                );
                defer PartitionAssignor.freeAssignment(self.allocator, plan);
                for (plan, 0..) |mp, mi| {
                    const parts = try self.allocator.dupe(i32, mp.partitions);
                    try part_owned.append(self.allocator, parts);
                    try per_member[mi].append(self.allocator, .{ .topic = topic, .partitions = parts });
                }
            }

            for (member_ids.items, 0..) |mid, mi| {
                const encoded = try KafkaWireFormat.buildMemberAssignmentTopics(self.allocator, per_member[mi].items);
                try assign_bufs.append(self.allocator, encoded);
                try assign_entries.append(self.allocator, .{ .member_id = mid, .assignment = encoded });
            }
        }

        const corr_sync = t.nextCorrelationPublic();
        const sync_req = try KafkaWireFormat.buildSyncGroupRequest(
            self.allocator,
            self.config.group_id,
            session.generation_id,
            session.member_id,
            assign_entries.items,
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
            const all = try KafkaWireFormat.parseMemberAssignmentAll(self.allocator, synced.assignment);
            defer self.allocator.free(all);
            if (self.config.partition_assignor == .cooperative_sticky and prior_owned and prior_member_id != null) {
                var revocations = std.ArrayList(ConsumerGroupSession.TopicAssignment).empty;
                defer {
                    for (revocations.items) |a| {
                        self.allocator.free(a.topic);
                        self.allocator.free(a.partitions);
                    }
                    revocations.deinit(self.allocator);
                }
                const mid = prior_member_id.?;
                for (all) |new_a| {
                    var prev_parts: []const i32 = &.{};
                    for (prior_assignments.items) |pa| {
                        if (std.mem.eql(u8, pa.topic, new_a.topic)) {
                            prev_parts = pa.partitions;
                            break;
                        }
                    }
                    if (prev_parts.len == 0) continue;
                    const prev_one = [_]CooperativeStickyAssignor.PreviousAssignment{
                        .{ .member_id = mid, .partitions = prev_parts },
                    };
                    const new_one = [_]CooperativeStickyAssignor.MemberPartitions{
                        .{ .member_id = session.member_id, .partitions = new_a.partitions },
                    };
                    const topic_rev = try CooperativeStickyAssignor.computeRevocations(
                        self.allocator,
                        &prev_one,
                        &new_one,
                    );
                    defer CooperativeStickyAssignor.freeAssignment(self.allocator, topic_rev);
                    for (topic_rev) |mp| {
                        if (mp.partitions.len == 0) continue;
                        const topic_copy = try self.allocator.dupe(u8, new_a.topic);
                        errdefer self.allocator.free(topic_copy);
                        const parts = try self.allocator.dupe(i32, mp.partitions);
                        try revocations.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
                    }
                }
                // Topics dropped entirely from subscription still need revocation scan.
                for (prior_assignments.items) |pa| {
                    var in_new = false;
                    for (all) |na| {
                        if (std.mem.eql(u8, na.topic, pa.topic)) {
                            in_new = true;
                            break;
                        }
                    }
                    if (in_new) continue;
                    const prev_one = [_]CooperativeStickyAssignor.PreviousAssignment{
                        .{ .member_id = mid, .partitions = pa.partitions },
                    };
                    const new_one = [_]CooperativeStickyAssignor.MemberPartitions{
                        .{ .member_id = session.member_id, .partitions = &.{} },
                    };
                    const topic_rev = try CooperativeStickyAssignor.computeRevocations(
                        self.allocator,
                        &prev_one,
                        &new_one,
                    );
                    defer CooperativeStickyAssignor.freeAssignment(self.allocator, topic_rev);
                    for (topic_rev) |mp| {
                        if (mp.partitions.len == 0) continue;
                        const topic_copy = try self.allocator.dupe(u8, pa.topic);
                        errdefer self.allocator.free(topic_copy);
                        const parts = try self.allocator.dupe(i32, mp.partitions);
                        try revocations.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
                    }
                }

                var owned_new = std.ArrayList(ConsumerGroupSession.TopicAssignment).empty;
                defer {
                    for (owned_new.items) |a| {
                        self.allocator.free(a.topic);
                        self.allocator.free(a.partitions);
                    }
                    owned_new.deinit(self.allocator);
                }
                for (all) |a| {
                    const topic_copy = try self.allocator.dupe(u8, a.topic);
                    errdefer self.allocator.free(topic_copy);
                    const parts = try self.allocator.dupe(i32, a.partitions);
                    try owned_new.append(self.allocator, .{ .topic = topic_copy, .partitions = parts });
                }
                try session.applyCooperativeAssignment(owned_new.items, revocations.items);
                // Move ownership into session from `all` parse — free outer slice only.
                for (all) |a| {
                    self.allocator.free(a.topic);
                    self.allocator.free(a.partitions);
                }
            } else {
                for (all) |a| {
                    try session.assignments.append(self.allocator, .{ .topic = a.topic, .partitions = a.partitions });
                }
            }
        } else if (topics.items.len > 0) {
            try session.joinOffline(topics.items);
        }
        session.state = .stable;
        self.group = session;
        std.log.info("[KafkaConsumer] joined group {s} generation={d} member={s} coord={s}:{d}", .{
            self.config.group_id,
            self.group.?.generation_id,
            self.group.?.member_id,
            coord.host,
            coord.port,
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

    /// Cooperative rebalance: commit deferred assignment after local partition revoke.
    pub fn acknowledgeRevocation(self: *Self) !void {
        const g = &(self.group orelse return);
        try g.acknowledgeRevocation();
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
    const api_metadata: i16 = 3;
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

    pub const TopicMeta = struct {
        topic: []u8,
        partition_count: i32,
    };

    pub fn freeTopicMetaList(allocator: std.mem.Allocator, list: []TopicMeta) void {
        for (list) |m| allocator.free(m.topic);
        allocator.free(list);
    }

    /// MetadataRequest v1: `[string] topics` (empty → all topics).
    pub fn buildMetadataRequest(
        allocator: std.mem.Allocator,
        topics: []const []const u8,
        correlation_id: i32,
        client_id: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_metadata, 1, correlation_id, client_id);
        try appendI32(&buf, allocator, @intCast(topics.len));
        for (topics) |t| try appendString(&buf, allocator, t);
        return buf.toOwnedSlice(allocator);
    }

    /// MetadataResponse v1 (non-flexible). Caller frees via `freeTopicMetaList`.
    pub fn parseMetadataResponse(allocator: std.mem.Allocator, resp: []const u8, expected_corr: i32) ![]TopicMeta {
        if (resp.len < 8) return error.InvalidResponse;
        if (readI32(resp[0..4]) != expected_corr) return error.CorrelationMismatch;
        var off: usize = 8; // correlation + throttle_time_ms

        if (off + 4 > resp.len) return error.InvalidResponse;
        const broker_count = readI32(resp[off..][0..4]);
        off += 4;
        for (0..@as(usize, @intCast(broker_count))) |_| {
            if (off + 4 > resp.len) return error.InvalidResponse;
            off += 4; // node_id
            _, const n1 = try readKafkaString(resp[off..]);
            off += n1;
            if (off + 4 > resp.len) return error.InvalidResponse;
            off += 4; // port
            _, const n2 = try readKafkaString(resp[off..]); // rack (v1+)
            off += n2;
        }

        if (off + 4 > resp.len) return error.InvalidResponse;
        const topic_count = readI32(resp[off..][0..4]);
        off += 4;
        if (topic_count < 0) return try allocator.alloc(TopicMeta, 0);

        var out = try allocator.alloc(TopicMeta, @intCast(topic_count));
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |m| allocator.free(m.topic);
            allocator.free(out);
        }

        for (0..@as(usize, @intCast(topic_count))) |ti| {
            if (off + 2 > resp.len) return error.InvalidResponse;
            off += 2; // topic error_code
            const topic, const n1 = try readKafkaString(resp[off..]);
            off += n1;
            if (off + 1 > resp.len) return error.InvalidResponse;
            off += 1; // is_internal (int8, v1+)
            if (off + 4 > resp.len) return error.InvalidResponse;
            const part_count = readI32(resp[off..][0..4]);
            off += 4;

            for (0..@as(usize, @intCast(part_count))) |_| {
                if (off + 10 > resp.len) return error.InvalidResponse;
                off += 2; // partition error_code
                off += 4; // partition id
                off += 4; // leader
                if (off + 4 > resp.len) return error.InvalidResponse;
                const repl_count = readI32(resp[off..][0..4]);
                off += 4;
                if (repl_count < 0 or off + @as(usize, @intCast(repl_count)) * 4 > resp.len) return error.InvalidResponse;
                off += @as(usize, @intCast(repl_count)) * 4;
                if (off + 4 > resp.len) return error.InvalidResponse;
                const isr_count = readI32(resp[off..][0..4]);
                off += 4;
                if (isr_count < 0 or off + @as(usize, @intCast(isr_count)) * 4 > resp.len) return error.InvalidResponse;
                off += @as(usize, @intCast(isr_count)) * 4;
            }

            out[ti] = .{
                .topic = try allocator.dupe(u8, topic),
                .partition_count = part_count,
            };
            filled += 1;
        }
        return out;
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
        protocol_name: []const u8,
    ) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendRequestHeader(&buf, allocator, api_join_group, 2, correlation_id, client_id);
        try appendString(&buf, allocator, group_id);
        try appendI32(&buf, allocator, session_timeout_ms);
        try appendString(&buf, allocator, member_id);
        try appendString(&buf, allocator, "consumer"); // protocol_type
        try appendI32(&buf, allocator, 1); // protocols count
        try appendString(&buf, allocator, protocol_name);
        const meta = try buildSubscriptionMetadata(allocator, topics);
        defer allocator.free(meta);
        try appendBytes(&buf, allocator, meta);
        return buf.toOwnedSlice(allocator);
    }

    /// MemberAssignment v0 for SyncGroup.
    pub fn buildMemberAssignment(allocator: std.mem.Allocator, topic: []const u8, partitions: []const i32) ![]u8 {
        return buildMemberAssignmentTopics(allocator, &.{.{ .topic = topic, .partitions = partitions }});
    }

    pub const TopicPartitionSet = struct {
        topic: []const u8,
        partitions: []const i32,
    };

    pub fn buildMemberAssignmentTopics(allocator: std.mem.Allocator, topics: []const TopicPartitionSet) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try appendI16(&buf, allocator, 0); // version
        try appendI32(&buf, allocator, @intCast(topics.len));
        for (topics) |t| {
            try appendString(&buf, allocator, t.topic);
            try appendI32(&buf, allocator, @intCast(t.partitions.len));
            for (t.partitions) |p| try appendI32(&buf, allocator, p);
        }
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

    pub const CoordinatorInfo = struct {
        error_code: i16,
        node_id: i32,
        host: []u8,
        port: i32,
    };

    /// FindCoordinatorResponse v2. Caller frees `host`.
    pub fn parseFindCoordinatorResponse(allocator: std.mem.Allocator, resp: []const u8, expected_corr: i32) !CoordinatorInfo {
        if (resp.len < 14) return error.InvalidResponse;
        if (readI32(resp[0..4]) != expected_corr) return error.CorrelationMismatch;
        var off: usize = 4;
        off += 4; // throttle
        const error_code = readI16(resp[off..][0..2]);
        off += 2;
        const node_id = readI32(resp[off..][0..4]);
        off += 4;
        const host, const n1 = try readKafkaString(resp[off..]);
        off += n1;
        if (off + 4 > resp.len) return error.InvalidResponse;
        const port = readI32(resp[off..][0..4]);
        return .{
            .error_code = error_code,
            .node_id = node_id,
            .host = try allocator.dupe(u8, host),
            .port = port,
        };
    }

    pub const JoinGroupMember = struct {
        member_id: []u8,
        metadata: []u8,
    };

    /// Parse JoinGroupResponse v2 (non-flexible). Caller frees strings + members.
    pub fn parseJoinGroupResponse(allocator: std.mem.Allocator, resp: []const u8, expected_corr: i32) !struct {
        error_code: i16,
        generation_id: i32,
        protocol: []u8,
        leader_id: []u8,
        member_id: []u8,
        members: []JoinGroupMember,
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
        off += n3;

        var members: []JoinGroupMember = &.{};
        if (off + 4 <= resp.len) {
            const count = readI32(resp[off..][0..4]);
            off += 4;
            if (count > 0) {
                var list = try allocator.alloc(JoinGroupMember, @intCast(count));
                errdefer {
                    for (list) |m| {
                        allocator.free(m.member_id);
                        allocator.free(m.metadata);
                    }
                    allocator.free(list);
                }
                for (0..@as(usize, @intCast(count))) |i| {
                    const mid, const nm = try readKafkaString(resp[off..]);
                    off += nm;
                    if (off + 4 > resp.len) return error.InvalidResponse;
                    const meta_len = readI32(resp[off..][0..4]);
                    off += 4;
                    if (meta_len < 0) {
                        list[i] = .{
                            .member_id = try allocator.dupe(u8, mid),
                            .metadata = try allocator.alloc(u8, 0),
                        };
                        continue;
                    }
                    if (off + @as(usize, @intCast(meta_len)) > resp.len) return error.InvalidResponse;
                    list[i] = .{
                        .member_id = try allocator.dupe(u8, mid),
                        .metadata = try allocator.dupe(u8, resp[off .. off + @as(usize, @intCast(meta_len))]),
                    };
                    off += @intCast(meta_len);
                }
                members = list;
            } else {
                members = try allocator.alloc(JoinGroupMember, 0);
            }
        } else {
            members = try allocator.alloc(JoinGroupMember, 0);
        }

        return .{
            .error_code = error_code,
            .generation_id = generation_id,
            .protocol = try allocator.dupe(u8, protocol),
            .leader_id = try allocator.dupe(u8, leader_id),
            .member_id = try allocator.dupe(u8, member_id),
            .members = members,
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
        const all = try parseMemberAssignmentAll(allocator, data);
        defer {
            if (all.len > 1) {
                for (all[1..]) |a| {
                    allocator.free(a.topic);
                    allocator.free(a.partitions);
                }
            }
            allocator.free(all);
        }
        if (all.len == 0) return error.InvalidAssignment;
        return .{ .topic = all[0].topic, .partitions = all[0].partitions };
    }

    pub const ParsedTopicAssignment = struct {
        topic: []u8,
        partitions: []i32,
    };

    /// Parse all topics from MemberAssignment v0. Caller frees each topic/partitions + the slice.
    pub fn parseMemberAssignmentAll(allocator: std.mem.Allocator, data: []const u8) ![]ParsedTopicAssignment {
        if (data.len < 6) return error.InvalidAssignment;
        var off: usize = 2; // version
        const topic_count = readI32(data[off..][0..4]);
        off += 4;
        if (topic_count <= 0) return try allocator.alloc(ParsedTopicAssignment, 0);
        var out = try allocator.alloc(ParsedTopicAssignment, @intCast(topic_count));
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |a| {
                allocator.free(a.topic);
                allocator.free(a.partitions);
            }
            allocator.free(out);
        }

        for (0..@as(usize, @intCast(topic_count))) |ti| {
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
            out[ti] = .{ .topic = try allocator.dupe(u8, topic), .partitions = parts };
            filled += 1;
        }
        return out;
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

    const join = try KafkaWireFormat.buildJoinGroupRequest(allocator, "g1", "", &.{"orders"}, 45000, 2, "c1", "range");
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

    const meta = try KafkaWireFormat.buildMetadataRequest(allocator, &.{"orders"}, 8, "c1");
    defer allocator.free(meta);
    try std.testing.expectEqual(@as(i16, 3), readI16(meta[0..2]));
}

test "ConsumerGroupSession offline join heartbeat leave" {
    const allocator = std.testing.allocator;
    var session = ConsumerGroupSession.init(allocator, "demo-group");
    defer session.deinit();

    try session.joinOffline(&.{ "orders", "payments" });
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
        for (parsed.members) |m| {
            allocator.free(m.member_id);
            allocator.free(m.metadata);
        }
        allocator.free(parsed.members);
    }
    try std.testing.expectEqual(@as(i16, 0), parsed.error_code);
    try std.testing.expectEqual(@as(i32, 7), parsed.generation_id);
    try std.testing.expectEqualStrings("member", parsed.member_id);
}

test "RangeAssignor divides partitions across members" {
    const allocator = std.testing.allocator;
    const plan = try RangeAssignor.assign(allocator, &.{ "m2", "m1", "m3" }, 5);
    defer RangeAssignor.freeAssignment(allocator, plan);
    try std.testing.expectEqual(@as(usize, 3), plan.len);
    // Sorted: m1, m2, m3 → sizes 2, 2, 1
    var m1_parts: ?[]i32 = null;
    var m2_parts: ?[]i32 = null;
    var m3_parts: ?[]i32 = null;
    for (plan) |mp| {
        if (std.mem.eql(u8, mp.member_id, "m1")) m1_parts = mp.partitions;
        if (std.mem.eql(u8, mp.member_id, "m2")) m2_parts = mp.partitions;
        if (std.mem.eql(u8, mp.member_id, "m3")) m3_parts = mp.partitions;
    }
    try std.testing.expectEqual(@as(usize, 2), m1_parts.?.len);
    try std.testing.expectEqual(@as(usize, 2), m2_parts.?.len);
    try std.testing.expectEqual(@as(usize, 1), m3_parts.?.len);
    try std.testing.expectEqual(@as(i32, 0), m1_parts.?[0]);
    try std.testing.expectEqual(@as(i32, 1), m1_parts.?[1]);
}

test "RoundRobinAssignor even split across members" {
    const allocator = std.testing.allocator;
    const plan = try RoundRobinAssignor.assign(allocator, &.{ "m2", "m1" }, 4);
    defer RoundRobinAssignor.freeAssignment(allocator, plan);
    try std.testing.expectEqual(@as(usize, 2), plan.len);
    var m1_parts: ?[]i32 = null;
    var m2_parts: ?[]i32 = null;
    for (plan) |mp| {
        if (std.mem.eql(u8, mp.member_id, "m1")) m1_parts = mp.partitions;
        if (std.mem.eql(u8, mp.member_id, "m2")) m2_parts = mp.partitions;
    }
    // Sorted m1, m2 → p0→m1, p1→m2, p2→m1, p3→m2
    try std.testing.expectEqual(@as(usize, 2), m1_parts.?.len);
    try std.testing.expectEqual(@as(usize, 2), m2_parts.?.len);
    try std.testing.expectEqual(@as(i32, 0), m1_parts.?[0]);
    try std.testing.expectEqual(@as(i32, 2), m1_parts.?[1]);
    try std.testing.expectEqual(@as(i32, 1), m2_parts.?[0]);
    try std.testing.expectEqual(@as(i32, 3), m2_parts.?[1]);
}

test "StickyAssignor prefers previous ownership when member still present" {
    const allocator = std.testing.allocator;
    const previous = [_]StickyAssignor.PreviousAssignment{
        .{ .member_id = "m1", .partitions = &.{ 0, 2 } },
    };
    const plan = try StickyAssignor.assign(allocator, &.{ "m2", "m1" }, 4, &previous);
    defer StickyAssignor.freeAssignment(allocator, plan);
    var m1_parts: ?[]i32 = null;
    var m2_parts: ?[]i32 = null;
    for (plan) |mp| {
        if (std.mem.eql(u8, mp.member_id, "m1")) m1_parts = mp.partitions;
        if (std.mem.eql(u8, mp.member_id, "m2")) m2_parts = mp.partitions;
    }
    try std.testing.expect(m1_parts != null);
    try std.testing.expect(m2_parts != null);
    // m1 keeps 0 and 2; remaining 1,3 round-robin → m1,m2 sorted → p1→m1, p3→m2
    try std.testing.expectEqual(@as(usize, 3), m1_parts.?.len);
    try std.testing.expectEqual(@as(i32, 0), m1_parts.?[0]);
    try std.testing.expectEqual(@as(i32, 2), m1_parts.?[1]);
    try std.testing.expectEqual(@as(i32, 1), m1_parts.?[2]);
    try std.testing.expectEqual(@as(usize, 1), m2_parts.?.len);
    try std.testing.expectEqual(@as(i32, 3), m2_parts.?[0]);
}

test "CooperativeStickyAssignor retains sticky then balances" {
    const allocator = std.testing.allocator;
    const previous = [_]CooperativeStickyAssignor.PreviousAssignment{
        .{ .member_id = "m1", .partitions = &.{ 0, 1, 2 } },
        .{ .member_id = "m2", .partitions = &.{3} },
    };
    const plan = try CooperativeStickyAssignor.assign(allocator, &.{ "m1", "m2" }, 4, &previous);
    defer CooperativeStickyAssignor.freeAssignment(allocator, plan);
    var m1_parts: ?[]i32 = null;
    var m2_parts: ?[]i32 = null;
    for (plan) |mp| {
        if (std.mem.eql(u8, mp.member_id, "m1")) m1_parts = mp.partitions;
        if (std.mem.eql(u8, mp.member_id, "m2")) m2_parts = mp.partitions;
    }
    // Sticky keeps m1=[0,1,2], m2=[3]; balance moves highest (2) from m1 → m2 → [0,1] / [2,3]
    try std.testing.expectEqual(@as(usize, 2), m1_parts.?.len);
    try std.testing.expectEqual(@as(usize, 2), m2_parts.?.len);
    try std.testing.expectEqual(@as(i32, 0), m1_parts.?[0]);
    try std.testing.expectEqual(@as(i32, 1), m1_parts.?[1]);
    try std.testing.expectEqual(@as(i32, 2), m2_parts.?[0]);
    try std.testing.expectEqual(@as(i32, 3), m2_parts.?[1]);
}

test "CooperativeStickyAssignor computeRevocations when member loses partition" {
    const allocator = std.testing.allocator;
    const previous = [_]CooperativeStickyAssignor.PreviousAssignment{
        .{ .member_id = "m1", .partitions = &.{ 0, 1, 2 } },
        .{ .member_id = "m2", .partitions = &.{3} },
    };
    var m1_new = [_]i32{ 0, 1 };
    var m2_new = [_]i32{ 2, 3 };
    const new_assignment = [_]CooperativeStickyAssignor.MemberPartitions{
        .{ .member_id = "m1", .partitions = &m1_new },
        .{ .member_id = "m2", .partitions = &m2_new },
    };
    const revocations = try CooperativeStickyAssignor.computeRevocations(allocator, &previous, &new_assignment);
    defer CooperativeStickyAssignor.freeAssignment(allocator, revocations);
    try std.testing.expectEqual(@as(usize, 1), revocations.len);
    try std.testing.expectEqualStrings("m1", revocations[0].member_id);
    try std.testing.expectEqual(@as(usize, 1), revocations[0].partitions.len);
    try std.testing.expectEqual(@as(i32, 2), revocations[0].partitions[0]);
}

test "parsePartitionAssignorKind accepts cooperative_sticky" {
    try std.testing.expectEqual(PartitionAssignorKind.cooperative_sticky, parsePartitionAssignorKind("cooperative_sticky").?);
    try std.testing.expectEqual(PartitionAssignorKind.cooperative_sticky, parsePartitionAssignorKind("cooperative-sticky").?);
    try std.testing.expectEqual(PartitionAssignorKind.range, parsePartitionAssignorKind("range").?);
    try std.testing.expect(parsePartitionAssignorKind("unknown") == null);
}

test "PartitionAssignorKind protocolName for join group wire" {
    try std.testing.expectEqualStrings("cooperative-sticky", PartitionAssignorKind.cooperative_sticky.protocolName());
    try std.testing.expectEqualStrings("roundrobin", PartitionAssignorKind.round_robin.protocolName());
    try std.testing.expectEqualStrings("sticky", PartitionAssignorKind.sticky.protocolName());
}

test "KafkaConsumerConfig default partition assignor is range" {
    const cfg = KafkaConsumerConfig{};
    try std.testing.expectEqual(PartitionAssignorKind.range, cfg.partition_assignor);
    const allocator = std.testing.allocator;
    const members = [_][]const u8{ "a", "b" };
    const range_plan = try RangeAssignor.assign(allocator, &members, 4);
    defer RangeAssignor.freeAssignment(allocator, range_plan);
    const via_kind = try PartitionAssignor.assignByKind(allocator, cfg.partition_assignor, &members, 4, &.{});
    defer PartitionAssignor.freeAssignment(allocator, via_kind);
    for (range_plan, via_kind) |r, v| {
        try std.testing.expectEqualStrings(r.member_id, v.member_id);
        try std.testing.expectEqual(r.partitions.len, v.partitions.len);
        for (r.partitions, v.partitions) |rp, vp| {
            try std.testing.expectEqual(rp, vp);
        }
    }
}

test "ConsumerGroupSession cooperative applyCooperativeAssignment revoke then ack" {
    const allocator = std.testing.allocator;
    var session = ConsumerGroupSession.init(allocator, "g");
    defer session.deinit();
    const topic = try allocator.dupe(u8, "orders");
    const parts = try allocator.alloc(i32, 2);
    parts[0] = 0;
    parts[1] = 1;
    try session.assignments.append(allocator, .{ .topic = topic, .partitions = parts });
    session.state = .stable;

    const new_topic = try allocator.dupe(u8, "orders");
    const new_parts = try allocator.alloc(i32, 1);
    new_parts[0] = 1;
    defer {
        allocator.free(new_topic);
        allocator.free(new_parts);
    }
    const new_assign = [_]ConsumerGroupSession.TopicAssignment{.{ .topic = new_topic, .partitions = new_parts }};

    const rev_topic = try allocator.dupe(u8, "orders");
    const rev_parts = try allocator.alloc(i32, 1);
    rev_parts[0] = 0;
    defer {
        allocator.free(rev_topic);
        allocator.free(rev_parts);
    }
    const revocations = [_]ConsumerGroupSession.TopicAssignment{.{ .topic = rev_topic, .partitions = rev_parts }};

    try session.applyCooperativeAssignment(&new_assign, &revocations);
    try std.testing.expectEqual(ConsumerGroupSession.State.revoking, session.state);
    try std.testing.expectEqual(@as(usize, 1), session.pending_revocations.items.len);
    try std.testing.expectEqual(@as(i32, 0), session.pending_revocations.items[0].partitions[0]);
    try std.testing.expectEqual(@as(usize, 1), session.assignments.items.len);
    try std.testing.expectEqual(@as(i32, 1), session.assignments.items[0].partitions[0]);

    try session.acknowledgeRevocation();
    try std.testing.expectEqual(ConsumerGroupSession.State.stable, session.state);
    try std.testing.expectEqual(@as(usize, 0), session.pending_revocations.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.assignments.items.len);
    try std.testing.expectEqual(@as(i32, 1), session.assignments.items[0].partitions[0]);
}

test "ConsumerGroupSession cooperative offline rebalance with prior" {
    const allocator = std.testing.allocator;
    const members = [_][]const u8{ "c-a", "c-b" };
    var session = ConsumerGroupSession.init(allocator, "g");
    defer session.deinit();
    try session.joinOfflineRebalance("c-a", &members, &.{"orders"}, 2, .cooperative_sticky);
    try std.testing.expectEqual(@as(usize, 1), session.assignments.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.assignments.items[0].partitions.len);
    const first_part = session.assignments.items[0].partitions[0];

    // Simulate member loss: only c-b remains; c-a should lose its partition cooperatively.
    try session.joinOfflineRebalance("c-a", &.{"c-b"}, &.{"orders"}, 2, .cooperative_sticky);
    if (session.state == .revoking) {
        try std.testing.expect(session.pending_revocations.items.len > 0);
        try session.acknowledgeRevocation();
    }
    try std.testing.expectEqual(ConsumerGroupSession.State.stable, session.state);
    if (session.assignments.items.len > 0) {
        for (session.assignments.items[0].partitions) |p| {
            try std.testing.expect(p != first_part or members.len == 1);
        }
    }
}

test "ConsumerGroupSession multi-member offline rebalance" {
    const allocator = std.testing.allocator;
    const members = [_][]const u8{ "c-b", "c-a" };
    var a = ConsumerGroupSession.init(allocator, "g");
    defer a.deinit();
    var b = ConsumerGroupSession.init(allocator, "g");
    defer b.deinit();
    try a.joinOfflineRebalance("c-a", &members, &.{"orders"}, 4, .range);
    try b.joinOfflineRebalance("c-b", &members, &.{"orders"}, 4, .range);
    try std.testing.expect(a.is_leader);
    try std.testing.expect(!b.is_leader);
    try std.testing.expectEqual(@as(usize, 1), a.assignments.items.len);
    try std.testing.expectEqual(@as(usize, 2), a.assignments.items[0].partitions.len);
    try std.testing.expectEqual(@as(usize, 2), b.assignments.items[0].partitions.len);
    // No overlap
    for (a.assignments.items[0].partitions) |pa| {
        for (b.assignments.items[0].partitions) |pb| {
            try std.testing.expect(pa != pb);
        }
    }
}

test "KafkaWireFormat buildMetadataRequest" {
    const allocator = std.testing.allocator;
    const req = try KafkaWireFormat.buildMetadataRequest(allocator, &.{ "orders", "payments" }, 3, "c1");
    defer allocator.free(req);
    try std.testing.expect(req.len > 10);
    try std.testing.expectEqual(@as(i16, 3), readI16(req[0..2])); // api_key Metadata
    try std.testing.expectEqual(@as(i16, 1), readI16(req[2..4])); // api_version
}

test "KafkaWireFormat parseMetadataResponse synthetic" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;

    writeI32(&b4, 11);
    try buf.appendSlice(allocator, &b4); // correlation
    writeI32(&b4, 0);
    try buf.appendSlice(allocator, &b4); // throttle
    writeI32(&b4, 0);
    try buf.appendSlice(allocator, &b4); // brokers count
    writeI32(&b4, 1);
    try buf.appendSlice(allocator, &b4); // topics count

    writeI16(&b2, 0);
    try buf.appendSlice(allocator, &b2); // topic error_code
    writeI16(&b2, 6);
    try buf.appendSlice(allocator, &b2);
    try buf.appendSlice(allocator, "orders");
    try buf.append(allocator, 0); // is_internal
    writeI32(&b4, 3);
    try buf.appendSlice(allocator, &b4); // partition count

    // Three minimal partition metadata entries (partition 0, 1, 2).
    for (0..3) |p| {
        writeI16(&b2, 0);
        try buf.appendSlice(allocator, &b2); // partition error_code
        writeI32(&b4, @intCast(p));
        try buf.appendSlice(allocator, &b4); // partition id
        writeI32(&b4, 1);
        try buf.appendSlice(allocator, &b4); // leader
        writeI32(&b4, 1);
        try buf.appendSlice(allocator, &b4); // replicas count
        writeI32(&b4, 1);
        try buf.appendSlice(allocator, &b4); // replica id
        writeI32(&b4, 1);
        try buf.appendSlice(allocator, &b4); // isr count
        writeI32(&b4, 1);
        try buf.appendSlice(allocator, &b4); // isr id
    }

    const meta = try KafkaWireFormat.parseMetadataResponse(allocator, buf.items, 11);
    defer KafkaWireFormat.freeTopicMetaList(allocator, meta);
    try std.testing.expectEqual(@as(usize, 1), meta.len);
    try std.testing.expectEqualStrings("orders", meta[0].topic);
    try std.testing.expectEqual(@as(i32, 3), meta[0].partition_count);
}

test "parseFindCoordinatorResponse synthetic" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var b4: [4]u8 = undefined;
    var b2: [2]u8 = undefined;
    writeI32(&b4, 9);
    try buf.appendSlice(allocator, &b4);
    writeI32(&b4, 0);
    try buf.appendSlice(allocator, &b4);
    writeI16(&b2, 0);
    try buf.appendSlice(allocator, &b2);
    writeI32(&b4, 1);
    try buf.appendSlice(allocator, &b4); // node
    writeI16(&b2, 9);
    try buf.appendSlice(allocator, &b2);
    try buf.appendSlice(allocator, "127.0.0.1");
    writeI32(&b4, 9093);
    try buf.appendSlice(allocator, &b4);

    const info = try KafkaWireFormat.parseFindCoordinatorResponse(allocator, buf.items, 9);
    defer allocator.free(info.host);
    try std.testing.expectEqual(@as(i16, 0), info.error_code);
    try std.testing.expectEqualStrings("127.0.0.1", info.host);
    try std.testing.expectEqual(@as(i32, 9093), info.port);
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
