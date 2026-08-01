//! KPI metric queries ("经营指标"): app-registered named metrics (name →
//! SQL → value column). The `kpi.query` skill lets an Agent answer business
//! questions like "本周营收多少" — the LLM only names a metric; the query and
//! semantics stay app-owned. A programmatic `Kpi.query` is also exposed.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const sqlx = @import("../sqlx/sqlx.zig");
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const freeValue = @import("skill.zig").freeValue;

/// A named business metric. `sql` must return exactly one row; `value_column`
/// selects the numeric value.
pub const KpiMetric = struct {
    name: []const u8,
    description: []const u8,
    sql: []const u8,
    value_column: []const u8 = "value",
};

/// Capability bundle for the KPI skill bridge. The caller owns this value and
/// sets `SkillContext.userdata = &kpi_ctx` before dispatch.
pub const KpiCtx = struct {
    backend: *SqlxBackend,
    metrics: []const KpiMetric,
};

pub const KpiResult = struct {
    name: []const u8,
    value: f64,
};

/// Query one metric programmatically. The returned struct borrows `name` from
/// the metric definition (caller-owned).
pub fn query(
    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    metric: KpiMetric,
) !KpiResult {
    var cursor = try backend.client.queryCursorEx(metric.sql, &.{}, .{});
    defer cursor.deinit();
    const row = cursor.next() orelse return error.NoRows;
    if (cursor.next() != null) return error.MultipleRows;
    const v = row.get(metric.value_column) orelse return error.MissingColumn;
    const value: f64 = switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        .null => 0,
        .string, .bool => return error.InvalidMetricValue,
    };
    _ = allocator;
    return .{ .name = metric.name, .value = value };
}

/// Register `kpi.query` — an Agent names a metric and receives its value +
/// description (and the metric is guaranteed to be app-registered).
pub fn registerKpiSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "kpi.query",
        .description = "Query an app-registered business metric (e.g. daily_revenue, refund_rate); returns its value",
        .parameters = &.{
            .{ .name = "metric", .type = .string, .description = "Metric name", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const kc: *KpiCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.KpiNotConfigured));
                const obj = args.object;
                const name_v = obj.get("metric") orelse return error.InvalidArguments;
                if (name_v != .string) return error.InvalidArguments;

                var found: ?KpiMetric = null;
                for (kc.metrics) |m| {
                    if (std.mem.eql(u8, m.name, name_v.string)) {
                        found = m;
                        break;
                    }
                }
                const metric = found orelse return error.MetricNotFound;

                const res = try query(sctx.allocator, kc.backend, metric);
                var out = std.json.ObjectMap{};
                try putOwned(&out, sctx.allocator, "metric", .{ .string = try sctx.allocator.dupe(u8, res.name) });
                try putOwned(&out, sctx.allocator, "value", .{ .float = res.value });
                try putOwned(&out, sctx.allocator, "description", .{ .string = try sctx.allocator.dupe(u8, metric.description) });
                return .{ .object = out };
            }
        }.h,
    });
}

/// ObjectMap does not copy keys and deinit does not free them; results must
/// own every key so `freeValue` can release them.
fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), value);
}

test "kpi.query returns an app-registered metric" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, amount INTEGER, status TEXT)", &.{});
    _ = try client.exec("INSERT INTO orders (amount, status) VALUES (100, 'paid'), (50, 'failed')", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const metrics = [_]KpiMetric{
        .{
            .name = "paid_revenue",
            .description = "Revenue from paid orders",
            .sql = "SELECT SUM(amount) AS value FROM orders WHERE status = 'paid'",
        },
    };
    var kpi_ctx = KpiCtx{ .backend = &backend, .metrics = &metrics };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerKpiSkills(&registry);

    var sctx = SkillContext{ .allocator = a, .userdata = &kpi_ctx };
    const res = try registry.dispatch("kpi.query", &sctx, .{ .object = blk: {
        var o = std.json.ObjectMap{};
        try putOwned(&o, a, "metric", .{ .string = try a.dupe(u8, "paid_revenue") });
        break :blk o;
    } });
    defer freeValue(a, res);

    try std.testing.expectEqual(@as(f64, 100), res.object.get("value").?.float);
    try std.testing.expectEqualStrings("Revenue from paid orders", res.object.get("description").?.string);
}
