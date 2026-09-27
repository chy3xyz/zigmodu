//! Tag-checked access to `std.json.Value` for the values this tree does not
//! author: model replies, provider responses, JSON-RPC parameter objects, tool
//! arguments.
//!
//! `std.json.Value` is a union, so `v.object` / `v.string` / `v.integer` on the
//! wrong tag is a checked panic in Debug and ReleaseSafe and undefined
//! behaviour in ReleaseFast. A model that answers `"I can't help with that"`
//! where the prompt asked for JSON, or a peer sending `{"params":"x"}` instead
//! of an object, is therefore a process abort rather than a failed call — and
//! on the policy paths it aborts *before* the documented fallback (`escalate`,
//! `pass = false`, `InvalidArguments`) can be reached.
//!
//! Every accessor here returns `error.MalformedJson` instead, so each caller
//! decides its own fallback. Nothing here allocates.

const std = @import("std");

pub const Error = error{MalformedJson};

pub fn object(v: std.json.Value) Error!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.MalformedJson,
    };
}

pub fn array(v: std.json.Value) Error!std.json.Array {
    return switch (v) {
        .array => |a| a,
        else => error.MalformedJson,
    };
}

pub fn string(v: std.json.Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.MalformedJson,
    };
}

pub fn boolean(v: std.json.Value) Error!bool {
    return switch (v) {
        .bool => |b| b,
        else => error.MalformedJson,
    };
}

/// A count from a JSON number: non-negative, saturating at `max`.
///
/// JSON has one number type, so an integral value can parse as `.integer` or as
/// `.float`, and `{"limit":-1}` is a *well-typed* `i64` that `@intCast(usize)`
/// aborts on. Non-finite floats are refused rather than saturated: `NaN` is not
/// a large limit, it is not a limit.
pub fn count(v: std.json.Value, max: usize) Error!usize {
    const n: i64 = switch (v) {
        .integer => |i| i,
        // The sign is checked before the conversion: `@intFromFloat` of `-0.5`
        // truncates to `0`, and a count of zero is not what `-0.5` asked for.
        .float => |f| if (std.math.isFinite(f) and f >= 0) std.math.lossyCast(i64, f) else return error.MalformedJson,
        else => return error.MalformedJson,
    };
    if (n < 0) return error.MalformedJson;
    return @min(std.math.lossyCast(usize, n), max);
}

/// A JSON number as `i64`, as a float API (`"amount": 100.5`) or an integral
/// one (`{"amount": 100}`) may both be sent. Refuses NaN/±inf.
pub fn numberToI64(v: std.json.Value) Error!i64 {
    return switch (v) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f)) std.math.lossyCast(i64, f) else error.MalformedJson,
        else => error.MalformedJson,
    };
}

/// Absent key → null; present with the wrong tag → `error.MalformedJson`.
/// "Present but not a string" is the shape an untyped model produces
/// (`{"decision":1}`), and it must not be read as "absent".
pub fn getString(obj: std.json.ObjectMap, key: []const u8) Error!?[]const u8 {
    const v = obj.get(key) orelse return null;
    return try string(v);
}

/// Absent key → null; present must be a JSON integer. Floats are refused here
/// on purpose: this is for the fields that are identifiers (`tenant_id`), where
/// `1.5` is not a rounding question but a malformed request.
pub fn getInt(obj: std.json.ObjectMap, key: []const u8) Error!?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => error.MalformedJson,
    };
}

/// Absent key → null; present must be a boolean. `{"pass":"true"}` is not
/// `true`: a gate that reads a string as a verdict is not a gate.
pub fn getBool(obj: std.json.ObjectMap, key: []const u8) Error!?bool {
    const v = obj.get(key) orelse return null;
    return try boolean(v);
}

/// Absent key → null; present must be a non-negative number, capped at `max`.
pub fn getCount(obj: std.json.ObjectMap, key: []const u8, max: usize) Error!?usize {
    const v = obj.get(key) orelse return null;
    return try count(v, max);
}

/// Absent key → null; present must be an array.
pub fn getArray(obj: std.json.ObjectMap, key: []const u8) Error!?std.json.Array {
    const v = obj.get(key) orelse return null;
    return try array(v);
}

test "count rejects negatives and non-finite floats instead of aborting" {
    try std.testing.expectEqual(@as(usize, 5), try count(.{ .integer = 5 }, 100));
    // Over the cap saturates; a negative one is malformed, not 0 — a silently
    // widened limit is how "max rows" stops meaning anything.
    try std.testing.expectEqual(@as(usize, 100), try count(.{ .integer = 10_000 }, 100));
    try std.testing.expectError(error.MalformedJson, count(.{ .integer = -1 }, 100));
    try std.testing.expectEqual(@as(usize, 7), try count(.{ .float = 7.0 }, 100));
    try std.testing.expectError(error.MalformedJson, count(.{ .float = -0.5 }, 100));
    try std.testing.expectError(error.MalformedJson, count(.{ .float = std.math.inf(f64) }, 100));
    try std.testing.expectError(error.MalformedJson, count(.{ .float = std.math.nan(f64) }, 100));
    try std.testing.expectError(error.MalformedJson, count(.{ .string = "5" }, 100));
    try std.testing.expectError(error.MalformedJson, count(.null, 100));
}

test "shape accessors turn a wrong tag into an error" {
    try std.testing.expectError(error.MalformedJson, object(.{ .string = "not json" }));
    try std.testing.expectError(error.MalformedJson, object(.{ .integer = 42 }));
    try std.testing.expectError(error.MalformedJson, object(.{ .array = std.json.Array.init(std.testing.allocator) }));
    try std.testing.expectError(error.MalformedJson, string(.{ .integer = 1 }));
    try std.testing.expectError(error.MalformedJson, array(.{ .string = "x" }));
    try std.testing.expectError(error.MalformedJson, boolean(.{ .string = "true" }));

    _ = try object(.{ .object = std.json.ObjectMap{} });
    try std.testing.expectEqualStrings("x", (try string(.{ .string = "x" })));
    try std.testing.expect((try boolean(.{ .bool = true })));
}

test "getString distinguishes absent from present-with-the-wrong-tag" {
    var obj = std.json.ObjectMap{};
    defer {
        var it = obj.iterator();
        while (it.next()) |e| std.testing.allocator.free(e.key_ptr.*);
        obj.deinit(std.testing.allocator);
    }
    try obj.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "note"), .{ .string = "ok" });
    try obj.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "decision"), .{ .integer = 1 });
    try obj.put(std.testing.allocator, try std.testing.allocator.dupe(u8, "limit"), .{ .integer = -3 });

    try std.testing.expectEqualStrings("ok", (try getString(obj, "note")).?);
    try std.testing.expect((try getString(obj, "missing")) == null);
    try std.testing.expectError(error.MalformedJson, getString(obj, "decision"));
    try std.testing.expectEqual(@as(i64, 1), (try getInt(obj, "decision")).?);
    try std.testing.expectError(error.MalformedJson, getCount(obj, "limit", 20));
    try std.testing.expect((try getCount(obj, "missing", 20)) == null);
}
