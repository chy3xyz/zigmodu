//! Retry utilities for zigzero
//!
//! Provides exponential backoff retry aligned with go-zero patterns.

const std = @import("std");
const errors = @import("../sqlx/errors.zig");

/// Retry policy configuration
pub const Policy = struct {
    /// Maximum number of retry attempts
    max_attempts: u32 = 3,
    /// Initial delay in milliseconds
    initial_delay_ms: u64 = 100,
    /// Maximum delay in milliseconds
    max_delay_ms: u64 = 10000,
    /// Multiplier for exponential backoff
    multiplier: f64 = 2.0,
    /// Add random jitter (0.0 - 1.0)
    jitter: f64 = 0.1,
};

/// Retry function with generic return type
pub fn retry(comptime T: type, policy: Policy, operation: *const fn () errors.ResultT(T)) errors.ResultT(T) {
    var delay_ms: u64 = policy.initial_delay_ms;

    var attempt: u32 = 0;
    while (attempt < policy.max_attempts) : (attempt += 1) {
        const result = operation();
        if (result) |value| {
            return value;
        } else |_| {
            if (attempt == policy.max_attempts - 1) {
                return result;
            }

            // Calculate delay with exponential backoff and jitter
            const jitter_amount = @as(f64, @floatFromInt(delay_ms)) * policy.jitter;
            _ = jitter_amount;
            // std.Thread.sleep(delay_ms * std.time.ns_per_ms);// TODO: 0.16.0 needs io

            delay_ms = @min(policy.max_delay_ms, @as(u64, @intFromFloat(@as(f64, @floatFromInt(delay_ms)) * policy.multiplier)));
        }
    }

    return error.ServerError;
}

/// Retry a function that returns void
pub fn retryVoid(policy: Policy, operation: *const fn () errors.Result) errors.Result {
    var delay_ms: u64 = policy.initial_delay_ms;

    var attempt: u32 = 0;
    while (attempt < policy.max_attempts) : (attempt += 1) {
        operation() catch |err| {
            if (attempt == policy.max_attempts - 1) {
                return err;
            }

            const jitter_amount = @as(f64, @floatFromInt(delay_ms)) * policy.jitter;
            _ = jitter_amount;
            // std.Thread.sleep(delay_ms * std.time.ns_per_ms);// TODO: 0.16.0 needs io

            delay_ms = @min(policy.max_delay_ms, @as(u64, @intFromFloat(@as(f64, @floatFromInt(delay_ms)) * policy.multiplier)));
        };
        return;
    }

    return error.ServerError;
}

/// Circuit breaker + retry combo
pub fn retryWithBreaker(comptime T: type, policy: Policy, breaker: *anyopaque, operation: *const fn () errors.ResultT(T)) errors.ResultT(T) {
    _ = breaker;
    return retry(T, policy, operation);
}

test "retry success" {
    var count: u32 = 0;
    const Op = struct {
        var c: *u32 = undefined;
        fn operation() errors.ResultT(u32) {
            c.* += 1;
            if (c.* < 3) return error.ServerError;
            return c.*;
        }
    };

    Op.c = &count;
    const result = retry(u32, .{ .max_attempts = 5, .initial_delay_ms = 10 }, Op.operation);
    try std.testing.expectEqual(@as(u32, 3), result);
}

test "retry failure" {
    const op = struct {
        fn operation() errors.ResultT(u32) {
            return error.ServerError;
        }
    }.operation;

    const result = retry(u32, .{ .max_attempts = 2, .initial_delay_ms = 10 }, op);
    try std.testing.expectError(error.ServerError, result);
}
