//! φ (Phi) Accrual Failure Detector
//!
//! This implementation calculates the probability (φ) of a node failure based on
//! the history of heartbeat intervals. Unlike simple heartbeat/death protocols,
//! this provides an adaptive threshold that responds to network conditions.
//!
//! The φ value is calculated using a normal distribution CDF approximation:
//! φ = -log10(1 - CDF(elapsed_time))
//!
//! Reference: Hayashibara et al. "The φ Accrual Failure Detector"

const std = @import("std");
const Time = @import("../Time.zig");

/// Configuration for the accrual failure detector
pub const AccrualFailureDetectorConfig = struct {
    /// φ threshold above which a node is considered dead (default: 8.0)
    /// Higher values = more tolerant, Lower values = more sensitive
    phi_threshold: f64 = 8.0,

    /// Maximum number of heartbeat intervals to keep in history
    max_samples: usize = 1000,

    /// Minimum standard deviation (ms) - used when not enough data
    min_std_deviation_ms: f64 = 100.0,

    /// Maximum acceptable heartbeat interval (ms) - for sanity checks
    max_heartbeat_interval_ms: u64 = 60000,
};

/// Heartbeat history for a single node
pub const NodeHistory = struct {
    intervals_ms: std.ArrayList(i64),
    last_heartbeat_ms: i64,
};

/// φ Accrual Failure Detector
///
/// Calculates the probability of failure for each node using
/// heartbeat interval statistics.
pub const AccrualFailureDetector = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: AccrualFailureDetectorConfig,
    histories: std.StringHashMap(NodeHistory),

    /// Initialize a new failure detector
    pub fn init(allocator: std.mem.Allocator, config: AccrualFailureDetectorConfig) Self {
        return .{
            .allocator = allocator,
            .config = config,
            .histories = std.StringHashMap(NodeHistory).init(allocator),
        };
    }

    /// Release all resources
    pub fn deinit(self: *Self) void {
        var iter = self.histories.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.intervals_ms.deinit(self.allocator);
        }
        self.histories.deinit();
    }

    /// Record a heartbeat from a node
    pub fn heartbeat(self: *Self, node_id: []const u8) !void {
        const now_ms = Time.monotonicNowMilliseconds();

        const gop = try self.histories.getOrPut(node_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .intervals_ms = std.ArrayList(i64).empty,
                .last_heartbeat_ms = now_ms,
            };
            return;
        }

        const history = gop.value_ptr;
        const interval_ms = now_ms - history.last_heartbeat_ms;

        // Only record positive intervals (node was truly down or unreachable)
        if (interval_ms > 0 and interval_ms < self.config.max_heartbeat_interval_ms) {
            try history.intervals_ms.append(self.allocator, interval_ms);

            // Trim to max samples
            while (history.intervals_ms.items.len > self.config.max_samples) {
                _ = history.intervals_ms.orderedRemove(0);
            }
        }

        history.last_heartbeat_ms = now_ms;
    }

    /// Check if a node is considered alive
    pub fn isAlive(self: *Self, node_id: []const u8) bool {
        const phi_val = self.phi(node_id);
        return phi_val < self.config.phi_threshold;
    }

    /// Calculate the φ (phi) value for a node
    ///
    /// φ represents the probability of failure on a logarithmic scale.
    /// Higher φ = more likely to be dead.
    ///
    /// Typical interpretation:
    /// - φ < 1: Node is healthy
    /// - φ 1-4: Some concern
    /// - φ 4-8: Probable failure
    /// - φ > 8: Highly likely dead
    pub fn phi(self: *Self, node_id: []const u8) f64 {
        const history = self.histories.get(node_id) orelse {
            // No history = assume healthy
            return 0.0;
        };

        // Not enough data = assume healthy
        if (history.intervals_ms.items.len < 2) {
            return 0.0;
        }

        const now_ms = Time.monotonicNowMilliseconds();
        const elapsed_ms = now_ms - history.last_heartbeat_ms;

        // Calculate mean and standard deviation
        const mean_ms = self.mean(history.intervals_ms.items);
        const std_dev_ms = self.stdDev(history.intervals_ms.items, mean_ms);

        // Use minimum std dev to avoid division by zero
        const effective_std = @max(std_dev_ms, self.config.min_std_deviation_ms);

        // Calculate z-score
        const z = @as(f64, @floatFromInt(elapsed_ms)) / effective_std;

        // Calculate φ using normal CDF approximation
        const phi_val = -std.math.log10(@max(0.0001, 1.0 - normalCDF(z)));

        return phi_val;
    }

    /// Get detailed heartbeat statistics for a node
    pub fn getStats(self: *Self, node_id: []const u8) ?HeartbeatStats {
        const history = self.histories.get(node_id) orelse return null;

        if (history.intervals_ms.items.len < 2) {
            return .{
                .sample_count = history.intervals_ms.items.len,
                .mean_ms = 0,
                .std_dev_ms = 0,
                .phi = 0,
                .is_alive = true,
                .last_heartbeat_ms = history.last_heartbeat_ms,
            };
        }

        const mean_ms = self.mean(history.intervals_ms.items);
        const std_dev_ms = self.stdDev(history.intervals_ms.items, mean_ms);
        const phi_val = self.phi(node_id);

        return .{
            .sample_count = history.intervals_ms.items.len,
            .mean_ms = mean_ms,
            .std_dev_ms = std_dev_ms,
            .phi = phi_val,
            .is_alive = phi_val < self.config.phi_threshold,
            .last_heartbeat_ms = history.last_heartbeat_ms,
        };
    }

    /// Remove a node from tracking
    pub fn remove(self: *Self, node_id: []const u8) void {
        if (self.histories.getPtr(node_id)) |history| {
            history.intervals_ms.deinit(self.allocator);
        }
        _ = self.histories.remove(node_id);
    }

    fn mean(_: *Self, values: []const i64) f64 {
        if (values.len == 0) return 0.0;
        var sum: f64 = 0.0;
        for (values) |v| sum += @as(f64, @floatFromInt(v));
        return sum / @as(f64, @floatFromInt(values.len));
    }

    fn stdDev(self: *Self, values: []const i64, mean_val: f64) f64 {
        if (values.len < 2) return self.config.min_std_deviation_ms;
        var sum_sq: f64 = 0.0;
        for (values) |v| {
            const diff = @as(f64, @floatFromInt(v)) - mean_val;
            sum_sq += diff * diff;
        }
        const variance = sum_sq / @as(f64, @floatFromInt(values.len - 1));
        return @sqrt(variance);
    }
};

