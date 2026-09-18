const std = @import("std");
const Time = @import("../core/Time.zig");

/// Log level
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

/// Reports a failure inside the logging subsystem itself; `detail` names the
/// sink, or the destination file of a rotation rename.
///
/// Never routes through `StructuredLogger.log`: the failing sink is the very
/// output that call would write to, so reporting through it recurses.
/// One line on stderr, then the caller carries on — a broken log sink must not
/// take the process down.
fn reportInternalFailure(what: []const u8, detail: []const u8, err: anyerror) void {
    std.debug.print("zigmodu.StructuredLogger: {s} ({s}): {s}\n", .{ what, detail, @errorName(err) });
}

/// Structured logger
/// Supports JSON output, context fields and multiple output targets
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
        self.* = undefined;
    }

    /// Adds a context field applied to every later log entry
    pub fn withField(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);
        try self.context.put(key_copy, value_copy);
    }

    /// Writes one log entry; entries below the configured level are dropped
    pub fn log(self: *Self, level: LogLevel, message: []const u8, fields: anytype) !void {
        if (@backingInt(level) < @backingInt(self.level)) {
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

        // Merge the context fields into the entry
        var ctx_iter = self.context.iterator();
        while (ctx_iter.next()) |entry_ctx| {
            const key = try self.allocator.dupe(u8, entry_ctx.key_ptr.*);
            const value = try self.allocator.dupe(u8, entry_ctx.value_ptr.*);
            try entry.fields.put(key, value);
        }

        // Merge the caller-supplied fields
        const fields_info = @typeInfo(@TypeOf(fields));
        if (fields_info == .@"struct" and fields_info.@"struct".is_tuple == false) {
            inline for (fields_info.@"struct".field_names) |key| {
                const value = @field(fields, key);
                const value_str = try std.fmt.allocPrint(self.allocator, "{any}", .{value});
                // `key` is a comptime string literal (read-only memory) — dupe
                // it before inserting: the defer above frees every map key.
                const key_copy = try self.allocator.dupe(u8, key);
                errdefer self.allocator.free(key_copy);
                try entry.fields.put(key_copy, value_str);
            }
        }

        const json = try entry.toJson(self.allocator);
        defer self.allocator.free(json);

        // Emit the entry. A failed write is reported on stderr and dropped:
        // the logger must not crash, nor fail its caller, because its sink died.
        // (The capture is `e`, not `err`: `Self.err` is a method in scope.)
        switch (self.output) {
            .stdout => std.Io.File.stdout().writeStreamingAll(self.io, json) catch |e| reportInternalFailure("output write failed", "stdout", e),
            .stderr => std.Io.File.stderr().writeStreamingAll(self.io, json) catch |e| reportInternalFailure("output write failed", "stderr", e),
            .file => |file| file.writeStreamingAll(self.io, json) catch |e| reportInternalFailure("output write failed", "file", e),
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

/// Log file rotator
pub const LogRotator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// Directory the log files live in. `init` uses the process CWD; `initIn`
    /// lets a caller (a test, or a server with a dedicated log dir) point it
    /// somewhere else. Held as a value so `rotate` never re-resolves the CWD.
    dir: std.Io.Dir,
    base_path: []const u8,
    max_size: u64,
    max_files: u32,
    current_size: u64,
    current_file: ?std.Io.File,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8, max_size: u64, max_files: u32) !Self {
        return initIn(allocator, io, std.Io.Dir.cwd(), base_path, max_size, max_files);
    }

    /// Same as `init`, but writes into `dir` instead of the process CWD.
    pub fn initIn(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, base_path: []const u8, max_size: u64, max_files: u32) !Self {
        return .{
            .allocator = allocator,
            .io = io,
            .dir = dir,
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
        self.* = undefined;
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
        // Close the current file first
        if (self.current_file) |file| {
            file.close(self.io);
        }

        // Rotate the old files. Only unexpected rename failures are reported:
        // a missing source (the `.N` slot, or the base file on the first write)
        // is the normal state, and rotation must not block writes to the new log.
        var i: u32 = self.max_files - 1;
        while (i > 0) : (i -= 1) {
            const old_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.base_path, i - 1 });
            defer self.allocator.free(old_name);
            const new_name = try std.fmt.allocPrint(self.allocator, "{s}.{d}", .{ self.base_path, i });
            defer self.allocator.free(new_name);

            std.Io.Dir.rename(self.dir, old_name, self.dir, new_name, self.io) catch |err| switch (err) {
                error.FileNotFound => {},
                else => reportInternalFailure("rotation rename failed", new_name, err),
            };
        }

        // Move the current file to .0
        const backup_name = try std.fmt.allocPrint(self.allocator, "{s}.0", .{self.base_path});
        defer self.allocator.free(backup_name);
        std.Io.Dir.rename(self.dir, self.base_path, self.dir, backup_name, self.io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => reportInternalFailure("rotation rename failed", backup_name, err),
        };

        // Open a fresh current file
        self.current_file = try self.dir.createFile(self.io, self.base_path, .{});
        self.current_size = 0;
    }
};

