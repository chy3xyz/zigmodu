const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "creative",
    .description = "Asset-as-idea (problem/solution/world) + marketplace",
    .dependencies = &.{"identity"},
};

pub fn init() !void {}
pub fn deinit() void {}
