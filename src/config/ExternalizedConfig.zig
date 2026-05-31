const std = @import("std");
const ZigModuError = @import("../core/Error.zig").ZigModuError;

/// Externalized configuration[...]
/// [...]
/// [...]
pub const ExternalizedConfig = struct {
    const Self = @This();

    /// Property loader: receives allocator, returns key-value map.
    pub const LoaderFn = *const fn (std.mem.Allocator) anyerror!std.StringHashMap([]const u8);

    allocator: std.mem.Allocator,
    io: std.Io,
    sources: std.ArrayList(ConfigSource),
    properties: std.StringHashMap([]const u8),
    listeners: std.ArrayList(*const fn ([]const u8, []const u8) void),
    file_watchers: std.ArrayList(FileWatcher),
    watch_thread: ?std.Thread = null,
    should_stop: std.atomic.Value(bool),
    watch_interval_ms: u64,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .sources = std.ArrayList(ConfigSource).empty,
            .properties = std.StringHashMap([]const u8).init(allocator),
            .listeners = std.ArrayList(*const fn ([]const u8, []const u8) void).empty,
            .file_watchers = std.ArrayList(FileWatcher).empty,
            .watch_thread = null,
            .should_stop = std.atomic.Value(bool).init(false),
            .watch_interval_ms = 1000,
        };
    }

    pub const ConfigSource = struct {
        name: []const u8,
        priority: u8, // Priority, lower number = higher priority
        loader: *const fn (allocator: std.mem.Allocator) anyerror!std.StringHashMap([]const u8),
    };

    /// [...] - [...]
    pub const FileWatcher = struct {
        filepath: []const u8,
        last_modified: i128,
        loader: *const fn (std.mem.Allocator) anyerror!std.StringHashMap([]const u8),
    };

    pub const WatchConfig = struct {
        interval_ms: u64 = 1000, // Default: check every 1 second
    };

    pub fn deinit(self: *Self) void {
        // [...]
        self.stopWatching();

        // [...]
        var prop_iter = self.properties.iterator();
        while (prop_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.properties.deinit();
        self.sources.deinit(self.allocator);
        self.listeners.deinit(self.allocator);

        // [...]
        for (self.file_watchers.items) |*watcher| {
            self.allocator.free(watcher.filepath);
        }
        self.file_watchers.deinit(self.allocator);
        self.* = undefined;
    }

    /// [...]
    pub fn addSource(self: *Self, name: []const u8, priority: u8, loader: LoaderFn) !void {
        try self.sources.append(self.allocator, .{
            .name = name,
            .priority = priority,
            .loader = loader,
        });

        // [...]
        std.sort.insertion(ConfigSource, self.sources.items, {}, compareSourcePriority);
    }

    /// Convenience: load from environment variables with a prefix.
    pub fn addEnvSource(self: *Self, prefix: []const u8) !void {
        const S = struct {
            var stored_prefix: []const u8 = undefined;
            fn loader(alloc: std.mem.Allocator) anyerror!std.StringHashMap([]const u8) {
                var map = std.StringHashMap([]const u8).init(alloc);
                var environ = std.process.Environ.empty;
                var env_map = try environ.createMap(alloc);
                defer env_map.deinit();
                var env_iter = env_map.iterator();
                while (env_iter.next()) |entry| {
                    if (std.mem.startsWith(u8, entry.key_ptr.*, stored_prefix)) {
                        const key = try alloc.dupe(u8, entry.key_ptr.*[stored_prefix.len..]);
                        const val = try alloc.dupe(u8, entry.value_ptr.*);
                        try map.put(key, val);
                    }
                }
                return map;
            }
        };
        S.stored_prefix = prefix;
        try self.addSource("env", 100, S.loader);
    }

    fn compareSourcePriority(_: void, a: ConfigSource, b: ConfigSource) bool {
        return a.priority < b.priority;
    }

    /// [...]
    pub fn load(self: *Self) !void {
        std.log.info("Loading configuration from {d} sources", .{self.sources.items.len});

        for (self.sources.items) |source| {
            std.log.info("Loading from source: {s} (priority: {d})", .{ source.name, source.priority });

            var source_props = try source.loader(self.allocator);
            defer {
                var iter = source_props.iterator();
                while (iter.next()) |entry| {
                    self.allocator.free(entry.key_ptr.*);
                    self.allocator.free(entry.value_ptr.*);
                }
                source_props.deinit();
            }

            var iter = source_props.iterator();
            while (iter.next()) |entry| {
                const key = try self.allocator.dupe(u8, entry.key_ptr.*);
                const value = try self.allocator.dupe(u8, entry.value_ptr.*);

                // [...]Decide overwrite based on priority
                if (self.properties.get(key)) |old_value| {
                    self.allocator.free(old_value);
                }

                try self.properties.put(key, value);
            }
        }

        std.log.info("Loaded {d} configuration properties", .{self.properties.count()});
    }

    /// [...]
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return self.properties.get(key);
    }

    /// [...]
    pub fn getOrDefault(self: *Self, key: []const u8, default_value: []const u8) []const u8 {
        return self.properties.get(key) orelse default_value;
    }

    /// [...]
    pub fn getInt(self: *Self, key: []const u8) ?i64 {
        const value = self.properties.get(key) orelse return null;
        return std.fmt.parseInt(i64, value, 10) catch |err| {
            std.log.warn("Failed to parse integer config '{s}' with value '{s}': {s}", .{ key, value, @errorName(err) });
            return null;
        };
    }

    /// [...]Error[...]
    pub fn getIntOrError(self: *Self, key: []const u8) !?i64 {
        const value = self.properties.get(key) orelse return null;
        return try std.fmt.parseInt(i64, value, 10);
    }

    /// [...]
    pub fn getBool(self: *Self, key: []const u8) ?bool {
        const value = self.properties.get(key) orelse return null;
        if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "yes")) {
            return true;
        }
        if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "no")) {
            return false;
        }
        return null;
    }

    /// Validation[...] = [...]
    /// [...] Application.start() [...]call[...]ErrorInfo[...]
    pub fn validateRequired(self: *Self, required_keys: []const []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
        var missing = std.ArrayList([]const u8).empty;
        for (required_keys) |key| {
            if (self.properties.get(key) == null) {
                try missing.append(allocator, key);
            }
        }
        return missing.toOwnedSlice(allocator);
    }

    /// [...]
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);

        if (self.properties.fetchRemove(key_copy)) |old_kv| {
            self.allocator.free(old_kv.key);
            self.allocator.free(old_kv.value);
        }

        try self.properties.put(key_copy, value_copy);

        // [...]
        for (self.listeners.items) |listener| {
            listener(key, value);
        }
    }

    /// [...]
    pub fn addListener(self: *Self, listener: *const fn ([]const u8, []const u8) void) !void {
        try self.listeners.append(self.allocator, listener);
    }

    /// [...]for[...]
    pub fn watchFile(self: *Self, filepath: []const u8, loader: *const fn (std.mem.Allocator) anyerror!std.StringHashMap([]const u8)) !void {
        const path_copy = try self.allocator.dupe(u8, filepath);
        errdefer self.allocator.free(path_copy);

        // Get file initial modification time
        const stat = std.Io.Dir.cwd().statFile(self.io, filepath, .{}) catch |err| {
            std.log.warn("Cannot get file status {s}: {}", .{ filepath, err });
            // [...]
            const watcher = FileWatcher{
                .filepath = path_copy,
                .last_modified = 0,
                .loader = loader,
            };
            try self.file_watchers.append(self.allocator, watcher);
            return;
        };

        const watcher = FileWatcher{
            .filepath = path_copy,
            .last_modified = @as(i128, @intCast(stat.mtime.nanoseconds)),
            .loader = loader,
        };
        try self.file_watchers.append(self.allocator, watcher);

        std.log.info("Start watching config file: {s}", .{filepath});
    }

    /// [...]
    pub fn watch(self: *Self, config: WatchConfig) !void {
        if (self.watch_thread != null) {
            std.log.warn("Config watcher already running", .{});
            return;
        }

        self.watch_interval_ms = config.interval_ms;
        self.should_stop.store(false, .release);

        // [...]
        self.watch_thread = try std.Thread.spawn(.{}, watchThreadFn, .{self});

        std.log.info("Config hot-reload started (interval: {d}ms)", .{config.interval_ms});
    }

    /// [...]
    pub fn stopWatching(self: *Self) void {
        if (self.watch_thread) |thread| {
            self.should_stop.store(true, .release);
            thread.join();
            self.watch_thread = null;
            std.log.info("Config watcher stopped", .{});
        }
    }

    /// [...]
    fn watchThreadFn(self: *Self) void {
        while (!self.should_stop.load(.acquire)) {
            self.checkFileChanges() catch |err| {
                std.log.err("Error checking file changes: {}", .{err});
            };

            // Use shorter sleep intervals for stop signal responsiveness
            var remaining_ms = self.watch_interval_ms;
            while (remaining_ms > 0 and !self.should_stop.load(.acquire)) {
                const sleep_ms = @min(remaining_ms, 100);
                // std.Thread.sleep(@as(u64, sleep_ms) * std.time.ns_per_ms);
                remaining_ms -= sleep_ms;
            }
        }
    }

    /// Check file changes and reload
    fn checkFileChanges(self: *Self) !void {
        for (self.file_watchers.items) |*watcher| {
            const stat = std.Io.Dir.cwd().statFile(self.io, watcher.filepath, .{}) catch |err| {
                // File may not exist or be inaccessible[...]
                if (err == error.FileNotFound) {
                    std.log.warn("Config file not found: {s}", .{watcher.filepath});
                    continue;
                }
                return err;
            };

            if (@as(i128, @intCast(stat.mtime.nanoseconds)) > watcher.last_modified) {
                std.log.info("Config file change detected: {s}", .{watcher.filepath});
                watcher.last_modified = @as(i128, @intCast(stat.mtime.nanoseconds));

                // [...]
                try self.reloadFromWatcher(watcher.*);
            }
        }
    }

    /// Reload config from listener
    fn reloadFromWatcher(self: *Self, watcher: FileWatcher) !void {
        var new_props = try watcher.loader(self.allocator);
        defer {
            var iter = new_props.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            new_props.deinit();
        }

        // Record which keys changed
        var changed_keys = std.ArrayList([]const u8).empty;
        defer {
            for (changed_keys.items) |key| {
                self.allocator.free(key);
            }
            changed_keys.deinit(self.allocator);
        }

        // [...]
        var iter = new_props.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const new_value = entry.value_ptr.*;

            if (self.properties.get(key)) |old_value| {
                if (!std.mem.eql(u8, old_value, new_value)) {
                    // [...]
                    const key_copy = try self.allocator.dupe(u8, key);
                    try changed_keys.append(self.allocator, key_copy);

                    // [...]
                    self.allocator.free(old_value);
                    const new_value_copy = try self.allocator.dupe(u8, new_value);
                    try self.properties.put(key, new_value_copy);

                    std.log.info("Config updated: {s} = {s}", .{ key, new_value });
                }
            } else {
                // [...]
                const key_copy = try self.allocator.dupe(u8, key);
                try changed_keys.append(self.allocator, key_copy);

                const key_copy2 = try self.allocator.dupe(u8, key);
                const value_copy = try self.allocator.dupe(u8, new_value);
                try self.properties.put(key_copy2, value_copy);

                std.log.info("Config added: {s} = {s}", .{ key, new_value });
            }
        }

        // [...]
        for (changed_keys.items) |key| {
            if (self.properties.get(key)) |value| {
                for (self.listeners.items) |listener| {
                    listener(key, value);
                }
            }
        }

        std.log.info("Config file reload done, {d} changes", .{changed_keys.items.len});
    }

    /// Check if[...]
    pub fn isWatching(self: *Self) bool {
        return self.watch_thread != null;
    }

    /// [...]
    pub fn getWatcherCount(self: *Self) usize {
        return self.file_watchers.items.len;
    }

    /// [...]
    pub fn refresh(self: *Self) !void {
        std.log.info("Manual config refresh...", .{});

        // [...]
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.properties.clearRetainingCapacity();

        // [...]
        try self.load();
        std.log.info("Config refresh done", .{});
    }

    /// [...]
    pub fn printAll(self: *Self) void {
        std.log.info("=== Configuration Properties ===", .{});
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            std.log.info("  {s} = {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
};

/// [...]
pub fn envVarLoader(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var props = std.StringHashMap([]const u8).init(allocator);

    // Read env vars with specific prefix
    const prefix = "ZIGMODU_";

    var env_map = std.process.getEnvMap(allocator) catch return props;
    defer env_map.deinit();

    var iter = env_map.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, prefix)) {
            const prop_key = try allocator.dupe(u8, key[prefix.len..]);
            const value = try allocator.dupe(u8, entry.value_ptr.*);
            try props.put(prop_key, value);
        }
    }

    return props;
}

