//! `zmodu saas` — turn a SaaS business model (JSON) into a zigmodu backend
//! module. Emits an org-scoped schema (`org_id` tenant column) that is fed to
//! the canonical `zmodu orm` pipeline: model/persistence/service/api with
//! ComptimeRouter routes, layered per MODULE_LAYERS.md.
//!
//! Model shape (shared with the SolidStart frontend generator):
//!   { "entities": [ {
//!       "name": "orders",                                  // table + module
//!       "writeRole": "admin",                              // member | admin
//!       "fields": [ { "name": "customer", "type": "string", "required": true } ]
//!   } ] }
//! Field types: string | text | number | boolean | date

const std = @import("std");

const SqlType = enum { text, integer, real };

fn sqlTypeFor(field_type: []const u8) !SqlType {
    if (std.mem.eql(u8, field_type, "string") or std.mem.eql(u8, field_type, "text") or std.mem.eql(u8, field_type, "date")) return .text;
    if (std.mem.eql(u8, field_type, "number") or std.mem.eql(u8, field_type, "boolean")) return .integer;
    return error.UnsupportedFieldType;
}

/// Convert a business model JSON document into CREATE TABLE SQL for the
/// `zmodu orm` pipeline. Each entity gets `org_id` as the tenant column.
pub fn emitSchemaSql(allocator: std.mem.Allocator, model_json: []const u8) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, model_json, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidModel;
    const entities = root.object.get("entities") orelse return error.InvalidModel;
    if (entities != .array or entities.array.items.len == 0) return error.InvalidModel;

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    for (entities.array.items) |ent| {
        if (ent != .object) return error.InvalidModel;
        const name_v = ent.object.get("name") orelse return error.InvalidModel;
        if (name_v != .string) return error.InvalidModel;
        const fields_v = ent.object.get("fields") orelse return error.InvalidModel;
        if (fields_v != .array) return error.InvalidModel;

        try buf.appendSlice(allocator, "CREATE TABLE ");
        try buf.appendSlice(allocator, name_v.string);
        try buf.appendSlice(allocator, " (\n  id INTEGER PRIMARY KEY AUTOINCREMENT,\n  org_id INTEGER NOT NULL,\n");
        for (fields_v.array.items) |f| {
            if (f != .object) return error.InvalidModel;
            const fname = f.object.get("name") orelse return error.InvalidModel;
            const ftype = f.object.get("type") orelse return error.InvalidModel;
            if (fname != .string or ftype != .string) return error.InvalidModel;
            const sql_type = try sqlTypeFor(ftype.string);
            try buf.appendSlice(allocator, "  ");
            try buf.appendSlice(allocator, fname.string);
            try buf.appendSlice(allocator, " ");
            try buf.appendSlice(allocator, switch (sql_type) {
                .text => "TEXT",
                .integer => "INTEGER",
                .real => "REAL",
            });
            if (f.object.get("required")) |req| {
                if (req == .bool and req.bool) try buf.appendSlice(allocator, " NOT NULL");
            }
            try buf.appendSlice(allocator, ",\n");
        }
        try buf.appendSlice(allocator, "  created_at INTEGER NOT NULL,\n  updated_at INTEGER NOT NULL\n);\n\n");
    }
    return buf.toOwnedSlice(allocator);
}

fn appendPrint(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try buf.appendSlice(allocator, s);
}

fn zigFieldType(field_type: []const u8) ![]const u8 {
    if (std.mem.eql(u8, field_type, "string") or std.mem.eql(u8, field_type, "text")) return "[]const u8";
    if (std.mem.eql(u8, field_type, "number")) return "i64";
    if (std.mem.eql(u8, field_type, "boolean")) return "bool";
    if (std.mem.eql(u8, field_type, "date")) return "i64";
    return error.UnsupportedFieldType;
}

const Entity = struct {
    name: []const u8, // owned
    fields: []Field, // owned
};
const Field = struct {
    name: []const u8, // owned
    field_type: []const u8, // owned
    required: bool,
    default: ?[]const u8 = null, // owned when set
};

