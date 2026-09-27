//! Write-operation skills ("AI 可执行"): app-registered, whitelisted mutations
//! with the framework's controlled-execution posture —
//!
//!   - `entity.create` / `entity.update` — write whitelisted columns of a
//!     registered entity; tenant column is forced from `SkillContext.tenant_id`
//!     (never accepted from the model); permission `entity:write`;
//!   - `command.execute` — submit an app-registered business command through
//!     the transactional outbox with an idempotency key from
//!     `SkillContext.run_id`; permission `command:execute`;
//!   - `report.generate` — run an app-registered aggregation and return CSV or
//!     JSON (row-capped, read-only).

const std = @import("std");
const SqlxBackend = @import("../data.zig").SqlxBackend;
const sqlx = @import("../data.zig").sqlx;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const OutboxPublisher = @import("../messaging/OutboxPublisher.zig").OutboxPublisher;
const business = @import("business.zig");
const freeValue = @import("skill.zig").freeValue;
const skill = @import("skill.zig");
const json_shape = @import("json_shape.zig");

pub const max_report_rows: usize = 100;

// ── shared helpers ─────────────────────────────────────────────────────────

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

fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    // The key copy needs its own guard: built as the `put` argument it was
    // stranded whenever the map refused the field (found by the OOM scan on
    // `writeEntity`). The disarmed-by-`return` guard leaves the value's
    // contract alone — a `.string` here is still owned by the caller.
    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    try obj.put(allocator, k, value);
}

/// Copy `s` and hand the copy to `list`, which releases it with its `defer`.
/// The transfer happens inside this function, so a failed `append` frees the
/// copy instead of stranding it — and a caller-side `errdefer` would stay armed
/// for the rest of the enclosing scope and free a string `list` already owns.
fn appendOwnedString(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), s: []const u8) ![]const u8 {
    const copy = try allocator.dupe(u8, s);
    errdefer allocator.free(copy);
    try list.append(allocator, copy);
    return copy;
}

fn findEntity(entities: []const business.EntitySpec, name: []const u8) ?business.EntitySpec {
    for (entities) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Column-name gate for the writable-column path. Delegates to the framework's
/// `sqlx.validateIdentifier` (`[A-Za-z_][A-Za-z0-9_.]*`, ≤128) rather than
/// re-deriving the rules: this local copy had drifted weaker than that gate (it
/// accepted a leading digit and had no length cap), which is the same second-
/// implementation problem `business.zig` was fixed for. The allowlist check
/// above already restricts `col` to declared writable columns; this stays as
/// the shape check that does not depend on that list being right.
fn isValidIdentifier(s: []const u8) bool {
    sqlx.validateIdentifier(s) catch return false;
    return true;
}

// ── entity.create / entity.update ──────────────────────────────────────────

pub const WriteCtx = struct {
    backend: *SqlxBackend,
    entities: []const business.EntitySpec,
};

pub fn registerWriteSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "entity.create",
        .action = .execute,
        .description = "Create a row in a whitelisted entity; only whitelisted columns are writable and the tenant column is forced from context",
        .required_permission = "entity:write",
        .parameters = &.{
            .{ .name = "entity", .type = .string, .description = "Registered entity name", .required = true },
            .{ .name = "fields", .type = .object, .description = "Column → value map (whitelisted columns only)", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const wctx: *WriteCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.WriteNotConfigured));
                return writeEntity(sctx, wctx, args, .create);
            }
        }.h,
    });
    try registry.register(.{
        .name = "entity.update",
        .action = .execute,
        .description = "Update a row by primary key in a whitelisted entity; only whitelisted columns are writable and the tenant column is forced from context",
        .required_permission = "entity:write",
        .parameters = &.{
            .{ .name = "entity", .type = .string, .description = "Registered entity name", .required = true },
            .{ .name = "id", .type = .number, .description = "Primary key value", .required = true },
            .{ .name = "fields", .type = .object, .description = "Column → value map (whitelisted columns only)", .required = true },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const wctx: *WriteCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.WriteNotConfigured));
                return writeEntity(sctx, wctx, args, .update);
            }
        }.h,
    });
}

