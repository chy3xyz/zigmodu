const std = @import("std");

/// API Key 认证配置
pub const ApiKeyConfig = struct {
    /// API Key 在请求头中的名称
    header_name: []const u8 = "X-API-Key",
    /// API Key 在 Query 参数中的名称
    query_param_name: []const u8 = "api_key",
    /// 是否允许通过 Query 参数传递 (安全性较低)
    allow_query_param: bool = false,
    /// 认证失败时的 HTTP 状态码
    unauthorized_status: u16 = 401,
    /// 认证失败消息
    unauthorized_message: []const u8 = "Invalid or missing API key",
};

/// API Key 认证中间件
///
/// 从请求头 X-API-Key (或 Query 参数 ?api_key=) 中提取 API Key
/// 并验证其是否在允许的密钥列表中
///
/// 用法:
///   server.addMiddleware(.{
///       .func = apiKeyAuth(.{ .keys = &.{"sk-123", "sk-456"} })
///   });
///
/// 支持从外部存储加载密钥 (如数据库、Redis):
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

/// API Key 认证配置 (含密钥列表)
pub const ApiKeyAuthConfig = struct {
    config: ApiKeyConfig = .{},
    keys: []const []const u8 = &.{},
};

/// API Key 认证中间件 (带外部加载器)
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

/// API Key 加载器配置
pub const ApiKeyLoaderConfig = struct {
    config: ApiKeyConfig = .{},
    loader: *const fn ([]const u8) bool,
};

/// 从 Context 中提取 API Key (Header 优先，然后 Query)
fn extractApiKey(ctx: *api.Context, config: ApiKeyConfig) ?[]const u8 {
    // 1. 从 Header 提取
    if (ctx.header(config.header_name)) |val| {
        return if (val.len > 0) val else null;
    }

    // 2. 从 Query 参数提取 (如允许)
    if (config.allow_query_param) {
        if (ctx.queryParam(config.query_param_name)) |val| {
            return if (val.len > 0) val else null;
        }
    }

    return null;
}

/// 验证 API Key 是否在允许列表中
fn validateKey(key: []const u8, allowed_keys: []const []const u8) bool {
    for (allowed_keys) |ak| {
        if (std.mem.eql(u8, key, ak)) return true;
    }
    return false;
}

/// API Key 生成器 — 生成安全的随机 API Key
pub const ApiKeyGenerator = struct {
    /// 生成一个 API Key (格式: sk-{32 hex chars})
    pub fn generate(allocator: std.mem.Allocator) ![]const u8 {
        var buf: [16]u8 = undefined;
        var seed: [32]u8 = undefined;
        std.mem.writeInt(u64, seed[0..8], @intCast(std.time.milliTimestamp()), .little);
        std.mem.writeInt(u64, seed[8..16], @intCast(std.os.getpid() catch 0), .little);
        std.mem.writeInt(u64, seed[16..24], @intFromPtr(&buf), .little);
        std.mem.writeInt(u64, seed[24..32], @intCast(std.time.microTimestamp()), .little);
        var csprng = std.Random.DefaultCsprng.init(seed);
        csprng.fill(&buf);
        const hex_chars = "0123456789abcdef";
        var hex: [32]u8 = undefined;
        for (buf, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0x0F];
        }
        return std.fmt.allocPrint(allocator, "sk-{s}", .{hex[0..32]});
    }

    /// 验证 API Key 格式 (sk-{32 hex})
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
    const key = try ApiKeyGenerator.generate(allocator);
    defer allocator.free(key);

    try std.testing.expect(std.mem.startsWith(u8, key, "sk-"));
    try std.testing.expectEqual(@as(usize, 35), key.len);
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
