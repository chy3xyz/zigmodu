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
const data = @import("../data.zig");

pub const CrudOpts = struct {
    envelope: page_mod.Envelope = .items,
    /// Permission base (default: Service.module_name) → "<base>:read"/"<base>:write".
    permission: ?[]const u8 = null,
    public: bool = false,
    /// Response DTO whitelist: when set, list/get serialize a convention-
    /// mapped DTO (Extract.toDto) instead of the raw entity — internal
    /// columns (org_id, created_at, secret…) stay out of the wire format.
    dto: ?type = null,
    /// Add a POST {nest}/bulk endpoint accepting a JSON array of entities
    /// (one round-trip for import-style workloads). Rows are inserted
    /// sequentially through the service (validate + CrudEvent per row).
    bulk: bool = false,
    /// Allowed ORDER BY columns for the list endpoint (`sort=<col>&order=
    /// asc|desc`). Empty = no sorting. Anything not whitelisted is ignored.
    sortable: []const []const u8 = &.{},
    /// Context attribute carrying the tenant id. Default `"tenant_id"` is
    /// populated by the catalog JWT middleware from the JWT `aud` claim
    /// (`Middleware.zig`); override for multi-portal setups where a different
    /// attribute name is injected.
    tenant_attr: []const u8 = "tenant_id",
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

        pub const routes = blk: {
            var route_list: [if (opts.bulk) 6 else 5]http.RouteSpec(State) = undefined;
            route_list[0] = .{ .method = .GET, .path = "", .handler = list, .meta = read_meta };
            route_list[1] = .{ .method = .POST, .path = "", .handler = create, .meta = write_meta };
            route_list[2] = .{ .method = .GET, .path = "{id}", .handler = get, .meta = read_meta };
            route_list[3] = .{ .method = .PUT, .path = "{id}", .handler = update, .meta = write_meta };
            route_list[4] = .{ .method = .DELETE, .path = "{id}", .handler = remove, .meta = write_meta };
            if (opts.bulk) route_list[5] = .{ .method = .POST, .path = "bulk", .handler = bulkCreate, .meta = write_meta };
            break :blk route_list;
        };

        fn tenantId(ctx: *http.Context) !i64 {
            const s = ctx.getAttr(opts.tenant_attr) orelse return error.Unauthorized;
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
        fn listImpl(self: *State, org_id: i64, page: usize, size: usize, sort: ?data.SortSpec) !data.ResultSet(Entity) {
            if (comptime custom_list) return self.service.list(org_id, page, size, sort);
            return svc(self).list(org_id, page, size, sort);
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
            const sort = if (opts.sortable.len > 0) page_mod.parseSort(ctx, opts.sortable) else null;
            var result = listImpl(self, org_id, params.page, params.page_size, sort) catch |err| return http.respondErr(ctx, err);
            defer result.deinit(ctx.allocator);
            if (comptime opts.dto) |DtoT| {
                const dtos = try ctx.allocator.alloc(DtoT, result.items.len);
                errdefer ctx.allocator.free(dtos);
                for (result.items, 0..) |e, i| dtos[i] = http.toDto(DtoT, e);
                try page_mod.sendPaged(ctx, dtos, result.total, params, opts.envelope);
            } else {
                try page_mod.sendPaged(ctx, result.items, result.total, params, opts.envelope);
            }
        }

        fn get(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            const entity = getImpl(self, ctx.allocator, org_id, id) catch |err| return http.respondErr(ctx, err);
            if (entity) |e| {
                if (comptime opts.dto) |DtoT| {
                    try ctx.jsonStruct(200, .{ .code = 0, .data = http.toDto(DtoT, e) });
                } else {
                    try ctx.jsonStruct(200, .{ .code = 0, .data = e });
                }
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

        fn bulkCreate(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const entities = ctx.bindJson([]Entity) catch return ctx.jsonStruct(400, .{ .code = 400, .msg = "invalid body" });
            var ids = std.ArrayList(i64).empty;
            defer ids.deinit(ctx.allocator);
            for (entities) |raw| {
                var e = raw;
                e.org_id = org_id;
                const id = createImpl(self, e) catch |err| return http.respondErr(ctx, err);
                try ids.append(ctx.allocator, id);
            }
            try ctx.jsonStruct(200, .{ .code = 0, .ids = ids.items });
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

    pub fn list(_: *@This(), _: i64, _: usize, _: usize, _: ?data.SortSpec) !data.ResultSet(TestEntity) {
        return data.ResultSet(TestEntity).fromOwned(&[_]TestEntity{}, null);
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
    pub fn list(_: *@This(), _: i64, _: usize, _: usize, _: ?data.SortSpec) !data.ResultSet(TestEntity) {
        return data.ResultSet(TestEntity).fromOwned(&[_]TestEntity{}, null);
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

test "CrudApi bulk option adds the bulk endpoint" {
    const Api = CrudApi(TestEntity, TestService, .{ .bulk = true });
    try std.testing.expectEqual(@as(usize, 6), Api.routes.len);
    try std.testing.expectEqualStrings("bulk", Api.routes[5].path);
    try std.testing.expect(Api.routes[5].method == .POST);

    const Plain = CrudApi(TestEntity, TestService, .{});
    try std.testing.expectEqual(@as(usize, 5), Plain.routes.len);
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

test "CrudApi tenantId reads configurable tenant_attr" {
    const allocator = std.testing.allocator;
    const Api = CrudApi(TestEntity, TestService, .{ .tenant_attr = "org_id" });

    var ctx = try http.Context.init(allocator, .GET, "/widgets");
    defer ctx.deinit();
    try ctx.setAttr("org_id", "42");
    try std.testing.expectEqual(@as(i64, 42), try Api.tenantId(&ctx));

    // Default attr name is not read when overridden — unauthorized.
    var ctx2 = try http.Context.init(allocator, .GET, "/widgets");
    defer ctx2.deinit();
    try ctx2.setAttr("tenant_id", "42");
    try std.testing.expectError(error.Unauthorized, Api.tenantId(&ctx2));
}
