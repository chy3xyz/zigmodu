//! Fluvio streaming platform connector.
//!
//! Interfaces with Fluvio via the `fluvio` CLI binary.
//! Falls back to a log-based stub when the CLI is unavailable.
//!
//! Fluvio produces key-value records to topics; this connector wraps
//! produce, consume, and topic management operations.

const std = @import("std");
const builtin = @import("builtin");
const Time = @import("../core/Time.zig");

pub const Record = struct {
    key: []const u8,
    value: []const u8,
    offset: i64,
    timestamp: i64,
};

pub const FluvioConfig = struct {
    /// Fluvio cluster URL (for HTTP fallback / profile selection)
    url: ?[]const u8 = null,
    /// Fluvio profile name to use with `fluvio profile`
    profile: ?[]const u8 = null,
    /// Timeout for CLI operations in milliseconds (not enforced)
    timeout_ms: u64 = 10_000,
};

pub const FluvioConnector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    config: FluvioConfig,
    cli_available: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: FluvioConfig) !Self {
        var self = Self{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
        self.cli_available = detectFluvioCli(allocator, io);
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.* = undefined;
    }

    /// Check whether the fluvio CLI is available.
    pub fn isAvailable(self: *const Self) bool {
        return self.cli_available;
    }

    /// Produce a record to a topic. Format: key \t value per line.
    pub fn produce(self: *Self, topic: []const u8, key: []const u8, value: []const u8) !void {
        if (!self.cli_available) {
            return self.stubProduce(topic, key, value);
        }

        // Use shell pipe: echo "key\tvalue" | fluvio produce <topic>
        const shell_cmd = try std.fmt.allocPrint(self.allocator, "echo \"{s}\\t{s}\" | fluvio produce {s}", .{ key, value, topic });
        defer self.allocator.free(shell_cmd);

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "sh", "-c", shell_cmd },
        });
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        if (!result.term.success()) {
            std.log.err("[Fluvio] produce failed: {s}", .{result.stderr});
            return error.FluvioError;
        }
    }

    /// Consume records from a topic starting at the given offset.
    /// Uses `fluvio consume <topic> -B -o <offset>` (from-beginning + offset).
    /// Caller owns returned memory.
    pub fn consume(self: *Self, topic: []const u8, offset: i64) ![]Record {
        if (!self.cli_available) {
            return self.stubConsume(offset);
        }

        var offset_buf: [32]u8 = undefined;
        const offset_str = try std.fmt.bufPrint(&offset_buf, "{d}", .{offset});

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "fluvio", "consume", topic, "-B", "-o", offset_str },
        });
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        if (!result.term.success()) {
            std.log.err("[Fluvio] consume failed: {s}", .{result.stderr});
            return error.FluvioError;
        }

        return parseConsumeOutput(self.allocator, result.stdout);
    }

    /// List all topics.
    /// Caller owns returned memory.
    pub fn listTopics(self: *Self) ![]const []const u8 {
        if (!self.cli_available) {
            return self.stubListTopics();
        }

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "fluvio", "topic", "list" },
        });
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        if (!result.term.success()) {
            std.log.err("[Fluvio] listTopics failed: {s}", .{result.stderr});
            return error.FluvioError;
        }

        return parseTopicList(self.allocator, result.stdout);
    }

    /// Create a new topic with the given number of partitions.
    pub fn createTopic(self: *Self, name: []const u8, partitions: u16) !void {
        if (!self.cli_available) {
            return self.stubCreateTopic(name, partitions);
        }

        var part_buf: [16]u8 = undefined;
        const part_str = try std.fmt.bufPrint(&part_buf, "{d}", .{partitions});

        const result = try std.process.run(self.allocator, self.io, .{
            .argv = &.{ "fluvio", "topic", "create", name, "-p", part_str },
        });
        defer {
            self.allocator.free(result.stdout);
            self.allocator.free(result.stderr);
        }

        if (!result.term.success()) {
            std.log.err("[Fluvio] createTopic failed: {s}", .{result.stderr});
            return error.FluvioError;
        }
    }

    // ── Stub implementations (log-based, no-op) ──

    fn stubProduce(self: *Self, topic: []const u8, key: []const u8, value: []const u8) !void {
        _ = self;
        std.log.info("[Fluvio-stub] produce topic={s} key={s} value={s}", .{ topic, key, value });
    }

    fn stubConsume(self: *Self, offset: i64) ![]Record {
        _ = offset;
        return try self.allocator.alloc(Record, 0);
    }

    fn stubListTopics(self: *Self) ![]const []const u8 {
        return try self.allocator.alloc([]const u8, 0);
    }

    fn stubCreateTopic(self: *Self, name: []const u8, partitions: u16) !void {
        _ = self;
        std.log.info("[Fluvio-stub] create topic={s} partitions={d}", .{ name, partitions });
    }

    fn detectFluvioCli(allocator: std.mem.Allocator, io: std.Io) bool {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "which", "fluvio" },
        }) catch return false;
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }
        return result.term.success() and result.stdout.len > 0;
    }
};

