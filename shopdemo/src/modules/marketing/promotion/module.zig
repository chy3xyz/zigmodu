const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "marketing.promotion",
    .description = "Marketing promotion sub-module",
    .dependencies = &.{"marketing"},
    .is_internal = false,
};

pub fn init() !void { std.log.info("marketing.promotion initialized", .{}); }
pub fn deinit() void { std.log.info("marketing.promotion cleaned up", .{}); }
