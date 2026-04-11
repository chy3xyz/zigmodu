const api = @import("zigmodu").api;
const std = @import("std");

pub const info = api.Module{
    .name = "order",
    .description = "Order management module - depends on user module",
    .dependencies = &.{"user"},
};

pub fn init() !void {
    std.log.info("📦 Order module initialized", .{});
}

pub fn deinit() void {
    std.log.info("📦 Order module cleaned up", .{});
}
