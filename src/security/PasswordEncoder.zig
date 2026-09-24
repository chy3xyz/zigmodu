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

    /// What a verifier reports. `false` is a genuine mismatch — the only answer
    /// that belongs to a failed login. An error means **our** side could not do
    /// the work: the stored record is not a usable PBKDF2 hash (corrupted row,
    /// unknown format) or the process ran out of memory. Both are operational
    /// faults, so callers must answer 5xx (and count them as errors), never
    /// 401 "bad credentials" — a login outage that is answered as wrong
    /// passwords is invisible in monitoring and misleads the user.
    ///
    /// Shared with `SecurityModule.verifyPassword` (same set, one name), so a
    /// single `switch` covers both verifiers.
    pub const PasswordError = error{MalformedStoredHash} || std.mem.Allocator.Error;

    /// PBKDF2-HMAC-SHA256 output length — the only stored digest length that
    /// can match (`encode` always writes this many bytes).
    pub const derived_key_len = 32;

    /// `false` = the password is wrong. An error = the credential could not be
    /// checked. The comparison itself is constant time on the digest bytes.
    pub fn matches(self: *PasswordEncoder, raw_password: []const u8, encoded_hash: []const u8) PasswordError!bool {
        var parts = std.mem.splitSequence(u8, encoded_hash, "$");
        _ = parts.next();
        const algo = parts.next() orelse return error.MalformedStoredHash;
        if (!std.mem.eql(u8, algo, "pbkdf2")) return error.MalformedStoredHash;

        const iter_str = parts.next() orelse return error.MalformedStoredHash;
        const iterations = std.fmt.parseInt(u32, iter_str, 10) catch return error.MalformedStoredHash;

        const salt_b64 = parts.next() orelse return error.MalformedStoredHash;
        const hash_b64 = parts.next() orelse return error.MalformedStoredHash;

        // Both decodes run before the key derivation: a failure here is
        // answered without doing (or timing) the PBKDF2 work, so it cannot be
        // confused with a mismatch on the timing axis either.
        const salt = try decodeStoredField(self.allocator, salt_b64);
        defer self.allocator.free(salt);

        const expected_hash = try decodeStoredField(self.allocator, hash_b64);
        defer self.allocator.free(expected_hash);

        // A digest of another length is not a credential we can compare: a
        // shorter one can never match, and prefix-comparing a longer one would
        // accept it. Refuse it explicitly instead of answering "wrong password".
        if (expected_hash.len != derived_key_len) return error.MalformedStoredHash;

        var derived_key: [derived_key_len]u8 = undefined;
        crypto.pwhash.pbkdf2(
            &derived_key,
            raw_password,
            salt,
            iterations,
            crypto.auth.hmac.sha2.HmacSha256,
        ) catch |err| switch (err) {
            // rounds < 1 or an impossible output length: the stored parameters
            // are corrupt, not the attempted password.
            error.WeakParameters, error.OutputTooLong => return error.MalformedStoredHash,
        };

        // Constant-time comparison to prevent timing side-channel
        return timingSafeSliceEql(&derived_key, expected_hash[0..derived_key_len]);
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

/// Decode one base64 field of a *stored* hash. Text that is not valid base64
/// is a corrupt stored record (`MalformedStoredHash`); only the allocator's own
/// failure stays `OutOfMemory`, so the two never collapse into "wrong password".
fn decodeStoredField(allocator: std.mem.Allocator, text: []const u8) PasswordEncoder.PasswordError![]const u8 {
    return base64Decode(allocator, text) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedStoredHash,
    };
}

// ── Tests ──

test "PasswordEncoder encode and matches" {
    const allocator = std.testing.allocator;
    var encoder = PasswordEncoder.init(allocator, std.testing.io);

    const hash = try encoder.encode("my_password");
    defer allocator.free(hash);

    try std.testing.expect(try encoder.matches("my_password", hash));
    try std.testing.expect(!try encoder.matches("wrong_password", hash));
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

    try std.testing.expect(try encoder.matches("", hash));
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

// ── Regression: an error on our side is never reported as "wrong password" ──
//
// Both defects below returned `false` before this change: an allocation failure
// and an unusable stored record were indistinguishable from a genuine mismatch,
// so a correct login during memory pressure came back 401 (and any
// failed-login counter counted a lie), and a corrupt row looked like a bad
// password instead of an operational fault.

test "matches reports every induced allocation failure as OutOfMemory" {
    const allocator = std.testing.allocator;
    var encoder = PasswordEncoder.init(allocator, std.testing.io);
    const hash = try encoder.encode("correct horse battery staple");
    defer allocator.free(hash);

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, raw: []const u8, encoded: []const u8) !void {
            var enc = PasswordEncoder.init(alloc, std.testing.io);
            // The credential is correct, so anything but OutOfMemory here is a
            // wrong answer: `checkAllAllocationFailures` propagates it as-is.
            try std.testing.expect(try enc.matches(raw, encoded));
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ "correct horse battery staple", hash });
}

test "matches refuses an unusable stored hash instead of answering false" {
    const allocator = std.testing.allocator;
    var encoder = PasswordEncoder.init(allocator, std.testing.io);
    const password = "correct horse battery staple";

    const unusable = [_][]const u8{
        "", // empty password_hash column
        "plaintext-password", // not a record at all
        "$pbkdf2$100000$c2FsdA==$aGFzaA==", // digest of the wrong length (4 bytes)
        "$pbkdf2$not-a-number$c2FsdA==$aGFzaA==", // rounds field corrupt
        "$pbkdf2$100000$not*base64$aGFzaA==", // salt undecodable
        "$pbkdf2$100000$c2FsdA==$not*base64", // digest undecodable
        "$pbkdf2$100000$c2FsdA==", // record truncated
        "$bcrypt$100000$c2FsdA==$aGFzaA==", // another algorithm's hash
        "$pbkdf2$0$c2FsdA==$aGFzaA==", // rounds < 1
        "$pbkdf2$100000$c2FsdA==$AAAA", // digest not `derived_key_len` bytes
    };
    for (unusable) |stored| {
        try std.testing.expectError(error.MalformedStoredHash, encoder.matches(password, stored));
    }
}

test "matches refuses a digest longer than the derived key (no prefix match)" {
    const allocator = std.testing.allocator;
    var encoder = PasswordEncoder.init(allocator, std.testing.io);
    const password = "correct horse battery staple";

    // The old comparison accepted any stored digest at least as long as the
    // derived key whenever its first `derived_key_len` bytes matched — so a
    // record with bytes appended to the digest verified.
    var salt: [16]u8 = undefined;
    @memset(&salt, 0x2a);
    var derived: [PasswordEncoder.derived_key_len]u8 = undefined;
    try crypto.pwhash.pbkdf2(&derived, password, &salt, 1000, crypto.auth.hmac.sha2.HmacSha256);

    var longer: [PasswordEncoder.derived_key_len + 1]u8 = undefined;
    @memcpy(longer[0..PasswordEncoder.derived_key_len], &derived);
    longer[PasswordEncoder.derived_key_len] = 0xAB;

    const salt_b64 = try base64Encode(allocator, &salt);
    defer allocator.free(salt_b64);
    const longer_b64 = try base64Encode(allocator, &longer);
    defer allocator.free(longer_b64);
    const stored = try std.fmt.allocPrint(allocator, "$pbkdf2$1000${s}${s}", .{ salt_b64, longer_b64 });
    defer allocator.free(stored);

    try std.testing.expectError(error.MalformedStoredHash, encoder.matches(password, stored));
}
