const std = @import("std");

/// Configuration management supporting multiple formats
/// Currently supports JSON and will support TOML
pub const ConfigManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    values: std.StringHashMap(ConfigValue),

    pub const ConfigValue = union(enum) {
        string: []const u8,
        integer: i64,
        float: f64,
        boolean: bool,
        array: std.ArrayList(ConfigValue),
        object: std.StringHashMap(ConfigValue),

        pub fn deinit(self: *ConfigValue, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .string => |s| allocator.free(s),
                .array => |*arr| {
                    for (arr.items) |*item| {
                        item.deinit(allocator);
                    }
                    arr.deinit(allocator);
                },
                .object => |*obj| {
                    var iter = obj.iterator();
                    while (iter.next()) |entry| {
                        entry.value_ptr.deinit(allocator);
                        allocator.free(entry.key_ptr.*);
                    }
                    obj.deinit();
                },
                else => {},
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .values = std.StringHashMap(ConfigValue).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.values.deinit();
    }

    /// Load configuration from JSON file
    pub fn loadJson(self: *Self, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        var parser = std.json.Parser.init(self.allocator, .alloc_if_needed);
        defer parser.deinit();

        var tree = try parser.parse(content);
        defer tree.deinit();

        try self.parseJsonValue(&tree.root, "");
    }

    fn parseJsonValue(self: *Self, value: *std.json.Value, prefix: []const u8) !void {
        switch (value.*) {
            .Object => |obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    const key = if (prefix.len == 0)
                        entry.key_ptr.*
                    else
                        try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* });

                    if (prefix.len > 0) {
                        defer self.allocator.free(key);
                    }

                    try self.parseJsonValue(entry.value_ptr, key);
                }
            },
            .String => |s| {
                const key_copy = try self.allocator.dupe(u8, prefix);
                const value_copy = try self.allocator.dupe(u8, s);
                try self.values.put(key_copy, .{ .string = value_copy });
            },
            .Integer => |i| {
                const key_copy = try self.allocator.dupe(u8, prefix);
                try self.values.put(key_copy, .{ .integer = i });
            },
            .Float => |f| {
                const key_copy = try self.allocator.dupe(u8, prefix);
                try self.values.put(key_copy, .{ .float = f });
            },
            .Bool => |b| {
                const key_copy = try self.allocator.dupe(u8, prefix);
                try self.values.put(key_copy, .{ .boolean = b });
            },
            else => {},
        }
    }

    /// Get string value
    pub fn getString(self: *Self, key: []const u8) ?[]const u8 {
        const value = self.values.get(key) orelse return null;
        return switch (value) {
            .string => |s| s,
            else => null,
        };
    }

    /// Get integer value
    pub fn getInt(self: *Self, key: []const u8) ?i64 {
        const value = self.values.get(key) orelse return null;
        return switch (value) {
            .integer => |i| i,
            else => null,
        };
    }

    /// Get float value
    pub fn getFloat(self: *Self, key: []const u8) ?f64 {
        const value = self.values.get(key) orelse return null;
        return switch (value) {
            .float => |f| f,
            .integer => |i| @as(f64, @floatFromInt(i)),
            else => null,
        };
    }

    /// Get boolean value
    pub fn getBool(self: *Self, key: []const u8) ?bool {
        const value = self.values.get(key) orelse return null;
        return switch (value) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// Get value with default
    pub fn getStringOrDefault(self: *Self, key: []const u8, default: []const u8) []const u8 {
        return self.getString(key) orelse default;
    }

    pub fn getIntOrDefault(self: *Self, key: []const u8, default: i64) i64 {
        return self.getInt(key) orelse default;
    }

    /// Set a configuration value
    pub fn set(self: *Self, key: []const u8, value: ConfigValue) !void {
        // Remove old value if exists
        if (self.values.fetchRemove(key)) |old| {
            var old_value = old.value;
            old_value.deinit(self.allocator);
            self.allocator.free(old.key);
        }

        const key_copy = try self.allocator.dupe(u8, key);
        // Duplicate string value so ConfigManager owns the memory
        var owned_value = value;
        switch (owned_value) {
            .string => |s| owned_value.string = try self.allocator.dupe(u8, s),
            else => {},
        }
        try self.values.put(key_copy, owned_value);
    }

    /// Check if key exists
    pub fn has(self: *Self, key: []const u8) bool {
        return self.values.contains(key);
    }

    /// Dump configuration for debugging
    pub fn dump(self: *Self, writer: anytype) !void {
        try writer.writeAll("Configuration:\n");
        var iter = self.values.iterator();
        while (iter.next()) |entry| {
            try writer.print("  {s} = ", .{entry.key_ptr.*});
            switch (entry.value_ptr.*) {
                .string => |s| try writer.print("\"{s}\"\n", .{s}),
                .integer => |i| try writer.print("{d}\n", .{i}),
                .float => |f| try writer.print("{d}\n", .{f}),
                .boolean => |b| try writer.print("{s}\n", .{if (b) "true" else "false"}),
                else => try writer.writeAll("<complex>\n"),
            }
        }
    }
};

