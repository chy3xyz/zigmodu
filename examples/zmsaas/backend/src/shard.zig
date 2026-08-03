//! Multi-tenant shard + data-permission depth demo.
//! ShardRouter 把 org_id 路由到分片（示例用两个 sqlite 文件分片），读写都
//! 打到租户所在分片；列表按 JWT 角色做数据权限过滤（admin=全量, user=本人）。
//! 生产：分片为 PG/MySQL 时直接用 ShardRouter.buildSqlxConfig(pool) 建连接。
const std = @import("std");
const zigmodu = @import("zigmodu");

const ShardOrder = struct {
    id: i64 = 0,
    org_id: i64 = 0,
    owner_id: i64 = 0,
    region: []const u8 = "",
    customer: []const u8 = "",
    amount: i64 = 0,
};

pub const ShardApi = struct {
    pub const module_name = "shard";
    pub const nest = .{"shard"};
    pub const State = @This();

    allocator: std.mem.Allocator,
    router: zigmodu.ShardRouter,
    paths: [2][]const u8,
    clients: [2]zigmodu.data.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8) !@This() {
        std.Io.Dir.cwd().createDirPath(io, base_dir) catch {};
        var paths: [2][]const u8 = undefined;
        var clients: [2]zigmodu.data.Client = undefined;
        for (0..2) |i| {
            const suffix = if (i == 0) "shard_a.db" else "shard_b.db";
            paths[i] = try std.fs.path.join(allocator, &.{ base_dir, suffix });
            clients[i] = zigmodu.data.Client.init(allocator, io, .{ .driver = .sqlite, .sqlite_path = paths[i] });
            try clients[i].connect();
            _ = try clients[i].exec(
                \\CREATE TABLE IF NOT EXISTS shard_orders (
                \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
                \\  org_id INTEGER NOT NULL,
                \\  owner_id INTEGER NOT NULL,
                \\  region TEXT NOT NULL,
                \\  customer TEXT NOT NULL,
                \\  amount INTEGER NOT NULL
                \\)
            ,
                &.{},
            );
        }
        var router = zigmodu.ShardRouter.init(allocator, .{ .shard_count = 2 });
        const pools = try allocator.alloc(zigmodu.ShardPool, 2);
        pools[0] = .{ .name = "shard_a", .host = "sqlite", .port = 0, .database = paths[0], .username = "", .password = "", .max_conns = 4 };
        pools[1] = .{ .name = "shard_b", .host = "sqlite", .port = 0, .database = paths[1], .username = "", .password = "", .max_conns = 4 };
        try router.setPools(pools);
        try router.assignTenant(1, 0);
        try router.assignTenant(2, 1);
        return .{ .allocator = allocator, .router = router, .paths = paths, .clients = clients };
    }

    fn shardFor(self: *@This(), org_id: i64) ?u16 {
        var tctx = zigmodu.TenantContext{};
        tctx.set(org_id);
        return self.router.route(&tctx);
    }

    pub const routes = [_]zigmodu.http.RouteSpec(State){
        .{ .method = .GET, .path = "route", .handler = routeInfo, .meta = .{ .auth = .jwt, .permission = "orders:read" } },
        .{ .method = .POST, .path = "orders", .handler = createOrder, .meta = .{ .auth = .jwt, .permission = "orders:write" } },
        .{ .method = .GET, .path = "orders", .handler = listOrders, .meta = .{ .auth = .jwt, .permission = "orders:read" } },
    };

    fn routeInfo(ctx: *zigmodu.http.Context, self: *State) !void {
        const org_id = ctx.queryInt(i64, "org_id", 1);
        const idx = self.shardFor(org_id) orelse return error.NotFound;
        const pool = self.router.getPool(idx) orelse return error.NotFound;
        try ctx.jsonStruct(200, .{ .code = 0, .org_id = org_id, .pool_index = idx, .database = pool.database });
    }

    fn createOrder(ctx: *zigmodu.http.Context, self: *State) !void {
        const org_id = ctx.queryInt(i64, "org_id", 1);
        const idx = self.shardFor(org_id) orelse return error.NotFound;
        const client = &self.clients[idx];
        const result = try client.exec("INSERT INTO shard_orders (org_id, owner_id, region, customer, amount) VALUES (?, ?, ?, ?, ?)", &.{
            .{ .int = org_id },
            .{ .int = ctx.queryInt(i64, "owner", 0) },
            .{ .string = ctx.queryStr("region", "cn") },
            .{ .string = ctx.queryStr("customer", "") },
            .{ .int = ctx.queryInt(i64, "amount", 0) },
        });
        try ctx.jsonStruct(200, .{ .code = 0, .shard = idx, .id = result.last_insert_id orelse 0 });
    }

    fn listOrders(ctx: *zigmodu.http.Context, self: *State) !void {
        const org_id = ctx.queryInt(i64, "org_id", 1);
        const idx = self.shardFor(org_id) orelse return error.NotFound;
        const client = &self.clients[idx];

        // 数据权限：JWT roles → DataPermissionContext → buildWhere(region, owner_id)。
        // admin → .all → 无过滤；user → .self_ → owner_id = JWT sub。
        const roles_csv = ctx.getAttr("roles") orelse "";
        const user_id = std.fmt.parseInt(i64, ctx.getAttr("user_id") orelse "0", 10) catch 0;
        const scope: zigmodu.security.Rbac.DataScope = if (std.mem.indexOf(u8, roles_csv, "admin") != null) .all else .self_;
        const roles = [_]zigmodu.security.Rbac.Role{
            .{
                .id = 1,
                .name = "r",
                .code = "r",
                .sort = 0,
                .status = 1,
                .type = 1,
                .remark = "",
                .data_scope = scope,
                .data_scope_dept_ids = null,
                .tenant_id = org_id,
            },
        };
        var dp = zigmodu.datapermission.DataPermissionContext.fromRoles(ctx.allocator, &roles, 0, user_id);
        defer dp.deinit();
        const filter = dp.buildWhere(ctx.allocator, "region", "owner_id");
        // NOTE: .all/.self_ 子句是 comptime 静态串（不可 free）；只有
        // .dept_custom 走 allocPrint，arena 回收即可。

        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(ctx.allocator);
        try sql.appendSlice(ctx.allocator, "SELECT id, org_id, owner_id, region, customer, amount FROM shard_orders WHERE org_id = ?");
        if (filter) |f| {
            try sql.appendSlice(ctx.allocator, " AND ");
            try sql.appendSlice(ctx.allocator, f.clause);
        }
        try sql.appendSlice(ctx.allocator, " ORDER BY id DESC");

        var args = std.ArrayList(zigmodu.data.sqlx.Value).empty;
        defer args.deinit(ctx.allocator);
        try args.append(ctx.allocator, .{ .int = org_id });
        if (filter) |f| {
            for (f.params) |p| try args.append(ctx.allocator, .{ .int = p });
        }

        var result = try client.queryRows(ShardOrder, sql.items, args.items);
        defer result.deinit(ctx.allocator);
        try ctx.jsonStruct(200, .{ .code = 0, .shard = idx, .items = result.items });
    }
};
