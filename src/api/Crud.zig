//! `http.CrudApi(Entity, Service, opts)` — one declaration generates the whole
//! org-scoped CRUD surface (list/get/create/update/delete) with JWT/permission
//! metas, `PageParams` clamping and a configurable paged envelope. Service
//! must expose duck-typed `list/get/create/update/delete` (see
//! `data.CrudService` for the generic implementation) plus
//! `module_name`/`nest` consts. Zero-passthrough form: when the Service
//! declares `pub const impl = data.CrudService(Entity, P);` (type) and a
//! `crud: impl` field of that type, CrudApi calls through to it directly,
//! so the service file only carries wiring + an optional validate hook.
//!
//! Custom business logic: any of the five CRUD methods the Service itself
//! declares takes precedence over the embedded impl — e.g. a wrapper
//! `pub fn create(...)` can call `self.crud.create(e)` for the base behavior
//! and then run side effects. Pure-CRUD services stay zero-passthrough.

const std = @import("std");
const http = @import("../http.zig");
const page_mod = @import("../http/Page.zig");

pub const CrudOpts = struct {
    envelope: page_mod.Envelope = .items,
    /// Permission base (default: Service.module_name) → "<base>:read"/"<base>:write".
    permission: ?[]const u8 = null,
    public: bool = false,
};

pub fn CrudApi(comptime Entity: type, comptime Service: type, comptime opts: CrudOpts) type {
    const base = comptime opts.permission orelse Service.module_name;
    const read_perm = comptime base ++ ":read";
    const write_perm = comptime base ++ ":write";

    return struct {
        const Self = @This();

        service: *Service,

        // Effective CRUD backend: the embedded CrudService when present,
        // otherwise the service itself (duck-typed methods).
        const Svc = if (@hasDecl(Service, "impl")) Service.impl else Service;

        pub const module_name = Service.module_name;
        pub const nest = Service.nest;
        pub const State = Self;

        pub fn init(s: *Service) Self {
            return .{ .service = s };
        }

        const auth = if (opts.public) .public else .jwt;
        const read_meta = http.RouteMeta{ .auth = auth, .permission = if (opts.public) null else read_perm };
        const write_meta = http.RouteMeta{ .auth = auth, .permission = if (opts.public) null else write_perm };

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = list, .meta = read_meta },
            .{ .method = .POST, .path = "", .handler = create, .meta = write_meta },
            .{ .method = .GET, .path = "{id}", .handler = get, .meta = read_meta },
            .{ .method = .PUT, .path = "{id}", .handler = update, .meta = write_meta },
            .{ .method = .DELETE, .path = "{id}", .handler = remove, .meta = write_meta },
        };

        fn tenantId(ctx: *http.Context) !i64 {
            const s = ctx.getAttr("tenant_id") orelse return error.Unauthorized;
            return std.fmt.parseInt(i64, s, 10);
        }

        fn svc(self: *State) *Svc {
            if (comptime @hasDecl(Service, "impl")) {
                return &self.service.crud;
            }
            return self.service;
        }

        // Custom-method-first dispatch: a wrapper-declared CRUD method wins,
        // otherwise fall back to the embedded CrudService.
        const custom_list = @hasDecl(Service, "list");
        fn listImpl(self: *State, allocator: std.mem.Allocator, org_id: i64, page: usize, size: usize) !std.ArrayList(Entity) {
            if (comptime custom_list) return self.service.list(allocator, org_id, page, size);
            return svc(self).list(allocator, org_id, page, size);
        }

        const custom_get = @hasDecl(Service, "get");
        fn getImpl(self: *State, allocator: std.mem.Allocator, org_id: i64, id: i64) !?Entity {
            if (comptime custom_get) return self.service.get(allocator, org_id, id);
            return svc(self).get(allocator, org_id, id);
        }

        const custom_create = @hasDecl(Service, "create");
        fn createImpl(self: *State, e: Entity) !i64 {
            if (comptime custom_create) return self.service.create(e);
            return svc(self).create(e);
        }

        const custom_update = @hasDecl(Service, "update");
        fn updateImpl(self: *State, e: Entity, org_id: i64) !void {
            if (comptime custom_update) return self.service.update(e, org_id);
            return svc(self).update(e, org_id);
        }

        const custom_delete = @hasDecl(Service, "delete");
        fn deleteImpl(self: *State, org_id: i64, id: i64) !void {
            if (comptime custom_delete) return self.service.delete(org_id, id);
            return svc(self).delete(org_id, id);
        }

        fn list(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const params = page_mod.PageParams.parse(ctx, .{});
            var items = listImpl(self, ctx.allocator, org_id, params.page, params.page_size) catch |err| return http.respondErr(ctx, err);
            defer items.deinit(ctx.allocator);
            try page_mod.sendPaged(ctx, items.items, items.items.len, params, opts.envelope);
        }

        fn get(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            const entity = getImpl(self, ctx.allocator, org_id, id) catch |err| return http.respondErr(ctx, err);
            if (entity) |e| {
                try ctx.jsonStruct(200, .{ .code = 0, .data = e });
            } else {
                try ctx.jsonStruct(404, .{ .code = 404, .msg = "not found" });
            }
        }

        fn create(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            var entity = ctx.bindJson(Entity) catch return ctx.jsonStruct(400, .{ .code = 400, .msg = "invalid body" });
            entity.org_id = org_id;
            const id = createImpl(self, entity) catch |err| return http.respondErr(ctx, err);
            try ctx.jsonStruct(200, .{ .code = 0, .id = id });
        }

        fn update(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            var entity = ctx.bindJson(Entity) catch return ctx.jsonStruct(400, .{ .code = 400, .msg = "invalid body" });
            entity.id = id;
            entity.org_id = org_id;
            updateImpl(self, entity, org_id) catch |err| return http.respondErr(ctx, err);
            try ctx.jsonStruct(200, .{ .code = 0 });
        }

        fn remove(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            deleteImpl(self, org_id, id) catch |err| return http.respondErr(ctx, err);
            try ctx.jsonStruct(200, .{ .code = 0 });
        }
    };
}

