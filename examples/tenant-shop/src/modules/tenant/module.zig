const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "tenant",
    .description = "Shop tenant / store CRUD",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
