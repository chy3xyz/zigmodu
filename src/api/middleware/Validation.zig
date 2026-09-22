//! Request body validation entry point for handlers.
//!
//! Rules are `Validator.FieldRules` values keyed by field name; the first
//! failing field yields a Validation message.
//! On HTTP failure it responds 422 (RFC 7807 when a problem renderer is set),
//! carrying a **non-zero** business code (`Validation.error_code`, default
//! `default_error_code`) — see that constant for why 0 is unusable here.
//!
//! By default the body is the historical flat string message. Set
//! `Validation.structured_errors` to answer with a per-field array instead:
//! the legacy envelope carries `"data":{"errors":[{"field","rule","message"}…]}`,
//! and `Validation.message_hook` can localize the default rule messages in
//! either shape.
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
/// Knobs, all opt-in — the zero value keeps the historical flat string
/// message body, the 422 transport status and `default_error_code`:
///
/// * `error_code`: the business code written into the `{code,msg,data}`
///   envelope (the transport status and the business code are separate
///   channels, and a consumer may read either one first).
/// * `structured_errors`: answer with a per-field error array instead of the
///   flat message — see `validateRequest`.
/// * `message_hook`: localize the default rule messages (`FieldRules.message`
///   overrides still win) in either body shape.
///
/// Everything else — the envelope, the RFC 7807 renderer when one is
/// installed — is untouched.
///
/// Usage:
///   try Validation{}.validateRequest(ctx, req, rules);            // 4220, flat
///   try (Validation{ .error_code = 4711 }).validateRequest(...);  // 4711, flat
///   try Validation.withErrorCode(4711).validateRequest(...);      // 4711, flat
///   try (Validation{ .structured_errors = true }).validateRequest(...); // errors array
pub const Validation = struct {
    /// Business code written for a validation failure. `0` is refused and
    /// replaced by `default_error_code`: accepting it would silently put the
    /// "422 reads as success" bug back for whoever configures it.
    error_code: i32 = default_error_code,

    /// When true, a validation failure responds with the structured error
    /// array instead of the flat string message: every failed field adds one
    /// `{"field","rule","message"}` entry to `data.errors` (the legacy
    /// envelope), and `msg` still carries the first field's message. When a
    /// process-wide `error_renderer` is installed the renderer decides the
    /// body, so it is invoked with the first message and the array is not
    /// representable there. Default false = the historical string body.
    structured_errors: bool = false,

    /// Localization hook applied to the default rule messages, in both body
    /// shapes. `FieldRules.message` overrides are returned verbatim before
    /// the hook runs. Default null = English defaults.
    message_hook: ?Validator.MessageHook = null,

    /// Configure the business code (`0` → `default_error_code`).
    pub fn withErrorCode(code: i32) Validation {
        return .{ .error_code = code };
    }

    /// Answer with the structured `errors` array on failure (see the field).
    pub fn withStructuredErrors(v: Validation) Validation {
        return .{ .error_code = v.error_code, .structured_errors = true, .message_hook = v.message_hook };
    }

    /// Install a localization hook for the default rule messages.
    pub fn withMessageHook(v: Validation, hook: Validator.MessageHook) Validation {
        return .{ .error_code = v.error_code, .structured_errors = v.structured_errors, .message_hook = hook };
    }

    /// The code actually written: never 0.
    pub fn errorCode(self: Validation) i32 {
        return if (self.error_code == 0) default_error_code else self.error_code;
    }

    pub fn validateRequest(self: Validation, ctx: anytype, value: anytype, comptime rules: anytype) !void {
        // Fast path, byte-for-byte the historical behavior: first failure
        // only, flat string message body, no localization hook consulted.
        if (!self.structured_errors and self.message_hook == null) {
            const err = Validator.validateStruct(ctx.allocator, value, rules) catch |e| {
                try ctx.sendError(500, @errorName(e));
                return e;
            };

            if (err) |msg| {
                defer ctx.allocator.free(msg);
                try ctx.sendErrorResponse(422, self.errorCode(), msg);
                return error.ValidationFailed;
            }
            return;
        }

        var collected = Validator.validateStructCollect(ctx.allocator, value, rules, self.message_hook) catch |e| {
            try ctx.sendError(500, @errorName(e));
            return e;
        };
        if (collected) |*violations| {
            defer violations.deinit();
            if (self.structured_errors) {
                try sendStructuredErrors(ctx, self.errorCode(), violations.*);
            } else {
                // Hook only: the flat envelope, with the localized message.
                try ctx.sendErrorResponse(422, self.errorCode(), violations.firstMessage());
            }
            return error.ValidationFailed;
        }
    }
};