fn parseModel(allocator: std.mem.Allocator, model_json: []const u8) ![]Entity {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, model_json, .{});
    defer parsed.deinit();
    const entities = parsed.value.object.get("entities").?.array;
    var out = std.ArrayList(Entity).empty;
    errdefer {
        for (out.items) |*e| {
            allocator.free(e.name);
            for (e.fields) |f| {
                allocator.free(f.name);
                allocator.free(f.field_type);
                if (f.default) |d| allocator.free(d);
            }
            allocator.free(e.fields);
        }
        out.deinit(allocator);
    }
    for (entities.items) |ent| {
        const name = try allocator.dupe(u8, ent.object.get("name").?.string);
        errdefer allocator.free(name);
        const farr = ent.object.get("fields").?.array;
        const fields = try allocator.alloc(Field, farr.items.len);
        errdefer allocator.free(fields);
        for (farr.items, 0..) |f, i| {
            const fname = try allocator.dupe(u8, f.object.get("name").?.string);
            errdefer allocator.free(fname);
            const ftype = try allocator.dupe(u8, f.object.get("type").?.string);
            errdefer allocator.free(ftype);
            var def: ?[]const u8 = null;
            if (f.object.get("default")) |d| {
                if (d == .string) def = try allocator.dupe(u8, d.string);
            }
            fields[i] = .{
                .name = fname,
                .field_type = ftype,
                .required = if (f.object.get("required")) |r| (r == .bool and r.bool) else false,
                .default = def,
            };
        }
        try out.append(allocator, .{ .name = name, .fields = fields });
    }
    return out.toOwnedSlice(allocator);
}

fn pascal(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var cap_next = true;
    for (name) |c| {
        if (c == '-' or c == '_') {
            cap_next = true;
            continue;
        }
        try buf.append(allocator, if (cap_next) std.ascii.toUpper(c) else c);
        cap_next = false;
    }
    return buf.toOwnedSlice(allocator);
}

fn emitModel(allocator: std.mem.Allocator, e: *const Entity, P: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "//! Generated by zmodu saas — ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " model\nconst std = @import(\"std\");\n\npub const ");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, " = struct {\n    id: i64 = 0,\n    org_id: i64 = 0,\n");
    for (e.fields) |f| {
        try buf.appendSlice(allocator, "    ");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, try zigFieldType(f.field_type));
        if (f.default) |d| {
            if (std.mem.eql(u8, f.field_type, "boolean")) {
                try buf.appendSlice(allocator, " = ");
                try buf.appendSlice(allocator, if (std.mem.eql(u8, d, "true")) "true" else "false");
            } else if (std.mem.eql(u8, f.field_type, "number")) {
                try buf.appendSlice(allocator, " = ");
                try buf.appendSlice(allocator, d);
            } else {
                try buf.appendSlice(allocator, " = \"");
                try buf.appendSlice(allocator, d);
                try buf.appendSlice(allocator, "\"");
            }
        } else if (std.mem.eql(u8, f.field_type, "boolean")) {
            try buf.appendSlice(allocator, " = false");
        } else if (std.mem.eql(u8, f.field_type, "number") or std.mem.eql(u8, f.field_type, "date")) {
            try buf.appendSlice(allocator, " = 0");
        } else if (std.mem.eql(u8, f.field_type, "text") or std.mem.eql(u8, f.field_type, "string")) {
            try buf.appendSlice(allocator, " = \"\"");
        }
        try buf.appendSlice(allocator, ",\n");
    }
    try buf.appendSlice(allocator, "    created_at: i64 = 0,\n    updated_at: i64 = 0,\n};\n");
    return buf.toOwnedSlice(allocator);
}

