//! Validation utilities for zigzero
//!
//! ⚠️ DEPRECATED — use `zigmodu.Validator` (validation/ObjectValidator.zig) instead.
//! This GoZero-style validator will be removed in v1.0.
//!
//! `FieldRules` is *no longer* one of the reasons it survives: the canonical
//! declaration moved to `validation/FieldRules.zig`, which `http.FieldRules`
//! reads directly. What is still load-bearing here is the `validateStruct` /
//! `validateStructCollect` entry points called by `http.validateRequest`
//! (`api/middleware/Validation.zig`) and `http.extractJsonValidated`
//! (`api/Extract.zig`), plus the `Validator.*` spellings themselves.
//!
//! Provides input validation aligned with go-zero's validate patterns.

const std = @import("std");
const errors = @import("../sqlx/errors.zig");

/// Validation result
pub const Result = struct {
    valid: bool,
    message: ?[]const u8,

    pub fn ok() Result {
        return .{ .valid = true, .message = null };
    }

    pub fn fail(msg: []const u8) Result {
        return .{ .valid = false, .message = msg };
    }
};

/// Validate that string is not empty
pub fn notEmpty(value: []const u8) Result {
    if (value.len == 0) return Result.fail("value cannot be empty");
    return Result.ok();
}

/// Validate minimum length
pub fn minLength(value: []const u8, min: usize) Result {
    if (value.len < min) return Result.fail("value too short");
    return Result.ok();
}

/// Validate maximum length
pub fn maxLength(value: []const u8, max: usize) Result {
    if (value.len > max) return Result.fail("value too long");
    return Result.ok();
}

/// Validate email format (simplified)
pub fn email(value: []const u8) Result {
    if (value.len == 0) return Result.fail("email cannot be empty");
    if (std.mem.indexOf(u8, value, "@") == null) return Result.fail("invalid email format");
    if (std.mem.indexOf(u8, value, ".") == null) return Result.fail("invalid email format");
    return Result.ok();
}

/// Validate phone number (simplified - digits only, 7-15 chars)
pub fn phone(value: []const u8) Result {
    if (value.len < 7 or value.len > 15) return Result.fail("invalid phone length");
    for (value) |c| {
        if (!std.ascii.isDigit(c) and c != '+' and c != '-') return Result.fail("invalid phone format");
    }
    return Result.ok();
}

/// Validate range for integers
pub fn range(comptime T: type, value: T, min: T, max: T) Result {
    if (value < min or value > max) return Result.fail("value out of range");
    return Result.ok();
}

/// Validate that value is in allowed set
pub fn oneOf(value: []const u8, choices: []const []const u8) Result {
    for (choices) |choice| {
        if (std.mem.eql(u8, value, choice)) return Result.ok();
    }
    return Result.fail("value not in allowed choices");
}

/// Validate UUID format
pub fn uuid(value: []const u8) Result {
    if (value.len != 36) return Result.fail("invalid UUID length");
    // Simplified check
    for (value, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return Result.fail("invalid UUID format");
        } else {
            if (!std.ascii.isHex(c)) return Result.fail("invalid UUID format");
        }
    }
    return Result.ok();
}

/// Validate URL format. Rejects: empty, non-http(s), embedded null bytes,
/// newlines (header injection), and dangerous schemes.
pub fn url(value: []const u8) Result {
    if (value.len == 0) return Result.fail("url cannot be empty");
    // Reject embedded control characters (null, CR, LF) to prevent header injection
    for (value) |c| {
        if (c == 0 or c == '\r' or c == '\n') return Result.fail("url contains invalid characters");
    }
    if (!std.mem.startsWith(u8, value, "http://") and !std.mem.startsWith(u8, value, "https://")) {
        return Result.fail("url must start with http:// or https://");
    }
    return Result.ok();
}

/// Field validation rules for comptime struct validation. The canonical
/// declaration lives in `validation/FieldRules.zig`, because `http.FieldRules`
/// resolves there now and the http domain must not be reached from this
/// deprecated file. This is the compatibility alias for consumers who wrote
/// `Validator.FieldRules`; the dependency runs one way only (deprecated file →
/// new home, never the reverse).
pub const FieldRules = @import("FieldRules.zig").FieldRules;