pub fn jsonFileLoader(filepath: []const u8, io: std.Io) *const fn (std.mem.Allocator) anyerror!std.StringHashMap([]const u8) {
    return struct {
        fn load(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
            var props = std.StringHashMap([]const u8).init(allocator);

            const file = std.Io.Dir.cwd().openFile(io, filepath, .{}) catch return props;
            defer std.Io.File.close(file, io);

            const file_len = try std.Io.File.length(file, io);
            const content = try allocator.alloc(u8, file_len);
            defer allocator.free(content);
            _ = try std.Io.File.readPositionalAll(file, io, content, 0);

            // [...]JSON[...]key-value[...]
            // [...]std.json[...]
            // content[...]
            const dummy_key = try allocator.dupe(u8, "config.loaded");
            const dummy_value = try allocator.dupe(u8, "true");
            try props.put(dummy_key, dummy_value);

            return props;
        }
    }.load;
}

test "ExternalizedConfig basic operations" {
    const allocator = std.testing.allocator;
    var config = ExternalizedConfig.init(allocator, std.testing.io);
    defer config.deinit();

    const testLoader = struct {
        fn load(a: std.mem.Allocator) !std.StringHashMap([]const u8) {
            var props = std.StringHashMap([]const u8).init(a);
            const k = try a.dupe(u8, "app.name");
            const v = try a.dupe(u8, "test-app");
            try props.put(k, v);
            return props;
        }
    }.load;

    try config.addSource("test", 1, testLoader);
    try config.load();

    try std.testing.expectEqualStrings("test-app", config.get("app.name").?);
    try std.testing.expectEqualStrings("default", config.getOrDefault("missing", "default"));

    try config.set("app.port", "8080");
    try std.testing.expectEqual(@as(i64, 8080), config.getInt("app.port").?);
    try config.set("feature.enabled", "true");
    try std.testing.expectEqual(true, config.getBool("feature.enabled").?);
}