/// Generate a scan expression for one field at `row.values[idx]`:
/// returns the Zig expression producing the field value (owned via allocator).
fn emitPersistence(allocator: std.mem.Allocator, e: *const Entity, P: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    const col_list = blk: {
        var cb = std.ArrayList(u8).empty;
        for (e.fields, 0..) |f, i| {
            if (i > 0) try cb.appendSlice(allocator, ", ");
            try cb.appendSlice(allocator, f.name);
        }
        break :blk try cb.toOwnedSlice(allocator);
    };
    defer allocator.free(col_list);

    try appendPrint(allocator, &buf, "//! Generated by zmodu saas — {s} persistence (org-scoped, parameterized)\n", .{e.name});
    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\const data = @import("zigmodu").data;
        \\const Time = @import("zigmodu").Time;
        \\const model = @import("model.zig");
        \\
        \\pub const
    );
    try buf.appendSlice(allocator, " ");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Persistence = struct {\n    backend: *data.SqlxBackend,\n\n    pub fn init(b: *data.SqlxBackend) ");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Persistence {\n");
    try buf.appendSlice(allocator, "        return .{ .backend = b };\n");
    try buf.appendSlice(allocator, "    }\n\n");

    // list
    try appendPrint(allocator, &buf, "    pub fn list(self: *@This(), org_id: i64, page: usize, size: usize, sort: ?data.SortSpec) !data.ResultSet(model.{s}) {{\n", .{P});
    try buf.appendSlice(allocator, "        const total = (try self.backend.client.queryRow(struct { total: i64 }, \"SELECT COUNT(*) AS total FROM ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " WHERE org_id = ?\", &.{ .{ .int = org_id } })).total;\n");
    try buf.appendSlice(allocator, "        var sql_buf: [512]u8 = undefined;\n        const sql = if (sort) |s| blk: {\n            break :blk std.fmt.bufPrint(&sql_buf, \"SELECT id, org_id, ");
    try buf.appendSlice(allocator, col_list);
    try buf.appendSlice(allocator, ", created_at, updated_at FROM ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " WHERE org_id = ? ORDER BY {s} {s} LIMIT ? OFFSET ?\", .{ s.column, if (s.desc) \"DESC\" else \"ASC\" }) catch return error.InvalidInput;\n        } else \"SELECT id, org_id, ");
    try buf.appendSlice(allocator, col_list);
    try buf.appendSlice(allocator, ", created_at, updated_at FROM ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " WHERE org_id = ? ORDER BY id DESC LIMIT ? OFFSET ?\";\n");
    try buf.appendSlice(allocator, "        var result = try self.backend.client.queryRows(model.");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, ", sql, &.{ .{ .int = org_id }, .{ .int = @intCast(size) }, .{ .int = @intCast((page -| 1) * size) } });\n");
    try buf.appendSlice(allocator,
        \\        const take = result.take();
        \\        return .{ .items = take.items, .total = @intCast(total), .arena = take.arena };
        \\    }
        \\
    );

    // get
    try appendPrint(allocator, &buf, "    pub fn get(self: *@This(), allocator: std.mem.Allocator, org_id: i64, id: i64) !?model.{s} {{\n", .{P});
    try buf.appendSlice(allocator,
        \\        const rows = try self.backend.client.queryRowsSlice(allocator, model.
    );
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, ", \"SELECT id, org_id, ");
    try buf.appendSlice(allocator, col_list);
    try buf.appendSlice(allocator, ", created_at, updated_at FROM ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " WHERE org_id = ? AND id = ? LIMIT 1\", &.{ .{ .int = org_id }, .{ .int = id } });\n");
    try buf.appendSlice(allocator,
        \\        if (rows.len == 0) {
        \\            allocator.free(rows);
        \\            return null;
        \\        }
        \\        const result = rows[0];
        \\        for (rows[1..]) |item| data.sqlx.freeScanned(allocator, model.
    );
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, ", item);\n        allocator.free(rows);\n        return result;\n    }\n\n");

    // create
    try appendPrint(allocator, &buf, "    pub fn create(self: *@This(), e: model.{s}) !i64 {{\n", .{P});
    try buf.appendSlice(allocator, "        const now = Time.monotonicNowSeconds();\n        const result = try self.backend.client.exec(\"INSERT INTO ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " (org_id, ");
    try buf.appendSlice(allocator, col_list);
    try buf.appendSlice(allocator, ", created_at, updated_at) VALUES (?, ");
    for (e.fields) |_| try buf.appendSlice(allocator, "?, ");
    try buf.appendSlice(allocator, "?, ?)\", &.{ .{ .int = e.org_id }");
    for (e.fields) |f| {
        if (std.mem.eql(u8, f.field_type, "number")) {
            try buf.appendSlice(allocator, ", .{ .int = e.");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, " }");
        } else if (std.mem.eql(u8, f.field_type, "boolean")) {
            try buf.appendSlice(allocator, ", .{ .bool = e.");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, " }");
        } else {
            try buf.appendSlice(allocator, ", .{ .string = e.");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, " }");
        }
    }
    try buf.appendSlice(allocator, ", .{ .int = now }, .{ .int = now } });\n        return result.last_insert_id orelse 0;\n    }\n\n");

    // update
    try appendPrint(allocator, &buf, "    pub fn update(self: *@This(), e: model.{s}, org_id: i64) !void {{\n", .{P});
    try buf.appendSlice(allocator, "        const now = Time.monotonicNowSeconds();\n        _ = try self.backend.client.exec(\"UPDATE ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " SET ");
    for (e.fields, 0..) |f, i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, " = ?");
    }
    try buf.appendSlice(allocator, ", updated_at = ? WHERE id = ? AND org_id = ?\", &.{");
    for (e.fields) |f| {
        if (std.mem.eql(u8, f.field_type, "number")) {
            try buf.appendSlice(allocator, " .{ .int = e.");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, " },");
        } else if (std.mem.eql(u8, f.field_type, "boolean")) {
            try buf.appendSlice(allocator, " .{ .bool = e.");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, " },");
        } else {
            try buf.appendSlice(allocator, " .{ .string = e.");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, " },");
        }
    }
    try buf.appendSlice(allocator, " .{ .int = now }, .{ .int = e.id }, .{ .int = org_id } });\n    }\n\n");

    // delete
    try appendPrint(allocator, &buf, "    pub fn delete(self: *@This(), org_id: i64, id: i64) !void {{\n", .{});
    try buf.appendSlice(allocator, "        _ = try self.backend.client.exec(\"DELETE FROM ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " WHERE id = ? AND org_id = ?\", &.{ .{ .int = id }, .{ .int = org_id } });\n    }\n\n");

    try buf.appendSlice(allocator, "};\n");
    return buf.toOwnedSlice(allocator);
}

