const std = @import("std");

/// Lightweight YAML parser for basic configuration files
/// Supports: key-value pairs, nested objects (2 levels), arrays of strings, comments
pub const YamlParser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    /// Parse YAML file into a flat key-value map
    /// Nested keys are flattened with dots (e.g., server.port -> "server.port")
    pub fn parseFile(self: *Self, path: []const u8) !std.StringHashMap([]const u8) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return try self.parse(content);
    }

    pub fn parse(self: *Self, content: []const u8) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var iter = result.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            result.deinit();
        }

        var lines = std.mem.splitSequence(u8, content, "\n");
        var current_section: ?[]const u8 = null;
        var array_key: ?[]const u8 = null;
        var array_buffer: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(self.allocator);
        defer {
            if (current_section) |s| self.allocator.free(s);
            if (array_key) |k| self.allocator.free(k);
            array_buffer.deinit();
        }

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");

            // Skip empty lines and comments
            if (line.len == 0 or line[0] == '#') continue;

            // Section header
            if (line[0] == '[' and line[line.len - 1] == ']') {
                if (current_section) |s| self.allocator.free(s);
                current_section = try self.allocator.dupe(u8, line[1 .. line.len - 1]);
                continue;
            }

            // Array items (lines starting with -)
            if (std.mem.startsWith(u8, line, "- ")) {
                const item = std.mem.trim(u8, line[2..], " \t\"'");
                if (array_buffer.items.len > 0) {
                    try array_buffer.append(',');
                }
                try array_buffer.appendSlice(item);
                continue;
            }

            // If we were building an array and now hit a key-value, save the array first
            if (array_key != null and array_buffer.items.len > 0) {
                const key_copy = try self.allocator.dupe(u8, array_key.?);
                const value_copy = try self.allocator.dupe(u8, array_buffer.items);
                try result.put(key_copy, value_copy);
                array_buffer.clearRetainingCapacity();
                if (array_key) |k| self.allocator.free(k);
                array_key = null;
            }

            // Key-value pair
            if (std.mem.indexOf(u8, line, ":")) |colon_idx| {
                const key = std.mem.trim(u8, line[0..colon_idx], " \t");
                const raw_value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");
                const value = stripQuotes(raw_value);

                const full_key = if (current_section) |section| blk: {
                    const fk = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ section, key });
                    break :blk fk;
                } else try self.allocator.dupe(u8, key);

                // Check if value is empty (might be array start)
                if (value.len == 0) {
                    if (array_key) |k| self.allocator.free(k);
                    array_key = try self.allocator.dupe(u8, full_key);
                    self.allocator.free(full_key);
                    continue;
                }

                const value_copy = try self.allocator.dupe(u8, value);
                try result.put(full_key, value_copy);
            }
        }

        // Flush remaining array
        if (array_key != null and array_buffer.items.len > 0) {
            const key_copy = try self.allocator.dupe(u8, array_key.?);
            const value_copy = try self.allocator.dupe(u8, array_buffer.items);
            try result.put(key_copy, value_copy);
        }

        return result;
    }

    fn stripQuotes(value: []const u8) []const u8 {
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            return value[1 .. value.len - 1];
        }
        return value;
    }

    pub fn deinitMap(self: *Self, map: *std.StringHashMap([]const u8)) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }
};

