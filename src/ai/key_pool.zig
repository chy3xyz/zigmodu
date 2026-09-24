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

/// Size of the buffer `keyStr` writes into. Callers pass `*[key_buf_len]u8`.
pub const key_buf_len = 128;
/// Bytes the long-name form of a logical key needs besides the name prefix:
/// "~", the 16 hex digits of the digest, ":" and the widest possible `usize`
/// index (20 digits).
const key_long_form_overhead = 1 + 16 + 1 + 20;
/// Longest provider-name prefix kept in the long-name form of a logical key.
pub const key_name_max = key_buf_len - key_long_form_overhead;

comptime {
    // `keyStr` writes the long form by hand and relies on exactly this
    // reservation: shrink `key_buf_len` (or set `key_name_max` by hand) and the
    // widest index would no longer fit after the prefix.
    std.debug.assert(key_name_max + key_long_form_overhead <= key_buf_len);
}

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
            // The copy is hoisted out of the append on purpose: as
            // `owned.append(allocator, .{ .key = try allocator.dupe(u8, k) })` the
            // dupe succeeds while the append grows, so an append failure left a
            // copy that no `errdefer` could see (it is not in `owned.items` yet).
            // Here the per-iteration `errdefer` owns it until the append takes it
            // over. Red: `ai.provider_registry.test.every allocation failure
            // inside register and deinit is reported and leaks nothing` with
            // `api_keys` non-empty — `fail_index: 8/33`, `leaked [len: 4]`.
            const owned_key = try allocator.dupe(u8, k);
            errdefer allocator.free(owned_key);
            try owned.append(allocator, .{ .key = owned_key });
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
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const klen = self.keys.items.len;
        if (klen == 0) return null;
        for (0..klen) |step| {
            const idx = (self.rr_index + step) % klen;
            const key = &self.keys.items[idx];
            var kbuf: [key_buf_len]u8 = undefined;
            if (key.status != .disabled and !self.store.isCooling(self.keyStr(idx, &kbuf))) {
                if (key.status == .cooling) key.status = .healthy; // recovered
                self.rr_index = (idx + 1) % klen;
                return .{ .key = key.key, .key_index = idx };
            }
        }
        return null;
    }

    pub fn onSuccess(self: *Self, io: std.Io, key_index: usize) void {
        // Uncancelable: this is the write that puts a key *back* into service and
        // clears its failure count. `void` is the whole answer, so `catch return`
        // is a silent no-op — the key stays cooling (or disabled) after a call it
        // just served, and nothing reaches the caller. The critical section is a
        // few map operations. Red: `ai.key_pool.test.canceled lock wait does not
        // lose an onError cooldown or onSuccess reset`.
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const key = self.keyPtrLocked(key_index) orelse return;
        key.total_calls += 1;
        key.failures = 0;
        var kbuf: [key_buf_len]u8 = undefined;
        self.store.reset(self.keyStr(key_index, &kbuf));
        if (key.status != .disabled) key.status = .healthy;
    }

    /// Feed back a failure for the key that served the request. auth failures
    /// accumulate and disable the key after `auth_fail_threshold`; all other
    /// kinds cool it with exponential backoff.
    pub fn onError(self: *Self, io: std.Io, key_index: usize, kind: KeyErrorKind) void {
        // Uncancelable: this is the write that takes a failing key *out* of
        // rotation, and its production caller is the 401/403/402/429 path
        // (`ai/provider.zig` → `AiProviderManager.onError`). `void` is the whole
        // answer, so `catch return` never records the failure — the key that just
        // failed stays selectable and is neither cooled nor banned. The critical
        // section is a few map operations. Red: `ai.key_pool.test.canceled lock
        // wait does not lose an onError cooldown or onSuccess reset`.
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const key = self.keyPtrLocked(key_index) orelse return;
        key.total_errors += 1;
        var kbuf: [key_buf_len]u8 = undefined;
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
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const key = self.keyPtrLocked(key_index) orelse return error.KeyNotFound;
        key.status = .healthy;
        key.failures = 0;
        var kbuf: [key_buf_len]u8 = undefined;
        self.store.reset(self.keyStr(key_index, &kbuf));
    }

    /// Snapshot per-key stats (owned by the caller).
    pub fn snapshot(self: *Self, io: std.Io, allocator: std.mem.Allocator) ![]KeyStats {
        try self.mutex.lock(io);
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
    ///
    /// A provider name is caller-supplied and never length-checked, so a name
    /// long enough to overflow `key_buf_len` is handled instead of dropped: the
    /// name is truncated (to `key_name_max`) and tagged with a digest of the
    /// **full** name, while the index stays. The old `catch self.name` fallback
    /// returned the bare name for every index, so all keys of a long-named
    /// provider shared one cooldown entry — one key's 429 cooled a different key
    /// (red: `ai.key_pool.test.a long provider name keeps one cooldown entry per
    /// key and per provider`).
    fn keyStr(self: *Self, key_index: usize, buf: *[key_buf_len]u8) []const u8 {
        if (std.fmt.bufPrint(buf, "{s}:{d}", .{ self.name, key_index })) |s| {
            return s;
        } else |err| switch (err) {
            // Handled by the bounded form below.
            error.NoSpaceLeft => {},
        }

        const digest = std.hash.Wyhash.hash(0, self.name);
        const short = self.name[0..@min(self.name.len, key_name_max)];
        var w: usize = 0;
        @memcpy(buf[w..][0..short.len], short);
        w += short.len;
        buf[w] = '~';
        w += 1;
        const hex = std.fmt.bytesToHex(@as([8]u8, @bitCast(digest)), .lower);
        @memcpy(buf[w..][0..hex.len], &hex);
        w += hex.len;
        buf[w] = ':';
        w += 1;
        // Total by construction: `key_name_max` reserves the widest possible
        // index, so this cannot run out of buffer.
        w += std.fmt.printInt(buf[w..], key_index, 10, .lower, .{});
        return buf[0..w];
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

fn repeatedName(comptime n: usize, comptime c: u8) [n]u8 {
    var b: [n]u8 = undefined;
    @memset(&b, c);
    return b;
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

test "a long provider name keeps one cooldown entry per key and per provider" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var shared = cooldown_store.MemoryCooldownStore.initWithOptions(allocator, std.testing.io, .{ .now_fn = fakeNow });
    defer shared.deinit();
    var shared_store = shared.asStore();

    // The logical key buffer is 128 bytes, so a name this long overflows
    // "<name>:<index>". The old `catch self.name` fallback then used the bare
    // name for *every* key of the pool.
    const long_a = repeatedName(200, 'p');
    // Same 199-byte prefix, different name.
    const long_b = blk: {
        var b = repeatedName(200, 'p');
        b[199] = 'q';
        break :blk b;
    };
    const opts = Options{
        .cooldown_base_ms = 1_000,
        .cooldown_max_ms = 8_000,
        .now_fn = fakeNow,
        .shared_store = &shared_store,
    };
    var pool_a = try KeyPool.init(allocator, std.testing.io, &long_a, &.{ "sk-a", "sk-b" }, opts);
    defer pool_a.deinit();
    var pool_b = try KeyPool.init(allocator, std.testing.io, &long_b, &.{"sk-c"}, opts);
    defer pool_b.deinit();

    const a0 = (try pool_a.acquire(std.testing.io)).?;
    try std.testing.expectEqual(@as(usize, 0), a0.key_index);
    pool_a.onError(std.testing.io, a0.key_index, .rate_limit); // cools sk-a only

    // Same pool, other key: the index survives the truncation, so sk-b is not
    // cooled along with sk-a.
    const a1 = try pool_a.acquire(std.testing.io);
    try std.testing.expect(a1 != null);
    try std.testing.expectEqualStrings("sk-b", a1.?.key);

    // Another provider whose name shares the whole 199-byte prefix: the digest of
    // the full name is what keeps the two providers' keys apart.
    const b0 = try pool_b.acquire(std.testing.io);
    try std.testing.expect(b0 != null);
    try std.testing.expectEqualStrings("sk-c", b0.?.key);
}

/// Park `read` on `mutex` with a cancel request already placed on its thread, then
/// let it through: the lock wait becomes the cancelation point. `std.Io.Mutex.lock`'s
/// uncontended fast path does not check for cancellation, so it is the contended
/// wait that can come back canceled.
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

// `onError` is the write that takes a failing key *out* of rotation and
// `onSuccess` the one that puts it back. Both return `void`, so a canceled lock
// wait swallowed as `catch return` is a silent no-op: the 401/403/402/429 the
// provider just received (`ai/provider.zig:279` → `AiProviderManager.onError`) is
// never recorded, the failing key stays selectable, and the caller has no error
// channel to notice. The critical section is a few map operations, so the wait
// must not be cancelable.
//
// Red evidence: with the old `self.mutex.lock(io) catch return;` the first
// assertion below fails (`sk-a` is handed back after the canceled `onError` was
// dropped). The `onSuccess` half is the same lock shape; a `try` ends the test at
// the first failure, so it is only exercised green.
test "canceled lock wait does not lose an onError cooldown or onSuccess reset" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    fake_now = 1_000_000;
    var pool = try testPool(allocator, &.{"sk-a"});
    defer pool.deinit();

    _ = (try pool.acquire(io)).?;
    const ErrorRead = struct {
        fn read(p: *KeyPool) void {
            p.onError(std.testing.io, 0, .rate_limit);
        }
    };
    try readUnderCanceledLockWait(KeyPool, &pool, &pool.mutex, io, ErrorRead.read);
    try std.testing.expectEqual(@as(?KeyLease, null), try pool.acquire(io));

    const SuccessRead = struct {
        fn read(p: *KeyPool) void {
            p.onSuccess(std.testing.io, 0);
        }
    };
    try readUnderCanceledLockWait(KeyPool, &pool, &pool.mutex, io, SuccessRead.read);
    try std.testing.expectEqualStrings("sk-a", (try pool.acquire(io)).?.key);
}

// The three waits a caller *can* be told about: `acquire`, `enableKey` and
// `snapshot` return errors, so the cancelation is propagated as
// `error.Canceled` — the only error `std.Io.Mutex.lock` has. The old
// `catch return error.LockFailed` reported lock-machinery failure for a
// cancelation, and a caller cannot tell "unwind, you were canceled" from "this
// pool's lock is broken". Nothing is at risk in an abandoned critical section: no
// key is rotated, enabled or copied. (`onError`/`onSuccess` above are the same
// lock shape in the other direction — `void`, so they wait.)
//
// Red evidence: with `catch return error.LockFailed` the first assertion below
// reads `expected error.Canceled, found error.LockFailed`. The `enableKey` and
// `snapshot` assertions after it are the same lock shape; a `try` ends the test at
// the first failure, so those two are only exercised green.
test "acquire, enableKey and snapshot report a canceled lock wait as error.Canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    fake_now = 1_000_000;
    var pool = try testPool(allocator, &.{"sk-a"});
    defer pool.deinit();

    const AcquireRead = struct {
        var seen: ?anyerror = null;
        fn read(p: *KeyPool) void {
            seen = null;
            _ = p.acquire(std.testing.io) catch |err| {
                seen = err;
            };
        }
    };
    AcquireRead.seen = null;
    try readUnderCanceledLockWait(KeyPool, &pool, &pool.mutex, io, AcquireRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), AcquireRead.seen);

    const EnableRead = struct {
        var seen: ?anyerror = null;
        fn read(p: *KeyPool) void {
            seen = null;
            p.enableKey(std.testing.io, 0) catch |err| {
                seen = err;
            };
        }
    };
    EnableRead.seen = null;
    try readUnderCanceledLockWait(KeyPool, &pool, &pool.mutex, io, EnableRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), EnableRead.seen);

    const SnapshotRead = struct {
        var seen: ?anyerror = null;
        fn read(p: *KeyPool) void {
            seen = null;
            const stats = p.snapshot(std.testing.io, std.testing.allocator) catch |err| {
                seen = err;
                return;
            };
            std.testing.allocator.free(stats);
        }
    };
    SnapshotRead.seen = null;
    try readUnderCanceledLockWait(KeyPool, &pool, &pool.mutex, io, SnapshotRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), SnapshotRead.seen);
}