test "ExternalizedConfig listener notification" {
    const allocator = std.testing.allocator;
    var config = ExternalizedConfig.init(allocator, std.testing.io);
    defer config.deinit();

    const testLoader = struct {
        fn load(a: std.mem.Allocator) !std.StringHashMap([]const u8) {
            var props = std.StringHashMap([]const u8).init(a);
            const k = try a.dupe(u8, "key1");
            const v = try a.dupe(u8, "val1");
            try props.put(k, v);
            return props;
        }
    }.load;

    try config.addSource("test", 1, testLoader);
    try config.load();

    var notified = false;
    const listener = struct {
        var flag: *bool = undefined;
        fn cb(key: []const u8, value: []const u8) void {
            if (std.mem.eql(u8, key, "key1") and std.mem.eql(u8, value, "new_val")) {
                flag.* = true;
            }
        }
    };
    listener.flag = &notified;

    try config.addListener(listener.cb);
    try config.set("key1", "new_val");
    try std.testing.expect(notified);
}

test "ExternalizedConfig refresh" {
    const allocator = std.testing.allocator;
    var config = ExternalizedConfig.init(allocator, std.testing.io);
    defer config.deinit();

    const testLoader = struct {
        fn load(a: std.mem.Allocator) !std.StringHashMap([]const u8) {
            var props = std.StringHashMap([]const u8).init(a);
            const k = try a.dupe(u8, "refresh_key");
            const v = try a.dupe(u8, "refreshed");
            try props.put(k, v);
            return props;
        }
    }.load;

    try config.addSource("test", 1, testLoader);
    try config.load();
    try config.refresh();

    try std.testing.expectEqualStrings("refreshed", config.get("refresh_key").?);
}

test "ExternalizedConfig file watcher lifecycle" {
    const allocator = std.testing.allocator;
    var config = ExternalizedConfig.init(allocator, std.testing.io);
    defer config.deinit();

    // Create a temp file
    var tmp = try std.Io.Dir.cwd().createFile(std.testing.io, "zigmodu_test_config.tmp", .{});
    defer {
        tmp.close(std.testing.io);
        std.Io.Dir.cwd().deleteFile(std.testing.io, "zigmodu_test_config.tmp") catch {};
    }
    try tmp.writeStreamingAll(std.testing.io, "{}");

    const dummyLoader = struct {
        fn load(a: std.mem.Allocator) !std.StringHashMap([]const u8) {
            return std.StringHashMap([]const u8).init(a);
        }
    }.load;

    try config.watchFile("zigmodu_test_config.tmp", dummyLoader);
    try std.testing.expectEqual(@as(usize, 1), config.getWatcherCount());

    try config.watch(.{ .interval_ms = 100 });
    try std.testing.expect(config.isWatching());

    config.stopWatching();
    try std.testing.expect(!config.isWatching());
}
