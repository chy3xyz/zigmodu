const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "inventory",
    .description = "Stock qty / reserved per product",
    .dependencies = &.{"tenant", "product"},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
