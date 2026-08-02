//! Provider registry — concurrency-safe registration of LLM providers, each
//! with its own `KeyPool`, model routing and provider-level fallback.
//!
//! `acquire(model)` resolves the model to the provider serving it, then to a
//! healthy key inside that provider's pool. When the primary provider has no
//! healthy key (or is disabled), the fallback provider chain is tried in
//! order — this is the "provider + key rotation" layer on top of `KeyPool`.

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
    providers: std.ArrayList(ProviderEntry),
    by_name: std.StringHashMap(usize),
    mutex: std.Io.Mutex,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .providers = std.ArrayList(ProviderEntry).empty,
            .by_name = std.StringHashMap(usize).init(allocator),
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.providers.items) |*p| {
            self.allocator.free(p.name);
            self.allocator.free(p.endpoint);
            for (p.models) |m| self.allocator.free(m);
            self.allocator.free(p.models);
            for (p.fallback_providers) |f| self.allocator.free(f);
            self.allocator.free(p.fallback_providers);
            p.pool.deinit();
        }
        self.providers.deinit(self.allocator);
        var it = self.by_name.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.by_name.deinit();
        self.* = undefined;
    }

    /// Register (or replace) a provider: name → endpoint + key pool + models.
    pub fn register(
        self: *Self,
        io: std.Io,
        name: []const u8,
        endpoint: []const u8,
        api_keys: []const []const u8,
        opts: ProviderOpts,
    ) !void {
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        try self.registerLocked(name, endpoint, api_keys, opts);
    }

    fn registerLocked(
        self: *Self,
        name: []const u8,
        endpoint: []const u8,
        api_keys: []const []const u8,
        opts: ProviderOpts,
    ) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_endpoint = try self.allocator.dupe(u8, endpoint);
        errdefer self.allocator.free(owned_endpoint);
        const owned_models = try self.allocator.alloc([]const u8, opts.models.len);
        errdefer self.allocator.free(owned_models);
        for (opts.models, 0..) |m, i| owned_models[i] = try self.allocator.dupe(u8, m);
        const owned_fallbacks = try self.allocator.alloc([]const u8, opts.fallback_providers.len);
        errdefer self.allocator.free(owned_fallbacks);
        for (opts.fallback_providers, 0..) |f, i| owned_fallbacks[i] = try self.allocator.dupe(u8, f);
        var pool = try KeyPool.init(self.allocator, api_keys, opts.pool_opts);
        errdefer pool.deinit();

        const entry = ProviderEntry{
            .name = owned_name,
            .endpoint = owned_endpoint,
            .models = owned_models,
            .fallback_providers = owned_fallbacks,
            .pool = pool,
            .enabled = opts.enabled,
        };
        if (self.by_name.get(name)) |idx| {
            const old = &self.providers.items[idx];
            self.allocator.free(old.name);
            self.allocator.free(old.endpoint);
            for (old.models) |m| self.allocator.free(m);
            self.allocator.free(old.models);
            for (old.fallback_providers) |f| self.allocator.free(f);
            self.allocator.free(old.fallback_providers);
            old.pool.deinit();
            self.providers.items[idx] = entry;
            return;
        }
        const new_idx = self.providers.items.len;
        try self.providers.append(self.allocator, entry);
        try self.by_name.put(try self.allocator.dupe(u8, name), new_idx);
    }

    /// Resolve `model` to a provider (provider rotation) and a healthy key
    /// (key rotation). Tries the provider serving the model, then its
    /// fallback providers in order.
    pub fn acquire(self: *Self, io: std.Io, model: []const u8) !ProviderLease {
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        const lease = try self.acquireLocked(io, model);
        return lease;
    }

    fn acquireLocked(self: *Self, io: std.Io, model: []const u8) !ProviderLease {
        var chain: [16]usize = undefined;
        var n: usize = 0;
        // Primary provider(s) serving this model.
        for (self.providers.items, 0..) |*p, idx| {
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
            const p = &self.providers.items[pidx];
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
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        const idx = self.by_name.get(name) orelse return error.ProviderNotFound;
        self.providers.items[idx].enabled = enabled;
    }

    pub fn enableKey(self: *Self, io: std.Io, provider: []const u8, key_index: usize) !void {
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);
        const idx = self.by_name.get(provider) orelse return error.ProviderNotFound;
        try self.providers.items[idx].pool.enableKey(io, key_index);
    }

    /// Snapshot the provider table (owned by the caller).
    pub fn listProviders(self: *Self, io: std.Io, allocator: std.mem.Allocator) ![]ProviderInfo {
        self.mutex.lock(io) catch return error.LockFailed;
        defer self.mutex.unlock(io);

        var out = std.ArrayList(ProviderInfo).empty;
        errdefer {
            for (out.items) |*p| p.deinit(allocator);
            out.deinit(allocator);
        }
        for (self.providers.items) |*p| {
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

var fake_now: i64 = 1_000_000;
fn fakeNow() i64 {
    return fake_now;
}
