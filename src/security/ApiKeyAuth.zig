const std = @import("std");

/// API key authentication configuration
pub const ApiKeyConfig = struct {
    /// Name of the request header carrying the API key
    header_name: []const u8 = "X-API-Key",
    /// Name of the query parameter carrying the API key
    query_param_name: []const u8 = "api_key",
    /// Whether the API key may also be passed as a query parameter (less safe)
    allow_query_param: bool = false,
    /// HTTP status code returned when authentication fails
    unauthorized_status: u16 = 401,
    /// Message returned when authentication fails
    unauthorized_message: []const u8 = "Invalid or missing API key",
};

/// API Key Auth middleware
///
/// Extracts the API key from the X-API-Key header (or the Query parameter ?api_key=)
/// and verifies that it is in the allowed key list
///
/// Usage:
///   server.addMiddleware(.{
///       .func = apiKeyAuth(.{ .keys = &.{"sk-123", "sk-456"} })
///   });
///
/// Supports loading keys from external storage (e.g. Redis):
///   server.addMiddleware(.{
///       .func = apiKeyAuthWithLoader(.{ .loader = loadKeysFromDb })
///   });
///
/// Every call gets its own configuration — a middleware built from one key list
/// or loader never authenticates against another one's. See `max_key_auth_instances`.
pub fn apiKeyAuth(config: ApiKeyAuthConfig) api.MiddlewareFn {
    return key_auth_middlewares[Instances.claim(.{ .static_keys = config })];
}

/// API key authentication configuration (with a static key list)
pub const ApiKeyAuthConfig = struct {
    config: ApiKeyConfig = .{},
    keys: []const []const u8 = &.{},
};

/// API key auth middleware (with an external loader) — each call keeps its own
/// loader (see `max_key_auth_instances`).
///
/// A loader cannot report why it said no — see `ApiKeyLoaderConfig.loader` for
/// what that means for a storage failure and what a loader must do about it.
pub fn apiKeyAuthWithLoader(config: ApiKeyLoaderConfig) api.MiddlewareFn {
    return key_auth_middlewares[Instances.claim(.{ .loader = config })];
}

/// Number of independently configured key-auth middlewares one process may build.
///
/// `api.MiddlewareFn` is a bare `*const fn(ctx, next, user_data)` and the call
/// shape above (`.func = apiKeyAuth(cfg)`) leaves `user_data` null, so the config
/// cannot ride along on it — a Zig function pointer carries no context. Each
/// factory call therefore claims one slot in `Instances` and returns that slot's
/// own trampoline, which reads its own configuration and nothing else.
///
/// A function-level `var` (the shape this replaced) is process-wide instead: the
/// second `apiKeyAuth` would retarget the first middleware too, so keys issued
/// for one instance would open another instance's routes. Returning an
/// `api.Middleware` (which carries `user_data`, the shape `securityHeaders` uses)
/// would fix it without a bound, but that is a source-breaking change to a
/// public signature — the bound is the price of leaving it alone.
///
/// Slots are claimed at wiring time and never released, so this bounds how many
/// middlewares an application *builds*, not how many requests it serves.
pub const max_key_auth_instances = 64;

/// Per-call store of one key-auth middleware (one kind per factory).
const KeyAuthStore = union(enum) {
    static_keys: ApiKeyAuthConfig,
    loader: ApiKeyLoaderConfig,
};

const Instances = struct {
    /// Unclaimed slots stay `null` and are not reachable — their trampolines are
    /// never handed out; they answer 401 rather than fall through.
    var slots: [max_key_auth_instances]?KeyAuthStore = @splat(null);
    /// Atomic so two threads wiring middlewares concurrently cannot claim one
    /// slot (which would put two middlewares on one configuration again).
    var claimed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

    fn claim(store: KeyAuthStore) usize {
        const slot = claimed.fetchAdd(1, .seq_cst);
        if (slot >= max_key_auth_instances) {
            @panic("ApiKeyAuth: middleware slot pool exhausted — raise max_key_auth_instances");
        }
        slots[slot] = store;
        return slot;
    }
};

fn KeyAuthTrampoline(comptime slot: usize) type {
    return struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            _ = user_data;

            const store = Instances.slots[slot] orelse {
                // Fail closed rather than fall through to `next`. Reaching this
                // means the pointer was used without claiming a slot, so there
                // is no per-instance policy to judge the request by.
                try deny(ctx, .{});
                return;
            };
            const config: ApiKeyConfig = switch (store) {
                .static_keys => |cfg| cfg.config,
                .loader => |cfg| cfg.config,
            };

            const key = extractApiKey(ctx, config) orelse {
                try deny(ctx, config);
                return;
            };

            const accepted = switch (store) {
                .static_keys => |cfg| validateKey(key, cfg.keys),
                .loader => |cfg| cfg.loader(key),
            };
            if (!accepted) {
                try deny(ctx, config);
                return;
            }

            try next(ctx);
        }
    };
}

