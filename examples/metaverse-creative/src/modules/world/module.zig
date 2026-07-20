const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "world",
    .description = "Virtual world hosting featured creatives",
    .dependencies = &.{ "identity", "creative" },
};

pub fn init() !void {}
pub fn deinit() void {}