const WriteKind = enum { create, update };

fn writeEntity(sctx: *SkillContext, wctx: *WriteCtx, args: std.json.Value, kind: WriteKind) anyerror!std.json.Value {
    const obj = args.object;
    const entity_v = obj.get("entity") orelse return error.InvalidArguments;
    const fields_v = obj.get("fields") orelse return error.InvalidArguments;
    if (entity_v != .string or fields_v != .object) return error.InvalidArguments;

    const spec = findEntity(wctx.entities, entity_v.string) orelse return error.EntityNotAllowed;
    if (spec.writable.len == 0) return error.EntityNotWritable;

    // Collect write columns/values; enforce the tenant column from context.
    var cols = std.ArrayList([]const u8).empty;
    defer cols.deinit(sctx.allocator);
    var vals = std.ArrayList(sqlx.Value).empty;
    defer vals.deinit(sctx.allocator);
    var val_owned = std.ArrayList([]const u8).empty;
    defer {
        for (val_owned.items) |s| sctx.allocator.free(s);
        val_owned.deinit(sctx.allocator);
    }

    if (spec.tenant_column) |tc| {
        const tid = sctx.tenant_id orelse return error.TenantRequired;
        try cols.append(sctx.allocator, tc);
        try vals.append(sctx.allocator, .{ .int = tid });
    }

    var it = fields_v.object.iterator();
    while (it.next()) |e| {
        const col = e.key_ptr.*;
        if (spec.tenant_column) |tc| {
            if (std.mem.eql(u8, col, tc)) return error.TenantColumnForbidden;
        }
        if (std.mem.eql(u8, col, spec.pk)) return error.PrimaryKeyForbidden;
        var allowed = false;
        for (spec.writable) |w| {
            if (std.mem.eql(u8, w, col)) {
                allowed = true;
                break;
            }
        }
        if (!allowed) return error.ColumnNotWritable;
        if (!isValidIdentifier(col)) return error.InvalidColumnName;
        try cols.append(sctx.allocator, col);
        const v = try jsonToValue(e.value_ptr.*);
        if (v == .string) {
            const owned = try appendOwnedString(sctx.allocator, &val_owned, v.string);
            try vals.append(sctx.allocator, .{ .string = owned });
        } else {
            try vals.append(sctx.allocator, v);
        }
    }
    if (cols.items.len == 0) return error.NoFields;

    var sql_buf = std.ArrayList(u8).empty;
    defer sql_buf.deinit(sctx.allocator);
    if (kind == .create) {
        try sql_buf.appendSlice(sctx.allocator, "INSERT INTO ");
        try sql_buf.appendSlice(sctx.allocator, spec.table);
        try sql_buf.appendSlice(sctx.allocator, " (");
        for (cols.items, 0..) |c, i| {
            if (i > 0) try sql_buf.append(sctx.allocator, ',');
            try sql_buf.appendSlice(sctx.allocator, c);
        }
        try sql_buf.appendSlice(sctx.allocator, ") VALUES (");
        for (cols.items, 0..) |_, i| {
            if (i > 0) try sql_buf.append(sctx.allocator, ',');
            try sql_buf.append(sctx.allocator, '?');
        }
        try sql_buf.append(sctx.allocator, ')');
    } else {
        const id_v = obj.get("id") orelse return error.InvalidArguments;
        // `.number` is the declared type, so a huge or NaN float (`1e999`)
        // reaches here: `@intFromFloat` of one is undefined behaviour, and
        // `@intCast` of a negative is a checked panic.
        const id = json_shape.numberToI64(id_v) catch return error.InvalidArguments;
        try sql_buf.appendSlice(sctx.allocator, "UPDATE ");
        try sql_buf.appendSlice(sctx.allocator, spec.table);
        try sql_buf.appendSlice(sctx.allocator, " SET ");
        for (cols.items, 0..) |c, i| {
            if (i > 0) try sql_buf.append(sctx.allocator, ',');
            try sql_buf.appendSlice(sctx.allocator, c);
            try sql_buf.appendSlice(sctx.allocator, " = ?");
        }
        try sql_buf.appendSlice(sctx.allocator, " WHERE ");
        try sql_buf.appendSlice(sctx.allocator, spec.pk);
        try sql_buf.appendSlice(sctx.allocator, " = ?");
        try vals.append(sctx.allocator, .{ .int = id });
    }

    const result = try wctx.backend.exec(sql_buf.items, vals.items);
    var out = std.json.ObjectMap{};
    // The result tree is handed to the caller by the `return` below; without
    // this, a field that fails to go in strands the ones already placed (the
    // OOM scan on this function found the same shape inside `putOwned`).
    errdefer freeValue(sctx.allocator, .{ .object = out });
    if (kind == .create) {
        if (result.last_insert_id) |lid| {
            try putOwned(&out, sctx.allocator, "id", .{ .integer = lid });
        }
        try putOwned(&out, sctx.allocator, "created", .{ .bool = result.rows_affected > 0 });
    } else {
        try putOwned(&out, sctx.allocator, "updated", .{ .integer = @intCast(result.rows_affected) });
    }
    return .{ .object = out };
}

