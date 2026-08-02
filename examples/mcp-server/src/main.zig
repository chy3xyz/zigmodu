//! MCP server example: exposes the framework's AI skills over the Model
//! Context Protocol (stdio). Run it and point an MCP client (Claude Desktop,
//! Codex, ...) at `zig-out/bin/mcp-server`, or drive it with
//! scripts/mcp-client-test.py.
//!
//! Skills registered here: `kpi.query` against an in-memory SQLite dataset,
//! plus a demo `ping`. Session identity is baked into the SkillContext
//! template (tenant + permissions).

const std = @import("std");
const zigmodu = @import("zigmodu");

const ai = zigmodu.ai;

pub fn main(init: std.process.Init) !void {
    var client = zigmodu.data.sqlx.Client.init(init.gpa, init.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, tenant_id INTEGER, amount INTEGER, status TEXT)", &.{});
    _ = try client.exec("INSERT INTO orders (tenant_id, amount, status) VALUES (1, 100, 'paid'), (1, 5000, 'paid'), (2, 9000, 'paid')", &.{});
    var backend = zigmodu.data.SqlxBackend{ .allocator = init.gpa, .client = &client };

    const metrics = [_]ai.kpi.KpiMetric{
        .{ .name = "paid_revenue", .description = "paid revenue", .sql = "SELECT SUM(amount) AS value FROM orders WHERE tenant_id = 1 AND status = 'paid'" },
    };
    var kpi_ctx = ai.kpi.KpiCtx{ .backend = &backend, .metrics = &metrics };

    var registry = ai.SkillRegistry.init(init.gpa, init.io);
    defer registry.deinit();
    try ai.kpi.registerKpiSkills(&registry);
    try registry.register(.{
        .name = "ping",
        .description = "pong",
        .parameters = &.{},
        .handler = struct {
            fn h(c: *ai.SkillContext, _: std.json.Value) anyerror!std.json.Value {
                return .{ .string = try c.allocator.dupe(u8, "pong") };
            }
        }.h,
    });

    // Session identity: tenant 1; no permissions (management skills stay
    // unreachable through this MCP session).
    const ctx = ai.SkillContext{ .allocator = init.gpa, .tenant_id = 1, .userdata = &kpi_ctx };
    try ai.mcp.serveStdio(init.io, init.gpa, &registry, ctx);
}
