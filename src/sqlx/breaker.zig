//! Minimal circuit breaker adapter for sqlx (zigzero-compatible API)

const std = @import("std");
const Time = @import("../core/Time.zig");

/// Simple circuit breaker compatible with zigzero sqlx expectations.
///
/// Does not store `std.Io`: callers pass the live `Io` into `allow` /
/// `recordSuccess` / `recordFailure` so futex waits always use a handle
/// that outlives the call (typically `Client.io`).
pub const CircuitBreaker = struct {
    const Self = @This();

    state: enum { closed, open, half_open } = .closed,
    failure_count: u32 = 0,
    success_count: u32 = 0,
    failure_threshold: u32 = 5,
    success_threshold: u32 = 2,
    timeout_ms: u64 = 5000,
    last_failure_ms: i64 = 0,
    mutex: std.Io.Mutex = .init,

    pub fn new() Self {
        return .{};
    }

    pub fn allow(self: *Self, io: std.Io) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        switch (self.state) {
            .closed => return true,
            .half_open => return true,
            .open => {
                const now = Time.monotonicNowSeconds() * 1000; // convert to ms
                if (now - self.last_failure_ms > @as(i64, @intCast(self.timeout_ms))) {
                    self.state = .half_open;
                    self.success_count = 0;
                    return true;
                }
                return false;
            },
        }
    }

    pub fn recordSuccess(self: *Self, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        switch (self.state) {
            .closed => {
                self.failure_count = 0;
            },
            .half_open => {
                self.success_count += 1;
                if (self.success_count >= self.success_threshold) {
                    self.state = .closed;
                    self.failure_count = 0;
                    self.success_count = 0;
                }
            },
            .open => {},
        }
    }

    pub fn recordFailure(self: *Self, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        self.failure_count += 1;
        self.last_failure_ms = Time.monotonicNowSeconds() * 1000;

        switch (self.state) {
            .closed => {
                if (self.failure_count >= self.failure_threshold) {
                    self.state = .open;
                }
            },
            .half_open => {
                self.state = .open;
                self.success_count = 0;
            },
            .open => {},
        }
    }
};

test "CircuitBreaker opens after threshold failures and rejects" {
    var cb = CircuitBreaker.new();
    cb.failure_threshold = 3;
    try std.testing.expect(cb.allow(std.testing.io));
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    try std.testing.expect(cb.allow(std.testing.io));
    cb.recordFailure(std.testing.io);
    try std.testing.expect(!cb.allow(std.testing.io)); // open
}

test "CircuitBreaker half-opens after timeout and closes on success" {
    var cb = CircuitBreaker.new();
    cb.failure_threshold = 2;
    cb.timeout_ms = 1000;
    cb.recordFailure(std.testing.io);
    cb.recordFailure(std.testing.io);
    try std.testing.expect(!cb.allow(std.testing.io)); // open

    // Force the timeout to have elapsed.
    cb.last_failure_ms = @import("../core/Time.zig").monotonicNowSeconds() * 1000 - 5000;
    try std.testing.expect(cb.allow(std.testing.io)); // half-open

    cb.recordSuccess(std.testing.io);
    try std.testing.expect(cb.allow(std.testing.io)); // still half-open (1/2)
    cb.recordSuccess(std.testing.io);
    try std.testing.expect(cb.allow(std.testing.io)); // closed again
}

test "CircuitBreaker half-open failure re-opens" {
    var cb = CircuitBreaker.new();
    cb.failure_threshold = 1;
    cb.timeout_ms = 1000;
    cb.recordFailure(std.testing.io);
    try std.testing.expect(!cb.allow(std.testing.io)); // open
    cb.last_failure_ms = @import("../core/Time.zig").monotonicNowSeconds() * 1000 - 5000;
    try std.testing.expect(cb.allow(std.testing.io)); // half-open
    cb.recordFailure(std.testing.io);
    try std.testing.expect(!cb.allow(std.testing.io)); // back to open
}
