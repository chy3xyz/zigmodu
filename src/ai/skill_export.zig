//! Skill registry export: renders a `SkillRegistry` as a compact skills
//! catalog JSON (machine-readable, for CLIs / docs) or as an OpenAPI 3.0
//! document (every skill becomes a `POST /skills/{name}` operation, with the
//! request body schema derived from the tool parameters). Serve the OpenAPI
//! doc from an app endpoint or feed the catalog to `zmodu ai openapi`.

const std = @import("std");
const SkillRegistry = @import("skill.zig").SkillRegistry;

pub const OpenApiOpts = struct {
    title: []const u8 = "AI Skills",
    version: []const u8 = "1.0.0",
    /// Path prefix applied to every operation (default: `/skills`).
    base_path: []const u8 = "/skills",
};

/// Compact catalog: `{"skills":[{name, description, parameters:[{name,type,description,required}]}]}`.
pub fn toSkillsJson(registry: *SkillRegistry, allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var skills = std.json.Array.init(a);
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(a);
    try collectNames(registry, a, &names);
    for (names.items) |name| {
        const tool = registry.get(name) orelse continue;
        var s = std.json.ObjectMap{};
        try putString(&s, a, "name", tool.name);
        try putString(&s, a, "description", tool.description);
        var params = std.json.Array.init(a);
        for (tool.parameters) |p| {
            var po = std.json.ObjectMap{};
            try putString(&po, a, "name", p.name);
            try putString(&po, a, "type", @tagName(p.type));
            try putString(&po, a, "description", p.description);
            try po.put(a, try a.dupe(u8, "required"), .{ .bool = p.required });
            try params.append(.{ .object = po });
        }
        try s.put(a, try a.dupe(u8, "parameters"), .{ .array = params });
        try skills.append(.{ .object = s });
    }
    var doc = std.json.ObjectMap{};
    try doc.put(a, try a.dupe(u8, "skills"), .{ .array = skills });
    const out_value: std.json.Value = .{ .object = doc };
    return try std.json.Stringify.valueAlloc(allocator, out_value, .{});
}

/// OpenAPI 3.0.3 document: one `POST {base_path}/{name}` operation per skill.
pub fn toOpenApi(registry: *SkillRegistry, allocator: std.mem.Allocator, opts: OpenApiOpts) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var doc = std.json.ObjectMap{};
    try putString(&doc, a, "openapi", "3.0.3");
    var info = std.json.ObjectMap{};
    try putString(&info, a, "title", opts.title);
    try putString(&info, a, "version", opts.version);
    try doc.put(a, try a.dupe(u8, "info"), .{ .object = info });
    var paths = std.json.ObjectMap{};

    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(a);
    try collectNames(registry, a, &names);
    for (names.items) |name| {
        const tool = registry.get(name) orelse continue;
        var op = std.json.ObjectMap{};
        try putString(&op, a, "summary", tool.description);
        try putString(&op, a, "operationId", tool.name);

        var props = std.json.ObjectMap{};
        var required = std.json.Array.init(a);
        for (tool.parameters) |p| {
            var ps = std.json.ObjectMap{};
            try putString(&ps, a, "type", jsonType(p.type));
            try putString(&ps, a, "description", p.description);
            try props.put(a, try a.dupe(u8, p.name), .{ .object = ps });
            if (p.required) try required.append(.{ .string = try a.dupe(u8, p.name) });
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
        const path_key = try std.fmt.allocPrint(a, "{s}/{s}", .{ opts.base_path, tool.name });
        try paths.put(a, path_key, .{ .object = post });
    }
    try doc.put(a, try a.dupe(u8, "paths"), .{ .object = paths });
    const out_value: std.json.Value = .{ .object = doc };
    return try std.json.Stringify.valueAlloc(allocator, out_value, .{});
}

fn putString(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try obj.put(allocator, try allocator.dupe(u8, key), .{ .string = try allocator.dupe(u8, value) });
}

fn collectNames(registry: *SkillRegistry, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    const count = registry.count();
    var scratch = try allocator.alloc([]const u8, count);
    defer allocator.free(scratch);
    const n = registry.names(scratch);
    const slice = scratch[0..n];
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    for (slice) |nm| try out.append(allocator, nm);
}

fn jsonType(t: @import("skill.zig").Param.Type) []const u8 {
    return switch (t) {
        .string => "string",
        .number => "number",
        .boolean => "boolean",
        .array => "array",
        .object => "object",
    };
}

test "toSkillsJson and toOpenApi render a registry" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "kpi.query",
        .description = "Query a business metric",
        .parameters = &.{
            .{ .name = "metric", .type = .string, .description = "Metric name", .required = true },
            .{ .name = "window", .type = .number, .description = "Lookback days", .required = false },
        },
        .handler = struct {
            fn h(_: *@import("skill.zig").SkillContext, _: std.json.Value) anyerror!std.json.Value {
                return .null;
            }
        }.h,
    });

    const catalog = try toSkillsJson(&registry, allocator);
    defer allocator.free(catalog);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"name\":\"kpi.query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, catalog, "\"required\":true") != null);

    const doc = try toOpenApi(&registry, allocator, .{});
    defer allocator.free(doc);
    // Both outputs must parse as valid JSON.
    var cat_parsed = try std.json.parseFromSlice(std.json.Value, allocator, catalog, .{});
    defer cat_parsed.deinit();
    var doc_parsed = try std.json.parseFromSlice(std.json.Value, allocator, doc, .{});
    defer doc_parsed.deinit();
    try std.testing.expectEqualStrings("3.0.3", doc_parsed.value.object.get("openapi").?.string);
    try std.testing.expect(doc_parsed.value.object.get("paths").?.object.get("/skills/kpi.query") != null);
}
