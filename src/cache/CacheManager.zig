const std = @import("std");
const ManagedArrayList = std.array_list.Managed;

/// 缓存管理器 - 支持多种淘汰策略
///
/// ⚠️ 线程安全注意：
/// - 当前实现不是线程安全的，请在单线程环境下使用
/// - 如果需要在多线程环境使用，请在外部添加同步机制（如 Mutex）
/// - 并发访问可能导致数据竞争和内存损坏
///
/// 建议：
/// - 单线程应用：直接使用
/// - 多线程应用：每个线程使用独立的 CacheManager 实例，或使用外部锁保护
///
pub const CacheManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    max_size: usize,
    ttl_seconds: u64,
    eviction_policy: EvictionPolicy,
    entries: std.StringHashMap(CacheEntry),
    access_order: ManagedArrayList([]const u8), // For LRU

    pub const EvictionPolicy = enum {
        LRU, // Least Recently Used
        LFU, // Least Frequently Used
        FIFO, // First In First Out
        TTL, // Time To Live only
    };

    pub const CacheEntry = struct {
        key: []const u8,
        value: []const u8,
        created_at: i64,
        last_accessed: i64,
        access_count: u64,
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize, ttl_seconds: u64, policy: EvictionPolicy) Self {
        return .{
            .allocator = allocator,
            .max_size = max_size,
            .ttl_seconds = ttl_seconds,
            .eviction_policy = policy,
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .access_order = ManagedArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.value);
        }
        self.entries.deinit();

        for (self.access_order.items) |key| {
            self.allocator.free(key);
        }
        self.access_order.deinit();
    }

    /// 设置缓存值
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        // 如果缓存已满，执行淘汰
        if (self.entries.count() >= self.max_size) {
            try self.evict();
        }

        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);

        const now = std.time.timestamp();

        // 如果键已存在，更新它
        if (self.entries.getPtr(key_copy)) |existing| {
            self.allocator.free(existing.value);
            existing.value = value_copy;
            existing.last_accessed = now;
            existing.access_count += 1;
            self.allocator.free(key_copy);
            return;
        }

        // 添加新条目
        const entry = CacheEntry{
            .key = key_copy,
            .value = value_copy,
            .created_at = now,
            .last_accessed = now,
            .access_count = 1,
        };

        try self.entries.put(key_copy, entry);

        // 更新访问顺序（用于LRU/FIFO）
        if (self.eviction_policy == .LRU or self.eviction_policy == .FIFO) {
            const order_key = try self.allocator.dupe(u8, key_copy);
            try self.access_order.append(order_key);
        }
    }

    /// 获取缓存值
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        const entry = self.entries.getPtr(key) orelse return null;

        // 检查TTL
        if (self.ttl_seconds > 0) {
            const now = std.time.timestamp();
            if (@as(u64, @intCast(now - entry.created_at)) > self.ttl_seconds) {
                // 条目已过期
                _ = self.remove(key);
                return null;
            }
        }

        // 更新访问信息
        entry.last_accessed = std.time.timestamp();
        entry.access_count += 1;

        // 更新LRU顺序
        if (self.eviction_policy == .LRU) {
            self.updateAccessOrder(key);
        }

        return entry.value;
    }

    /// 删除缓存条目
    pub fn remove(self: *Self, key: []const u8) bool {
        const entry = self.entries.fetchRemove(key) orelse return false;
        self.allocator.free(entry.value.key);
        self.allocator.free(entry.value.value);

        // 从访问顺序中移除
        if (self.eviction_policy == .LRU or self.eviction_policy == .FIFO) {
            for (self.access_order.items, 0..) |k, i| {
                if (std.mem.eql(u8, k, key)) {
                    self.allocator.free(k);
                    _ = self.access_order.orderedRemove(i);
                    break;
                }
            }
        }

        return true;
    }

    /// 执行淘汰
    fn evict(self: *Self) !void {
        if (self.entries.count() == 0) return;

        var key_to_remove: ?[]const u8 = null;

        switch (self.eviction_policy) {
            .LRU, .FIFO => {
                // 移除最早访问的
                if (self.access_order.items.len > 0) {
                    const oldest_key = self.access_order.items[0];
                    key_to_remove = try self.allocator.dupe(u8, oldest_key);
                }
            },
            .LFU => {
                // 找到访问次数最少的
                var min_access_count: u64 = std.math.maxInt(u64);
                var iter = self.entries.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.access_count < min_access_count) {
                        min_access_count = entry.value_ptr.access_count;
                        key_to_remove = try self.allocator.dupe(u8, entry.key_ptr.*);
                    }
                }
            },
            .TTL => {
                // 移除最早创建的
                var oldest_time: i64 = std.math.maxInt(i64);
                var iter = self.entries.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.created_at < oldest_time) {
                        oldest_time = entry.value_ptr.created_at;
                        key_to_remove = try self.allocator.dupe(u8, entry.key_ptr.*);
                    }
                }
            },
        }

        if (key_to_remove) |key| {
            defer self.allocator.free(key);
            _ = self.remove(key);
        }
    }

    /// 更新LRU访问顺序
    /// 优化：使用双向链表可以实现O(1)，但当前使用ArrayList优化查找
    fn updateAccessOrder(self: *Self, key: []const u8) void {
        // 只在LRU策略下更新
        if (self.eviction_policy != .LRU) return;

        // 找到并移除旧位置
        for (self.access_order.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) {
                // 如果已经在末尾，不需要移动
                if (i == self.access_order.items.len - 1) return;

                const key_copy = self.access_order.orderedRemove(i);
                // 添加到末尾（最近访问）
                self.access_order.append(key_copy) catch {
                    // 如果追加失败，至少把key放回去（保持数据一致性）
                    // 虽然这不太可能失败，因为 orderedRemove 已经移除了一个元素
                };
                break;
            }
        }
    }

    /// 获取缓存值（批量版本，减少重复更新访问顺序的开销）
    pub fn getBatch(self: *Self, keys: []const []const u8, values: [][]const u8) !usize {
        var found_count: usize = 0;

        // 先收集所有值，再统一更新访问顺序
        for (keys, 0..) |key, i| {
            if (self.entries.getPtr(key)) |entry| {
                // 检查TTL
                if (self.ttl_seconds > 0) {
                    const now = std.time.timestamp();
                    if (@as(u64, @intCast(now - entry.created_at)) > self.ttl_seconds) {
                        continue;
                    }
                }

                values[i] = entry.value;
                entry.last_accessed = std.time.timestamp();
                entry.access_count += 1;
                found_count += 1;
            }
        }

        // 批量更新访问顺序（如果有LRU）
        if (self.eviction_policy == .LRU and found_count > 0) {
            // 优化：批量更新访问顺序
            // 1. 收集所有需要更新的key（排除已经过期的）
            var valid_keys = ManagedArrayList([]const u8).init(self.allocator);
            defer valid_keys.deinit();

            for (keys) |key| {
                if (self.entries.contains(key)) {
                    try valid_keys.append(key);
                }
            }

            // 2. 批量移除这些key（从后往前遍历，避免索引偏移问题）
            var i: usize = self.access_order.items.len;
            while (i > 0) {
                i -= 1;
                const current_key = self.access_order.items[i];
                // 检查这个key是否在valid_keys中
                for (valid_keys.items) |vk| {
                    if (std.mem.eql(u8, current_key, vk)) {
                        // 使用swapRemove提高效率（顺序不重要，因为我们后面会重新添加）
                        _ = self.access_order.swapRemove(i);
                        break;
                    }
                }
            }

            // 3. 批量添加到末尾（最近访问），处理可能的内存分配失败
            for (valid_keys.items) |key| {
                const key_copy = self.allocator.dupe(u8, key) catch |err| {
                    // 如果分配失败，清理已分配的key并返回错误
                    var j: usize = self.access_order.items.len;
                    while (j > 0) {
                        j -= 1;
                        // 清理我们刚才添加的新key（从原始位置+1开始）
                        const item = self.access_order.items[j];
                        var is_new = false;
                        for (valid_keys.items) |vk| {
                            if (std.mem.eql(u8, item, vk)) {
                                is_new = true;
                                break;
                            }
                        }
                        if (is_new) {
                            const removed = self.access_order.orderedRemove(j);
                            self.allocator.free(removed);
                        }
                    }
                    return err;
                };
                self.access_order.append(key_copy) catch |err| {
                    self.allocator.free(key_copy);
                    return err;
                };
            }
        }

        return found_count;
    }

    /// 清空缓存
    pub fn clear(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.value);
        }
        self.entries.clearRetainingCapacity();

        for (self.access_order.items) |key| {
            self.allocator.free(key);
        }
        self.access_order.clearRetainingCapacity();
    }

    /// 获取缓存统计
    pub fn getStats(self: *Self) CacheStats {
        var stats = CacheStats{
            .size = self.entries.count(),
            .max_size = self.max_size,
        };

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            stats.total_access_count += entry.value_ptr.access_count;
        }

        return stats;
    }

    /// 批量获取
    pub fn getMany(self: *Self, keys: []const []const u8) !std.StringHashMap([]const u8) {
        var results = std.StringHashMap([]const u8).init(self.allocator);

        for (keys) |key| {
            if (self.get(key)) |value| {
                try results.put(key, value);
            }
        }

        return results;
    }

    /// 批量设置
    pub fn setMany(self: *Self, items: std.StringHashMap([]const u8)) !void {
        var iter = items.iterator();
        while (iter.next()) |entry| {
            try self.set(entry.key_ptr.*, entry.value_ptr.*);
        }
    }
};