/// One log entry
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

test "StructuredLogger struct fields keys are owned" {
    // Regression: keys coming from struct fields are comptime string
    // literals (read-only memory). They must be duped before map insert —
    // the entry deinit frees every key, and freeing a literal crashes.
    const allocator = std.testing.allocator;

    const tmp_file = try std.Io.Dir.cwd().createFile(std.testing.io, "zigmodu_test_log.tmp", .{});
    defer {
        tmp_file.close(std.testing.io);
        std.Io.Dir.cwd().deleteFile(std.testing.io, "zigmodu_test_log.tmp") catch {};
    }

    var logger = StructuredLogger.init(allocator, std.testing.io, .DEBUG, .{ .file = tmp_file });
    defer logger.deinit();

    // Non-empty struct fields — previously aborted freeing the literal keys.
    try logger.info("user event", .{ .user_id = 42, .action = "login" });
    try logger.err("boom", .{ .code = 500, .message = "upstream timeout" });
}

/// Reads a bounded log file back as a slice of `buf`.
fn readLogFile(dir: std.Io.Dir, io: std.Io, name: []const u8, buf: []u8) ![]const u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const n = try file.readStreaming(io, &.{buf});
    return buf[0..n];
}

test "StructuredLogger carries a bound trace_id on every line" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [1024]u8 = undefined;

    // No field bound: the line keeps its historical shape — no empty `{}`,
    // no stray `trace_id`.
    const plain_file = try tmp.dir.createFile(io, "plain.log", .{});
    var plain = StructuredLogger.init(allocator, io, .INFO, .{ .file = plain_file });
    defer {
        plain.deinit();
        plain_file.close(io);
    }
    try plain.info("charged", .{});
    const plain_line = try readLogFile(tmp.dir, io, "plain.log", &buf);
    try std.testing.expect(std.mem.indexOf(u8, plain_line, "trace_id") == null);
    try std.testing.expectEqualStrings(
        "{\"timestamp\":",
        plain_line[0..13],
    );

    // Bound `trace_id`: it lands on *every* line, so a slow span can be walked
    // straight to its log entries.
    const traced_file = try tmp.dir.createFile(io, "traced.log", .{});
    var traced = StructuredLogger.init(allocator, io, .INFO, .{ .file = traced_file });
    defer {
        traced.deinit();
        traced_file.close(io);
    }
    try traced.withField("trace_id", "4bf92f3577b34da6a3ce929d0e0e4736");
    try traced.info("charged", .{});
    try traced.err("refund failed", .{});
    const traced_lines = try readLogFile(tmp.dir, io, "traced.log", &buf);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, traced_lines, "\"trace_id\":\"4bf92f3577b34da6a3ce929d0e0e4736\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, traced_lines, "\"message\":\""));
}

test "LogLevel ordering" {
    const testing = std.testing;

    try testing.expect(@backingInt(LogLevel.DEBUG) < @backingInt(LogLevel.INFO));
    try testing.expect(@backingInt(LogLevel.INFO) < @backingInt(LogLevel.WARN));
    try testing.expect(@backingInt(LogLevel.WARN) < @backingInt(LogLevel.ERROR));
    try testing.expect(@backingInt(LogLevel.ERROR) < @backingInt(LogLevel.FATAL));
}

test "LogRotator rotates by size and keeps max_files generations" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // 4-byte writes against a 10-byte cap rotate once every two writes, so each
    // generation holds the pair of writes that overflowed together.
    var rotator = try LogRotator.initIn(allocator, io, tmp.dir, "app.log", 10, 3);
    defer rotator.deinit();

    try rotator.write("aaaa");
    try rotator.write("bbbb");
    try rotator.write("cccc");
    try rotator.write("dddd");
    try rotator.write("eeee");

    // Current file holds only the last write; the earlier pairs moved down a slot.
    try expectFileContents(tmp.dir, io, "app.log", "eeee");
    try expectFileContents(tmp.dir, io, "app.log.0", "ccccdddd");
    try expectFileContents(tmp.dir, io, "app.log.1", "aaaabbbb");
    // max_files == 3 → nothing older than .1 survives.
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "app.log.2", .{}));
}

/// Reads `name` out of `dir` and asserts its exact contents.
fn expectFileContents(dir: std.Io.Dir, io: std.Io, name: []const u8, want: []const u8) !void {
    var buf: [64]u8 = undefined;
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const n = try file.readStreaming(io, &.{&buf});
    try std.testing.expectEqualStrings(want, buf[0..n]);
}
