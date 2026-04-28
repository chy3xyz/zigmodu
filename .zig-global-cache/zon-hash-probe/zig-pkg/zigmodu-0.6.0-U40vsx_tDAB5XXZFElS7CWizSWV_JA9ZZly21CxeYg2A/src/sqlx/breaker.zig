//! Minimal circuit breaker adapter for sqlx (zigzero-compatible API)

const std = @import("std");

/// Simple circuit breaker compatible with zigzero sqlx expectations
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
    io: std.Io = undefined,

    pub fn new(io: std.Io) Self {
        return .{
            .io = io,
        };
    }

    pub fn allow(self: *Self) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        switch (self.state) {
            .closed => return true,
            .half_open => return true,
            .open => {
                const now = 0;
                if (now - self.last_failure_ms > @as(i64, @intCast(self.timeout_ms))) {
                    self.state = .half_open;
                    self.success_count = 0;
                    return true;
                }
                return false;
            },
        }
    }

    pub fn recordSuccess(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

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

    pub fn recordFailure(self: *Self) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.failure_count += 1;
        self.last_failure_ms = 0;

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
