const std = @import("std");
const Time = @import("../core/Time.zig");

/// One stored idempotency key entry
pub const IdempotencyEntry = struct {
    key: []const u8,
    response: []const u8,
    status_code: u16,
    created_at: i64,
    expires_at: i64,
};

/// Idempotency middleware configuration.
///
/// Lives on `IdempotencyStore.config` and is consumed by
/// `idempotencyMiddleware` (and the manual `wrapContextWithIdempotency`
/// placeholder path): `header_name` picks the request header carrying the
/// key and `ttl_seconds` decides how long a stored response is replayed.
/// `max_entries` duplicates the capacity already set through
/// `IdempotencyStore.init` — keep the two consistent when overriding it.
pub const IdempotencyConfig = struct {
    /// Default lifetime of an idempotency key (seconds)
    ttl_seconds: u64 = 24 * 60 * 60, // 24 hours
    /// Maximum number of entries kept in the store
    max_entries: usize = 100_000,
    /// Name of the HTTP header carrying the idempotency key
    /// (matched case-insensitively, RFC 9110)
    header_name: []const u8 = "Idempotency-Key",
};

/// Idempotency store
/// Can be swapped for a Redis / SQLite / Memory implementation
pub const IdempotencyStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    entries: std.StringHashMap(IdempotencyEntry),
    max_entries: usize,
    /// Middleware behavior consumed by `idempotencyMiddleware`: which request
    /// header carries the key (`header_name`) and how long stored entries stay
    /// replayable (`ttl_seconds`). Mutate before `addMiddleware`; defaults are
    /// the `Idempotency-Key` header and a 24 h TTL.
    config: IdempotencyConfig = .{},

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) Self {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap(IdempotencyEntry).init(allocator),
            .max_entries = max_entries,
            .config = .{},
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

    /// Stores the response produced for an idempotency key
    pub fn store(self: *Self, key: []const u8, response: []const u8, status_code: u16, ttl_seconds: u64) !void {
        const now = Time.monotonicNowSeconds();

        // Evict the oldest entry once the store is full
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

    /// Looks up an existing idempotency response
    pub fn get(self: *Self, key: []const u8) ?IdempotencyEntry {
        const entry_ptr = self.entries.getPtr(key) orelse return null;

        const now = Time.monotonicNowSeconds();
        if (now >= entry_ptr.expires_at) {
            // Expired — hold on to the owned pointers before removing the entry
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

    /// Checks whether the key exists and is not expired
    pub fn has(self: *Self, key: []const u8) bool {
        return self.get(key) != null;
    }

    /// Purges expired entries, returning how many were removed
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
/// Prevent duplicate processing of same request for write methods.
///
/// Usage:
///   var store = http.IdempotencyStore.init(allocator, 10_000);
///   try server.addMiddleware(http.idempotencyMiddleware(&store));
///
/// The client must send the configured header (default `Idempotency-Key`).
/// Behavior comes from `store.config` (`IdempotencyConfig`): set
/// `store.config.header_name` / `store.config.ttl_seconds` before
/// `addMiddleware` to override the header and the 24 h default lifetime.
pub fn idempotencyMiddleware(store: *IdempotencyStore) api.Middleware {
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const s: *IdempotencyStore = @ptrCast(@alignCast(user_data orelse return error.InternalError));
            const cfg = s.config;

            const method = ctx.method.toString();
            const is_write = std.mem.eql(u8, method, "POST") or
                std.mem.eql(u8, method, "PUT") or
                std.mem.eql(u8, method, "PATCH") or
                std.mem.eql(u8, method, "DELETE");

            if (!is_write) {
                try next(ctx);
                return;
            }

            const key = ctx.header(cfg.header_name) orelse {
                try next(ctx);
                return;
            };

            if (s.get(key)) |existing| {
                try ctx.json(existing.status_code, existing.response);
                return;
            }

            try next(ctx);

            if (ctx.responded and ctx.response_body.items.len > 0) {
                s.store(key, ctx.response_body.items, ctx.status_code, cfg.ttl_seconds) catch |err| {
                    std.log.warn("idempotency store failed: {s}", .{@errorName(err)});
                };
            }
        }
    };
    return .{ .func = S.handler, .user_data = @ptrCast(store) };
}

/// Extends the Context for the idempotency middleware so it can capture the response body.
///
/// Manual placeholder path, kept consistent with `idempotencyMiddleware`:
/// reads the key from `store.config.header_name` and stores the placeholder
/// with `store.config.ttl_seconds`. Pair with `recordIdempotencyResponse`
/// once the handler is done.
pub fn wrapContextWithIdempotency(ctx: *api.Context, store: *IdempotencyStore) !void {
    const key = ctx.header(store.config.header_name) orelse return;

    // Check the store first to avoid a race
    if (store.has(key)) return;

    // Store a placeholder marking the request as being processed
    _ = try store.store(key, "", 202, store.config.ttl_seconds);
}

/// Records the idempotency response (call once the handler is done).
/// Pass `store.config.ttl_seconds` to stay consistent with the middleware.
pub fn recordIdempotencyResponse(store: *IdempotencyStore, key: []const u8, response_body: []const u8, status_code: u16, ttl_seconds: u64) !void {
    // Drop the placeholder first — fetchRemove + free, because store() would
    // otherwise replace the entry without releasing the owned copies
    // (get() only removes expired entries, so it cannot do this drop).
    if (store.entries.fetchRemove(key)) |removed| {
        store.allocator.free(removed.key);
        store.allocator.free(removed.value.response);
    }
    // Then store the real response
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

// ─────────────────────────────────────────────────
// Middleware config wiring tests
// ─────────────────────────────────────────────────

/// Sequential test runner: plain counter for "did the business handler run".
var handler_calls: usize = 0;

fn countingHandler(ctx: *api.Context) anyerror!void {
    handler_calls += 1;
    try ctx.json(200, "{\"ran\":true}");
}

fn putRequestHeader(ctx: *api.Context, key: []const u8, value: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, key);
    errdefer ctx.allocator.free(k);
    const v = try ctx.allocator.dupe(u8, value);
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

test "idempotencyMiddleware default config replays on Idempotency-Key header" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();

    // Pin the defaults the regression guards: default header + 24 h TTL.
    try std.testing.expectEqualStrings("Idempotency-Key", (IdempotencyConfig{}).header_name);
    try std.testing.expectEqual(@as(u64, 24 * 60 * 60), (IdempotencyConfig{}).ttl_seconds);

    const mw = idempotencyMiddleware(&store);
    handler_calls = 0;

    var ctx1 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx1.deinit();
    try putRequestHeader(&ctx1, "idempotency-key", "k-default");
    try mw.func(&ctx1, countingHandler, mw.user_data);
    try std.testing.expectEqual(@as(usize, 1), handler_calls);
    try std.testing.expectEqualStrings("{\"ran\":true}", ctx1.response_body.items);

    // Replay: cached response is returned, the handler does not run again.
    var ctx2 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx2.deinit();
    try putRequestHeader(&ctx2, "idempotency-key", "k-default");
    try mw.func(&ctx2, countingHandler, mw.user_data);
    try std.testing.expectEqual(@as(usize, 1), handler_calls);
    try std.testing.expectEqualStrings("{\"ran\":true}", ctx2.response_body.items);
}

test "idempotencyMiddleware honors store.config.header_name" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();
    store.config = .{ .header_name = "x-req-key" };

    const mw = idempotencyMiddleware(&store);
    handler_calls = 0;

    // First request with the custom header runs the handler and gets stored.
    var ctx1 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx1.deinit();
    try putRequestHeader(&ctx1, "x-req-key", "k-custom");
    try mw.func(&ctx1, countingHandler, mw.user_data);
    try std.testing.expectEqual(@as(usize, 1), handler_calls);

    // Retry with the same custom header: replayed from the store.
    var ctx2 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx2.deinit();
    try putRequestHeader(&ctx2, "x-req-key", "k-custom");
    try mw.func(&ctx2, countingHandler, mw.user_data);
    try std.testing.expectEqual(@as(usize, 1), handler_calls);
    try std.testing.expectEqualStrings("{\"ran\":true}", ctx2.response_body.items);

    // Same key value under the DEFAULT header name is not consulted:
    // it falls through to the handler.
    var ctx3 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx3.deinit();
    try putRequestHeader(&ctx3, "idempotency-key", "k-custom");
    try mw.func(&ctx3, countingHandler, mw.user_data);
    try std.testing.expectEqual(@as(usize, 2), handler_calls);
}

test "idempotencyMiddleware honors store.config.ttl_seconds" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();
    store.config = .{ .ttl_seconds = 0 }; // entries expire immediately

    const mw = idempotencyMiddleware(&store);
    handler_calls = 0;

    var ctx1 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx1.deinit();
    try putRequestHeader(&ctx1, "idempotency-key", "k-ttl");
    try mw.func(&ctx1, countingHandler, mw.user_data);
    try std.testing.expectEqual(@as(usize, 1), handler_calls);

    // The stored entry is already expired, so the retry re-runs the handler
    // instead of replaying — proves cfg.ttl_seconds reaches the store path.
    var ctx2 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx2.deinit();
    try putRequestHeader(&ctx2, "idempotency-key", "k-ttl");
    try mw.func(&ctx2, countingHandler, mw.user_data);
    try std.testing.expectEqual(@as(usize, 2), handler_calls);
}