pub const CacheStats = struct {
    size: usize,
    max_size: usize,
    total_access_count: u64 = 0,

    pub fn hitRate(self: CacheStats) f64 {
        if (self.total_access_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.total_access_count)) / @as(f64, @floatFromInt(self.size));
    }

    pub fn utilization(self: CacheStats) f64 {
        if (self.max_size == 0) return 0.0;
        return @as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(self.max_size));
    }
};

test "CacheManager basic set get remove" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 0, .LRU);
    defer cache.deinit();

    try cache.set("key1", "value1");
    try std.testing.expectEqualStrings("value1", cache.get("key1").?);

    try cache.set("key1", "value2");
    try std.testing.expectEqualStrings("value2", cache.get("key1").?);

    try std.testing.expect(cache.remove("key1"));
    try std.testing.expect(cache.get("key1") == null);
}

test "CacheManager LRU eviction" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 2, 0, .LRU);
    defer cache.deinit();

    try cache.set("a", "1");
    try cache.set("b", "2");
    _ = cache.get("a"); // access a to make it recently used
    try cache.set("c", "3"); // should evict b

    try std.testing.expect(cache.get("a") != null);
    try std.testing.expect(cache.get("b") == null);
    try std.testing.expect(cache.get("c") != null);
}

test "CacheManager TTL expiration" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 10, 1, .TTL);
    defer cache.deinit();

    try cache.set("a", "1");
    try std.testing.expectEqualStrings("1", cache.get("a").?);

    // Wait for TTL to expire
    std.Thread.sleep(2 * std.time.ns_per_s);
    try std.testing.expect(cache.get("a") == null);
}

test "CacheManager clear and stats" {
    const allocator = std.testing.allocator;
    var cache = CacheManager.init(allocator, 5, 0, .FIFO);
    defer cache.deinit();

    try cache.set("a", "1");
    try cache.set("b", "2");
    _ = cache.get("a");
    _ = cache.get("b");

    var stats = cache.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.size);
    try std.testing.expectEqual(@as(usize, 5), stats.max_size);

    cache.clear();
    stats = cache.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.size);
    try std.testing.expect(cache.get("a") == null);
}
