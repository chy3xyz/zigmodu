//! zmsaas — versioned schema (MigrationRunner) + RBAC grants.
//! DDL 走框架 MigrationRunner（history 表 + checksum），不再手写 apply 循环。
const std = @import("std");
const zigmodu = @import("zigmodu");
const data = zigmodu.data;

pub fn apply(client: *data.Client, allocator: std.mem.Allocator, io: std.Io) !void {
    var runner = data.MigrationRunner.init(allocator);
    defer runner.deinit();
    // Rolling deploys start several replicas at once: without this guard two of
    // them can apply the same DDL concurrently. TTL covers the slowest
    // migration; a crashed holder's lock is reaped after it elapses.
    var migration_lock = try zigmodu.DistributedLock.SqlLock(@TypeOf(client.*)).init(
        allocator,
        io,
        client,
        "zigmodu_migration_lock",
        .sqlite,
    );
    defer migration_lock.deinit();
    runner.setLock(migration_lock.lock(), 300_000);
    try runner.addMigration(1, "orders", @embedFile("migrations/V1__orders.sql"));
    try runner.addMigration(2, "order_events", @embedFile("migrations/V2__order_events.sql"));
    try runner.addMigration(3, "event_outbox", @embedFile("migrations/V3__event_outbox.sql"));
    try runner.addMigration(4, "rebalance_events", @embedFile("migrations/V4__rebalance_events.sql"));
    try runner.run(client);

    // Lock released here (runner.run returned) — seeding is idempotent.

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
