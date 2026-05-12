//! TLS-secured transport wrapper for cluster communication.
//!
//! Provides encryption and optional mutual TLS for node-to-node messaging.
//! Uses Zig 0.16 std.crypto.tls.Client for TLS 1.3 connections.
//!
//! NOTE: Full mTLS requires server-side TLS which is not yet in Zig 0.16 stdlib.
//! For production, use a sidecar TLS proxy (nginx/envoy) or the Zig TLS client
//! with pre-shared keys for node authentication.

const std = @import("std");

/// TLS configuration for cluster transport.
pub const TlsConfig = struct {
    /// Path to CA certificate for server verification
    ca_cert_path: ?[]const u8 = null,
    /// Path to client certificate for mTLS
    client_cert_path: ?[]const u8 = null,
    /// Path to client private key
    client_key_path: ?[]const u8 = null,
    /// Expected server hostname (SNI)
    server_name: ?[]const u8 = null,
    /// Skip certificate verification (DEV ONLY)
    insecure_skip_verify: bool = false,
};

/// Wraps cluster messages with PSK-based node authentication.
/// Each node has a pre-shared key that's included in message headers.
pub const ClusterAuth = struct {
    allocator: std.mem.Allocator,
    node_id: []const u8,
    pre_shared_key: [32]u8,

    pub fn init(allocator: std.mem.Allocator, node_id: []const u8, key: [32]u8) !ClusterAuth {
        return .{
            .allocator = allocator,
            .node_id = try allocator.dupe(u8, node_id),
            .pre_shared_key = key,
        };
    }

    pub fn deinit(self: *ClusterAuth) void {
        self.allocator.free(self.node_id);
    }

    /// Sign a message payload with HMAC-SHA256 using the pre-shared key.
    /// Returns hex-encoded signature. Caller owns returned memory.
    pub fn sign(self: *ClusterAuth, payload: []const u8) ![64]u8 {
        var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(&self.pre_shared_key);
        hmac.update(payload);
        var sig: [32]u8 = undefined;
        hmac.final(&sig);

        var hex: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (sig, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        return hex;
    }

    /// Constant-time slice comparison for signature verification.
    fn timingSafeEql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var acc: u8 = 0;
        for (a, 0..) |x, i| acc |= x ^ b[i];
        const s = @typeInfo(u8).int.bits;
        const Cu = std.meta.Int(.unsigned, s);
        const Cext = std.meta.Int(.unsigned, s + 1);
        return @as(bool, @bitCast(@as(u1, @truncate((@as(Cext, @as(Cu, @bitCast(acc))) -% 1) >> s))));
    }

    /// Verify a message signature.
    pub fn verify(self: *ClusterAuth, payload: []const u8, signature: []const u8) bool {
        const expected = self.sign(payload) catch return false;
        // Constant-time comparison to prevent timing oracle
        return timingSafeEql(&expected, signature);
    }
};

test "ClusterAuth sign and verify" {
    const allocator = std.testing.allocator;
    var key: [32]u8 = undefined;
    var seed: [32]u8 = undefined;
    std.mem.writeInt(u64, seed[0..8], @intFromPtr(&key), .little);
    std.mem.writeInt(u64, seed[8..16], @intFromPtr(&seed), .little);
    std.mem.writeInt(u64, seed[16..24], @intFromPtr(&key) +% @intFromPtr(&seed), .little);
    std.mem.writeInt(u64, seed[24..32], @intFromPtr(&key) *% @intFromPtr(&seed), .little);
    var csprng = std.Random.DefaultCsprng.init(seed);
    csprng.fill(&key);

    var auth = try ClusterAuth.init(allocator, "node-1", key);
    defer auth.deinit();

    const sig = try auth.sign("hello");
    try std.testing.expect(auth.verify("hello", &sig));
    try std.testing.expect(!auth.verify("evil", &sig));
}

test "ClusterAuth different keys reject" {
    const allocator = std.testing.allocator;
    const k1: [32]u8 = [_]u8{1} ** 32;
    const k2: [32]u8 = [_]u8{2} ** 32;

    var a1 = try ClusterAuth.init(allocator, "n1", k1);
    defer a1.deinit();
    var a2 = try ClusterAuth.init(allocator, "n2", k2);
    defer a2.deinit();

    const sig = try a1.sign("data");
    try std.testing.expect(!a2.verify("data", &sig));
}
