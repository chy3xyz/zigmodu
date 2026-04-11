const api = @import("zigmodu").api;
const std = @import("std");

pub const info = api.Module{
    .name = "payment",
    .description = "Payment processing module - depends on order module",
    .dependencies = &.{"order"},
};

pub fn init() !void {
    std.log.info("💳 Payment module initialized", .{});
}

pub fn deinit() void {
    std.log.info("💳 Payment module cleaned up", .{});
}
