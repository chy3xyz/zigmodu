const std = @import("std");
const Application = @import("../Application.zig").Application;
const ApplicationModules = @import("Module.zig").ApplicationModules;

/// Module Hot-Reloading System
/// Watches module files for changes and reloads them dynamically
/// Note: Due to Zig's compile-time nature, true hot-reloading is limited
/// This system provides file watching and triggers recompilation
pub const HotReloader = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    watch_paths: std.ArrayList([]const u8),
    is_watching: bool,
    watch_thread: ?std.Thread,
    file_hashes: std.StringHashMap(u64),
    on_change_cb: ?*const fn ([]const u8) void,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .watch_paths = std.ArrayList([]const u8).init(allocator),
            .is_watching = false,
            .watch_thread = null,
            .file_hashes = std.StringHashMap(u64).init(allocator),
            .on_change_cb = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stopWatching();

        for (self.watch_paths.items) |path| {
            self.allocator.free(path);
        }
        self.watch_paths.deinit();

        var iter = self.file_hashes.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.file_hashes.deinit();
    }

    /// Add a path to watch
    pub fn watchPath(self: *Self, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.watch_paths.append(path_copy);

        // Initialize file hashes
        try self.scanAndHashPath(path);

        std.log.info("[HotReloader] Now watching: {s}", .{path});
    }

    /// Set callback for file changes
    pub fn onChange(self: *Self, callback: *const fn ([]const u8) void) void {
        self.on_change_cb = callback;
    }

    /// Start watching for changes
    pub fn startWatching(self: *Self) !void {
        if (self.is_watching) return;

        self.is_watching = true;

        self.watch_thread = try std.Thread.spawn(.{}, watchLoop, .{self});

        std.log.info("[HotReloader] Started watching for changes", .{});
    }

    pub fn stopWatching(self: *Self) void {
        self.is_watching = false;
        if (self.watch_thread) |thread| {
            thread.join();
            self.watch_thread = null;
        }
    }

    fn watchLoop(self: *Self) void {
        while (self.is_watching) {
            self.checkForChanges() catch |err| {
                std.log.err("[HotReloader] Error checking for changes: {}", .{err});
            };

            // Check every 1 second
            std.time.sleep(1 * std.time.ns_per_s);
        }
    }

    fn checkForChanges(self: *Self) !void {
        for (self.watch_paths.items) |path| {
            try self.checkPathForChanges(path);
        }
    }

    fn checkPathForChanges(self: *Self, path: []const u8) !void {
        var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const ext = std.fs.path.extension(entry.name);
                if (std.mem.eql(u8, ext, ".zig")) {
                    const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                    defer self.allocator.free(full_path);

                    const current_hash = try self.hashFile(full_path);

                    const entry_result = try self.file_hashes.getOrPut(full_path);
                    if (entry_result.found_existing) {
                        if (entry_result.value_ptr.* != current_hash) {
                            // File changed!
                            entry_result.value_ptr.* = current_hash;
                            self.handleFileChange(full_path);
                        }
                    } else {
                        // New file
                        entry_result.value_ptr.* = current_hash;
                    }
                }
            } else if (entry.kind == .directory) {
                // Recursively check subdirectories
                const sub_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                defer self.allocator.free(sub_path);
                try self.checkPathForChanges(sub_path);
            }
        }
    }

    fn scanAndHashPath(self: *Self, path: []const u8) !void {
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
            std.log.warn("[HotReloader] Could not open directory: {s} - {}", .{ path, err });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                const ext = std.fs.path.extension(entry.name);
                if (std.mem.eql(u8, ext, ".zig")) {
                    const full_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
                    defer self.allocator.free(full_path);

                    const hash = try self.hashFile(full_path);
                    const path_copy = try self.allocator.dupe(u8, full_path);

                    try self.file_hashes.put(path_copy, hash);
                }
            }
        }
    }

    fn hashFile(self: *Self, path: []const u8) !u64 {
        _ = self;

        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const stat = try file.stat();
        const modified_time = stat.mtime;
        const size = stat.size;

        // Simple hash based on modification time and size
        var hasher = std.hash.Crc32.init();
        hasher.update(std.mem.asBytes(&modified_time));
        hasher.update(std.mem.asBytes(&size));

        return hasher.final();
    }

    fn handleFileChange(self: *Self, path: []const u8) void {
        std.log.info("[HotReloader] File changed: {s}", .{path});

        // Call user callback if set
        if (self.on_change_cb) |callback| {
            callback(path);
        }

        // In a real implementation with shared libraries:
        // 1. Unload the old module
        // 2. Recompile the module
        // 3. Load the new module
        // 4. Migrate state

        // For now, we just log the change
        std.log.info("[HotReloader] Module would be reloaded: {s}", .{path});
    }

    /// Trigger manual reload of a module
    pub fn reloadModule(self: *Self, module_path: []const u8) !void {
        _ = self;
        std.log.info("[HotReloader] Manual reload requested for: {s}", .{module_path});

        // In production:
        // - Stop the module
        // - Recompile if needed
        // - Reload the shared library
        // - Restart with preserved state
    }

    /// Get list of watched files
    pub fn getWatchedFiles(self: *Self) []const []const u8 {
        return self.watch_paths.items;
    }

    /// Get number of watched files
    pub fn getWatchedFileCount(self: *Self) usize {
        return self.file_hashes.count();
    }
};

/// Reload strategy for state preservation
pub const ReloadStrategy = enum {
    /// Restart module with fresh state
    restart,
    /// Preserve module state across reload
    preserve_state,
    /// Gradual migration with dual-running
    gradual_migration,
};

/// Module state snapshot for preservation during reload
pub fn ModuleSnapshot(comptime T: type) type {
    return struct {
        const Self = @This();

        data: T,
        version: u32,
        timestamp: i64,

        pub fn init(data: T) Self {
            return .{
                .data = data,
                .version = 1,
                .timestamp = std.time.timestamp(),
            };
        }

        pub fn incrementVersion(self: *Self) void {
            self.version += 1;
            self.timestamp = std.time.timestamp();
        }
    };
}
