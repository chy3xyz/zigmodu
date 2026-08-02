//! `http.CrudApi(Entity, Service, opts)` — one declaration generates the whole
//! org-scoped CRUD surface (list/get/create/update/delete) with JWT/permission
//! metas, `PageParams` clamping and a configurable paged envelope. Service
//! must expose duck-typed `list/get/create/update/delete` (see
//! `data.CrudService` for the generic implementation) plus
//! `module_name`/`nest` consts.

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

        fn list(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const params = page_mod.PageParams.parse(ctx, .{});
            var items = try self.service.list(ctx.allocator, org_id, params.page, params.page_size);
            defer items.deinit(ctx.allocator);
            try page_mod.sendPaged(ctx, items.items, items.items.len, params, opts.envelope);
        }

        fn get(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            const entity = try self.service.get(ctx.allocator, org_id, id);
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
            const id = try self.service.create(entity);
            try ctx.jsonStruct(200, .{ .code = 0, .id = id });
        }

        fn update(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            var entity = ctx.bindJson(Entity) catch return ctx.jsonStruct(400, .{ .code = 400, .msg = "invalid body" });
            entity.id = id;
            entity.org_id = org_id;
            try self.service.update(entity, org_id);
            try ctx.jsonStruct(200, .{ .code = 0 });
        }

        fn remove(ctx: *http.Context, self: *State) !void {
            const org_id = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            try self.service.delete(org_id, id);
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

test "CrudApi generates five routes with permission metas" {
    const Api = CrudApi(TestEntity, TestService, .{});
    try std.testing.expectEqual(@as(usize, 5), Api.routes.len);
    try std.testing.expect(Api.routes[0].method == .GET);
    try std.testing.expect(Api.routes[1].method == .POST);
    try std.testing.expectEqualStrings("widgets:read", Api.routes[0].meta.permission.?);
    try std.testing.expectEqualStrings("widgets:write", Api.routes[1].meta.permission.?);
    try std.testing.expect(Api.routes[0].meta.auth == .jwt);
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
