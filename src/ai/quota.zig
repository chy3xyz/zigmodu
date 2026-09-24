//! Per-tenant token quota skeleton for multi-tenant AI chat / agent.

const std = @import("std");

pub const TokenQuota = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex,
    /// tenant_id → bucket
    buckets: std.AutoHashMap(i64, Bucket),
    default_limit: usize,

    pub const Bucket = struct {
        limit: usize,
        used: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, default_limit: usize) TokenQuota {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .buckets = std.AutoHashMap(i64, Bucket).init(allocator),
            .default_limit = if (default_limit == 0) 1_000_000 else default_limit,
        };
    }

    pub fn deinit(self: *TokenQuota) void {
        self.buckets.deinit();
        self.* = undefined;
    }

    pub fn setLimit(self: *TokenQuota, tenant_id: i64, limit: usize) !void {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const gop = try self.buckets.getOrPut(tenant_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .limit = limit, .used = 0 };
        } else {
            gop.value_ptr.limit = limit;
        }
    }

    /// Consume tokens for a tenant. Returns `error.QuotaExceeded` when over limit.
    pub fn tryConsume(self: *TokenQuota, tenant_id: i64, tokens: usize) !void {
        if (tokens == 0) return;
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        const gop = try self.buckets.getOrPut(tenant_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .limit = self.default_limit, .used = 0 };
        }
        const b = gop.value_ptr;
        if (b.used + tokens > b.limit) return error.QuotaExceeded;
        b.used += tokens;
    }

    pub fn record(self: *TokenQuota, tenant_id: i64, prompt_tokens: usize, completion_tokens: usize) !void {
        const total = prompt_tokens +% completion_tokens;
        try self.tryConsume(tenant_id, total);
    }

    pub fn used(self: *TokenQuota, tenant_id: i64) usize {
        // Uncancelable: a fabricated `0` reads as "this tenant has consumed
        // nothing" — the fail-open direction, and `used` is what an operator or a
        // dashboard compares against `limit`. One map lookup.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const b = self.buckets.get(tenant_id) orelse return 0;
        return b.used;
    }

    pub fn remaining(self: *TokenQuota, tenant_id: i64) usize {
        // Uncancelable: a fabricated `0` reads as "quota exhausted" (fail-closed,
        // but still a false refusal for a tenant with budget left). One map
        // lookup. Red pair: `ai.quota.test.canceled lock wait does not fabricate
        // used 0 or remaining 0`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const b = self.buckets.get(tenant_id) orelse return self.default_limit;
        if (b.used >= b.limit) return 0;
        return b.limit - b.used;
    }

    pub fn toPrometheusFormat(self: *TokenQuota, allocator: std.mem.Allocator) ![]u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(allocator);
        try buf.print(allocator, "# HELP zigmodu_ai_token_quota_used Tokens consumed per tenant.\n", .{});
        try buf.print(allocator, "# TYPE zigmodu_ai_token_quota_used gauge\n", .{});
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            try buf.print(allocator, "zigmodu_ai_token_quota_used{{tenant_id=\"{d}\"}} {d}\n", .{ e.key_ptr.*, e.value_ptr.used });
            try buf.print(allocator, "zigmodu_ai_token_quota_limit{{tenant_id=\"{d}\"}} {d}\n", .{ e.key_ptr.*, e.value_ptr.limit });
        }
        return try buf.toOwnedSlice(allocator);
    }
};

test "TokenQuota tryConsume and exceed" {
    const a = std.testing.allocator;
    var q = TokenQuota.init(a, std.testing.io, 100);
    defer q.deinit();
    try q.record(7, 40, 40);
    try std.testing.expectEqual(@as(usize, 80), q.used(7));
    try std.testing.expectEqual(@as(usize, 20), q.remaining(7));
    try std.testing.expectError(error.QuotaExceeded, q.tryConsume(7, 30));
    try q.setLimit(7, 200);
    try q.tryConsume(7, 30);
    try std.testing.expectEqual(@as(usize, 110), q.used(7));
}

test "TokenQuota prometheus" {
    const a = std.testing.allocator;
    var q = TokenQuota.init(a, std.testing.io, 50);
    defer q.deinit();
    try q.record(1, 10, 5);
    const out = try q.toPrometheusFormat(a);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "tenant_id=\"1\"") != null);
}

