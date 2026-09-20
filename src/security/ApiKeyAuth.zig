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
pub fn apiKeyAuth(config: ApiKeyAuthConfig) api.MiddlewareFn {
    const S = struct {
        var cfg: ApiKeyAuthConfig = undefined;

        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            _ = user_data;

            const key = extractApiKey(ctx, cfg.config) orelse {
                try ctx.sendErrorResponse(cfg.config.unauthorized_status, 0, cfg.config.unauthorized_message);
                return;
            };

            if (!validateKey(key, cfg.keys)) {
                try ctx.sendErrorResponse(cfg.config.unauthorized_status, 0, cfg.config.unauthorized_message);
                return;
            }

            try next(ctx, next, null);
        }
    };
    S.cfg = config;
    return S.handler;
}

/// API key authentication configuration (with a static key list)
pub const ApiKeyAuthConfig = struct {
    config: ApiKeyConfig = .{},
    keys: []const []const u8 = &.{},
};

/// API key auth middleware (with an external loader)
pub fn apiKeyAuthWithLoader(config: ApiKeyLoaderConfig) api.MiddlewareFn {
    const S = struct {
        var cfg: ApiKeyLoaderConfig = undefined;

        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            _ = user_data;

            const key = extractApiKey(ctx, cfg.config) orelse {
                try ctx.sendErrorResponse(cfg.config.unauthorized_status, 0, cfg.config.unauthorized_message);
                return;
            };

            if (!cfg.loader(key)) {
                try ctx.sendErrorResponse(cfg.config.unauthorized_status, 0, cfg.config.unauthorized_message);
                return;
            }

            try next(ctx, next, null);
        }
    };
    S.cfg = config;
    return S.handler;
}

/// API key loader configuration
pub const ApiKeyLoaderConfig = struct {
    config: ApiKeyConfig = .{},
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

/// Checks whether the API key is in the allowed list
fn validateKey(key: []const u8, allowed_keys: []const []const u8) bool {
    for (allowed_keys) |ak| {
        if (std.mem.eql(u8, key, ak)) return true;
    }
    return false;
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