/// Module-specific configuration wrapper
pub const ModuleConfig = struct {
    manager: *ConfigManager,
    prefix: []const u8,

    pub fn init(manager: *ConfigManager, module_name: []const u8) ModuleConfig {
        return .{
            .manager = manager,
            .prefix = module_name,
        };
    }

    fn makeKey(self: ModuleConfig, subkey: []const u8, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}.{s}", .{ self.prefix, subkey });
    }

    pub fn getString(self: ModuleConfig, key: []const u8) ?[]const u8 {
        // SAFETY: Buffer is immediately filled by makeKey() before use
        var buf: [256]u8 = undefined;
        const full_key = self.makeKey(key, &buf) catch return null;
        return self.manager.getString(full_key);
    }

    pub fn getInt(self: ModuleConfig, key: []const u8) ?i64 {
        // SAFETY: Buffer is immediately filled by makeKey() before use
        var buf: [256]u8 = undefined;
        const full_key = self.makeKey(key, &buf) catch return null;
        return self.manager.getInt(full_key);
    }

    pub fn getBool(self: ModuleConfig, key: []const u8) ?bool {
        // SAFETY: Buffer is immediately filled by makeKey() before use
        var buf: [256]u8 = undefined;
        const full_key = self.makeKey(key, &buf) catch return null;
        return self.manager.getBool(full_key);
    }
};

test "ConfigManager basic operations" {
    const allocator = std.testing.allocator;

    var config = ConfigManager.init(allocator);
    defer config.deinit();

    // Set values
    try config.set("app.name", .{ .string = "MyApp" });
    try config.set("app.port", .{ .integer = 8080 });
    try config.set("app.debug", .{ .boolean = true });

    // Get values
    try std.testing.expectEqualStrings("MyApp", config.getString("app.name").?);
    try std.testing.expectEqual(@as(i64, 8080), config.getInt("app.port").?);
    try std.testing.expectEqual(true, config.getBool("app.debug").?);

    // Test defaults
    try std.testing.expectEqualStrings("default", config.getStringOrDefault("missing", "default"));
    try std.testing.expectEqual(@as(i64, 42), config.getIntOrDefault("missing", 42));
}

test "ModuleConfig" {
    const allocator = std.testing.allocator;

    var config = ConfigManager.init(allocator);
    defer config.deinit();

    // Set module-specific values
    try config.set("order.timeout", .{ .integer = 30 });
    try config.set("order.retries", .{ .integer = 3 });
    try config.set("payment.timeout", .{ .integer = 60 });

    const order_config = ModuleConfig.init(&config, "order");

    try std.testing.expectEqual(@as(i64, 30), order_config.getInt("timeout").?);
    try std.testing.expectEqual(@as(i64, 3), order_config.getInt("retries").?);
    try std.testing.expect(order_config.getInt("payment") == null);
}
