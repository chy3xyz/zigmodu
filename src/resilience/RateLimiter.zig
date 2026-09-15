//! Rate limiters — token bucket, registry, sliding window.
//!
//! ## Thread safety
//!
//! All three types are safe to share across threads; each guards its mutable
//! state with an internal `SpinLock` (`core/SpinLock.zig`, with the reasoning for
//! a spinlock over `std.Io.Mutex`). That matters because `tryAcquire` runs on
//! request handlers: with a shared limiter (one global budget for the process)
//! two threads racing on the last token both see it and both admit, and
//! `RateLimiterRegistry`'s map insert can tear the backing storage.

const std = @import("std");
const Time = @import("../core/Time.zig");
const SpinLock = @import("../core/SpinLock.zig").SpinLock;

/// Token bucket. `max_tokens` is the burst size, `refill_rate` the sustained
/// rate in tokens per second. Safe to share across threads.
pub const RateLimiter = struct {
    const Self = @This();

    guard: SpinLock = .{},
    allocator: std.mem.Allocator,
    name: []const u8,
    max_tokens: u32,
    refill_rate: u32, // tokens per second
    current_tokens: f64,
    last_refill_time: i64,
    /// Monotonic seconds of the last successful acquire, for
    /// `RateLimiterRegistry`'s idle sweep. Atomic so a sweep can read it without
    /// taking this limiter's guard.
    last_used_at: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn init(allocator: std.mem.Allocator, name: []const u8, max_tokens: u32, refill_rate: u32) !Self {
        const now = Time.monotonicNowSeconds();
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .current_tokens = @as(f64, @floatFromInt(max_tokens)),
            .last_refill_time = now,
            .last_used_at = std.atomic.Value(i64).init(now),
        };
    }

    /// Monotonic seconds of the last successful acquire (creation time until
    /// then). 0 only for a value that was never `init`ed.
    pub fn lastUsedAt(self: *const Self) i64 {
        return self.last_used_at.load(.monotonic);
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// Take one token if available. Denies rather than waiting.
    pub fn tryAcquire(self: *Self) bool {
        @branchHint(.likely);
        const allowed = blk: {
            self.guard.lock();
            defer self.guard.unlock();
            break :blk self.acquireLocked(1.0);
        };
        if (allowed) self.last_used_at.store(Time.monotonicNowSeconds(), .monotonic);
        return allowed;
    }

    /// Acquire a token, waiting if unavailable.
    /// DEPRECATED: identical to `tryAcquire` — the wait it once implied is not
    /// available in a sync context. Use `tryAcquire` and shed the request.
    pub fn acquire(self: *Self) bool {
        return self.tryAcquire();
    }

    /// Take `count` tokens if all are available (all-or-nothing).
    pub fn tryAcquireMany(self: *Self, count: u32) bool {
        if (count == 0) return true;
        self.guard.lock();
        defer self.guard.unlock();
        return self.acquireLocked(@floatFromInt(count));
    }

    /// Refund one token (e.g. the request failed before doing the work it was
    /// reserved for). Capped at `max_tokens`.
    pub fn release(self: *Self) void {
        self.guard.lock();
        defer self.guard.unlock();
        self.refillLocked();
        self.current_tokens = @min(@as(f64, @floatFromInt(self.max_tokens)), self.current_tokens + 1.0);
    }

    /// Tokens available right now, after accounting for elapsed refill.
    pub fn availableTokens(self: *Self) u32 {
        self.guard.lock();
        defer self.guard.unlock();
        self.refillLocked();
        return @intFromFloat(self.current_tokens);
    }

    /// Restore the bucket to full.
    pub fn reset(self: *Self) void {
        self.guard.lock();
        defer self.guard.unlock();
        self.current_tokens = @as(f64, @floatFromInt(self.max_tokens));
        self.last_refill_time = Time.monotonicNowSeconds();
    }

    pub fn getStats(self: *Self) Stats {
        self.guard.lock();
        defer self.guard.unlock();
        self.refillLocked();
        return .{
            .name = self.name,
            .max_tokens = self.max_tokens,
            .refill_rate = self.refill_rate,
            .available_tokens = @intFromFloat(self.current_tokens),
        };
    }

    pub const Stats = struct {
        name: []const u8,
        max_tokens: u32,
        refill_rate: u32,
        available_tokens: u32,
    };

    /// Caller holds the guard.
    fn acquireLocked(self: *Self, count: f64) bool {
        self.refillLocked();
        if (self.current_tokens >= count) {
            self.current_tokens -= count;
            return true;
        }
        return false;
    }

    /// Caller holds the guard. Uses the cached timestamp — the refill rate is
    /// per second, so ~1s of staleness is within the limiter's own resolution.
    fn refillLocked(self: *Self) void {
        const now = Time.cachedNowSeconds();
        const elapsed = now - self.last_refill_time;
        if (elapsed > 0) {
            const tokens_to_add = @as(f64, @floatFromInt(self.refill_rate)) * @as(f64, @floatFromInt(elapsed));
            self.current_tokens = @min(@as(f64, @floatFromInt(self.max_tokens)), self.current_tokens + tokens_to_add);
            self.last_refill_time = now;
        }
    }
};