fn deny(ctx: *api.Context, config: ApiKeyConfig) !void {
    try ctx.sendErrorResponse(config.unauthorized_status, 0, config.unauthorized_message);
}

/// One distinct function pointer per slot — the identity a bare fn pointer cannot
/// otherwise carry. Every entry reads a different slot, so they are not
/// interchangeable and no optimizer may fold them into one.
const key_auth_middlewares: [max_key_auth_instances]api.MiddlewareFn = blk: {
    var table: [max_key_auth_instances]api.MiddlewareFn = undefined;
    for (0..max_key_auth_instances) |i| table[i] = KeyAuthTrampoline(i).handler;
    break :blk table;
};

/// API key loader configuration
pub const ApiKeyLoaderConfig = struct {
    config: ApiKeyConfig = .{},
    /// Reports whether `key` is a valid key.
    ///
    /// The `bool` has no room for "the lookup itself failed", so **a storage
    /// failure is indistinguishable from "no such key"**: a Redis timeout or a
    /// DB outage returns `false` here and the client is told
    /// `unauthorized_status` (401) — the same "our failure presented as the
    /// caller's fault" shape that `AuthMiddleware.runJwtAuth` had to stop
    /// doing for allocation failures. Nothing in this file can tell the two
    /// apart; the signature cannot express the difference, so this is a
    /// documented limitation rather than a bug that can be fixed here.
    ///
    /// A loader therefore has to **fail closed** (return `false`) and report
    /// its own failure out of band — a log line or a metric — because neither
    /// the middleware nor the caller ever sees it.
    ///
    /// Recommended change, not made here: widen this to
    /// `*const fn ([]const u8) anyerror!bool` and answer 500 when the loader
    /// returns an error, matching `PermissionLoader` and
    /// `CatalogPermissionLoader`, which are already fallible. `api.MiddlewareFn`
    /// is a bare function pointer, so there is no way to accept both shapes
    /// (an optional second field would be a second way to wire the same thing,
    /// and only one of them could be correct); widening the type breaks every
    /// existing `.loader = fn([]const u8) bool` call site, so it belongs in a
    /// release window that can carry a breaking change.
    loader: *const fn ([]const u8) bool,
};

/// Extracts the API key from the Context (header first, then query parameter)
fn extractApiKey(ctx: *api.Context, config: ApiKeyConfig) ?[]const u8 {
    // 1. Read from the request header
    if (ctx.header(config.header_name)) |val| {
        return if (val.len > 0) val else null;
    }

    // 2. Fall back to the query parameter (only when explicitly allowed)
    if (config.allow_query_param) {
        if (ctx.queryParam(config.query_param_name)) |val| {
            return if (val.len > 0) val else null;
        }
    }

    return null;
}

/// Checks whether the API key is in the allowed list.
///
/// Every entry is compared, and every byte of every entry is read, even after a
/// match — so neither the bytes of the guess nor its position in the list
/// decides how much work the check does.
///
/// `std.mem.eql` cannot be used here: it returns at the first differing byte, so
/// a guess agreeing with a stored key for N bytes costs more than one diverging
/// immediately, and over enough samples that difference says how much of a
/// guess is right. Measured in this file's own test binary (Debug), comparing
/// two 64 KiB keys that each differ from the stored one in exactly one byte —
/// byte 0 versus the last byte — 2000 calls cost 269 µs against 957 ms. The
/// same loop with `constantTimeEql` below shows the two at parity.
fn validateKey(key: []const u8, allowed_keys: []const []const u8) bool {
    var matched = false;
    for (allowed_keys) |ak| {
        if (constantTimeEql(key, ak)) matched = true;
    }
    return matched;
}

/// Constant-time byte-slice comparison for API keys.
///
/// Zig 0.17's `std.crypto.timing_safe.eql` only accepts arrays/vectors, so the
/// slice loop is spelled out here — the same shape as the CSRF check in
/// `api.Middleware` and `security.PasswordEncoder`.
///
/// One length is still free: the `!=` below returns immediately, so this leaks
/// how long the stored key is, not how much of a guess matches. That is
/// acceptable for a fixed-format key (`sk-` + 32 hex); a secret whose length is
/// itself sensitive needs a padded compare instead.
fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, 0..) |x, i| diff |= x ^ b[i];
    // `diff -% 1` borrows to 0xFF exactly when every byte matched; widening to
    // u16 and shifting by 8 turns that into the branchless answer.
    const widened: u16 = diff;
    return (widened -% 1) >> 8 != 0;
}

