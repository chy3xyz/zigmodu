//! Key pool — a concurrency-safe pool of API keys for one provider endpoint.
//!
//! Responsibilities:
//!   - round-robin selection over healthy keys;
//!   - failure feedback: 429/quota/server cool the key with exponential
//!     backoff; repeated 401/403 disable the key (`auth_fail_threshold`);
//!   - recovery: a cooling key becomes healthy again when its cooldown
//!     expires; `onSuccess` resets failures immediately;
//!   - all bookkeeping is guarded by `std.Io.Mutex` and only happens around
//!     acquire/feedback (microseconds) — the HTTP call runs lock-free.
//!
//! Keys are owned by the pool and never freed until `deinit`, so leased
//! slices stay valid as long as the pool outlives the caller.

const std = @import("std");
const Time = @import("../core/Time.zig");
const cooldown_store = @import("cooldown_store.zig");

pub const KeyStatus = enum { healthy, cooling, disabled };

pub const KeyErrorKind = enum {
    auth, // 401 / 403 — bad key
    rate_limit, // 429 — too many requests
    quota, // 402 / insufficient quota
    server, // 5xx
    network, // transport failure / connection reset
    timeout,
    unknown,

    /// Map an HTTP status to a key error kind.
    pub fn fromHttpStatus(status: u16) KeyErrorKind {
        return switch (status) {
            401, 403 => .auth,
            402 => .quota,
            429 => .rate_limit,
            500...599 => .server,
            else => .unknown,
        };
    }

    /// Whether swapping to another key is likely to help.
    pub fn isKeyRetryable(self: KeyErrorKind) bool {
        return switch (self) {
            .auth, .rate_limit, .quota => true,
            else => false,
        };
    }
};

pub const ApiKey = struct {
    key: []const u8, // owned by the pool
    status: KeyStatus = .healthy,
    failures: u32 = 0,
    total_calls: u64 = 0,
    total_errors: u64 = 0,
};

pub const KeyLease = struct {
    key: []const u8, // borrowed from the pool
    key_index: usize,
};

pub const KeyStats = struct {
    status: KeyStatus,
    failures: u32,
    total_calls: u64,
    total_errors: u64,
};

pub const Options = struct {
    cooldown_base_ms: i64 = 5_000,
    cooldown_max_ms: i64 = 120_000,
    /// TTL for an auth-banned key (default 1h).
    ban_ttl_ms: i64 = 3_600_000,
    auth_fail_threshold: u32 = 3,
    /// Cross-process shared cooldown/failure state. When set, the pool reads
    /// and writes cooldown/ban/failures through this store (e.g. Redis) so
    /// multiple instances sharing the same keys coordinate.
    shared_store: ?*cooldown_store.CooldownStore = null,
    /// Injectable clock for tests (defaults to the framework monotonic clock).
    now_fn: *const fn () i64 = Time.monotonicNowMilliseconds,
};

