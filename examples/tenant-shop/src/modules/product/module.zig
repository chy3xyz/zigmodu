const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "product",
    .description = "Tenant-scoped product catalog",
    .dependencies = &.{"tenant"},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