/// Write a 422 validation failure whose `data` carries the structured array:
/// `{"code":…,"msg":<first message>,"data":{"errors":[{"field","rule","message"}…]}}`.
///
/// Follows `Context.sendErrorResponse`'s contract: with a process-wide
/// `error_renderer` installed (RFC 7807) the renderer is invoked with the
/// first message — that shape has no business code and no `data` slot, so
/// the array is only representable in the legacy envelope.
fn sendStructuredErrors(ctx: anytype, code: i32, violations: Validator.Violations) !void {
    const first = violations.firstMessage();
    if (api.error_renderer) |render| {
        return render(ctx, 422, first);
    }

    var data = std.ArrayList(u8).empty;
    defer data.deinit(ctx.allocator);
    try data.appendSlice(ctx.allocator, "{\"errors\":[");
    for (violations.items, 0..) |v, i| {
        if (i > 0) try data.appendSlice(ctx.allocator, ",");
        const field_json = try std.json.Stringify.valueAlloc(ctx.allocator, v.field, .{});
        defer ctx.allocator.free(field_json);
        const rule_json = try std.json.Stringify.valueAlloc(ctx.allocator, v.rule, .{});
        defer ctx.allocator.free(rule_json);
        const msg_json = try std.json.Stringify.valueAlloc(ctx.allocator, v.message, .{});
        defer ctx.allocator.free(msg_json);
        const item = try std.fmt.allocPrint(ctx.allocator, "{{\"field\":{s},\"rule\":{s},\"message\":{s}}}", .{ field_json, rule_json, msg_json });
        defer ctx.allocator.free(item);
        try data.appendSlice(ctx.allocator, item);
    }
    try data.appendSlice(ctx.allocator, "]}");

    ctx.status_code = 422;
    try ctx.setHeader("Content-Type", "application/json");
    const first_json = try std.json.Stringify.valueAlloc(ctx.allocator, first, .{});
    defer ctx.allocator.free(first_json);
    const body = try std.fmt.allocPrint(ctx.allocator, "{{\"code\":{d},\"msg\":{s},\"data\":{s}}}", .{ code, first_json, data.items });
    defer ctx.allocator.free(body);
    try ctx.response_body.appendSlice(ctx.allocator, body);
    ctx.responded = true;
}

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

test "validateRequest structured mode: a single failure is a one-element errors array" {
    const User = struct { email: []const u8 };
    const rules = .{ .email = Validator.FieldRules{ .required = true, .email = true } };
    const allocator = std.testing.allocator;

    var ctx = try api.Context.init(allocator, .POST, "/users");
    defer ctx.deinit();
    const v = Validation{ .structured_errors = true };
    try std.testing.expectError(error.ValidationFailed, v.validateRequest(&ctx, User{ .email = "not-an-email" }, rules));

    try std.testing.expectEqual(@as(u16, 422), ctx.status_code);
    try std.testing.expectEqualStrings(
        "{\"code\":4220,\"msg\":\"email: invalid email format\",\"data\":{\"errors\":[{\"field\":\"email\",\"rule\":\"email\",\"message\":\"email: invalid email format\"}]}}",
        ctx.response_body.items,
    );

    // A valid body still writes no response.
    var ok_ctx = try api.Context.init(allocator, .POST, "/users");
    defer ok_ctx.deinit();
    try (Validation{ .structured_errors = true }).validateRequest(&ok_ctx, User{ .email = "alice@example.com" }, rules);
    try std.testing.expect(!ok_ctx.responded);
}

test "validateRequest structured mode: failures aggregate one entry per field" {
    const User = struct { name: []const u8, email: []const u8, age: u32 };
    const rules = .{
        .name = Validator.FieldRules{ .required = true, .min_len = 2 },
        .email = Validator.FieldRules{ .required = true, .email = true },
        .age = Validator.FieldRules{ .min = 0, .max = 150 },
    };
    const allocator = std.testing.allocator;

    var ctx = try api.Context.init(allocator, .POST, "/users");
    defer ctx.deinit();
    try std.testing.expectError(
        error.ValidationFailed,
        (Validation{ .structured_errors = true }).validateRequest(&ctx, User{ .name = "", .email = "nope", .age = 999 }, rules),
    );

    try std.testing.expectEqual(@as(u16, 422), ctx.status_code);
    try std.testing.expectEqualStrings(
        "{\"code\":4220,\"msg\":\"name: is required\"," ++
            "\"data\":{\"errors\":[" ++
            "{\"field\":\"name\",\"rule\":\"required\",\"message\":\"name: is required\"}," ++
            "{\"field\":\"email\",\"rule\":\"email\",\"message\":\"email: invalid email format\"}," ++
            "{\"field\":\"age\",\"rule\":\"max\",\"message\":\"age: must be at most 150\"}" ++
            "]}}",
        ctx.response_body.items,
    );
}

