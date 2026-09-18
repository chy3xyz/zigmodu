//! propose *does* have a store, and it is the smallest one that still exercises
//! the framework's risk engine.
//!
//! `ai.RiskReview` (`src/ai/risk.zig`) scores a subject by running SQL rules —
//! so the subject has to be somewhere the rules can query. That somewhere is
//! `staged_proposal` in `module.zig`'s `State`: an in-memory SQLite table, one
//! row, written by the agent worker's thread immediately before the review and
//! read by the review itself. Nothing else touches it, nothing outlives the
//! process, and no second thread ever sees a half-written row.
//!
//! Everything else the module keeps is a counter (`service.Report`) — the
//! proposals it produced and where each one ended. A real deployment would put
//! those in an audit table and the staged row in the same transaction as the
//! order; this example keeps them in memory, because the spec's "no new
//! dependencies, must run offline" (`docs/dev/alpha-engine-spec.md` §5) rules
//! out a durable database here.
//!
//! The file exists because the framework's `zmodu verify` gate expects every
//! `src/modules/<name>/` to carry the full module layout — a module that stores
//! something in-process says so here just as clearly as one that stores nothing.
