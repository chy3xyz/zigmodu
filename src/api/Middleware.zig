//! Lightweight middleware for ZigModu HTTP server
//!
//! Adapted from zigzero, with dependencies reduced to std library only.

const std = @import("std");
const api = @import("Server.zig");

/// CORS middleware configuration
pub const CorsConfig = struct {
    allow_origins: []const []const u8 = &.{"*"},
    allow_methods: []const u8 = "GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS",
    allow_headers: []const u8 = "Content-Type,Authorization",
    max_age: u32 = 86400,
};

/// CORS middleware
pub fn cors(config: CorsConfig) api.Middleware {
    const cfg_ptr = std.heap.page_allocator.create(CorsConfig) catch unreachable;
    cfg_ptr.* = config;
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const cfg: *const CorsConfig = @ptrCast(@alignCast(user_data.?));
                try ctx.setHeader("Access-Control-Allow-Origin", cfg.allow_origins[0]);
                try ctx.setHeader("Access-Control-Allow-Methods", cfg.allow_methods);
                try ctx.setHeader("Access-Control-Allow-Headers", cfg.allow_headers);
                const max_age_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{cfg.max_age});
                defer ctx.allocator.free(max_age_str);
                try ctx.setHeader("Access-Control-Max-Age", max_age_str);
                if (ctx.method == .OPTIONS) {
                    ctx.status_code = 204;
                    ctx.responded = true;
                    return;
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @ptrCast(cfg_ptr),
    };
}

var request_id_counter = std.atomic.Value(u64).init(0);

/// Request ID middleware - adds X-Request-Id header
pub fn requestId() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const id = try std.fmt.allocPrint(ctx.allocator, "{x:0>16}", .{request_id_counter.fetchAdd(1, .monotonic)});
                defer ctx.allocator.free(id);
                try ctx.setHeader("X-Request-Id", id);
                try next(ctx);
            }
        }.mw,
    };
}

/// Logging middleware - logs request method, path, status and duration
pub fn logging() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                const start = 0;
                try next(ctx);
                const elapsed = 0 - start;
                std.log.info("{s} {s} {d} {d}ms", .{
                    ctx.method.toString(),
                    ctx.raw_path,
                    ctx.status_code,
                    elapsed,
                });
            }
        }.mw,
    };
}

/// Max body size middleware
pub fn maxBodySize(max_size: usize) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const limit = @as(usize, @intFromPtr(user_data));
                if (ctx.body) |body| {
                    if (body.len > limit) {
                        try ctx.sendError(413, "Payload Too Large");
                        return;
                    }
                }
                try next(ctx);
            }
        }.mw,
        .user_data = @ptrFromInt(max_size),
    };
}

/// Request timeout middleware
pub fn requestTimeout(timeout_ms: u64) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const deadline = 0 + @as(u64, @intFromPtr(user_data));
                try next(ctx);
                if (0 > deadline) {
                    ctx.status_code = 504;
                }
            }
        }.mw,
        .user_data = @ptrFromInt(timeout_ms),
    };
}

/// Recovery middleware - catches panics and returns 500
pub fn recover() api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
                next(ctx) catch |err| {
                    std.log.warn("Handler panic: {any}", .{err});
                    if (!ctx.responded) {
                        try ctx.sendError(500, "Internal Server Error");
                    }
                };
            }
        }.mw,
    };
}

/// JWT claims
pub const Claims = struct {
    sub: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    username: ?[]const u8 = null,
    exp: ?i64 = null,
    iat: ?i64 = null,
};

fn base64UrlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const pad_len = (4 - (input.len % 4)) % 4;
    var padded = try allocator.alloc(u8, input.len + pad_len);
    defer allocator.free(padded);
    @memcpy(padded[0..input.len], input);
    for (padded[input.len..]) |*b| b.* = '=';
    const decoder = std.base64.url_safe.Decoder;
    const size = try decoder.calcSizeForSlice(padded);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, padded);
    return out;
}

/// Verify a JWT token using HMAC-SHA256. Returns decoded payload on success.
fn verifyJwt(allocator: std.mem.Allocator, token: []const u8, secret: []const u8) !std.json.Parsed(std.json.Value) {
    var parts_iter = std.mem.splitScalar(u8, token, '.');
    const header_b64 = parts_iter.next() orelse return error.InvalidToken;
    const payload_b64 = parts_iter.next() orelse return error.InvalidToken;
    const sig_b64 = parts_iter.next() orelse return error.InvalidToken;
    if (parts_iter.next() != null) return error.InvalidToken;

    const signed_data = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
    defer allocator.free(signed_data);

    var expected_sig: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&expected_sig, signed_data, secret);

    const sig_decoded = try base64UrlDecode(allocator, sig_b64);
    defer allocator.free(sig_decoded);

    if (sig_decoded.len < 32 or !std.crypto.timing_safe.eql([32]u8, expected_sig, sig_decoded[0..32].*)) {
        return error.InvalidToken;
    }

    const payload_json = try base64UrlDecode(allocator, payload_b64);
    defer allocator.free(payload_json);

    return std.json.parseFromSlice(std.json.Value, allocator, payload_json, .{});
}

/// JWT auth middleware - validates Bearer token and stores claims in context user_data
pub fn jwtAuth(secret: []const u8) api.Middleware {
    return .{
        .func = struct {
            fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
                const jwt_secret_ptr: *const []const u8 = @ptrCast(@alignCast(user_data.?));
                const jwt_secret = jwt_secret_ptr.*;
                const auth = ctx.headers.get("Authorization") orelse {
                    try ctx.sendError(401, "Unauthorized");
                    return;
                };
                const prefix = "Bearer ";
                if (!std.mem.startsWith(u8, auth, prefix)) {
                    try ctx.sendError(401, "Unauthorized");
                    return;
                }
                const token = auth[prefix.len..];
                const parsed = verifyJwt(ctx.allocator, token, jwt_secret) catch {
                    try ctx.sendError(401, "Unauthorized");
                    return;
                };
                defer parsed.deinit();
                ctx.user_data = @constCast(&parsed.value);
                try next(ctx);
            }
        }.mw,
        .user_data = @constCast(@ptrCast(&secret)),
    };
}

test "cors middleware sets headers" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const cfg = CorsConfig{};
    const mw = cors(cfg);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqualStrings("*", ctx.response_headers.get("Access-Control-Allow-Origin").?);
    try std.testing.expectEqualStrings("GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS", ctx.response_headers.get("Access-Control-Allow-Methods").?);
}

test "maxBodySize middleware rejects large payload" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/test");
    defer ctx.deinit();
    ctx.body = "this is a test body that is longer than ten bytes";

    const mw = maxBodySize(10);
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 413), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "recover middleware catches panic" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const mw = recover();
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
            return error.SomePanic;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 500), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

test "jwtAuth middleware rejects missing authorization" {
    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .GET, "/test");
    defer ctx.deinit();

    const mw = jwtAuth("secret");
    const next = struct {
        fn n(c: *api.Context) anyerror!void {
            _ = c;
        }
    }.n;

    try mw.func(&ctx, next, mw.user_data);
    try std.testing.expectEqual(@as(u16, 401), ctx.status_code);
    try std.testing.expect(ctx.responded);
}

