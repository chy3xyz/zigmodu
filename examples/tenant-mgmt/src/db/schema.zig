const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;

pub fn apply(client: *data.Client) !void {
    const ddl = [_][]const u8{
        \\CREATE TABLE IF NOT EXISTS tenants (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name TEXT NOT NULL,
        \\  domain TEXT NOT NULL UNIQUE,
        \\  status INTEGER NOT NULL,
        \\  tier TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\)
        ,
        \\CREATE TABLE IF NOT EXISTS users (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  tenant_id INTEGER NOT NULL,
        \\  username TEXT NOT NULL,
        \\  email TEXT NOT NULL,
        \\  password_hash TEXT NOT NULL DEFAULT '',
        \\  role TEXT NOT NULL,
        \\  status INTEGER NOT NULL,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL,
        \\  UNIQUE(tenant_id, username)
        \\)
        ,
        \\CREATE TABLE IF NOT EXISTS plans (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  name TEXT NOT NULL UNIQUE,
        \\  max_users INTEGER NOT NULL,
        \\  max_storage INTEGER NOT NULL,
        \\  price REAL NOT NULL,
        \\  created_at INTEGER NOT NULL
        \\)
        ,
        \\CREATE TABLE IF NOT EXISTS subscriptions (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  tenant_id INTEGER NOT NULL,
        \\  plan_id INTEGER NOT NULL,
        \\  status TEXT NOT NULL,
        \\  started_at INTEGER NOT NULL,
        \\  expires_at INTEGER NOT NULL,
        \\  created_at INTEGER NOT NULL
        \\)
    };
    for (ddl) |sql| _ = try client.exec(sql, &.{});

    var count_rows = try client.query("SELECT COUNT(*) AS cnt FROM plans", &.{});
    defer count_rows.deinit();
    const existing = count_rows.rows[0].get("cnt").?.int;
    if (existing > 0) return;

    const now: i64 = @intCast(zigmodu.time.monotonicNowSeconds());
    const plans = [_]struct { name: []const u8, max_users: i32, max_storage: i64, price: f64 }{
        .{ .name = "free", .max_users = 5, .max_storage = 1_073_741_824, .price = 0 },
        .{ .name = "pro", .max_users = 50, .max_storage = 10_737_418_240, .price = 29.99 },
        .{ .name = "enterprise", .max_users = 500, .max_storage = 107_374_182_400, .price = 199.99 },
    };
    for (plans) |plan| {
        _ = try client.exec(
            "INSERT INTO plans (name, max_users, max_storage, price, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            &.{
                .{ .string = plan.name },
                .{ .int = plan.max_users },
                .{ .int = plan.max_storage },
                .{ .float = plan.price },
                .{ .int = now },
            },
        );
    }
}