/// Per-key `RateLimiter` pool (per user, per IP, per route).
///
/// Limiters are heap-allocated and the map holds pointers, so a `*RateLimiter`
/// returned by `getOrCreate*` stays valid for the life of the registry — it is
/// *not* invalidated by a later insert. (Storing limiters by value instead would
/// move them on rehash and hand callers dangling pointers.) Safe to share across
/// threads.
pub const RateLimiterRegistry = struct {
    const Self = @This();

    guard: SpinLock = .{},
    allocator: std.mem.Allocator,
    limiters: std.StringHashMap(*RateLimiter),
    default_max_tokens: u32,
    default_refill_rate: u32,
    /// Upper bound on tracked limiters. 0 = unbounded (previous behaviour).
    ///
    /// Per-client limiters are keyed by attacker-controlled input (IP, user id),
    /// so an unbounded registry grows for as long as someone keeps sending new
    /// keys — a memory-growth vector, not a style question. At `max_keys` the
    /// least-recently-used limiter is evicted on insert (its budget resets if it
    /// comes back, which under eviction pressure is the intended trade).
    max_keys: usize = 0,

    pub fn init(allocator: std.mem.Allocator, default_max_tokens: u32, default_refill_rate: u32) Self {
        return .{
            .allocator = allocator,
            .limiters = std.StringHashMap(*RateLimiter).init(allocator),
            .default_max_tokens = default_max_tokens,
            .default_refill_rate = default_refill_rate,
        };
    }

    /// `init` plus a hard cap on tracked keys. See `max_keys`.
    pub fn initWithCapacity(
        allocator: std.mem.Allocator,
        default_max_tokens: u32,
        default_refill_rate: u32,
        max_keys: usize,
    ) Self {
        var self = Self.init(allocator, default_max_tokens, default_refill_rate);
        self.max_keys = max_keys;
        return self;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.limiters.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.limiters.deinit();
        self.* = undefined;
    }

    /// Limiter for `name`, created with the registry defaults on first use.
    pub fn getOrCreate(self: *Self, name: []const u8) !*RateLimiter {
        return self.getOrCreateWith(name, self.default_max_tokens, self.default_refill_rate);
    }

    /// Limiter for `name`, created with explicit limits on first use.
    pub fn getOrCreateForClient(self: *Self, client_id: []const u8, max_tokens: u32, refill_rate: u32) !*RateLimiter {
        return self.getOrCreateWith(client_id, max_tokens, refill_rate);
    }

    /// Existing limiter, or null. The returned pointer outlives later inserts.
    pub fn get(self: *Self, name: []const u8) ?*RateLimiter {
        self.guard.lock();
        defer self.guard.unlock();
        return self.limiters.get(name);
    }

    /// Drop `name`'s limiter (e.g. on logout, so the next session starts with a
    /// full budget). No-op when absent. Returns whether an entry was removed.
    pub fn remove(self: *Self, name: []const u8) bool {
        self.guard.lock();
        defer self.guard.unlock();
        return self.removeLocked(name);
    }

    /// Drop every limiter idle for more than `max_idle_seconds`. Call from a
    /// periodic tick. The clock is coarse (1s), so `0` reclaims what has been
    /// untouched for a full second — never an entry used in the current second.
    pub fn retain(self: *Self, max_idle_seconds: i64) usize {
        self.guard.lock();
        defer self.guard.unlock();

        const now = Time.monotonicNowSeconds();
        var evicted: usize = 0;
        var it = self.limiters.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.*.lastUsedAt() > max_idle_seconds) {
                const doomed = entry.key_ptr.*;
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
                _ = self.limiters.remove(doomed);
                self.allocator.free(doomed);
                evicted += 1;
            }
        }
        return evicted;
    }

    /// Number of tracked limiters.
    pub fn count(self: *Self) usize {
        self.guard.lock();
        defer self.guard.unlock();
        return self.limiters.count();
    }

    fn getOrCreateWith(self: *Self, name: []const u8, max_tokens: u32, refill_rate: u32) !*RateLimiter {
        self.guard.lock();
        defer self.guard.unlock();

        if (self.limiters.get(name)) |existing| return existing;

        if (self.max_keys > 0 and self.limiters.count() >= self.max_keys) {
            try self.evictLeastRecentlyUsedLocked();
        }

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);

        const limiter = try self.allocator.create(RateLimiter);
        errdefer self.allocator.destroy(limiter);
        limiter.* = try RateLimiter.init(self.allocator, name, max_tokens, refill_rate);
        errdefer limiter.deinit();

        try self.limiters.put(key, limiter);
        return limiter;
    }

    /// Caller holds the guard.
    fn removeLocked(self: *Self, name: []const u8) bool {
        const entry = self.limiters.fetchRemove(name) orelse return false;
        self.allocator.free(entry.key);
        entry.value.deinit();
        self.allocator.destroy(entry.value);
        return true;
    }

    /// Caller holds the guard. Drops the entry whose `last_used_at` is oldest —
    /// the client least likely to notice its budget resetting.
    fn evictLeastRecentlyUsedLocked(self: *Self) !void {
        var oldest_name: ?[]const u8 = null;
        var oldest_at: i64 = std.math.maxInt(i64);
        var it = self.limiters.iterator();
        while (it.next()) |entry| {
            const used = entry.value_ptr.*.lastUsedAt();
            if (used < oldest_at) {
                oldest_at = used;
                oldest_name = entry.key_ptr.*;
            }
        }
        const victim = oldest_name orelse return;
        _ = self.removeLocked(victim);
    }

    /// JSON snapshot of every tracked limiter — for an admin/debug endpoint.
    /// Caller frees.
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        const Entry = struct {
            name: []const u8,
            max_tokens: u32,
            refill_rate: u32,
            available_tokens: u32,
            last_used_at: i64,
        };

        self.guard.lock();
        defer self.guard.unlock();

        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(allocator);

        var it = self.limiters.iterator();
        while (it.next()) |kv| {
            const limiter = kv.value_ptr.*;
            try entries.append(allocator, .{
                .name = limiter.name,
                .max_tokens = limiter.max_tokens,
                .refill_rate = limiter.refill_rate,
                // Reading a peer's counters needs its own guard.
                .available_tokens = limiter.availableTokens(),
                .last_used_at = limiter.lastUsedAt(),
            });
        }
        return std.json.Stringify.valueAlloc(allocator, entries.items, .{});
    }
};

