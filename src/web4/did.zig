const std = @import("std");

/// DID Method: key — self-certifying, no blockchain needed.
/// Format: did:key:z<multibase-encoded-multicodec-publicKey>
pub const DidKey = struct {
    const Self = @This();

    /// Ed25519 key pair
    secret_key: [64]u8, // seed(32) + public(32)
    public_key: [32]u8,
    did: []const u8, // "did:key:z..."

    /// Generate a new did:key identity using OS random.
    pub fn generate(allocator: std.mem.Allocator, io: std.Io) Self {
        const kp = std.crypto.sign.Ed25519.KeyPair.generate(io);
        var sk: [64]u8 = undefined;
        @memcpy(&sk, &kp.secret_key.bytes);
        var pk: [32]u8 = undefined;
        @memcpy(&pk, &kp.public_key.bytes);
        const did = formatDidKey(allocator, pk) catch @panic("OOM");
        return .{ .secret_key = sk, .public_key = pk, .did = did };
    }

    /// Restore from Ed25519 seed.
    pub fn fromSeed(allocator: std.mem.Allocator, seed: [32]u8) !Self {
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        var pk: [32]u8 = undefined;
        @memcpy(&pk, &kp.public_key.bytes);
        var sk: [64]u8 = undefined;
        @memcpy(&sk, &kp.secret_key.bytes);
        const did = try formatDidKey(allocator, pk);
        return .{ .secret_key = sk, .public_key = pk, .did = did };
    }

    /// Sign a message and return signature bytes.
    pub fn sign(self: *Self, allocator: std.mem.Allocator, msg: []const u8) ![]const u8 {
        var seed: [32]u8 = undefined;
        @memcpy(&seed, self.secret_key[0..32]);
        const kp = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
        const sig = try kp.sign(msg, null);
        return allocator.dupe(u8, &sig.toBytes());
    }

    /// Verify a signature against this DID's public key.
    pub fn verify(self: *Self, msg: []const u8, signature: []const u8) !bool {
        if (signature.len != 64) return false;
        const sig = std.crypto.sign.Ed25519.Signature.fromBytes(signature[0..64].*);
        sig.verify(msg, std.crypto.sign.Ed25519.PublicKey{ .bytes = self.public_key }) catch return false;
        return true;
    }

    /// Build the DID Document for this identity.
    pub fn document(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var pk_buf: [64]u8 = undefined;
        const pk_b64_len = std.base64.standard.Encoder.calcSize(32);
        _ = std.base64.standard.Encoder.encode(pk_buf[0..pk_b64_len], &self.public_key);

        return std.fmt.allocPrint(allocator,
            \\{{"@context":"https://www.w3.org/ns/did/v1","id":"{s}","verificationMethod":[{{"id":"{s}#keys-1","type":"Ed25519VerificationKey2020","controller":"{s}","publicKeyMultibase":"z{s}"}}],"authentication":["{s}#keys-1"]}}
        , .{ self.did, self.did, self.did, pk_buf[0..pk_b64_len], self.did });
    }

    fn formatDidKey(allocator: std.mem.Allocator, pk: [32]u8) ![]const u8 {
        const mc_ed25519: u8 = 0xed;
        var mc_buf: [35]u8 = undefined;
        mc_buf[0] = 0x01; // multicodec prefix byte 1
        mc_buf[1] = mc_ed25519; // multicodec prefix byte 2 (ed25519-pub)
        @memcpy(mc_buf[2..34], &pk);

        // Append multicodec prefix length (2 bytes)
        mc_buf[34] = 2;

        const b58 = try encodeBase58Btc(allocator, mc_buf[0..35]);
        defer allocator.free(b58);
        return std.fmt.allocPrint(allocator, "did:key:z{s}", .{b58});
    }
};

/// Base58btc encoding (Bitcoin-style, used by did:key).
fn encodeBase58Btc(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    var zeroes: usize = 0;
    while (zeroes < data.len and data[zeroes] == 0) : (zeroes += 1) {}

    const size = data.len * 138 / 100 + 1;
    var b58 = try allocator.alloc(u8, size);
    @memset(b58, 0);
    var b58_len: usize = 0;

    for (data) |byte| {
        var carry: u32 = byte;
        var i: usize = 0;
        while (i < b58_len or carry != 0) : (i += 1) {
            if (i < b58_len) carry += @as(u32, b58[i]) * 256;
            b58[i] = @intCast(carry % 58);
            carry /= 58;
        }
        b58_len = i;
    }

    for (0..zeroes) |i| b58[i] = 0;
    b58_len = @max(b58_len, zeroes);

    var result = try allocator.alloc(u8, b58_len);
    for (0..b58_len) |i| result[i] = alphabet[@intCast(b58[b58_len - 1 - i])];
    allocator.free(b58);
    return result;
}

