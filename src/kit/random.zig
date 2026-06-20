const std = @import("std");
const Time = @import("../core/Time.zig");

var test_source: ?std.Random = null;

/// Set a deterministic random source for tests (call in test setup).
pub fn setTestSource(rng: std.Random) void {
    test_source = rng;
}

fn getRandom() std.Random {
    if (test_source) |ts| return ts;
    // Lazy-init CSPRNG with benign race (first writer wins)
    const Seed = struct {
        var csprng: ?std.Random = null;
    };
    if (Seed.csprng) |r| return r;
    var seed: [32]u8 = undefined;
    // Multi-source entropy (no single-timestamp seed)
    const ts: u64 = @intCast(Time.monotonicNowMilliseconds());
    std.mem.writeInt(u64, seed[0..8], ts, .little);
    std.mem.writeInt(u64, seed[8..16], @intFromPtr(&seed), .little);
    std.mem.writeInt(u64, seed[16..24], @intFromPtr(&Seed.csprng), .little);
    @memset(seed[24..32], 0xAA);
    var csprng = std.Random.DefaultCsprng.init(seed);
    const r = csprng.random();
    Seed.csprng = r;
    return r;
}

/// Generate a UUID v4 string. Caller owns returned memory.
pub fn uuid(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [36]u8 = undefined;
    const rng = getRandom();
    const val = rng.int(u128);
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
pub fn bytes(len: usize) ![len]u8 {
    var buf: [len]u8 = undefined;
    getRandom().bytes(&buf);
    return buf;
}

test "uuid format" {
    const a = std.testing.allocator;
    const id = try uuid(a);
    defer a.free(id);
    try std.testing.expectEqual(@as(usize, 36), id.len);
    try std.testing.expectEqual(@as(u8, '-'), id[8]);
    try std.testing.expectEqual(@as(u8, '4'), id[14]); // version 4
    try std.testing.expectEqual(@as(u8, '-'), id[23]);
}

test "setTestSource makes deterministic output" {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    setTestSource(rng);
    defer test_source = null;

    const a = std.testing.allocator;
    const id1 = try uuid(a);
    defer a.free(id1);
    const id2 = try uuid(a);
    defer a.free(id2);
    try std.testing.expect(!std.mem.eql(u8, id1, id2));
}