/// Park `read` on `mutex` with a cancel request already placed on its thread, then
/// let it through: the lock wait becomes the cancelation point. `std.Io.Mutex.lock`'s
/// uncontended fast path does not check for cancellation, so it is the contended
/// wait that can come back canceled.
fn readUnderCanceledLockWait(
    comptime T: type,
    target: *T,
    mutex: *std.Io.Mutex,
    io: std.Io,
    comptime read: fn (*T) void,
) !void {
    const Gate = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn run(t: *T) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            read(t);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.entered.store(false, .monotonic);
    Gate.open.store(false, .monotonic);

    try mutex.lock(io);

    var read_fut = try io.concurrent(Gate.run, .{target});
    while (!Gate.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    while (mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);
}

// The two readers are a matched pair, and the old shapes failed **opposite ways**:
// `used → 0` reads as "nothing has been consumed" (fail-open — a tenant over its
// budget looks untouched), while `remaining → 0` reads as "quota exhausted"
// (fail-closed — a tenant with budget left is refused). Neither `0` is a
// legitimate answer for a tenant that has spent tokens, and both return `usize`
// with no error channel, so they wait (`lockUncancelable`).
//
// Red evidence: with the old `catch return 0` on both, the first assertion below
// fails — `expected 80, found 0`. The `remaining` assertion after it is the same
// lock shape; a `try` ends the test at the first failure, so it is only exercised
// green.
test "canceled lock wait does not fabricate used 0 or remaining 0" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var q = TokenQuota.init(a, io, 100);
    defer q.deinit();
    try q.record(7, 40, 40);

    const UsedRead = struct {
        var seen: usize = 0;
        fn read(qq: *TokenQuota) void {
            seen = qq.used(7);
        }
    };
    UsedRead.seen = 0;
    try readUnderCanceledLockWait(TokenQuota, &q, &q.mutex, io, UsedRead.read);
    try std.testing.expectEqual(@as(usize, 80), UsedRead.seen);

    const RemainingRead = struct {
        var seen: usize = 0;
        fn read(qq: *TokenQuota) void {
            seen = qq.remaining(7);
        }
    };
    RemainingRead.seen = 0;
    try readUnderCanceledLockWait(TokenQuota, &q, &q.mutex, io, RemainingRead.read);
    try std.testing.expectEqual(@as(usize, 20), RemainingRead.seen);
}

// The three quota calls that return errors report the cancelation as
// `error.Canceled` (the only error `std.Io.Mutex.lock` has). A canceled wait
// abandons the critical section *before* it is entered, so no bucket is created,
// raised or printed — nothing is at stake, and `error.QuotaLockFailed` named
// lock-machinery failure for a cancelation, which a caller cannot tell from "this
// quota's lock is broken". (`used`/`remaining` above are `usize`-returning, so they
// wait instead.)
//
// Red evidence: with `catch return error.QuotaLockFailed` the first assertion
// below reads `expected error.Canceled, found error.QuotaLockFailed`. The
// `tryConsume` and `toPrometheusFormat` assertions after it are the same lock
// shape; a `try` ends the test at the first failure, so those two are only
// exercised green.
test "setLimit, tryConsume and toPrometheusFormat report a canceled lock wait as error.Canceled" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var q = TokenQuota.init(a, io, 100);
    defer q.deinit();

    const SetLimitRead = struct {
        var seen: ?anyerror = null;
        fn read(qq: *TokenQuota) void {
            seen = null;
            qq.setLimit(7, 200) catch |err| {
                seen = err;
            };
        }
    };
    SetLimitRead.seen = null;
    try readUnderCanceledLockWait(TokenQuota, &q, &q.mutex, io, SetLimitRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), SetLimitRead.seen);

    const ConsumeRead = struct {
        var seen: ?anyerror = null;
        fn read(qq: *TokenQuota) void {
            seen = null;
            qq.tryConsume(7, 1) catch |err| {
                seen = err;
            };
        }
    };
    ConsumeRead.seen = null;
    try readUnderCanceledLockWait(TokenQuota, &q, &q.mutex, io, ConsumeRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), ConsumeRead.seen);

    const PromRead = struct {
        var seen: ?anyerror = null;
        fn read(qq: *TokenQuota) void {
            seen = null;
            const out = qq.toPrometheusFormat(std.testing.allocator) catch |err| {
                seen = err;
                return;
            };
            std.testing.allocator.free(out);
        }
    };
    PromRead.seen = null;
    try readUnderCanceledLockWait(TokenQuota, &q, &q.mutex, io, PromRead.read);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), PromRead.seen);
}