/// Resolve a did:key string → DidKey (public key only, no signing capability).
pub fn resolve(allocator: std.mem.Allocator, did: []const u8) !DidKey {
    if (!std.mem.startsWith(u8, did, "did:key:z")) return error.InvalidDid;
    const b58 = did["did:key:z".len..];
    const decoded = try decodeBase58Btc(allocator, b58);
    defer allocator.free(decoded);
    if (decoded.len < 35) return error.InvalidDid;
    if (decoded[0] != 0x01 or decoded[1] != 0xed) return error.UnsupportedDidMethod;
    var pk: [32]u8 = undefined;
    @memcpy(&pk, decoded[2..34]);
    const resolved_did = try DidKey.formatDidKey(allocator, pk);
    var sk: [64]u8 = @splat(0);
    @memcpy(sk[32..64], &pk);
    return DidKey{ .secret_key = sk, .public_key = pk, .did = resolved_did };
}

fn decodeBase58Btc(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    var data = try allocator.alloc(u8, encoded.len * 2);
    @memset(data, 0);
    var data_len: usize = 0;
    for (encoded) |ch| {
        const idx = std.mem.indexOfScalar(u8, alphabet, ch) orelse return error.InvalidBase58;
        var carry: u32 = @intCast(idx);
        var i: usize = 0;
        while (i < data_len or carry != 0) : (i += 1) {
            if (i < data_len) carry += @as(u32, data[i]) * 58;
            data[i] = @intCast(carry % 256);
            carry /= 256;
        }
        data_len = i;
    }
    var zeroes: usize = 0;
    while (zeroes < encoded.len and encoded[zeroes] == '1') : (zeroes += 1) {}
    const result = try allocator.alloc(u8, zeroes + data_len);
    @memset(result[0..zeroes], 0);
    for (0..data_len) |i| result[zeroes + i] = data[data_len - 1 - i];
    allocator.free(data);
    return result;
}

// ── Verifiable Credential ──

pub const VerifiableCredential = struct {
    issuer: []const u8, // DID of issuer
    subject: []const u8, // DID of subject
    claims: []const Claim,
    issued_at: i64,
    proof: ?Proof = null,

    pub const Claim = struct { key: []const u8, value: []const u8 };
    pub const Proof = struct {
        type_: []const u8 = "Ed25519Signature2020",
        created: i64,
        verification_method: []const u8,
        signature: []const u8,
    };
};

/// Issue a verifiable credential: sign claims with issuer's DID key.
pub fn issueCredential(allocator: std.mem.Allocator, issuer: *DidKey, vc: *VerifiableCredential) !void {
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, vc.issuer);
    try buf.appendSlice(allocator, vc.subject);
    for (vc.claims) |c| {
        try buf.appendSlice(allocator, c.key);
        try buf.appendSlice(allocator, c.value);
    }
    const sig = try issuer.sign(allocator, buf.items);
    vc.proof = .{
        .created = 0,
        .verification_method = try std.fmt.allocPrint(allocator, "{s}#keys-1", .{vc.issuer}),
        .signature = sig,
    };
}

// Verify a credential's proof against the issuer's public key.
test "resolve did:key round-trip" {
    const allocator = std.testing.allocator;
    const did = DidKey.generate(allocator, std.testing.io);
    defer allocator.free(did.did);
    const resolved = try resolve(allocator, did.did);
    defer allocator.free(resolved.did);
    try std.testing.expect(std.mem.eql(u8, &did.public_key, &resolved.public_key));
}

pub fn verifyCredential(allocator: std.mem.Allocator, issuer: *DidKey, vc: *VerifiableCredential) !bool {
    if (vc.proof == null) return false;
    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, vc.issuer);
    try buf.appendSlice(allocator, vc.subject);
    for (vc.claims) |c| {
        try buf.appendSlice(allocator, c.key);
        try buf.appendSlice(allocator, c.value);
    }
    return try issuer.verify(buf.items, vc.proof.?.signature);
}

test "did:key generate and document" {
    const allocator = std.testing.allocator;
    var did = DidKey.generate(allocator, std.testing.io);
    defer allocator.free(did.did);

    try std.testing.expect(std.mem.startsWith(u8, did.did, "did:key:z"));

    const doc = try did.document(allocator);
    defer allocator.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "Ed25519VerificationKey2020") != null);
}

test "did:key sign and verify" {
    const allocator = std.testing.allocator;
    var did = DidKey.generate(allocator, std.testing.io);
    defer allocator.free(did.did);

    const sig = try did.sign(allocator, "hello world");
    defer allocator.free(sig);
    try std.testing.expect(try did.verify("hello world", sig));
    try std.testing.expect(!(try did.verify("wrong msg", sig)));
}

test "issue and verify credential" {
    const allocator = std.testing.allocator;
    var issuer_did = DidKey.generate(allocator, std.testing.io);
    defer allocator.free(issuer_did.did);
    const subject_did = DidKey.generate(allocator, std.testing.io);
    defer allocator.free(subject_did.did);

    var vc = VerifiableCredential{
        .issuer = issuer_did.did,
        .subject = subject_did.did,
        .claims = &.{ .{ .key = "name", .value = "Alice" }, .{ .key = "role", .value = "admin" } },
        .issued_at = 0,
    };
    try issueCredential(allocator, &issuer_did, &vc);
    try std.testing.expect(vc.proof != null);
    try std.testing.expect(try verifyCredential(allocator, &issuer_did, &vc));
}
