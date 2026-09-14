//! Rate limiters — token bucket, registry, sliding window.
//!
//! ## Thread safety
//!
//! All three types are safe to share across threads; each guards its mutable
//! state with an internal `Guard`. `tryAcquire` is called from request handlers,
//! and with a shared limiter (one global budget for the whole process) that is
//! genuinely concurrent — without the guard two threads racing on the last token
//! both see it and both admit, and `RateLimiterRegistry`'s map insert can tear
//! the backing storage.
//!
//! `Guard` is a short adaptive spinlock rather than a `std.Io.Mutex`: the
//! critical sections here are a map lookup or two float operations, and
//! `std.Io.Mutex.lock`/`unlock` need an `Io`, which would have to be threaded
//! through `init`, `tryAcquire`, `authRateLimitMiddleware` and
//! `RedisRateLimiter.allowWithFallback`. If profiling ever shows contention on
//! one shared limiter, the fix is to shard the limiter, not to re-lock it.

const std = @import("std");
const Time = @import("../core/Time.zig");

/// Minimal io-free mutual exclusion for the tiny critical sections in this file.
/// Spins briefly, then yields the time slice, so it degrades to polite waiting
/// instead of burning a core under sustained contention.
const Guard = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *Guard) void {
        var spins: u32 = 0;
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            spins += 1;
            if (spins < 32) {
                std.atomic.spinLoopHint();
            } else {
                // A failed yield is benign (we just retry the acquire), but it is
                // still an error — surface it at debug rather than swallowing it.
                std.Thread.yield() catch |err| std.log.debug("[RateLimiter] lock wait: yield failed ({s}), retrying", .{@errorName(err)});
            }
        }
    }

    fn unlock(self: *Guard) void {
        self.state.store(false, .release);
    }
};

/// Token bucket. `max_tokens` is the burst size, `refill_rate` the sustained
/// rate in tokens per second. Safe to share across threads.
pub const RateLimiter = struct {
    const Self = @This();

    guard: Guard = .{},
    allocator: std.mem.Allocator,
    name: []const u8,
    max_tokens: u32,
    refill_rate: u32, // tokens per second
    current_tokens: f64,
    last_refill_time: i64,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, max_tokens: u32, refill_rate: u32) !Self {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .max_tokens = max_tokens,
            .refill_rate = refill_rate,
            .current_tokens = @as(f64, @floatFromInt(max_tokens)),
            .last_refill_time = Time.monotonicNowSeconds(),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// Take one token if available. Denies rather than waiting.
    pub fn tryAcquire(self: *Self) bool {
        @branchHint(.likely);
        self.guard.lock();
        defer self.guard.unlock();
        return self.acquireLocked(1.0);
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

    guard: Guard = .{},
    allocator: std.mem.Allocator,
    limiters: std.StringHashMap(*RateLimiter),
    default_max_tokens: u32,
    default_refill_rate: u32,

    pub fn init(allocator: std.mem.Allocator, default_max_tokens: u32, default_refill_rate: u32) Self {
        return .{
            .allocator = allocator,
            .limiters = std.StringHashMap(*RateLimiter).init(allocator),
            .default_max_tokens = default_max_tokens,
            .default_refill_rate = default_refill_rate,
        };
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

        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);

        const limiter = try self.allocator.create(RateLimiter);
        errdefer self.allocator.destroy(limiter);
        limiter.* = try RateLimiter.init(self.allocator, name, max_tokens, refill_rate);
        errdefer limiter.deinit();

        try self.limiters.put(key, limiter);
        return limiter;
    }

    /// Pending: needs an allocPrint migration for Zig 0.17.
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        return allocator.dupe(u8, "generateReport (pending Zig 0.16 allocPrint migration)");
    }
};

/// Sliding window counter: at most `max_requests` in any `window_size_seconds`
/// interval. Safe to share across threads.
pub const SlidingWindowRateLimiter = struct {
    const Self = @This();

    guard: Guard = .{},
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
