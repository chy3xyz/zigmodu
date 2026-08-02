const std = @import("std");
const Time = @import("core/Time.zig");

/// Generate a random hex string suitable for trace IDs / request IDs.
pub fn randomHex(allocator: std.mem.Allocator, len: usize) ![]u8 {
    const seed = @as(u64, @intCast(Time.monotonicNowMilliseconds())) ^ @as(u64, @intFromPtr(&len));
    // Zig 0.17 moved the default PRNG from std.rand to std.Random.
    var rng = std.Random.DefaultPrng.init(seed);
    const hex_chars = "0123456789abcdef";
    var buf = try allocator.alloc(u8, len);
    for (0..len) |i| {
        buf[i] = hex_chars[rng.random().int(usize) % 16];
    }
    return buf;
}

/// Generate a UUID-v4-like random string (32 hex chars).
pub fn randomUuid(allocator: std.mem.Allocator) ![]const u8 {
    return randomHex(allocator, 32);
}

/// English pluralization rules (minimal). Allocates result.
pub fn pluralize(allocator: std.mem.Allocator, singular: []const u8) ![]const u8 {
    if (singular.len == 0) return try allocator.dupe(u8, singular);
    const last = singular[singular.len - 1];
    if (last == 's' or last == 'x' or last == 'z') return try std.fmt.allocPrint(allocator, "{s}es", .{singular});
    if (std.mem.endsWith(u8, singular, "ch") or std.mem.endsWith(u8, singular, "sh")) return try std.fmt.allocPrint(allocator, "{s}es", .{singular});
    if (last == 'y' and singular.len > 1 and !isVowel(singular[singular.len - 2])) {
        const stem = singular[0 .. singular.len - 1];
        return try std.fmt.allocPrint(allocator, "{s}ies", .{stem});
    }
    return try std.fmt.allocPrint(allocator, "{s}s", .{singular});
}

fn isVowel(c: u8) bool {
    return switch (c) {
        'a', 'e', 'i', 'o', 'u', 'A', 'E', 'I', 'O', 'U' => true,
        else => false,
    };
}

/// Encode bytes as lowercase hex string. Caller owns result.
pub fn hexEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, data.len * 2);
    for (data, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

pub const HashKit = struct {
    pub fn md5(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var h: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(data, &h, .{});
        return hexEncode(allocator, &h);
    }
    pub fn sha1(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var h: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(data, &h, .{});
        return hexEncode(allocator, &h);
    }
    pub fn sha256(data: []const u8, out: *[32]u8) void {
        std.crypto.hash.sha2.Sha256.hash(data, out, .{});
    }
    pub fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
        return hexEncode(allocator, &h);
    }
};

test "randomHex produces hex strings of the requested length" {
    const allocator = std.testing.allocator;
    const hex = try randomHex(allocator, 16);
    defer allocator.free(hex);
    try std.testing.expectEqual(@as(usize, 16), hex.len);
    for (hex) |c| {
        try std.testing.expect(std.mem.indexOfScalar(u8, "0123456789abcdef", c) != null);
    }
    const uuid = try randomUuid(allocator);
    defer allocator.free(uuid);
    try std.testing.expectEqual(@as(usize, 32), uuid.len);
}

test "pluralize applies english rules" {
    const allocator = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "order", "orders" },
        .{ "box", "boxes" },
        .{ "buzz", "buzzes" },
        .{ "match", "matches" },
        .{ "dish", "dishes" },
        .{ "category", "categories" },
        .{ "key", "keys" }, // vowel before y
    };
    for (cases) |c| {
        const got = try pluralize(allocator, c[0]);
        defer allocator.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "hexEncode and HashKit match known vectors" {
    const allocator = std.testing.allocator;
    const hex = try hexEncode(allocator, "abc");
    defer allocator.free(hex);
    try std.testing.expectEqualStrings("616263", hex);

    const md5 = try HashKit.md5(allocator, "abc");
    defer allocator.free(md5);
    try std.testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", md5);

    const sha256 = try HashKit.sha256Hex(allocator, "abc");
    defer allocator.free(sha256);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", sha256);
}
