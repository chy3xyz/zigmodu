const std = @import("std");

pub const ApplicationObserver = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    listeners: std.ArrayList(*const fn (Event) void),

    pub const Event = union(enum) {
        module_initializing: ModuleName,
        module_started: ModuleName,
        module_stopping: ModuleName,
        module_stopped: ModuleName,
        application_ready: void,
        application_shutting_down: void,
    };

    pub const ModuleName = struct {
        name: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .listeners = std.ArrayList(*const fn (Event) void).empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.listeners.deinit(self.allocator);
    }

    pub fn addListener(self: *Self, listener: *const fn (Event) void) !void {
        try self.listeners.append(self.allocator, listener);
    }

    pub fn notify(self: *Self, event: Event) void {
        for (self.listeners.items) |listener| {
            listener(event);
        }
    }

    pub fn notifyModuleStarted(self: *Self, module_name: []const u8) void {
        self.notify(.{ .module_started = .{ .name = module_name } });
    }

    pub fn notifyModuleStopped(self: *Self, module_name: []const u8) void {
        self.notify(.{ .module_stopped = .{ .name = module_name } });
    }

    pub fn notifyApplicationReady(self: *Self) void {
        self.notify(.{ .application_ready = {} });
    }

    pub fn notifyApplicationShuttingDown(self: *Self) void {
        self.notify(.{ .application_shutting_down = {} });
    }
};

test "ApplicationObserver" {
    const allocator = std.testing.allocator;
    var observer = ApplicationObserver.init(allocator);
    defer observer.deinit();

    const listener = struct {
        fn handle(event: ApplicationObserver.Event) void {
            _ = event;
        }
    }.handle;

    try observer.addListener(listener);
    observer.notifyApplicationReady();
}
