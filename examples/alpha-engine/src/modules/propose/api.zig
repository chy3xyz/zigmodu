//! The propose module's public surface: the policy the agent runs under, the
//! table its risk rules score, and how big its two mailboxes are.
//!
//! This file is the reviewable one. `allow_execute = false` with a non-empty
//! allow list is the whole P3 contract, and it fits on two lines — which is the
//! point of writing the policy as a literal instead of spreading it across
//! handlers.

const ai = @import("zigmodu").ai;

/// The one action the agent may *name*. Listing it is what lets the agent
/// propose; the class is what stops it there — `Guard.Permissions` puts the
/// execute switch on top of the list, so a typo here cannot hand over the venue.
pub const action = "order.propose";

/// The bot's identity. The guard is about *its* authority, before any question
/// of which user it acts for — that question belongs to `security/`.
pub const tenant_id: i64 = 1;
pub const user_id: i64 = 7;

/// One day-end snapshot per run, and one goal per snapshot: 8 slots is already
/// more than the loop can use, so a future agent that starts chattering shows
/// up as backpressure instead of as a queue that grows.
pub const trigger_capacity: usize = 8;
pub const agent_capacity: usize = 8;

/// The risk engine (`src/ai/risk.zig`) scores a *subject string* by running SQL
/// rules; a rule that returns a row adds its score. So the subject has to exist
/// in a table, and that is what `staged_proposal` is: one row, written just
/// before the review, holding the leg under review.
pub const stage_schema =
    "CREATE TABLE IF NOT EXISTS staged_proposal (" ++
    "id INTEGER PRIMARY KEY, qty INTEGER NOT NULL, side TEXT NOT NULL, price INTEGER NOT NULL)";

/// The rules the proposal is scored against. Two bands, deliberately far apart:
///   * any leg at all scores 30 → below `escalate_threshold` → the review
///     approves, and the gate then refuses *execution*, which is the normal P3
///     ending and the one worth demonstrating.
///   * a leg of 8 contracts or more adds 90 → 120 ≥ `high_threshold` → the
///     review rejects it outright, before the execute check is even reached.
pub const risk_rules = [_]ai.risk.RiskRule{
    .{ .name = "any size", .sql = "SELECT 1 FROM staged_proposal WHERE qty > 0", .score = 30 },
    .{ .name = "whale", .sql = "SELECT 1 FROM staged_proposal WHERE qty >= 8", .score = 90 },
};

/// Spelled out rather than inherited: 30 is `low`, 120 is `high`, and both ends
/// of that range are part of what the report prints.
pub const high_threshold: i32 = 100;
pub const escalate_threshold: i32 = 50;
