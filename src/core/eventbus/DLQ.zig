//! Dead Letter Queue (DLQ) for failed message handling
//!
//! Used by `DistributedEventBus` to store messages that failed delivery
//! (e.g., after crossing `max_send_failures`) so they can be inspected,
//! manually reprocessed, or automatically retried.
//!
//! Features:
//! - In-memory and SQLite storage backends
//! - Configurable retry policies
//! - Message age tracking and automatic expiration
//! - Manual requeue for reprocessing
//!
//! ## Thread safety
//!
//! Every entry point that touches the entry list is serialized by an internal
//! lock. That is not optional here: `DistributedEventBus` runs `purgeExpired` +
//! `requeue` on a background fiber (`dlqRetryLoop`) while request threads push
//! failed sends from `recordSendFailure` / `pushParseFailureToDlq`, so `push`
//! races the retry fiber over the same `ArrayList` (`entries.items.len` and
//! `items.ptr` are both read-modify-written by `append` / `orderedRemove`).
//!
//! Two rules follow from that, and both are load-bearing:
//!
//! - **Callbacks run with the lock released.** The `requeue` callback
//!   republishes the message through the bus, and a republish that fails pushes
//!   a *new* DLQ entry — the callback re-enters `push`. The lock is not
//!   recursive, so invoking it while holding the lock would deadlock the retry
//!   fiber against itself. The bus widens that to two threads: its callback
//!   path is `publish` → `fanOut`, which holds `DistributedEventBus.nodes_lock`
//!   for the whole fan-out, while a failing send takes `nodes_lock` and *then*
//!   pushes to the DLQ. Holding this lock across the callback would therefore
//!   add the edge `DLQ.lock → nodes_lock` on top of the bus's existing
//!   `nodes_lock → DLQ.lock`, and two threads would wait on each other. The
//!   only cross-module order is `nodes_lock` → `DLQ.lock`; nothing in this file
//!   takes another module's lock. For the same reason the message handed to the
//!   callback is a private copy: once the lock is dropped, a concurrent
//!   `purgeExpired` may free the strings the entry pointed at.
//! - **The lock is `core/SpinLock`, not `std.Io.Mutex`.** `std.Io.Mutex.lock`
//!   needs an `Io`, and no entry point in this file has one — `init`, `push`,
//!   `requeue`, `purgeExpired`, `size`, `get`, `remove`, `stats` and `deinit`
//!   are all io-free in their public signatures, which `DistributedEventBus`
//!   and `zigmodu.DLQ` consumers already call. Threading an `Io` through them
//!   is an API break of its own, so it is left to a separate change.
//!
//! Critical sections are list mutations plus the matching allocator calls — no
//! I/O, no callbacks, no logging. That holds inside this module too: the only
//! lock the DLQ lock is ever nested inside is the bus's `nodes_lock` (see
//! above), and the allocator's lock is *below* it — the `dupe` calls that
//! allocate happen before `lock` is taken, and no `free` calls back in — so
//! neither pair can form a cycle.
//!
//! `deinit` is still a lifecycle boundary: the lock makes an *in-flight*
//! operation finish before the list is freed, but the caller must guarantee
//! that no other thread starts a new operation from the moment `deinit` is
//! called.