/// Sliding window counter: at most `max_requests` in any `window_size_seconds`
/// interval. Safe to share across threads.
pub const SlidingWindowRateLimiter = struct {
    const Self = @This();

    guard: SpinLock = .{},
    allocator: std.mem.Allocator,
    name: []const u8,
    window_size_seconds: u64,
    max_requests: u32,
    requests: std.array_list.Managed(i64), // Request timestamp list

    pub fn init(allocator: std.mem.Allocator, name: []const u8, window_size_seconds: u64, max_requests: u32) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .window_size_seconds = window_size_seconds,
            .max_requests = max_requests,
            .requests = std.array_list.Managed(i64).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.requests.deinit();
        self.* = undefined;
    }

    /// Record a request if the window has room. Denies rather than waiting.
    pub fn tryAcquire(self: *Self) bool {
        self.guard.lock();
        defer self.guard.unlock();

        self.cleanupLocked();
        if (self.requests.items.len < self.max_requests) {
            self.requests.append(Time.monotonicNowSeconds()) catch return false;
            return true;
        }
        return false;
    }

    /// Requests currently inside the window.
    pub fn currentCount(self: *Self) usize {
        self.guard.lock();
        defer self.guard.unlock();
        self.cleanupLocked();
        return self.requests.items.len;
    }

    /// Caller holds the guard. Drops timestamps older than the window.
    fn cleanupLocked(self: *Self) void {
        const now = Time.cachedNowSeconds();
        const cutoff = now - @as(i64, @intCast(self.window_size_seconds));

        var i: usize = 0;
        while (i < self.requests.items.len) {
            if (self.requests.items[i] < cutoff) {
                _ = self.requests.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "RateLimiter token bucket" {
    const allocator = std.testing.allocator;
    var limiter = try RateLimiter.init(allocator, "api", 3, 1);
    defer limiter.deinit();

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire()); // exhausted
}

test "RateLimiter burst and refill" {
    const allocator = std.testing.allocator;
    var limiter = try RateLimiter.init(allocator, "burst", 5, 1); // 5 tokens, refill 1/sec
    defer limiter.deinit();

    // Burst: consume all 5 tokens rapidly
    var allowed: u32 = 0;
    for (0..10) |_| {
        if (limiter.tryAcquire()) allowed += 1;
    }
    try std.testing.expectEqual(@as(u32, 5), allowed); // exactly 5 allowed

    // After burst, no more tokens available
    try std.testing.expect(!limiter.tryAcquire());
    try std.testing.expectEqual(@as(u32, 0), limiter.availableTokens());
}

test "RateLimiterRegistry" {
    const allocator = std.testing.allocator;
    var registry = RateLimiterRegistry.init(allocator, 5, 10);
    defer registry.deinit();

    const limiter = try registry.getOrCreate("user");
    try std.testing.expectEqualStrings("user", limiter.name);
    try std.testing.expect(registry.get("user") != null);
}

test "RateLimiterRegistry keeps pointers valid across inserts" {
    const allocator = std.testing.allocator;
    var registry = RateLimiterRegistry.init(allocator, 5, 10);
    defer registry.deinit();

    const first = try registry.getOrCreate("a");
    // Force the map to grow well past its initial capacity: a by-value map would
    // rehash here and leave `first` dangling.
    for (0..256) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "key-{d}", .{i});
        _ = try registry.getOrCreate(key);
    }
    try std.testing.expect(first == try registry.getOrCreate("a"));
    try std.testing.expectEqual(@as(usize, 257), registry.count());
    first.reset();
    try std.testing.expect(first.tryAcquire());
}