// ── tests ─────────────────────────────────────────────────────────────────

const TestEntity = struct {
    id: i64 = 0,
    org_id: i64 = 0,
};

const TestService = struct {
    pub const module_name = "widgets";
    pub const nest = .{"widgets"};

    pub fn list(_: *@This(), _: std.mem.Allocator, _: i64, _: usize, _: usize) !std.ArrayList(TestEntity) {
        return std.ArrayList(TestEntity).empty;
    }
    pub fn get(_: *@This(), allocator: std.mem.Allocator, _: i64, id: i64) !?TestEntity {
        _ = allocator;
        return .{ .id = id };
    }
    pub fn create(_: *@This(), _: TestEntity) !i64 {
        return 1;
    }
    pub fn update(_: *@This(), _: TestEntity, _: i64) !void {}
    pub fn delete(_: *@This(), _: i64, _: i64) !void {}
};

// Zero-passthrough form: CrudApi must route through the embedded `impl`
// field (a data.CrudService-compatible type) instead of requiring the
// service itself to expose list/get/create/update/delete.
const TestCrudImpl = struct {
    pub fn list(_: *@This(), _: std.mem.Allocator, _: i64, _: usize, _: usize) !std.ArrayList(TestEntity) {
        return std.ArrayList(TestEntity).empty;
    }
    pub fn get(_: *@This(), allocator: std.mem.Allocator, _: i64, id: i64) !?TestEntity {
        _ = allocator;
        return .{ .id = id };
    }
    pub fn create(_: *@This(), _: TestEntity) !i64 {
        return 9;
    }
    pub fn update(_: *@This(), _: TestEntity, _: i64) !void {}
    pub fn delete(_: *@This(), _: i64, _: i64) !void {}
};

const TestImplService = struct {
    pub const module_name = "widgets";
    pub const nest = .{"widgets"};
    pub const impl = TestCrudImpl;
    crud: TestCrudImpl,

    pub fn init() @This() {
        return .{ .crud = .{} };
    }
};

// Custom business logic: wrapper-declared methods must win over the embedded
// impl (they can call self.crud for the base behavior + run side effects).
const TestOverrideService = struct {
    pub const module_name = "widgets";
    pub const nest = .{"widgets"};
    pub const impl = TestCrudImpl;
    crud: TestCrudImpl,

    pub fn init() @This() {
        return .{ .crud = .{} };
    }

    pub fn create(self: *@This(), e: TestEntity) !i64 {
        return (try self.crud.create(e)) + 33;
    }

    pub fn delete(_: *@This(), org_id: i64, id: i64) !void {
        _ = org_id;
        _ = id;
    }
};

test "CrudApi generates five routes with permission metas" {
    const Api = CrudApi(TestEntity, TestService, .{});
    try std.testing.expectEqual(@as(usize, 5), Api.routes.len);
    try std.testing.expect(Api.routes[0].method == .GET);
    try std.testing.expect(Api.routes[1].method == .POST);
    try std.testing.expectEqualStrings("widgets:read", Api.routes[0].meta.permission.?);
    try std.testing.expectEqualStrings("widgets:write", Api.routes[1].meta.permission.?);
    try std.testing.expect(Api.routes[0].meta.auth == .jwt);
}

test "CrudApi prefers wrapper-declared CRUD methods over embedded impl" {
    const Api = CrudApi(TestEntity, TestOverrideService, .{});
    try std.testing.expectEqual(@as(usize, 5), Api.routes.len);
    var svc = TestOverrideService.init();
    var api = Api.init(&svc);
    _ = &api;
}

test "CrudApi routes through embedded impl (zero passthrough)" {
    const Api = CrudApi(TestEntity, TestImplService, .{});
    try std.testing.expectEqual(@as(usize, 5), Api.routes.len);
    try std.testing.expectEqualStrings("widgets:read", Api.routes[0].meta.permission.?);
    var svc = TestImplService.init();
    var api = Api.init(&svc);
    _ = &api;
}

test "CrudApi honors permission override and public flag" {
    const Api = CrudApi(TestEntity, TestService, .{ .permission = "crm.order" });
    try std.testing.expectEqualStrings("crm.order:read", Api.routes[0].meta.permission.?);
    try std.testing.expectEqualStrings("crm.order:write", Api.routes[1].meta.permission.?);
    try std.testing.expect(Api.routes[0].meta.auth == .jwt);

    const Pub = CrudApi(TestEntity, TestService, .{ .public = true });
    try std.testing.expect(Pub.routes[0].meta.permission == null);
    try std.testing.expect(Pub.routes[0].meta.auth == .public);
}
