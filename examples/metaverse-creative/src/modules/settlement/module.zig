const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "settlement",
    .description = "P0 payment intent + ledger + ownership + outbox",
    .dependencies = &.{ "identity", "creative" },
};

pub fn init() !void {}
pub fn deinit() void {}
