const std = @import("std");
const Time = @import("../core/Time.zig");

/// Bulkhead [...] — Semaphore[...]
///
/// [...]Prevent downstream failure from exhausting all resources
/// [...] Resilience4j Bulkhead / Hystrix Thread Pool Isolation
///
/// Usage:
///   var bulkhead = Bulkhead.init(allocator, "db-pool", 10, 5);
///   try bulkhead.acquire();
///   defer bulkhead.release();
/// // ... [...] ...
///
/// Semaphore[...]:
/// max_concurrent: [...]
/// max_queue:      [...] (0 = [...])
pub const Bulkhead = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    name: []const u8,
    /// [...]call[...]
    active_calls: u32,
    /// [...]
    max_concurrent: u32,
    /// [...]
    max_queue: u32,
    /// [...]
    waiting: u32,
    /// [...]
    stats: BulkheadStats,

    pub const BulkheadStats = struct {
        total_acquired: u64 = 0,
        total_rejected: u64 = 0,
        total_released: u64 = 0,
        peak_concurrent: u32 = 0,
        created_at: i64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, max_concurrent: u32, max_queue: u32) !Self {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        return .{
            .allocator = allocator,
            .name = name_copy,
            .active_calls = 0,
            .max_concurrent = max_concurrent,
            .max_queue = max_queue,
            .waiting = 0,
            .stats = .{ .created_at = Time.monotonicNowSeconds() },
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
    }

    /// [...]Semaphore
    /// success[...] true[...] false
    pub fn tryAcquire(self: *Self) bool {
        if (self.active_calls < self.max_concurrent) {
            self.active_calls += 1;
            self.stats.total_acquired += 1;
            if (self.active_calls > self.stats.peak_concurrent) {
                self.stats.peak_concurrent = self.active_calls;
            }
            return true;
        }
        self.stats.total_rejected += 1;
        return false;
    }

    /// [...]Semaphore ([...])
    pub fn acquire(self: *Self) void {
        if (self.tryAcquire()) return;

        // Check if[...]
        if (self.max_queue > 0 and self.waiting < self.max_queue) {
            self.waiting += 1;
            // [...] ([...]: [...])
            while (self.active_calls >= self.max_concurrent) {
                // yield
                std.atomic.spinLoopHint();
            }
            self.waiting -= 1;
            self.active_calls += 1;
            self.stats.total_acquired += 1;
            if (self.active_calls > self.stats.peak_concurrent) {
                self.stats.peak_concurrent = self.active_calls;
            }
            return;
        }

        self.stats.total_rejected += 1;
    }

    /// [...]Semaphore
    pub fn release(self: *Self) void {
        if (self.active_calls > 0) {
            self.active_calls -= 1;
            self.stats.total_released += 1;
        }
    }

    /// Get current[...]
    pub fn getActiveCount(self: *Self) u32 {
        return self.active_calls;
    }

    /// [...]
    pub fn getMaxConcurrent(self: *Self) u32 {
        return self.max_concurrent;
    }

    /// Get current[...]
    pub fn getWaitingCount(self: *Self) u32 {
        return self.waiting;
    }

    /// [...]Info
    pub fn getStats(self: *Self) BulkheadStats {
        return self.stats;
    }

    /// Check if[...]
    pub fn isFull(self: *Self) bool {
        return self.active_calls >= self.max_concurrent;
    }

    /// Get current[...] (0.0-1.0)
    pub fn getUtilization(self: *Self) f64 {
        if (self.max_concurrent == 0) return 0;
        return @as(f64, @floatFromInt(self.active_calls)) / @as(f64, @floatFromInt(self.max_concurrent));
    }
};

/// BulkheadRegistry — [...] Bulkhead [...]
pub const BulkheadRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    bulkheads: std.StringHashMap(*Bulkhead),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .bulkheads = std.StringHashMap(*Bulkhead).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.bulkheads.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.name);
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.bulkheads.deinit();
    }

    pub fn getOrCreate(self: *Self, name: []const u8, max_concurrent: u32, max_queue: u32) !*Bulkhead {
        if (self.bulkheads.get(name)) |bh| return bh;

        const bh = try self.allocator.create(Bulkhead);
        bh.* = try Bulkhead.init(self.allocator, name, max_concurrent, max_queue);
        try self.bulkheads.put(bh.name, bh);
        return bh;
    }

    pub fn get(self: *Self, name: []const u8) ?*Bulkhead {
        return self.bulkheads.get(name);
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "Bulkhead basic acquire release" {
    const allocator = std.testing.allocator;
    var bh = try Bulkhead.init(allocator, "test", 5, 0);
    defer bh.deinit();

    try std.testing.expect(bh.tryAcquire());
    try std.testing.expectEqual(@as(u32, 1), bh.getActiveCount());

    bh.release();
    try std.testing.expectEqual(@as(u32, 0), bh.getActiveCount());
}

test "Bulkhead max concurrent enforcement" {
    const allocator = std.testing.allocator;
    var bh = try Bulkhead.init(allocator, "test", 2, 0);
    defer bh.deinit();

    try std.testing.expect(bh.tryAcquire());
    try std.testing.expect(bh.tryAcquire());
    // [...]failure
    try std.testing.expect(!bh.tryAcquire());

    try std.testing.expect(bh.isFull());
}

test "Bulkhead stats" {
    const allocator = std.testing.allocator;
    var bh = try Bulkhead.init(allocator, "stats-test", 2, 0);
    defer bh.deinit();

    try std.testing.expect(bh.tryAcquire());
    try std.testing.expect(bh.tryAcquire());
    try std.testing.expect(!bh.tryAcquire()); // rejected

    const stats = bh.getStats();
    try std.testing.expectEqual(@as(u64, 2), stats.total_acquired);
    try std.testing.expectEqual(@as(u64, 1), stats.total_rejected);
    try std.testing.expectEqual(@as(u32, 2), stats.peak_concurrent);
}

test "Bulkhead utilization" {
    const allocator = std.testing.allocator;
    var bh = try Bulkhead.init(allocator, "util", 10, 0);
    defer bh.deinit();

    try std.testing.expect(bh.tryAcquire());
    try std.testing.expect(bh.tryAcquire());

    const util = bh.getUtilization();
    try std.testing.expect(util > 0.19 and util < 0.21); // ~20%
}

test "BulkheadRegistry get or create" {
    const allocator = std.testing.allocator;
    var registry = BulkheadRegistry.init(allocator);
    defer registry.deinit();

    const bh1 = try registry.getOrCreate("db", 10, 5);
    const bh2 = try registry.getOrCreate("db", 10, 5);

    // [...]
    try std.testing.expect(bh1 == bh2);

    try std.testing.expect(bh1.tryAcquire());
    try std.testing.expectEqual(@as(u32, 1), bh1.getActiveCount());
}

test "Bulkhead queue full rejection" {
    const allocator = std.testing.allocator;
    var bh = try Bulkhead.init(allocator, "queue-test", 3, 2);
    defer bh.deinit();

    // Exhaust concurrent slots
    try std.testing.expect(bh.tryAcquire());
    try std.testing.expect(bh.tryAcquire());
    try std.testing.expect(bh.tryAcquire());
    try std.testing.expectEqual(@as(u32, 3), bh.getActiveCount());

    // Next call should be rejected (queue full + no concurrent slots)
    try std.testing.expect(!bh.tryAcquire());

    // Release and re-acquire should work
    bh.release();
    try std.testing.expect(bh.tryAcquire());
}
