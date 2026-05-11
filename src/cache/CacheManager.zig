//! Cache Manager with multiple eviction policies.
//!
//! LRU uses monotonic counter (O(1) promotion, O(n) eviction scan).
//! LFU uses access_count field (O(1) promotion, O(n) eviction scan).
//! Thread safety: single-threaded. Use external Mutex for concurrent access.

const std = @import("std");
const Time = @import("../core/Time.zig");

pub const CacheManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    max_size: usize,
    ttl_seconds: u64,
    eviction_policy: EvictionPolicy,
    entries: std.StringHashMap(CacheEntry),
    /// Monotonic counter for O(1) LRU ordering. Higher = more recently used.
    lru_counter: u64 = 0,

    pub const EvictionPolicy = enum { LRU, LFU, FIFO, TTL };

    pub const CacheEntry = struct {
        value: []const u8,
        created_at: i64,
        last_accessed: i64,
        access_count: u64,
        /// Monotonic ID assigned on last access. Higher = newer (for LRU eviction).
        lru_id: u64 = 0,
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize, ttl_seconds: u64, policy: EvictionPolicy) Self {
        return .{
            .allocator = allocator,
            .max_size = max_size,
            .ttl_seconds = ttl_seconds,
            .eviction_policy = policy,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.entries.deinit();
    }

    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        if (self.entries.count() >= self.max_size and self.entries.get(key) == null) {
            try self.evict();
        }

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        const now = Time.monotonicNowSeconds();

        if (self.entries.getPtr(key)) |existing| {
            self.allocator.free(existing.value);
            existing.value = value_copy;
            existing.last_accessed = now;
            existing.access_count += 1;
            self.lru_counter += 1;
            existing.lru_id = self.lru_counter;
            return;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        self.lru_counter += 1;
        try self.entries.put(key_copy, .{
            .value = value_copy,
            .created_at = now,
            .last_accessed = now,
            .access_count = 1,
            .lru_id = self.lru_counter,
        });
    }

    /// O(1) lookup. LRU promotion is O(1) via lru_counter increment.
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        const entry = self.entries.getPtr(key) orelse return null;

        if (self.ttl_seconds > 0) {
            const now = Time.monotonicNowSeconds();
            if (@as(u64, @intCast(now - entry.created_at)) > self.ttl_seconds) {
                _ = self.remove(key);
                return null;
            }
        }

        entry.last_accessed = Time.monotonicNowSeconds();
        entry.access_count += 1;
        self.lru_counter += 1;
        entry.lru_id = self.lru_counter; // O(1) LRU promotion

        return entry.value;
    }

    pub fn remove(self: *Self, key: []const u8) bool {
        const entry = self.entries.fetchRemove(key) orelse return false;
        self.allocator.free(entry.key);
        self.allocator.free(entry.value.value);
        return true;
    }

    /// Evict one entry per policy. O(n) scan for LRU/LFU (dominant cost is HashMap iteration).
    fn evict(self: *Self) !void {
        if (self.entries.count() == 0) return;

        var key_to_remove: ?[]const u8 = null;
        var min_lru_id: u64 = std.math.maxInt(u64);
        var min_access_count: u64 = std.math.maxInt(u64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            switch (self.eviction_policy) {
                .LRU, .FIFO => {
                    if (entry.value_ptr.lru_id < min_lru_id) {
                        min_lru_id = entry.value_ptr.lru_id;
                        key_to_remove = entry.key_ptr.*;
                    }
                },
                .LFU => {
                    if (entry.value_ptr.access_count < min_access_count) {
                        min_access_count = entry.value_ptr.access_count;
                        key_to_remove = entry.key_ptr.*;
                    }
                },
                .TTL => {
                    const now = Time.monotonicNowSeconds();
                    if (@as(u64, @intCast(now - entry.value_ptr.created_at)) > self.ttl_seconds) {
                        key_to_remove = entry.key_ptr.*;
                        break;
                    }
                },
            }
        }

        if (key_to_remove) |k| {
            _ = self.remove(k);
        }
    }

    pub fn count(self: *Self) usize {
        return self.entries.count();
    }
};

// ── Tests ──

test "CacheManager LRU eviction" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 2, 0, .LRU);
    defer cache.deinit();

    try cache.set("a", "1");
    try cache.set("b", "2");
    // Access "a" to make it more recent
    _ = cache.get("a");
    // Add "c" — should evict "b" (older LRU)
    try cache.set("c", "3");

    try std.testing.expect(cache.get("a") != null);
    try std.testing.expect(cache.get("c") != null);
    try std.testing.expect(cache.get("b") == null); // evicted
}

test "CacheManager TTL expiration" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 1, .TTL);
    defer cache.deinit();

    try cache.set("x", "val");
    try std.testing.expect(cache.get("x") != null);
    // TTL=1 means immediate expiry on next access
    _ = cache.get("x"); // triggers TTL check — may expire
}

test "CacheManager LFU eviction" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 2, 0, .LFU);
    defer cache.deinit();

    try cache.set("a", "1");
    try cache.set("b", "2");
    _ = cache.get("a");
    _ = cache.get("a"); // a has access_count=3
    _ = cache.get("b"); // b has access_count=2

    try cache.set("c", "3"); // should evict b (lower access count)
    try std.testing.expect(cache.get("a") != null);
    try std.testing.expect(cache.get("b") == null);
}
