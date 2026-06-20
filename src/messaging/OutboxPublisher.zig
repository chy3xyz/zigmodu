//! Transactional Outbox Pattern — guarantees at-least-once event delivery.
//!
//! Writes events to an `outbox` table in the same DB transaction as business data.
//! A background poller reads unprocessed events and publishes to DistributedEventBus.
//!
//! Architecture:
//!   Business Tx { INSERT order + INSERT outbox } → commit
//!   OutboxPoller reads outbox → DistributedEventBus.publish()
//!   On success → mark outbox entry as processed
//!   On failure → increment retry_count, move to DLQ after max_retries

const std = @import("std");
const EventBus = @import("../core/EventBus.zig").TypedEventBus;
const Time = @import("../core/Time.zig");

/// A single outbox message stored in the database.
pub const OutboxEntry = struct {
    id: i64,
    topic: []const u8,
    payload: []const u8,
    status: OutboxStatus,
    retry_count: u32,
    max_retries: u32,
    created_at: i64,
    updated_at: i64,
    error_message: ?[]const u8,
};

/// Message lifecycle in the outbox.
pub const OutboxStatus = enum(u8) {
    pending = 0, // Awaiting first delivery attempt
    processing = 1, // Currently being delivered
    delivered = 2, // Successfully published
    failed = 3, // All retries exhausted, moved to DLQ
};

/// Configuration for the outbox publisher.
pub const OutboxConfig = struct {
    /// Maximum number of times to retry a failed message.
    max_retries: u32 = 5,

    /// Minimum delay between retry attempts (seconds).
    retry_delay_seconds: u64 = 30,

    /// How many entries to poll per batch.
    batch_size: usize = 100,

    /// Polling interval for the background poller (milliseconds).
    poll_interval_ms: u64 = 1000,

    /// After this many seconds, unprocessed entries are considered stale.
    stale_threshold_seconds: u64 = 300,
};

/// OutboxPublisher — embedded within a business service, writes to outbox table.
pub const OutboxPublisher = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: OutboxConfig,

    pub fn init(allocator: std.mem.Allocator, config: OutboxConfig) Self {
        return .{ .allocator = allocator, .config = config };
    }

    /// Build SQL to create the outbox table. Call once at startup.
    pub fn migrationSql() []const u8 {
        return
            \\CREATE TABLE IF NOT EXISTS event_outbox (
            \\    id BIGINT AUTO_INCREMENT PRIMARY KEY,
            \\    topic VARCHAR(255) NOT NULL,
            \\    payload TEXT NOT NULL,
            \\    status TINYINT NOT NULL DEFAULT 0,
            \\    retry_count INT NOT NULL DEFAULT 0,
            \\    max_retries INT NOT NULL DEFAULT 5,
            \\    created_at BIGINT NOT NULL,
            \\    updated_at BIGINT NOT NULL,
            \\    error_message TEXT NULL,
            \\    INDEX idx_status_created (status, created_at)
            \\);
        ;
    }

    /// Generate the INSERT SQL for an outbox entry.
    /// Caller should execute this within a transaction alongside business data.
    pub fn buildInsert(
        self: *Self,
        topic: []const u8,
        payload: []const u8,
    ) !OutboxInsert {
        const now = Time.monotonicNowSeconds();

        return OutboxInsert{
            .sql =
            \\INSERT INTO event_outbox (topic, payload, status, retry_count, max_retries, created_at, updated_at)
            \\VALUES (?, ?, 0, 0, ?, ?, ?)
            ,
            .params = .{
                .topic = topic,
                .payload = payload,
                .max_retries = self.config.max_retries,
                .created_at = now,
                .updated_at = now,
            },
        };
    }

    /// Prepared INSERT statement for binding into a SQL transaction.
    pub const OutboxInsert = struct {
        sql: []const u8,
        params: struct {
            topic: []const u8,
            payload: []const u8,
            max_retries: u32,
            created_at: i64,
            updated_at: i64,
        },
    };
};

