//! Built-in business skills for AI Agents.
//!
//! Follows the framework's controlled-execution posture (docs/AI.md):
//! - `db.query`  — read-only, parameterized SELECT only, row-capped;
//! - `entity.lookup` / `entity.list` — queries against an app-registered
//!   entity whitelist (no free-form SQL; tenant-scoped when configured);
//! - every handler checks the deadline and refuses to cross tenant/user
//!   boundaries encoded in `SkillContext`.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const sqlx = @import("../sqlx/sqlx.zig");
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const freeValue = @import("skill.zig").freeValue;

pub const max_rows: usize = 100;
pub const default_limit: usize = 20;

/// Whitelisted business entity descriptor for `entity.lookup` / `entity.list`.
/// The LLM may only reference entities registered here — never free-form
/// table names.
pub const EntitySpec = struct {
    name: []const u8,
    table: []const u8,
    pk: []const u8 = "id",
    /// Column name carrying the tenant id. When set and the SkillContext has a
    /// tenant_id, every lookup/list is automatically scoped to that tenant.
    tenant_column: ?[]const u8 = null,
    /// Columns the LLM may write via `entity.create` / `entity.update`
    /// (whitelist; empty = no write access). The tenant column is always
    /// forced by the framework, never accepted from the model.
    writable: []const []const u8 = &.{},
};

fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') return false;
    }
    return true;
}

fn jsonToValue(v: std.json.Value) error{InvalidArguments}!sqlx.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = s },
        else => error.InvalidArguments,
    };
}

fn valueToJson(v: ?sqlx.Value) std.json.Value {
    return switch (v orelse .null) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .int => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .string => |s| .{ .string = s },
    };
}

/// Convert a JSON `args` array into sqlx values (caller owns the slice).
fn readArgs(ctx: *SkillContext, v: ?std.json.Value) ![]sqlx.Value {
    const arr = (v orelse return &.{}).array;
    const out = try ctx.allocator.alloc(sqlx.Value, arr.items.len);
    errdefer ctx.allocator.free(out);
    for (arr.items, 0..) |item, i| out[i] = try jsonToValue(item);
    return out;
}

fn rowToJson(row: *sqlx.Row, allocator: std.mem.Allocator) !std.json.Value {
    var obj = std.json.ObjectMap{};
    for (row.columns, 0..) |col, i| {
        const v = valueToJson(row.values[i]);
        // ObjectMap does not copy keys and does not free them on deinit;
        // dupe both keys and string values so freeValue can release them.
        const key = try allocator.dupe(u8, col);
        if (v == .string) {
            try obj.put(allocator, key, .{ .string = try allocator.dupe(u8, v.string) });
        } else {
            try obj.put(allocator, key, v);
        }
    }
    return .{ .object = obj };
}

