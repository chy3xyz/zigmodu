//! Life — issue/release governance core (state machine, validation, model).
//!
//! Spec: docs/dev/superpowers/specs/2026-10-16-life-issue-release-design.md
//! Pure Zig, no IO, zero dependencies beyond std — the CLI consumes this
//! module as `life_core` (wired in both build.zig files, same pattern as
//! `module_graph`), and the Phase-2 module adapter imports it straight from
//! the framework. Experimental export until v1.x (see spec §12).

pub const model = @import("life/model.zig");
pub const state = @import("life/state.zig");