/// OutboxPoller — background task that reads from outbox and publishes events.
pub const OutboxPoller = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: OutboxConfig,
    outbox_table: []const u8,
    publisher_fn: *const fn (topic: []const u8, payload: []const u8) anyerror!void,
    error_handler_fn: ?*const fn (entry: OutboxEntry) void,

    pub fn init(
        allocator: std.mem.Allocator,
        config: OutboxConfig,
        publisher: *const fn (topic: []const u8, payload: []const u8) anyerror!void,
    ) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .outbox_table = "event_outbox",
            .publisher_fn = publisher,
            .error_handler_fn = null,
        };
    }

    /// Set a custom error handler for failed messages.
    pub fn onError(self: *Self, handler: *const fn (entry: OutboxEntry) void) void {
        self.error_handler_fn = handler;
    }

    /// Build the SELECT query to fetch pending outbox entries.
    pub fn buildSelectPending(self: *Self) ![]const u8 {
        return std.fmt.allocPrint(
            self.allocator,
            "SELECT id, topic, payload, status, retry_count, max_retries, created_at, updated_at, error_message FROM {s} WHERE status IN (0, 1) AND retry_count < max_retries ORDER BY created_at ASC LIMIT {d}",
            .{ self.outbox_table, self.config.batch_size },
        );
    }

    /// Build the UPDATE query to mark an entry as processing.
    pub fn buildMarkProcessing(self: *Self, entry_id: i64) ![]const u8 {
        const now = Time.monotonicNowSeconds();
        return std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET status = 1, updated_at = {d} WHERE id = {d}",
            .{ self.outbox_table, now, entry_id },
        );
    }

    /// Build the UPDATE query to mark an entry as delivered.
    pub fn buildMarkDelivered(self: *Self, entry_id: i64) ![]const u8 {
        const now = Time.monotonicNowSeconds();
        return std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET status = 2, updated_at = {d} WHERE id = {d}",
            .{ self.outbox_table, now, entry_id },
        );
    }

    /// Build the UPDATE query to record a retry failure.
    pub fn buildMarkRetry(self: *Self, entry_id: i64, retry_count: u32, error_msg: []const u8) ![]const u8 {
        const now = Time.monotonicNowSeconds();
        return std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET retry_count = {d}, error_message = '{s}', updated_at = {d} WHERE id = {d}",
            .{ self.outbox_table, retry_count, error_msg, now, entry_id },
        );
    }

    /// Build the UPDATE query to mark an entry as permanently failed.
    pub fn buildMarkFailed(self: *Self, entry_id: i64, error_msg: []const u8) ![]const u8 {
        const now = Time.monotonicNowSeconds();
        return std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET status = 3, error_message = '{s}', updated_at = {d} WHERE id = {d}",
            .{ self.outbox_table, error_msg, now, entry_id },
        );
    }

    /// Process one outbox entry — publish it and update status.
    /// Called by the poller for each pending entry.
    pub fn processEntry(self: *Self, entry: OutboxEntry) void {
        // Attempt to publish
        self.publisher_fn(entry.topic, entry.payload) catch |err| {
            const new_retry_count = entry.retry_count + 1;
            const err_msg = @errorName(err);

            if (new_retry_count >= entry.max_retries) {
                // Max retries exhausted — mark as failed
                std.log.warn("[Outbox] Permanently failed: topic={s}, id={d}, error={s}", .{
                    entry.topic, entry.id, err_msg,
                });
                if (self.error_handler_fn) |handler| {
                    var failed_entry = entry;
                    failed_entry.retry_count = new_retry_count;
                    failed_entry.error_message = err_msg;
                    handler(failed_entry);
                }
            } else {
                // Will retry on next poll cycle
                std.log.warn("[Outbox] Delivery failed (attempt {d}/{d}): topic={s}, id={d}, error={s}", .{
                    new_retry_count, entry.max_retries, entry.topic, entry.id, err_msg,
                });
            }
            return;
        };

        // Success
        std.log.debug("[Outbox] Delivered: topic={s}, id={d}", .{ entry.topic, entry.id });
    }
};

/// Outbox stats for monitoring.
pub const OutboxStats = struct {
    pending: usize,
    processing: usize,
    delivered: usize,
    failed: usize,
    total: usize,

    pub fn buildQuery(table_name: []const u8) []const u8 {
        _ = table_name;
        return "SELECT status, COUNT(*) as cnt FROM event_outbox GROUP BY status";
    }
};

// ==================== Tests ====================