// ── command.execute (outbox, idempotent by run_id) ─────────────────────────

pub const CommandSpec = struct {
    name: []const u8,
    description: []const u8,
};

pub const CommandCtx = struct {
    backend: *SqlxBackend,
    outbox: *OutboxPublisher,
    commands: []const CommandSpec,
    topic_prefix: []const u8 = "ai.command",
};

pub fn registerCommandSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "command.execute",
        .action = .execute,
        .description = "Submit an app-registered business command through the transactional outbox; idempotency key comes from the run context",
        .required_permission = "command:execute",
        .parameters = &.{
            .{ .name = "command", .type = .string, .description = "Registered command name", .required = true },
            .{ .name = "payload", .type = .object, .description = "Command payload", .required = false },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const cctx: *CommandCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.CommandNotConfigured));
                return executeCommand(sctx, cctx, args);
            }
        }.h,
    });
}

fn executeCommand(sctx: *SkillContext, cctx: *CommandCtx, args: std.json.Value) anyerror!std.json.Value {
    const obj = args.object;
    const name_v = obj.get("command") orelse return error.InvalidArguments;
    if (name_v != .string) return error.InvalidArguments;

    var found = false;
    for (cctx.commands) |c| {
        if (std.mem.eql(u8, c.name, name_v.string)) {
            found = true;
            break;
        }
    }
    if (!found) return error.CommandNotAllowed;

    // Idempotency: the run_id (when present) is the exactly-once key.
    const run_id = sctx.run_id orelse return error.RunIdRequired;

    var payload_buf = std.ArrayList(u8).empty;
    defer payload_buf.deinit(sctx.allocator);
    // The two interpolated fields go through the encoder: `run_id` is
    // caller-supplied and one `"` in it used to make the event (and everything
    // downstream of it) unparseable. `payload_buf` only splices the rendered
    // envelope and the already-valid `data` member.
    const head = try skill.encodeJsonObject(sctx.allocator, &.{
        .{ .key = "run_id", .value = .{ .string = run_id } },
        .{ .key = "command", .value = .{ .string = name_v.string } },
    });
    defer sctx.allocator.free(head);
    // `head` is exactly `{"run_id":…,"command":…}` — drop its closing brace and
    // re-close with the `data` member.
    try payload_buf.appendSlice(sctx.allocator, head[0 .. head.len - 1]);
    try payload_buf.appendSlice(sctx.allocator, ",\"data\":");
    if (obj.get("payload")) |p| {
        const data = try std.json.Stringify.valueAlloc(sctx.allocator, p, .{});
        defer sctx.allocator.free(data);
        try payload_buf.appendSlice(sctx.allocator, data);
    } else {
        try payload_buf.appendSlice(sctx.allocator, "{}");
    }
    try payload_buf.appendSlice(sctx.allocator, "}");

    const topic = try std.fmt.allocPrint(sctx.allocator, "{s}.{s}", .{ cctx.topic_prefix, name_v.string });
    defer sctx.allocator.free(topic);
    const insert = try cctx.outbox.buildInsert(topic, payload_buf.items);
    const result = try cctx.backend.exec(insert.sql, &.{
        .{ .string = insert.params.topic },
        .{ .string = insert.params.payload },
        .{ .int = @intCast(insert.params.max_retries) },
        .{ .int = insert.params.created_at },
        .{ .int = insert.params.updated_at },
    });

    var out = std.json.ObjectMap{};
    // `out` owns every key and value placed into it; the guard is disarmed by
    // the `return` that hands the tree to the caller. The string values go
    // through putJsonField, which makes its own copy — a `dupe` built as the
    // `put` argument was stranded whenever the map refused the field.
    errdefer freeValue(sctx.allocator, .{ .object = out });
    try putOwned(&out, sctx.allocator, "ok", .{ .bool = true });
    try skill.putJsonField(sctx.allocator, &out, "topic", .{ .string = topic });
    try skill.putJsonField(sctx.allocator, &out, "run_id", .{ .string = run_id });
    if (result.last_insert_id) |lid| try putOwned(&out, sctx.allocator, "event_id", .{ .integer = lid });
    return .{ .object = out };
}

