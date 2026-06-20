//! Compile-time log level filtering.
//! Import build_options to determine the minimum log level at compile time.

const std = @import("std");
const build_options = @import("build_options");

/// Log levels ordered by severity (higher = more severe).
pub const LogLevel = enum(u3) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn fromString(s: []const u8) ?LogLevel {
        const lower = s; // assume already lower in build_options
        if (std.mem.eql(u8, lower, "debug")) return .debug;
        if (std.mem.eql(u8, lower, "info")) return .info;
        if (std.mem.eql(u8, lower, "warn")) return .warn;
        if (std.mem.eql(u8, lower, "err")) return .err;
        return null;
    }
};

/// Compile-time minimum log level from build_options.
pub const LOG_LEVEL: LogLevel = blk: {
    const raw = build_options.log_level;
    break :blk LogLevel.fromString(raw) orelse @compileError("Invalid log_level: '" ++ raw ++ "'. Expected debug/info/warn/err");
};

/// Returns true if the given level meets or exceeds the compile-time minimum.
pub fn logLevelAtLeast(level: LogLevel) bool {
    return @intFromEnum(level) >= @intFromEnum(LOG_LEVEL);
}

test "logLevelAtLeast" {
    // LOG_LEVEL is set at compile-time; verify the function is consistent.
    // At minimum, LOG_LEVEL itself should always pass.
    try std.testing.expect(logLevelAtLeast(LOG_LEVEL));
    // Higher severity levels should also pass.
    if (@intFromEnum(LOG_LEVEL) <= @intFromEnum(LogLevel.err)) {
        try std.testing.expect(logLevelAtLeast(.err));
    }
}

test "LogLevel ordering" {
    try std.testing.expect(@intFromEnum(LogLevel.debug) < @intFromEnum(LogLevel.info));
    try std.testing.expect(@intFromEnum(LogLevel.info) < @intFromEnum(LogLevel.warn));
    try std.testing.expect(@intFromEnum(LogLevel.warn) < @intFromEnum(LogLevel.err));
}

test "LogLevel fromString" {
    try std.testing.expectEqual(LogLevel.debug, LogLevel.fromString("debug").?);
    try std.testing.expectEqual(LogLevel.info, LogLevel.fromString("info").?);
    try std.testing.expectEqual(LogLevel.warn, LogLevel.fromString("warn").?);
    try std.testing.expectEqual(LogLevel.err, LogLevel.fromString("err").?);
    try std.testing.expect(LogLevel.fromString("invalid") == null);
}
