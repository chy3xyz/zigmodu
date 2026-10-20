const zmodu = @import("zmodu");
pub const info = zmodu.api.Module{
    .name = "subscription",
    .description = "Plan & subscription management",
    .dependencies = &.{},
    .is_internal = false,
};
pub fn init() !void {}
pub fn deinit() void {}