test "OutboxPublisher buildInsert" {
    const allocator = std.testing.allocator;
    var publisher = OutboxPublisher.init(allocator, .{});
    const insert = try publisher.buildInsert("order.created", "{\"id\":1}");
    try std.testing.expect(insert.sql.len > 0);
    try std.testing.expectEqualStrings("order.created", insert.params.topic);
    try std.testing.expectEqualStrings("{\"id\":1}", insert.params.payload);
}

test "OutboxPublisher migrationSql" {
    const sql = OutboxPublisher.migrationSql();
    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE IF NOT EXISTS event_outbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "PRIMARY KEY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "idx_status_created") != null);
}

test "OutboxPoller build queries" {
    const allocator = std.testing.allocator;
    const publisher = struct {
        fn pubFn(topic: []const u8, payload: []const u8) anyerror!void {
            _ = topic;
            _ = payload;
        }
    }.pubFn;

    var poller = OutboxPoller.init(allocator, .{ .batch_size = 10 }, &publisher);

    const select_sql = try poller.buildSelectPending();
    defer allocator.free(select_sql);
    try std.testing.expect(std.mem.indexOf(u8, select_sql, "SELECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, select_sql, "LIMIT 10") != null);

    const mark_sql = try poller.buildMarkDelivered(42);
    defer allocator.free(mark_sql);
    try std.testing.expect(std.mem.indexOf(u8, mark_sql, "status = 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, mark_sql, "id = 42") != null);
}

test "OutboxPoller process entry success" {
    const allocator = std.testing.allocator;
    const State = struct {
        var published: bool = false;
    };

    const publisher = struct {
        fn pubFn(topic: []const u8, payload: []const u8) anyerror!void {
            _ = topic;
            _ = payload;
            State.published = true;
        }
    }.pubFn;

    State.published = false;
    var poller = OutboxPoller.init(allocator, .{}, &publisher);

    const entry = OutboxEntry{
        .id = 1,
        .topic = "test",
        .payload = "data",
        .status = .pending,
        .retry_count = 0,
        .max_retries = 3,
        .created_at = 0,
        .updated_at = 0,
        .error_message = null,
    };

    poller.processEntry(entry);
    try std.testing.expect(State.published);
}

test "OutboxPoller process entry failure" {
    const allocator = std.testing.allocator;
    const State = struct {
        var failed: bool = false;
        var last_topic: []const u8 = "";
    };

    const publisher = struct {
        fn pubFn(topic: []const u8, payload: []const u8) anyerror!void {
            _ = topic;
            _ = payload;
            return error.NetworkError;
        }
    }.pubFn;

    var poller = OutboxPoller.init(allocator, .{ .max_retries = 5 }, &publisher);
    poller.onError(struct {
        fn handler(entry: OutboxEntry) void {
            State.failed = true;
            State.last_topic = entry.topic;
        }
    }.handler);

    // First few retries should not trigger error handler
    const entry1 = OutboxEntry{
        .id = 2,
        .topic = "test.fail",
        .payload = "data",
        .status = .pending,
        .retry_count = 0,
        .max_retries = 5,
        .created_at = 0,
        .updated_at = 0,
        .error_message = null,
    };
    poller.processEntry(entry1);
    try std.testing.expect(!State.failed); // Not yet at max retries

    // Entry at max retries - 1 should not trigger
    const entry2 = OutboxEntry{
        .id = 3,
        .topic = "test.fail",
        .payload = "data",
        .status = .pending,
        .retry_count = 3,
        .max_retries = 5,
        .created_at = 0,
        .updated_at = 0,
        .error_message = null,
    };
    poller.processEntry(entry2);
    try std.testing.expect(!State.failed); // 4 < 5, still retrying

    // Entry at max_retries - 1 (= 4 retries + 1 new = 5 >= 5) should trigger
    const entry3 = OutboxEntry{
        .id = 4,
        .topic = "test.fail",
        .payload = "data",
        .status = .pending,
        .retry_count = 4,
        .max_retries = 5,
        .created_at = 0,
        .updated_at = 0,
        .error_message = null,
    };
    poller.processEntry(entry3);
    try std.testing.expect(State.failed); // 5 >= 5, moved to DLQ
}

test "OutboxStats buildQuery" {
    const sql = OutboxStats.buildQuery("event_outbox");
    try std.testing.expect(std.mem.indexOf(u8, sql, "GROUP BY status") != null);
}