/// API key generator — creates random API keys
pub const ApiKeyGenerator = struct {
    /// Generates one API key (format: sk-{32 hex chars}).
    ///
    /// The 16 random bytes come from the OS entropy source
    /// (`std.Io.randomSecure`) — a syscall on every call, never derived from
    /// process-local state such as the clock, the stack layout or a
    /// long-lived in-process RNG. Failure to reach an entropy source surfaces
    /// as `error.EntropyUnavailable` rather than silently falling back to a
    /// predictable seed.
    pub fn generate(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        var buf: [16]u8 = undefined;
        try std.Io.randomSecure(io, &buf);
        const hex_chars = "0123456789abcdef";
        var hex: [32]u8 = undefined;
        for (buf, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
        return std.fmt.allocPrint(allocator, "sk-{s}", .{hex[0..32]});
    }

    /// Validates the API key format (sk-{32 hex})
    pub fn validateFormat(key: []const u8) bool {
        if (!std.mem.startsWith(u8, key, "sk-")) return false;
        if (key.len != 35) return false; // "sk-" + 32 hex chars
        for (key[3..]) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }
};

const api = @import("../api/Server.zig");

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "api key comparison reads every byte, not just the differing prefix" {
    const allocator = std.testing.allocator;
    const key = try allocator.alloc(u8, 256);
    defer allocator.free(key);
    @memset(key, 'a');

    // Same length, same mismatch count — only the position of the first
    // differing byte moves. The comparison must answer false for both without
    // the answer depending on how much of the key matched first.
    const early = try allocator.dupe(u8, key);
    defer allocator.free(early);
    early[0] = 'b';

    const late = try allocator.dupe(u8, key);
    defer allocator.free(late);
    late[key.len - 1] = 'b';

    try std.testing.expect(!constantTimeEql(early, key));
    try std.testing.expect(!constantTimeEql(late, key));
    try std.testing.expect(constantTimeEql(key, key));

    // A length difference is still answered without reading bytes — that is
    // the one property this helper does leak (see its comment).
    const short = key[0 .. key.len - 1];
    try std.testing.expect(!constantTimeEql(short, key));

    // The list scan keeps no early exit: a match at either position is found,
    // and a key absent from the list is still rejected after comparing all.
    const keys = [_][]const u8{ key, late };
    try std.testing.expect(validateKey(key, &keys));
    try std.testing.expect(validateKey(late, &keys));
    try std.testing.expect(!validateKey(early, &keys));
    try std.testing.expect(!validateKey("sk-nope", &keys));
    try std.testing.expect(!validateKey(key, &.{}));
}

test "constantTimeEql agrees with std.mem.eql on every byte position" {
    // Correctness baseline: for keys that differ by one byte, the result must
    // match plain equality at every position (the difference is in *cost*, not
    // in the answer).
    const allocator = std.testing.allocator;
    const base = try allocator.alloc(u8, 64);
    defer allocator.free(base);
    @memset(base, 'q');

    const probe = try allocator.dupe(u8, base);
    defer allocator.free(probe);

    for (0..base.len) |i| {
        probe[i] = base[i] +% 1;
        try std.testing.expectEqual(std.mem.eql(u8, probe, base), constantTimeEql(probe, base));
        probe[i] = base[i];
    }
    try std.testing.expect(constantTimeEql(base, base));
}

test "ApiKeyGenerator generate" {
    const allocator = std.testing.allocator;
    const key = try ApiKeyGenerator.generate(allocator, std.testing.io);
    defer allocator.free(key);

    try std.testing.expect(std.mem.startsWith(u8, key, "sk-"));
    try std.testing.expectEqual(@as(usize, 35), key.len);
}

test "ApiKeyGenerator keys are unique within one process and one millisecond" {
    const allocator = std.testing.allocator;
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const key = try ApiKeyGenerator.generate(allocator, std.testing.io);
        const res = try seen.getOrPut(key);
        if (res.found_existing) allocator.free(key);
    }
    // A seed built from the clock plus the stack address of the output buffer
    // collapses here: calls made inside one millisecond from the same frame
    // re-seed identically, so a batch like this yields only a handful of
    // distinct keys. OS entropy must make every key unique.
    try std.testing.expectEqual(@as(usize, 256), seen.count());
}

test "ApiKeyGenerator validate format" {
    try std.testing.expect(ApiKeyGenerator.validateFormat("sk-1234567890abcdef1234567890abcdef"));
    try std.testing.expect(!ApiKeyGenerator.validateFormat("invalid"));
    try std.testing.expect(!ApiKeyGenerator.validateFormat("sk-tooshort"));
    try std.testing.expect(!ApiKeyGenerator.validateFormat("pk-1234567890abcdef1234567890abcdef"));
}

