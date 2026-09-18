//! exec has no persistence, and that is a decision, not a gap.
//!
//! Everything this module knows lives in the `PaperExchange` value owned by the
//! `Execution` worker: one thread reads and writes it, nothing outlives the
//! process, and the fills that *do* leave the module leave as messages to the
//! supervised reporter (see `service.zig`).
//!
//! The file exists because the framework's `zmodu verify` gate expects every
//! `src/modules/<name>/` to carry the full module layout — a module that
//! genuinely has nothing to store says so here rather than by omission.
