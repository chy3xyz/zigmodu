const std = @import("std");

/// Generate a random hex string suitable for trace IDs / request IDs.
pub fn randomHex(allocator: std.mem.Allocator, len: usize) ![]const u8 {
    const seed = @as(u64, @intCast(@abs(std.time.timestamp()))) ^ @as(u64, @intCast(std.time.microTimestamp()));
    var rng = std.rand.DefaultPrng.init(seed);
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
