const std = @import("std");
const builtin = @import("builtin");

/// Global Io instance — auto-switches to std.testing.io in test mode.
pub var io: std.Io = if (builtin.is_test) std.testing.io else undefined;

/// Initialize Io from process init data (call in main).
pub fn @"init"(init_data: std.process.Init) void {
    io = init_data.io;
}
