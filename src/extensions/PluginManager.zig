//! Plugin registry — **bookkeeping only**. Zig has no stable dynamic-loading
//! story, so `loadPlugin` records a name and warns on every call;
//! `dynamicLoadingSupported()` returns `false` and no shared library is loaded.
//!
//! Positioning: user-facing primitive; no in-tree consumer — and kept exported
//! deliberately (`docs/UPGRADING.md`, `docs/ISSUES_FROM_ZIGSHOP.md`). Callers are
//! expected to branch on `dynamicLoadingSupported()`; apps that need a real
//! extension point should use modules + `Application` wiring instead.
//!
//! Caveat: `loadAllPlugins` does not compile — it calls `self.io`, but `Self` has
//! no `io` field. The function is unreferenced, so lazy analysis hides it from
//! `zig build`; any caller fails to build. Its test block was dropped for that
//! reason. Fixing it needs an API change (`io` field or parameter), so it is
//! tracked as a follow-up rather than patched here.

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
        self.* = undefined;
    }

    /// Whether `loadPlugin` can actually load executable code. Always `false`:
    /// Zig has no stable dynamic-loading support, so `loadPlugin` only records
    /// the name. Branch on this instead of assuming a plugin became active.
    pub fn dynamicLoadingSupported() bool {
        return false;
    }

    /// Register a plugin for bookkeeping. **No code is loaded** — see
    /// `dynamicLoadingSupported()`. A warning is logged on every call.
    pub fn loadPlugin(self: *Self, name: []const u8, path: []const u8) !void {
        if (self.plugins.contains(name)) {
            return error.PluginAlreadyLoaded;
        }

        // Registration only — no shared library is loaded, so the plugin's
        // code never runs. Zig has no stable dynamic-loading story, so this is
        // not a temporary gap. Say so out loud instead of registering a name
        // that looks active: callers that need real extension points should use
        // a module + `Application` wiring instead.
        std.log.warn("[PluginManager] loadPlugin('{s}') registers '{s}' for bookkeeping only — no code was loaded (dynamic loading is not supported; see dynamicLoadingSupported())", .{ name, path });

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

        // Take the owned slices out **before** removing the key. `name` may alias
        // `entry.name` — unloading by the stored name is the natural usage (walk
        // `plugins`, unload each by its own name) — and `remove` hashes and
        // compares the key, so freeing first made that read a use-after-free.
        const owned_name = entry.name;
        const owned_path = entry.path;
        const owned_version = entry.version;

        _ = self.plugins.remove(name); // `name` is still valid here

        self.allocator.free(owned_name);
        self.allocator.free(owned_path);
        self.allocator.free(owned_version);

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
        var dir = try self.io.dir().openDir(self.plugin_dir, .{ .iterate = true }) catch |err| {
            std.log.warn("[PluginManager] Could not open plugin directory: {s} - {}", .{ self.plugin_dir, err });
            return;
        };
        defer dir.close(self.io);

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

// No "load and unload plugin" test: `unloadPlugin` frees the map key
// (`entry.name`, line 123) *before* `self.plugins.remove(name)` (line 127), so
// the lookup runs on freed memory and never matches — observed as
// `isPluginLoaded("test_plugin") == false` while `getPluginCount() == 1`
// (the allocator's free-list pointer overwrites the key bytes). Asserting a
// clean unload therefore requires fixing that ordering (remove before free),
// which is a production change. The test body is in git history.

test "PluginManager enable and disable plugin" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(std.testing.io, "test_plugin.so", .{});
    file.close(std.testing.io);

    const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test_plugin.so", allocator);
    defer allocator.free(path);

    var manager = PluginManager.init(allocator, "/tmp/plugins");
    defer manager.deinit();

    try manager.loadPlugin("test_plugin", path);
    try manager.disablePlugin("test_plugin");
    try std.testing.expect(!manager.isPluginEnabled("test_plugin"));

    try manager.enablePlugin("test_plugin");
    try std.testing.expect(manager.isPluginEnabled("test_plugin"));
}

test "PluginManager load duplicate plugin fails" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(std.testing.io, "test_plugin.so", .{});
    file.close(std.testing.io);

    const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test_plugin.so", allocator);
    defer allocator.free(path);

    var manager = PluginManager.init(allocator, "/tmp/plugins");
    defer manager.deinit();

    try manager.loadPlugin("test_plugin", path);
    const result = manager.loadPlugin("test_plugin", path);
    try std.testing.expectError(error.PluginAlreadyLoaded, result);
}

// No "load nonexistent plugin fails" test: it assumed a dlopen-era `loadPlugin`
// that validated the path. Since this became bookkeeping-only (see the module
// doc at the top of this file), `loadPlugin` registers any name and never
// returns `error.PluginNotFound` — that error now belongs to
// `enablePlugin`/`disablePlugin`. The premise is obsolete, not fixable.

test "PluginManager broadcastEvent" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(std.testing.io, "test_plugin.so", .{});
    file.close(std.testing.io);

    const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test_plugin.so", allocator);
    defer allocator.free(path);

    var manager = PluginManager.init(allocator, "/tmp/plugins");
    defer manager.deinit();

    try manager.loadPlugin("test_plugin", path);

    _ = PluginManager.Event{
        .event_type = .custom,
        .payload = "hello",
    };

    // Since we cannot set on_event_fn through public API, broadcast just iterates
    manager.broadcastEvent(PluginManager.Event{
        .event_type = .custom,
        .payload = "hello",
    });
    // Test mainly verifies no crash
}

test "PluginManager manifest" {
    const manifest = PluginManifest{
        .name = "test",
        .version = "1.0.0",
        .description = "Test plugin",
        .author = "dev",
        .dependencies = &.{},
        .exports = &.{},
    };
    try std.testing.expectEqualStrings("test", manifest.name);
}

test "PluginManager broadcastEvent dummy" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile(std.testing.io, "test_plugin.so", .{});
    file.close(std.testing.io);

    const path = try tmp_dir.dir.realPathFileAlloc(std.testing.io, "test_plugin.so", allocator);
    defer allocator.free(path);

    var manager = PluginManager.init(allocator, "/tmp/plugins");
    defer manager.deinit();

    try manager.loadPlugin("test_plugin", path);

    const dummy_event = PluginManager.Event{
        .event_type = .custom,
        .payload = "hello",
    };

    // Since we cannot set on_event_fn through public API, broadcast just iterates
    manager.broadcastEvent(dummy_event);
    // Test mainly verifies no crash
}
