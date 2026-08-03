//! zent-backed generic CRUD API - the schema-as-code counterpart of
//! `zigmodu.http.CrudApi` (sqlx). One declaration generates the standard
//! five ComptimeRouter routes (list / create / get / update / delete) over a
//! `zent.crud.CrudService`, with tenant scoping and PageParams clamping.
//!
//! Usage (see main.zig / modules/catalog):
//!   pub const ProductApi = zent_crud.CrudApi(infos, ProductInfo, .{
//!       .module_name = "catalog",
//!       .nest = .{"products"},
//!       .tenant_col = "tenant_id",
//!       .tenant_source = .query, // or .attr (JWT middleware writes it)
//!   });
//!   // main: ProductApi.init(&product_crud) where product_crud is a
//!   // zent.crud.CrudService(infos, ProductInfo, "tenant_id").
//!
//! Custom endpoints live in a sibling Api type with the same module_name/nest
//! - the framework's assertNoDupes only rejects duplicate method+path pairs,
//! so bespoke handlers (search, counts, bulk, SSE) coexist with the generic
//! CRUD surface.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const zent = @import("zent");

pub const TenantSource = enum {
    /// Read `tenant_id` from the request context attr (JWT middleware).
    attr,
    /// Read `tenant_id` from the query string (public/API-key demos).
    query,
};

pub const CrudApiOpts = struct {
    module_name: []const u8,
    nest: []const []const u8 = &.{},
    tenant_col: []const u8 = "tenant_id",
    tenant_source: TenantSource = .attr,
    /// Permission base (default: module_name) -> "<base>:read"/"<base>:write".
    permission: ?[]const u8 = null,
    public: bool = false,
    default_page_size: usize = 20,
    max_page_size: usize = 100,
};

pub fn CrudApi(
    comptime infos: []const zent.codegen.graph.TypeInfo,
    comptime info: zent.codegen.graph.TypeInfo,
    comptime opts: CrudApiOpts,
) type {
    const Entity = zent.codegen.entity(infos, info);
    const Service = zent.crud.CrudService(infos, info, opts.tenant_col);

    // Request body = entity minus `id` and the tenant column (both are
    // derived: id from insert/update, tenant from the request context).
    const Body = comptime blk: {
        var count: usize = 0;
        for (info.fields) |f| {
            if (!f.is_id and !std.mem.eql(u8, f.name, opts.tenant_col)) count += 1;
        }
        var names: [count][:0]const u8 = undefined;
        var types: [count]type = undefined;
        var attrs: [count]std.builtin.Type.Struct.FieldAttributes = undefined;
        var i: usize = 0;
        for (info.fields) |f| {
            if (f.is_id or std.mem.eql(u8, f.name, opts.tenant_col)) continue;
            names[i] = (f.name)[0..f.name.len :0];
            types[i] = if (f.optional) ?f.zig_type else f.zig_type;
            attrs[i] = .{
                // @Struct fields with a null default are treated as required
                // by std.json - optional fields need an explicit null default.
                .default_value_ptr = if (f.optional)
                    @ptrCast(&@as(?f.zig_type, null))
                else
                    null,
                .@"comptime" = false,
                .@"align" = @alignOf(types[i]),
            };
            i += 1;
        }
        break :blk @Struct(.auto, null, names[0..count], types[0..count], attrs[0..count]);
    };

    return struct {
        const Self = @This();

        svc: *Service,

        pub const module_name = opts.module_name;
        pub const nest = opts.nest;
        pub const State = Self;

        pub fn init(svc: *Service) Self {
            return .{ .svc = svc };
        }

        const auth = if (opts.public) .public else .jwt;
        const base_perm = opts.permission orelse opts.module_name;
        const read_meta = http.RouteMeta{ .auth = auth, .permission = if (opts.public) null else base_perm ++ ":read" };
        const write_meta = http.RouteMeta{ .auth = auth, .permission = if (opts.public) null else base_perm ++ ":write" };

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = list, .meta = read_meta },
            .{ .method = .POST, .path = "", .handler = create, .meta = write_meta },
            .{ .method = .GET, .path = "{id}", .handler = get, .meta = read_meta },
            .{ .method = .PUT, .path = "{id}", .handler = update, .meta = write_meta },
            .{ .method = .DELETE, .path = "{id}", .handler = remove, .meta = write_meta },
        };

        fn tenantId(ctx: *http.Context) !i64 {
            switch (opts.tenant_source) {
                .attr => {
                    const s = ctx.getAttr(opts.tenant_col) orelse return error.Unauthorized;
                    return std.fmt.parseInt(i64, s, 10) catch error.Unauthorized;
                },
                .query => {
                    const v = ctx.queryInt(i64, opts.tenant_col, 0);
                    if (v <= 0) return error.Unauthorized;
                    return v;
                },
            }
        }

        fn buildEntity(tenant_id: i64, body: Body) Entity {
            var e: Entity = undefined;
            e.id = 0;
            @field(e, opts.tenant_col) = tenant_id;
            // Body is exactly "entity minus id minus tenant" by construction.
            inline for (comptime std.meta.fieldNames(Body)) |fname| {
                @field(e, fname) = @field(body, fname);
            }
            return e;
        }

        fn list(ctx: *http.Context, self: *State) !void {
            const tenant = try tenantId(ctx);
            const params = http.PageParams.parse(ctx, .{
                .default_page_size = opts.default_page_size,
                .max_page_size = opts.max_page_size,
            });
            var paged = self.svc.list(tenant, params.page, params.page_size) catch |err| return http.respondErr(ctx, err);
            defer paged.deinit();
            try http.sendPaged(ctx, paged.items.items, @intCast(paged.total), params, .items);
        }

        fn create(ctx: *http.Context, self: *State) !void {
            const tenant = try tenantId(ctx);
            const body = ctx.bindJson(Body) catch |err| return http.respondErr(ctx, err);
            const id = self.svc.create(buildEntity(tenant, body)) catch |err| return http.respondErr(ctx, err);
            try ctx.jsonStruct(201, .{ .id = id });
        }

        fn get(ctx: *http.Context, self: *State) !void {
            const tenant = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            var found = self.svc.get(ctx.allocator, tenant, id) catch |err| return http.respondErr(ctx, err);
            // NOTE: defer must be at function scope — a defer inside the
            // `if` body runs before jsonStruct below and would serialize
            // already-freed strings (visible as garbage names in responses).
            defer if (found) |*e| zent.codegen.deinitEntity(infos, info, e, ctx.allocator);
            if (found) |e| {
                try ctx.jsonStruct(200, e);
            } else {
                return http.respondErr(ctx, error.NotFound);
            }
        }

        fn update(ctx: *http.Context, self: *State) !void {
            const tenant = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            const body = ctx.bindJson(Body) catch |err| return http.respondErr(ctx, err);
            var e = buildEntity(tenant, body);
            e.id = id;
            const ok = self.svc.update(e, tenant) catch |err| return http.respondErr(ctx, err);
            if (!ok) return http.respondErr(ctx, error.NotFound);
            try ctx.jsonStruct(200, .{ .ok = true });
        }

        fn remove(ctx: *http.Context, self: *State) !void {
            const tenant = try tenantId(ctx);
            const id = try ctx.paramInt(i64, "id");
            const ok = self.svc.delete(tenant, id) catch |err| return http.respondErr(ctx, err);
            if (!ok) return http.respondErr(ctx, error.NotFound);
            try ctx.jsonStruct(200, .{ .ok = true });
        }
    };
}
