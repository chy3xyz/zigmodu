const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = allocator;


    std.log.info("Application started!", .{});

    // TODO: Add your modules here
}