fn emitService(allocator: std.mem.Allocator, e: *const Entity, P: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try appendPrint(allocator, &buf, "//! Generated by zmodu saas — {s} service (CrudService event-source composition)\n", .{e.name});
    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const model = @import("model.zig");
        \\const persistence = @import("persistence.zig");
        \\
        \\pub const
    );
    try buf.appendSlice(allocator, " ");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Service = struct {\n");
    try appendPrint(allocator, &buf, "    pub const module_name = \"{s}\";\n", .{e.name});
    try appendPrint(allocator, &buf, "    pub const nest = .{{\"{s}\"}};\n", .{e.name});
    try appendPrint(allocator, &buf, "    pub const impl = zigmodu.data.CrudService(model.{s}, persistence.{s}Persistence);\n", .{ P, P });
    try buf.appendSlice(allocator, "    crud: impl,\n    persistence: *persistence.");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Persistence,\n\n");
    try buf.appendSlice(allocator, "    pub fn init(p: *persistence.");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Persistence) @This() {\n        var self: @This() = .{ .crud = impl.init(p), .persistence = p };\n        self.crud.validate = &validate;\n        return self;\n    }\n\n");
    try appendPrint(allocator, &buf, "    pub fn validate(e: model.{s}) anyerror!void {{\n", .{P});
    for (e.fields) |f| {
        if (f.required and (std.mem.eql(u8, f.field_type, "string") or std.mem.eql(u8, f.field_type, "text"))) {
            try buf.appendSlice(allocator, "        if (e.");
            try buf.appendSlice(allocator, f.name);
            try buf.appendSlice(allocator, ".len == 0) return error.ValidationFailed;\n");
        }
    }
    try buf.appendSlice(allocator,
        \\    }
        \\
        \\    /// Multi-statement atomic writes: runs `f` inside a transaction
        \\    /// (rollback on error) — custom business methods needing cross-table
        \\    /// consistency use this instead of hand-rolling begin/commit/rollback.
        \\    pub fn transact(self: *@This(), comptime T: type, f: *const fn (*zigmodu.data.sqlx.Transaction) zigmodu.ZigModuError!T) zigmodu.ZigModuError!T {
        \\        return self.persistence.backend.client.transact(T, f);
        \\    }
        \\    pub fn transactWith(self: *@This(), comptime T: type, comptime Ctx: type, ctx: Ctx, f: *const fn (*zigmodu.data.sqlx.Transaction, Ctx) zigmodu.ZigModuError!T) zigmodu.ZigModuError!T {
        \\        return self.persistence.backend.client.transactWith(T, Ctx, ctx, f);
        \\    }
        \\};
        \\
    );
    return buf.toOwnedSlice(allocator);
}

