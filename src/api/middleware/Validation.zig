const std = @import("std");
const Validator = @import("../../validation/Validator.zig");

/// Request body validation entry point for handlers.
///
/// Rules are `Validator.FieldRules` values keyed by field name; the first
/// failing field yields a Validation message.
/// On HTTP failure it responds 422 (RFC 7807 when a problem renderer is set).
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

/// Request body validation middleware (pass-through scaffold).
///
/// Mount it on the Middleware chain; a request carrying the `X-Validate`
/// header is one that expects Validation, but the schema is not resolved here.
///
/// Usage:
///   server.addMiddleware(.{ .func = validationMiddleware() });
///
/// A client may send `X-Validate-Schema: UserReq` to name the schema; the
/// middleware does not read that header.
pub fn validationMiddleware() api.MiddlewareFn {
    const S = struct {
        fn handler(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            _ = user_data;

            // Check whether the caller asked for request validation
            if (ctx.header("X-Validate")) |_| {
                // The schema is not resolved here, so no Validation runs:
                // handlers are expected to call validateRequest themselves.
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
