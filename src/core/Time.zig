const std = @import("std");
const builtin = @import("builtin");

/// Centralized time utility for zmodu.
///
/// The 0.16/0.17 toolchains removed the old `std.time` helpers
/// (`std.time.Instant` / `std.time.nanoTimestamp()`, and later
/// `std.time.timestamp()` / `std.time.milliTimestamp()`). This module
/// provides portable replacements on top of the OS clock.
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
///
/// ## Wall clock vs monotonic（重要边界）
///
/// - `wallClockSeconds(io) i64` / `wallClockMilliseconds(io) i64`（自 v0.7.0 起）
///   返回墙钟（realtime），需要一个 `std.Io`；用于入库时间戳、审计日志等
///   "绝对时刻"场景。
/// - **墙钟会被 NTP 同步、闰秒、手动拨动影响，可回拨**：两次读数之差不是时长。
///   时长 / 截止 / 超时一律用 `monotonicNow*`。
/// - **monotonic 值（进程 uptime 语义）禁止入库**：重启后同一数值对应的绝对
///   时刻完全不同（与 zent 侧 nowUs 翻转事故同构的教训）；存库时间戳用
///   `wallClock*`。
/// Last-ditch fallback when no OS clock is available: a strictly increasing
/// counter. Useless for measuring real durations, but preserves the
/// monotonicity invariant that TTL / rate-limit / breaker logic relies on.
var fallback_tick = std.atomic.Value(i64).init(1);

/// Returns monotonic nanoseconds since an arbitrary epoch.
/// Suitable for elapsed-time measurement, NOT wall-clock time.
pub fn monotonicNow() i64 {
    switch (comptime builtin.target.os.tag) {
        .windows => {
            // QueryPerformanceCounter is monotonic; convert ticks → ns.
            // zig 0.17 removed std.os.windows.QueryPerformanceCounter — call
            // the ntdll entry points directly.
            const ntdll = std.os.windows.ntdll;
            var counter: std.os.windows.LARGE_INTEGER = undefined;
            var freq: std.os.windows.LARGE_INTEGER = undefined;
            if (ntdll.RtlQueryPerformanceCounter(&counter) != .FALSE and
                ntdll.RtlQueryPerformanceFrequency(&freq) != .FALSE and freq > 0)
            {
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
///
/// Prefer this over removed `std.posix.clock_gettime(.REALTIME, …)` / wall
/// helpers for request timestamps (`collected_at`, audit logs, etc.).
pub fn wallClockSeconds(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_s));
}

/// Returns wall-clock milliseconds via `std.Io` (async-compatible).
pub fn wallClockMilliseconds(io: std.Io) i64 {
    const ts = std.Io.Clock.Timestamp.now(io, .real);
    return @intCast(@divTrunc(ts.raw.nanoseconds, std.time.ns_per_ms));
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
