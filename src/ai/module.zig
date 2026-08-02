//! AI key module — the top-level manager wiring `ProviderRegistry` +
//! `KeyPool` into `AiProvider`.
//!
//! `AiKeyManager` owns provider registration (endpoint + api_keys + models +
//! fallback providers) and the pool lifecycle; `acquire(model)` performs
//! provider rotation (fallback chain) and key rotation (per-provider pool);
//! `providerFor` returns an `AiProvider` already bound to the leased key so
//! `chat` auto-rotates the key on 401/403/402/429 and retries once.

const std = @import("std");
const provider_registry = @import("provider_registry.zig");
const provider_mod = @import("provider.zig");
const key_pool = @import("key_pool.zig");

pub const KeyPool = provider_registry.KeyPool;
pub const KeyErrorKind = provider_registry.KeyErrorKind;
pub const ProviderLease = provider_registry.ProviderLease;
pub const ProviderInfo = provider_registry.ProviderInfo;

/// Declarative provider config: name + endpoint + api_keys + models.
pub const ProviderConfig = struct {
    name: []const u8,
    endpoint: []const u8,
    api_keys: []const []const u8,
    models: []const []const u8 = &.{},
    fallback_providers: []const []const u8 = &.{},
    enabled: bool = true,
    pool_opts: key_pool.Options = .{},
};

pub const AiKeyManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    registry: provider_registry.ProviderRegistry,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .registry = provider_registry.ProviderRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.registry.deinit();
        self.* = undefined;
    }

    /// Register providers from declarative configs (api_keys + lifecycle).
    pub fn applyConfig(self: *Self, configs: []const ProviderConfig) !void {
        for (configs) |cfg| {
            try self.registry.register(self.io, cfg.name, cfg.endpoint, cfg.api_keys, .{
                .models = cfg.models,
                .fallback_providers = cfg.fallback_providers,
                .enabled = cfg.enabled,
                .pool_opts = cfg.pool_opts,
            });
        }
    }

    pub fn registerProvider(self: *Self, cfg: ProviderConfig) !void {
        try self.registry.register(self.io, cfg.name, cfg.endpoint, cfg.api_keys, .{
            .models = cfg.models,
            .fallback_providers = cfg.fallback_providers,
            .enabled = cfg.enabled,
            .pool_opts = cfg.pool_opts,
        });
    }

    /// Provider rotation (fallback chain) + key rotation (pool), by model.
    pub fn acquire(self: *Self, model: []const u8) !ProviderLease {
        return self.registry.acquire(self.io, model);
    }

    pub fn onSuccess(self: *Self, lease: ProviderLease) void {
        self.registry.onSuccess(self.io, lease);
    }

    pub fn onError(self: *Self, lease: ProviderLease, kind: KeyErrorKind) void {
        self.registry.onError(self.io, lease, kind);
    }

    /// Acquire a lease and return an `AiProvider` bound to the pool, so
    /// `chat`/`chatWith` rotate the key on 401/403/402/429 and retry once.
    /// The manager must outlive the provider.
    pub fn providerFor(
        self: *Self,
        allocator: std.mem.Allocator,
        http: *@import("../http/HttpClient.zig").HttpClient,
        model: []const u8,
    ) !provider_mod.AiProvider {
        const lease = try self.acquire(model);
        var provider = provider_mod.AiProvider.init(allocator, http, lease.endpoint, lease.key, lease.model);
        provider.bindKeyPool(self.io, lease.pool, lease.key_index);
        return provider;
    }

    pub fn listProviders(self: *Self, allocator: std.mem.Allocator) ![]ProviderInfo {
        return self.registry.listProviders(self.io, allocator);
    }

    pub fn enableProvider(self: *Self, name: []const u8, enabled: bool) !void {
        try self.registry.enableProvider(self.io, name, enabled);
    }

    pub fn enableKey(self: *Self, provider: []const u8, key_index: usize) !void {
        try self.registry.enableKey(self.io, provider, key_index);
    }
};

// ── tests ─────────────────────────────────────────────────────────────────

test "AiKeyManager applyConfig + provider/key rotation + snapshot" {
    const allocator = std.testing.allocator;
    fake_now = 1_000_000;
    var mgr = AiKeyManager.init(allocator, std.testing.io);
    defer mgr.deinit();

    try mgr.applyConfig(&.{
        .{
            .name = "deepseek",
            .endpoint = "https://d/v1/chat/completions",
            .api_keys = &.{ "sk-d1", "sk-d2" },
            .models = &.{"deepseek-v4-flash"},
            .fallback_providers = &.{"openai"},
            .pool_opts = .{ .cooldown_base_ms = 1_000, .cooldown_max_ms = 8_000, .now_fn = fakeNow },
        },
        .{
            .name = "openai",
            .endpoint = "https://o/v1/chat/completions",
            .api_keys = &.{"sk-o1"},
            .models = &.{"deepseek-v4-flash"},
        },
    });

    const l1 = try mgr.acquire("deepseek-v4-flash");
    try std.testing.expectEqualStrings("deepseek", l1.provider);
    try std.testing.expectEqualStrings("sk-d1", l1.key);
    mgr.onError(l1, .rate_limit); // sk-d1 cools

    const l2 = try mgr.acquire("deepseek-v4-flash");
    try std.testing.expectEqualStrings("sk-d2", l2.key);
    mgr.onError(l2, .rate_limit); // sk-d2 cools too -> fallback provider

    const l3 = try mgr.acquire("deepseek-v4-flash");
    try std.testing.expectEqualStrings("openai", l3.provider);
    try std.testing.expectEqualStrings("sk-o1", l3.key);
    mgr.onSuccess(l3);

    const infos = try mgr.listProviders(allocator);
    defer {
        for (infos) |*p| p.deinit(allocator);
        allocator.free(infos);
    }
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expectEqual(@as(u64, 1), infos[1].keys[0].total_calls);
}

var fake_now: i64 = 1_000_000;
fn fakeNow() i64 {
    return fake_now;
}