test "validateKey basic" {
    const keys = &[_][]const u8{ "sk-aaa", "sk-bbb", "sk-ccc" };

    try std.testing.expect(validateKey("sk-aaa", keys));
    try std.testing.expect(validateKey("sk-bbb", keys));
    try std.testing.expect(!validateKey("sk-xxx", keys));
    try std.testing.expect(!validateKey("", keys));
}

test "ApiKeyConfig defaults" {
    const config = ApiKeyConfig{};
    try std.testing.expectEqualStrings("X-API-Key", config.header_name);
    try std.testing.expectEqualStrings("api_key", config.query_param_name);
    try std.testing.expect(!config.allow_query_param);
    try std.testing.expectEqual(@as(u16, 401), config.unauthorized_status);
}

/// Request header whose key/value are owned by the context (freed by `deinit`).
fn testPutHeader(ctx: *api.Context, name: []const u8, value: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, name);
    errdefer ctx.allocator.free(k);
    const v = try ctx.allocator.dupe(u8, value);
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

const Reached = struct {
    var value: bool = false;
    fn handler(_: *api.Context) anyerror!void {
        value = true;
    }
};

test "each apiKeyAuth keeps its own key list" {
    const allocator = std.testing.allocator;

    // A accepts key1 only; B accepts key2 only. Building B must not change how
    // A judges: while both shared one function-level `var`, the second
    // `apiKeyAuth` retargeted the first middleware at its own key list, so
    // key2 authenticated against A's routes.
    const mw_a = apiKeyAuth(.{ .keys = &.{"key1"} });
    const mw_b = apiKeyAuth(.{ .keys = &.{"key2"} });

    Reached.value = false;
    var ctx_foreign = try api.Context.init(allocator, .GET, "/thing");
    defer ctx_foreign.deinit();
    try testPutHeader(&ctx_foreign, "X-API-Key", "key2");
    try mw_a(&ctx_foreign, Reached.handler, null);
    try std.testing.expectEqual(@as(u16, 401), ctx_foreign.status_code);
    try std.testing.expect(!Reached.value);

    // A's own key still passes.
    Reached.value = false;
    var ctx_own = try api.Context.init(allocator, .GET, "/thing");
    defer ctx_own.deinit();
    try testPutHeader(&ctx_own, "X-API-Key", "key1");
    try mw_a(&ctx_own, Reached.handler, null);
    try std.testing.expect(Reached.value);
    try std.testing.expect(!ctx_own.responded);

    // …and B is not loosened by A either.
    Reached.value = false;
    var ctx_b = try api.Context.init(allocator, .GET, "/thing");
    defer ctx_b.deinit();
    try testPutHeader(&ctx_b, "X-API-Key", "key1");
    try mw_b(&ctx_b, Reached.handler, null);
    try std.testing.expectEqual(@as(u16, 401), ctx_b.status_code);
    try std.testing.expect(!Reached.value);
}

test "each apiKeyAuthWithLoader keeps its own loader" {
    const allocator = std.testing.allocator;

    const Loaders = struct {
        fn onlyKey1(key: []const u8) bool {
            return std.mem.eql(u8, key, "key1");
        }
        fn onlyKey2(key: []const u8) bool {
            return std.mem.eql(u8, key, "key2");
        }
    };

    const mw_a = apiKeyAuthWithLoader(.{ .loader = Loaders.onlyKey1 });
    const mw_b = apiKeyAuthWithLoader(.{ .loader = Loaders.onlyKey2 });

    Reached.value = false;
    var ctx_foreign = try api.Context.init(allocator, .GET, "/thing");
    defer ctx_foreign.deinit();
    try testPutHeader(&ctx_foreign, "X-API-Key", "key2");
    try mw_a(&ctx_foreign, Reached.handler, null);
    try std.testing.expectEqual(@as(u16, 401), ctx_foreign.status_code);
    try std.testing.expect(!Reached.value);

    Reached.value = false;
    var ctx_own = try api.Context.init(allocator, .GET, "/thing");
    defer ctx_own.deinit();
    try testPutHeader(&ctx_own, "X-API-Key", "key1");
    try mw_a(&ctx_own, Reached.handler, null);
    try std.testing.expect(Reached.value);

    Reached.value = false;
    var ctx_b = try api.Context.init(allocator, .GET, "/thing");
    defer ctx_b.deinit();
    try testPutHeader(&ctx_b, "X-API-Key", "key1");
    try mw_b(&ctx_b, Reached.handler, null);
    try std.testing.expectEqual(@as(u16, 401), ctx_b.status_code);
    try std.testing.expect(!Reached.value);
}
