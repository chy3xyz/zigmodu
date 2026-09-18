//! market has no persistence — by definition, nearly: the replay series is the
//! module's data, and it is embedded in `model.zig` rather than read from a file
//! so the example is deterministic and offline.
//!
//! Swapping this file for a loader (NDJSON, a database, a live socket) is the
//! one change the "Live" driver mode would need. The file exists because the
//! framework's `zmodu verify` gate expects the full module layout under
//! `src/modules/`.