/// Failure message for one violated rule.
///
/// The default is `<field>: <what the rule requires>` — the field name is part
/// of it because "invalid email format" on a multi-field request body does not
/// say which field to fix. A `FieldRules.message` override replaces the whole
/// string, including the field-name prefix, and wins over `hook`. When `hook`
/// is set it sees the finished default message and may replace it with a
/// localized one (the replacement is duplicated, so static table strings work).
fn ruleFailure(
    allocator: std.mem.Allocator,
    field_name: []const u8,
    field_rules: anytype,
    comptime rule_name: []const u8,
    comptime rule_fmt: []const u8,
    rule_args: anytype,
    hook: ?MessageHook,
) ![]const u8 {
    if (field_rules.message) |override| return try allocator.dupe(u8, override);
    const rule_text = try std.fmt.allocPrint(allocator, rule_fmt, rule_args);
    defer allocator.free(rule_text);
    const default_msg = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ field_name, rule_text });
    if (hook) |h| {
        if (h(field_name, rule_name, default_msg)) |localized| {
            allocator.free(default_msg);
            return try allocator.dupe(u8, localized);
        }
    }
    return default_msg;
}

/// One violated rule on one field, as reported by `validateStructCollect`.
pub const Violation = struct {
    /// Struct field name (a comptime constant; not owned).
    field: []const u8,
    /// Machine name of the violated rule: "required", "min_len", "max_len",
    /// "min", "max", "email", "uuid", "phone", "url" or "one_of".
    rule: []const u8,
    /// Failure message: either the default `<field>: <rule text>` (possibly
    /// localized through `MessageHook`) or the verbatim `FieldRules.message`
    /// override. Owned by `Violations`.
    message: []const u8,
};

/// Every violation found by one `validateStructCollect` call. Owns all message
/// strings plus the list itself; one `deinit` frees everything.
pub const Violations = struct {
    items: []Violation,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Violations) void {
        for (self.items) |v| self.allocator.free(v.message);
        self.allocator.free(self.items);
    }

    /// Message of the earliest-collected violation — what the
    /// first-failure-only `validateStruct` would have returned.
    pub fn firstMessage(self: *const Violations) []const u8 {
        return self.items[0].message;
    }
};

/// Localization hook for default rule messages. Receives the field name, the
/// rule name and the finished default message; return a replacement string, or
/// `null` to keep the default. The returned string is duplicated into the
/// caller's allocator, so returning static strings from a message table is the
/// intended use. A `FieldRules.message` override is returned before the hook
/// runs, so per-field overrides always win.
pub const MessageHook = *const fn (
    field: []const u8,
    rule: []const u8,
    default_message: []const u8,
) ?[]const u8;

fn appendViolation(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Violation),
    field_name: []const u8,
    field_rules: anytype,
    comptime rule_name: []const u8,
    comptime rule_fmt: []const u8,
    rule_args: anytype,
    hook: ?MessageHook,
) !void {
    const message = try ruleFailure(allocator, field_name, field_rules, rule_name, rule_fmt, rule_args, hook);
    errdefer allocator.free(message);
    try list.append(allocator, .{
        .field = field_name,
        .rule = rule_name,
        .message = message,
    });
}

/// Validate a struct value against comptime rules.
/// Returns an allocator-owned error message if validation fails, or null on success.
/// Caller must free the returned string if non-null.
///
/// This is the historical first-failure-only entry point: the message is the
/// first failing field's first failing rule. The collecting variant is
/// `validateStructCollect`.
pub fn validateStruct(allocator: std.mem.Allocator, value: anytype, comptime rules: anytype) !?[]const u8 {
    var violations = (try validateStructCollect(allocator, value, rules, null)) orelse return null;
    defer violations.deinit();
    return try allocator.dupe(u8, violations.firstMessage());
}

