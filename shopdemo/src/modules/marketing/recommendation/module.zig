const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "marketing.recommendation",
    .description = "Marketing recommendation sub-module",
    .dependencies = &.{"marketing"},
    .is_internal = false,
};

pub fn init() !void { std.log.info("marketing.recommendation initialized", .{}); }
pub fn deinit() void { std.log.info("marketing.recommendation cleaned up", .{}); }
