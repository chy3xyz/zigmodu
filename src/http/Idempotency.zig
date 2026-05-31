const std = @import("std");
const Time = @import("../core/Time.zig");

/// Idempotency[...]
pub const IdempotencyEntry = struct {
    key: []const u8,
    response: []const u8,
    status_code: u16,
    created_at: i64,
    expires_at: i64,
};

/// Idempotency middleware[...]
pub const IdempotencyConfig = struct {
    /// Idempotency[...] ([...])
    ttl_seconds: u64 = 24 * 60 * 60, // 24 hours
    /// [...]
    max_entries: usize = 100_000,
    /// Idempotency[...] HTTP header [...]
    header_name: []const u8 = "Idempotency-Key",
};

/// Idempotency store[...]
/// [...] Redis / SQLite / Memory [...]
pub const IdempotencyStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(IdempotencyEntry),
    max_entries: usize,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(IdempotencyEntry).init(allocator),
            .max_entries = max_entries,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.response);
        }
        self.entries.deinit();
        self.* = undefined;
    }

    /// [...]Idempotency[...]
    pub fn store(self: *Self, key: []const u8, response: []const u8, status_code: u16, ttl_seconds: u64) !void {
        const now = Time.monotonicNowSeconds();

        // [...]
        if (self.entries.count() >= self.max_entries) {
            self.evictOldest();
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const resp_copy = try self.allocator.dupe(u8, response);
        errdefer self.allocator.free(resp_copy);

        try self.entries.put(key_copy, .{
            .key = key_copy,
            .response = resp_copy,
            .status_code = status_code,
            .created_at = now,
            .expires_at = now + @as(i64, @intCast(ttl_seconds)),
        });
    }

    /// [...]Idempotency[...]
    pub fn get(self: *Self, key: []const u8) ?IdempotencyEntry {
        const entry_ptr = self.entries.getPtr(key) orelse return null;

        const now = Time.monotonicNowSeconds();
        if (now >= entry_ptr.expires_at) {
            // [...] — [...]
            const owned_key = entry_ptr.key;
            const owned_resp = entry_ptr.response;
            _ = self.entries.remove(key);
            self.allocator.free(owned_key);
            self.allocator.free(owned_resp);
            return null;
        }

        return IdempotencyEntry{
            .key = entry_ptr.key,
            .response = entry_ptr.response,
            .status_code = entry_ptr.status_code,
            .created_at = entry_ptr.created_at,
            .expires_at = entry_ptr.expires_at,
        };
    }

    /// [...]IdempotencyWhether key exists and is not expired
    pub fn has(self: *Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// [...]
    pub fn purgeExpired(self: *Self) !usize {
        const now = Time.monotonicNowSeconds();
        var purged: usize = 0;

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (now >= entry.value_ptr.expires_at) {
                const owned_key = entry.value_ptr.key;
                const owned_resp = entry.value_ptr.response;
                _ = self.entries.remove(entry.key_ptr.*);
                self.allocator.free(owned_key);
                self.allocator.free(owned_resp);
                purged += 1;
            }
        }

        return purged;
    }

    fn evictOldest(self: *Self) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.created_at < oldest_time) {
                oldest_time = entry.value_ptr.created_at;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value.response);
            }
        }
    }
};

/// HTTP Idempotency middleware
/// Prevent duplicate processing of same request[...]for[...]
///
/// Usage:
///   server.addMiddleware(.{ .func = idempotencyMiddleware(&store) });
///
/// Client must send in request header `Idempotency-Key`
pub fn idempotencyMiddleware(store: *IdempotencyStore) api.MiddlewareFn {
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            _ = user_data;

            // [...]Idempotency
            const method = ctx.method.toString();
            const is_write = std.mem.eql(u8, method, "POST") or
                std.mem.eql(u8, method, "PUT") or
                std.mem.eql(u8, method, "PATCH") or
                std.mem.eql(u8, method, "DELETE");

            if (!is_write) {
                try next(ctx, next, null);
                return;
            }

            // [...]Idempotency[...]
            const key = ctx.header("Idempotency-Key") orelse {
                // [...]Idempotency[...]Non-critical ops can be omitted[...]
                try next(ctx, next, null);
                return;
            };

            // Check if[...]
            if (store.get(key)) |existing| {
                // Idempotency[...]
                try ctx.json(existing.status_code, existing.response);
                return;
            }

            // [...]
            try next(ctx, next, null);

            // [...]——Actual impl needs to intercept response body[...]
            // [...] ctx [...]
        }
    };
    return S.handler;
}

/// [...]Idempotency middleware[...] Context[...]
pub fn wrapContextWithIdempotency(ctx: *api.Context, store: *IdempotencyStore, ttl_seconds: u64) !void {
    const key = ctx.header("Idempotency-Key") orelse return;

    // [...]
    if (store.has(key)) return;

    // [...]Indicates request is being processed
    _ = try store.store(key, "", 202, ttl_seconds);
}

/// [...]Idempotency[...] ([...] handler done[...]call)
pub fn recordIdempotencyResponse(store: *IdempotencyStore, key: []const u8, response_body: []const u8, status_code: u16, ttl_seconds: u64) !void {
    // [...]
    _ = store.get(key);
    // [...]
    try store.store(key, response_body, status_code, ttl_seconds);
}

const api = @import("../api/Server.zig");

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "IdempotencyStore store and get" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();

    try store.store("key-001", "{\"result\":\"ok\"}", 200, 3600);

    const entry = store.get("key-001").?;
    try std.testing.expectEqualStrings("{\"result\":\"ok\"}", entry.response);
    try std.testing.expectEqual(@as(u16, 200), entry.status_code);
}

test "IdempotencyStore expired entry returns null" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();

    // Store with 0 TTL (immediately expired)
    try store.store("key-ephemeral", "data", 200, 0);

    const entry = store.get("key-ephemeral");
    try std.testing.expect(entry == null);
}

test "IdempotencyStore purge expired" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();

    try store.store("key-purge", "data", 200, 0);
    try store.store("key-valid", "data2", 200, 3600);

    const purged = try store.purgeExpired();
    try std.testing.expect(purged >= 1);
    try std.testing.expect(store.has("key-valid"));
    try std.testing.expect(!store.has("key-purge"));
}

test "IdempotencyStore eviction under max" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 3);
    defer store.deinit();

    try store.store("k1", "v1", 200, 3600);
    try store.store("k2", "v2", 200, 3600);
    try store.store("k3", "v3", 200, 3600);
    try store.store("k4", "v4", 200, 3600);

    // k1 should have been evicted (oldest)
    try std.testing.expect(!store.has("k1"));
    try std.testing.expect(store.has("k4"));
}

test "IdempotencyStore has" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();

    try std.testing.expect(!store.has("nonexistent"));
    try store.store("exists", "v", 200, 3600);
    try std.testing.expect(store.has("exists"));
}
