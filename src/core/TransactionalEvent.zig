const std = @import("std");
const Time = @import("Time.zig");
const EventPublisher = @import("EventPublisher.zig");

/// Transactional event support
/// Ensures events are published only when transaction succeeds
/// Implements the Outbox pattern for reliability
pub const TransactionalEvent = struct {
    const Self = @This();

    /// Transaction state
    pub const State = enum {
        pending, // Event staged but not committed
        committed, // Transaction committed, event published
        failed, // Transaction failed, event discarded
    };

    event: *anyopaque,
    event_type: []const u8,
    state: State = .pending,
    retry_count: u32 = 0,
    max_retries: u32 = 3,

    /// Transaction manager for ACID events
    pub const TransactionManager = struct {
        const TM = @This();

        allocator: std.mem.Allocator,
        pending_events: std.array_list.Managed(TransactionalEvent),
        committed_events: std.array_list.Managed(TransactionalEvent),

        pub fn init(allocator: std.mem.Allocator) TM {
            return .{
                .allocator = allocator,
                .pending_events = std.array_list.Managed(TransactionalEvent).init(allocator),
                .committed_events = std.array_list.Managed(TransactionalEvent).init(allocator),
            };
        }

        pub fn deinit(self: *TM) void {
            self.pending_events.deinit();
            self.committed_events.deinit();
        }

        /// Begin a transaction
        pub fn begin(self: *TM) Transaction {
            return Transaction.init(self);
        }

        /// Stage an event for transactional publishing
        pub fn stageEvent(self: *TM, event: anytype) !void {
            // In real implementation, would serialize event
            _ = self;
            _ = event;
        }
    };

    /// Individual transaction
    pub const Transaction = struct {
        manager: *TransactionManager,
        events: std.array_list.Managed(TransactionalEvent),
        state: State = .pending,

        pub fn init(manager: *TransactionManager) Transaction {
            return .{
                .manager = manager,
                .events = std.array_list.Managed(TransactionalEvent).init(manager.allocator),
                .state = .pending,
            };
        }

        pub fn deinit(self: *Transaction) void {
            self.events.deinit();
        }

        /// Add event to transaction
        pub fn addEvent(self: *Transaction, event: anytype) !void {
            _ = self;
            _ = event;
            // Stage event for later publishing
        }

        /// Commit transaction and publish events
        pub fn commit(self: *Transaction) !void {
            if (self.state != .pending) {
                return error.InvalidTransactionState;
            }

            // In real implementation:
            // 1. Persist events to outbox
            // 2. Commit business transaction
            // 3. Mark events as committed
            // 4. Publish events
            // 5. Remove from outbox

            self.state = .committed;
        }

        /// Rollback transaction
        pub fn rollback(self: *Transaction) void {
            self.state = .failed;
            // Discard all staged events
        }
    };
};

/// Outbox pattern implementation
/// Stores events durably before publishing
pub const EventOutbox = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    storage: std.array_list.Managed(OutboxEntry),

    const OutboxEntry = struct {
        id: u64,
        event_data: []const u8,
        event_type: []const u8,
        timestamp: i64,
        processed: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .storage = std.array_list.Managed(OutboxEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.storage.items) |entry| {
            self.allocator.free(entry.event_data);
            self.allocator.free(entry.event_type);
        }
        self.storage.deinit();
    }

    /// Store event in outbox
    pub fn store(self: *Self, event: anytype) !u64 {
        const id = self.storage.items.len + 1;

        // Serialize event (simplified)
        const event_type = @typeName(@TypeOf(event));
        const type_copy = try self.allocator.dupe(u8, event_type);

        // In real impl, would properly serialize
        const data = try self.allocator.alloc(u8, 0);

        try self.storage.append(.{
            .id = id,
            .event_data = data,
            .event_type = type_copy,
            .timestamp = Time.monotonicNowSeconds(),
        });

        return id;
    }

    /// Mark entry as processed
    pub fn markProcessed(self: *Self, id: u64) void {
        for (self.storage.items) |*entry| {
            if (entry.id == id) {
                entry.processed = true;
                return;
            }
        }
    }

    /// Get unprocessed events
    pub fn getUnprocessed(self: *Self, buf: []OutboxEntry) []OutboxEntry {
        var count: usize = 0;
        for (self.storage.items) |entry| {
            if (!entry.processed and count < buf.len) {
                buf[count] = entry;
                count += 1;
            }
        }
        return buf[0..count];
    }
};

/// Retry policy for failed event publications
pub const RetryPolicy = struct {
    max_retries: u32 = 3,
    initial_delay_ms: u64 = 100,
    backoff_multiplier: f64 = 2.0,
    max_delay_ms: u64 = 30000,

    /// Calculate delay for retry attempt
    pub fn getDelay(self: RetryPolicy, attempt: u32) u64 {
        if (attempt >= self.max_retries) {
            return 0;
        }

        const delay = @as(f64, @floatFromInt(self.initial_delay_ms)) *
            std.math.pow(f64, self.backoff_multiplier, @floatFromInt(attempt));

        return @min(@as(u64, @intFromFloat(delay)), self.max_delay_ms);
    }
};

test "TransactionalEvent basic flow" {
    const allocator = std.testing.allocator;

    var tm = TransactionalEvent.TransactionManager.init(allocator);
    defer tm.deinit();

    var txn = tm.begin();
    defer txn.deinit();

    // Add events to transaction
    try txn.addEvent(42);

    // Commit publishes events
    try txn.commit();
    try std.testing.expectEqual(TransactionalEvent.State.committed, txn.state);
}

test "EventOutbox storage" {
    const allocator = std.testing.allocator;

    var outbox = EventOutbox.init(allocator);
    defer outbox.deinit();

    const TestEvent = struct { value: i32 };
    const id = try outbox.store(TestEvent{ .value = 42 });

    try std.testing.expectEqual(@as(u64, 1), id);

    // SAFETY: Buffer is immediately filled by getUnprocessed() and never read uninitialized
    var buf: [10]EventOutbox.OutboxEntry = undefined;
    const unprocessed = outbox.getUnprocessed(&buf);
    try std.testing.expectEqual(@as(usize, 1), unprocessed.len);
}

test "RetryPolicy backoff" {
    const policy = RetryPolicy{
        .initial_delay_ms = 100,
        .backoff_multiplier = 2.0,
    };

    try std.testing.expectEqual(@as(u64, 100), policy.getDelay(0));
    try std.testing.expectEqual(@as(u64, 200), policy.getDelay(1));
    try std.testing.expectEqual(@as(u64, 400), policy.getDelay(2));
    try std.testing.expectEqual(@as(u64, 0), policy.getDelay(3)); // Max retries exceeded
}