// ── report.generate (CSV / JSON) ───────────────────────────────────────────

pub const ReportSpec = struct {
    name: []const u8,
    sql: []const u8,
};

pub const ReportCtx = struct {
    backend: *SqlxBackend,
    reports: []const ReportSpec,
    max_rows: usize = max_report_rows,
};

pub fn registerReportSkills(registry: *SkillRegistry) !void {
    try registry.register(.{
        .name = "report.generate",
        .action = .read,
        .description = "Run an app-registered aggregation report and return it as CSV or JSON (row-capped, read-only)",
        .parameters = &.{
            .{ .name = "report", .type = .string, .description = "Registered report name", .required = true },
            .{ .name = "format", .type = .string, .description = "csv or json (default json)", .required = false },
        },
        .handler = struct {
            fn h(sctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try sctx.checkDeadline();
                const rctx: *ReportCtx = @ptrCast(@alignCast(sctx.userdata orelse return error.ReportNotConfigured));
                return generateReport(sctx, rctx, args);
            }
        }.h,
    });
}

fn generateReport(sctx: *SkillContext, rctx: *ReportCtx, args: std.json.Value) anyerror!std.json.Value {
    const obj = try json_shape.object(args);
    const name_v = obj.get("report") orelse return error.InvalidArguments;
    if (name_v != .string) return error.InvalidArguments;
    const format = (try json_shape.getString(obj, "format")) orelse "json";
    if (!std.mem.eql(u8, format, "csv") and !std.mem.eql(u8, format, "json")) return error.InvalidArguments;

    var spec: ?ReportSpec = null;
    for (rctx.reports) |r| {
        if (std.mem.eql(u8, r.name, name_v.string)) {
            spec = r;
            break;
        }
    }
    const report = spec orelse return error.ReportNotAllowed;

    var cursor = try rctx.backend.client.queryCursorEx(report.sql, &.{}, .{});
    defer cursor.deinit();

    if (std.mem.eql(u8, format, "csv")) {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(sctx.allocator);
        var first_row = true;
        var rows: usize = 0;
        while (try cursor.next()) |row| {
            if (rows >= rctx.max_rows) break;
            rows += 1;
            if (first_row) {
                for (row.columns, 0..) |c, i| {
                    if (i > 0) try buf.append(sctx.allocator, ',');
                    try buf.appendSlice(sctx.allocator, c);
                }
                try buf.append(sctx.allocator, '\n');
                first_row = false;
            }
            for (row.values, 0..) |v, i| {
                if (i > 0) try buf.append(sctx.allocator, ',');
                switch (v orelse .null) {
                    .null => try buf.appendSlice(sctx.allocator, ""),
                    .bool => |b| try buf.appendSlice(sctx.allocator, if (b) "true" else "false"),
                    .int => |n| {
                        const s = try std.fmt.allocPrint(sctx.allocator, "{d}", .{n});
                        defer sctx.allocator.free(s);
                        try buf.appendSlice(sctx.allocator, s);
                    },
                    .float => |f| {
                        const s = try std.fmt.allocPrint(sctx.allocator, "{d}", .{f});
                        defer sctx.allocator.free(s);
                        try buf.appendSlice(sctx.allocator, s);
                    },
                    .string => |s| try buf.appendSlice(sctx.allocator, s),
                }
            }
            try buf.append(sctx.allocator, '\n');
        }
        return .{ .string = try buf.toOwnedSlice(sctx.allocator) };
    }

    var arr = std.json.Array.init(sctx.allocator);
    // Covers the records already placed when a later column or row fails; the
    // `return` hands the tree to the caller and disarms the guard — one that
    // outlived the hand-over is how a tree gets freed twice.
    errdefer freeValue(sctx.allocator, .{ .array = arr });
    var rows: usize = 0;
    while (try cursor.next()) |row| {
        if (rows >= rctx.max_rows) break;
        rows += 1;
        var rec = std.json.ObjectMap{};
        // The append is the last statement of the loop body, so this guard is
        // gone — disarmed by the normal scope exit — exactly when `arr` takes
        // ownership of the record.
        errdefer freeValue(sctx.allocator, .{ .object = rec });
        for (row.columns, 0..) |c, i| {
            const v = row.values[i] orelse .null;
            // putJsonField copies the key and a `.string` value itself (and
            // frees both copies when the map refuses the field) — a `dupe`
            // built as the `put` argument was stranded on exactly that failure.
            try skill.putJsonField(sctx.allocator, &rec, c, switch (v) {
                .bool => |b| .{ .bool = b },
                .int => |n| .{ .integer = n },
                .float => |f| .{ .float = f },
                .string => |s| .{ .string = s },
                else => .null,
            });
        }
        try arr.append(.{ .object = rec });
    }
    return .{ .array = arr };
}