/// Validate a struct value against comptime rules, collecting every failed
/// field instead of stopping at the first one.
///
/// Each failed field contributes exactly one `Violation` — its first failing
/// rule, in the rule order the checks run — so the result is aggregated per
/// field. Entries follow the declaration order of `rules`. `hook` localizes
/// default messages (a `FieldRules.message` override still wins). Returns
/// `null` when the value is valid; otherwise a `Violations` the caller owns.
pub fn validateStructCollect(
    allocator: std.mem.Allocator,
    value: anytype,
    comptime rules: anytype,
    hook: ?MessageHook,
) !?Violations {
    const T = @TypeOf(value);
    const t_info = @typeInfo(T);
    if (t_info != .@"struct") @compileError("value must be a struct");

    const RulesType = @TypeOf(rules);
    const r_info = @typeInfo(RulesType);
    if (r_info != .@"struct") @compileError("rules must be a struct literal");

    var list = std.ArrayList(Violation).empty;
    errdefer {
        for (list.items) |v| allocator.free(v.message);
        list.deinit(allocator);
    }

    inline for (r_info.@"struct".field_names) |field_name| {
        if (!@hasField(T, field_name)) {
            @compileError("validation rules contain unknown field: " ++ field_name);
        }

        const field_value = @field(value, field_name);
        const field_rules = @field(rules, field_name);
        // First failing rule per field is reported; later rules on the same
        // field are skipped (mirrors the single-message entry point).
        var field_failed = false;

        // required check
        if (!field_failed and field_rules.required) {
            const valid = isRequiredValid(@TypeOf(field_value), field_value);
            if (!valid) {
                try appendViolation(allocator, &list, field_name, field_rules, "required", "is required", .{}, hook);
                field_failed = true;
            }
        }

        // string length checks
        const is_string = isStringSlice(@TypeOf(field_value));
        if (!field_failed and is_string) {
            if (field_rules.min_len) |min| {
                if (field_value.len < min) {
                    try appendViolation(allocator, &list, field_name, field_rules, "min_len", "must be at least {d} characters", .{min}, hook);
                    field_failed = true;
                }
            }
            if (!field_failed) {
                if (field_rules.max_len) |max| {
                    if (field_value.len > max) {
                        try appendViolation(allocator, &list, field_name, field_rules, "max_len", "must be at most {d} characters", .{max}, hook);
                        field_failed = true;
                    }
                }
            }
        }

        // numeric range checks
        const is_int = isInteger(@TypeOf(field_value));
        const is_float = isFloat(@TypeOf(field_value));
        if (!field_failed and (is_int or is_float)) {
            if (field_rules.min) |min| {
                const fv = asF64(field_value);
                if (fv < @as(f64, @floatFromInt(min))) {
                    try appendViolation(allocator, &list, field_name, field_rules, "min", "must be at least {d}", .{min}, hook);
                    field_failed = true;
                }
            }
            if (!field_failed) {
                if (field_rules.max) |max| {
                    const fv = asF64(field_value);
                    if (fv > @as(f64, @floatFromInt(max))) {
                        try appendViolation(allocator, &list, field_name, field_rules, "max", "must be at most {d}", .{max}, hook);
                        field_failed = true;
                    }
                }
            }
        }

        // string format validators
        if (!field_failed and is_string) {
            if (field_rules.email) {
                const r = email(field_value);
                if (!r.valid) {
                    try appendViolation(allocator, &list, field_name, field_rules, "email", "{s}", .{r.message.?}, hook);
                    field_failed = true;
                }
            }
            if (!field_failed) {
                if (field_rules.uuid) {
                    const r = uuid(field_value);
                    if (!r.valid) {
                        try appendViolation(allocator, &list, field_name, field_rules, "uuid", "{s}", .{r.message.?}, hook);
                        field_failed = true;
                    }
                }
            }
            if (!field_failed) {
                if (field_rules.phone) {
                    const r = phone(field_value);
                    if (!r.valid) {
                        try appendViolation(allocator, &list, field_name, field_rules, "phone", "{s}", .{r.message.?}, hook);
                        field_failed = true;
                    }
                }
            }
            if (!field_failed) {
                if (field_rules.url) {
                    const r = url(field_value);
                    if (!r.valid) {
                        try appendViolation(allocator, &list, field_name, field_rules, "url", "{s}", .{r.message.?}, hook);
                        field_failed = true;
                    }
                }
            }
            if (!field_failed) {
                if (field_rules.one_of) |choices_str| {
                    var it = std.mem.splitScalar(u8, choices_str, ',');
                    var found = false;
                    while (it.next()) |choice| {
                        if (std.mem.eql(u8, field_value, choice)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try appendViolation(allocator, &list, field_name, field_rules, "one_of", "must be one of: {s}", .{choices_str}, hook);
                        field_failed = true;
                    }
                }
            }
        }
    }

    if (list.items.len == 0) {
        list.deinit(allocator);
        return null;
    }
    return Violations{ .items = try list.toOwnedSlice(allocator), .allocator = allocator };
}

fn isRequiredValid(comptime T: type, value: T) bool {
    const info = @typeInfo(T);
    if (info == .optional) {
        return value != null;
    }
    if (isStringSlice(T)) {
        return value.len > 0;
    }
    return true;
}

fn isStringSlice(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice and info.pointer.child == u8) {
        return true;
    }
    if (info == .optional) {
        const child = info.optional.child;
        const child_info = @typeInfo(child);
        if (child_info == .pointer and child_info.pointer.size == .slice and child_info.pointer.child == u8) {
            return true;
        }
    }
    return false;
}