// ── CLI output parsers ──

/// Parse `fluvio consume` output into Record slices.
/// Expected format: lines like `key\tvalue` or `[timestamp] key\tvalue`.
fn parseConsumeOutput(allocator: std.mem.Allocator, stdout: []const u8) ![]Record {
    var records = std.ArrayList(Record).empty;
    errdefer {
        for (records.items) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        records.deinit(allocator);
    }

    var offset_counter: i64 = 0;

    var line_iter = std.mem.splitScalar(u8, stdout, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;

        // Try to parse "[timestamp] key\tvalue" or just "key\tvalue"
        var key: []const u8 = undefined;
        var value: []const u8 = undefined;
        var timestamp: i64 = Time.monotonicNowMilliseconds();

        if (line[0] == '[') {
            // [timestamp] rest
            const bracket_end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const ts_str = line[1..bracket_end];
            timestamp = std.fmt.parseInt(i64, ts_str, 10) catch timestamp;
            const rest = std.mem.trim(u8, line[bracket_end + 1 ..], " \t");
            if (std.mem.indexOfScalar(u8, rest, '\t')) |tab_idx| {
                key = rest[0..tab_idx];
                value = rest[tab_idx + 1 ..];
            } else {
                key = rest;
                value = "";
            }
        } else {
            if (std.mem.indexOfScalar(u8, line, '\t')) |tab_idx| {
                key = line[0..tab_idx];
                value = line[tab_idx + 1 ..];
            } else {
                key = "";
                value = line;
            }
        }

        try records.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
            .offset = offset_counter,
            .timestamp = timestamp,
        });
        offset_counter += 1;
    }

    return try records.toOwnedSlice(allocator);
}

/// Parse `fluvio topic list` output into topic name slices.
fn parseTopicList(allocator: std.mem.Allocator, stdout: []const u8) ![]const []const u8 {
    var topics = std.ArrayList([]const u8).empty;
    errdefer {
        for (topics.items) |t| allocator.free(t);
        topics.deinit(allocator);
    }

    var line_iter = std.mem.splitScalar(u8, stdout, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        // Skip header lines
        if (std.mem.startsWith(u8, line, "NAME")) continue;

        // First whitespace-delimited token is the topic name
        const name_end = std.mem.indexOfAnyPos(u8, line, 0, " \t") orelse line.len;
        const name = line[0..name_end];
        if (name.len > 0) {
            try topics.append(allocator, try allocator.dupe(u8, name));
        }
    }

    return try topics.toOwnedSlice(allocator);
}

// ── Tests ──

test "FluvioConnector init and deinit" {
    const allocator = std.testing.allocator;
    var connector = try FluvioConnector.init(allocator, std.testing.io, .{});
    defer connector.deinit();
    // Availability depends on whether fluvio CLI is installed
    _ = connector.isAvailable();
}

