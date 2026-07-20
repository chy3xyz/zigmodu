const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "creative",
    .description = "Asset-as-idea (problem/solution/world) + marketplace",
    .dependencies = &.{"identity"},
};

pub fn init() !void {}
pub fn deinit() void {}
