//! book has no persistence, and would need a different example to have one.
//!
//! The order book here is a filter over a print series — it holds the touch, not
//! resting orders, so there is nothing to restore. A real book keeps depth in
//! memory and rebuilds it from a snapshot plus a journal, which is work this
//! stage explicitly does not do (`docs/dev/alpha-engine-spec.md` §5).
//!
//! The file exists because the framework's `zmodu verify` gate expects the full
//! module layout under `src/modules/`.
