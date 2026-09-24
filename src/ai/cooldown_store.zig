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
        // Uncancelable: `false` here is the reading `KeyPool` rotates on
        // (`!store.isCooling(key)` re-selects the key, `ai/key_pool.zig`), so a
        // canceled wait that answers `false` puts the key that just failed back
        // into service and the caller has no way to tell the two apart. The
        // critical section is one map lookup. Red:
        // `ai.cooldown_store.test.canceled lock wait does not fabricate a key as
        // not-cooling`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const until = self.cooling.get(key) orelse return false;
        return until > self.now_fn();
    }

    fn coolFn(ctx: *anyopaque, key: []const u8, ttl_ms: i64) void {
        const self = selfOf(ctx);
        // Uncancelable: `cool` is the write that takes a failing key *out* of
        // rotation, and the vtable gives it no error channel (`void`), so
        // `catch return` is a silent no-op — the key keeps failing and `KeyPool`
        // keeps selecting it. The critical section is one map operation. Red:
        // `ai.cooldown_store.test.canceled lock wait does not lose a memory store
        // cool, failure count or reset`.
        self.mutex.lockUncancelable(self.io);
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
        // Uncancelable: the return value *is* the answer — a fabricated `0` reads
        // as "this key has not failed yet", which is exactly the count `KeyPool`
        // compares against its threshold before cooling the key. Waiting costs one
        // map operation.
        self.mutex.lockUncancelable(self.io);
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
        // Uncancelable: this is the manual "clear this key" call an operator or a
        // recovered provider triggers. Skipping it leaves the key cooling (and its
        // failure count standing) with nothing reported back, and the vtable has
        // no error channel to report it through. Two map removals.
        self.mutex.lockUncancelable(self.io);
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

    // Every function above is analysed only when something reaches this table (Zig
    // is lazy), so this store went a whole Zig release without compiling: two
    // mirror inserts still called the old three-argument `put`, and `resetFn`
    // discarded `del`'s `u32` into a `void` catch block. The red run of the mirror
    // test below is what surfaced it, and that test is what keeps the table honest
    // now — it instantiates the store through `asStore`.
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
            // Uncancelable, for the same reason as the in-process store's
            // `isCoolingFn`: this mirror answer is what `KeyPool` selects keys
            // with (`!store.isCooling(key)`), so a canceled wait answered with
            // `false` re-selects the key that just failed.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const until = self.mirror_cooling.get(key) orelse return false;
            return until > self.now_fn();
        }
    }

    fn coolFn(ctx: *anyopaque, key: []const u8, ttl_ms: i64) void {
        const self = selfOf(ctx);
        // Uncancelable, for the same reason as the in-process store's `coolFn`:
        // `void` is the whole answer, so a canceled wait swallowed here drops the
        // cooldown *and* never reaches the Redis `SET` below — the key that just
        // failed stays in rotation. The mirror write is one map operation.
        self.mutex.lockUncancelable(self.io);
        if (self.mirror_cooling.getPtr(key)) |until| {
            until.* = self.now_fn() + ttl_ms;
        } else {
            // The mirror key is owned — freed if the insert itself fails, the same
            // shape the in-process store uses (this used to call the old
            // three-argument `put`, which no longer exists; see the note on the
            // vtable below).
            const owned = self.allocator.dupe(u8, key) catch return;
            self.mirror_cooling.put(owned, self.now_fn() + ttl_ms) catch |err| {
                self.allocator.free(owned);
                std.log.debug("[RedisCooldownStore] mirror cool insert failed ({s})", .{@errorName(err)});
            };
        }
        self.mutex.unlock(self.io);

        var kbuf: [128]u8 = undefined;
        const rkey = redisKey(&kbuf, key);
        const ttl_sec: u32 = @intCast(@max(@divTrunc(ttl_ms + 999, 1000), 1));
        self.redis.set(rkey, "1", ttl_sec) catch |err| {
            std.log.warn("[RedisCooldownStore] set failed ({}), using local cooldown for '{s}'", .{ err, key });
        };
    }

    fn bumpFailuresFn(ctx: *anyopaque, key: []const u8) u32 {
        const self = selfOf(ctx);
        // Uncancelable: with Redis unreachable the mirror count below is the value
        // that comes back, and a fabricated `0` reads as a key that has never
        // failed — the comparison `KeyPool` makes before cooling it.
        self.mutex.lockUncancelable(self.io);
        const count = (self.mirror_failures.get(key) orelse 0) + 1;
        if (self.mirror_failures.getPtr(key)) |c| {
            c.* = count;
        } else {
            const owned = self.allocator.dupe(u8, key) catch return count;
            self.mirror_failures.put(owned, count) catch |err| {
                self.allocator.free(owned);
                std.log.debug("[RedisCooldownStore] mirror failure insert failed ({s})", .{@errorName(err)});
            };
        }
        self.mutex.unlock(self.io);

        var kbuf: [128]u8 = undefined;
        const fkey = failKey(&kbuf, key);
        if (self.redis.incr(fkey)) |n| {
            self.redis.expire(fkey, 3600) catch |err| {
                std.log.debug("[RedisCooldownStore] expire of failure key failed ({s})", .{@errorName(err)});
            };
            return @intCast(@max(n, 0));
        } else |err| {
            std.log.warn("[RedisCooldownStore] incr failed ({}), using local count {d} for '{s}'", .{ err, count, key });
            return count;
        }
    }

    fn resetFn(ctx: *anyopaque, key: []const u8) void {
        const self = selfOf(ctx);
        // Uncancelable: a skipped reset leaves both mirrors standing, so with Redis
        // unreachable (the state the mirror is for) the key stays cooling after a
        // manual clear. Two map removals.
        self.mutex.lockUncancelable(self.io);
        if (self.mirror_cooling.fetchRemove(key)) |kv| self.allocator.free(kv.key);
        if (self.mirror_failures.fetchRemove(key)) |kv| self.allocator.free(kv.key);
        self.mutex.unlock(self.io);

        var kbuf: [128]u8 = undefined;
        const rkey = redisKey(&kbuf, key);
        var fbuf: [128]u8 = undefined;
        const fkey = failKey(&fbuf, key);
        if (self.redis.del(&.{ rkey, fkey })) |_| {} else |err| {
            std.log.warn("[RedisCooldownStore] del failed ({}), mirror cleared for '{s}'", .{ err, key });
        }
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

// `isCooling` answering a canceled lock wait with `false` is the reading that
// decides whether a failing key goes back into rotation: `KeyPool` selects a key
// with `!store.isCooling(key)` (`ai/key_pool.zig`), so a fabricated "not cooling"
// re-selects the key that just failed and the caller has no way to tell the two
// apart. The key *is* cooling here.
//
// Red evidence: with the old `self.mutex.lock(self.io) catch return false` this
// fails with `expected true, found false`. The lock wait is the cancelation point:
// the task is parked on the store's mutex (held by the test thread) with a cancel
// request already placed on its thread.
test "canceled lock wait does not fabricate a key as not-cooling" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    fake_now = 1_000_000;
    var store = MemoryCooldownStore.initWithOptions(allocator, io, .{ .now_fn = fakeNow });
    defer store.deinit();
    store.asStore().cool("p:0", 60_000);
    try std.testing.expect(store.asStore().isCooling("p:0"));

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var seen: bool = false;

        fn read(s: *MemoryCooldownStore) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            seen = s.asStore().isCooling("p:0");
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.seen = false;

    try store.mutex.lock(io);

    var read_fut = try io.concurrent(Task.read, .{&store});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (store.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    store.mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);

    try std.testing.expect(Task.seen);
}