test "validateRequest structured mode: FieldRules.message override is verbatim in the entry" {
    const User = struct { email: []const u8 };
    const rules = .{ .email = Validator.FieldRules{ .required = true, .email = true, .message = "邮箱格式不正确" } };
    const allocator = std.testing.allocator;

    var ctx = try api.Context.init(allocator, .POST, "/users");
    defer ctx.deinit();
    try std.testing.expectError(
        error.ValidationFailed,
        (Validation{ .structured_errors = true }).validateRequest(&ctx, User{ .email = "nope" }, rules),
    );

    try std.testing.expectEqualStrings(
        "{\"code\":4220,\"msg\":\"邮箱格式不正确\",\"data\":{\"errors\":[{\"field\":\"email\",\"rule\":\"email\",\"message\":\"邮箱格式不正确\"}]}}",
        ctx.response_body.items,
    );
}

test "validateRequest structured mode: the business code stays configurable, 0 still refused" {
    const User = struct { email: []const u8 };
    const rules = .{ .email = Validator.FieldRules{ .required = true, .email = true } };
    const allocator = std.testing.allocator;

    var ctx = try api.Context.init(allocator, .POST, "/users");
    defer ctx.deinit();
    const v = Validation.withErrorCode(4711).withStructuredErrors();
    try std.testing.expectError(error.ValidationFailed, v.validateRequest(&ctx, User{ .email = "nope" }, rules));
    try std.testing.expect(std.mem.containsAtLeast(u8, ctx.response_body.items, 1, "\"code\":4711,"));

    var zero_ctx = try api.Context.init(allocator, .POST, "/users");
    defer zero_ctx.deinit();
    const v0 = Validation.withErrorCode(0).withStructuredErrors();
    try std.testing.expectError(error.ValidationFailed, v0.validateRequest(&zero_ctx, User{ .email = "nope" }, rules));
    try std.testing.expect(std.mem.containsAtLeast(u8, zero_ctx.response_body.items, 1, "\"code\":4220,"));
    try std.testing.expect(std.mem.indexOf(u8, zero_ctx.response_body.items, "\"code\":0,") == null);
}

test "validateRequest: message hook localizes the flat envelope, default shape unchanged otherwise" {
    const User = struct { name: []const u8, email: []const u8 };
    const rules = .{
        .name = Validator.FieldRules{ .required = true },
        .email = Validator.FieldRules{ .required = true, .email = true },
    };
    const allocator = std.testing.allocator;

    var ctx = try api.Context.init(allocator, .POST, "/users");
    defer ctx.deinit();
    const v = Validation{ .message_hook = demoHook };
    try std.testing.expectError(error.ValidationFailed, v.validateRequest(&ctx, User{ .name = "", .email = "nope" }, rules));

    // Same flat envelope as always — only the message went through the hook.
    try std.testing.expectEqualStrings(
        "{\"code\":4220,\"msg\":\"不能为空\",\"data\":null}",
        ctx.response_body.items,
    );
}

test "validateRequest structured mode: message hook applies to the entries too" {
    const User = struct { email: []const u8, age: u32 };
    const rules = .{
        .email = Validator.FieldRules{ .required = true, .email = true },
        .age = Validator.FieldRules{ .max = 150 },
    };
    const allocator = std.testing.allocator;

    var ctx = try api.Context.init(allocator, .POST, "/users");
    defer ctx.deinit();
    const v = Validation{ .structured_errors = true, .message_hook = demoHook };
    try std.testing.expectError(error.ValidationFailed, v.validateRequest(&ctx, User{ .email = "nope", .age = 999 }, rules));

    try std.testing.expectEqualStrings(
        "{\"code\":4220,\"msg\":\"邮箱格式不正确\"," ++
            "\"data\":{\"errors\":[" ++
            "{\"field\":\"email\",\"rule\":\"email\",\"message\":\"邮箱格式不正确\"}," ++
            "{\"field\":\"age\",\"rule\":\"max\",\"message\":\"age: must be at most 150\"}" ++
            "]}}",
        ctx.response_body.items,
    );
}

fn demoHook(field: []const u8, rule: []const u8, default_message: []const u8) ?[]const u8 {
    _ = field;
    _ = default_message;
    if (std.mem.eql(u8, rule, "required")) return "不能为空";
    if (std.mem.eql(u8, rule, "email")) return "邮箱格式不正确";
    return null;
}
