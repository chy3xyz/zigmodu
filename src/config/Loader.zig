const std = @import("std");

/// Configuration loader supporting multiple formats
pub const ConfigLoader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    /// Load configuration from a JSON file
    pub fn loadJson(self: *Self, path: []const u8) !std.json.Parsed(std.json.Value) {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024); // Max 1MB
        defer self.allocator.free(content);

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
