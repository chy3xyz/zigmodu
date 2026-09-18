//! audit has no persistence, and here that is the *point*: the trail it keeps is
//! what a real system would flush to a log or a column store, and the example
//! stops one hop short of that on purpose (see `docs/dev/alpha-engine-spec.md`
//! §5: no new dependencies).
//!
//! The counter it does keep lives in the worker's own field. The file exists
//! because the framework's `zmodu verify` gate expects the full module layout
//! under `src/modules/`.
