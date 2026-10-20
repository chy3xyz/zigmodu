const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "user",
    .description = "Tenant-scoped users (staff/customer)",
    .dependencies = &.{"tenant"},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
