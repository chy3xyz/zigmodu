const std = @import("std");
const ConfigManager = @import("ConfigManager.zig").ConfigManager;

/// TOML configuration loader
pub const TomlLoader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Load TOML file into ConfigManager
    pub fn loadFile(self: *Self, path: []const u8, config: *ConfigManager) !void {
        const file = try std.Io.Dir.cwd().openFile(path, .{});
        defer file.close(std.testing.io);

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        try self.parse(content, config, "");
    }

    /// Parse TOML content
    fn parse(self: *Self, content: []const u8, config: *ConfigManager, prefix: []const u8) !void {
        _ = prefix;
        var lines = std.mem.splitSequence(u8, content, "\n");
        var current_section: ?[]const u8 = null;
        defer if (current_section) |s| self.allocator.free(s);

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (trimmed[0] == '[') {
                if (current_section) |s| self.allocator.free(s);
                current_section = try self.parseSection(trimmed);
                continue;
            }

            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                const full_key = if (current_section) |section|
                    try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ section, key })
                else
                    try self.allocator.dupe(u8, key);
                defer self.allocator.free(full_key);

                try self.parseValue(full_key, value, config);
            }
        }
    }

    fn parseSection(self: *Self, line: []const u8) ![]const u8 {
        var end = line.len - 1;
        if (line[end] == ']') end -= 1;
        const inner = line[1 .. end + 1];
        return try self.allocator.dupe(u8, inner);
    }

    fn parseValue(self: *Self, key: []const u8, value: []const u8, config: *ConfigManager) !void {
        if (std.mem.eql(u8, value, "true")) {
            try config.set(key, .{ .boolean = true });
            return;
        }
        if (std.mem.eql(u8, value, "false")) {
            try config.set(key, .{ .boolean = false });
            return;
        }

        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            const str = value[1 .. value.len - 1];
            const unescaped = try self.unescapeString(str);
            defer self.allocator.free(unescaped);
            try config.set(key, .{ .string = unescaped });
            return;
        }

        if (std.fmt.parseInt(i64, value, 10)) |int_val| {
            try config.set(key, .{ .integer = int_val });
            return;
        } else |_| {}

        if (std.fmt.parseFloat(f64, value)) |float_val| {
            try config.set(key, .{ .float = float_val });
            return;
        } else |_| {}

        try config.set(key, .{ .string = value });
    }

    fn unescapeString(self: *Self, str: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, str);
    }
};

test "TomlLoader basic parsing" {
    const allocator = std.testing.allocator;

    const toml_content = "title = \"Test Application\"\nport = 8080\ndebug = true\ntimeout = 30.5\n";

    var loader = TomlLoader.init(allocator);
    var config = ConfigManager.init(allocator);
    defer config.deinit();

    try loader.parse(toml_content, &config, "");

    try std.testing.expectEqualStrings("Test Application", config.getString("title").?);
    try std.testing.expectEqual(@as(i64, 8080), config.getInt("port").?);
    try std.testing.expectEqual(true, config.getBool("debug").?);
    try std.testing.expectEqual(@as(f64, 30.5), config.getFloat("timeout").?);
}

test "TomlLoader with sections" {
    const allocator = std.testing.allocator;

    const toml_content = "[database]\nhost = \"localhost\"\nport = 5432\n";

    var loader = TomlLoader.init(allocator);
    var config = ConfigManager.init(allocator);
    defer config.deinit();

    try loader.parse(toml_content, &config, "");

    try std.testing.expectEqualStrings("localhost", config.getString("database.host").?);
    try std.testing.expectEqual(@as(i64, 5432), config.getInt("database.port").?);
}
