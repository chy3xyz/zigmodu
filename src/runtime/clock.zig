//! Clock — the runtime's single source of time, injectable for tests.
//!
//! Everything in the runtime that schedules (timers, retries, rate windows,
//! metrics buckets) reads time from a `Clock` instead of calling
//! `Time.monotonicNowMilliseconds()` directly. That is what lets a test drive a
//! one-hour timer without sleeping: hand it a `Manual` clock and advance it.
//!
//! `Clock` is a small value type (no allocation, no vtable call on the hot path
//! for the production variant).

const std = @import("std");
const Time = @import("../core/Time.zig");

/// `std.Io.Timeout.duration` is a `Clock.Duration` (raw nanos + which clock), not
/// an `Io.Duration` — the two types are easy to confuse and the compiler only
/// tells you when the call is instantiated.
pub fn duration(ms: i64) std.Io.Clock.Duration {
    return .{ .raw = std.Io.Duration.fromMilliseconds(ms), .clock = .awake };
}

pub const Clock = union(enum) {
    /// Process monotonic clock. Unaffected by wall-clock jumps.
    monotonic,
    /// Test clock: only moves when the test moves it.
    manual: *Manual,

    pub fn nowMs(self: Clock) i64 {
        return switch (self) {
            .monotonic => Time.monotonicNowMilliseconds(),
            .manual => |m| m.now_ms,
        };
    }

    pub fn nowUs(self: Clock) i64 {
        return switch (self) {
            .monotonic => Time.monotonicNowMilliseconds() * 1000,
            .manual => |m| m.now_ms * 1000,
        };
    }

    /// Test-only handle. Production code should use `.monotonic`.
    pub const Manual = struct {
        now_ms: i64 = 0,

        pub fn advance(self: *Manual, ms: i64) void {
            self.now_ms += ms;
        }

        pub fn set(self: *Manual, ms: i64) void {
            self.now_ms = ms;
        }

        pub fn clock(self: *Manual) Clock {
            return .{ .manual = self };
        }
    };
};

test "Clock: monotonic advances, manual only when told" {
    const sys: Clock = .monotonic;
    const before = sys.nowMs();
    try std.testing.expect(sys.nowMs() >= before);

    var manual = Clock.Manual{ .now_ms = 1_000 };
    const c = manual.clock();
    try std.testing.expectEqual(@as(i64, 1_000), c.nowMs());
    try std.testing.expectEqual(@as(i64, 1_000_000), c.nowUs());
    manual.advance(500);
    try std.testing.expectEqual(@as(i64, 1_500), c.nowMs());
    manual.set(0);
    try std.testing.expectEqual(@as(i64, 0), c.nowMs());
}
