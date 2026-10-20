const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "order",
    .description = "Orders + outbox (scaffold)",
    .dependencies = &.{ "tenant", "user", "product", "inventory", "cart" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