test "FluvioConnector stub produce and consume" {
    const allocator = std.testing.allocator;
    var connector = try FluvioConnector.init(allocator, std.testing.io, .{});
    defer connector.deinit();

    // Stub operations should always work
    try connector.stubProduce("test-topic", "key1", "value1");
    const records = try connector.stubConsume(0);
    defer allocator.free(records);
    try std.testing.expectEqual(@as(usize, 0), records.len);

    const topics = try connector.stubListTopics();
    defer allocator.free(topics);
    try std.testing.expectEqual(@as(usize, 0), topics.len);

    try connector.stubCreateTopic("new-topic", 3);
}

test "FluvioConnector list topics" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fluvio_url = if (std.c.getenv("FLUVIO_URL")) |ptr| std.mem.span(ptr) else null;
    if (fluvio_url == null or fluvio_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var connector = try FluvioConnector.init(allocator, std.testing.io, .{});
    defer connector.deinit();

    if (!connector.isAvailable()) return error.SkipZigTest;

    const topics = try connector.listTopics();
    defer {
        for (topics) |t| allocator.free(t);
        allocator.free(topics);
    }
}

test "FluvioConnector produce and consume" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fluvio_url = if (std.c.getenv("FLUVIO_URL")) |ptr| std.mem.span(ptr) else null;
    if (fluvio_url == null or fluvio_url.?.len == 0) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var connector = try FluvioConnector.init(allocator, std.testing.io, .{});
    defer connector.deinit();

    if (!connector.isAvailable()) return error.SkipZigTest;

    const test_topic = "zigmodu-test";

    // Create topic (ignore if already exists)
    connector.createTopic(test_topic, 1) catch {};

    // Produce a record
    try connector.produce(test_topic, "hello", "world");

    // Consume from offset 0
    const records = try connector.consume(test_topic, 0);
    defer {
        for (records) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(records);
    }

    // At minimum, our produced record should be there
    try std.testing.expect(records.len >= 1);
}

test "parseConsumeOutput - basic" {
    const allocator = std.testing.allocator;
    const output = "key1\tvalue1\nkey2\tvalue2\n";
    const records = try parseConsumeOutput(allocator, output);
    defer {
        for (records) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(records);
    }
    try std.testing.expectEqual(@as(usize, 2), records.len);
    try std.testing.expectEqualStrings("key1", records[0].key);
    try std.testing.expectEqualStrings("value1", records[0].value);
    try std.testing.expectEqualStrings("key2", records[1].key);
    try std.testing.expectEqualStrings("value2", records[1].value);
}

test "parseConsumeOutput - with timestamps" {
    const allocator = std.testing.allocator;
    const output = "[1234567890] key1\tvalue1\n";
    const records = try parseConsumeOutput(allocator, output);
    defer {
        for (records) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(records);
    }
    try std.testing.expectEqual(@as(usize, 1), records.len);
    try std.testing.expectEqualStrings("key1", records[0].key);
    try std.testing.expectEqualStrings("value1", records[0].value);
    try std.testing.expectEqual(@as(i64, 1234567890), records[0].timestamp);
}

test "parseTopicList - basic" {
    const allocator = std.testing.allocator;
    const output = "my-topic\nother-topic\n";
    const topics = try parseTopicList(allocator, output);
    defer {
        for (topics) |t| allocator.free(t);
        allocator.free(topics);
    }
    try std.testing.expectEqual(@as(usize, 2), topics.len);
    try std.testing.expectEqualStrings("my-topic", topics[0]);
    try std.testing.expectEqualStrings("other-topic", topics[1]);
}

test "FluvioConnector parse empty consume" {
    const allocator = std.testing.allocator;
    const records = try parseConsumeOutput(allocator, "");
    defer {
        for (records) |r| {
            allocator.free(r.key);
            allocator.free(r.value);
        }
        allocator.free(records);
    }
    try std.testing.expectEqual(@as(usize, 0), records.len);
}
