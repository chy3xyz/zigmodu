//! zmsaas — database schema (orders business module + RBAC grants)
const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;

pub fn apply(client: *data.Client) !void {
    const ddl = [_][]const u8{
        \\CREATE TABLE IF NOT EXISTS orders (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  org_id INTEGER NOT NULL,
        \\  customer TEXT NOT NULL,
        \\  amount INTEGER,
        \\  status TEXT,
        \\  notes TEXT,
        \\  created_at INTEGER NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\)
        ,
        \\CREATE TABLE IF NOT EXISTS order_events (
        \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
        \\  order_id INTEGER NOT NULL,
        \\  action TEXT NOT NULL,
        \\  created_at INTEGER NOT NULL
        \\)
        ,
    };
    for (ddl) |sql| _ = try client.exec(sql, &.{});

    // Seed one org so login has data to list.
    _ = try client.exec(
        "INSERT OR IGNORE INTO orders (org_id, customer, amount, status, notes, created_at, updated_at) VALUES (1, 'acme', 9900, 'paid', 'zmsaas seed', 0, 0)",
        &.{},
    );
}

/// RBAC: role → permission grants for the orders module.
pub fn grants(client: *data.Client) !void {
    try zigmodu.security.CatalogPermDb.ensureSchema(client);
    try zigmodu.security.CatalogPermDb.grant(client, "admin", "orders:read");
    try zigmodu.security.CatalogPermDb.grant(client, "admin", "orders:write");
    try zigmodu.security.CatalogPermDb.grant(client, "owner", "orders:read");
    try zigmodu.security.CatalogPermDb.grant(client, "owner", "orders:write");
    try zigmodu.security.CatalogPermDb.grant(client, "user", "orders:read");
}