// ── tests ──────────────────────────────────────────────────────────────────

fn setupRegistry(allocator: std.mem.Allocator, io: std.Io) !SkillRegistry {
    const registry = SkillRegistry.init(allocator, io);
    return registry;
}

test "entity.create enforces tenant and writable whitelist" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, amount INTEGER, note TEXT)", &.{});
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };

    const entities = [_]business.EntitySpec{
        .{ .name = "order", .table = "orders", .tenant_column = "tenant_id", .writable = &.{ "amount", "note" } },
    };
    var wctx = WriteCtx{ .backend = &backend, .entities = &entities };
    var registry = try setupRegistry(allocator, std.testing.io);
    defer registry.deinit();
    try registerWriteSkills(&registry);
    const perms = [_][]const u8{"entity:write"};
    var sctx = SkillContext{ .allocator = allocator, .tenant_id = 7, .permissions = &perms, .userdata = &wctx };

    var fields = std.json.ObjectMap{};
    try putOwned(&fields, allocator, "amount", .{ .integer = 9900 });
    try putOwned(&fields, allocator, "note", .{ .string = try allocator.dupe(u8, "rush") });
    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "entity", .{ .string = try allocator.dupe(u8, "order") });
    try putOwned(&args_map, allocator, "fields", .{ .object = fields });
    const res = try registry.dispatch("entity.create", &sctx, .{ .object = args_map });
    defer freeValue(allocator, res);
    defer freeValue(allocator, .{ .object = args_map });
    try std.testing.expectEqual(@as(bool, true), res.object.get("created").?.bool);

    var cursor = try client.queryCursorEx("SELECT tenant_id, amount, note FROM orders", &.{}, .{});
    defer cursor.deinit();
    const row = (try cursor.next()).?;
    try std.testing.expectEqual(@as(i64, 7), row.get("tenant_id").?.int);
    try std.testing.expectEqual(@as(i64, 9900), row.get("amount").?.int);
    try std.testing.expectEqualStrings("rush", row.get("note").?.string);

    // Tenant column cannot be set by the model.
    var bad_fields = std.json.ObjectMap{};
    try putOwned(&bad_fields, allocator, "tenant_id", .{ .integer = 99 });
    var bad_args = std.json.ObjectMap{};
    try putOwned(&bad_args, allocator, "entity", .{ .string = try allocator.dupe(u8, "order") });
    try putOwned(&bad_args, allocator, "fields", .{ .object = bad_fields });
    defer freeValue(allocator, .{ .object = bad_args });
    try std.testing.expectError(error.TenantColumnForbidden, registry.dispatch("entity.create", &sctx, .{ .object = bad_args }));
}

