const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "payment",
    .description = "Payments + idempotent charge",
    .dependencies = &.{ "tenant", "order" },
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
