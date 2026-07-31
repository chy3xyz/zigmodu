const zigmodu = @import("zigmodu");
pub const info = zigmodu.api.Module{
    .name = "user",
    .description = "User management with tenant isolation",
    .dependencies = &.{},
    .is_internal = false,
};
pub fn init() !void {}
pub fn deinit() void {}
