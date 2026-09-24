//! Provider registry — concurrency-safe registration of LLM providers, each
//! with its own `KeyPool`, model routing and provider-level fallback.
//!
//! `acquire(model)` resolves the model to the provider serving it, then to a
//! healthy key inside that provider's pool. When the primary provider has no
//! healthy key (or is disabled), the fallback provider chain is tried in
//! order — this is the "provider + key rotation" layer on top of `KeyPool`.
//!
//! Ownership: every provider lives in its own heap box (`*ProviderEntry`), and
//! `ProviderLease` borrows pointers out of that box (`&entry.pool`,
//! `entry.name`, `entry.endpoint`) plus a key string owned by the pool. The box
//! address is therefore stable when the provider list grows, and a same-named
//! re-registration **retires** the box it replaces instead of freeing it — so
//! every lease stays valid until `ProviderRegistry.deinit`, the only place a
//! box dies. See `register`.

const std = @import("std");
const key_pool = @import("key_pool.zig");

pub const KeyPool = key_pool.KeyPool;
pub const KeyErrorKind = key_pool.KeyErrorKind;
pub const KeyStatus = key_pool.KeyStatus;

pub const ProviderOpts = struct {
    /// Model names this provider serves (used by `acquire(model)` routing).
    models: []const []const u8 = &.{},
    /// Fallback provider names tried when this provider has no healthy key.
    fallback_providers: []const []const u8 = &.{},
    enabled: bool = true,
    pool_opts: key_pool.Options = .{},
};

/// A leased provider + key. `provider`, `endpoint` and `key` are borrowed, and
/// stay valid until `ProviderRegistry.deinit` — including when the provider is
/// re-registered while the lease is out (the registry retires the box it
/// replaced rather than freeing it, so feedback about this lease still reaches
/// the pool it was taken from). `model` is the caller's own string.
pub const ProviderLease = struct {
    provider: []const u8, // borrowed (provider name)
    endpoint: []const u8, // borrowed
    key: []const u8, // borrowed from the pool
    model: []const u8, // borrowed (the requested model)
    pool: *KeyPool, // borrowed — feed onSuccess/onError here
    key_index: usize,
};

pub const ProviderInfo = struct {
    name: []const u8, // owned copy
    endpoint: []const u8, // owned copy
    enabled: bool,
    models: []const []const u8, // owned copy
    keys: []key_pool.KeyStats, // owned copy

    pub fn deinit(self: *ProviderInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.endpoint);
        for (self.models) |m| allocator.free(m);
        allocator.free(self.models);
        allocator.free(self.keys);
        self.* = undefined;
    }
};

/// One provider's owned state. Always heap-allocated (in `registerLocked`) so
/// that `&entry.pool` (and the borrowed strings) stay valid for the lifetime of
/// a `ProviderLease` — the list holding these pointers may reallocate freely.
const ProviderEntry = struct {
    name: []const u8, // owned
    endpoint: []const u8, // owned
    models: []const []const u8, // owned
    fallback_providers: []const []const u8, // owned
    pool: KeyPool, // owned
    enabled: bool,
};