fn emitApi(allocator: std.mem.Allocator, e: *const Entity, P: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try appendPrint(allocator, &buf, "//! Generated by zmodu saas — {s} API (autoCrud: tenant-scoped CRUD, JWT, paged)\n", .{e.name});
    try buf.appendSlice(allocator,
        \\const zigmodu = @import("zigmodu");
        \\const model = @import("model.zig");
        \\const service = @import("service.zig");
        \\
        \\pub const
    );
    try buf.appendSlice(allocator, " ");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Api = zigmodu.http.CrudApi(model.");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, ", service.");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Service, .{});\n");
    return buf.toOwnedSlice(allocator);
}

fn emitTests(allocator: std.mem.Allocator, e: *const Entity, P: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try appendPrint(allocator, &buf, "//! Generated by zmodu saas — {s} smoke test (in-memory sqlite)\n", .{e.name});
    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const model = @import("model.zig");
        \\const persistence = @import("persistence.zig");
        \\const service = @import("service.zig");
        \\
    );
    try appendPrint(allocator, &buf, "test \"{s} persistence + CrudService round-trip\" {{\n", .{e.name});
    try buf.appendSlice(allocator,
        \\    const allocator = std.testing.allocator;
        \\    var client = zigmodu.data.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
        \\    defer client.deinit();
        \\    try client.connect();
        \\    _ = try client.exec("CREATE TABLE
    );
    try buf.appendSlice(allocator, " ");
    try buf.appendSlice(allocator, e.name);
    try buf.appendSlice(allocator, " (id INTEGER PRIMARY KEY AUTOINCREMENT, org_id INTEGER NOT NULL, ");
    for (e.fields) |f| {
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, " ");
        if (std.mem.eql(u8, f.field_type, "number") or std.mem.eql(u8, f.field_type, "boolean")) {
            try buf.appendSlice(allocator, "INTEGER");
        } else {
            try buf.appendSlice(allocator, "TEXT");
        }
        try buf.appendSlice(allocator, " NOT NULL, ");
    }
    try buf.appendSlice(allocator, "created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)\", &.{});\n\n");
    try buf.appendSlice(allocator,
        \\    var backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
        \\    var persist = persistence.
    );
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Persistence.init(&backend);\n    var svc = service.");
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator, "Service.init(&persist);\n\n");
    try buf.appendSlice(allocator,
        \\    var bus = zigmodu.TypedEventBus(zigmodu.data.CrudEvent(model.
    );
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator,
        \\)).init(allocator);
        \\    defer bus.deinit();
        \\    svc.crud.setEventBus(&bus);
        \\
    );
    // create with sample values (validate hook runs for required strings)
    try buf.appendSlice(allocator, "    const id = try svc.crud.create(.{ .org_id = 1, ");
    for (e.fields) |f| {
        try buf.appendSlice(allocator, ".");
        try buf.appendSlice(allocator, f.name);
        try buf.appendSlice(allocator, " = ");
        if (std.mem.eql(u8, f.field_type, "number")) {
            try buf.appendSlice(allocator, "100");
        } else if (std.mem.eql(u8, f.field_type, "boolean")) {
            try buf.appendSlice(allocator, "true");
        } else {
            try buf.appendSlice(allocator, "\"alice\"");
        }
        try buf.appendSlice(allocator, ", ");
    }
    try buf.appendSlice(allocator, "});\n");
    try buf.appendSlice(allocator,
        \\    try std.testing.expect(id > 0);
        \\    try std.testing.expectEqual(@as(u64, 1), bus.publishedCount());
        \\
        \\    var items = try svc.crud.list(1, 1, 10, null);
        \\    defer items.deinit(allocator);
        \\    try std.testing.expectEqual(@as(usize, 1), items.items.len);
        \\
        \\    const got = (try svc.crud.get(allocator, 1, id)).?;
        \\    defer zigmodu.data.sqlx.freeScanned(allocator, model.
    );
    try buf.appendSlice(allocator, P);
    try buf.appendSlice(allocator,
        \\, got);
        \\    try std.testing.expectEqual(id, got.id);
        \\
        \\    var updated = got;
        \\    updated.org_id = 1;
        \\    try svc.crud.update(updated, 1);
        \\    try std.testing.expectEqual(@as(u64, 2), bus.publishedCount());
        \\
        \\    try svc.crud.delete(1, id);
        \\    try std.testing.expectEqual(@as(u64, 3), bus.publishedCount());
        \\
        \\    const tx_id = try svc.transact(i64, struct {
        \\        fn f(tx: *zigmodu.data.sqlx.Transaction) zigmodu.ZigModuError!i64 {
        \\            _ = tx;
        \\            return 42;
        \\        }
        \\    }.f);
        \\    try std.testing.expectEqual(@as(i64, 42), tx_id);
        \\}
        \\
    );
    // negative validation test when a required string/text field exists
    var has_required_string = false;
    for (e.fields) |f| {
        if (f.required and (std.mem.eql(u8, f.field_type, "string") or std.mem.eql(u8, f.field_type, "text"))) {
            has_required_string = true;
            break;
        }
    }
    if (has_required_string) {
        var required_field: []const u8 = "";
        for (e.fields) |f| {
            if (f.required and (std.mem.eql(u8, f.field_type, "string") or std.mem.eql(u8, f.field_type, "text"))) {
                required_field = f.name;
                break;
            }
        }
        try appendPrint(allocator, &buf, "test \"{s} validate rejects empty required fields\" {{\n", .{e.name});
        try buf.appendSlice(allocator,
            \\    const allocator = std.testing.allocator;
            \\    var client = zigmodu.data.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
            \\    defer client.deinit();
            \\    try client.connect();
            \\    var backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &client };
            \\    var persist = persistence.
        );
        try buf.appendSlice(allocator, P);
        try buf.appendSlice(allocator, "Persistence.init(&backend);\n    var svc = service.");
        try buf.appendSlice(allocator, P);
        try buf.appendSlice(allocator,
            \\Service.init(&persist);
            \\    try std.testing.expectError(error.ValidationFailed, svc.crud.create(.{ .org_id = 1, .
        );
        try buf.appendSlice(allocator, required_field);
        try buf.appendSlice(allocator,
            \\ = "" }));
            \\}
            \\
        );
    }
    return buf.toOwnedSlice(allocator);
}

