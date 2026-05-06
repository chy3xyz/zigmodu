const std = @import("std");
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "marketing.coupon",
    .description = "Marketing coupon sub-module",
    .dependencies = &.{"marketing"},
    .is_internal = false,
};

pub fn init() !void { std.log.info("marketing.coupon initialized", .{}); }
pub fn deinit() void { std.log.info("marketing.coupon cleaned up", .{}); }