pub const ProviderRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    providers: std.ArrayList(*ProviderEntry),
    /// Boxes replaced by a later `register` of the same name. A lease taken
    /// from one may still be in flight — `onSuccess`/`onError`, or a key that
    /// is the credential of a request already being made — and a lease has no
    /// release call, so nothing here can prove it is dead. They are freed in
    /// `deinit`; the cost is one box per replacement that lives until shutdown.
    retired: std.ArrayList(*ProviderEntry),
    by_name: std.StringHashMap(usize),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .providers = std.ArrayList(*ProviderEntry).empty,
            .retired = std.ArrayList(*ProviderEntry).empty,
            .by_name = std.StringHashMap(usize).init(allocator),
            .mutex = std.Io.Mutex.init,
        };
    }

    /// Frees every provider box, live and retired. Leases (and `AiProvider`s
    /// bound to them) still hold borrowed pointers into those boxes, so the
    /// registry must outlive every lease it handed out.
    pub fn deinit(self: *Self) void {
        for (self.providers.items) |p| self.destroyEntry(p);
        self.providers.deinit(self.allocator);
        for (self.retired.items) |p| self.destroyEntry(p);
        self.retired.deinit(self.allocator);
        var it = self.by_name.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.by_name.deinit();
        self.* = undefined;
    }

    fn destroyEntry(self: *Self, p: *ProviderEntry) void {
        self.allocator.free(p.name);
        self.allocator.free(p.endpoint);
        for (p.models) |m| self.allocator.free(m);
        self.allocator.free(p.models);
        for (p.fallback_providers) |f| self.allocator.free(f);
        self.allocator.free(p.fallback_providers);
        p.pool.deinit();
        self.allocator.destroy(p);
    }

    /// How many replaced provider boxes are still being kept alive for
    /// outstanding leases. Grows by one per same-named `register` and only
    /// shrinks when the registry dies — worth watching if providers are
    /// re-registered on a hot path (a lease-release API would bound it).
    pub fn retiredCount(self: *Self, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.retired.items.len;
    }

    /// Register (or replace) a provider: name → endpoint + key pool + models.
    ///
    /// Replacing a provider does not free the state it replaces: leases already
    /// issued from it borrow `&entry.pool`, `entry.name`, `entry.endpoint` and
    /// a key string, and none of those has a release call — the caller may
    /// still be using the lease (`onSuccess`/`onError`, or a request already in
    /// flight with that key). The replaced entry moves to `retired`, where its
    /// pool keeps accepting that lease's feedback, and is freed in `deinit`.
    /// Routing and `listProviders` only ever see the new entry.
    pub fn register(
        self: *Self,
        io: std.Io,
        name: []const u8,
        endpoint: []const u8,
        api_keys: []const []const u8,
        opts: ProviderOpts,
    ) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.registerLocked(io, name, endpoint, api_keys, opts);
    }

    fn registerLocked(
        self: *Self,
        io: std.Io,
        name: []const u8,
        endpoint: []const u8,
        api_keys: []const []const u8,
        opts: ProviderOpts,
    ) !void {
        // Built in a block of its own so the construction-time `errdefer`s are
        // no longer armed once the box exists: from then on the box owns the
        // strings and the pool, and only `destroyEntry` may free them.
        const box = blk: {
            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);
            const owned_endpoint = try self.allocator.dupe(u8, endpoint);
            errdefer self.allocator.free(owned_endpoint);
            const owned_models = try self.allocator.alloc([]const u8, opts.models.len);
            errdefer self.allocator.free(owned_models);
            var n_models: usize = 0;
            errdefer for (owned_models[0..n_models]) |m| self.allocator.free(m);
            for (opts.models, 0..) |m, i| {
                owned_models[i] = try self.allocator.dupe(u8, m);
                n_models += 1;
            }
            const owned_fallbacks = try self.allocator.alloc([]const u8, opts.fallback_providers.len);
            errdefer self.allocator.free(owned_fallbacks);
            var n_fallbacks: usize = 0;
            errdefer for (owned_fallbacks[0..n_fallbacks]) |f| self.allocator.free(f);
            for (opts.fallback_providers, 0..) |f, i| {
                owned_fallbacks[i] = try self.allocator.dupe(u8, f);
                n_fallbacks += 1;
            }
            var pool = try KeyPool.init(self.allocator, io, name, api_keys, opts.pool_opts);
            errdefer pool.deinit();

            const box = try self.allocator.create(ProviderEntry);
            box.* = .{
                .name = owned_name,
                .endpoint = owned_endpoint,
                .models = owned_models,
                .fallback_providers = owned_fallbacks,
                .pool = pool,
                .enabled = opts.enabled,
            };
            break :blk box;
        };
        errdefer self.destroyEntry(box);

        if (self.by_name.get(name)) |idx| {
            // The box being replaced may still be named by a live lease, so it
            // goes to `retired` instead of being freed (see `register`).
            try self.retired.append(self.allocator, self.providers.items[idx]);
            self.providers.items[idx] = box;
            return;
        }
        const new_idx = self.providers.items.len;
        try self.providers.append(self.allocator, box);
        errdefer _ = self.providers.pop();
        const by_name_key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(by_name_key);
        try self.by_name.put(by_name_key, new_idx);
    }

    /// Resolve `model` to a provider (provider rotation) and a healthy key
    /// (key rotation). Tries the provider serving the model, then its
    /// fallback providers in order.
    ///
    /// The returned lease borrows registry-owned memory and has no release
    /// call: it stays valid (and its `onSuccess`/`onError` keep reaching the
    /// pool it was taken from) until `deinit`, whether or not the provider is
    /// replaced in the meantime.
    pub fn acquire(self: *Self, io: std.Io, model: []const u8) !ProviderLease {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const lease = try self.acquireLocked(io, model);
        return lease;
    }

    fn acquireLocked(self: *Self, io: std.Io, model: []const u8) !ProviderLease {
        var chain: [16]usize = undefined;
        var n: usize = 0;
        // Primary provider(s) serving this model.
        for (self.providers.items, 0..) |p, idx| {
            if (n >= chain.len) break;
            for (p.models) |m| {
                if (std.mem.eql(u8, m, model)) {
                    chain[n] = idx;
                    n += 1;
                    // Append this provider's fallback chain.
                    for (p.fallback_providers) |f| {
                        if (self.by_name.get(f)) |fidx| {
                            if (n >= chain.len) break;
                            chain[n] = fidx;
                            n += 1;
                        }
                    }
                    break;
                }
            }
        }
        if (n == 0) return error.ModelNotFound;

        for (chain[0..n]) |pidx| {
            const p = self.providers.items[pidx];
            if (!p.enabled) continue;
            if (try p.pool.acquire(io)) |lease| {
                return .{
                    .provider = p.name,
                    .endpoint = p.endpoint,
                    .key = lease.key,
                    .model = model,
                    .pool = &p.pool,
                    .key_index = lease.key_index,
                };
            }
        }
        return error.NoHealthyKey;
    }

    /// Mark the lease's key as successful (resets failures/cooldown).
    pub fn onSuccess(self: *Self, io: std.Io, lease: ProviderLease) void {
        _ = self;
        lease.pool.onSuccess(io, lease.key_index);
    }

    /// Feed back a failure for the lease's key.
    pub fn onError(self: *Self, io: std.Io, lease: ProviderLease, kind: KeyErrorKind) void {
        _ = self;
        lease.pool.onError(io, lease.key_index, kind);
    }

    pub fn enableProvider(self: *Self, io: std.Io, name: []const u8, enabled: bool) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const idx = self.by_name.get(name) orelse return error.ProviderNotFound;
        self.providers.items[idx].enabled = enabled;
    }

    pub fn enableKey(self: *Self, io: std.Io, provider: []const u8, key_index: usize) !void {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        const idx = self.by_name.get(provider) orelse return error.ProviderNotFound;
        try self.providers.items[idx].pool.enableKey(io, key_index);
    }

    /// Snapshot the provider table (owned by the caller). Live providers only —
    /// a replaced one is retired, not registered (see `register`).
    pub fn listProviders(self: *Self, io: std.Io, allocator: std.mem.Allocator) ![]ProviderInfo {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);

        var out = std.ArrayList(ProviderInfo).empty;
        errdefer {
            for (out.items) |*p| p.deinit(allocator);
            out.deinit(allocator);
        }
        for (self.providers.items) |p| {
            const keys = try p.pool.snapshot(io, allocator);
            errdefer allocator.free(keys);
            const models = try allocator.alloc([]const u8, p.models.len);
            errdefer allocator.free(models);
            for (p.models, 0..) |m, i| models[i] = try allocator.dupe(u8, m);
            try out.append(allocator, .{
                .name = try allocator.dupe(u8, p.name),
                .endpoint = try allocator.dupe(u8, p.endpoint),
                .enabled = p.enabled,
                .models = models,
                .keys = keys,
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

test "registry routes model to provider and rotates keys" {
    const allocator = std.testing.allocator;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(std.testing.io, "deepseek", "https://d/v1/chat/completions", &.{ "sk-d1", "sk-d2" }, .{
        .models = &.{"deepseek-v4-flash"},
    });

    const l1 = try reg.acquire(std.testing.io, "deepseek-v4-flash");
    try std.testing.expectEqualStrings("deepseek", l1.provider);
    try std.testing.expectEqualStrings("sk-d1", l1.key);
    const l2 = try reg.acquire(std.testing.io, "deepseek-v4-flash");
    try std.testing.expectEqualStrings("sk-d2", l2.key);
    try std.testing.expectError(error.ModelNotFound, reg.acquire(std.testing.io, "nope"));
}

test "registry falls back to another provider when the pool is exhausted" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(std.testing.io, "primary", "https://p/v1/chat/completions", &.{"sk-a"}, .{
        .models = &.{"m"},
        .fallback_providers = &.{"backup"},
        .pool_opts = .{ .cooldown_base_ms = 1_000, .cooldown_max_ms = 8_000, .now_fn = fakeNow },
    });
    try reg.register(std.testing.io, "backup", "https://b/v1/chat/completions", &.{"sk-b"}, .{
        .models = &.{"m"},
    });

    const l1 = try reg.acquire(std.testing.io, "m"); // sk-a
    reg.onError(std.testing.io, l1, .rate_limit); // sk-a cools
    const l2 = try reg.acquire(std.testing.io, "m");
    try std.testing.expectEqualStrings("backup", l2.provider);
    try std.testing.expectEqualStrings("sk-b", l2.key);
}

test "registry disabled provider is skipped" {
    const allocator = std.testing.allocator;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(std.testing.io, "a", "https://a/v1/chat/completions", &.{"sk-a"}, .{ .models = &.{"m"} });
    try reg.register(std.testing.io, "b", "https://b/v1/chat/completions", &.{"sk-b"}, .{
        .models = &.{"m"},
        .fallback_providers = &.{"a"},
    });
    try reg.enableProvider(std.testing.io, "b", false);
    const l = try reg.acquire(std.testing.io, "m");
    try std.testing.expectEqualStrings("a", l.provider);
    try std.testing.expectEqualStrings("sk-a", l.key);
}

test "registry listProviders snapshot" {
    const allocator = std.testing.allocator;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(std.testing.io, "a", "https://a/v1/chat/completions", &.{ "sk-a", "sk-b" }, .{ .models = &.{"m"} });

    const l = try reg.acquire(std.testing.io, "m");
    reg.onSuccess(std.testing.io, l);
    const infos = try reg.listProviders(std.testing.io, allocator);
    defer {
        for (infos) |*p| p.deinit(allocator);
        allocator.free(infos);
    }
    try std.testing.expectEqual(@as(usize, 1), infos.len);
    try std.testing.expectEqualStrings("a", infos[0].name);
    try std.testing.expectEqual(@as(usize, 2), infos[0].keys.len);
    try std.testing.expectEqual(@as(u64, 1), infos[0].keys[0].total_calls);
}

// The three tests below pin the lifetime a `ProviderLease` is entitled to: it
// borrows `&entry.pool` plus `entry.name` / `entry.endpoint` / the pool's key
// string, so the registry may not free any of them while a lease is out.
// `std.testing.allocator` fills every freed block with 0x55 (SafeAllocator
// `overwriteFreed`), so a read through a dead lease shows up as 0x55 bytes and a
// write that lands on a moved pool shows up in the counters.

test "re-registering a provider keeps the leased key readable" {
    const allocator = std.testing.allocator;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(std.testing.io, "p", "https://old/v1/chat/completions", &.{"sk-old"}, .{ .models = &.{"m"} });
    const lease = try reg.acquire(std.testing.io, "m");
    try std.testing.expectEqualStrings("sk-old", lease.key);

    // Same-named re-registration — the replacement path in `registerLocked`.
    try reg.register(std.testing.io, "p", "https://new/v1/chat/completions", &.{"sk-new"}, .{ .models = &.{"m"} });

    // The request the lease was issued for is still in flight: the key it names
    // is the credential of that request and must not be freed under it. The
    // other borrows are what `AiKeyManager.providerFor` copies into the
    // `AiProvider` it hands out (`provider`/`endpoint`/`key`/`pool`).
    try std.testing.expectEqual(@as(usize, 1), reg.retiredCount(std.testing.io));
    try std.testing.expectEqualStrings("sk-old", lease.key);
    try std.testing.expectEqualStrings("p", lease.provider);
    try std.testing.expectEqualStrings("https://old/v1/chat/completions", lease.endpoint);
    try std.testing.expect(lease.pool == &reg.retired.items[0].pool);
}

test "a replaced provider's lease does not write into the replacement" {
    const allocator = std.testing.allocator;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(std.testing.io, "p", "https://old/v1/chat/completions", &.{"sk-old"}, .{ .models = &.{"m"} });
    const lease = try reg.acquire(std.testing.io, "m");
    try reg.register(std.testing.io, "p", "https://new/v1/chat/completions", &.{ "sk-new-1", "sk-new-2" }, .{ .models = &.{"m"} });

    // Feedback rides on the lease: it is about the key that served the request,
    // which by key index alone happens to be key 0 of the replacement too.
    reg.onError(std.testing.io, lease, .rate_limit);

    const keys = try reg.providers.items[0].pool.snapshot(std.testing.io, allocator);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(u64, 0), keys[0].total_errors);
    try std.testing.expectEqual(KeyStatus.healthy, keys[0].status);
    try std.testing.expectEqual(@as(u64, 0), keys[1].total_errors);
    try std.testing.expectEqual(KeyStatus.healthy, keys[1].status);

    // ... and the failure is not lost either: it is recorded on the pool the
    // lease was taken from, which is exactly what the feedback is about.
    const old_keys = try reg.retired.items[0].pool.snapshot(std.testing.io, allocator);
    defer allocator.free(old_keys);
    try std.testing.expectEqual(@as(u64, 1), old_keys[0].total_errors);
    try std.testing.expectEqual(KeyStatus.cooling, old_keys[0].status);
    try std.testing.expectEqualStrings("sk-old", lease.key);
}

test "a lease survives a registration that moves the provider list" {
    const allocator = std.testing.allocator;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(std.testing.io, "p0", "https://p0/v1/chat/completions", &.{"sk-0"}, .{ .models = &.{"m"} });
    const lease = try reg.acquire(std.testing.io, "m");

    // Fill the list until `ArrayList.append` has to move the entries, which
    // frees the buffer the lease's pointers were taken from.
    const initial_capacity = reg.providers.capacity;
    var name_buf: [16]u8 = undefined;
    var i: usize = 1;
    while (reg.providers.capacity == initial_capacity) : (i += 1) {
        try std.testing.expect(i < 64);
        const name = try std.fmt.bufPrint(&name_buf, "extra{d}", .{i});
        try reg.register(std.testing.io, name, "https://x/v1/chat/completions", &.{"sk-x"}, .{});
    }

    // Reading the lease first: it must not touch the freed buffer. The rest of
    // this test is exercised green only (`try` ends the test at the first
    // failure), and the write below would be a write into freed memory.
    try std.testing.expectEqualStrings("sk-0", lease.key);
    try std.testing.expect(lease.pool == &reg.providers.items[0].pool);

    reg.onSuccess(std.testing.io, lease);
    const keys = try reg.providers.items[0].pool.snapshot(std.testing.io, allocator);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(u64, 1), keys[0].total_calls);
}

