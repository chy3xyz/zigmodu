const std = @import("std");
const CacheManager = @import("CacheManager.zig").CacheManager;

/// Cache-Aside pattern — automatic read-through / write-through caching
///
/// Read flow:
/// 1. Look up the cache → return on a hit
/// 2. On a miss → query the database → write to cache → return
///
/// Write flow:
/// 1. Write to the database
/// 2. Invalidate the cache entry (or refresh it)
///
/// Usage:
///   var aside = CacheAside.init(allocator, &cache);
///   const user = try aside.get("user:42", struct {
///       fn load(key: []const u8) ![]const u8 { return db.query(key); }
///   }.load);
pub const CacheAside = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    cache: *CacheManager,
    /// Cache TTL override (0 = use the CacheManager default TTL)
    ttl_seconds: u64,

    pub fn init(allocator: std.mem.Allocator, cache: *CacheManager) Self {
        return .{
            .allocator = allocator,
            .cache = cache,
            .ttl_seconds = 0,
        };
    }

    /// Read-Through: read the cache first, load from the DB on a miss and cache the value
    pub fn get(self: *Self, key: []const u8, db_loader: *const fn ([]const u8) anyerror![]const u8) anyerror![]const u8 {
        // Step 1: look up the cache
        if (self.cache.get(key)) |cached| {
            return cached;
        }

        // Step 2: cache miss → query the database
        const value = try db_loader(key);

        // Step 3: write the value to the cache
        try self.cache.set(key, value);

        return value;
    }

    /// Write-Through: write to the DB, then update the cache
    pub fn set(self: *Self, key: []const u8, value: []const u8, db_writer: *const fn ([]const u8, []const u8) anyerror!void) !void {
        try db_writer(key, value);
        try self.cache.set(key, value);
    }

    /// Write-Invalidate: write to the DB, then invalidate the cache (the common pattern)
    pub fn invalidate(self: *Self, key: []const u8, db_writer: *const fn ([]const u8) anyerror!void) !void {
        try db_writer(key);
        _ = self.cache.remove(key);
    }

    /// Delete from both the database and the cache
    pub fn delete(self: *Self, key: []const u8, db_deleter: *const fn ([]const u8) anyerror!void) !void {
        try db_deleter(key);
        _ = self.cache.remove(key);
    }

    /// Warm up the cache: load the given keys from the DB in bulk
    pub fn warmup(self: *Self, keys: []const []const u8, db_loader: *const fn ([]const u8) anyerror![]const u8) !void {
        for (keys) |key| {
            _ = self.get(key, db_loader) catch |err| {
                std.log.warn("[CacheAside] Warmup failed for key '{s}': {s}", .{ key, @errorName(err) });
            };
        }
    }

    /// Get cache statistics
    pub fn getStats(self: *Self) CacheManager.CacheStats {
        return self.cache.getStats();
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "CacheAside read-through miss" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 0, .LRU);
    defer cache.deinit();

    var aside = CacheAside.init(allocator, &cache);

    var call_count: usize = 0;
    const loader = struct {
        var count: *usize = undefined;
        fn load(key: []const u8) ![]const u8 {
            _ = key;
            count.* += 1;
            return "from-db";
        }
    };
    loader.count = &call_count;

    // First call: cache miss → loads from DB
    const val1 = try aside.get("key1", loader.load);
    try std.testing.expectEqualStrings("from-db", val1);
    try std.testing.expectEqual(@as(usize, 1), call_count);

    // Second call: cache hit → no DB call
    const val2 = try aside.get("key1", loader.load);
    try std.testing.expectEqualStrings("from-db", val2);
    try std.testing.expectEqual(@as(usize, 1), call_count);
}

test "CacheAside write-through" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 0, .LRU);
    defer cache.deinit();

    var aside = CacheAside.init(allocator, &cache);

    var db_written = false;
    const writer = struct {
        var flag: *bool = undefined;
        fn write(key: []const u8, val: []const u8) !void {
            _ = key;
            _ = val;
            flag.* = true;
        }
    };
    writer.flag = &db_written;

    try aside.set("k", "v", writer.write);

    try std.testing.expect(db_written);
    try std.testing.expectEqualStrings("v", cache.get("k").?);
}

test "CacheAside write-invalidate" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 0, .LRU);
    defer cache.deinit();

    var aside = CacheAside.init(allocator, &cache);

    // Prime cache
    try cache.set("k", "old");

    var db_called = false;
    const writer = struct {
        var flag: *bool = undefined;
        fn write(key: []const u8) !void {
            _ = key;
            flag.* = true;
        }
    };
    writer.flag = &db_called;

    try aside.invalidate("k", writer.write);

    try std.testing.expect(db_called);
    try std.testing.expect(cache.get("k") == null);
}

test "CacheAside delete" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 0, .LRU);
    defer cache.deinit();

    var aside = CacheAside.init(allocator, &cache);

    try cache.set("k", "v");

    var db_called = false;
    const deleter = struct {
        var flag: *bool = undefined;
        fn del(key: []const u8) !void {
            _ = key;
            flag.* = true;
        }
    };
    deleter.flag = &db_called;

    try aside.delete("k", deleter.del);

    try std.testing.expect(db_called);
    try std.testing.expect(cache.get("k") == null);
}

test "CacheAside warmup" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 0, .LRU);
    defer cache.deinit();

    var aside = CacheAside.init(allocator, &cache);

    var call_count: usize = 0;
    const loader = struct {
        var count: *usize = undefined;
        fn load(key: []const u8) ![]const u8 {
            _ = key;
            count.* += 1;
            return "db-value";
        }
    };
    loader.count = &call_count;

    const keys = &[_][]const u8{ "a", "b", "c" };
    try aside.warmup(keys, loader.load);

    try std.testing.expectEqual(@as(usize, 3), call_count);
    // All keys should now be cached
    try std.testing.expect(cache.get("a") != null);
    try std.testing.expect(cache.get("b") != null);
    try std.testing.expect(cache.get("c") != null);
}
