const std = @import("std");

/// Module-specific logger with context
pub const ModuleLogger = struct {
    const Self = @This();

    module_name: []const u8,

    pub fn init(module_name: []const u8) Self {
        return .{
            .module_name = module_name,
        };
    }

    pub fn debug(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.debug("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }

    pub fn info(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.info("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }

    pub fn warn(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.warn("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }

    pub fn err(self: *const Self, comptime fmt: []const u8, args: anytype) void {
        std.log.err("[{s}] " ++ fmt, .{self.module_name} ++ args);
    }
};

/// Global log scope for the framework
pub const LogScope = struct {
    pub const default_level = std.log.Level.info;

    pub fn scope(comptime module: []const u8) type {
        return struct {
            pub const default_level = std.log.Level.info;

            pub fn debug(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).debug("[" ++ module ++ "] " ++ fmt, args);
            }

            pub fn info(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).info("[" ++ module ++ "] " ++ fmt, args);
            }

            pub fn warn(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).warn("[" ++ module ++ "] " ++ fmt, args);
            }

            pub fn err(comptime fmt: []const u8, args: anytype) void {
                std.log.scoped(.zigmodu).err("[" ++ module ++ "] " ++ fmt, args);
            }
        };
    }
};
