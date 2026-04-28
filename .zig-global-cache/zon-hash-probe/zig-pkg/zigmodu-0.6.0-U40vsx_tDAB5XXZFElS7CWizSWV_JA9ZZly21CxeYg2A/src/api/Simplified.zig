const std = @import("std");
const Event = @import("../core/Event.zig").Event;
const ArrayList = std.array_list.Managed;

/// Simplified Module interface using VTable pattern
/// Provides runtime polymorphism without circular dependencies
pub const Module = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (*anyopaque) []const u8,
        init: *const fn (*anyopaque, *anyopaque) anyerror!void,
        start: *const fn (*anyopaque) anyerror!void,
        stop: *const fn (*anyopaque) void,
        dependencies: ?*const fn (*anyopaque) []const []const u8 = null,
        on_event: ?*const fn (*anyopaque, Event) void = null,
    };

    pub fn name(self: Module) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn init(self: Module, app: *anyopaque) !void {
        return self.vtable.init(self.ptr, app);
    }

    pub fn start(self: Module) !void {
        return self.vtable.start(self.ptr);
    }

    pub fn stop(self: Module) void {
        return self.vtable.stop(self.ptr);
    }

    pub fn dependencies(self: Module) []const []const u8 {
        if (self.vtable.dependencies) |dep_fn| {
            return dep_fn(self.ptr);
        }
        return &[_][]const u8{};
    }

    pub fn onEvent(self: Module, event: Event) void {
        if (self.vtable.on_event) |handler| {
            handler(self.ptr, event);
        }
    }
};

/// Auto-generate Module interface from implementation struct
pub fn ModuleImpl(comptime T: type) type {
    return struct {
        pub fn interface(ptr: *T) Module {
            const gen = struct {
                pub fn name(ctx: *anyopaque) []const u8 {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    return @call(.auto, T.name, .{self});
                }

                pub fn init(ctx: *anyopaque, app_ctx: *anyopaque) !void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    if (@hasDecl(T, "init")) {
                        return @call(.auto, T.init, .{ self, app_ctx });
                    }
                }

                pub fn start(ctx: *anyopaque) !void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    if (@hasDecl(T, "start")) {
                        return @call(.auto, T.start, .{self});
                    }
                }

                pub fn stop(ctx: *anyopaque) void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    if (@hasDecl(T, "stop")) {
                        @call(.auto, T.stop, .{self});
                    }
                }

                pub fn dependencies(ctx: *anyopaque) []const []const u8 {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    if (@hasDecl(T, "dependencies")) {
                        return @call(.auto, T.dependencies, .{self});
                    }
                    return &[_][]const u8{};
                }

                pub fn on_event(ctx: *anyopaque, evt: Event) void {
                    const self: *T = @ptrCast(@alignCast(ctx));
                    if (@hasDecl(T, "onEvent")) {
                        @call(.auto, T.onEvent, .{ self, evt });
                    }
                }
            };

            // Check which methods exist at compile time
            const has_deps = @hasDecl(T, "dependencies");
            const has_event = @hasDecl(T, "onEvent");

            return Module{
                .ptr = ptr,
                .vtable = &.{
                    .name = gen.name,
                    .init = gen.init,
                    .start = gen.start,
                    .stop = gen.stop,
                    .dependencies = if (has_deps) gen.dependencies else null,
                    .on_event = if (has_event) gen.on_event else null,
                },
            };
        }
    };
}

/// Simplified Application container
pub const App = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    modules: ArrayList(Module),
    state: State,

    pub const State = enum {
        initialized,
        started,
        stopped,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .modules = ArrayList(Module).init(allocator),
            .state = .initialized,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.state == .started) {
            self.stop();
        }
        self.modules.deinit();
    }

    pub fn register(self: *Self, module: Module) !void {
        try self.modules.append(module);
    }

    pub fn start(self: *Self) !void {
        if (self.state == .started) return;

        // Initialize all modules
        for (self.modules.items) |mod| {
            try mod.init(self);
        }

        // Start all modules
        for (self.modules.items) |mod| {
            try mod.start();
        }

        self.state = .started;
    }

    pub fn stop(self: *Self) void {
        if (self.state != .started) return;

        // Stop in reverse order
        var i: usize = self.modules.items.len;
        while (i > 0) {
            i -= 1;
            self.modules.items[i].stop();
        }

        self.state = .stopped;
    }

    /// Publish an event to all registered modules
    pub fn publish(self: *Self, event: Event) void {
        for (self.modules.items) |mod| {
            mod.onEvent(event);
        }
    }

    /// Get number of registered modules
    pub fn moduleCount(self: *Self) usize {
        return self.modules.items.len;
    }
};

test "ModuleImpl interface generation" {
    const MockModule = struct {
        pub fn name(self: *@This()) []const u8 {
            _ = self;
            return "mock-module";
        }
        pub fn init(self: *@This(), app: *anyopaque) !void {
            _ = self;
            _ = app;
        }
        pub fn start(self: *@This()) !void {
            _ = self;
        }
        pub fn stop(self: *@This()) void {
            _ = self;
        }
        pub fn dependencies(self: *@This()) []const []const u8 {
            _ = self;
            return &.{"dep1"};
        }
    };

    var mock = MockModule{};
    const module = ModuleImpl(MockModule).interface(&mock);

    try std.testing.expectEqualStrings("mock-module", module.name());
    try std.testing.expectEqual(@as(usize, 1), module.dependencies().len);
    try std.testing.expectEqualStrings("dep1", module.dependencies()[0]);
}

test "App register start stop publish" {
    const allocator = std.testing.allocator;

    const EventType = @import("../core/Event.zig").Event;
    const MockModule = struct {
        started: bool = false,
        stopped: bool = false,
        last_event: ?EventType = null,

        pub fn name(self: *@This()) []const u8 {
            _ = self;
            return "event-mock";
        }
        pub fn init(self: *@This(), app: *anyopaque) !void {
            _ = app;
            _ = self;
        }
        pub fn start(self: *@This()) !void {
            self.started = true;
        }
        pub fn stop(self: *@This()) void {
            self.stopped = true;
        }
        pub fn onEvent(self: *@This(), evt: EventType) void {
            self.last_event = evt;
        }
    };

    var app = App.init(allocator);
    defer app.deinit();

    var mock = MockModule{};
    const module = ModuleImpl(MockModule).interface(&mock);

    try app.register(module);
    try std.testing.expectEqual(@as(usize, 1), app.moduleCount());

    try app.start();
    try std.testing.expect(mock.started);

    const evt = EventType{ .module_init = .{ .module_name = "test", .timestamp = 1 } };
    app.publish(evt);
    try std.testing.expect(mock.last_event != null);

    app.stop();
    try std.testing.expect(mock.stopped);
}
