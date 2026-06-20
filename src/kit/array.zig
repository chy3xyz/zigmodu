const std = @import("std");

/// Check if slice contains a value (requires T to support ==).
pub fn contains(comptime T: type, slice: []const T, value: T) bool {
    for (slice) |item| {
        if (item == value) return true;
    }
    return false;
}

/// Filter elements matching predicate. Caller owns returned slice.
pub fn filter(comptime T: type, allocator: std.mem.Allocator, slice: []const T, predicate: *const fn (T) bool) ![]T {
    var result = std.ArrayList(T).empty;
    errdefer result.deinit(allocator);
    for (slice) |item| {
        if (predicate(item)) try result.append(allocator, item);
    }
    return result.toOwnedSlice(allocator);
}

/// Map elements through transform. Caller owns returned slice.
pub fn map(comptime T: type, comptime U: type, allocator: std.mem.Allocator, slice: []const T, transform: *const fn (T) U) ![]U {
    var result = try allocator.alloc(U, slice.len);
    for (slice, 0..) |item, i| {
        result[i] = transform(item);
    }
    return result;
}

/// Return unique elements (first occurrence wins). Caller owns returned slice.
pub fn unique(comptime T: type, allocator: std.mem.Allocator, slice: []const T) ![]T {
    var result = std.ArrayList(T).empty;
    errdefer result.deinit(allocator);
    for (slice) |item| {
        if (!contains(T, result.items, item)) try result.append(allocator, item);
    }
    return result.toOwnedSlice(allocator);
}

/// Sum of all elements (T must support + and cast from 0).
pub fn sum(comptime T: type, slice: []const T) T {
    var total: T = 0;
    for (slice) |item| total += item;
    return total;
}

/// Maximum element. Returns null for empty slices.
pub fn max(comptime T: type, slice: []const T) ?T {
    if (slice.len == 0) return null;
    var m = slice[0];
    for (slice[1..]) |item| {
        if (item > m) m = item;
    }
    return m;
}

/// Minimum element. Returns null for empty slices.
pub fn min(comptime T: type, slice: []const T) ?T {
    if (slice.len == 0) return null;
    var m = slice[0];
    for (slice[1..]) |item| {
        if (item < m) m = item;
    }
    return m;
}

test "contains" {
    try std.testing.expect(contains(i32, &.{ 1, 2, 3 }, 2));
}

fn filterEven(x: i32) bool {
    return @mod(x, 2) == 0;
}
test "filter" {
    const a = std.testing.allocator;
    const slice: []const i32 = &.{ 1, 2, 3, 4 };
    const r = try filter(i32, a, slice, &filterEven);
    defer a.free(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
}

fn double(x: i32) i32 {
    return x * 2;
}
test "map" {
    const a = std.testing.allocator;
    const slice: []const i32 = &.{ 1, 2, 3 };
    const r = try map(i32, i32, a, slice, &double);
    defer a.free(r);
    try std.testing.expectEqual(@as(i32, 4), r[1]);
}

test "unique" {
    const a = std.testing.allocator;
    const slice: []const i32 = &.{ 1, 2, 2, 3, 1 };
    const r = try unique(i32, a, slice);
    defer a.free(r);
    try std.testing.expectEqual(@as(usize, 3), r.len);
}

test "sum" {
    try std.testing.expectEqual(@as(i32, 6), sum(i32, &.{ 1, 2, 3 }));
}

test "max" {
    try std.testing.expectEqual(@as(i32, 5), max(i32, &.{ 1, 5, 3 }).?);
}

test "min" {
    try std.testing.expectEqual(@as(i32, 1), min(i32, &.{ 1, 5, 3 }).?);
}

test "max empty" {
    try std.testing.expect(max(i32, &.{}) == null);
}
