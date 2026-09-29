//! PSK authentication helpers for cluster ports — the `ClusterAuth` used by
//! `RaftTransport.zig` and `DistributedEventBus.zig`.
//!
//! 集群两面（Raft 端口 / 分布式事件总线）的帧认证原语：HMAC-SHA256 签名（hex 与 raw
//! 两种形态）、常数时间比较。线格式 `[len][tag][payload][mac]` 的 mac 由这里的
//! 原语产生与核验（帧形状的拼装/剥离归 `RaftTransport.zig` 与总线各自所有）。
//!
//! 机密性边界（A-2 定界，第 111 批）：本文件给的是**认证 + 完整性**，不是加密 ——
//! 帧体仍是明文，被动嗅探者能读到 Raft 日志条目与事件载荷。框架**不内嵌 TLS**：
//! 零依赖铁律（加密只用 `std.crypto`）加上 Zig std 没有 server-side TLS，而自研
//! TLS 栈是安全禁区。生产部署把集群端口限制在受信二层（VPC/专线/localhost），
//! 跨域/公网用边车或服务网格终结 mTLS —— 权威说明与最小拓扑见
//! `docs/DISTRIBUTED.md`「传输加密边界（A-2 定界）」。std 若日后长出 server-side
//! TLS，该节写明了重开条件。

const std = @import("std");

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
        self.* = undefined;
    }

    /// Sign a message payload with HMAC-SHA256 using the pre-shared key.
    /// Returns hex-encoded signature.
    ///
    /// The `!` here is vestigial: both the tag and its hex rendering are stack
    /// values (`mac` + `hexTag`), so the inferred error set is empty and nothing
    /// in this file depends on this call being able to fail. It is left on the
    /// type because callers already write `try auth.sign(...)` (see
    /// `RaftTransport.zig`); dropping it is a source-breaking change for them and
    /// belongs in a change that can touch them together.
    pub fn sign(self: *ClusterAuth, payload: []const u8) ![64]u8 {
        return hexTag(self.mac(payload));
    }

    /// Raw HMAC-SHA256 over `payload` — the form the wire format uses.
    /// (`sign` hex-encodes the same tag, for JSON and humans.)
    pub fn mac(self: *ClusterAuth, payload: []const u8) [32]u8 {
        var tag: [32]u8 = undefined;
        std.crypto.auth.hmac.sha2.HmacSha256.create(&tag, payload, &self.pre_shared_key);
        return tag;
    }

    /// Hex-encode an HMAC tag: the encoding `sign` returns and `verify`
    /// recomputes. Pure stack work — no allocator, so no failure to report.
    fn hexTag(tag: [32]u8) [64]u8 {
        var hex: [64]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (tag, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0xf];
        }
        return hex;
    }

    /// Constant-time slice comparison for signature verification.
    ///
    /// `pub` because the raw-byte verifier lives in `RaftTransport.zig` (which
    /// owns the frame shape) and must not re-implement the comparison with a
    /// non-constant-time `std.mem.eql`.
    pub fn timingSafeEql(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        var acc: u8 = 0;
        for (a, b) |x, y| acc |= x ^ y;
        return acc == 0;
    }

    /// Verify a message signature.
    ///
    /// Infallible on purpose. The body used to be
    /// `const expected = self.sign(payload) catch return false;`, which made one
    /// `false` mean two different things at once — "the peer signed something
    /// else" and "we could not compute the tag" — so any failure on our own side
    /// would have rejected a valid peer as a forger: a wrong accusation, an
    /// availability loss, and nothing in the operator's log to explain it. The
    /// tag is now recomputed locally (`mac` + `hexTag`), both of which are stack
    /// values, so there is no failure to misreport: a `false` from this function
    /// means exactly one thing.
    ///
    /// That single thing is acted on, not logged: the real inbound path
    /// (`RaftTransport.verifiedRecv`, which verifies the raw tag itself) maps a
    /// mismatch to `error.ClusterAuthFailed`, and its callers treat that as "drop
    /// this peer". A rejection must only ever be reached for the peer's reasons.
    pub fn verify(self: *ClusterAuth, payload: []const u8, signature: []const u8) bool {
        const expected = hexTag(self.mac(payload));
        // Constant-time comparison to prevent timing oracle
        return timingSafeEql(expected[0..], signature);
    }
};

// The audit this pin answers read `verify`'s `self.sign(payload) catch return
// false` as a live path: an allocation failure on *our* side would have been
// reported as "your signature is invalid" — a valid peer accused of forging.
//
// It was never live, and this measures that rather than arguing it: computing the
// tag and rendering it as hex both work on stack values (`mac` + `hexTag`), so
// the verification path reaches no allocator and has no failure to misreport. The
// `try` on the `FailingAllocator`-backed second `init` below proves the
// instrument is armed (that allocation really does fail), while `verify` — with
// every further allocation armed to fail — still returns the true verdict and
// leaves the allocation count where it was.
//
// Teeth: if the verification path ever grows an allocation, the armed allocator
// turns it into a failure, and a `verify` that reports such a failure as "invalid
// signature" fails this test instead of shipping.
test "verify reaches no allocator, so no OOM can be reported as a bad signature" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();

    // `node_id` is the only allocation this type has, and it happens here.
    var auth = try ClusterAuth.init(allocator, "node-1", @splat(5));
    defer auth.deinit();

    const sig = try auth.sign("payload");

    // From here on, the next allocation fails.
    const before = failing.allocations;
    failing.fail_index = failing.alloc_index;
    defer failing.fail_index = std.math.maxInt(usize);

    // The instrument is armed: this `init` really does hit the wall.
    try std.testing.expectError(error.OutOfMemory, ClusterAuth.init(allocator, "node-2", @splat(5)));

    // Same arming, on the verification path: the verdict is still the true one.
    try std.testing.expect(auth.verify("payload", &sig));
    try std.testing.expect(!auth.verify("payload!", &sig));
    try std.testing.expectEqual(before, failing.allocations);
}

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
    const k1: [32]u8 = @splat(1);
    const k2: [32]u8 = @splat(2);

    var a1 = try ClusterAuth.init(allocator, "n1", k1);
    defer a1.deinit();
    var a2 = try ClusterAuth.init(allocator, "n2", k2);
    defer a2.deinit();

    const sig = try a1.sign("data");
    try std.testing.expect(!a2.verify("data", &sig));
}
