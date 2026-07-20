const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "identity",
    .description = "Creator DID + reputation (zent)",
    .dependencies = &.{},
};

pub fn init() !void {}
pub fn deinit() void {}
