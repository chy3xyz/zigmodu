const std = @import("std");
const crypto = std.crypto;

pub const PasswordEncoder = struct {
    allocator: std.mem.Allocator,
    iterations: u32,

    pub const default_iterations: u32 = 100_000;

    pub fn init(allocator: std.mem.Allocator) PasswordEncoder {
        return .{ .allocator = allocator, .iterations = default_iterations };
    }

    pub fn initWithIterations(allocator: std.mem.Allocator, iterations: u32) PasswordEncoder {
        return .{ .allocator = allocator, .iterations = iterations };
    }

    pub fn encode(self: *PasswordEncoder, raw_password: []const u8) ![]const u8 {
        var salt: [16]u8 = undefined;
        var seed: [32]u8 = undefined; std.mem.writeInt(u64, seed[0..8], @as(u64, @intCast(@import("../core/Time.zig").monotonicNowSeconds())), .little);
        var csprng = std.Random.DefaultCsprng.init(seed);
        csprng.fill(&salt);

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

        return std.mem.eql(u8, &derived_key, expected_hash);
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
