//! `zmodu ai` — AI skill registry CLI integration.
//!
//!   zmodu ai export-skills [--out skills.json]
//!     Write the built-in framework AI skill catalog (same JSON shape as
//!     zigmodu.ai.skill_export.toSkillsJson).
//!
//!   zmodu ai openapi --in skills.json [--out openapi.json]
//!     Convert a skills catalog (built-in or app-exported) into an OpenAPI
//!     3.0 document (one POST /skills/{name} operation per skill).

const std = @import("std");

const ParamType = enum { string, number, boolean, array, object };

const ParamSpec = struct {
    name: []const u8,
    type: ParamType,
    description: []const u8,
    required: bool = false,
};

const SkillSpec = struct {
    name: []const u8,
    description: []const u8,
    parameters: []const ParamSpec,
};

/// Built-in framework AI skills (mirrors the modules that register them).
const builtin: []const SkillSpec = &.{
    .{ .name = "db.query", .description = "Run a read-only parameterized SELECT", .parameters = &.{
        .{ .name = "sql", .type = .string, .description = "SELECT statement with ? placeholders", .required = true },
        .{ .name = "args", .type = .array, .description = "Bind values", .required = false },
    } },
    .{ .name = "entity.lookup", .description = "Look up a whitelisted entity by primary key", .parameters = &.{
        .{ .name = "entity", .type = .string, .description = "Registered entity name", .required = true },
        .{ .name = "id", .type = .number, .description = "Primary key value", .required = true },
    } },
    .{ .name = "entity.list", .description = "List whitelisted entities (tenant-scoped when configured)", .parameters = &.{
        .{ .name = "entity", .type = .string, .description = "Registered entity name", .required = true },
        .{ .name = "limit", .type = .number, .description = "Row cap", .required = false },
        .{ .name = "page", .type = .number, .description = "Page number", .required = false },
    } },
    .{ .name = "list_schedulable_tasks", .description = "List tasks that can be scheduled", .parameters = &.{} },
    .{ .name = "schedule_job", .description = "Schedule a named task on a 5-field cron expression", .parameters = &.{
        .{ .name = "task", .type = .string, .description = "Task name", .required = true },
        .{ .name = "expr", .type = .string, .description = "Cron expression", .required = true },
    } },
    .{ .name = "list_jobs", .description = "List scheduled jobs", .parameters = &.{} },
    .{ .name = "cancel_job", .description = "Cancel a scheduled job", .parameters = &.{
        .{ .name = "job", .type = .string, .description = "Job name", .required = true },
    } },
    .{ .name = "approval.request", .description = "Submit a request through the app-registered approval chain", .parameters = &.{
        .{ .name = "subject", .type = .string, .description = "What is being approved", .required = true },
        .{ .name = "amount", .type = .number, .description = "Amount involved", .required = true },
    } },
    .{ .name = "kpi.query", .description = "Query an app-registered business metric", .parameters = &.{
        .{ .name = "metric", .type = .string, .description = "Metric name", .required = true },
    } },
    .{ .name = "notification.send", .description = "Send a notification to a named channel", .parameters = &.{
        .{ .name = "channel", .type = .string, .description = "Channel name", .required = true },
        .{ .name = "title", .type = .string, .description = "Title", .required = true },
        .{ .name = "body", .type = .string, .description = "Body", .required = true },
    } },
};

pub fn exportSkills(io: std.Io, allocator: std.mem.Allocator, out_path: ?[]const u8) !void {
    const json = try renderSkillsJson(allocator);
    defer allocator.free(json);
    if (out_path) |path| {
        try writeFile(io, path, json);
        std.log.info("wrote {d} skills to {s}", .{ builtin.len, path });
    } else {
        var out_buf: [8192]u8 = undefined;
        var out_file = std.Io.File.stdout();
        var w = out_file.writer(io, &out_buf);
        try w.interface.writeAll(json);
        try w.interface.writeAll("\n");
    }
}

pub fn openapi(io: std.Io, allocator: std.mem.Allocator, in_path: []const u8, out_path: ?[]const u8) !void {
    const catalog = try std.Io.Dir.cwd().readFileAlloc(io, in_path, allocator, std.Io.Limit.limited(8 * 1024 * 1024));
    defer allocator.free(catalog);
    const doc = try renderOpenApi(allocator, catalog);
    defer allocator.free(doc);
    if (out_path) |path| {
        try writeFile(io, path, doc);
        std.log.info("wrote OpenAPI doc to {s}", .{path});
    } else {
        var out_buf: [8192]u8 = undefined;
        var out_file = std.Io.File.stdout();
        var w = out_file.writer(io, &out_buf);
        try w.interface.writeAll(doc);
        try w.interface.writeAll("\n");
    }
}