fn emitModuleAndRoot(allocator: std.mem.Allocator, e: *const Entity) !struct { module: []const u8, root: []const u8 } {
    var mb = std.ArrayList(u8).empty;
    errdefer mb.deinit(allocator);
    try appendPrint(allocator, &mb, "//! Generated by zmodu saas — {s} module\n", .{e.name});
    try mb.appendSlice(allocator, "const zigmodu = @import(\"zigmodu\");\npub const info = zigmodu.api.Module{\n    .name = \"");
    try mb.appendSlice(allocator, e.name);
    try mb.appendSlice(allocator, "\",\n    .description = \"");
    try mb.appendSlice(allocator, e.name);
    try mb.appendSlice(allocator, " business module\",\n    .dependencies = &.{},\n};\npub fn init() !void {}\npub fn deinit() void {}\n");
    var rb = std.ArrayList(u8).empty;
    errdefer rb.deinit(allocator);
    try rb.appendSlice(allocator,
        \\pub const model = @import("model.zig");
        \\pub const persistence = @import("persistence.zig");
        \\pub const service = @import("service.zig");
        \\pub const api = @import("api.zig");
        \\
    );
    return .{ .module = try mb.toOwnedSlice(allocator), .root = try rb.toOwnedSlice(allocator) };
}

/// Generate the six-file business module for one entity into `out_dir/<name>/`.
pub fn generateModule(
    io: std.Io,
    allocator: std.mem.Allocator,
    model_json: []const u8,
    out_dir: []const u8,
) !void {
    const entities = try parseModel(allocator, model_json);
    defer {
        for (entities) |*e| {
            allocator.free(e.name);
            for (e.fields) |f| {
                allocator.free(f.name);
                allocator.free(f.field_type);
                if (f.default) |d| allocator.free(d);
            }
            allocator.free(e.fields);
        }
        allocator.free(entities);
    }

    for (entities) |*e| {
        const P = try pascal(allocator, e.name);
        defer allocator.free(P);
        const mod_dir = try std.fs.path.join(allocator, &.{ out_dir, e.name });
        defer allocator.free(mod_dir);
        std.Io.Dir.cwd().createDirPath(io, mod_dir) catch {};

        const pairs = [_]struct { name: []const u8, content: []const u8 }{
            .{ .name = "model.zig", .content = try emitModel(allocator, e, P) },
            .{ .name = "persistence.zig", .content = try emitPersistence(allocator, e, P) },
            .{ .name = "service.zig", .content = try emitService(allocator, e, P) },
            .{ .name = "api.zig", .content = try emitApi(allocator, e, P) },
            .{ .name = "tests.zig", .content = try emitTests(allocator, e, P) },
        };
        for (pairs) |pair| {
            const file_path = try std.fs.path.join(allocator, &.{ mod_dir, pair.name });
            const file = try std.Io.Dir.cwd().createFile(io, file_path, .{});
            try file.writeStreamingAll(io, pair.content);
            file.close(io);
            allocator.free(file_path);
            allocator.free(pair.content);
        }
        const mr = try emitModuleAndRoot(allocator, e);
        defer allocator.free(mr.module);
        defer allocator.free(mr.root);
        const mp = try std.fs.path.join(allocator, &.{ mod_dir, "module.zig" });
        const mf = try std.Io.Dir.cwd().createFile(io, mp, .{});
        try mf.writeStreamingAll(io, mr.module);
        mf.close(io);
        allocator.free(mp);
        const rp = try std.fs.path.join(allocator, &.{ mod_dir, "root.zig" });
        const rf = try std.Io.Dir.cwd().createFile(io, rp, .{});
        try rf.writeStreamingAll(io, mr.root);
        rf.close(io);
        allocator.free(rp);
        std.log.info("saas: generated module {s} -> {s}", .{ e.name, mod_dir });
    }
}

// ── tests ─────────────────────────────────────────────────────────────────

test "emitSchemaSql produces org-scoped CREATE TABLE" {
    const allocator = std.testing.allocator;
    const model =
        \\{"entities":[{"name":"orders","fields":[
        \\  {"name":"customer","type":"string","required":true},
        \\  {"name":"amount","type":"number"},
        \\  {"name":"status","type":"string","default":"pending"}
        \\]}]}
    ;
    const sql = try emitSchemaSql(allocator, model);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE TABLE orders") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "org_id INTEGER NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "customer TEXT NOT NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "amount INTEGER") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "created_at INTEGER NOT NULL") != null);
}

test "emitSchemaSql rejects unsupported types" {
    const allocator = std.testing.allocator;
    const model = "{\"entities\":[{\"name\":\"x\",\"fields\":[{\"name\":\"a\",\"type\":\"blob\"}]}]}";
    try std.testing.expectError(error.UnsupportedFieldType, emitSchemaSql(allocator, model));
}
