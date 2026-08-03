//! zmsaas — versioned schema (MigrationRunner) + RBAC grants.
//! DDL 走框架 MigrationRunner（history 表 + checksum），不再手写 apply 循环。
const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;

pub fn apply(client: *data.Client, allocator: std.mem.Allocator) !void {
    var runner = data.MigrationRunner.init(allocator);
    defer runner.deinit();
    try runner.addMigration(1, "orders", @embedFile("migrations/V1__orders.sql"));
    try runner.addMigration(2, "order_events", @embedFile("migrations/V2__order_events.sql"));
    try runner.addMigration(3, "event_outbox", @embedFile("migrations/V3__event_outbox.sql"));
    try runner.addMigration(4, "rebalance_events", @embedFile("migrations/V4__rebalance_events.sql"));
    try runner.run(client);

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