fn isInteger(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .int or info == .comptime_int;
}

fn isFloat(comptime T: type) bool {
    const info = @typeInfo(T);
    return info == .float or info == .comptime_float;
}

fn asF64(value: anytype) f64 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @floatFromInt(value),
        .float, .comptime_float => @floatCast(value),
        else => 0,
    };
}

/// Validator that combines multiple checks
pub const Validator = struct {
    checks: []const Result,

    pub fn validate(results: []const Result) errors.Result {
        for (results) |result| {
            if (!result.valid) return error.ValidationFailed;
        }
        return;
    }
};

test "validation" {
    try std.testing.expect(notEmpty("hello").valid);
    try std.testing.expect(!notEmpty("").valid);

    try std.testing.expect(email("test@example.com").valid);
    try std.testing.expect(!email("invalid").valid);

    try std.testing.expect(range(u32, 5, 1, 10).valid);
    try std.testing.expect(!range(u32, 15, 1, 10).valid);

    try std.testing.expect(uuid("550e8400-e29b-41d4-a716-446655440000").valid);
    try std.testing.expect(!uuid("not-a-uuid").valid);
}

test "validateStruct" {
    const allocator = std.testing.allocator;

    const User = struct {
        name: []const u8,
        email: []const u8,
        age: u32,
        role: []const u8,
    };

    const valid_user = User{
        .name = "Alice",
        .email = "alice@example.com",
        .age = 30,
        .role = "admin",
    };

    const rules = .{
        .name = FieldRules{ .required = true, .min_len = 2, .max_len = 20 },
        .email = FieldRules{ .required = true, .email = true },
        .age = FieldRules{ .min = 0, .max = 150 },
        .role = FieldRules{ .one_of = "admin,user,guest" },
    };

    const err1 = try validateStruct(allocator, valid_user, rules);
    try std.testing.expect(err1 == null);
    if (err1) |e| allocator.free(e);

    const invalid_user = User{
        .name = "A",
        .email = "not-an-email",
        .age = 200,
        .role = "superuser",
    };

    const err2 = try validateStruct(allocator, invalid_user, rules);
    try std.testing.expect(err2 != null);
    if (err2) |e| allocator.free(e);

    const empty_name_user = User{
        .name = "",
        .email = "test@example.com",
        .age = 25,
        .role = "user",
    };

    const err3 = try validateStruct(allocator, empty_name_user, rules);
    try std.testing.expect(err3 != null);
    if (err3) |e| allocator.free(e);
}

test "validateStruct: the message names the failing field" {
    const allocator = std.testing.allocator;
    const User = struct { email: []const u8 };
    const rules = .{ .email = FieldRules{ .required = true, .email = true } };

    // Without the field name, "invalid email format" on a multi-field body does
    // not say which field to fix.
    const bad_format = (try validateStruct(allocator, User{ .email = "not-an-email" }, rules)).?;
    defer allocator.free(bad_format);
    try std.testing.expectEqualStrings("email: invalid email format", bad_format);

    const missing = (try validateStruct(allocator, User{ .email = "" }, rules)).?;
    defer allocator.free(missing);
    try std.testing.expectEqualStrings("email: is required", missing);
}

