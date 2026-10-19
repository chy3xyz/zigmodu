//! Compile-time evaluation budget.
//!
//! `@setEvalBranchQuota` is a **resource**, and a fixed number is either too
//! small for a large graph (the classic "evaluation exceeded 1000 branches"
//! when a 154-table schema or a 200-module app grows) or needlessly high for a
//! small one. The rule here is the one zent adopted for its migration helpers:
//! a generous ceiling that scales with the input —
//!
//!     quota = base + per_unit × units
//!
//! — where `units` is the number of things the analysis walks (modules,
//! fields, nodes). A ceiling costs nothing when it is not reached, so the
//! number only has to be *large enough*, never tight.
//!
//! ## The rule that surprises people
//!
//! **The innermost quota on an evaluation path wins.** A caller's
//! `@setEvalBranchQuota(10_000_000)` cannot rescue a helper that sets its own
//! fixed quota inside, which is why library helpers (and these modules) must
//! scale rather than hard-code. Your own code can raise its quota before the
//! call, but only for evaluations that do not enter a narrower inner one.
//!
//! ## Measuring
//!
//! `scripts/check-comptime-budget.sh` builds a synthetic app with N modules and
//! M routes and prints wall time / peak RSS, so a regression shows up as a
//! number rather than as a mysterious CI timeout.

/// Fixed headroom every evaluation gets (name lookups, small loops, formatting).
pub const base: comptime_int = 1_000_000;

/// Additional budget per walked unit (module, field, node).
pub const per_unit: comptime_int = 20_000;

/// Budget for an analysis over `units` items. `units` must be comptime-known —
/// that is the point: the number is folded before the evaluation runs.
pub fn forUnits(comptime units: usize) comptime_int {
    return base + @as(comptime_int, @intCast(units)) * per_unit;
}

test "quota scales with the graph and keeps a floor" {
    try std.testing.expectEqual(base, forUnits(0));
    try std.testing.expect(forUnits(100) > forUnits(10));
    try std.testing.expectEqual(base + 200 * per_unit, forUnits(200));
}

const std = @import("std");
