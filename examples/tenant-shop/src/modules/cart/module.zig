const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "cart",
    .description = "Shopping cart (scaffold)",
    .dependencies = &.{ "tenant", "product", "inventory" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