pub const KeyPool = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Provider name — prefixes cooldown store keys ("<name>:<index>").
    name: []const u8,
    keys: std.ArrayList(ApiKey),
    store: cooldown_store.CooldownStore,
    mem_store: ?*cooldown_store.MemoryCooldownStore = null,
    mutex: std.Io.Mutex,
    opts: Options,
    rr_index: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        keys: []const []const u8,
        opts: Options,
    ) !KeyPool {
        var owned = std.ArrayList(ApiKey).empty;
        errdefer {
            for (owned.items) |k| allocator.free(k.key);
            owned.deinit(allocator);
        }
        for (keys) |k| {
            if (k.len == 0) return error.EmptyApiKey;
            try owned.append(allocator, .{ .key = try allocator.dupe(u8, k) });
        }
        if (opts.shared_store) |shared| {
            return .{
                .allocator = allocator,
                .io = io,
                .name = name,
                .keys = owned,
                .store = shared.*,
                .mutex = std.Io.Mutex.init,
                .opts = opts,
            };
        }
        var pool = KeyPool{
            .allocator = allocator,
            .io = io,
            .name = name,
            .keys = owned,
            .mutex = std.Io.Mutex.init,
            .opts = opts,
            .store = undefined,
            .mem_store = null,
        };
        // Heap-allocate the internal store so its address survives the
        // by-value return of this struct.
        const mem = try allocator.create(cooldown_store.MemoryCooldownStore);
        errdefer allocator.destroy(mem);
        mem.* = cooldown_store.MemoryCooldownStore.initWithOptions(allocator, io, .{ .now_fn = opts.now_fn });
        pool.mem_store = mem;
        pool.store = mem.asStore();
        return pool;
    }

    pub fn deinit(self: *Self) void {
        for (self.keys.items) |k| self.allocator.free(k.key);
        self.keys.deinit(self.allocator);
        if (self.mem_store) |m| {
            m.deinit();
            self.allocator.destroy(m);
        }
        self.* = undefined;
    }

    pub fn keyCount(self: *const Self) usize {
        return self.keys.items.len;
    }

    /// Acquire a healthy key (round-robin). Returns null when every key is
    /// cooling or disabled — the caller should back off or use a fallback
    /// provider.
    pub fn acquire(self: *Self, io: std.Io) !?KeyLease {
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        const klen = self.keys.items.len;
        if (klen == 0) return null;
        for (0..klen) |step| {
            const idx = (self.rr_index + step) % klen;
            const key = &self.keys.items[idx];
            var kbuf: [128]u8 = undefined;
            if (key.status != .disabled and !self.store.isCooling(self.keyStr(idx, &kbuf))) {
                if (key.status == .cooling) key.status = .healthy; // recovered
                self.rr_index = (idx + 1) % klen;
                return .{ .key = key.key, .key_index = idx };
            }
        }
        return null;
    }

    pub fn onSuccess(self: *Self, io: std.Io, key_index: usize) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        const key = self.keyPtrLocked(key_index) orelse return;
        key.total_calls += 1;
        key.failures = 0;
        var kbuf: [128]u8 = undefined;
        self.store.reset(self.keyStr(key_index, &kbuf));
        if (key.status != .disabled) key.status = .healthy;
    }

    /// Feed back a failure for the key that served the request. auth failures
    /// accumulate and disable the key after `auth_fail_threshold`; all other
    /// kinds cool it with exponential backoff.
    pub fn onError(self: *Self, io: std.Io, key_index: usize, kind: KeyErrorKind) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        const key = self.keyPtrLocked(key_index) orelse return;
        key.total_errors += 1;
        var kbuf: [128]u8 = undefined;
        const k = self.keyStr(key_index, &kbuf);
        key.failures = self.store.bumpFailures(k);
        switch (kind) {
            .auth => {
                if (key.failures >= self.opts.auth_fail_threshold) {
                    key.status = .disabled;
                    self.store.cool(k, self.opts.ban_ttl_ms);
                } else {
                    key.status = .cooling;
                    self.store.cool(k, self.backoffMs(key.failures));
                }
            },
            .rate_limit, .quota, .server, .network, .timeout => {
                key.status = .cooling;
                self.store.cool(k, self.backoffMs(key.failures));
            },
            .unknown => {
                key.status = .cooling;
                self.store.cool(k, self.opts.cooldown_base_ms);
            },
        }
    }

    /// Manually (re)enable a key that was disabled by auth failures.
    pub fn enableKey(self: *Self, io: std.Io, key_index: usize) !void {
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        const key = self.keyPtrLocked(key_index) orelse return error.KeyNotFound;
        key.status = .healthy;
        key.failures = 0;
        var kbuf: [128]u8 = undefined;
        self.store.reset(self.keyStr(key_index, &kbuf));
    }

    /// Snapshot per-key stats (owned by the caller).
    pub fn snapshot(self: *Self, io: std.Io, allocator: std.mem.Allocator) ![]KeyStats {
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        const out = try allocator.alloc(KeyStats, self.keys.items.len);
        errdefer allocator.free(out);
        for (self.keys.items, 0..) |k, i| {
            out[i] = .{
                .status = k.status,
                .failures = k.failures,
                .total_calls = k.total_calls,
                .total_errors = k.total_errors,
            };
        }
        return out;
    }

    fn keyPtrLocked(self: *Self, key_index: usize) ?*ApiKey {
        if (key_index >= self.keys.items.len) return null;
        return &self.keys.items[key_index];
    }

    /// Logical cooldown-store key: "<provider>:<key_index>". Writes into the
    /// caller-provided buffer (the store copies or reads it synchronously).
    fn keyStr(self: *Self, key_index: usize, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:{d}", .{ self.name, key_index }) catch self.name;
    }

    fn backoffMs(self: *Self, failures: u32) i64 {
        const exponent: u32 = @min(failures -| 1, 6);
        const delay = self.opts.cooldown_base_ms * (@as(i64, 1) << @intCast(exponent));
        return @min(delay, self.opts.cooldown_max_ms);
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

var fake_now: i64 = 1_000_000;
fn fakeNow() i64 {
    return fake_now;
}

fn testPool(allocator: std.mem.Allocator, keys: []const []const u8) !KeyPool {
    return KeyPool.init(allocator, std.testing.io, "test", keys, .{
        .cooldown_base_ms = 1_000,
        .cooldown_max_ms = 8_000,
        .now_fn = fakeNow,
    });
}

test "pool round-robins healthy keys" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var pool = try testPool(allocator, &.{ "sk-a", "sk-b" });
    defer pool.deinit();
    try std.testing.expectEqualStrings("sk-a", (try pool.acquire(std.testing.io)).?.key);
    try std.testing.expectEqualStrings("sk-b", (try pool.acquire(std.testing.io)).?.key);
    try std.testing.expectEqualStrings("sk-a", (try pool.acquire(std.testing.io)).?.key);
}

