//! exec — the module barrel. Anything outside the module imports this file, so
//! `api` / `model` / `service` stay free to move.

pub const Module = @import("module.zig").Module;
pub const api = @import("api.zig");
pub const model = @import("model.zig");
pub const service = @import("service.zig");
