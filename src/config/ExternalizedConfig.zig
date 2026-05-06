const std = @import("std");
const ZigModuError = @import("../core/Error.zig").ZigModuError;

/// 外部化配置管理器
/// 支持多源配置：环境变量、配置文件、配置中心
/// 支持配置热更新（文件监听）
pub const ExternalizedConfig = struct {
    const Self = @This();

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
        priority: u8, // 优先级，数字越小优先级越高
        loader: *const fn (allocator: std.mem.Allocator) anyerror!std.StringHashMap([]const u8),
    };

    /// 文件监听器 - 监控配置文件变化
    pub const FileWatcher = struct {
        filepath: []const u8,
        last_modified: i128,
        loader: *const fn (std.mem.Allocator) anyerror!std.StringHashMap([]const u8),
    };

    pub const WatchConfig = struct {
        interval_ms: u64 = 1000, // 默认1秒检查一次
    };

    pub fn deinit(self: *Self) void {
        // 停止监听线程
        self.stopWatching();

        // 释放所有配置值
        var prop_iter = self.properties.iterator();
        while (prop_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.properties.deinit();
        self.sources.deinit(self.allocator);
        self.listeners.deinit(self.allocator);

        // 释放文件监听器
        for (self.file_watchers.items) |*watcher| {
            self.allocator.free(watcher.filepath);
        }
        self.file_watchers.deinit(self.allocator);
    }

    /// 添加配置源
    pub fn addSource(self: *Self, name: []const u8, priority: u8, loader: *const fn (std.mem.Allocator) anyerror!std.StringHashMap([]const u8)) !void {
        try self.sources.append(self.allocator, .{
            .name = name,
            .priority = priority,
            .loader = loader,
        });

        // 按优先级排序
        std.sort.insertion(ConfigSource, self.sources.items, {}, compareSourcePriority);
    }

    fn compareSourcePriority(_: void, a: ConfigSource, b: ConfigSource) bool {
        return a.priority < b.priority;
    }

    /// 从所有源加载配置
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

                // 如果键已存在，根据优先级决定是否覆盖
                if (self.properties.get(key)) |old_value| {
                    self.allocator.free(old_value);
                }

                try self.properties.put(key, value);
            }
        }

        std.log.info("Loaded {d} configuration properties", .{self.properties.count()});
    }

    /// 获取配置值
    pub fn get(self: *Self, key: []const u8) ?[]const u8 {
        return self.properties.get(key);
    }

    /// 获取配置值（带默认值）
    pub fn getOrDefault(self: *Self, key: []const u8, default_value: []const u8) []const u8 {
        return self.properties.get(key) orelse default_value;
    }

    /// 获取整数配置
    pub fn getInt(self: *Self, key: []const u8) ?i64 {
        const value = self.properties.get(key) orelse return null;
        return std.fmt.parseInt(i64, value, 10) catch |err| {
            std.log.warn("Failed to parse integer config '{s}' with value '{s}': {s}", .{ key, value, @errorName(err) });
            return null;
        };
    }

    /// 获取整数配置（带明确错误）
    pub fn getIntOrError(self: *Self, key: []const u8) !?i64 {
        const value = self.properties.get(key) orelse return null;
        return try std.fmt.parseInt(i64, value, 10);
    }

    /// 获取布尔配置
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

    /// 设置配置值
    pub fn set(self: *Self, key: []const u8, value: []const u8) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        const value_copy = try self.allocator.dupe(u8, value);

        if (self.properties.fetchRemove(key_copy)) |old_kv| {
            self.allocator.free(old_kv.key);
            self.allocator.free(old_kv.value);
        }

        try self.properties.put(key_copy, value_copy);

        // 通知监听器
        for (self.listeners.items) |listener| {
            listener(key, value);
        }
    }

    /// 添加配置变更监听器
    pub fn addListener(self: *Self, listener: *const fn ([]const u8, []const u8) void) !void {
        try self.listeners.append(self.allocator, listener);
    }

    /// 添加配置文件监听（用于热更新）
    pub fn watchFile(self: *Self, filepath: []const u8, loader: *const fn (std.mem.Allocator) anyerror!std.StringHashMap([]const u8)) !void {
        const path_copy = try self.allocator.dupe(u8, filepath);
        errdefer self.allocator.free(path_copy);

        // 获取文件初始修改时间
        const stat = std.Io.Dir.cwd().statFile(self.io, filepath, .{}) catch |err| {
            std.log.warn("无法获取文件状态 {s}: {}", .{ filepath, err });
            // 文件可能不存在，使用当前时间
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

        std.log.info("开始监听配置文件: {s}", .{filepath});
    }

    /// 启动配置监听（热更新）
    pub fn watch(self: *Self, config: WatchConfig) !void {
        if (self.watch_thread != null) {
            std.log.warn("配置监听已在运行", .{});
            return;
        }

        self.watch_interval_ms = config.interval_ms;
        self.should_stop.store(false, .release);

        // 创建监听线程
        self.watch_thread = try std.Thread.spawn(.{}, watchThreadFn, .{self});

        std.log.info("配置热更新已启动 (检查间隔: {d}ms)", .{config.interval_ms});
    }

    /// 停止配置监听
    pub fn stopWatching(self: *Self) void {
        if (self.watch_thread) |thread| {
            self.should_stop.store(true, .release);
            thread.join();
            self.watch_thread = null;
            std.log.info("配置监听已停止", .{});
        }
    }

    /// 监听线程函数
    fn watchThreadFn(self: *Self) void {
        while (!self.should_stop.load(.acquire)) {
            self.checkFileChanges() catch |err| {
                std.log.err("检查文件变化时出错: {}", .{err});
            };

            // 使用更短的睡眠间隔来响应停止信号
            var remaining_ms = self.watch_interval_ms;
            while (remaining_ms > 0 and !self.should_stop.load(.acquire)) {
                const sleep_ms = @min(remaining_ms, 100);
                // std.Thread.sleep(@as(u64, sleep_ms) * std.time.ns_per_ms);
                remaining_ms -= sleep_ms;
            }
        }
    }

    /// 检查文件变化并重新加载
    fn checkFileChanges(self: *Self) !void {
        for (self.file_watchers.items) |*watcher| {
            const stat = std.Io.Dir.cwd().statFile(self.io, watcher.filepath, .{}) catch |err| {
                // 文件可能不存在或无法访问，跳过
                if (err == error.FileNotFound) {
                    std.log.warn("配置文件不存在: {s}", .{watcher.filepath});
                    continue;
                }
                return err;
            };

            if (@as(i128, @intCast(stat.mtime.nanoseconds)) > watcher.last_modified) {
                std.log.info("检测到配置文件变化: {s}", .{watcher.filepath});
                watcher.last_modified = @as(i128, @intCast(stat.mtime.nanoseconds));

                // 重新加载配置
                try self.reloadFromWatcher(watcher.*);
            }
        }
    }

    /// 从监听器重新加载配置
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

        // 记录哪些键发生了变化
        var changed_keys = std.ArrayList([]const u8).empty;
        defer {
            for (changed_keys.items) |key| {
                self.allocator.free(key);
            }
            changed_keys.deinit(self.allocator);
        }

        // 应用新配置
        var iter = new_props.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const new_value = entry.value_ptr.*;

            if (self.properties.get(key)) |old_value| {
                if (!std.mem.eql(u8, old_value, new_value)) {
                    // 值发生变化
                    const key_copy = try self.allocator.dupe(u8, key);
                    try changed_keys.append(self.allocator, key_copy);

                    // 更新配置
                    self.allocator.free(old_value);
                    const new_value_copy = try self.allocator.dupe(u8, new_value);
                    try self.properties.put(key, new_value_copy);

                    std.log.info("配置更新: {s} = {s}", .{ key, new_value });
                }
            } else {
                // 新增配置
                const key_copy = try self.allocator.dupe(u8, key);
                try changed_keys.append(self.allocator, key_copy);

                const key_copy2 = try self.allocator.dupe(u8, key);
                const value_copy = try self.allocator.dupe(u8, new_value);
                try self.properties.put(key_copy2, value_copy);

                std.log.info("配置新增: {s} = {s}", .{ key, new_value });
            }
        }

        // 通知监听器
        for (changed_keys.items) |key| {
            if (self.properties.get(key)) |value| {
                for (self.listeners.items) |listener| {
                    listener(key, value);
                }
            }
        }

        std.log.info("配置文件重新加载完成，共 {d} 个配置项变更", .{changed_keys.items.len});
    }

    /// 检查是否正在监听
    pub fn isWatching(self: *Self) bool {
        return self.watch_thread != null;
    }

    /// 获取监听器数量
    pub fn getWatcherCount(self: *Self) usize {
        return self.file_watchers.items.len;
    }

    /// 刷新配置（重新加载所有源）
    pub fn refresh(self: *Self) !void {
        std.log.info("手动刷新配置...", .{});

        // 清除现有配置
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.properties.clearRetainingCapacity();

        // 重新加载
        try self.load();
        std.log.info("配置刷新完成", .{});
    }

    /// 打印所有配置
    pub fn printAll(self: *Self) void {
        std.log.info("=== Configuration Properties ===", .{});
        var iter = self.properties.iterator();
        while (iter.next()) |entry| {
            std.log.info("  {s} = {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
};

/// 环境变量配置源
pub fn envVarLoader(allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
    var props = std.StringHashMap([]const u8).init(allocator);

    // 读取特定前缀的环境变量
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

            // 简化实现：解析JSON并扁平化为key-value对
            // 实际实现应使用std.json解析
            // content包含文件内容，实际应解析
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
