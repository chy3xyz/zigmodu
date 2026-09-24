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
    /// `error.EntropyUnavailable` instead of a degraded challenge — new in this
    /// function's inferred error set, which otherwise holds `error.OutOfMemory`
    /// and the `error.Canceled` of a canceled lock wait (`std.Io.Mutex.lock`
    /// fails with nothing else; the old `catch return error.LockFailed` named
    /// lock-machinery failure for a cancelation). Red:
    /// `web4.challenge.test.issue reports a canceled lock wait as error.Canceled`
    /// reads `expected error.Canceled, found error.LockFailed`.
    pub fn issue(self: *Self, allocator: std.mem.Allocator, did: []const u8) ![]const u8 {
        var buf: [8]u8 = undefined;
        try std.Io.randomSecure(self.io, &buf);
        const n = std.mem.readInt(u64, &buf, .little);
        const challenge = try std.fmt.allocPrint(allocator, "challenge-{x}", .{n});
        errdefer allocator.free(challenge);

        try self.mutex.lock(self.io);
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
        // Deliberately `false` on a canceled wait — the one wait in this file that
        // is not made uncancelable: entering the critical section *consumes* the
        // one-time challenge, so waiting would burn the nonce for a request that is
        // being canceled and force the client to re-issue and re-sign. `false` is
        // fail-closed (the middleware answers 401, byte-identical to a bad
        // signature) and spends nothing, so a retry carrying the same live
        // challenge still succeeds — pinned by
        // `web4.challenge.test.canceled lock wait leaves the challenge to be
        // retried`.
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

// `issue` answered a canceled lock with `error.LockFailed`. Nothing is fabricated
// by that name — no challenge is stored — but it is the wrong fact:
// `std.Io.Mutex.lock` fails only with `error.Canceled`, so a cancelation was
// reported as lock-machinery failure, and a caller cannot tell "unwind, you were
// canceled" from "this store's lock is broken". The error set is inferred and the
// freshly printed challenge is freed by the `errdefer` either way, so naming the
// truth costs no call site.
//
// Red evidence: with the old `catch return error.LockFailed` the assertion below
// reads `expected error.Canceled, found error.LockFailed`.
test "issue reports a canceled lock wait as error.Canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Task = struct {
        var store: *ChallengeStore = undefined;
        var err: ?anyerror = null;
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn body() void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            const challenge = store.issue(std.testing.allocator, "did:key:z6MkA") catch |e| {
                err = e;
                return;
            };
            std.testing.allocator.free(challenge);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var store = ChallengeStore.init(allocator, io);
    defer store.deinit();
    Task.store = &store;

    Task.err = null;
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    // Parked on the store mutex this thread holds, with the cancelation delivered
    // there — the idiom the framework's canceled-lock-wait tests share.
    try store.mutex.lock(io);
    var task_fut = try io.concurrent(Task.body, .{});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (store.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    store.mutex.unlock(io);
    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Task.err);
    // The failure was real: nothing was stored for the DID.
    try std.testing.expectEqual(@as(usize, 0), store.map.count());
}

// `verifyAndConsume` is the one canceled lock wait in this file that does NOT wait
// uncancelably. It cannot: entering the critical section *consumes* the one-time
// challenge, so waiting would burn the nonce for a request that is being canceled
// and force the client to re-issue and re-sign. `false` is fail-closed (the
// middleware answers 401, byte-identical to a bad signature) and spends nothing,
// so a retry carrying the same live challenge still succeeds — which is what this
// test pins.
test "canceled lock wait leaves the challenge to be retried" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const did = "did:key:z6MkA";

    const Task = struct {
        var store: *ChallengeStore = undefined;
        var challenge: []const u8 = undefined;
        var result: ?bool = null;
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn body() void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            result = store.verifyAndConsume(std.testing.allocator, did, challenge);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var store = ChallengeStore.init(allocator, io);
    defer store.deinit();
    const challenge = try store.issue(allocator, did);
    defer allocator.free(challenge);

    Task.store = &store;
    Task.challenge = challenge;
    Task.result = null;
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    try store.mutex.lock(io);
    var task_fut = try io.concurrent(Task.body, .{});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (store.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    store.mutex.unlock(io);
    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(?bool, false), Task.result);
    // Nothing was spent, so the client's retry with the same challenge passes.
    try std.testing.expectEqual(@as(usize, 1), store.map.count());
    try std.testing.expect(store.verifyAndConsume(allocator, did, challenge));
}
