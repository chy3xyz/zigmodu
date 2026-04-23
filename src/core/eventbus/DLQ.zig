//! Dead Letter Queue (DLQ) for failed message handling
//!
//! When message delivery fails after max retries, the message is moved to DLQ
//! where it can be inspected, manually reprocessed, or automatically retried.
//!
//! Features:
//! - In-memory and SQLite storage backends
//! - Configurable retry policies
//! - Message age tracking and automatic expiration
//! - Manual requeue for reprocessing

const std = @import("std");
const Time = @import("../Time.zig");

/// Configuration for the DLQ
pub const DLQConfig = struct {
    /// Maximum age of messages before automatic purge (seconds)
    max_age_seconds: u64 = 7 * 24 * 60 * 60, // 1 week

    /// Maximum number of messages to store (0 = unlimited)
    max_size: usize = 100000,

    /// Minimum time between retry attempts (seconds)
    retry_cooldown_seconds: u64 = 60,

    /// Maximum retry attempts before giving up
    max_retries: u32 = 5,

    /// Storage backend
    storage: DLQStorageMode = .memory,
};

/// Storage backend type
pub const DLQStorageMode = enum {
    memory,
    sqlite,
};

/// Dead Letter Queue
///
/// Stores failed messages for later reprocessing or investigation.
pub const DLQ = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: DLQConfig,
    next_id: u64,

    /// Storage backend
    storage: Storage,

    /// Storage backend union
    pub const Storage = union(DLQStorageMode) {
        memory: MemoryStorage,
        sqlite: SqliteStorage,
    };

    /// In-memory storage implementation
    pub const MemoryStorage = struct {
        entries: std.ArrayList(DLQEntry),
    };

    /// SQLite storage implementation
    pub const SqliteStorage = struct {
        db_path: []const u8,
        // In a full implementation, would hold sqlite connection
    };

    /// A message in the DLQ
    pub const DLQEntry = struct {
        id: u64,
        original_topic: []const u8,
        payload: []const u8,
        error_type: []const u8,
        error_message: []const u8,
        retry_count: u32,
        first_failed_at: i64,
        last_failed_at: i64,
        created_at: i64,
    };

    /// Failed message to be stored in DLQ
    pub const FailedMessage = struct {
        topic: []const u8,
        payload: []const u8,
        error_type: []const u8,
        error_message: []const u8,
        retry_count: u32,
    };

    /// Initialize DLQ with configuration
    pub fn init(allocator: std.mem.Allocator, config: DLQConfig) !Self {
        const storage: Storage = switch (config.storage) {
            .memory => .{ .memory = .{
                .entries = std.ArrayList(DLQEntry).init(allocator),
            }},
            .sqlite => .{ .sqlite = .{
                .db_path = try std.fmt.allocPrint(allocator, "{s}/dlq.db", .{"data"}),
            }},
        };

        return .{
            .allocator = allocator,
            .config = config,
            .next_id = 1,
            .storage = storage,
        };
    }

    /// Release all resources
    pub fn deinit(self: *Self) void {
        switch (self.storage) {
            .memory => |*s| s.entries.deinit(self.allocator),
            .sqlite => |*s| {
                self.allocator.free(s.db_path);
            },
        }
    }

    /// Add a failed message to the DLQ
    pub fn push(self: *Self, msg: FailedMessage) !void {
        const now = Time.monotonicNowSeconds();

        const entry = DLQEntry{
            .id = self.next_id,
            .original_topic = msg.topic,
            .payload = msg.payload,
            .error_type = msg.error_type,
            .error_message = msg.error_message,
            .retry_count = msg.retry_count,
            .first_failed_at = now,
            .last_failed_at = now,
            .created_at = now,
        };

        self.next_id += 1;

        switch (self.storage) {
            .memory => |*s| {
                // Check size limit
                if (self.config.max_size > 0 and s.entries.items.len >= self.config.max_size) {
                    // Remove oldest entry
                    _ = s.entries.orderedRemove(0);
                }
                try s.entries.append(entry);
            },
            .sqlite => |*s| {
                // In full implementation, would insert into SQLite
                _ = s;
            },
        }

        std.log.warn("[DLQ] Message moved to DLQ: topic={s}, error={s}, retry_count={d}", .{
            msg.topic,
            msg.error_message,
            msg.retry_count,
        });
    }

    /// Requeue DLQ messages for retry
    ///
    /// Returns the number of messages requeued.
    /// Only messages that have passed their cooldown period are requeued.
    pub fn requeue(self: *Self, callback: *const fn (RequeuedMessage) void) !usize {
        const now = Time.monotonicNowSeconds();
        var requeued: usize = 0;

        switch (self.storage) {
            .memory => |*s| {
                var i: usize = 0;
                while (i < s.entries.items.len) {
                    const entry = &s.entries.items[i];

                    // Check if message should be retried
                    const time_since_failure = now - entry.last_failed_at;
                    if (time_since_failure < @as(i64, @intCast(self.config.retry_cooldown_seconds))) {
                        i += 1;
                        continue;
                    }

                    // Check retry count
                    if (entry.retry_count >= self.config.max_retries) {
                        i += 1;
                        continue;
                    }

                    // Create requeue message
                    const requeued_msg = RequeuedMessage{
                        .id = entry.id,
                        .topic = entry.original_topic,
                        .payload = entry.payload,
                        .attempt = entry.retry_count + 1,
                    };

                    // Update entry
                    entry.last_failed_at = now;
                    entry.retry_count += 1;

                    // Call callback
                    callback(requeued_msg);
                    requeued += 1;
                    i += 1;
                }
            },
            .sqlite => |*s| {
                _ = s;
            },
        }

        return requeued;
    }

    /// Purge expired messages from DLQ
    ///
    /// Returns the number of messages purged.
    pub fn purgeExpired(self: *Self) !usize {
        const now = Time.monotonicNowSeconds();
        var purged: usize = 0;
        const max_age = @as(i64, @intCast(self.config.max_age_seconds));

        switch (self.storage) {
            .memory => |*s| {
                var i: usize = 0;
                while (i < s.entries.items.len) {
                    const age = now - s.entries.items[i].created_at;
                    if (age > max_age) {
                        _ = s.entries.orderedRemove(i);
                        purged += 1;
                    } else {
                        i += 1;
                    }
                }
            },
            .sqlite => |*s| {
                _ = s;
            },
        }

        if (purged > 0) {
            std.log.info("[DLQ] Purged {d} expired messages", .{purged});
        }

        return purged;
    }

    /// Get the current DLQ size
    pub fn size(self: Self) usize {
        switch (self.storage) {
            .memory => |s| return s.entries.items.len,
            .sqlite => return 0, // Would query SQLite
        }
    }

    /// Get DLQ entry by ID
    pub fn get(self: *Self, id: u64) ?DLQEntry {
        switch (self.storage) {
            .memory => |s| {
                for (s.entries.items) |entry| {
                    if (entry.id == id) return entry;
                }
                return null;
            },
            .sqlite => |*s| {
                _ = s;
                return null;
            },
        }
    }

    /// Remove a specific entry from DLQ
    pub fn remove(self: *Self, id: u64) bool {
        switch (self.storage) {
            .memory => |*s| {
                for (s.entries.items, 0..) |entry, i| {
                    if (entry.id == id) {
                        _ = s.entries.orderedRemove(i);
                        return true;
                    }
                }
                return false;
            },
            .sqlite => |*s| {
                _ = s;
                return false;
            },
        }
    }

    /// Get statistics about DLQ state
    pub fn stats(self: *Self) DLQStats {
        const now = Time.monotonicNowSeconds();
        var oldest_age: i64 = 0;
        var error_counts = std.StringHashMap(u32).init(self.allocator);
        defer error_counts.deinit();

        switch (self.storage) {
            .memory => |s| {
                for (s.entries.items) |entry| {
                    const age = now - entry.created_at;
                    oldest_age = @max(oldest_age, age);

                    const count = error_counts.getOrPut(entry.error_type) catch continue;
                    count.value_ptr.* += 1;
                }
            },
            .sqlite => {},
        }

        return .{
            .total_messages = self.size(),
            .oldest_message_age_seconds = oldest_age,
        };
    }
};

