//! One-time DID authentication challenges (anti-replay): the server issues a
//! short-lived random challenge to a DID, the client signs it and returns it;
//! `verifyAndConsume` accepts each challenge exactly once. Wire into
//! `DidAuthConfig.challenge_store` to prevent signature replay attacks.

const std = @import("std");
const Time = @import("../core/Time.zig");

pub const ChallengeStore = struct {
    const Self = @This();
    const Entry = struct {
        challenge: []u8,
        expires_at: i64,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    map: std.StringHashMap(Entry),
    mutex: std.Io.Mutex = .init,
    ttl_s: i64 = 300,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{ .allocator = allocator, .io = io, .map = std.StringHashMap(Entry).init(allocator) };
    }

    pub fn deinit(self: *Self) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.challenge);
        }
        self.map.deinit();
        self.* = undefined;
    }

    /// Issue a fresh random challenge for `did` (replaces any previous one).
    /// The caller owns the returned string.
    ///
    /// The nonce comes from the OS entropy source via `std.Io.randomSecure`,
    /// never from a seeded PRNG: a predictable challenge is one an attacker can
    /// sign for a DID it does not control. A failing entropy source surfaces as
    /// `error.EntropyUnavailable` (or `error.Canceled`) instead of a degraded
    /// challenge — both are new in this function's inferred error set, which
    /// otherwise holds `error.OutOfMemory` / `error.LockFailed`.
    pub fn issue(self: *Self, allocator: std.mem.Allocator, did: []const u8) ![]const u8 {
        var buf: [8]u8 = undefined;
        try std.Io.randomSecure(self.io, &buf);
        const n = std.mem.readInt(u64, &buf, .little);
        const challenge = try std.fmt.allocPrint(allocator, "challenge-{x}", .{n});
        errdefer allocator.free(challenge);

        self.mutex.lock(self.io) catch return error.LockFailed;
        defer self.mutex.unlock(self.io);
        if (self.map.fetchRemove(did)) |old| {
            allocator.free(old.key);
            allocator.free(old.value.challenge);
        }
        try self.map.put(try allocator.dupe(u8, did), .{
            .challenge = try allocator.dupe(u8, challenge),
            .expires_at = Time.monotonicNowSeconds() + self.ttl_s,
        });
        return challenge;
    }

    /// Accept `challenge` for `did` exactly once. Expired or unknown
    /// challenges are rejected.
    pub fn verifyAndConsume(self: *Self, allocator: std.mem.Allocator, did: []const u8, challenge: []const u8) bool {
        _ = allocator;
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);
        const entry = self.map.getPtr(did) orelse return false;
        if (entry.expires_at < Time.monotonicNowSeconds()) {
            return false;
        }
        if (!std.mem.eql(u8, entry.challenge, challenge)) return false;
        // Consume: remove the challenge so a replayed signature fails.
        if (self.map.fetchRemove(did)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.challenge);
        }
        return true;
    }
};

test "ChallengeStore issues and consumes exactly once" {
    const allocator = std.testing.allocator;
    var store = ChallengeStore.init(allocator, std.testing.io);
    defer store.deinit();

    const ch = try store.issue(allocator, "did:key:z6MkA");
    defer allocator.free(ch);
    try std.testing.expect(store.verifyAndConsume(allocator, "did:key:z6MkA", ch));
    // Replay of the same challenge is rejected.
    try std.testing.expect(!store.verifyAndConsume(allocator, "did:key:z6MkA", ch));
    // Unknown DID is rejected.
    try std.testing.expect(!store.verifyAndConsume(allocator, "did:key:z6MkB", "challenge-x"));
}

test "ChallengeStore re-issuing for the same DID yields a different challenge" {
    const allocator = std.testing.allocator;
    var store = ChallengeStore.init(allocator, std.testing.io);
    defer store.deinit();

    // Same slice → same DoS-visible inputs. A clock/pointer-seeded PRNG draws
    // the identical nonce twice here, which re-issues the challenge an attacker
    // already captured a signature for; OS entropy cannot.
    const did = "did:key:z6MkA";
    const first = try store.issue(allocator, did);
    defer allocator.free(first);
    const second = try store.issue(allocator, did);
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}
