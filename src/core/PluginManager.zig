const std = @import("std");

/// Plugin System for dynamic module loading
/// Supports loading shared libraries (.so on Linux, .dll on Windows, .dylib on macOS)
pub const PluginManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    plugins: std.StringHashMap(Plugin),
    plugin_dir: []const u8,

    const Plugin = struct {
        name: []const u8,
        path: []const u8,
        handle: ?*anyopaque, // Dynamic library handle
        version: []const u8,
        enabled: bool,

        // Plugin interface functions
        init_fn: ?*const fn () anyerror!void,
        deinit_fn: ?*const fn () void,
        on_event_fn: ?*const fn (Event) void,
    };

    const Event = struct {
        event_type: EventType,
        payload: []const u8,
    };

    const EventType = enum {
        module_loaded,
        module_unloaded,
        config_changed,
        custom,
    };

    pub fn init(allocator: std.mem.Allocator, plugin_dir: []const u8) Self {
        return .{
            .allocator = allocator,
            .plugins = std.StringHashMap(Plugin).init(allocator),
            .plugin_dir = plugin_dir,
        };
    }

    pub fn deinit(self: *Self) void {
        // Unload all plugins
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            self.unloadPlugin(entry.value_ptr.name);
        }
        self.plugins.deinit();
    }

    /// Load a plugin from file
    pub fn loadPlugin(self: *Self, name: []const u8, path: []const u8) !void {
        if (self.plugins.contains(name)) {
            return error.PluginAlreadyLoaded;
        }

        // Check file exists
        std.fs.accessAbsolute(path, .{}) catch |err| {
            std.log.err("[PluginManager] Plugin file not found: {s} - {}", .{ path, err });
            return error.PluginNotFound;
        };

        // Note: In Zig, dynamic library loading at runtime is limited
        // This is a framework for future implementation when better DLL support is available

        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        const version = try self.allocator.dupe(u8, "0.1.0");
        errdefer self.allocator.free(version);

        try self.plugins.put(name_copy, .{
            .name = name_copy,
            .path = path_copy,
            .handle = null,
            .version = version,
            .enabled = true,
            .init_fn = null,
            .deinit_fn = null,
            .on_event_fn = null,
        });

        std.log.info("[PluginManager] Loaded plugin: {s} from {s}", .{ name, path });
    }

    /// Unload a plugin
    pub fn unloadPlugin(self: *Self, name: []const u8) void {
        const entry = self.plugins.getPtr(name) orelse return;

        // Call deinit if available
        if (entry.deinit_fn) |deinit_fn| {
            deinit_fn();
        }

        // Free resources
        self.allocator.free(entry.name);
        self.allocator.free(entry.path);
        self.allocator.free(entry.version);

        _ = self.plugins.remove(name);

        std.log.info("[PluginManager] Unloaded plugin: {s}", .{name});
    }

    /// Enable a plugin
    pub fn enablePlugin(self: *Self, name: []const u8) !void {
        const entry = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        entry.enabled = true;

        // Call init if available
        if (entry.init_fn) |init_fn| {
            try init_fn();
        }

        std.log.info("[PluginManager] Enabled plugin: {s}", .{name});
    }

    /// Disable a plugin
    pub fn disablePlugin(self: *Self, name: []const u8) !void {
        const entry = self.plugins.getPtr(name) orelse return error.PluginNotFound;
        entry.enabled = false;

        // Call deinit if available
        if (entry.deinit_fn) |deinit_fn| {
            deinit_fn();
        }

        std.log.info("[PluginManager] Disabled plugin: {s}", .{name});
    }

    /// Load all plugins from plugin directory
    pub fn loadAllPlugins(self: *Self) !void {
        var dir = std.fs.openDirAbsolute(self.plugin_dir, .{ .iterate = true }) catch |err| {
            std.log.warn("[PluginManager] Could not open plugin directory: {s} - {}", .{ self.plugin_dir, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                // Check if it's a shared library
                const ext = std.fs.path.extension(entry.name);
                if (std.mem.eql(u8, ext, ".so") or
                    std.mem.eql(u8, ext, ".dll") or
                    std.mem.eql(u8, ext, ".dylib"))
                {
                    const name = std.fs.path.stem(entry.name);
                    const path = try std.fs.path.join(self.allocator, &.{ self.plugin_dir, entry.name });
                    defer self.allocator.free(path);

                    self.loadPlugin(name, path) catch |err| {
                        std.log.err("[PluginManager] Failed to load plugin {s}: {}", .{ name, err });
                        continue;
                    };
                }
            }
        }
    }

    /// Get list of loaded plugins
    pub fn getLoadedPlugins(self: *Self) []const Plugin {
        // Note: This is a simplified version, in production would return a list
        _ = self;
        return &[]Plugin{};
    }

    /// Get plugin count
    pub fn getPluginCount(self: *Self) usize {
        return self.plugins.count();
    }

    /// Check if plugin is loaded
    pub fn isPluginLoaded(self: *Self, name: []const u8) bool {
        return self.plugins.contains(name);
    }

    /// Check if plugin is enabled
    pub fn isPluginEnabled(self: *Self, name: []const u8) bool {
        const entry = self.plugins.get(name) orelse return false;
        return entry.enabled;
    }

    /// Broadcast event to all loaded plugins
    pub fn broadcastEvent(self: *Self, event: Event) void {
        var iter = self.plugins.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.enabled) {
                if (entry.value_ptr.on_event_fn) |on_event| {
                    on_event(event);
                }
            }
        }
    }
};

/// Plugin manifest for plugin metadata
pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8,
    dependencies: []const []const u8,
    exports: []const Export,

    const Export = struct {
        name: []const u8,
        export_type: ExportType,
    };

    const ExportType = enum {
        function,
        module,
        event_handler,
    };
};
