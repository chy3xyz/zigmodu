const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "catalog",
    .description = "zent-backed catalog (tenant + product)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
