const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "admin_bff",
    .description = "Merchant admin BFF — no tables",
    .dependencies = &.{ "tenant", "user", "product", "inventory", "order" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
