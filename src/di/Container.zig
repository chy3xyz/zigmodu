const std = @import("std");

const ServiceWrapper = struct {
    ptr: *anyopaque,
    type_name: []const u8,
    type_hash: u64, // 添加类型哈希用于运行时验证
    vtable: *const VTable,

    const VTable = struct {
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    fn create(comptime T: type, instance: *T, allocator: std.mem.Allocator) !*ServiceWrapper {
        const type_name = @typeName(T);
        const wrapper = try allocator.create(ServiceWrapper);
        wrapper.* = .{
            .ptr = instance,
            .type_name = try allocator.dupe(u8, type_name),
            .type_hash = comptime std.hash.Crc32.hash(type_name), // 编译时计算类型哈希
            .vtable = &comptime VTable{
                .destroy = struct {
                    fn destroy(service_ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const typed_ptr: *T = @ptrCast(@alignCast(service_ptr));
                        alloc.destroy(typed_ptr);
                    }
                }.destroy,
            },
        };
        return wrapper;
    }

    fn destroy(self: *ServiceWrapper, allocator: std.mem.Allocator) void {
        allocator.free(self.type_name);
        self.vtable.destroy(self.ptr, allocator);
        allocator.destroy(self);
    }
};

pub const Container = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    services: std.StringHashMap(*ServiceWrapper),

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .services = std.StringHashMap(*ServiceWrapper).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.services.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.*.destroy(self.allocator);
        }
        self.services.deinit();
    }

    pub fn register(self: *Self, comptime T: type, name: []const u8, instance: *T) !void {
        const wrapper = try ServiceWrapper.create(T, instance, self.allocator);
        try self.services.put(name, wrapper);
    }

    pub fn get(self: *Self, comptime T: type, name: []const u8) ?*T {
        const wrapper = self.services.get(name) orelse return null;
        const expected_type = @typeName(T);
        if (!std.mem.eql(u8, wrapper.type_name, expected_type)) {
            std.log.warn("Type mismatch for service '{s}': expected {s}, got {s}", .{
                name,
                expected_type,
                wrapper.type_name,
            });
            return null;
        }

        // 运行时类型哈希验证
        const expected_hash = comptime std.hash.Crc32.hash(expected_type);
        if (wrapper.type_hash != expected_hash) {
            std.log.warn("Type hash mismatch for service '{s}': possible memory corruption", .{name});
            return null;
        }

        return @ptrCast(@alignCast(wrapper.ptr));
    }

    pub fn contains(self: *Self, name: []const u8) bool {
        return self.services.contains(name);
    }

    pub fn remove(self: *Self, name: []const u8) void {
        if (self.services.fetchRemove(name)) |kv| {
            kv.value.destroy(self.allocator);
        }
    }

    pub fn serviceCount(self: *Self) usize {
        return self.services.count();
    }
};

pub const ScopedContainer = struct {
    const Self = @This();

    parent: ?*Container,
    local: Container,
    scope_name: []const u8,

    pub fn init(allocator: std.mem.Allocator, scope_name: []const u8, parent: ?*Container) Self {
        return .{
            .parent = parent,
            .local = Container.init(allocator),
            .scope_name = scope_name,
        };
    }

    pub fn deinit(self: *Self) void {
        self.local.deinit();
    }

    pub fn register(self: *Self, comptime T: type, name: []const u8, instance: *T) !void {
        try self.local.register(T, name, instance);
    }

    pub fn get(self: *Self, comptime T: type, name: []const u8) ?*T {
        if (self.local.get(T, name)) |svc| {
            return svc;
        }
        if (self.parent) |parent| {
            return parent.get(T, name);
        }
        return null;
    }

    pub fn contains(self: *Self, name: []const u8) bool {
        return self.local.contains(name) or (self.parent != null and self.parent.?.contains(name));
    }
};

test "Container register get remove" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const DbType = struct {
        connected: bool = true,
    };
    const db = try allocator.create(DbType);
    db.* = .{ .connected = true };

    try container.register(DbType, "database", db);
    try std.testing.expect(container.contains("database"));
    try std.testing.expectEqual(@as(usize, 1), container.serviceCount());

    const retrieved = container.get(DbType, "database").?;
    try std.testing.expect(retrieved.connected);

    container.remove("database");
    try std.testing.expect(!container.contains("database"));
    try std.testing.expectEqual(@as(usize, 0), container.serviceCount());
}

test "Container type mismatch returns null" {
    const allocator = std.testing.allocator;

    var container = Container.init(allocator);
    defer container.deinit();

    const DbType = struct { id: i32 = 1 };
    const db = try allocator.create(DbType);
    db.* = .{ .id = 1 };
    try container.register(DbType, "db", db);

    const wrong_type = container.get(i32, "db");
    try std.testing.expect(wrong_type == null);
}

test "ScopedContainer parent resolution" {
    const allocator = std.testing.allocator;

    var parent = Container.init(allocator);
    defer parent.deinit();

    var scoped = ScopedContainer.init(allocator, "request", &parent);
    defer scoped.deinit();

    const SvcType = struct { value: i32 = 10 };
    const svc = try allocator.create(SvcType);
    svc.* = .{ .value = 10 };
    try parent.register(SvcType, "svc", svc);

    try std.testing.expect(scoped.contains("svc"));
    const retrieved = scoped.get(SvcType, "svc").?;
    try std.testing.expectEqual(@as(i32, 10), retrieved.value);
}