// The table, the entity spec and the args tree are built with the test
// allocator before the scan; the failing allocator covers the dispatch itself
// (the skill context's allocator is swapped for it) — the copies in
// `val_owned`, the SQL text and the result value.
test "entity.create hands back its values at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY AUTOINCREMENT, tenant_id INTEGER NOT NULL, amount INTEGER, note TEXT)", &.{});
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const entities = [_]business.EntitySpec{
        .{ .name = "order", .table = "orders", .tenant_column = "tenant_id", .writable = &.{ "amount", "note" } },
    };
    var wctx = WriteCtx{ .backend = &backend, .entities = &entities };
    var registry = try setupRegistry(allocator, std.testing.io);
    defer registry.deinit();
    try registerWriteSkills(&registry);
    const perms = [_][]const u8{"entity:write"};
    var base_ctx = SkillContext{ .allocator = allocator, .tenant_id = 7, .permissions = &perms, .userdata = &wctx };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var sctx = base.*;
            sctx.allocator = a;
            // Built with `putJsonField`, which copies the keys *and* the
            // string values (this file's `putOwned` hands values over as-is, so
            // a literal put through it must not be freed).
            const fields = blk: {
                var map = std.json.ObjectMap{};
                errdefer freeValue(a, .{ .object = map });
                try skill.putJsonField(a, &map, "amount", .{ .integer = 9900 });
                try skill.putJsonField(a, &map, "note", .{ .string = "rush \"today\"" });
                break :blk map;
            };
            var args = std.json.ObjectMap{};
            defer freeValue(a, .{ .object = args });
            // The transfer is the very next statement, and `putJsonField`
            // releases an `.object` value it cannot place — so `fields` needs no
            // guard of its own here, and none may outlive this put (that would
            // free what `args` owns).
            try skill.putJsonField(a, &args, "fields", .{ .object = fields });
            try skill.putJsonField(a, &args, "entity", .{ .string = "order" });
            const res = try reg.dispatch("entity.create", &sctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expectEqual(@as(bool, true), res.object.get("created").?.bool);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}

// Same harness as the entity.create scan: the table, backend, outbox and
// registry ride the test allocator; the failing allocator is the context's,
// walking the payload buffer, the encoded envelope, the topic copy and the
// result map.
//
// Red before the fix: the `topic`/`run_id` copies were built as `put`
// arguments and stranded when the map refused the field, and the result map
// had no guard at all.
test "command.execute hands back its event at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    const commands = [_]CommandSpec{
        .{ .name = "refund", .description = "refund an order" },
    };
    var cctx = CommandCtx{ .backend = &backend, .outbox = &outbox, .commands = &commands };
    var registry = try setupRegistry(allocator, std.testing.io);
    defer registry.deinit();
    try registerCommandSkills(&registry);
    const perms = [_][]const u8{"command:execute"};
    var base_ctx = SkillContext{ .allocator = allocator, .run_id = "run-42", .permissions = &perms, .userdata = &cctx };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var sctx = base.*;
            sctx.allocator = a;
            var args = std.json.ObjectMap{};
            defer freeValue(a, .{ .object = args });
            const payload = blk: {
                var map = std.json.ObjectMap{};
                errdefer freeValue(a, .{ .object = map });
                try skill.putJsonField(a, &map, "order_id", .{ .integer = 7 });
                break :blk map;
            };
            try skill.putJsonField(a, &args, "payload", .{ .object = payload });
            try skill.putJsonField(a, &args, "command", .{ .string = "refund" });
            const res = try reg.dispatch("command.execute", &sctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expectEqualStrings("ai.command.refund", res.object.get("topic").?.string);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}

