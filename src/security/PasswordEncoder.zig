const std = @import("std");
const crypto = std.crypto;

pub const PasswordEncoder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    iterations: u32,

    pub const default_iterations: u32 = 100_000;

    /// `io` is the only source of salt entropy: there is deliberately no
    /// constructor without it, because a fallback seed would make the salt
    /// predictable.
    pub fn init(allocator: std.mem.Allocator, io: std.Io) PasswordEncoder {
        return .{ .allocator = allocator, .io = io, .iterations = default_iterations };
    }

    pub fn initWithIterations(allocator: std.mem.Allocator, io: std.Io, iterations: u32) PasswordEncoder {
        return .{ .allocator = allocator, .io = io, .iterations = iterations };
    }

    pub fn encode(self: *PasswordEncoder, raw_password: []const u8) ![]const u8 {
        var salt: [16]u8 = undefined;
        try std.Io.randomSecure(self.io, &salt);

        var derived_key: [32]u8 = undefined;
        try crypto.pwhash.pbkdf2(
            &derived_key,
            raw_password,
            &salt,
            self.iterations,
            crypto.auth.hmac.sha2.HmacSha256,
        );

        const salt_b64 = try base64Encode(self.allocator, &salt);
        defer self.allocator.free(salt_b64);
        const hash_b64 = try base64Encode(self.allocator, &derived_key);
        defer self.allocator.free(hash_b64);

        return std.fmt.allocPrint(
            self.allocator,
            "$pbkdf2${d}${s}${s}",
            .{ self.iterations, salt_b64, hash_b64 },
        );
    }

    pub fn matches(self: *PasswordEncoder, raw_password: []const u8, encoded_hash: []const u8) bool {
        var parts = std.mem.splitSequence(u8, encoded_hash, "$");
        _ = parts.next();
        const algo = parts.next() orelse return false;
        if (!std.mem.eql(u8, algo, "pbkdf2")) return false;

        const iter_str = parts.next() orelse return false;
        const iterations = std.fmt.parseInt(u32, iter_str, 10) catch return false;

        const salt_b64 = parts.next() orelse return false;
        const hash_b64 = parts.next() orelse return false;

        const salt = base64Decode(self.allocator, salt_b64) catch return false;
        defer self.allocator.free(salt);

        const expected_hash = base64Decode(self.allocator, hash_b64) catch return false;
        defer self.allocator.free(expected_hash);

        var derived_key: [32]u8 = undefined;
        crypto.pwhash.pbkdf2(
            &derived_key,
            raw_password,
            salt,
            iterations,
            crypto.auth.hmac.sha2.HmacSha256,
        ) catch return false;

        // Constant-time comparison to prevent timing side-channel
        if (expected_hash.len < derived_key.len) return false;
        return timingSafeSliceEql(derived_key[0..], expected_hash[0..derived_key.len]);
    }

    pub fn needsUpgrade(self: *PasswordEncoder, encoded_hash: []const u8) bool {
        var parts = std.mem.splitSequence(u8, encoded_hash, "$");
        _ = parts.next();
        _ = parts.next();
        const iter_str = parts.next() orelse return true;
        const iterations = std.fmt.parseInt(u32, iter_str, 10) catch return true;
        return iterations < self.iterations;
    }
};

/// Constant-time slice comparison, used in place of Zig 0.16 timing_safe.eql.
fn timingSafeSliceEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var acc: u8 = 0;
    for (a, 0..) |x, i| {
        acc |= x ^ b[i];
    }
    return acc == 0;
}

fn base64Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const len = encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, len);
    return encoder.encode(buf, data);
}

fn base64Decode(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const decoder = std.base64.standard.Decoder;
    const len = try decoder.calcSizeForSlice(text);
    const buf = try allocator.alloc(u8, len);
    try decoder.decode(buf, text);
    return buf;
}

// ── Tests ──

test "PasswordEncoder encode and matches" {
    const allocator = std.testing.allocator;
    var encoder = PasswordEncoder.init(allocator, std.testing.io);

    const hash = try encoder.encode("my_password");
    defer allocator.free(hash);

    try std.testing.expect(encoder.matches("my_password", hash));
    try std.testing.expect(!encoder.matches("wrong_password", hash));
}

test "PasswordEncoder salts are unique within one process and one millisecond" {
    const allocator = std.testing.allocator;
    // One PBKDF2 iteration keeps the batch inside a single millisecond, which
    // is exactly where a clock/stack-derived seed repeats itself.
    var encoder = PasswordEncoder.initWithIterations(allocator, std.testing.io, 1);

    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const hash = try encoder.encode("same_password");
        const res = try seen.getOrPut(hash);
        if (res.found_existing) allocator.free(hash);
    }
    try std.testing.expectEqual(@as(usize, 64), seen.count());
}

test "PasswordEncoder empty password" {
    const allocator = std.testing.allocator;
    var encoder = PasswordEncoder.init(allocator, std.testing.io);

    const hash = try encoder.encode("");
    defer allocator.free(hash);

    try std.testing.expect(encoder.matches("", hash));
}

test "PasswordEncoder needsUpgrade with low iterations" {
    const allocator = std.testing.allocator;
    var encoder = PasswordEncoder.init(allocator, std.testing.io);

    var low_iter = PasswordEncoder.initWithIterations(allocator, std.testing.io, 10_000);
    const old_hash = try low_iter.encode("test");
    defer allocator.free(old_hash);

    try std.testing.expect(encoder.needsUpgrade(old_hash));
}

test "PasswordEncoder default iterations" {
    try std.testing.expectEqual(@as(u32, 100_000), PasswordEncoder.default_iterations);
}