test "SlidingWindowRateLimiter" {
    const allocator = std.testing.allocator;
    var limiter = try SlidingWindowRateLimiter.init(allocator, "window", 1, 2);
    defer limiter.deinit();

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire()); // limit reached
    try std.testing.expectEqual(@as(usize, 2), limiter.currentCount());
}

test "concurrent tryAcquire admits exactly the bucket size" {
    // The lost-update test: `refill_rate = 0` means no token can appear, so the
    // number of admissions is exactly `max_tokens` no matter how the threads
    // interleave. An unsynchronised read-modify-write on `current_tokens` lets
    // two threads spend the same token and over-admit.
    const allocator = std.testing.allocator;
    const max_tokens: u32 = 100;
    const threads_n: usize = 32;
    const attempts_per_thread: usize = 40;

    var limiter = try RateLimiter.init(allocator, "concurrent", max_tokens, 0);
    defer limiter.deinit();

    const Counter = struct {
        var admitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
        fn run(l: *RateLimiter) void {
            for (0..attempts_per_thread) |_| {
                if (l.tryAcquire()) _ = admitted.fetchAdd(1, .monotonic);
            }
        }
    };
    Counter.admitted.store(0, .monotonic);

    const threads = try allocator.alloc(std.Thread, threads_n);
    defer allocator.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Counter.run, .{&limiter});
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, max_tokens), Counter.admitted.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), limiter.availableTokens());
}

