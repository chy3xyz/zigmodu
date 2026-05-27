const std = @import("std");
const Validator = @import("../../validation/Validator.zig");

/// [...]Request bodyValidation middleware
///
/// [...] Validator.FieldRules [...]Validation[...]
/// [...] HTTP [...]Request body[...]failure[...] RFC 7807 [...]Error
///
/// Usage:
///   const UserReq = struct { name: []const u8, email: []const u8, age: u32 };
///
///   const rules = .{
///       .name  = FieldRules{ .required = true, .min_len = 2, .max_len = 50 },
///       .email = FieldRules{ .required = true, .email = true },
///       .age   = FieldRules{ .min = 0, .max = 150 },
///   };
///
///   try api.post("/users", struct {
///       fn handle(ctx: *Context) !void {
///           const req = try ctx.bindJson(UserReq);
///           try validateRequest(ctx, req, rules);
///           // ... req is now validated ...
///       }
///   }.handle, null);
pub fn validateRequest(
    ctx: anytype,
    value: anytype,
    comptime rules: anytype,
) !void {
    const err = Validator.validateStruct(ctx.allocator, value, rules) catch |e| {
        try ctx.sendError(500, @errorName(e));
        return e;
    };

    if (err) |msg| {
        defer ctx.allocator.free(msg);
        try ctx.sendErrorResponse(422, 0, msg);
        return error.ValidationFailed;
    }
}

/// [...]Request bodyValidation middleware ([...]Validation[...])
///
/// [...] Middleware chain [...] `X-Validate` header [...]Validation[...]
/// Or always for matching paths+[...]Validation[...]
///
/// Usage:
///   server.addMiddleware(.{ .func = validationMiddleware() });
///
/// [...] X-Validate-Schema: UserReq [...]Validation[...]
pub fn validationMiddleware() api.MiddlewareFn {
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            _ = user_data;

            // Check ifRequest validation
            if (ctx.header("X-Validate")) |_| {
                // [...]: [...]Validation ([...])
                // [...] handler [...]call validateRequest
            }

            try next(ctx, next, null);
        }
    };

    return S.handler;
}

const api = @import("../../api/Server.zig");

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "validateRequest passes for valid data" {
    const User = struct {
        name: []const u8,
        email: []const u8,
        age: u32,
    };

    const rules = .{
        .name = Validator.FieldRules{ .required = true, .min_len = 2 },
        .email = Validator.FieldRules{ .required = true, .email = true },
        .age = Validator.FieldRules{ .min = 0, .max = 150 },
    };

    const user = User{ .name = "Alice", .email = "alice@example.com", .age = 30 };

    // Direct validation (no HTTP context)
    const allocator = std.testing.allocator;
    const err = try Validator.validateStruct(allocator, user, rules);
    try std.testing.expect(err == null);
    if (err) |e| allocator.free(e);
}

test "validateRequest catches invalid email" {
    const User = struct {
        name: []const u8,
        email: []const u8,
        age: u32,
    };

    const rules = .{
        .name = Validator.FieldRules{ .required = true, .min_len = 2 },
        .email = Validator.FieldRules{ .required = true, .email = true },
        .age = Validator.FieldRules{ .min = 0, .max = 150 },
    };

    const user = User{ .name = "Bob", .email = "not-an-email", .age = 25 };

    const allocator = std.testing.allocator;
    const err = try Validator.validateStruct(allocator, user, rules);
    try std.testing.expect(err != null);
    if (err) |e| allocator.free(e);
}

test "validateRequest catches empty required field" {
    const User = struct {
        name: []const u8,
        email: []const u8,
    };

    const rules = .{
        .name = Validator.FieldRules{ .required = true, .min_len = 2 },
        .email = Validator.FieldRules{ .required = true, .email = true },
    };

    const user = User{ .name = "", .email = "test@test.com" };

    const allocator = std.testing.allocator;
    const err = try Validator.validateStruct(allocator, user, rules);
    try std.testing.expect(err != null);
    if (err) |e| allocator.free(e);
}

test "validateRequest catches age out of range" {
    const User = struct {
        name: []const u8,
        age: u32,
    };

    const rules = .{
        .name = Validator.FieldRules{ .required = true },
        .age = Validator.FieldRules{ .min = 0, .max = 150 },
    };

    const user = User{ .name = "Test", .age = 999 };

    const allocator = std.testing.allocator;
    const err = try Validator.validateStruct(allocator, user, rules);
    try std.testing.expect(err != null);
    if (err) |e| allocator.free(e);
}

test "validateRequest oneOf validation" {
    const Request = struct {
        role: []const u8,
    };

    const rules = .{
        .role = Validator.FieldRules{ .one_of = "admin,user,guest" },
    };

    const valid_req = Request{ .role = "admin" };
    const invalid_req = Request{ .role = "superuser" };

    const allocator = std.testing.allocator;

    const err1 = try Validator.validateStruct(allocator, valid_req, rules);
    try std.testing.expect(err1 == null);
    if (err1) |e| allocator.free(e);

    const err2 = try Validator.validateStruct(allocator, invalid_req, rules);
    try std.testing.expect(err2 != null);
    if (err2) |e| allocator.free(e);
}
