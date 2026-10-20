const zmodu = @import("zmodu");
pub const info = zmodu.api.Module{
    .name = "user",
    .description = "User management with tenant isolation",
    .dependencies = &.{},
    .is_internal = false,
};
pub fn init() !void {}
pub fn deinit() void {}
