const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "order",
    .description = "Orders + outbox (scaffold)",
    .dependencies = &.{ "tenant", "user", "product", "inventory", "cart" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
