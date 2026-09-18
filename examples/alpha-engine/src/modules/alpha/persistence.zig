//! alpha has no persistence: the price window is a worker field, rebuilt from
//! whatever quotes arrive after a restart.
//!
//! This is the stage where that claim is most worth stating out loud — a real
//! strategy usually *does* persist its model. Ours has none to persist. The file
//! exists because the framework's `zmodu verify` gate expects the full module
//! layout under `src/modules/`.
