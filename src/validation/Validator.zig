//! Validation utilities for zigzero
//!
//! ⚠️ DEPRECATED — use `zigmodu.Validator` (validation/ObjectValidator.zig) instead.
//! This GoZero-style validator will be removed in v1.0.
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

/// Field validation rules for comptime struct validation.
/// Only fields relevant to the value type are enforced.
pub const FieldRules = struct {
    required: bool = false,
    min_len: ?usize = null,
    max_len: ?usize = null,
    min: ?i64 = null,
    max: ?i64 = null,
    email: bool = false,
    uuid: bool = false,
    phone: bool = false,
    url: bool = false,
    one_of: ?[]const u8 = null,
    /// Replaces the failure message for this field **verbatim** (no field-name
    /// prefix added). Use it to phrase the error for the end user. It covers any
    /// rule on that field, not one specific rule.
    message: ?[]const u8 = null,
};

/// Failure message for one violated rule.
///
/// The default is `<field>: <what the rule requires>` — the field name is part
/// of it because "invalid email format" on a multi-field request body does not
/// say which field to fix. A `FieldRules.message` override replaces the whole
/// string, including the field-name prefix.
fn ruleFailure(
    allocator: std.mem.Allocator,
    field_name: []const u8,
    field_rules: anytype,
    comptime rule_fmt: []const u8,
    rule_args: anytype,
) ![]const u8 {
    if (field_rules.message) |override| return try allocator.dupe(u8, override);
    const rule_text = try std.fmt.allocPrint(allocator, rule_fmt, rule_args);
    defer allocator.free(rule_text);
    return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ field_name, rule_text });
}

/// Validate a struct value against comptime rules.
/// Returns an allocator-owned error message if validation fails, or null on success.
/// Caller must free the returned string if non-null.
pub fn validateStruct(allocator: std.mem.Allocator, value: anytype, comptime rules: anytype) !?[]const u8 {
    const T = @TypeOf(value);
    const t_info = @typeInfo(T);
    if (t_info != .@"struct") @compileError("value must be a struct");

    const RulesType = @TypeOf(rules);
    const r_info = @typeInfo(RulesType);
    if (r_info != .@"struct") @compileError("rules must be a struct literal");

    inline for (r_info.@"struct".field_names) |field_name| {
        if (!@hasField(T, field_name)) {
            @compileError("validation rules contain unknown field: " ++ field_name);
        }

        const field_value = @field(value, field_name);
        const field_rules = @field(rules, field_name);

        // required check
        if (field_rules.required) {
            const valid = isRequiredValid(@TypeOf(field_value), field_value);
            if (!valid) {
                return try ruleFailure(allocator, field_name, field_rules, "is required", .{});
            }
        }

        // string length checks
        const is_string = isStringSlice(@TypeOf(field_value));
        if (is_string) {
            if (field_rules.min_len) |min| {
                if (field_value.len < min) {
                    return try ruleFailure(allocator, field_name, field_rules, "must be at least {d} characters", .{min});
                }
            }
            if (field_rules.max_len) |max| {
                if (field_value.len > max) {
                    return try ruleFailure(allocator, field_name, field_rules, "must be at most {d} characters", .{max});
                }
            }
        }

        // numeric range checks
        const is_int = isInteger(@TypeOf(field_value));
        const is_float = isFloat(@TypeOf(field_value));
        if (is_int or is_float) {
            if (field_rules.min) |min| {
                const fv = asF64(field_value);
                if (fv < @as(f64, @floatFromInt(min))) {
                    return try ruleFailure(allocator, field_name, field_rules, "must be at least {d}", .{min});
                }
            }
            if (field_rules.max) |max| {
                const fv = asF64(field_value);
                if (fv > @as(f64, @floatFromInt(max))) {
                    return try ruleFailure(allocator, field_name, field_rules, "must be at most {d}", .{max});
                }
            }
        }

        // string format validators
        if (is_string) {
            if (field_rules.email) {
                const r = email(field_value);
                if (!r.valid) {
                    return try ruleFailure(allocator, field_name, field_rules, "{s}", .{r.message.?});
                }
            }
            if (field_rules.uuid) {
                const r = uuid(field_value);
                if (!r.valid) {
                    return try ruleFailure(allocator, field_name, field_rules, "{s}", .{r.message.?});
                }
            }
            if (field_rules.phone) {
                const r = phone(field_value);
                if (!r.valid) {
                    return try ruleFailure(allocator, field_name, field_rules, "{s}", .{r.message.?});
                }
            }
            if (field_rules.url) {
                const r = url(field_value);
                if (!r.valid) {
                    return try ruleFailure(allocator, field_name, field_rules, "{s}", .{r.message.?});
                }
            }
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
                    return try ruleFailure(allocator, field_name, field_rules, "must be one of: {s}", .{choices_str});
                }
            }
        }
    }

    return null;
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