test "every allocation failure inside register and deinit is reported and leaks nothing" {
    // `api_keys` is non-empty on purpose: the keyed register is the only path
    // that reaches `KeyPool.init`'s two-statement `try owned.append(allocator,
    // .{ .key = try allocator.dupe(u8, k) })`. The dupe succeeds while the append
    // grows, and only then can the append fail — at which point the duplicated
    // key is not yet in `owned.items` and the pool's `errdefer` cannot see it
    // (red: this test with `api_keys` empty passed, with one key it reported
    // `leaked [len: 4]` through the fail index that lands on the append).
    const Scan = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var reg = ProviderRegistry.init(allocator);
            defer reg.deinit();
            // New provider: strings, pool (with its owned keys), entry box, list
            // slot, by_name entry.
            try reg.register(std.testing.io, "p", "https://p/v1/chat/completions", &.{"sk-p"}, .{
                .models = &.{ "m1", "m2" },
                .fallback_providers = &.{"q"},
            });
            // Replacement: the replaced box must reach `retired` (or be freed
            // when the move to `retired` itself fails) and be freed by `deinit`.
            try reg.register(std.testing.io, "p", "https://p2/v1/chat/completions", &.{"sk-p2"}, .{
                .models = &.{"m1"},
            });
            // A second provider: the append + by_name path for a name that is
            // not a replacement.
            try reg.register(std.testing.io, "q", "https://q/v1/chat/completions", &.{ "sk-q1", "sk-q2" }, .{
                .models = &.{"m1"},
            });
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Scan.run, .{});
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

