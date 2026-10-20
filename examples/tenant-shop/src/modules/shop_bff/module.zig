const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "shop_bff",
    .description = "Storefront BFF — no tables",
    .dependencies = &.{ "user", "product", "cart", "order", "payment" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