/// Park `read` on `mutex` with a cancel request already placed on its thread, then
/// let it through. That makes the lock wait the cancelation point: `read` starts
/// only after `open` is set, the 50 ms sleep places the cancel while the task is
/// still gated, and the mutex is contended by the time the task reaches it.
fn readUnderCanceledLockWait(
    comptime T: type,
    target: *T,
    mutex: *std.Io.Mutex,
    io: std.Io,
    comptime read: fn (*T) void,
) !void {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn run(t: *T) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            read(t);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);

    try mutex.lock(io);

    var read_fut = try io.concurrent(Gate.run, .{target});
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    while (mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);
}

// The three write-side vtable calls on the in-process store: none of them returns
// an error, so a canceled lock wait swallowed as `catch return` / `catch return 0`
// is a silent no-op — `cool` leaves the key that just failed in rotation,
// `bumpFailures` reports a count that never happened (0, i.e. "this key is fine"),
// and `reset` leaves a key cooling after the operator asked for it back. Each
// critical section is a map operation, so waiting costs nothing.
//
// Red evidence: with the old shapes the first assertion below fails —
// `FAIL (TestUnexpectedResult)` on the `isCooling("c:0")` line, because the
// canceled `cool` was dropped. The `bumpFailures` and `reset` assertions after it
// are the same lock shape; a `try` ends the test at the first failure, so those
// two are only exercised green.
test "canceled lock wait does not lose a memory store cool, failure count or reset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    fake_now = 1_000_000;
    var store = MemoryCooldownStore.initWithOptions(allocator, io, .{ .now_fn = fakeNow });
    defer store.deinit();

    const CoolRead = struct {
        fn read(s: *MemoryCooldownStore) void {
            s.asStore().cool("c:0", 60_000);
        }
    };
    try readUnderCanceledLockWait(MemoryCooldownStore, &store, &store.mutex, io, CoolRead.read);
    try std.testing.expect(store.asStore().isCooling("c:0"));

    const BumpRead = struct {
        var seen: u32 = 0;
        fn read(s: *MemoryCooldownStore) void {
            seen = s.asStore().bumpFailures("b:0");
        }
    };
    // Seeded to 1 first, so the true answer to the canceled call is 2 and the
    // fabricated 0 is not confusable with a legitimate first bump.
    try std.testing.expectEqual(@as(u32, 1), store.asStore().bumpFailures("b:0"));
    BumpRead.seen = 0;
    try readUnderCanceledLockWait(MemoryCooldownStore, &store, &store.mutex, io, BumpRead.read);
    try std.testing.expectEqual(@as(u32, 2), BumpRead.seen);

    const ResetRead = struct {
        fn read(s: *MemoryCooldownStore) void {
            s.asStore().reset("c:0");
        }
    };
    try std.testing.expect(store.asStore().isCooling("c:0"));
    try readUnderCanceledLockWait(MemoryCooldownStore, &store, &store.mutex, io, ResetRead.read);
    try std.testing.expect(!store.asStore().isCooling("c:0"));
}

