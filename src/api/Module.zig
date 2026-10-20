//! Compatibility shim: the module contract lives in `core/Module.zig`.
//!
//! `zmodu.api.Module` and the other names below keep working; new code can
//! import `core.Module` directly. The move removed the last core -> api edge
//! (core's registry had to import the API layer to name the contract).

pub const Module = @import("../core/Module.zig").Module;
pub const RuntimeOptions = @import("../core/Module.zig").RuntimeOptions;
pub const Modulith = @import("../core/Module.zig").Modulith;
pub const ModuleTrait = @import("../core/Module.zig").ModuleTrait;
