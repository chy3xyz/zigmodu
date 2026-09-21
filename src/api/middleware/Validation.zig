//! Request body validation entry point for handlers.
//!
//! Rules are `Validator.FieldRules` values keyed by field name; the first
//! failing field yields a Validation message.
//! On HTTP failure it responds 422 (RFC 7807 when a problem renderer is set),
//! carrying a **non-zero** business code (`Validation.error_code`, default
//! `default_error_code`) — see that constant for why 0 is unusable here.
//!
//! Usage:
//!   const UserReq = struct { name: []const u8, email: []const u8, age: u32 };
//!
//!   const rules = .{
//!       .name  = FieldRules{ .required = true, .min_len = 2, .max_len = 50 },
//!       .email = FieldRules{ .required = true, .email = true },
//!       .age   = FieldRules{ .min = 0, .max = 150 },
//!   };
//!
//!   try api.post("/users", struct {
//!       fn handle(ctx: *Context) !void {
//!           const req = try ctx.bindJson(UserReq);
//!           try validateRequest(ctx, req, rules);
//!           // ... req is now validated ...
//!       }
//!   }.handle, null);

const std = @import("std");
const Validator = @import("../../validation/Validator.zig");

/// Business code written into the `{code,msg,data}` envelope for a validation
/// failure.
///
/// **It must not be 0.** In this dialect `code: 0` *is success* — `sendSuccess`
/// writes `0`, and so does every paginated helper — so a client that branches on
/// `code` before the HTTP status read the old `422 … {"code":0,…}` as a success.
/// That is why `0` is not a usable configuration value here: see
/// `Validation.errorCode`, which substitutes this constant for it.
pub const default_error_code: i32 = 4220;

/// Validation entry point plus its configuration.
///
/// The only knob is the business code; the HTTP status stays 422 (the transport
/// status and the business code are separate channels, and a consumer may read
/// either one first). Everything else — the envelope, the RFC 7807 renderer when
/// one is installed — is untouched.
///
/// Usage:
///   try Validation{}.validateRequest(ctx, req, rules);            // 4220
///   try (Validation{ .error_code = 4711 }).validateRequest(...);  // 4711
///   try Validation.withErrorCode(4711).validateRequest(...);      // 4711
pub const Validation = struct {
    /// Business code written for a validation failure. `0` is refused and
    /// replaced by `default_error_code`: accepting it would silently put the
    /// "422 reads as success" bug back for whoever configures it.
    error_code: i32 = default_error_code,

    /// Configure the business code (`0` → `default_error_code`).
    pub fn withErrorCode(code: i32) Validation {
        return .{ .error_code = code };
    }

    /// The code actually written: never 0.
    pub fn errorCode(self: Validation) i32 {
        return if (self.error_code == 0) default_error_code else self.error_code;
    }

    pub fn validateRequest(self: Validation, ctx: anytype, value: anytype, comptime rules: anytype) !void {
        const err = Validator.validateStruct(ctx.allocator, value, rules) catch |e| {
            try ctx.sendError(500, @errorName(e));
            return e;
        };

        if (err) |msg| {
            defer ctx.allocator.free(msg);
            try ctx.sendErrorResponse(422, self.errorCode(), msg);
            return error.ValidationFailed;
        }
    }
};

/// Default-configuration wrapper (`Validation{}.validateRequest`) — the call the
/// module docs show. The business code lives on `Validation`, not here: this
/// entry point always emits `default_error_code`.
pub fn validateRequest(
    ctx: anytype,
    value: anytype,
    comptime rules: anytype,
) !void {
    return (Validation{}).validateRequest(ctx, value, rules);
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

test "validateRequest answers 422 with a non-zero business code by default" {
    const User = struct { email: []const u8 };
    const rules = .{ .email = Validator.FieldRules{ .required = true, .email = true } };

    const allocator = std.testing.allocator;
    var ctx = try api.Context.init(allocator, .POST, "/users");
    defer ctx.deinit();

    try std.testing.expectError(
        error.ValidationFailed,
        validateRequest(&ctx, User{ .email = "not-an-email" }, rules),
    );

    // The transport status stays 422.
    try std.testing.expectEqual(@as(u16, 422), ctx.status_code);
    // The business code is non-zero: `0` is the success value in this dialect
    // (`sendSuccess` writes it), so `code: 0` here made a code-branching client
    // read a rejected request as a success.
    try std.testing.expectEqualStrings(
        "{\"code\":4220,\"msg\":\"email: invalid email format\",\"data\":null}",
        ctx.response_body.items,
    );
    try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "\"code\":0,") == null);
    try std.testing.expectEqual(default_error_code, 4220);
}

test "validateRequest: the business code is configurable, and 0 is refused" {
    const User = struct { email: []const u8 };
    const rules = .{ .email = Validator.FieldRules{ .required = true, .email = true } };
    const allocator = std.testing.allocator;

    // Configured through the field …
    {
        var ctx = try api.Context.init(allocator, .POST, "/users");
        defer ctx.deinit();
        var v = Validation{};
        v.error_code = 4711;
        try std.testing.expectError(error.ValidationFailed, v.validateRequest(&ctx, User{ .email = "nope" }, rules));
        try std.testing.expectEqualStrings(
            "{\"code\":4711,\"msg\":\"email: invalid email format\",\"data\":null}",
            ctx.response_body.items,
        );
    }

    // … and through the setter.
    {
        var ctx = try api.Context.init(allocator, .POST, "/users");
        defer ctx.deinit();
        const v = Validation.withErrorCode(9001);
        try std.testing.expectEqual(@as(i32, 9001), v.errorCode());
        try std.testing.expectError(error.ValidationFailed, v.validateRequest(&ctx, User{ .email = "nope" }, rules));
        try std.testing.expect(std.mem.containsAtLeast(u8, ctx.response_body.items, 1, "\"code\":9001,"));
    }

    // A misconfiguration cannot silently restore the bug: 0 is coerced.
    {
        var ctx = try api.Context.init(allocator, .POST, "/users");
        defer ctx.deinit();
        const v = Validation.withErrorCode(0);
        try std.testing.expectEqual(default_error_code, v.errorCode());
        try std.testing.expectError(error.ValidationFailed, v.validateRequest(&ctx, User{ .email = "nope" }, rules));
        try std.testing.expect(std.mem.containsAtLeast(u8, ctx.response_body.items, 1, "\"code\":4220,"));
        try std.testing.expect(std.mem.indexOf(u8, ctx.response_body.items, "\"code\":0,") == null);
    }

    // Valid data is untouched: no response written at all.
    {
        var ctx = try api.Context.init(allocator, .POST, "/users");
        defer ctx.deinit();
        try (Validation{}).validateRequest(&ctx, User{ .email = "alice@example.com" }, rules);
        try std.testing.expect(!ctx.responded);
        try std.testing.expectEqual(@as(usize, 0), ctx.response_body.items.len);
    }
}