test "rate_limit cools a key and it recovers after backoff" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var pool = try testPool(allocator, &.{ "sk-a", "sk-b" });
    defer pool.deinit();

    const l1 = (try pool.acquire(std.testing.io)).?;
    pool.onError(std.testing.io, l1.key_index, .rate_limit); // failure #1 -> +1s
    try std.testing.expectEqualStrings("sk-b", (try pool.acquire(std.testing.io)).?.key);

    const l2 = (try pool.acquire(std.testing.io)).?;
    pool.onError(std.testing.io, l2.key_index, .rate_limit); // sk-b cools too
    try std.testing.expectEqual(@as(?KeyLease, null), try pool.acquire(std.testing.io));

    fake_now += 1_000; // sk-a's cooldown expires first
    try std.testing.expectEqualStrings("sk-a", (try pool.acquire(std.testing.io)).?.key);
}

test "auth failures disable a key after threshold" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var pool = try testPool(allocator, &.{"sk-a"});
    defer pool.deinit();

    const l1 = (try pool.acquire(std.testing.io)).?;
    pool.onError(std.testing.io, l1.key_index, .auth);
    fake_now = 1_001_000;
    const l2 = (try pool.acquire(std.testing.io)).?;
    pool.onError(std.testing.io, l2.key_index, .auth);
    fake_now = 1_003_000;
    const l3 = (try pool.acquire(std.testing.io)).?;
    pool.onError(std.testing.io, l3.key_index, .auth); // 3rd -> disabled

    try std.testing.expectEqual(@as(?KeyLease, null), try pool.acquire(std.testing.io));
    try pool.enableKey(std.testing.io, 0);
    try std.testing.expectEqualStrings("sk-a", (try pool.acquire(std.testing.io)).?.key);
}

test "onSuccess resets failures and re-enables a cooling key" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var pool = try testPool(allocator, &.{"sk-a"});
    defer pool.deinit();

    const l = (try pool.acquire(std.testing.io)).?;
    pool.onError(std.testing.io, l.key_index, .server);
    fake_now += 500; // still cooling
    try std.testing.expectEqual(@as(?KeyLease, null), try pool.acquire(std.testing.io));
    pool.onSuccess(std.testing.io, l.key_index);
    try std.testing.expectEqualStrings("sk-a", (try pool.acquire(std.testing.io)).?.key);
}

test "KeyErrorKind fromHttpStatus + retryable" {
    try std.testing.expectEqual(KeyErrorKind.auth, KeyErrorKind.fromHttpStatus(401));
    try std.testing.expectEqual(KeyErrorKind.auth, KeyErrorKind.fromHttpStatus(403));
    try std.testing.expectEqual(KeyErrorKind.rate_limit, KeyErrorKind.fromHttpStatus(429));
    try std.testing.expectEqual(KeyErrorKind.quota, KeyErrorKind.fromHttpStatus(402));
    try std.testing.expectEqual(KeyErrorKind.server, KeyErrorKind.fromHttpStatus(503));
    try std.testing.expectEqual(KeyErrorKind.unknown, KeyErrorKind.fromHttpStatus(200));
    try std.testing.expect(KeyErrorKind.auth.isKeyRetryable());
    try std.testing.expect(KeyErrorKind.rate_limit.isKeyRetryable());
    try std.testing.expect(!KeyErrorKind.server.isKeyRetryable());
}

test "pool routes cooldown through an external shared store" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var shared = cooldown_store.MemoryCooldownStore.initWithOptions(allocator, std.testing.io, .{ .now_fn = fakeNow });
    defer shared.deinit();
    var shared_store = shared.asStore();
    var pool = try KeyPool.init(allocator, std.testing.io, "shared", &.{"sk-a"}, .{
        .cooldown_base_ms = 1_000,
        .cooldown_max_ms = 8_000,
        .now_fn = fakeNow,
        .shared_store = &shared_store,
    });
    defer pool.deinit();

    const l = (try pool.acquire(std.testing.io)).?;
    pool.onError(std.testing.io, l.key_index, .rate_limit);
    try std.testing.expectEqual(@as(?KeyLease, null), try pool.acquire(std.testing.io));
    // External store knows the key is cooling (cross-process visibility).
    try std.testing.expect(shared.asStore().isCooling("shared:0"));
}
