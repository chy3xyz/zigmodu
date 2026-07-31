const zigmodu = @import("zigmodu");
pub const info = zigmodu.api.Module{
    .name = "subscription",
    .description = "Plan & subscription management",
    .dependencies = &.{},
    .is_internal = false,
};
pub fn init() !void {}
pub fn deinit() void {}
