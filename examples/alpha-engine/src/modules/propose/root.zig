//! propose — the module barrel. Everything outside the module imports this and
//! nothing else.

pub const Module = @import("module.zig").Module;
pub const api = @import("api.zig");
pub const model = @import("model.zig");
pub const service = @import("service.zig");
