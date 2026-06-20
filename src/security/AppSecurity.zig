//! Production security bundle: `SecurityModule` wired to `std.Io` wall clock + HTTP middleware helpers.

const std = @import("std");
const api = @import("../api/Server.zig");
const http_middleware = @import("../api/Middleware.zig");
const SecurityModule = @import("SecurityModule.zig").SecurityModule;
const AuthMiddleware = @import("AuthMiddleware.zig");

pub const AppSecurity = struct {
    module: SecurityModule,

    pub const Config = struct {
        jwt_secret: []const u8,
        token_expiry_seconds: i64 = 3600,
    };

    /// Prefer this over `SecurityModule.init` in HTTP servers — uses wall-clock JWT exp.
    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: Config) AppSecurity {
        return .{
            .module = SecurityModule.initWithIo(allocator, config.jwt_secret, config.token_expiry_seconds, io),
        };
    }

    pub fn jwtMiddleware(self: *AppSecurity) api.Middleware {
        return http_middleware.jwtAuthWithSecurity(&self.module);
    }

    /// RBAC-aware JWT middleware (sets `Rbac.AuthInfo` in `ctx.user_data`).
    pub fn rbacJwtMiddleware(self: *AppSecurity, allocator: std.mem.Allocator) !api.Middleware {
        return AuthMiddleware.jwtAuth(&self.module, allocator);
    }

    pub fn generateToken(self: *AppSecurity, user_id: []const u8, roles: []const []const u8) ![]const u8 {
        return self.module.generateToken(user_id, roles);
    }
};

test "AppSecurity init uses io for token issue and verify" {
    const allocator = std.testing.allocator;
    var sec = AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    const token = try sec.generateToken("42", &.{});
    defer allocator.free(token);
    const payload = try sec.module.verifyToken(token);
    defer sec.module.freePayload(payload);
    try std.testing.expectEqualStrings("42", payload.sub);
}