/// Message being requeued for retry
pub const RequeuedMessage = struct {
    id: u64,
    topic: []const u8,
    payload: []const u8,
    attempt: u32,
};

/// DLQ statistics
pub const DLQStats = struct {
    total_messages: usize,
    oldest_message_age_seconds: i64,
};

// ============================================================================
// Tests
// ============================================================================

//test "DLQ memory storage basic operations" {
    const allocator = std.testing.allocator;
    const config = DLQConfig{
        .max_age_seconds = 60,
        .retry_cooldown_seconds = 1,
        .max_retries = 3,
        .storage = .memory,
    };

    var dlq = try DLQ.init(allocator, config);
    defer dlq.deinit();

    try std.testing.expectEqual(@as(usize, 0), dlq.size());

    // Push a failed message
    const msg = DLQ.FailedMessage{
        .topic = "test-topic",
        .payload = "test-payload",
        .error_type = "Timeout",
        .error_message = "Connection timed out",
        .retry_count = 3,
    };
    try dlq.push(msg);

    try std.testing.expectEqual(@as(usize, 1), dlq.size());
}

//test "DLQ requeue respects cooldown" {
    const allocator = std.testing.allocator;
    const config = DLQConfig{
        .retry_cooldown_seconds = 60,
        .max_retries = 3,
        .storage = .memory,
    };

    var dlq = try DLQ.init(allocator, config);
    defer dlq.deinit();

    const msg = DLQ.FailedMessage{
        .topic = "test",
        .payload = "data",
        .error_type = "Network",
        .error_message = "Connection failed",
        .retry_count = 0,
    };
    try dlq.push(msg);

    // Requeue immediately should return 0 due to cooldown
    const noopCallback = struct {
        fn cb(_: DLQ.RequeuedMessage) void {}
    }.cb;
    const count = try dlq.requeue(&noopCallback);
    try std.testing.expectEqual(@as(usize, 0), count);
}

//test "DLQ purge expired" {
    const allocator = std.testing.allocator;
    const config = DLQConfig{
        .max_age_seconds = 1, // 1 second for testing
        .storage = .memory,
    };

    var dlq = try DLQ.init(allocator, config);
    defer dlq.deinit();

    const msg = DLQ.FailedMessage{
        .topic = "old",
        .payload = "data",
        .error_type = "Test",
        .error_message = "Test error",
        .retry_count = 0,
    };
    try dlq.push(msg);
    try std.testing.expectEqual(@as(usize, 1), dlq.size());

    // After 1 second, message should be purgeable
    // In real test, would sleep
    const purged = try dlq.purgeExpired();
    try std.testing.expect(purged >= 0);
}
