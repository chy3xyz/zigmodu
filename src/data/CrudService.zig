//! Generic CRUD service — eliminates the per-module `list/get/create/update/
//! delete` passthrough boilerplate and turns writes into events
//! ("CRUD 即事件源"). Modules only supply persistence (duck-typed
//! `list/get/create/update/delete`) and an optional validate hook.

const std = @import("std");
const event_bus = @import("../core/EventBus.zig");
const result_set = @import("ResultSet.zig");

pub fn CrudEvent(comptime Entity: type) type {
    _ = Entity;
    return union(enum) {
        created: i64,
        updated: i64,
        deleted: i64,
    };
}

pub fn CrudService(comptime Entity: type, comptime P: type) type {
    return struct {
        const Self = @This();

        persistence: *P,
        event_bus: ?*event_bus.TypedEventBus(CrudEvent(Entity)) = null,
        /// Optional validation hook called by create/update.
        validate: ?*const fn (Entity) anyerror!void = null,

        pub fn init(p: *P) Self {
            return .{ .persistence = p };
        }

        pub fn setEventBus(self: *Self, bus: *event_bus.TypedEventBus(CrudEvent(Entity))) void {
            self.event_bus = bus;
        }

        fn publish(self: *Self, e: CrudEvent(Entity)) void {
            if (self.event_bus) |bus| bus.publish(e);
        }

        /// Arena-backed read: items borrow one arena (no per-string copy) —
        /// callers `defer result.deinit(allocator)` once.
        pub fn list(self: *Self, org_id: i64, page: usize, size: usize, sort: ?result_set.SortSpec) !result_set.ResultSet(Entity) {
            return self.persistence.list(org_id, page, size, sort);
        }

        pub fn get(self: *Self, allocator: std.mem.Allocator, org_id: i64, id: i64) !?Entity {
            return self.persistence.get(allocator, org_id, id);
        }

        pub fn create(self: *Self, e: Entity) !i64 {
            if (self.validate) |v| try v(e);
            const id = try self.persistence.create(e);
            self.publish(.{ .created = id });
            return id;
        }

        pub fn update(self: *Self, e: Entity, org_id: i64) !void {
            if (self.validate) |v| try v(e);
            try self.persistence.update(e, org_id);
            self.publish(.{ .updated = e.id });
        }

        pub fn delete(self: *Self, org_id: i64, id: i64) !void {
            try self.persistence.delete(org_id, id);
            self.publish(.{ .deleted = id });
        }
    };
}

// ── tests ─────────────────────────────────────────────────────────────────

const FakeEntity = struct {
    id: i64 = 0,
    org_id: i64 = 0,
    name: []const u8 = "",
};

const FakePersistence = struct {
    created: i64 = 0,
    updated: bool = false,
    deleted: bool = false,

    pub fn list(_: *@This(), _: i64, _: usize, _: usize, _: ?result_set.SortSpec) !result_set.ResultSet(FakeEntity) {
        return result_set.ResultSet(FakeEntity).fromOwned(&[_]FakeEntity{}, null);
    }
    pub fn get(_: *@This(), allocator: std.mem.Allocator, _: i64, id: i64) !?FakeEntity {
        _ = allocator;
        return .{ .id = id };
    }
    pub fn create(self: *@This(), e: FakeEntity) !i64 {
        self.created = e.id;
        return e.id;
    }
    pub fn update(self: *@This(), e: FakeEntity, _: i64) !void {
        self.updated = true;
        _ = e;
    }
    pub fn delete(self: *@This(), _: i64, _: i64) !void {
        self.deleted = true;
    }
};

test "CrudService delegates and publishes events" {
    const allocator = std.testing.allocator;
    var bus = event_bus.TypedEventBus(CrudEvent(FakeEntity)).init(allocator);
    defer bus.deinit();
    try bus.subscribe(struct {
        fn h(e: CrudEvent(FakeEntity)) void {
            _ = e;
        }
    }.h);

    var persist = FakePersistence{};
    var svc = CrudService(FakeEntity, FakePersistence).init(&persist);
    svc.setEventBus(&bus);
    const id = try svc.create(.{ .id = 7 });
    try std.testing.expectEqual(@as(i64, 7), id);
    try std.testing.expectEqual(@as(i64, 7), persist.created);
    try svc.update(.{ .id = 7 }, 1);
    try std.testing.expect(persist.updated);
    try svc.delete(1, 7);
    try std.testing.expect(persist.deleted);
    try std.testing.expectEqual(@as(usize, 3), bus.publishedCount());
}
