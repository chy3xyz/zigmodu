//! Task-level token budget shared across an agent run / workflow steps.
//!
//! Unlike the per-tenant `TokenQuota` (which records usage after the fact),
//! `Budget` is a hard reservation: steps must `tryConsume` before running so a
//! multi-step task can degrade or stop when the budget is exhausted instead of
//! silently overspending.

const std = @import("std");

pub const ExceedMode = enum {
    stop,
    warn,
};

pub const Budget = struct {
    limit: u64,
    used: std.atomic.Value(u64),
    mode: ExceedMode = .stop,

    pub fn init(limit: u64) Budget {
        return .{ .limit = limit, .used = std.atomic.Value(u64).init(0) };
    }

    pub fn usedTokens(self: *Budget) u64 {
        return self.used.load(.monotonic);
    }

    pub fn remainingTokens(self: *Budget) u64 {
        const u = self.used.load(.monotonic);
        return if (u >= self.limit) 0 else self.limit - u;
    }

    /// Reserve `n` tokens; returns false when the reservation would exceed the
    /// limit (nothing is consumed in that case).
    pub fn tryConsume(self: *Budget, n: u64) bool {
        if (n == 0) return true;
        var cur = self.used.load(.monotonic);
        while (true) {
            if (cur + n > self.limit) return false;
            const prev = self.used.cmpxchgWeak(cur, cur + n, .monotonic, .monotonic);
            if (prev == null) return true;
            cur = prev.?;
        }
    }

    /// Consume unconditionally, clamped to the limit.
    pub fn consume(self: *Budget, n: u64) void {
        var cur = self.used.load(.monotonic);
        while (true) {
            const next = @min(self.limit, cur + n);
            const prev = self.used.cmpxchgWeak(cur, next, .monotonic, .monotonic);
            if (prev == null) return;
            cur = prev.?;
        }
    }
};

test "Budget tryConsume respects the limit" {
    var b = Budget.init(100);
    try std.testing.expect(b.tryConsume(60));
    try std.testing.expect(b.tryConsume(40));
    try std.testing.expectEqual(@as(u64, 100), b.usedTokens());
    try std.testing.expectEqual(@as(u64, 0), b.remainingTokens());
    try std.testing.expect(!b.tryConsume(1));
    try std.testing.expectEqual(@as(u64, 100), b.usedTokens());
}

test "Budget consume clamps at the limit" {
    var b = Budget.init(50);
    b.consume(100);
    try std.testing.expectEqual(@as(u64, 50), b.usedTokens());
}

test "Budget warn mode still tracks usage" {
    var b = Budget.init(10);
    b.mode = .warn;
    try std.testing.expect(!b.tryConsume(11));
    try std.testing.expectEqual(@as(u64, 0), b.usedTokens());
}