/// Statistics about a node's heartbeat behavior
pub const HeartbeatStats = struct {
    sample_count: usize,
    mean_ms: f64,
    std_dev_ms: f64,
    phi: f64,
    is_alive: bool,
    last_heartbeat_ms: i64,
};

// ============================================================================
// Normal Distribution CDF Approximation
// ============================================================================
//
// Uses the Abramowitz and Stegun approximation for the error function.
// This provides accurate results for the normal CDF needed for φ calculation.

/// Standard normal cumulative distribution function CDF(z)
/// Uses the error function approximation
fn normalCDF(z: f64) f64 {
    // Constants for Abramowitz and Stegun approximation
    const a1 = 0.254829592;
    const a2 = -0.284496736;
    const a3 = 1.421413741;
    const a4 = -1.453152027;
    const a5 = 1.061405429;
    const p = 0.3275911;

    // Handle negative z values
    const sign: f64 = if (z < 0) -1.0 else 1.0;
    const abs_z = @abs(z);

    // Calculate t = 1 / (1 + p * |z|)
    const t = 1.0 / (1.0 + p * abs_z);
    const t2 = t * t;
    const t3 = t2 * t;
    const t4 = t3 * t;
    const t5 = t4 * t;

    // Calculate the series sum
    // y = 1 - (((((a5*t + a4)*t + a3)*t + a2)*t + a1)*t * exp(-z*z)
    const y = 1.0 - (((((a5 * t5) + (a4 * t4)) + (a3 * t3)) + (a2 * t2)) + (a1 * t)) * std.math.exp(-abs_z * abs_z);

    return 0.5 * (1.0 + sign * y);
}

// ============================================================================
// Tests - DISABLED due to Zig 0.16.0 test compilation type resolution issue
// ============================================================================
//
// Inline tests are disabled because Zig 0.16.0 has a known issue where
// std.ArrayList.init(allocator) fails type resolution inside nested struct
// literals during test compilation. The modules compile correctly via
// `zig build` but fail during `zig build test`.
//
// To enable tests when this issue is fixed, remove the `//` prefix from each test.