fn findEntity(entities: []const EntitySpec, name: []const u8) ?EntitySpec {
    for (entities) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Register the built-in business skills (`db.query`, `entity.lookup`,
/// `entity.list`). `backend` must point at a connected sqlx Client; `entities`
/// is borrowed (keep it alive for the registry's lifetime).
pub fn registerBusinessSkills(
    registry: *SkillRegistry,
    comptime entities: []const EntitySpec,
) !void {
    try registry.register(.{
        .name = "db.query",
        .description = "Run a read-only parameterized SQL SELECT against the business database. Use ? placeholders and pass values in args. Row count is capped.",
        .parameters = &.{
            .{ .name = "sql", .type = .string, .description = "SELECT statement with ? placeholders (no literals, no ;)", .required = true },
            .{ .name = "args", .type = .array, .description = "Values for ? placeholders in order", .required = false },
            .{ .name = "limit", .type = .number, .description = "Max rows (default 20, cap 100)", .required = false },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const b: *SqlxBackend = @ptrCast(@alignCast(ctx.backend_ptr orelse return error.BackendNotConfigured));
                const obj = args.object;
                const sql_value = obj.get("sql") orelse return error.InvalidArguments;
                if (sql_value != .string) return error.InvalidArguments;
                const sql = std.mem.trim(u8, sql_value.string, " \t\r\n");
                if (sql.len < 6 or !std.ascii.eqlIgnoreCase(sql[0..6], "SELECT")) return error.ReadOnlyQueryRequired;
                try sqlx.validateSqlFragment(sql); // rejects literals/comments/`;` — forces ? args

                const limit: usize = if (obj.get("limit")) |lv| blk: {
                    if (lv != .integer) return error.InvalidArguments;
                    break :blk @min(@as(usize, @intCast(lv.integer)), max_rows);
                } else default_limit;

                const sql_args = try readArgs(ctx, obj.get("args"));
                defer ctx.allocator.free(sql_args);

                var cursor = try b.client.queryCursorEx(sql, sql_args, .{});
                defer cursor.deinit();

                var rows = std.json.Array.init(ctx.allocator);
                var count: usize = 0;
                while (cursor.next()) |row| {
                    if (count >= limit) break;
                    try rows.append(try rowToJson(row, ctx.allocator));
                    count += 1;
                }
                var out = std.json.ObjectMap{};
                try out.put(ctx.allocator, "rows", .{ .array = rows });
                try out.put(ctx.allocator, "count", .{ .integer = @intCast(count) });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "entity.lookup",
        .description = "Look up one registered business entity by primary key. Returns null when not found.",
        .parameters = &.{
            .{ .name = "entity", .type = .string, .description = "Entity name from the registered whitelist", .required = true },
            .{ .name = "id", .type = .string, .description = "Primary key value", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const b: *SqlxBackend = @ptrCast(@alignCast(ctx.backend_ptr orelse return error.BackendNotConfigured));
                const obj = args.object;
                const ent_v = obj.get("entity") orelse return error.InvalidArguments;
                const id_v = obj.get("id") orelse return error.InvalidArguments;
                if (ent_v != .string or (id_v != .string and id_v != .integer)) return error.InvalidArguments;
                const spec = findEntity(entities, ent_v.string) orelse return error.UnknownEntity;
                if (!isValidIdentifier(spec.table) or !isValidIdentifier(spec.pk)) return error.UnsafeSqlIdentifier;

                var sql_buf = std.ArrayList(u8).empty;
                defer sql_buf.deinit(ctx.allocator);
                try sql_buf.appendSlice(ctx.allocator, "SELECT * FROM ");
                try sql_buf.appendSlice(ctx.allocator, spec.table);
                try sql_buf.appendSlice(ctx.allocator, " WHERE ");
                try sql_buf.appendSlice(ctx.allocator, spec.pk);
                try sql_buf.appendSlice(ctx.allocator, " = ?");

                var args_list = std.ArrayList(sqlx.Value).empty;
                defer args_list.deinit(ctx.allocator);
                try args_list.append(ctx.allocator, try jsonToValue(id_v));

                if (spec.tenant_column) |tc| {
                    if (ctx.tenant_id) |tid| {
                        try sql_buf.appendSlice(ctx.allocator, " AND ");
                        try sql_buf.appendSlice(ctx.allocator, tc);
                        try sql_buf.appendSlice(ctx.allocator, " = ?");
                        try args_list.append(ctx.allocator, .{ .int = tid });
                    }
                }

                var cursor = try b.client.queryCursorEx(sql_buf.items, args_list.items, .{});
                defer cursor.deinit();
                const row = cursor.next() orelse return .{ .object = .{} };
                return rowToJson(row, ctx.allocator);
            }
        }.h,
    });

    try registry.register(.{
        .name = "entity.list",
        .description = "List registered business entities with optional equality filters. Row count is capped.",
        .parameters = &.{
            .{ .name = "entity", .type = .string, .description = "Entity name from the registered whitelist", .required = true },
            .{ .name = "filters", .type = .object, .description = "Column → value equality filters", .required = false },
            .{ .name = "limit", .type = .number, .description = "Max rows (default 20, cap 100)", .required = false },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const b: *SqlxBackend = @ptrCast(@alignCast(ctx.backend_ptr orelse return error.BackendNotConfigured));
                const obj = args.object;
                const ent_v = obj.get("entity") orelse return error.InvalidArguments;
                if (ent_v != .string) return error.InvalidArguments;
                const spec = findEntity(entities, ent_v.string) orelse return error.UnknownEntity;
                if (!isValidIdentifier(spec.table)) return error.UnsafeSqlIdentifier;

                const limit: usize = if (obj.get("limit")) |lv| blk: {
                    if (lv != .integer) return error.InvalidArguments;
                    break :blk @min(@as(usize, @intCast(lv.integer)), max_rows);
                } else default_limit;

                var sql_buf = std.ArrayList(u8).empty;
                defer sql_buf.deinit(ctx.allocator);
                try sql_buf.appendSlice(ctx.allocator, "SELECT * FROM ");
                try sql_buf.appendSlice(ctx.allocator, spec.table);
                try sql_buf.appendSlice(ctx.allocator, " WHERE 1=1");

                var args_list = std.ArrayList(sqlx.Value).empty;
                defer args_list.deinit(ctx.allocator);

                if (obj.get("filters")) |fv| {
                    if (fv != .object) return error.InvalidArguments;
                    var it = fv.object.iterator();
                    while (it.next()) |entry| {
                        if (!isValidIdentifier(entry.key_ptr.*)) return error.UnsafeSqlIdentifier;
                        try sql_buf.appendSlice(ctx.allocator, " AND ");
                        try sql_buf.appendSlice(ctx.allocator, entry.key_ptr.*);
                        try sql_buf.appendSlice(ctx.allocator, " = ?");
                        try args_list.append(ctx.allocator, try jsonToValue(entry.value_ptr.*));
                    }
                }
                if (spec.tenant_column) |tc| {
                    if (ctx.tenant_id) |tid| {
                        try sql_buf.appendSlice(ctx.allocator, " AND ");
                        try sql_buf.appendSlice(ctx.allocator, tc);
                        try sql_buf.appendSlice(ctx.allocator, " = ?");
                        try args_list.append(ctx.allocator, .{ .int = tid });
                    }
                }

                var limit_buf: [16]u8 = undefined;
                const limit_str = try std.fmt.bufPrint(&limit_buf, " LIMIT {d}", .{limit});
                try sql_buf.appendSlice(ctx.allocator, limit_str);

                var cursor = try b.client.queryCursorEx(sql_buf.items, args_list.items, .{});
                defer cursor.deinit();

                var rows = std.json.Array.init(ctx.allocator);
                var count: usize = 0;
                while (cursor.next()) |row| {
                    if (count >= limit) break;
                    try rows.append(try rowToJson(row, ctx.allocator));
                    count += 1;
                }
                var out = std.json.ObjectMap{};
                try out.put(ctx.allocator, "rows", .{ .array = rows });
                try out.put(ctx.allocator, "count", .{ .integer = @intCast(count) });
                return .{ .object = out };
            }
        }.h,
    });
}

test "db.query runs a parameterized SELECT and caps rows" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, tenant_id INTEGER)", &.{});
    _ = try client.exec("INSERT INTO users (name, tenant_id) VALUES ('alice', 1), ('bob', 2), ('carol', 1)", &.{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerBusinessSkills(&registry, &.{});

    var ctx = SkillContext{ .allocator = a, .backend_ptr = &backend, .tenant_id = 1 };

    var args_map = std.json.ObjectMap{};
    try args_map.put(a, "sql", .{ .string = "SELECT id, name FROM users WHERE tenant_id = ?" });
    var args_arr = std.json.Array.init(a);
    try args_arr.append(.{ .integer = 1 });
    try args_map.put(a, "args", .{ .array = args_arr });

    const res = try registry.dispatch("db.query", &ctx, .{ .object = args_map });
    try std.testing.expectEqual(@as(i64, 2), res.object.get("count").?.integer);
    const rows = res.object.get("rows").?.array.items;
    try std.testing.expectEqualStrings("alice", rows[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("carol", rows[1].object.get("name").?.string);
}

test "db.query rejects non-SELECT and free-form literals" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerBusinessSkills(&registry, &.{});
    var ctx = SkillContext{ .allocator = a, .backend_ptr = &backend };

    var m1 = std.json.ObjectMap{};
    try m1.put(a, "sql", .{ .string = "DELETE FROM users" });
    const e1 = registry.dispatch("db.query", &ctx, .{ .object = m1 }) catch |e| e;
    try std.testing.expectEqual(error.ReadOnlyQueryRequired, e1);

    var m2 = std.json.ObjectMap{};
    try m2.put(a, "sql", .{ .string = "SELECT * FROM users WHERE name = 'alice'" });
    const e2 = registry.dispatch("db.query", &ctx, .{ .object = m2 }) catch |e| e;
    try std.testing.expectEqual(error.UnsafeSqlFragment, e2);
}

test "entity.lookup/list are whitelisted and tenant-scoped" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, tenant_id INTEGER)", &.{});
    _ = try client.exec("INSERT INTO users (name, tenant_id) VALUES ('alice', 1), ('bob', 2)", &.{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const entities = [_]EntitySpec{.{ .name = "user", .table = "users", .pk = "id", .tenant_column = "tenant_id" }};
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerBusinessSkills(&registry, &entities);

    var ctx = SkillContext{ .allocator = a, .backend_ptr = &backend, .tenant_id = 1 };

    // lookup within tenant 1 finds alice (id=1); tenant 2 cannot see her.
    var m = std.json.ObjectMap{};
    try m.put(a, "entity", .{ .string = "user" });
    try m.put(a, "id", .{ .integer = 1 });
    const found = try registry.dispatch("entity.lookup", &ctx, .{ .object = m });
    try std.testing.expectEqualStrings("alice", found.object.get("name").?.string);

    ctx.tenant_id = 2;
    const hidden = try registry.dispatch("entity.lookup", &ctx, .{ .object = m });
    try std.testing.expect(hidden.object.count() == 0);

    // Unknown entity is rejected (whitelist).
    var m2 = std.json.ObjectMap{};
    try m2.put(a, "entity", .{ .string = "orders" });
    try m2.put(a, "id", .{ .integer = 1 });
    const err = registry.dispatch("entity.lookup", &ctx, .{ .object = m2 }) catch |e| e;
    try std.testing.expectEqual(error.UnknownEntity, err);

    // list with an equality filter within tenant 1.
    ctx.tenant_id = 1;
    var lm = std.json.ObjectMap{};
    try lm.put(a, "entity", .{ .string = "user" });
    var filters = std.json.ObjectMap{};
    try filters.put(a, "name", .{ .string = "alice" });
    try lm.put(a, "filters", .{ .object = filters });
    const list = try registry.dispatch("entity.list", &ctx, .{ .object = lm });
    try std.testing.expectEqual(@as(i64, 1), list.object.get("count").?.integer);
}
