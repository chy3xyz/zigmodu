//! ZigModu module `order` (zent-backed) — lifecycle hooks are no-ops
//! because the zent driver is owned by `main.zig` and shared across
//! handlers via the `OrderStore` pointer.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "order",
    .description = "zent-backed order domain (orders + line items)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
