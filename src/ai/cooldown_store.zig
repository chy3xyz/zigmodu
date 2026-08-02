//! Cooldown store — pluggable shared state for `KeyPool` key rotation.
//!
//! `KeyPool` routes cooldown/failure/ban state through a `CooldownStore` so
//! multiple processes sharing the same API keys coordinate:
//!   - `MemoryCooldownStore` — default, in-process (monotonic clock);
//!   - `RedisCooldownStore` — cross-process via Redis SET EX / INCR / EXPIRE /
//!     DEL, with a local mirror and **fail-open** fallback (Redis down →
//!     degrade to local state + warn, mirroring `RedisRateLimiter`).
//!
//! Store keys are opaque strings; `KeyPool` composes `<provider>:<key_index>`.

const std = @import("std");
const Time = @import("../core/Time.zig");
const redis_mod = @import("../redis/redis.zig");

pub const CooldownStore = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        isCooling: *const fn (ctx: *anyopaque, key: []const u8) bool,
        cool: *const fn (ctx: *anyopaque, key: []const u8, ttl_ms: i64) void,
        bumpFailures: *const fn (ctx: *anyopaque, key: []const u8) u32,
        reset: *const fn (ctx: *anyopaque, key: []const u8) void,
    };

    pub fn isCooling(self: CooldownStore, key: []const u8) bool {
        return self.vtable.isCooling(self.ctx, key);
    }

    pub fn cool(self: CooldownStore, key: []const u8, ttl_ms: i64) void {
        self.vtable.cool(self.ctx, key, ttl_ms);
    }

    pub fn bumpFailures(self: CooldownStore, key: []const u8) u32 {
        return self.vtable.bumpFailures(self.ctx, key);
    }

    pub fn reset(self: CooldownStore, key: []const u8) void {
        self.vtable.reset(self.ctx, key);
    }
};

// ── in-process store ──────────────────────────────────────────────────────

