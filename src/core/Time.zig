const std = @import("std");
const builtin = @import("builtin");

/// Centralized time utility for ZigModu.
///
/// Zig 0.16.0 removed `std.time.Instant` / `std.time.nanoTimestamp()`.
/// This module provides portable monotonic time using the OS clock.
///
/// ## Usage
///
/// ```zig
/// const Time = @import("core/Time.zig");
/// const now_ns = Time.monotonicNow();
/// const now_s  = Time.monotonicNowSeconds();
/// ```
///
/// All subsystems (CircuitBreaker, RateLimiter, CacheManager, etc.) should call
/// these functions instead of hardcoding `const now = 0`.
/// Returns monotonic nanoseconds since an arbitrary epoch.
/// Suitable for elapsed-time measurement, NOT wall-clock time.
pub fn monotonicNow() i64 {
    if (comptime builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
        var ts: std.c.timespec = undefined;
        const clock_id: std.c.clockid_t = switch (comptime builtin.os.tag) {
            .macos => .MONOTONIC,
            .linux => .MONOTONIC,
            .freebsd => .MONOTONIC,
            else => unreachable,
        };
        const rc = std.c.clock_gettime(clock_id, &ts);
        if (rc == 0) {
            return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
        }
    }
    // Fallback: use epoch unix (not monotonic, but better than 0)
    return @intCast(std.time.epoch.unix);
}

/// Returns monotonic time in seconds (integer).
/// Returns monotonic time in milliseconds.
pub fn monotonicNowMilliseconds() i64 {
    return @divFloor(monotonicNow(), std.time.ns_per_ms);
}

/// Returns monotonic time in seconds (integer).
pub fn monotonicNowSeconds() i64 {
    return @divFloor(monotonicNow(), std.time.ns_per_s);
}

/// Returns wall-clock seconds via `std.Io` (async-compatible).
/// Use this when you have access to an `std.Io` instance.
pub fn wallClockSeconds(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_s));
}

test "monotonicNow returns positive value" {
    const t = monotonicNow();
    try std.testing.expect(t > 0);
}

test "monotonicNowSeconds returns positive value" {
    const t = monotonicNowSeconds();
    try std.testing.expect(t > 0);
}

test "monotonicNow is monotonically increasing" {
    const t1 = monotonicNow();
    const t2 = monotonicNow();
    try std.testing.expect(t2 >= t1);
}
