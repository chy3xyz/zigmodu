const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "shop_bff",
    .description = "Storefront BFF — no tables",
    .dependencies = &.{ "user", "product", "cart", "order", "payment" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