test "validateStruct: the default message still describes the rule" {
    const allocator = std.testing.allocator;
    const Req = struct { name: []const u8, age: u32, role: []const u8 };

    const too_short = (try validateStruct(allocator, Req{ .name = "A", .age = 30, .role = "admin" }, .{
        .name = FieldRules{ .min_len = 2 },
    })).?;
    defer allocator.free(too_short);
    try std.testing.expectEqualStrings("name: must be at least 2 characters", too_short);

    const too_old = (try validateStruct(allocator, Req{ .name = "Alice", .age = 999, .role = "admin" }, .{
        .age = FieldRules{ .min = 0, .max = 150 },
    })).?;
    defer allocator.free(too_old);
    try std.testing.expectEqualStrings("age: must be at most 150", too_old);

    const not_allowed = (try validateStruct(allocator, Req{ .name = "Alice", .age = 30, .role = "superuser" }, .{
        .role = FieldRules{ .one_of = "admin,user,guest" },
    })).?;
    defer allocator.free(not_allowed);
    try std.testing.expectEqualStrings("role: must be one of: admin,user,guest", not_allowed);

    const too_long = (try validateStruct(allocator, Req{ .name = "Al", .age = 30, .role = "admin" }, .{
        .name = FieldRules{ .max_len = 1 },
    })).?;
    defer allocator.free(too_long);
    try std.testing.expectEqualStrings("name: must be at most 1 characters", too_long);
}

test "validateStruct: FieldRules.message is used verbatim" {
    const allocator = std.testing.allocator;
    const User = struct { email: []const u8, age: u32 };

    const rules = .{
        .email = FieldRules{ .required = true, .email = true, .message = "邮箱格式不正确" },
        .age = FieldRules{ .max = 150, .message = "age out of range" },
    };

    const bad_email = (try validateStruct(allocator, User{ .email = "nope", .age = 30 }, rules)).?;
    defer allocator.free(bad_email);
    // Verbatim: no field-name prefix is added, and the override survives even
    // when a different rule on the same field is the one that failed.
    try std.testing.expectEqualStrings("邮箱格式不正确", bad_email);

    const bad_age = (try validateStruct(allocator, User{ .email = "a@b.com", .age = 999 }, rules)).?;
    defer allocator.free(bad_age);
    try std.testing.expectEqualStrings("age out of range", bad_age);

    const empty_email = (try validateStruct(allocator, User{ .email = "", .age = 30 }, rules)).?;
    defer allocator.free(empty_email);
    try std.testing.expectEqualStrings("邮箱格式不正确", empty_email);
}

test "validateStructCollect: one entry per failed field, first failing rule per field" {
    const allocator = std.testing.allocator;
    const Req = struct { name: []const u8, email: []const u8, age: u32 };

    const rules = .{
        .name = FieldRules{ .required = true, .min_len = 2 },
        .email = FieldRules{ .required = true, .email = true },
        .age = FieldRules{ .min = 0, .max = 150 },
    };

    // name fails `required` first — `min_len` would also fail on "" but a field
    // contributes only its first failing rule.
    var violations = (try validateStructCollect(allocator, Req{ .name = "", .email = "nope", .age = 999 }, rules, null)).?;
    defer violations.deinit();

    try std.testing.expectEqual(@as(usize, 3), violations.items.len);
    try std.testing.expectEqualStrings("name", violations.items[0].field);
    try std.testing.expectEqualStrings("required", violations.items[0].rule);
    try std.testing.expectEqualStrings("name: is required", violations.items[0].message);
    try std.testing.expectEqualStrings("email", violations.items[1].field);
    try std.testing.expectEqualStrings("email", violations.items[1].rule);
    try std.testing.expectEqualStrings("email: invalid email format", violations.items[1].message);
    try std.testing.expectEqualStrings("age", violations.items[2].field);
    try std.testing.expectEqualStrings("max", violations.items[2].rule);
    try std.testing.expectEqualStrings("age: must be at most 150", violations.items[2].message);

    // The first message matches what first-failure-only validateStruct reports.
    const single = (try validateStruct(allocator, Req{ .name = "", .email = "nope", .age = 999 }, rules)).?;
    defer allocator.free(single);
    try std.testing.expectEqualStrings(violations.firstMessage(), single);

    // A valid value reports no violations at all.
    const ok_result = try validateStructCollect(allocator, Req{ .name = "Alice", .email = "a@b.com", .age = 30 }, rules, null);
    try std.testing.expect(ok_result == null);
}

