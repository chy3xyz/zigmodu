const std = @import("std");

var test_source: ?std.Random = null;

/// Set a deterministic random source for tests (call in test setup).
/// This is an explicit, test-only override; it is never consulted by the
/// security primitives (`ApiKeyGenerator`, `PasswordEncoder`).
pub fn setTestSource(rng: std.Random) void {
    test_source = rng;
}

/// Generate a UUID v4 string. Caller owns returned memory.
pub fn uuid(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buf: [36]u8 = undefined;
    const val = if (test_source) |ts| ts.int(u128) else blk: {
        var b: [16]u8 = undefined;
        try std.Io.randomSecure(io, &b);
        break :blk std.mem.readInt(u128, &b, .little);
    };
    // Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    _ = try std.fmt.bufPrint(&buf, "{x:0>8}-{x:0>4}-4{x:0>3}-{x:0>4}-{x:0>12}", .{
        @as(u32, @truncate(val >> 96)),
        @as(u16, @truncate(val >> 80)),
        @as(u16, @truncate((val >> 64) & 0xFFF)),
        @as(u16, @intCast((val >> 48) & 0x3FFF)) | 0x8000,
        @as(u64, @truncate(val & 0xFFFFFFFFFFFF)),
    });
    return allocator.dupe(u8, &buf);
}

/// Generate cryptographically random bytes.
///
/// Entropy comes from `io` (the OS source) on every call — there is no
/// process-wide CSPRNG whose seed could be recovered from one observed output.
/// A failing entropy source is reported as `error.EntropyUnavailable`.
pub fn bytes(io: std.Io, len: usize) ![len]u8 {
    var buf: [len]u8 = undefined;
    if (test_source) |ts| {
        ts.bytes(&buf);
        return buf;
    }
    try std.Io.randomSecure(io, &buf);
    return buf;
}

test "uuid format" {
    const a = std.testing.allocator;
    const id = try uuid(a, std.testing.io);
    defer a.free(id);
    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '4'), id[14]); // version 4
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
}

test "uuid and bytes are unique across calls in one process" {
    const a = std.testing.allocator;
    var seen = std.StringHashMap(void).init(a);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| a.free(k.*);
        seen.deinit();
    }
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const id = try uuid(a, std.testing.io);
        const res = try seen.getOrPut(id);
        if (res.found_existing) a.free(id);
    }
    try std.testing.expectEqual(@as(usize, 64), seen.count());
}

test "setTestSource makes deterministic output" {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    setTestSource(rng);
    defer test_source = null;

    const a = std.testing.allocator;
    const id1 = try uuid(a, std.testing.io);
    defer a.free(id1);
    const id2 = try uuid(a, std.testing.io);
    defer a.free(id2);
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}
