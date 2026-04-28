const std = @import("std");

/// Configuration loader supporting multiple formats
pub const ConfigLoader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
        };
    }

    /// Load configuration from a JSON file
    pub fn loadJson(self: *Self, path: []const u8) !std.json.Parsed(std.json.Value) {
        const file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);

        const file_len = try std.Io.File.length(file, self.io);
        const content = try self.allocator.alloc(u8, file_len);
        defer self.allocator.free(content);
        _ = try std.Io.File.readPositionalAll(file, self.io, content, 0);

        return try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
    }

    /// Get a string value from config
    pub fn getString(config: std.json.Parsed(std.json.Value), key: []const u8) ?[]const u8 {
        const obj = config.value.object;
        const val = obj.get(key) orelse return null;
        if (val != .string) return null;
        return val.string;
    }

    /// Get an integer value from config
    pub fn getInt(config: std.json.Parsed(std.json.Value), key: []const u8) ?i64 {
        const obj = config.value.object;
        const val = obj.get(key) orelse return null;
        if (val != .integer) return null;
        return val.integer;
    }

    /// Get a boolean value from config
    pub fn getBool(config: std.json.Parsed(std.json.Value), key: []const u8) ?bool {
        const obj = config.value.object;
        const val = obj.get(key) orelse return null;
        if (val != .bool) return null;
        return val.bool;
    }
};

/// Module-specific configuration
pub const ModuleConfig = struct {
    const Self = @This();

    module_name: []const u8,
    config: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *Self) void {
        self.config.deinit();
    }

    pub fn getString(self: *Self, key: []const u8) ?[]const u8 {
        return ConfigLoader.getString(self.config, key);
    }

    pub fn getInt(self: *Self, key: []const u8) ?i64 {
        return ConfigLoader.getInt(self.config, key);
    }

    pub fn getBool(self: *Self, key: []const u8) ?bool {
        return ConfigLoader.getBool(self.config, key);
    }
};

test "ConfigLoader load and get values" {
    const allocator = std.testing.allocator;
    var loader = ConfigLoader.init(allocator, std.testing.io);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(std.testing.io, "test.json", .{});
    try file.writeStreamingAll(std.testing.io, "{\"name\":\"zigmodu\",\"port\":8080,\"debug\":true}");
    file.close(std.testing.io);

    const base_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(base_path);
    const path = try std.fs.path.join(allocator, &.{ base_path, "test.json" });
    defer allocator.free(path);

    const config = try loader.loadJson(path);
    defer config.deinit();

    try std.testing.expectEqualStrings("zigmodu", ConfigLoader.getString(config, "name").?);
    try std.testing.expectEqual(@as(i64, 8080), ConfigLoader.getInt(config, "port").?);
    try std.testing.expectEqual(true, ConfigLoader.getBool(config, "debug").?);
    try std.testing.expect(ConfigLoader.getString(config, "missing") == null);
}

test "ModuleConfig wrapper" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(std.testing.io, "module.json", .{});
    try file.writeStreamingAll(std.testing.io, "{\"version\":\"1.0.0\"}");
    file.close(std.testing.io);

    const base_path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(base_path);
    const path = try std.fs.path.join(allocator, &.{ base_path, "module.json" });
    defer allocator.free(path);

    var loader = ConfigLoader.init(allocator, std.testing.io);
    const parsed = try loader.loadJson(path);

    var module_config = ModuleConfig{
        .module_name = "test-module",
        .config = parsed,
    };
    defer module_config.deinit();

    try std.testing.expectEqualStrings("1.0.0", module_config.getString("version").?);
}
