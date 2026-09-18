//! The market module's domain: the replay series itself.
//!
//! Deterministic and embedded — no file, no network, no RNG (`docs/dev/alpha-engine-spec.md`
//! §5: CI must run offline and the same series must come out every time).

const c = @import("../../contracts.zig");

/// The feed deliberately *outruns* the book: 2,000 points into a 64-slot
/// mailbox makes `error.Full` a certainty, which is what turns backpressure
/// from a claim into a counter.
pub const points = 2_000;

/// A triangle wave around 10,000 with a 40-point period. The series is
/// deterministic; which prefix of it the book accepts under load is not, and
/// that difference is exactly what the run makes visible.
pub fn pointAt(i: usize) c.MarketData {
    const period = 40;
    const half = period / 2;
    const phase = i % period;
    const ramp: i64 = @intCast(if (phase < half) phase else period - phase);
    return .{
        .seq = @intCast(i),
        .price = 10_000 + ramp * 5,
        .qty = 1 + @as(i64, @intCast(i % 5)),
        .side = if (i % 3 == 0) .sell else .buy,
    };
}
