const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "marketing.affiliate",
    .description = "Marketing affiliate sub-module",
    .dependencies = &.{"marketing"},
    .is_internal = false,
};

pub fn init() !void { std.log.info("marketing.affiliate initialized", .{}); }
pub fn deinit() void { std.log.info("marketing.affiliate cleaned up", .{}); }