// The same three calls on the Redis store, whose first act is the local mirror
// (Redis is consulted after, outside the lock). The client below has no stream and
// no pool, so every command fails inside `acquireStream` without opening a socket
// — the fail-open state the mirror exists for, and the same client shape
// `RedisRateLimiter`'s degradation test builds. With Redis dead the mirror *is*
// the answer, so a skipped mirror write is the whole effect lost.
//
// Red evidence: with the old shapes the first assertion below fails —
// `FAIL (TestUnexpectedResult)` on the `isCooling("c:0")` line, because the
// canceled `cool` was dropped. The `bumpFailures` and `reset` assertions after it
// are the same lock shape; a `try` ends the test at the first failure, so those
// two are only exercised green.
test "canceled lock wait does not lose a redis store cool, failure count or reset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var redis_client = redis_mod.Redis{
        .allocator = allocator,
        .io = io,
        .stream = null,
        .config = .{},
    };
    var store = RedisCooldownStore.init(allocator, io, &redis_client);
    defer store.deinit();

    const CoolRead = struct {
        fn read(s: *RedisCooldownStore) void {
            s.asStore().cool("c:0", 60_000);
        }
    };
    try readUnderCanceledLockWait(RedisCooldownStore, &store, &store.mutex, io, CoolRead.read);
    try std.testing.expect(store.asStore().isCooling("c:0"));

    const BumpRead = struct {
        var seen: u32 = 0;
        fn read(s: *RedisCooldownStore) void {
            seen = s.asStore().bumpFailures("b:0");
        }
    };
    try std.testing.expectEqual(@as(u32, 1), store.asStore().bumpFailures("b:0"));
    BumpRead.seen = 0;
    try readUnderCanceledLockWait(RedisCooldownStore, &store, &store.mutex, io, BumpRead.read);
    try std.testing.expectEqual(@as(u32, 2), BumpRead.seen);

    const ResetRead = struct {
        fn read(s: *RedisCooldownStore) void {
            s.asStore().reset("c:0");
        }
    };
    try std.testing.expect(store.asStore().isCooling("c:0"));
    try readUnderCanceledLockWait(RedisCooldownStore, &store, &store.mutex, io, ResetRead.read);
    try std.testing.expect(!store.asStore().isCooling("c:0"));
}
