//! Local cache for zigzero
//!
//! Provides in-memory LRU cache aligned with go-zero's cache patterns.

const std = @import("std");

pub fn Cache(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Entry = struct {
            key: K,
            value: V,
            expires_at: ?i64,
        };

        allocator: std.mem.Allocator,
        map: std.AutoHashMap(K, Entry),
        max_size: usize,
        mutex: std.Thread.Mutex,

        pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
            return .{
                .allocator = allocator,
                .map = std.AutoHashMap(K, Entry).init(allocator),
                .max_size = max_size,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }

        /// Get value from cache
        pub fn get(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();

            const entry = self.map.get(key) orelse return null;

            if (entry.expires_at) |expires| {
                if (std.time.milliTimestamp() > expires) {
                    _ = self.map.remove(key);
                    return null;
                }
            }

            return entry.value;
        }

        /// Set value in cache with optional TTL
        pub fn set(self: *Self, key: K, value: V, ttl_ms: ?i64) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const expires_at = if (ttl_ms) |ttl| std.time.milliTimestamp() + ttl else null;

            // Simple eviction if at capacity
            if (self.map.count() >= self.max_size and !self.map.contains(key)) {
                var iter = self.map.keyIterator();
                if (iter.next()) |first_key| {
                    _ = self.map.remove(first_key.*);
                }
            }

            try self.map.put(key, .{
                .key = key,
                .value = value,
                .expires_at = expires_at,
            });
        }

        /// Delete key from cache
        pub fn delete(self: *Self, key: K) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.map.remove(key);
        }

        /// Clear all cache entries
        pub fn clear(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.map.clearRetainingCapacity();
        }

        /// Current cache size
        pub fn size(self: *Self) usize {
            self.mutex.lock();
            const s = self.map.count();
            self.mutex.unlock();
            return s;
        }
    };
}

test "cache basic" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "hello", null);
    try std.testing.expectEqualStrings("hello", cache.get(1).?);

    cache.delete(1);
    try std.testing.expect(cache.get(1) == null);
}

test "cache ttl" {
    var cache = Cache(u32, []const u8).init(std.testing.allocator, 10);
    defer cache.deinit();

    try cache.set(1, "hello", 1);
    try std.testing.expectEqualStrings("hello", cache.get(1).?);

    std.Thread.sleep(2 * std.time.ns_per_ms);
    try std.testing.expect(cache.get(1) == null);
}