fn renderSkillsJson(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"skills\":[");
    for (builtin, 0..) |s, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.print(allocator, "{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":[", .{ s.name, s.description });
        for (s.parameters, 0..) |p, pi| {
            if (pi > 0) try buf.append(allocator, ',');
            try buf.print(allocator, "{{\"name\":\"{s}\",\"type\":\"{s}\",\"description\":\"{s}\",\"required\":{s}}}", .{ p.name, @tagName(p.type), p.description, if (p.required) "true" else "false" });
        }
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

fn renderOpenApi(allocator: std.mem.Allocator, catalog_json: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, catalog_json, .{});
    defer parsed.deinit();
    const skills = parsed.value.object.get("skills") orelse return error.MissingSkills;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = std.json.ObjectMap{};
    try putString(&doc, a, "openapi", "3.0.3");
    var info = std.json.ObjectMap{};
    try putString(&info, a, "title", "AI Skills");
    try putString(&info, a, "version", "1.0.0");
    try doc.put(a, try a.dupe(u8, "info"), .{ .object = info });
    var paths = std.json.ObjectMap{};

    for (skills.array.items) |item| {
        const obj = item.object;
        const name = obj.get("name").?.string;
        const description = if (obj.get("description")) |d| d.string else "";
        const params = obj.get("parameters").?.array;

        var op = std.json.ObjectMap{};
        try putString(&op, a, "summary", description);
        try putString(&op, a, "operationId", name);
        var props = std.json.ObjectMap{};
        var required = std.json.Array.init(a);
        for (params.items) |p| {
            const po = p.object;
            var ps = std.json.ObjectMap{};
            try putString(&ps, a, "type", po.get("type").?.string);
            try putString(&ps, a, "description", if (po.get("description")) |d| d.string else "");
            try props.put(a, try a.dupe(u8, po.get("name").?.string), .{ .object = ps });
            if (po.get("required")) |r| {
                if (r.bool) try required.append(.{ .string = try a.dupe(u8, po.get("name").?.string) });
            }
        }
        var schema = std.json.ObjectMap{};
        try putString(&schema, a, "type", "object");
        try schema.put(a, try a.dupe(u8, "properties"), .{ .object = props });
        try schema.put(a, try a.dupe(u8, "required"), .{ .array = required });
        var media = std.json.ObjectMap{};
        try media.put(a, try a.dupe(u8, "schema"), .{ .object = schema });
        var content = std.json.ObjectMap{};
        try content.put(a, try a.dupe(u8, "application/json"), .{ .object = media });
        var request_body = std.json.ObjectMap{};
        try request_body.put(a, try a.dupe(u8, "required"), .{ .bool = true });
        try request_body.put(a, try a.dupe(u8, "content"), .{ .object = content });
        try op.put(a, try a.dupe(u8, "requestBody"), .{ .object = request_body });

        var ok_schema = std.json.ObjectMap{};
        try putString(&ok_schema, a, "type", "object");
        var ok_media = std.json.ObjectMap{};
        try ok_media.put(a, try a.dupe(u8, "schema"), .{ .object = ok_schema });
        var ok_content = std.json.ObjectMap{};
        try ok_content.put(a, try a.dupe(u8, "application/json"), .{ .object = ok_media });
        var ok = std.json.ObjectMap{};
        try putString(&ok, a, "description", "OK");
        try ok.put(a, try a.dupe(u8, "content"), .{ .object = ok_content });
        var responses = std.json.ObjectMap{};
        try responses.put(a, try a.dupe(u8, "200"), .{ .object = ok });
        try op.put(a, try a.dupe(u8, "responses"), .{ .object = responses });

        var post = std.json.ObjectMap{};
        try post.put(a, try a.dupe(u8, "post"), .{ .object = op });
        const path_key = try std.fmt.allocPrint(a, "/skills/{s}", .{name});
        try paths.put(a, path_key, .{ .object = post });
    }
    try doc.put(a, try a.dupe(u8, "paths"), .{ .object = paths });
    const out_value: std.json.Value = .{ .object = doc };
    return try std.json.Stringify.valueAlloc(allocator, out_value, .{});
}

fn putString(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}
