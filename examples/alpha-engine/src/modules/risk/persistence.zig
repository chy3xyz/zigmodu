//! risk has no persistence: the position is a worker field, owned by the one
//! thread that handles signals and lost on shutdown.
//!
//! That is the honest shape for this example — a real risk service would keep
//! the position in the order store and rebuild it on restart, which is exactly
//! the work this stage is not doing. The file exists because the framework's
//! `zmodu verify` gate expects the full module layout under `src/modules/`.
