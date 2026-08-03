//! Data-scope demo: a scope middleware derives the permission context and a
//! DocApi queries through a scoped zent client. The Doc schema carries
//! `zent.data_scope.Policy`, so any query without a context is denied at the
//! query layer (PrivacyDenied) - row-level filtering happens in SQL, not in
//! handlers.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const zent = @import("zent");
const persist = @import("modules/catalog/persistence.zig");

/// Public-demo middleware: reads scope params from the query string and
/// normalizes them into context attrs (real deployments source them from JWT
/// claims / role attributes instead). Mounted with Scoped.use(...).
pub fn scopeMiddleware(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
    const user_id = ctx.queryStr("user_id", "");
    const tenant_id = ctx.queryStr("tenant_id", "");
    if (user_id.len == 0 or tenant_id.len == 0) {
        try ctx.jsonStruct(401, .{ .msg = "user_id and tenant_id are required" });
        return;
    }
    try ctx.setAttr("user_id", user_id);
    try ctx.setAttr("tenant_id", tenant_id);
    try ctx.setAttr("data_scope", ctx.queryStr("scope", "self_"));
    try ctx.setAttr("self_dept_id", ctx.queryStr("self_dept_id", "0"));
    try ctx.setAttr("dept_ids", ctx.queryStr("dept_ids", ""));
    return next(ctx);
}

fn parseIntAttr(ctx: *const http.Context, key: []const u8) !i64 {
    const s = ctx.getAttr(key) orelse return error.Unauthorized;
    return std.fmt.parseInt(i64, s, 10) catch error.Unauthorized;
}

fn parseScope(s: []const u8) !zent.data_scope.DataScope {
    if (std.mem.eql(u8, s, "all")) return .all;
    if (std.mem.eql(u8, s, "self_")) return .self_;
    if (std.mem.eql(u8, s, "dept_only")) return .dept_only;
    if (std.mem.eql(u8, s, "dept_and_child")) return .dept_and_child;
    if (std.mem.eql(u8, s, "dept_custom")) return .dept_custom;
    return error.InvalidScope;
}

fn parseDeptIds(s: []const u8, buf: *[32]i64) usize {
    var it = std.mem.splitScalar(u8, s, ',');
    var n: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0 or n >= 32) continue;
        buf[n] = std.fmt.parseInt(i64, part, 10) catch continue;
        n += 1;
    }
    return n;
}

/// DocApi: GET /api/v1/docs?user_id=&tenant_id=&scope=&self_dept_id=&dept_ids=
/// The scope middleware runs first and fills the attrs; the handler builds
/// the DataScopeFilter and queries through the scoped zent client.
pub fn DocApi(comptime Client: type) type {
    return struct {
        const Self = @This();

        client: *Client,

        pub const module_name = "catalog";
        pub const nest = .{"docs"};
        pub const State = Self;

        pub fn init(client: *Client) Self {
            return .{ .client = client };
        }

        pub const routes = [_]http.RouteSpec(State){
            .{ .method = .GET, .path = "", .handler = list, .meta = .{ .auth = .public } },
        };

        fn list(ctx: *http.Context, self: *State) !void {
            const user_id = try parseIntAttr(ctx, "user_id");
            const tenant_id = try parseIntAttr(ctx, "tenant_id");
            const scope = parseScope(ctx.getAttr("data_scope") orelse "self_") catch |err| return http.respondErr(ctx, err);
            const self_dept_id = std.fmt.parseInt(i64, ctx.getAttr("self_dept_id") orelse "0", 10) catch 0;
            var dept_buf: [32]i64 = undefined;
            const dept_count = parseDeptIds(ctx.getAttr("dept_ids") orelse "", &dept_buf);

            var filter = zent.data_scope.DataScopeFilter.init("dept_id", "owner_id", scope, .{
                .user_id = user_id,
                .self_dept_id = self_dept_id,
                .dept_ids = dept_buf[0..dept_count],
            });
            const scoped_doc = self.client.*.doc.withContext(filter.context(.{ .user_id = user_id, .tenant_id = tenant_id }));

            var q = scoped_doc.Query();
            defer q.deinit();
            _ = try q.Where(.{scoped_doc.predicates.tenant_idEQ(.{ .int = tenant_id })});
            const rows = try q.All();
            defer {
                for (rows.items) |*e| zent.codegen.deinitEntity(persist.infos, persist.DocInfo, e, self.client.allocator);
                rows.deinit();
            }
            try ctx.jsonStruct(200, .{ .items = rows.items });
        }
    };
}