pub const MemoryCooldownStore = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    cooling: std.StringHashMap(i64),
    failures: std.StringHashMap(u32),
    mutex: std.Io.Mutex,
    now_fn: *const fn () i64 = Time.monotonicNowMilliseconds,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return initWithOptions(allocator, io, .{});
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, io: std.Io, opts: Options) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .cooling = std.StringHashMap(i64).init(allocator),
            .failures = std.StringHashMap(u32).init(allocator),
            .mutex = std.Io.Mutex.init,
            .now_fn = opts.now_fn,
        };
    }

    pub fn deinit(self: *Self) void {
        var cit = self.cooling.iterator();
        while (cit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.cooling.deinit();
        var fit = self.failures.iterator();
        while (fit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.failures.deinit();
        self.* = undefined;
    }

    pub fn asStore(self: *Self) CooldownStore {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = CooldownStore.VTable{
        .isCooling = isCoolingFn,
        .cool = coolFn,
        .bumpFailures = bumpFailuresFn,
        .reset = resetFn,
    };

    fn selfOf(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    fn isCoolingFn(ctx: *anyopaque, key: []const u8) bool {
        const self = selfOf(ctx);
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const until = self.cooling.get(key) orelse return false;
        return until > self.now_fn();
    }

    fn coolFn(ctx: *anyopaque, key: []const u8, ttl_ms: i64) void {
        const self = selfOf(ctx);
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        // ArrayHashMap stores keys by reference — own a copy on insert.
        if (self.cooling.getPtr(key)) |until| {
            until.* = self.now_fn() + ttl_ms;
        } else {
            const owned = self.allocator.dupe(u8, key) catch return;
            self.cooling.put(owned, self.now_fn() + ttl_ms) catch {
                self.allocator.free(owned);
            };
        }
    }

    fn bumpFailuresFn(ctx: *anyopaque, key: []const u8) u32 {
        const self = selfOf(ctx);
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        const count = (self.failures.get(key) orelse 0) + 1;
        if (self.failures.getPtr(key)) |c| {
            c.* = count;
        } else {
            const owned = self.allocator.dupe(u8, key) catch return count;
            self.failures.put(owned, count) catch {
                self.allocator.free(owned);
            };
        }
        return count;
    }

    fn resetFn(ctx: *anyopaque, key: []const u8) void {
        const self = selfOf(ctx);
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        if (self.cooling.fetchRemove(key)) |kv| self.allocator.free(kv.key);
        if (self.failures.fetchRemove(key)) |kv| self.allocator.free(kv.key);
    }

    pub const Options = struct {
        now_fn: *const fn () i64 = Time.monotonicNowMilliseconds,
    };
};

// ── Redis-backed store (cross-process, fail-open) ─────────────────────────

pub const RedisCooldownStore = struct {
    const Self = @This();
    const key_prefix = "zigmodu:llm:key:";

    allocator: std.mem.Allocator,
    io: std.Io,
    redis: *redis_mod.Redis,
    mutex: std.Io.Mutex,
    // Local mirror for fail-open (Redis down → serve/record locally).
    mirror_cooling: std.StringHashMap(i64),
    mirror_failures: std.StringHashMap(u32),
    now_fn: *const fn () i64 = Time.monotonicNowMilliseconds,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, redis: *redis_mod.Redis) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .redis = redis,
            .mutex = std.Io.Mutex.init,
            .mirror_cooling = std.StringHashMap(i64).init(allocator),
            .mirror_failures = std.StringHashMap(u32).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var cit = self.mirror_cooling.iterator();
        while (cit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.mirror_cooling.deinit();
        var fit = self.mirror_failures.iterator();
        while (fit.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.mirror_failures.deinit();
        self.* = undefined;
    }

    pub fn asStore(self: *Self) CooldownStore {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable = CooldownStore.VTable{
        .isCooling = isCoolingFn,
        .cool = coolFn,
        .bumpFailures = bumpFailuresFn,
        .reset = resetFn,
    };

    fn selfOf(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    /// Full Redis key for a logical store key.
    fn redisKey(buf: *[128]u8, key: []const u8) []const u8 {
        const n = std.fmt.bufPrint(buf, "{s}{s}", .{ key_prefix, key }) catch return key;
        return buf[0..n.len];
    }

    /// Failure-counter key — separate from the cooldown marker so `SET` in
    /// cool() never overwrites the `INCR` counter (and vice versa).
    fn failKey(buf: *[128]u8, key: []const u8) []const u8 {
        const n = std.fmt.bufPrint(buf, "{s}{s}:fail", .{ key_prefix, key }) catch return key;
        return buf[0..n.len];
    }

    fn isCoolingFn(ctx: *anyopaque, key: []const u8) bool {
        const self = selfOf(ctx);
        var kbuf: [128]u8 = undefined;
        const rkey = redisKey(&kbuf, key);
        // Redis is authoritative; fall back to the local mirror on failure.
        if (self.redis.get(rkey)) |v| {
            return v != null;
        } else |_| {
            self.mutex.lock(self.io) catch return false;
            defer self.mutex.unlock(self.io);
            const until = self.mirror_cooling.get(key) orelse return false;
            return until > self.now_fn();
        }
    }

    fn coolFn(ctx: *anyopaque, key: []const u8, ttl_ms: i64) void {
        const self = selfOf(ctx);
        self.mutex.lock(self.io) catch return;
        if (self.mirror_cooling.getPtr(key)) |until| {
            until.* = self.now_fn() + ttl_ms;
        } else {
            _ = self.mirror_cooling.put(self.allocator, self.allocator.dupe(u8, key) catch return, self.now_fn() + ttl_ms) catch {};
        }
        self.mutex.unlock(self.io);

        var kbuf: [128]u8 = undefined;
        const rkey = redisKey(&kbuf, key);
        const ttl_sec: u32 = @intCast(@max((ttl_ms + 999) / 1000, 1));
        self.redis.set(rkey, "1", ttl_sec) catch |err| {
            std.log.warn("[RedisCooldownStore] set failed ({}), using local cooldown for '{s}'", .{ err, key });
        };
    }

    fn bumpFailuresFn(ctx: *anyopaque, key: []const u8) u32 {
        const self = selfOf(ctx);
        self.mutex.lock(self.io) catch return 0;
        const count = (self.mirror_failures.get(key) orelse 0) + 1;
        if (self.mirror_failures.getPtr(key)) |c| {
            c.* = count;
        } else {
            _ = self.mirror_failures.put(self.allocator, self.allocator.dupe(u8, key) catch return count, count) catch {};
        }
        self.mutex.unlock(self.io);

        var kbuf: [128]u8 = undefined;
        const fkey = failKey(&kbuf, key);
        if (self.redis.incr(fkey)) |n| {
            self.redis.expire(fkey, 3600) catch {};
            return @intCast(@max(n, 0));
        } else |err| {
            std.log.warn("[RedisCooldownStore] incr failed ({}), using local count {d} for '{s}'", .{ err, count, key });
            return count;
        }
    }

    fn resetFn(ctx: *anyopaque, key: []const u8) void {
        const self = selfOf(ctx);
        self.mutex.lock(self.io) catch return;
        if (self.mirror_cooling.fetchRemove(key)) |kv| self.allocator.free(kv.key);
        if (self.mirror_failures.fetchRemove(key)) |kv| self.allocator.free(kv.key);
        self.mutex.unlock(self.io);

        var kbuf: [128]u8 = undefined;
        const rkey = redisKey(&kbuf, key);
        var fbuf: [128]u8 = undefined;
        const fkey = failKey(&fbuf, key);
        self.redis.del(&.{ rkey, fkey }) catch |err| {
            std.log.warn("[RedisCooldownStore] del failed ({}), mirror cleared for '{s}'", .{ err, key });
        };
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

var fake_now: i64 = 1_000_000;
fn fakeNow() i64 {
    return fake_now;
}

test "memory cooldown store cool/expire/reset + failures" {
    const allocator = std.testing.allocator;
    var store = MemoryCooldownStore.initWithOptions(allocator, std.testing.io, .{ .now_fn = fakeNow });
    defer store.deinit();
    const s = store.asStore();

    try std.testing.expect(!s.isCooling("p:0"));
    s.cool("p:0", 1_000);
    try std.testing.expect(s.isCooling("p:0"));
    fake_now += 1_000;
    try std.testing.expect(!s.isCooling("p:0"));

    try std.testing.expectEqual(@as(u32, 1), s.bumpFailures("p:0"));
    try std.testing.expectEqual(@as(u32, 2), s.bumpFailures("p:0"));
    s.reset("p:0");
    try std.testing.expectEqual(@as(u32, 1), s.bumpFailures("p:0"));
    try std.testing.expect(!s.isCooling("p:0"));
}

test "memory store two-key cooldown sequence" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var store = MemoryCooldownStore.initWithOptions(allocator, std.testing.io, .{ .now_fn = fakeNow });
    defer store.deinit();
    const s = store.asStore();

    s.cool("t:0", 1_000);
    try std.testing.expect(s.isCooling("t:0"));
    try std.testing.expect(!s.isCooling("t:1"));
    s.cool("t:1", 1_000);
    try std.testing.expect(s.isCooling("t:1"));
    fake_now += 1_000;
    try std.testing.expect(!s.isCooling("t:0"));
    try std.testing.expect(!s.isCooling("t:1"));
}

test "redis cooldown store builds and formats keys" {
    var buf: [128]u8 = undefined;
    const k = RedisCooldownStore.redisKey(&buf, "deepseek:3");
    try std.testing.expectEqualStrings("zigmodu:llm:key:deepseek:3", k);
    var fbuf: [128]u8 = undefined;
    const f = RedisCooldownStore.failKey(&fbuf, "deepseek:3");
    try std.testing.expectEqualStrings("zigmodu:llm:key:deepseek:3:fail", f);
}