fn demoMessageHook(field: []const u8, rule: []const u8, default_message: []const u8) ?[]const u8 {
    _ = field;
    _ = default_message;
    if (std.mem.eql(u8, rule, "required")) return "不能为空";
    if (std.mem.eql(u8, rule, "email")) return "邮箱格式不正确";
    return null;
}

test "validateStructCollect: message hook localizes defaults, FieldRules.message wins" {
    const allocator = std.testing.allocator;
    const Req = struct { name: []const u8, email: []const u8, age: u32 };

    const rules = .{
        .name = FieldRules{ .required = true },
        .email = FieldRules{ .required = true, .email = true },
        .age = FieldRules{ .min = 0, .max = 150 },
    };

    var localized = (try validateStructCollect(allocator, Req{ .name = "", .email = "nope", .age = 999 }, rules, demoMessageHook)).?;
    defer localized.deinit();

    try std.testing.expectEqual(@as(usize, 3), localized.items.len);
    try std.testing.expectEqualStrings("不能为空", localized.items[0].message);
    try std.testing.expectEqualStrings("邮箱格式不正确", localized.items[1].message);
    // No mapping for `max`: the default survives untouched.
    try std.testing.expectEqualStrings("age: must be at most 150", localized.items[2].message);

    // A per-field override replaces the whole message, so the hook never runs.
    const override_rules = .{
        .name = FieldRules{ .required = true, .message = "name 必填" },
    };
    var overridden = (try validateStructCollect(allocator, Req{ .name = "", .email = "a@b.com", .age = 30 }, override_rules, demoMessageHook)).?;
    defer overridden.deinit();
    try std.testing.expectEqual(@as(usize, 1), overridden.items.len);
    try std.testing.expectEqualStrings("name 必填", overridden.items[0].message);
}

// The collector allocates once or twice per violated field (rule text, then the
// `<field>: <rule text>` message, then the hooked localization) and grows a
// list, with three `errdefer`s layered over that. `checkAllAllocationFailures`
// re-runs the whole call once per allocation point with that allocation
// failing: the error has to come back out (nothing may be swallowed) and
// `Violations` must not own any string that was built before the failure.
test "validateStructCollect survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const Req = struct { name: []const u8, email: []const u8, age: u32, role: []const u8 };
            const rules = .{
                .name = FieldRules{ .required = true, .min_len = 2 },
                .email = FieldRules{ .email = true },
                .age = FieldRules{ .min = 0, .max = 150 },
                .role = FieldRules{ .one_of = "user,admin" },
            };
            // All four fields fail, each on its first failing rule: four
            // messages built, four list slots.
            var violations = (try validateStructCollect(
                alloc,
                Req{ .name = "", .email = "nope", .age = 999, .role = "root" },
                rules,
                demoMessageHook,
            )) orelse return error.ExpectedViolations;
            defer violations.deinit();
            try std.testing.expectEqual(@as(usize, 4), violations.items.len);
            // The hook localizes two of the four; `one_of` has no mapping.
            try std.testing.expectEqualStrings("不能为空", violations.items[0].message);
            try std.testing.expectEqualStrings("邮箱格式不正确", violations.items[1].message);
            try std.testing.expectEqualStrings("age: must be at most 150", violations.items[2].message);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{});
}

// The `FieldRules.message` override returns before any of that: one `dupe` and
// no list growth past the first slot is the whole allocation budget here.
test "validateStructCollect message override survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(alloc: std.mem.Allocator) !void {
            const Req = struct { name: []const u8, email: []const u8, age: u32 };
            const rules = .{
                .name = FieldRules{ .required = true, .message = "name 必填" },
                .email = FieldRules{ .required = true, .email = true },
                .age = FieldRules{ .min = 0, .max = 150 },
            };
            var violations = (try validateStructCollect(
                alloc,
                Req{ .name = "", .email = "nope", .age = 999 },
                rules,
                demoMessageHook,
            )) orelse return error.ExpectedViolations;
            defer violations.deinit();
            try std.testing.expectEqual(@as(usize, 3), violations.items.len);
            try std.testing.expectEqualStrings("name 必填", violations.items[0].message);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{});
}
