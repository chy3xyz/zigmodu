const std = @import("std");

var _tick: i64 = 0;
fn monotonicNowSeconds() i64 {
    _tick += 1;
    return _tick;
}

/// Persistent memory entry — facts, preferences, lessons stored across sessions.
pub const MemoryEntry = struct {
    key: []const u8,
    value: []const u8,
    tenant_id: i64 = 0,
    user_id: i64 = 0,
    created_at: i64,
    access_count: usize = 0,
    last_accessed_at: i64 = 0,
};

/// Thread-safe in-memory store with optional persistence backend.
/// Pattern: same mutex model as SkillRegistry, ConnectionRegistry.
///
/// Usage:
///   var store = MemoryStore.init(allocator, io);
///   try store.remember("user:pref:lang", "zh", 1, 42);
///   const facts = try store.recall(allocator, "user:pref", 1, 42);
pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.StringHashMap(MemoryEntry),
    mutex: std.Io.Mutex,
    max_entries: usize = 10000,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) MemoryStore {
        return initCapacity(allocator, io, 1000);
    }

    /// Init with capacity hint for pre-allocated HashMap storage.
    pub fn initCapacity(allocator: std.mem.Allocator, io: std.Io, capacity: usize) MemoryStore {
        var entries = std.StringHashMap(MemoryEntry).init(allocator);
        entries.ensureTotalCapacity(@intCast(capacity)) catch {};
        return .{
            .allocator = allocator,
            .io = io,
            .entries = entries,
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.key);
            self.allocator.free(entry.value_ptr.*.value);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    /// Store a fact. Key format: "namespace:category:detail" (e.g. "user:pref:lang").
    pub fn remember(self: *MemoryStore, key: []const u8, value: []const u8, tenant_id: i64, user_id: i64) !void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        // Evict oldest if at capacity
        if (self.entries.count() >= self.max_entries) {
            self.evictOldestLocked();
        }

        const now = monotonicNowSeconds();
        const owned_key = try self.allocator.dupe(u8, key);
        const owned_value = try self.allocator.dupe(u8, value);

        // Check if key exists — update if so
        if (self.entries.getPtr(key)) |existing| {
            self.allocator.free(existing.key);
            self.allocator.free(existing.value);
            existing.key = owned_key;
            existing.value = owned_value;
            existing.tenant_id = tenant_id;
            existing.user_id = user_id;
            existing.access_count += 1;
            existing.last_accessed_at = now;
            return;
        }

        self.entries.putAssumeCapacity(owned_key, .{
            .key = owned_key,
            .value = owned_value,
            .tenant_id = tenant_id,
            .user_id = user_id,
            .created_at = now,
            .access_count = 0,
            .last_accessed_at = now,
        });
    }

    /// Recall facts matching a key prefix, scoped to tenant+user.
    /// Caller owns returned ArrayList memory.
    pub fn recall(
        self: *MemoryStore,
        allocator: std.mem.Allocator,
        key_prefix: []const u8,
        tenant_id: i64,
        user_id: i64,
    ) !std.ArrayList(MemoryEntry) {
        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);

        var result = std.ArrayList(MemoryEntry).empty;
        const now = monotonicNowSeconds();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const e = entry.value_ptr;
            if (e.tenant_id != tenant_id and tenant_id != 0) continue;
            if (e.user_id != user_id and user_id != 0) continue;
            if (key_prefix.len > 0 and !std.mem.startsWith(u8, e.key, key_prefix)) continue;

            e.access_count += 1;
            e.last_accessed_at = now;

            try result.append(allocator, .{
                .key = try allocator.dupe(u8, e.key),
                .value = try allocator.dupe(u8, e.value),
                .tenant_id = e.tenant_id,
                .user_id = e.user_id,
                .created_at = e.created_at,
                .access_count = e.access_count,
                .last_accessed_at = e.last_accessed_at,
            });
        }
        return result;
    }

    /// Remove a specific memory by key.
    pub fn forget(self: *MemoryStore, key: []const u8) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (self.entries.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value.key);
            self.allocator.free(kv.value.value);
        }
    }

    /// Format recalled memories as context strings for system prompt injection.
    /// Returns allocated string — caller owns.
    pub fn formatContext(
        self: *MemoryStore,
        allocator: std.mem.Allocator,
        key_prefix: []const u8,
        tenant_id: i64,
        user_id: i64,
        max_items: usize,
    ) ![]const u8 {
        var recalled = try self.recall(allocator, key_prefix, tenant_id, user_id);
        defer {
            for (recalled.items) |e| {
                allocator.free(e.key);
                allocator.free(e.value);
            }
            recalled.deinit(allocator);
        }

        var buf = std.ArrayList(u8).empty;
        try buf.appendSlice(allocator, "Relevant context:\n");
        const limit = @min(recalled.items.len, max_items);
        for (recalled.items[0..limit]) |e| {
            try buf.appendSlice(allocator, "- ");
            try buf.appendSlice(allocator, e.value);
            try buf.appendSlice(allocator, "\n");
        }
        return buf.toOwnedSlice(allocator);
    }

    /// Number of stored entries.
    pub fn count(self: *MemoryStore) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.entries.count();
    }

    fn evictOldestLocked(self: *MemoryStore) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_accessed_at < oldest_time) {
                oldest_time = entry.value_ptr.last_accessed_at;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.key);
                self.allocator.free(kv.value.value);
            }
        }
    }
};

test "MemoryStore remember and recall" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("user:pref:lang", "zh", 1, 42);
    try store.remember("user:pref:theme", "dark", 1, 42);
    try store.remember("user:pref:lang", "en", 2, 99); // different user

    var results = try store.recall(a, "user:pref", 1, 42);
    defer {
        for (results.items) |e| {
            a.free(e.key);
            a.free(e.value);
        }
        results.deinit(a);
    }

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
}

test "MemoryStore forget" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("test:key", "value", 0, 0);
    try std.testing.expectEqual(@as(usize, 1), store.count());

    store.forget("test:key");
    try std.testing.expectEqual(@as(usize, 0), store.count());
}

test "MemoryStore formatContext" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    defer store.deinit();

    try store.remember("user:fact:name", "Alice", 1, 1);
    try store.remember("user:fact:role", "admin", 1, 1);

    const ctx = try store.formatContext(a, "user:fact", 1, 1, 10);
    defer a.free(ctx);

    try std.testing.expect(std.mem.indexOf(u8, ctx, "Alice") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "admin") != null);
}

test "MemoryStore capacity eviction" {
    const a = std.testing.allocator;
    var store = MemoryStore.init(a, std.testing.io);
    store.max_entries = 3;
    defer store.deinit();

    try store.remember("k1", "v1", 0, 0);
    try store.remember("k2", "v2", 0, 0);
    try store.remember("k3", "v3", 0, 0);
    try store.remember("k4", "v4", 0, 0); // triggers eviction

    try std.testing.expect(store.count() <= 3);
}