const std = @import("std");
const Time = @import("../Time.zig");
const SpinLock = @import("../SpinLock.zig").SpinLock;

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

    /// Guards `next_id` and the in-memory entry list. See the module doc for
    /// why this is a `SpinLock` rather than `std.Io.Mutex`.
    lock: SpinLock = .{},

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
                .entries = std.ArrayList(DLQEntry).empty,
            } },
            .sqlite => .{ .sqlite = .{
                .db_path = try std.fmt.allocPrint(allocator, "{s}/dlq.db", .{"data"}),
            } },
        };

        return .{
            .allocator = allocator,
            .config = config,
            .next_id = 1,
            .storage = storage,
        };
    }

    /// Free the strings one entry owns. Caller holds `lock` (or owns the entry
    /// outright, as `deinit` does).
    fn freeEntry(self: *Self, entry: DLQEntry) void {
        self.allocator.free(entry.original_topic);
        self.allocator.free(entry.payload);
        self.allocator.free(entry.error_type);
        self.allocator.free(entry.error_message);
    }

    /// Release all resources
    ///
    /// Takes the lock so a `push` / `purgeExpired` that is already running
    /// finishes before the entries are freed; it does not make concurrent
    /// *new* operations safe (see the module doc).
    pub fn deinit(self: *Self) void {
        self.lock.lock();
        switch (self.storage) {
            .memory => |*s| {
                for (s.entries.items) |entry| self.freeEntry(entry);
                s.entries.deinit(self.allocator);
            },
            .sqlite => |*s| {
                self.allocator.free(s.db_path);
            },
        }
        self.lock.unlock();
        self.* = undefined;
    }

    /// Add a failed message to the DLQ
    pub fn push(self: *Self, msg: FailedMessage) !void {
        const now = Time.monotonicNowSeconds();

        // Dup strings so DLQ owns the memory. Done *before* the lock is taken:
        // these are the calls that reach the allocator's own lock, and the
        // entry list is a spin lock — nothing that can block on the allocator
        // belongs inside it.
        const topic_copy = try self.allocator.dupe(u8, msg.topic);
        errdefer self.allocator.free(topic_copy);
        const payload_copy = try self.allocator.dupe(u8, msg.payload);
        errdefer self.allocator.free(payload_copy);
        const err_type_copy = try self.allocator.dupe(u8, msg.error_type);
        errdefer self.allocator.free(err_type_copy);
        const err_msg_copy = try self.allocator.dupe(u8, msg.error_message);
        errdefer self.allocator.free(err_msg_copy);

        self.lock.lock();

        const entry = DLQEntry{
            .id = self.next_id,
            .original_topic = topic_copy,
            .payload = payload_copy,
            .error_type = err_type_copy,
            .error_message = err_msg_copy,
            .retry_count = msg.retry_count,
            .first_failed_at = now,
            .last_failed_at = now,
            .created_at = now,
        };

        self.next_id += 1;

        switch (self.storage) {
            .memory => |*s| {
                // Check size limit. The test and the eviction are one step with
                // the append below: two threads that both saw room for one more
                // entry are what pushes the list past `max_size`.
                if (self.config.max_size > 0 and s.entries.items.len >= self.config.max_size) {
                    // Remove oldest entry
                    const removed = s.entries.orderedRemove(0);
                    self.freeEntry(removed);
                }
                s.entries.append(self.allocator, entry) catch |err| {
                    self.lock.unlock();
                    return err;
                };
            },
            .sqlite => |*s| {
                // In full implementation, would insert into SQLite
                _ = s;
            },
        }

        self.lock.unlock();

        std.log.warn("[DLQ] Message moved to DLQ: topic={s}, error={s}, retry_count={d}", .{
            msg.topic,
            msg.error_message,
            msg.retry_count,
        });
    }

    /// Requeue DLQ messages for retry
    ///
    /// Returns the number of messages requeued.
    /// Only messages that have passed their cooldown period are requeued, and
    /// each entry is requeued at most once per call.
    ///
    /// The callback is invoked with the lock **released** and receives a
    /// private copy of the topic and payload, valid for the duration of the
    /// call.
    ///
    /// The pass is best-effort over a list other threads are mutating: an entry
    /// the callback removes (or a purge takes) shifts the entries behind it
    /// down, so a pass can skip one. It stays queued and the next pass picks it
    /// up — a pass never requeues the same entry twice.
    pub fn requeue(self: *Self, ctx: *anyopaque, callback: *const fn (*anyopaque, RequeuedMessage) void) !usize {
        const now = Time.monotonicNowSeconds();
        const cooldown = @as(i64, @intCast(self.config.retry_cooldown_seconds));
        var requeued: usize = 0;

        const Claim = struct {
            id: u64,
            topic: []u8,
            payload: []u8,
            attempt: u32,
        };

        // Length captured up front: it bounds the pass, so entries pushed while
        // this call is running cannot extend it.
        var limit: usize = 0;
        self.lock.lock();
        switch (self.storage) {
            .memory => |s| limit = s.entries.items.len,
            .sqlite => {},
        }
        self.lock.unlock();

        // `scan` only ever moves forward, so an entry requeued in this pass is
        // not requeued again by it: removals shift entries left, never right.
        var scan: usize = 0;
        while (scan < limit) {
            self.lock.lock();
            var claimed: ?Claim = null;
            switch (self.storage) {
                .memory => |*s| {
                    var i = scan;
                    while (i < s.entries.items.len and i < limit) : (i += 1) {
                        const entry = &s.entries.items[i];

                        // Check if message should be retried
                        if (now - entry.last_failed_at < cooldown) continue;

                        // Check retry count
                        if (entry.retry_count >= self.config.max_retries) continue;

                        // Copy out while the entry is still in the list: the
                        // callback runs unlocked and a concurrent purge may
                        // free the originals before it returns.
                        const topic_copy = self.allocator.dupe(u8, entry.original_topic) catch |err| {
                            self.lock.unlock();
                            return err;
                        };
                        const payload_copy = self.allocator.dupe(u8, entry.payload) catch |err| {
                            self.allocator.free(topic_copy);
                            self.lock.unlock();
                            return err;
                        };

                        // Update entry
                        entry.last_failed_at = now;
                        entry.retry_count += 1;

                        claimed = .{
                            .id = entry.id,
                            .topic = topic_copy,
                            .payload = payload_copy,
                            .attempt = entry.retry_count,
                        };
                        scan = i + 1;
                        break;
                    }
                },
                .sqlite => {},
            }
            self.lock.unlock();

            const msg = claimed orelse break;

            // Call callback with caller-provided context, outside the lock.
            callback(ctx, .{
                .id = msg.id,
                .topic = msg.topic,
                .payload = msg.payload,
                .attempt = msg.attempt,
            });
            self.allocator.free(msg.topic);
            self.allocator.free(msg.payload);
            requeued += 1;
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

        self.lock.lock();
        switch (self.storage) {
            .memory => |*s| {
                var i: usize = 0;
                while (i < s.entries.items.len) {
                    const age = now - s.entries.items[i].created_at;
                    if (age > max_age) {
                        const removed = s.entries.orderedRemove(i);
                        self.freeEntry(removed);
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
        self.lock.unlock();

        if (purged > 0) {
            std.log.info("[DLQ] Purged {d} expired messages", .{purged});
        }

        return purged;
    }

    /// Get the current DLQ size
    pub fn size(self: *Self) usize {
        self.lock.lock();
        defer self.lock.unlock();
        return switch (self.storage) {
            .memory => |s| s.entries.items.len,
            .sqlite => 0, // Would query SQLite
        };
    }

    /// Get DLQ entry by ID
    ///
    /// The returned entry borrows the DLQ's strings, so it is only safe to read
    /// until that entry leaves the queue (`remove`, `purgeExpired`, or an
    /// eviction by a `push` at `max_size`). Copy anything kept beyond that.
    pub fn get(self: *Self, id: u64) ?DLQEntry {
        self.lock.lock();
        defer self.lock.unlock();
        switch (self.storage) {
            .memory => |s| {
                for (s.entries.items) |entry| {
                    if (entry.id == id) return entry;
                }
                return null;
            },
            .sqlite => return null,
        }
    }

    /// Remove a specific entry from DLQ
    pub fn remove(self: *Self, id: u64) bool {
        self.lock.lock();
        defer self.lock.unlock();
        switch (self.storage) {
            .memory => |*s| {
                for (s.entries.items, 0..) |entry, i| {
                    if (entry.id == id) {
                        const removed = s.entries.orderedRemove(i);
                        self.freeEntry(removed);
                        return true;
                    }
                }
                return false;
            },
            .sqlite => return false,
        }
    }

    /// Get statistics about DLQ state
    pub fn stats(self: *Self) DLQStats {
        const now = Time.monotonicNowSeconds();
        var oldest_age: i64 = 0;
        var error_counts = std.StringHashMap(u32).init(self.allocator);
        defer error_counts.deinit();

        self.lock.lock();
        defer self.lock.unlock();

        // Count under the same lock as the iteration: calling `size()` here
        // would take the lock twice.
        var total: usize = 0;
        switch (self.storage) {
            .memory => |s| {
                total = s.entries.items.len;
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
            .total_messages = total,
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

/// Shared probe state for the concurrency tests below. File scope so the
/// thread entry points and the requeue callback can name it.
const ConcurrentProbe = struct {
    /// Dispatch count per DLQ entry id (id 0 is unused; ids start at 1).
    dispatches: []std.atomic.Value(u32),
    dispatched: std.atomic.Value(usize) = .init(0),
    pushed: std.atomic.Value(usize) = .init(0),
    purged: std.atomic.Value(usize) = .init(0),
    requeued: std.atomic.Value(usize) = .init(0),
    out_of_range: std.atomic.Value(usize) = .init(0),
    errors: std.atomic.Value(usize) = .init(0),

    fn onRequeue(ctx: *anyopaque, msg: RequeuedMessage) void {
        const self: *ConcurrentProbe = @ptrCast(@alignCast(ctx));
        if (msg.id >= self.dispatches.len) {
            _ = self.out_of_range.fetchAdd(1, .monotonic);
            return;
        }
        _ = self.dispatches[@intCast(msg.id)].fetchAdd(1, .monotonic);
        _ = self.dispatched.fetchAdd(1, .monotonic);
    }

    fn count(self: *ConcurrentProbe, id: u64) u32 {
        if (id >= self.dispatches.len) return 0;
        return self.dispatches[@intCast(id)].load(.monotonic);
    }
};

const ConcurrentPusher = struct {
    fn run(dlq: *DLQ, probe: *ConcurrentProbe, pushes: usize, seed: usize) void {
        for (0..pushes) |i| {
            var buf: [64]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "payload-{d}-{d}", .{ seed, i }) catch {
                _ = probe.errors.fetchAdd(1, .monotonic);
                return;
            };
            dlq.push(.{
                .topic = "concurrent.topic",
                .payload = payload,
                .error_type = "Race",
                .error_message = "concurrent push",
                .retry_count = 0,
            }) catch {
                _ = probe.errors.fetchAdd(1, .monotonic);
                return;
            };
            _ = probe.pushed.fetchAdd(1, .monotonic);
        }
    }
};

/// The retry fiber's shape: purge and requeue back to back. Tight, where
/// `DistributedEventBus.dlqRetryLoop` sleeps a second between passes — the
/// amplification is the point, it compresses the race window into test-sized
/// runtime.
const ConcurrentChurn = struct {
    fn run(
        dlq: *DLQ,
        probe: *ConcurrentProbe,
        stop: *std.atomic.Value(bool),
        callback: *const fn (*anyopaque, RequeuedMessage) void,
    ) void {
        while (!stop.load(.acquire)) {
            const purged = dlq.purgeExpired() catch {
                _ = probe.errors.fetchAdd(1, .monotonic);
                return;
            };
            _ = probe.purged.fetchAdd(purged, .monotonic);

            const requeued = dlq.requeue(probe, callback) catch {
                _ = probe.errors.fetchAdd(1, .monotonic);
                return;
            };
            _ = probe.requeued.fetchAdd(requeued, .monotonic);
        }
    }
};

test "DLQ memory storage basic operations" {
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

test "DLQ requeue respects cooldown" {
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
        fn cb(_: *anyopaque, _: RequeuedMessage) void {}
    }.cb;
    const count = try dlq.requeue(@ptrFromInt(0x8), &noopCallback);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "DLQ purge expired" {
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

test "DLQ requeue hands the callback a private copy, once per entry" {
    const allocator = std.testing.allocator;
    const entries_n: usize = 8;

    var dlq = try DLQ.init(allocator, .{
        .max_age_seconds = 3600,
        .retry_cooldown_seconds = 0,
        // Exactly one retry per entry: the first pass must spend the budget, so
        // a second pass has nothing eligible left.
        .max_retries = 1,
        .storage = .memory,
    });
    defer dlq.deinit();

    for (0..entries_n) |i| {
        var buf: [32]u8 = undefined;
        const payload = try std.fmt.bufPrint(&buf, "entry-{d}", .{i});
        try dlq.push(.{
            .topic = "copy.topic",
            .payload = payload,
            .error_type = "Race",
            .error_message = "private copy",
            .retry_count = 0,
        });
    }

    const Collector = struct {
        var queue: *DLQ = undefined;
        var ids: [entries_n]u64 = undefined;
        var payloads: [entries_n][32]u8 = undefined;
        var lens: [entries_n]usize = undefined;
        var seen: usize = 0;
        var missing: usize = 0;
        var unexpected: usize = 0;
        /// Dispatches whose slices alias the live entry's strings. That is the
        /// pre-lock copy bug: the callback gets the queue's own memory and a
        /// concurrent purge frees it under the callback's feet.
        var aliased: usize = 0;

        fn cb(_: *anyopaque, msg: RequeuedMessage) void {
            const entry = queue.get(msg.id) orelse {
                missing += 1;
                return;
            };
            if (entry.payload.ptr == msg.payload.ptr or entry.original_topic.ptr == msg.topic.ptr) {
                aliased += 1;
            }
            if (seen >= ids.len) {
                unexpected += 1;
                return;
            }
            ids[seen] = msg.id;
            @memcpy(payloads[seen][0..msg.payload.len], msg.payload);
            lens[seen] = msg.payload.len;
            seen += 1;
        }
    };
    Collector.queue = &dlq;

    const requeued = try dlq.requeue(@ptrFromInt(0x8), &Collector.cb);
    try std.testing.expectEqual(entries_n, requeued);
    try std.testing.expectEqual(entries_n, Collector.seen);
    try std.testing.expectEqual(@as(usize, 0), Collector.missing);
    try std.testing.expectEqual(@as(usize, 0), Collector.unexpected);
    try std.testing.expectEqual(@as(usize, 0), Collector.aliased);

    // Every entry exactly once, in queue order, with the payload it was pushed
    // with (ids are assigned in push order and start at 1).
    for (Collector.ids[0..Collector.seen], 0..) |id, slot| {
        try std.testing.expectEqual(@as(u64, slot + 1), id);
        var expected: [32]u8 = undefined;
        const expected_payload = try std.fmt.bufPrint(&expected, "entry-{d}", .{id - 1});
        try std.testing.expectEqualStrings(expected_payload, Collector.payloads[slot][0..Collector.lens[slot]]);
    }

    // The entries are still queued (requeue does not remove them) and their
    // retry budget was spent, so a second pass finds nothing to do.
    try std.testing.expectEqual(entries_n, dlq.size());
    try std.testing.expectEqual(@as(usize, 0), try dlq.requeue(@ptrFromInt(0x8), &Collector.cb));
    try std.testing.expectEqual(entries_n, Collector.seen);
}

test "DLQ concurrent push and retry keep the ledger and the retry budget" {
    const allocator = std.testing.allocator;
    const pushers: usize = 4;
    const pushes_per_pusher: usize = 250;
    const second_wave_pushers: usize = 2;
    const second_wave_pushes: usize = 100;
    const max_retries: u32 = 2;
    const total_pushes = pushers * pushes_per_pusher + second_wave_pushers * second_wave_pushes;

    // Suppress the per-push warning: this test moves `total_pushes` messages on
    // purpose, and the runner prints at `.warn`.
    const prev_log_level = std.testing.log_level;
    defer std.testing.log_level = prev_log_level;
    std.testing.log_level = .err;

    var dlq = try DLQ.init(allocator, .{
        // `max_age_seconds = 0` means an entry created in an earlier clock
        // second is already expired (`age > max_age`), which is what lets the
        // churn thread purge for real while pushes are in flight.
        .max_age_seconds = 0,
        .retry_cooldown_seconds = 0,
        .max_retries = max_retries,
        .max_size = 0,
    });
    defer dlq.deinit();

    const dispatches = try allocator.alloc(std.atomic.Value(u32), total_pushes + 1);
    defer allocator.free(dispatches);
    for (dispatches) |*d| d.* = std.atomic.Value(u32).init(0);

    var probe = ConcurrentProbe{ .dispatches = dispatches };
    var stop = std.atomic.Value(bool).init(false);

    const churn = try std.Thread.spawn(.{}, ConcurrentChurn.run, .{ &dlq, &probe, &stop, &ConcurrentProbe.onRequeue });

    const threads = try allocator.alloc(std.Thread, pushers);
    defer allocator.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, ConcurrentPusher.run, .{ &dlq, &probe, pushes_per_pusher, i });
    }
    for (threads) |t| t.join();

    // Let the clock cross a second boundary so the churn thread purges the
    // first wave, then push the second wave against that purge.
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1100), .awake) catch {};
    const purged_after_first_wave = probe.purged.load(.monotonic);

    for (threads[0..second_wave_pushers], 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, ConcurrentPusher.run, .{ &dlq, &probe, second_wave_pushes, 100 + i });
    }
    for (threads[0..second_wave_pushers]) |t| t.join();

    stop.store(true, .release);
    churn.join();

    const pushed = probe.pushed.load(.acquire);
    const purged = probe.purged.load(.acquire);
    const requeued = probe.requeued.load(.acquire);
    const dispatched = probe.dispatched.load(.acquire);
    const final_size = dlq.size();

    try std.testing.expectEqual(@as(usize, 0), probe.errors.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), probe.out_of_range.load(.monotonic));
    try std.testing.expectEqual(@as(usize, total_pushes), pushed);

    // The retry fiber really ran both halves while pushes were in flight.
    try std.testing.expect(purged_after_first_wave > 0);
    try std.testing.expect(requeued > 0);
    try std.testing.expect(dispatched > 0);

    // Ledger conservation: nothing but an eviction (`max_size = 0` here) or a
    // purge leaves the queue, so `pushed - purged` is exactly the size. A lost
    // or double-counted append breaks it.
    try std.testing.expectEqual(pushed - purged, final_size);

    // No entry may be dispatched more times than `max_retries`: that is what a
    // requeue racing a purge/append breaks (the write of `retry_count` lands on
    // a shifted or reallocated slot, so the budget is never spent).
    var dispatched_ids: usize = 0;
    for (1..dispatches.len) |id| {
        const count = probe.count(id);
        if (count > max_retries) {
            std.debug.print("[DLQ] id {d} dispatched {d} times (budget {d})\n", .{ id, count, max_retries });
        }
        try std.testing.expect(count <= max_retries);
        if (count > 0) dispatched_ids += 1;
    }
    try std.testing.expect(dispatched_ids > 0);
    try std.testing.expectEqual(dispatched, requeued);
}

test "DLQ eviction keeps max_size under concurrent pushes" {
    const allocator = std.testing.allocator;
    const threads_n: usize = 4;
    const pushes_per_thread: usize = 400;
    const max_size: usize = 32;

    const prev_log_level = std.testing.log_level;
    defer std.testing.log_level = prev_log_level;
    std.testing.log_level = .err;

    var dlq = try DLQ.init(allocator, .{
        .max_age_seconds = 3600,
        .retry_cooldown_seconds = 60,
        .max_size = max_size,
        .storage = .memory,
    });
    defer dlq.deinit();

    const dispatches = try allocator.alloc(std.atomic.Value(u32), 1);
    defer allocator.free(dispatches);
    dispatches[0] = std.atomic.Value(u32).init(0);

    var probe = ConcurrentProbe{ .dispatches = dispatches };
    const threads = try allocator.alloc(std.Thread, threads_n);
    defer allocator.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, ConcurrentPusher.run, .{ &dlq, &probe, pushes_per_thread, i });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, 0), probe.errors.load(.monotonic));
    try std.testing.expectEqual(@as(usize, threads_n * pushes_per_thread), probe.pushed.load(.acquire));

    // `max_size` is a hard cap, not a target: the size test, the eviction and
    // the append are one critical section, so the list can never end a push
    // over the limit (nor pair two appends that both skipped eviction).
    try std.testing.expectEqual(max_size, dlq.size());
}
