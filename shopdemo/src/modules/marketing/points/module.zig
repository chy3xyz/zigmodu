const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "marketing.points",
    .description = "Marketing points sub-module",
    .dependencies = &.{"marketing"},
    .is_internal = false,
};

pub fn init() !void { std.log.info("marketing.points initialized", .{}); }
pub fn deinit() void { std.log.info("marketing.points cleaned up", .{}); }
