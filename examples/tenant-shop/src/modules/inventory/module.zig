const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "inventory",
    .description = "Stock qty / reserved per product",
    .dependencies = &.{ "tenant", "product" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
