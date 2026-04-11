const std = @import("std");
const EventBus = @import("./EventBus.zig").EventBus;

/// @ApplicationModuleListener 等效实现
/// 用于标记模块事件监听器，提供事务性、异步等特性
pub fn ApplicationModuleListener(comptime EventType: type) type {
    return struct {
        const Self = @This();

        /// 监听器配置
        pub const Config = struct {
            async_mode: bool = true,
            transactional: bool = false,
            condition: ?[]const u8 = null,
        };

        config: Config,
        handler: *const fn (EventType) anyerror!void,
        event_bus: *EventBus(EventType),

        pub fn init(
            event_bus: *EventBus(EventType),
            handler: *const fn (EventType) anyerror!void,
            config: Config,
        ) Self {
            return .{
                .event_bus = event_bus,
                .handler = handler,
                .config = config,
            };
        }

        /// 订阅事件
        pub fn subscribe(self: *Self) !void {
            const handler_ptr = self.handler;

            // 根据配置包装处理器
            const wrapped_handler = if (self.config.async_mode)
                struct {
                    fn wrapper(event: EventType) void {
                        handler_ptr(event) catch |err| {
                            std.log.err("Event handler failed: {}", .{err});
                        };
                    }
                }.wrapper
            else
                struct {
                    fn wrapper(event: EventType) void {
                        handler_ptr(event) catch |err| {
                            std.log.err("Event handler failed: {}", .{err});
                        };
                    }
                }.wrapper;

            // 实际订阅
            try self.event_bus.subscribe(wrapped_handler);
        }

        /// 取消订阅
        pub fn unsubscribe(self: *Self) void {
            _ = self;
            // 实现取消订阅逻辑
        }
    };
}

/// 模块事件监听器注册表
/// 管理所有模块的事件监听器
pub const ModuleListenerRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    listeners: std.StringHashMap(ListenerInfo),

    pub const ListenerInfo = struct {
        module_name: []const u8,
        event_type: []const u8,
        handler_ptr: *anyopaque,
        is_async: bool,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .listeners = std.StringHashMap(ListenerInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.listeners.deinit();
    }

    /// 注册监听器
    pub fn registerListener(
        self: *Self,
        module_name: []const u8,
        event_type: []const u8,
        handler: *anyopaque,
        is_async: bool,
    ) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ module_name, event_type });
        defer self.allocator.free(key);

        try self.listeners.put(key, .{
            .module_name = module_name,
            .event_type = event_type,
            .handler_ptr = handler,
            .is_async = is_async,
        });
    }

    /// 获取模块的所有监听器
    pub fn getModuleListeners(self: *Self, module_name: []const u8) !std.ArrayList(ListenerInfo) {
        // Validate input
        if (module_name.len == 0) return error.InvalidModuleName;

        var result = std.ArrayList(ListenerInfo).init(self.allocator);
        errdefer result.deinit();

        var iter = self.listeners.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.module_name, module_name)) {
                try result.append(entry.value_ptr.*);
            }
        }

        return result;
    }
};

/// 事件外部化支持
/// 将事件发布到外部系统（消息队列等）
pub const EventExternalization = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    externalizers: std.ArrayList(Externalizer),

    pub const Externalizer = struct {
        name: []const u8,
        can_handle: *const fn ([]const u8) bool,
        externalize: *const fn ([]const u8, []const u8) anyerror!void,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .externalizers = std.ArrayList(Externalizer).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.externalizers.deinit();
    }

    /// 注册外部化器
    pub fn registerExternalizer(self: *Self, externalizer: Externalizer) !void {
        try self.externalizers.append(externalizer);
    }

    /// 外部化事件
    pub fn externalize(self: *Self, event_type: []const u8, event_data: []const u8) !void {
        for (self.externalizers.items) |externalizer| {
            if (externalizer.can_handle(event_type)) {
                try externalizer.externalize(event_type, event_data);
                return;
            }
        }

        // 没有找到合适的外部化器
        std.log.warn("No externalizer found for event type: {s}", .{event_type});
    }
};
