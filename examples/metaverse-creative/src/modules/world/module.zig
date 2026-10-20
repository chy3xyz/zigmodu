const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "world",
    .description = "Virtual world hosting featured creatives",
    .dependencies = &.{ "identity", "creative" },
};

pub fn init() !void {}
pub fn deinit() void {}