// The five registry waits that have an error channel: `register`, `acquire`,
// `enableProvider`, `enableKey` and `listProviders` all return errors and abandon
// nothing when the wait is canceled *before* the critical section (no provider is
// registered, retired or copied; no key is enabled; no lease is issued), so the
// cancelation is propagated as `error.Canceled`. The old `error.LockFailed` named
// lock-machinery failure for it. (`retiredCount` above returns `usize`, so it
// waits.)
//
// Red evidence: with `catch return error.LockFailed` the first assertion below
// reads `expected error.Canceled, found error.LockFailed`. The rest are the same
// lock shape; a `try` ends the test at the first failure, so they are only
// exercised green.
test "register, acquire, enableProvider, enableKey and listProviders report a canceled lock wait as error.Canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var reg = ProviderRegistry.init(allocator);
    defer reg.deinit();
    try reg.register(io, "p", "https://p/v1/chat/completions", &.{"sk-p"}, .{ .models = &.{"m"} });

    const RegisterRead = struct {
        var seen: ?anyerror = null;
        fn read(r: *ProviderRegistry) void {
            seen = null;
            r.register(std.testing.io, "q", "https://q/v1/chat/completions", &.{}, .{}) catch |err| {
                seen = err;
            };
        }
    };
    RegisterRead.seen = null;
    try readUnderCanceledLockWait(ProviderRegistry, &reg, &reg.mutex, io, RegisterRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), RegisterRead.seen);

    const AcquireRead = struct {
        var seen: ?anyerror = null;
        fn read(r: *ProviderRegistry) void {
            seen = null;
            _ = r.acquire(std.testing.io, "m") catch |err| {
                seen = err;
                return;
            };
        }
    };
    AcquireRead.seen = null;
    try readUnderCanceledLockWait(ProviderRegistry, &reg, &reg.mutex, io, AcquireRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), AcquireRead.seen);

    const EnableProviderRead = struct {
        var seen: ?anyerror = null;
        fn read(r: *ProviderRegistry) void {
            seen = null;
            r.enableProvider(std.testing.io, "p", false) catch |err| {
                seen = err;
            };
        }
    };
    EnableProviderRead.seen = null;
    try readUnderCanceledLockWait(ProviderRegistry, &reg, &reg.mutex, io, EnableProviderRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), EnableProviderRead.seen);

    const EnableKeyRead = struct {
        var seen: ?anyerror = null;
        fn read(r: *ProviderRegistry) void {
            seen = null;
            r.enableKey(std.testing.io, "p", 0) catch |err| {
                seen = err;
            };
        }
    };
    EnableKeyRead.seen = null;
    try readUnderCanceledLockWait(ProviderRegistry, &reg, &reg.mutex, io, EnableKeyRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), EnableKeyRead.seen);

    const ListRead = struct {
        var seen: ?anyerror = null;
        fn read(r: *ProviderRegistry) void {
            seen = null;
            const infos = r.listProviders(std.testing.io, std.testing.allocator) catch |err| {
                seen = err;
                return;
            };
            for (infos) |*p| p.deinit(std.testing.allocator);
            std.testing.allocator.free(infos);
        }
    };
    ListRead.seen = null;
    try readUnderCanceledLockWait(ProviderRegistry, &reg, &reg.mutex, io, ListRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), ListRead.seen);
}

var fake_now: i64 = 1_000_000;
fn fakeNow() i64 {
    return fake_now;
}