// Read-only sibling of the command.execute scan: the failing allocator walks
// the row records, the rows array and — for the CSV leg — the buffer and its
// per-value formatting copies.
//
// Red before the fix: a record's string copy was built as the `put` argument
// and stranded when the map refused the field, and the `rec`/`arr` trees had
// no guard while they were being built.
test "report.generate hands back its rows at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, tenant_id INTEGER, amount INTEGER)", &.{});
    _ = try client.exec("INSERT INTO orders (tenant_id, amount) VALUES (1, 100), (1, 200), (2, 50)", &.{});
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const reports = [_]ReportSpec{
        .{ .name = "revenue", .sql = "SELECT tenant_id, SUM(amount) AS total FROM orders GROUP BY tenant_id ORDER BY tenant_id" },
    };
    var rctx = ReportCtx{ .backend = &backend, .reports = &reports };
    var registry = try setupRegistry(allocator, std.testing.io);
    defer registry.deinit();
    try registerReportSkills(&registry);
    var base_ctx = SkillContext{ .allocator = allocator, .userdata = &rctx };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var sctx = base.*;
            sctx.allocator = a;
            {
                var args = std.json.ObjectMap{};
                defer freeValue(a, .{ .object = args });
                try skill.putJsonField(a, &args, "report", .{ .string = "revenue" });
                const res = try reg.dispatch("report.generate", &sctx, .{ .object = args });
                defer freeValue(a, res);
                try std.testing.expectEqual(@as(usize, 2), res.array.items.len);
            }
            {
                var args = std.json.ObjectMap{};
                defer freeValue(a, .{ .object = args });
                try skill.putJsonField(a, &args, "report", .{ .string = "revenue" });
                try skill.putJsonField(a, &args, "format", .{ .string = "csv" });
                const res = try reg.dispatch("report.generate", &sctx, .{ .object = args });
                defer freeValue(a, res);
                try std.testing.expect(std.mem.indexOf(u8, res.string, "1,300") != null);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}

test "command.execute writes an idempotent outbox event" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    const commands = [_]CommandSpec{
        .{ .name = "refund", .description = "refund an order" },
    };
    var cctx = CommandCtx{ .backend = &backend, .outbox = &outbox, .commands = &commands };
    var registry = try setupRegistry(allocator, std.testing.io);
    defer registry.deinit();
    try registerCommandSkills(&registry);
    const perms = [_][]const u8{"command:execute"};
    var sctx = SkillContext{ .allocator = allocator, .run_id = "run-42", .permissions = &perms, .userdata = &cctx };

    var payload = std.json.ObjectMap{};
    try putOwned(&payload, allocator, "order_id", .{ .integer = 7 });
    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "command", .{ .string = try allocator.dupe(u8, "refund") });
    try putOwned(&args_map, allocator, "payload", .{ .object = payload });
    const res = try registry.dispatch("command.execute", &sctx, .{ .object = args_map });
    defer freeValue(allocator, res);
    defer freeValue(allocator, .{ .object = args_map });
    try std.testing.expectEqualStrings("ai.command.refund", res.object.get("topic").?.string);
    try std.testing.expectEqualStrings("run-42", res.object.get("run_id").?.string);

    var cursor = try client.queryCursorEx("SELECT topic, payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = (try cursor.next()).?;
    try std.testing.expectEqualStrings("ai.command.refund", row.get("topic").?.string);
    try std.testing.expect(std.mem.indexOf(u8, row.get("payload").?.string, "run-42") != null);

    // Without a run_id the command is refused (no idempotency key).
    var no_run = SkillContext{ .allocator = allocator, .permissions = &perms, .userdata = &cctx };
    try std.testing.expectError(error.RunIdRequired, registry.dispatch("command.execute", &no_run, .{ .object = args_map }));
}