test "concurrent getOrCreate yields one limiter per key" {
    const allocator = std.testing.allocator;
    const threads_n: usize = 32;
    const keys_n: usize = 16;

    var registry = RateLimiterRegistry.init(allocator, 10, 0);
    defer registry.deinit();

    const Worker = struct {
        var seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
        fn run(reg: *RateLimiterRegistry) void {
            var buf: [16]u8 = undefined;
            for (0..keys_n) |i| {
                const key = std.fmt.bufPrint(&buf, "k-{d}", .{i}) catch return;
                const limiter = reg.getOrCreate(key) catch return;
                // Every caller must get the same object, and a usable one.
                if (limiter.tryAcquire()) _ = seen.fetchAdd(1, .monotonic);
            }
        }
    };
    Worker.seen.store(0, .monotonic);

    const threads = try allocator.alloc(std.Thread, threads_n);
    defer allocator.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&registry});
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(usize, keys_n), registry.count());
    // 32 threads × 16 keys, 10 tokens each: admissions are capped per key.
    try std.testing.expectEqual(@as(u64, @as(u64, keys_n) * 10), Worker.seen.load(.monotonic));
}

test "registry max_keys bounds growth for per-client limiters" {
    // Per-client keys come from the request (IP, user id). Without a bound the
    // registry only grows, so a client that keeps inventing keys is a
    // memory-growth vector — this pins that `max_keys` actually holds.
    const allocator = std.testing.allocator;
    var registry = RateLimiterRegistry.initWithCapacity(allocator, 5, 0, 3);
    defer registry.deinit();

    for (0..50) |i| {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "client-{d}", .{i});
        _ = try registry.getOrCreateForClient(key, 5, 0);
    }
    try std.testing.expectEqual(@as(usize, 3), registry.count());

    // Re-reading a survivor must not create a second entry.
    const again = try registry.getOrCreateForClient("client-49", 5, 0);
    try std.testing.expect(again == (registry.get("client-49")).?);
    try std.testing.expectEqual(@as(usize, 3), registry.count());
}

test "registry evicts the least recently used limiter" {
    const allocator = std.testing.allocator;
    var registry = RateLimiterRegistry.initWithCapacity(allocator, 10, 0, 2);
    defer registry.deinit();

    const old = try registry.getOrCreate("old");
    const fresh = try registry.getOrCreate("fresh");
    // Make `old` strictly older than `fresh` before the third insert.
    _ = old.tryAcquire();
    _ = fresh.tryAcquire();
    _ = fresh.tryAcquire();

    _ = try registry.getOrCreate("newcomer");

    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expect(registry.get("newcomer") != null);
    // The two most recently used survive; `old` is the victim.
    try std.testing.expect(registry.get("fresh") != null);
    try std.testing.expect(registry.get("old") == null);
}

test "registry remove and retain reclaim entries" {
    const allocator = std.testing.allocator;
    var registry = RateLimiterRegistry.init(allocator, 5, 0);
    defer registry.deinit();

    _ = try registry.getOrCreate("a");
    _ = try registry.getOrCreate("b");
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    // Explicit removal (e.g. on logout) frees the key and the limiter.
    try std.testing.expect(registry.remove("a"));
    try std.testing.expect(!registry.remove("a")); // idempotent
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    // …and the key can come back with a fresh budget.
    const readded = try registry.getOrCreate("a");
    try std.testing.expectEqualStrings("a", readded.name);

    // Both entries were created in the current second, so a 0-second window
    // keeps them: `retain(0)` drops only what has been idle for a full second.
    try std.testing.expectEqual(@as(usize, 0), registry.retain(0));
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    // Backdate one entry instead of waiting on the wall clock: the sweep reads
    // `last_used_at`, so this is the same code path a real idle limiter takes,
    // minus a second of test time.
    registry.get("a").?.last_used_at.store(Time.monotonicNowSeconds() - 100, .monotonic);
    try std.testing.expectEqual(@as(usize, 1), registry.retain(0));
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.get("a") == null);
    try std.testing.expect(registry.get("b") != null);

    // A generous window keeps freshly-used limiters.
    _ = try registry.getOrCreate("c");
    try std.testing.expectEqual(@as(usize, 0), registry.retain(3600));
    try std.testing.expectEqual(@as(usize, 2), registry.count());
}

test "registry.max_keys = 0 keeps the unbounded behaviour" {
    const allocator = std.testing.allocator;
    var registry = RateLimiterRegistry.init(allocator, 5, 0);
    defer registry.deinit();

    for (0..20) |i| {
        var buf: [16]u8 = undefined;
        _ = try registry.getOrCreate(try std.fmt.bufPrint(&buf, "k{d}", .{i}));
    }
    try std.testing.expectEqual(@as(usize, 20), registry.count());
}
