const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "tenant",
    .description = "Shop tenant / store CRUD",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