/// Lightweight TOML parser for basic configuration files
/// Supports: key-value pairs, [sections], arrays of strings, comments
pub const TomlParser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn parseFile(self: *Self, path: []const u8) !std.StringHashMap([]const u8) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        return try self.parse(content);
    }

    pub fn parse(self: *Self, content: []const u8) !std.StringHashMap([]const u8) {
        var result = std.StringHashMap([]const u8).init(self.allocator);
        errdefer {
            var iter = result.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            result.deinit();
        }

        var lines = std.mem.splitSequence(u8, content, "\n");
        var current_section: ?[]const u8 = null;
        var array_key: ?[]const u8 = null;
        var array_buffer: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(self.allocator);
        defer {
            if (current_section) |s| self.allocator.free(s);
            if (array_key) |k| self.allocator.free(k);
            array_buffer.deinit();
        }

        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");

            if (line.len == 0 or line[0] == '#') continue;

            // Section header
            if (line[0] == '[' and line[line.len - 1] == ']') {
                if (current_section) |s| self.allocator.free(s);
                current_section = try self.allocator.dupe(u8, line[1 .. line.len - 1]);
                continue;
            }

            // Array items in TOML multi-line arrays
            if (array_key != null) {
                const trimmed = std.mem.trim(u8, line, " \t,");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == ']') {
                    if (array_buffer.items.len > 0) {
                        const key_copy = try self.allocator.dupe(u8, array_key.?);
                        const value_copy = try self.allocator.dupe(u8, array_buffer.items);
                        try result.put(key_copy, value_copy);
                        array_buffer.clearRetainingCapacity();
                    }
                    self.allocator.free(array_key.?);
                    array_key = null;
                    continue;
                }
                const item = stripQuotes(std.mem.trim(u8, trimmed, " \t,\"'"));
                if (array_buffer.items.len > 0) {
                    try array_buffer.append(',');
                }
                try array_buffer.appendSlice(item);
                continue;
            }

            // Key-value pair
            if (std.mem.indexOf(u8, line, "=")) |eq_idx| {
                const key = std.mem.trim(u8, line[0..eq_idx], " \t");
                const raw_value = std.mem.trim(u8, line[eq_idx + 1 ..], " \t");

                const full_key = if (current_section) |section| blk: {
                    const fk = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ section, key });
                    break :blk fk;
                } else try self.allocator.dupe(u8, key);

                // Array start
                if (raw_value.len > 0 and raw_value[0] == '[') {
                    if (raw_value[raw_value.len - 1] == ']') {
                        // Single-line array
                        const inner = std.mem.trim(u8, raw_value[1 .. raw_value.len - 1], " \t");
                        const value_copy = try self.allocator.dupe(u8, inner);
                        try result.put(full_key, value_copy);
                    } else {
                        // Multi-line array start
                        array_key = try self.allocator.dupe(u8, full_key);
                        const first_item = stripQuotes(std.mem.trim(u8, raw_value[1..], " \t,\"'"));
                        if (first_item.len > 0) {
                            try array_buffer.appendSlice(first_item);
                        }
                        self.allocator.free(full_key);
                    }
                    continue;
                }

                const value = stripQuotes(raw_value);
                const value_copy = try self.allocator.dupe(u8, value);
                try result.put(full_key, value_copy);
            }
        }

        return result;
    }

    fn stripQuotes(value: []const u8) []const u8 {
        if (value.len >= 2 and ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            return value[1 .. value.len - 1];
        }
        return value;
    }

    pub fn deinitMap(self: *Self, map: *std.StringHashMap([]const u8)) void {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }
};

// ========================================
// Tests
// ========================================

test "YamlParser basic key-value" {
    const allocator = std.testing.allocator;
    var parser = YamlParser.init(allocator);

    const yaml =
        \\name: "zigmodu"
        \\version: "0.2.0"
        \\port: 8080
    ;

    var map = try parser.parse(yaml);
    defer parser.deinitMap(&map);

    try std.testing.expectEqualStrings("zigmodu", map.get("name").?);
    try std.testing.expectEqualStrings("0.2.0", map.get("version").?);
    try std.testing.expectEqualStrings("8080", map.get("port").?);
}

test "YamlParser sections" {
    const allocator = std.testing.allocator;
    var parser = YamlParser.init(allocator);

    const yaml =
        \\[server]
        \\host: "0.0.0.0"
        \\port: 3000
        \\
        \\[database]
        \\url: "postgres://localhost"
    ;

    var map = try parser.parse(yaml);
    defer parser.deinitMap(&map);

    try std.testing.expectEqualStrings("0.0.0.0", map.get("server.host").?);
    try std.testing.expectEqualStrings("3000", map.get("server.port").?);
    try std.testing.expectEqualStrings("postgres://localhost", map.get("database.url").?);
}

test "YamlParser arrays" {
    const allocator = std.testing.allocator;
    var parser = YamlParser.init(allocator);

    const yaml =
        \\features:
        \\  - hot_reload
        \\  - websockets
        \\  - clustering
    ;

    var map = try parser.parse(yaml);
    defer parser.deinitMap(&map);

    try std.testing.expectEqualStrings("hot_reload,websockets,clustering", map.get("features").?);
}

test "TomlParser basic key-value" {
    const allocator = std.testing.allocator;
    var parser = TomlParser.init(allocator);

    const toml =
        \\name = "zigmodu"
        \\version = "0.2.0"
        \\port = 8080
    ;

    var map = try parser.parse(toml);
    defer parser.deinitMap(&map);

    try std.testing.expectEqualStrings("zigmodu", map.get("name").?);
    try std.testing.expectEqualStrings("0.2.0", map.get("version").?);
    try std.testing.expectEqualStrings("8080", map.get("port").?);
}

test "TomlParser sections and arrays" {
    const allocator = std.testing.allocator;
    var parser = TomlParser.init(allocator);

    const toml =
        \\[server]
        \\host = "0.0.0.0"
        \\port = 3000
        \\
        \\features = ["hot_reload", "websockets"]
    ;

    var map = try parser.parse(toml);
    defer parser.deinitMap(&map);

    try std.testing.expectEqualStrings("0.0.0.0", map.get("server.host").?);
    try std.testing.expectEqualStrings("3000", map.get("server.port").?);
    try std.testing.expectEqualStrings("\"hot_reload\", \"websockets\"", map.get("server.features").?);
}
