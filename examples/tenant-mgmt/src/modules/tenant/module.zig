const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "tenant",
    .description = "Multi-tenant management — tenant CRUD, tier management",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
