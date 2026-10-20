const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "identity",
    .description = "Creator DID + reputation (zent)",
    .dependencies = &.{},
};

pub fn init() !void {}
pub fn deinit() void {}