test "report.generate returns JSON and CSV" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec("CREATE TABLE orders (id INTEGER PRIMARY KEY, tenant_id INTEGER, amount INTEGER)", &.{});
    _ = try client.exec("INSERT INTO orders (tenant_id, amount) VALUES (1, 100), (1, 200), (2, 50)", &.{});
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    const reports = [_]ReportSpec{
        .{ .name = "revenue", .sql = "SELECT tenant_id, SUM(amount) AS total FROM orders GROUP BY tenant_id ORDER BY tenant_id" },
    };
    var rctx = ReportCtx{ .backend = &backend, .reports = &reports };
    var registry = try setupRegistry(allocator, std.testing.io);
    defer registry.deinit();
    try registerReportSkills(&registry);
    var sctx = SkillContext{ .allocator = allocator, .userdata = &rctx };

    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "report", .{ .string = try allocator.dupe(u8, "revenue") });
    const res = try registry.dispatch("report.generate", &sctx, .{ .object = args_map });
    defer freeValue(allocator, res);
    defer freeValue(allocator, .{ .object = args_map });
    try std.testing.expectEqual(@as(usize, 2), res.array.items.len);
    try std.testing.expectEqual(@as(i64, 300), res.array.items[0].object.get("total").?.integer);

    var csv_args = std.json.ObjectMap{};
    try putOwned(&csv_args, allocator, "report", .{ .string = try allocator.dupe(u8, "revenue") });
    try putOwned(&csv_args, allocator, "format", .{ .string = try allocator.dupe(u8, "csv") });
    const csv = try registry.dispatch("report.generate", &sctx, .{ .object = csv_args });
    defer freeValue(allocator, csv);
    defer freeValue(allocator, .{ .object = csv_args });
    try std.testing.expect(std.mem.indexOf(u8, csv.string, "tenant_id,total") != null);
    try std.testing.expect(std.mem.indexOf(u8, csv.string, "1,300") != null);
}

test "command.execute outbox payload escapes quotes in the run id" {
    const allocator = std.testing.allocator;
    var client = sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    _ = try client.exec(
        "CREATE TABLE event_outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, topic TEXT, payload TEXT, status INTEGER DEFAULT 0, tenant_id INTEGER, retry_count INTEGER DEFAULT 0, max_retries INTEGER DEFAULT 5, created_at INTEGER, updated_at INTEGER, error_message TEXT)",
        &.{},
    );
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var outbox = OutboxPublisher.init(allocator, .{ .max_retries = 3 });
    const commands = [_]CommandSpec{
        .{ .name = "refund", .description = "refund an order" },
    };
    var cctx = CommandCtx{ .backend = &backend, .outbox = &outbox, .commands = &commands };
    var registry = try setupRegistry(allocator, std.testing.io);
    defer registry.deinit();
    try registerCommandSkills(&registry);
    const perms = [_][]const u8{"command:execute"};
    const run_id = "run-\"42\"-\\x";
    var sctx = SkillContext{ .allocator = allocator, .run_id = run_id, .permissions = &perms, .userdata = &cctx };

    var payload = std.json.ObjectMap{};
    try putOwned(&payload, allocator, "order_id", .{ .integer = 7 });
    try putOwned(&payload, allocator, "note", .{ .string = try allocator.dupe(u8, "a \"quoted\" note") });
    var args_map = std.json.ObjectMap{};
    try putOwned(&args_map, allocator, "command", .{ .string = try allocator.dupe(u8, "refund") });
    try putOwned(&args_map, allocator, "payload", .{ .object = payload });
    const res = try registry.dispatch("command.execute", &sctx, .{ .object = args_map });
    defer freeValue(allocator, res);
    defer freeValue(allocator, .{ .object = args_map });

    var cursor = try client.queryCursorEx("SELECT payload FROM event_outbox", &.{}, .{});
    defer cursor.deinit();
    const row = (try cursor.next()) orelse return error.NoOutboxRow;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, row.get("payload").?.string, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings(run_id, obj.get("run_id").?.string);
    try std.testing.expectEqualStrings("refund", obj.get("command").?.string);
    // `data` is the model's own object, spliced as the valid JSON it already is.
    try std.testing.expectEqual(@as(i64, 7), obj.get("data").?.object.get("order_id").?.integer);
    try std.testing.expectEqualStrings("a \"quoted\" note", obj.get("data").?.object.get("note").?.string);
}
