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
    /// 迁移时记录源分片行 id（行级幂等：唯一索引 (org_id, source_id)）。
    source_id: ?i64 = null,
};

const RebalanceEvent = struct {
    org_id: i64,
    from_shard: i64,
    to_shard: i64,
    migrated: i64,
};

pub const ShardApi = struct {
    pub const module_name = "shard";
    pub const nest = .{"shard"};
    pub const State = @This();

    allocator: std.mem.Allocator,
    router: zigmodu.ShardRouter,
    paths: [2][]const u8,
    clients: [2]zigmodu.data.Client,
    meta_client: *zigmodu.data.Client,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, base_dir: []const u8, meta_client: *zigmodu.data.Client) !@This() {
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
                \\  amount INTEGER NOT NULL,
                \\  source_id INTEGER
                \\)
            ,
                &.{},
            );
            _ = try clients[i].exec(
                \\CREATE UNIQUE INDEX IF NOT EXISTS idx_shard_orders_org_source
                \\ON shard_orders (org_id, source_id) WHERE source_id IS NOT NULL
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
        return .{ .allocator = allocator, .router = router, .paths = paths, .clients = clients, .meta_client = meta_client };
    }

    fn shardFor(self: *@This(), org_id: i64) ?u16 {
        var tctx = zigmodu.TenantContext{};
        tctx.set(org_id);
        return self.router.route(&tctx);
    }

    pub const routes = [_]zigmodu.http.RouteSpec(State){
        .{ .method = .GET, .path = "route", .handler = routeInfo, .meta = .{ .auth = .jwt, .permission = "orders:read" } },
        .{ .method = .GET, .path = "load", .handler = shardLoad, .meta = .{ .auth = .jwt, .permission = "orders:read" } },
        .{ .method = .POST, .path = "rebalance", .handler = rebalance, .meta = .{ .auth = .jwt, .permission = "orders:write" } },
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

        // 数据权限：中间件解析 data_scope attr，这里构建 DataPermissionContext
        // 并用框架 DataPermissionInterceptor 在 SQL 层注入 scope 子句——
        // handler 不再手写 " AND owner_id = ?"。
        const scope = ctx.getAttr("data_scope") orelse "all";
        const user_id = std.fmt.parseInt(i64, ctx.getAttr("user_id") orelse "0", 10) catch 0;
        var dp = zigmodu.datapermission.DataPermissionContext{ .allocator = ctx.allocator };
        defer dp.deinit();
        dp.scope = if (std.mem.eql(u8, scope, "self")) .self_ else .all;
        dp.user_id = user_id;
        var interceptor = zigmodu.datapermission.DataPermissionInterceptor.init(ctx.allocator);
        const filter = try interceptor.andWhere(&dp, "region", "owner_id");

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

    fn countOrders(client: *zigmodu.data.Client) !i64 {
        return (try client.queryRow(struct { total: i64 }, "SELECT COUNT(*) AS total FROM shard_orders", &.{})).total;
    }

    fn shardLoad(ctx: *zigmodu.http.Context, self: *State) !void {
        const a = try countOrders(&self.clients[0]);
        const b = try countOrders(&self.clients[1]);
        try ctx.jsonStruct(200, .{ .code = 0, .shards = .{ .shard_a = a, .shard_b = b } });
    }

    /// 负载驱动的再平衡：把 org_id 迁移到更轻的分片（数据随迁）。
    /// 稳定规则：仅当 `目标行数 + 本租户行数 < 当前行数`（迁移真正改善负载）
    /// 才迁移，否则保持现状——避免整租户移动在双分片间来回振荡。
    /// 幂等：`key` 参数 + rebalance_events 表防止同一键重复整轮迁移；
    /// 行级用 (org_id, source_id) 唯一索引 + INSERT OR IGNORE，部分失败重试
    /// 不会重复写入（migrated 只统计实际新插入）。
    fn rebalance(ctx: *zigmodu.http.Context, self: *State) !void {
        const org_id = ctx.queryInt(i64, "org_id", 1);
        const key = ctx.queryStr("key", "");
        if (key.len > 0) {
            if (try self.findRebalance(key)) |ev| {
                try ctx.jsonStruct(200, .{ .code = 0, .org_id = ev.org_id, .from = ev.from_shard, .to = ev.to_shard, .migrated = ev.migrated, .balanced = true, .idempotent = true });
                return;
            }
        }
        const from = self.shardFor(org_id) orelse return error.NotFound;
        const cnt_a = try countOrders(&self.clients[0]);
        const cnt_b = try countOrders(&self.clients[1]);
        const to: u16 = if (cnt_b < cnt_a) 1 else 0;
        const n_rows = try countOrdersFor(&self.clients[from], org_id);
        const from_count = if (from == 0) cnt_a else cnt_b;
        const to_count = if (to == 0) cnt_a else cnt_b;
        if (to == from or to_count + n_rows >= from_count) {
            if (key.len > 0) try self.recordRebalance(key, org_id, from, to, 0);
            try ctx.jsonStruct(200, .{ .code = 0, .org_id = org_id, .from = from, .to = to, .migrated = 0, .balanced = true });
            return;
        }
        var rows = try self.clients[from].queryRows(ShardOrder, "SELECT id, org_id, owner_id, region, customer, amount FROM shard_orders WHERE org_id = ?", &.{.{ .int = org_id }});
        defer rows.deinit(ctx.allocator);
        var migrated: usize = 0;
        for (rows.items) |r| {
            const ins = try self.clients[to].exec("INSERT OR IGNORE INTO shard_orders (org_id, owner_id, region, customer, amount, source_id) VALUES (?, ?, ?, ?, ?, ?)", &.{
                .{ .int = r.org_id },
                .{ .int = r.owner_id },
                .{ .string = r.region },
                .{ .string = r.customer },
                .{ .int = r.amount },
                .{ .int = r.id },
            });
            migrated += @intCast(ins.rows_affected);
        }
        _ = try self.clients[from].exec("DELETE FROM shard_orders WHERE org_id = ?", &.{.{ .int = org_id }});
        try self.router.assignTenant(org_id, to);
        if (key.len > 0) try self.recordRebalance(key, org_id, from, to, @intCast(migrated));
        try ctx.jsonStruct(200, .{ .code = 0, .org_id = org_id, .from = from, .to = to, .migrated = migrated, .balanced = true });
    }

    fn countOrdersFor(client: *zigmodu.data.Client, org_id: i64) !i64 {
        return (try client.queryRow(struct { total: i64 }, "SELECT COUNT(*) AS total FROM shard_orders WHERE org_id = ?", &.{.{ .int = org_id }})).total;
    }

    fn findRebalance(self: *@This(), key: []const u8) !?RebalanceEvent {
        return self.meta_client.queryRow(RebalanceEvent, "SELECT org_id, from_shard, to_shard, migrated FROM rebalance_events WHERE idempotency_key = ?", &.{.{ .string = key }}) catch |err| switch (err) {
            error.NotFound => null,
            else => return err,
        };
    }

    fn recordRebalance(self: *@This(), key: []const u8, org_id: i64, from: u16, to: u16, migrated: usize) !void {
        _ = try self.meta_client.exec("INSERT OR IGNORE INTO rebalance_events (idempotency_key, org_id, from_shard, to_shard, migrated, created_at) VALUES (?, ?, ?, ?, ?, ?)", &.{
            .{ .string = key },
            .{ .int = org_id },
            .{ .int = from },
            .{ .int = to },
            .{ .int = @intCast(migrated) },
            .{ .int = zigmodu.Time.monotonicNowSeconds() },
        });
    }
};