test "wrapContextWithIdempotency and recordIdempotencyResponse use store.config" {
    const allocator = std.testing.allocator;
    var store = IdempotencyStore.init(allocator, 100);
    defer store.deinit();
    store.config = .{ .header_name = "x-req-key", .ttl_seconds = 3600 };

    // No configured header → no placeholder.
    var ctx1 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx1.deinit();
    try wrapContextWithIdempotency(&ctx1, &store);
    try std.testing.expectEqual(@as(usize, 0), store.entries.count());

    // The default header name is ignored when a custom one is configured.
    var ctx2 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx2.deinit();
    try putRequestHeader(&ctx2, "idempotency-key", "k-wrap-default");
    try wrapContextWithIdempotency(&ctx2, &store);
    try std.testing.expect(!store.has("k-wrap-default"));

    // Custom header → placeholder stored, then replaced by the real response.
    var ctx3 = try api.Context.init(allocator, .POST, "/orders");
    defer ctx3.deinit();
    try putRequestHeader(&ctx3, "x-req-key", "k-wrap");
    try wrapContextWithIdempotency(&ctx3, &store);
    try std.testing.expect(store.has("k-wrap"));

    try recordIdempotencyResponse(&store, "k-wrap", "{\"ok\":true}", 201, store.config.ttl_seconds);
    const entry = store.get("k-wrap").?;
    try std.testing.expectEqualStrings("{\"ok\":true}", entry.response);
    try std.testing.expectEqual(@as(u16, 201), entry.status_code);
}
