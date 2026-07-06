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
/// Last-ditch fallback when no OS clock is available: a strictly increasing
/// counter. Useless for measuring real durations, but preserves the
/// monotonicity invariant that TTL / rate-limit / breaker logic relies on.
var fallback_tick = std.atomic.Value(i64).init(1);

/// Returns monotonic nanoseconds since an arbitrary epoch.
/// Suitable for elapsed-time measurement, NOT wall-clock time.
pub fn monotonicNow() i64 {
    switch (comptime builtin.os.tag) {
        .windows => {
            // QueryPerformanceCounter is monotonic; convert ticks → ns.
            const counter = std.os.windows.QueryPerformanceCounter();
            const freq = std.os.windows.QueryPerformanceFrequency();
            if (freq > 0) {
                return @intCast(@divFloor(@as(i128, @intCast(counter)) * std.time.ns_per_s, @as(i128, @intCast(freq))));
            }
            return fallback_tick.fetchAdd(1, .monotonic);
        },
        .freestanding, .other, .uefi => return fallback_tick.fetchAdd(1, .monotonic),
        else => {
            // Any POSIX-ish libc target (linux, macos, *bsd, solaris, ...).
            var ts: std.c.timespec = undefined;
            const rc = std.c.clock_gettime(.MONOTONIC, &ts);
            if (rc == 0) {
                return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
            }
            return fallback_tick.fetchAdd(1, .monotonic);
        },
    }
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

/// Coarse-grained cached timestamp for hot-path callers that can tolerate ~1s staleness.
/// Auto-refreshes on each call when the cached value is older than 1 second.
///
/// First call within a second does a clock_gettime syscall; subsequent calls
/// within the same second return the cached value without syscall overhead.
/// At 10K RPS this avoids ~9,999 syscalls/sec per calling site.
///
/// Suitable for: TTL expiry checks, rate limiter coarse windows, LRU promotion.
/// NOT suitable for: circuit breaker timeout precision, sub-second timing.
var cached_seconds = std.atomic.Value(i64).init(0);

pub fn cachedNowSeconds() i64 {
    const cached = cached_seconds.load(.monotonic);
    const now = monotonicNowSeconds();
    if (now - cached >= 1) {
        cached_seconds.store(now, .monotonic);
        return now;
    }
    return cached;
}

/// Refresh the cached timestamp. Call this periodically (e.g., from a
/// 1-second timer or event loop tick) to keep cachedNowSeconds() fresh
/// without requiring the internal monotonicNowSeconds() call.
pub fn refreshCache() void {
    cached_seconds.store(monotonicNowSeconds(), .monotonic);
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

test "cachedNowSeconds returns positive after refresh" {
    refreshCache();
    const t = cachedNowSeconds();
    try std.testing.expect(t > 0);
}
