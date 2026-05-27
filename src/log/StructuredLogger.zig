const std = @import("std");
const Time = @import("../core/Time.zig");

/// Log level[...]
pub const LogLevel = enum(u8) {
    DEBUG = 0,
    INFO = 1,
    WARN = 2,
    ERROR = 3,
    FATAL = 4,

    pub fn asString(self: LogLevel) []const u8 {
        return switch (self) {
            .DEBUG => "DEBUG",
            .INFO => "INFO",
            .WARN => "WARN",
            .ERROR => "ERROR",
            .FATAL => "FATAL",
        };
    }
};

/// Structured logger
/// [...] JSON [...]Context[...]
pub const StructuredLogger = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    level: LogLevel,
    output: Output,
    context: std.StringHashMap([]const u8),
    io: std.Io,

    const Output = union(enum) {
        stdout,
        stderr,
        file: std.Io.File,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, level: LogLevel, output: Output) Self {
        return .{
            .allocator = allocator,
            .level = level,
            .output = output,
            .context = std.StringHashMap([]const u8).init(allocator),
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.context.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.context.deinit();
    }

    /// [...]Context[...]
    pub fn withField(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.context.put(key_copy, value_copy);
    }

    /// [...]
    pub fn log(self: *Self, level: LogLevel, message: []const u8, fields: anytype) !void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) {
            return;
        }

        var entry = LogEntry{
            .timestamp = Time.monotonicNowSeconds(),
            .level = level,
            .message = message,
            .fields = std.StringHashMap([]const u8).init(self.allocator),
        };
        defer {
            var fields_iter = entry.fields.iterator();
            while (fields_iter.next()) |f| {
                self.allocator.free(f.key_ptr.*);
                self.allocator.free(f.value_ptr.*);
            }
            entry.fields.deinit();
        }

        // [...]Context[...]
        var ctx_iter = self.context.iterator();
        while (ctx_iter.next()) |entry_ctx| {
            const key = try self.allocator.dupe(u8, entry_ctx.key_ptr.*);
            const value = try self.allocator.dupe(u8, entry_ctx.value_ptr.*);
            try entry.fields.put(key, value);
        }

        // [...]
        const fields_info = @typeInfo(@TypeOf(fields));
        if (fields_info == .@"struct" and fields_info.@"struct".is_tuple == false) {
            inline for (fields_info.@"struct".fields) |field| {
                const key = field.name;
                const value = @field(fields, field.name);
                const value_str = try std.fmt.allocPrint(self.allocator, "{any}", .{value});
                try entry.fields.put(key, value_str);
            }
        }

        const json = try entry.toJson(self.allocator);
        defer self.allocator.free(json);

        // [...]
        // [...]failure[...]
        // 1. Log system must not fail due to outputfailure[...]
        // 2. Cannot log through log systemfailure
        switch (self.output) {
            .stdout => std.Io.File.stdout().writeStreamingAll(self.io, json) catch {},
            .stderr => std.Io.File.stderr().writeStreamingAll(self.io, json) catch {},
            .file => |file| file.writeStreamingAll(self.io, json) catch {},
        }
    }

    pub fn debug(self: *Self, message: []const u8, fields: anytype) !void {
        try self.log(.DEBUG, message, fields);
    }

    pub fn info(self: *Self, message: []const u8, fields: anytype) !void {
        try self.log(.INFO, message, fields);
    }

    pub fn warn(self: *Self, message: []const u8, fields: anytype) !void {
        try self.log(.WARN, message, fields);
    }

    pub fn err(self: *Self, message: []const u8, fields: anytype) !void {
        try self.log(.ERROR, message, fields);
    }

    pub fn fatal(self: *Self, message: []const u8, fields: anytype) !void {
        try self.log(.FATAL, message, fields);
    }
};

/// [...]
pub const LogRotator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    max_size: u64,
    max_files: u32,
    current_size: u64,
    current_file: ?std.Io.File,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8, max_size: u64, max_files: u32) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .base_path = try allocator.dupe(u8, base_path),
            .max_size = max_size,
            .max_files = max_files,
            .current_size = 0,
            .current_file = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.current_file) |file| {
            file.close(self.io);
        }
        self.allocator.free(self.base_path);
    }

    pub fn write(self: *Self, data: []const u8) !void {
        if (self.current_file == null or self.current_size + data.len > self.max_size) {
            try self.rotate();
        }

        if (self.current_file) |file| {
            try file.writeStreamingAll(self.io, data);
            self.current_size += data.len;
        }
    }

    fn rotate(self: *Self) !void {
        // CLOSED[...]
        if (self.current_file) |file| {
            file.close(self.io);
        }

        // [...]
        // [...]failure[...]
        // 1. Some files may not exist during rotation
        // 2. [...]failure[...]
        var i: u32 = self.max_files - 1;
        while (i > 0) : (i -= 1) {
            const old_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.base_path, i - 1 });
            defer self.allocator.free(old_name);
            const new_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.base_path, i });
            defer self.allocator.free(new_name);

            std.Io.Dir.cwd().rename(self.io, old_name, new_name) catch {};
        }

        // [...]
        const backup_name = try std.fmt.allocPrint(self.allocator, "{s}.0", .{self.base_path});
        defer self.allocator.free(backup_name);
        std.Io.Dir.cwd().rename(self.io, self.base_path, backup_name) catch {};

        // [...]
        self.current_file = try std.Io.Dir.cwd().createFile(self.io, self.base_path, .{});
        self.current_size = 0;
    }
};

/// [...]
const LogEntry = struct {
    timestamp: i64,
    level: LogLevel,
    message: []const u8,
    fields: std.StringHashMap([]const u8),

    pub fn toJson(self: LogEntry, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.array_list.Managed(u8).init(allocator);
        defer buf.deinit();

        try buf.appendSlice("{");
        try buf.print("\"timestamp\":{d},", .{self.timestamp});
        try buf.print("\"level\":\"{s}\",", .{self.level.asString()});
        try buf.print("\"message\":\"{s}\"", .{self.message});

        var iter = self.fields.iterator();
        while (iter.next()) |entry| {
            try buf.print(",\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        return buf.toOwnedSlice();
    }
};

test "StructuredLogger basic" {
    const allocator = std.testing.allocator;

    // Use a temp file instead of stdout to avoid corrupting test runner protocol
    const tmp_file = try std.Io.Dir.cwd().createFile(std.testing.io, "zigmodu_test_log.tmp", .{});
    defer {
        tmp_file.close(std.testing.io);
        std.Io.Dir.cwd().deleteFile(std.testing.io, "zigmodu_test_log.tmp") catch {};
    }

    var logger = StructuredLogger.init(allocator, std.testing.io, .INFO, .{ .file = tmp_file });
    defer logger.deinit();

    try logger.withField("app", "test");
    try logger.info("Test message", .{});
}

test "LogLevel ordering" {
    const testing = std.testing;

    try testing.expect(@intFromEnum(LogLevel.DEBUG) < @intFromEnum(LogLevel.INFO));
    try testing.expect(@intFromEnum(LogLevel.INFO) < @intFromEnum(LogLevel.WARN));
    try testing.expect(@intFromEnum(LogLevel.WARN) < @intFromEnum(LogLevel.ERROR));
    try testing.expect(@intFromEnum(LogLevel.ERROR) < @intFromEnum(LogLevel.FATAL));
}
