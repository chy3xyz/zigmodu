//! Outbox + Idempotency smoke sample (unit-level — no listen).
//! Pattern: business write + outbox insert SQL; HTTP writes guarded by Idempotency-Key.
//! See docs/FRAMEWORK_BACKLOG.md §7 and docs/MODULITH.md.

const std = @import("std");
const OutboxPublisher = @import("OutboxPublisher.zig").OutboxPublisher;
const Idempotency = @import("../http/Idempotency.zig");
const server_mod = @import("../api/Server.zig");

test "outbox migration SQL is non-empty" {
    const sql = OutboxPublisher.migrationSql();
    try std.testing.expect(std.mem.indexOf(u8, sql, "event_outbox") != null);
}

test "outbox buildInsert produces parameterized SQL" {
    const allocator = std.testing.allocator;
    var publisher = OutboxPublisher.init(allocator, .{});
    const insert = try publisher.buildInsert("orders.created", "{\"id\":1}");
    try std.testing.expect(std.mem.indexOf(u8, insert.sql, "INSERT") != null);
    try std.testing.expectEqualStrings("orders.created", insert.params.topic);
}

test "idempotency middleware replays stored response" {
    const allocator = std.testing.allocator;
    var store = Idempotency.IdempotencyStore.init(allocator, 100);
    defer store.deinit();
    try store.store("k-1", "{\"ok\":true}", 201, 3600);

    var server = server_mod.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    try server.addMiddleware(Idempotency.idempotencyMiddleware(&store));
    try server.addRoute(.{
        .method = .POST,
        .path = "orders",
        .handler = struct {
            fn handle(ctx: *server_mod.Context) !void {
                try ctx.json(200, "{\"ok\":false}"); // should not run when key hits
            }
        }.handle,
    });

    var ctx = try server_mod.Context.init(allocator, .POST, "orders");
    defer ctx.deinit();
    // Request headers are lowercase in Context (ZigModu rule).
    const hk = try allocator.dupe(u8, "idempotency-key");
    const hv = try allocator.dupe(u8, "k-1");
    try ctx.headers.put(hk, hv);

    try server.handleForTest(&ctx);
    try std.testing.expectEqual(@as(u16, 201), ctx.status_code);
    try std.testing.expectEqualStrings("{\"ok\":true}", ctx.response_body.items);
}
