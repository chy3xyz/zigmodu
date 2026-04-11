const api = @import("zigmodu").api;
const std = @import("std");

pub const info = api.Module{
    .name = "user",
    .description = "User management module - base module with no dependencies",
    .dependencies = &.{},
};

pub fn init() !void {
    std.log.info("👤 User module initialized", .{});
}

pub fn deinit() void {
    std.log.info("👤 User module cleaned up", .{});
}
