//! SkillRegistry → MCP bridge: expose the framework's registered AI skills
//! as Model Context Protocol tools, so LLM platforms (Claude/Codex/etc.)
//! can call `db.query`, `kpi.query`, `approval.request`, ... over MCP.
//!
//!   - `toMcpTools` — render skills as the MCP `tools/list` payload;
//!   - `handleToolCall` — dispatch a `tools/call` to the registry;
//!   - `serveStdio` — a minimal JSON-RPC 2.0 MCP server over stdin/stdout.
//!
//! The application owns security: skills keep their `required_permission`
//! gates, and the `SkillContext` template passed to `serveStdio` carries
//! tenant/user/permissions for the MCP session.

const std = @import("std");
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const freeValue = @import("skill.zig").freeValue;
const putJsonField = @import("skill.zig").putJsonField;
const json_shape = @import("json_shape.zig");

/// Render the registry as the MCP `tools/list` result
/// (`{"tools":[{name,description,inputSchema}]}`).
pub fn toMcpTools(registry: *SkillRegistry, allocator: std.mem.Allocator) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tools = std.json.Array.init(a);
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(a);
    const count = registry.count();
    var scratch = try a.alloc([]const u8, count);
    defer a.free(scratch);
    const n = registry.names(scratch);
    const slice = scratch[0..n];
    std.mem.sort([]const u8, slice, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    for (slice) |nm| try names.append(a, nm);

    for (names.items) |nm| {
        const tool = registry.get(nm) orelse continue;
        var props = std.json.ObjectMap{};
        var required = std.json.Array.init(a);
        for (tool.parameters) |p| {
            var ps = std.json.ObjectMap{};
            try putString(&ps, a, "type", switch (p.type) {
                .string => "string",
                .number => "number",
                .boolean => "boolean",
                .array => "array",
                .object => "object",
            });
            try putString(&ps, a, "description", p.description);
            try props.put(a, try a.dupe(u8, p.name), .{ .object = ps });
            if (p.required) try required.append(.{ .string = try a.dupe(u8, p.name) });
        }
        var schema = std.json.ObjectMap{};
        try putString(&schema, a, "type", "object");
        try schema.put(a, try a.dupe(u8, "properties"), .{ .object = props });
        try schema.put(a, try a.dupe(u8, "required"), .{ .array = required });

        var t = std.json.ObjectMap{};
        try putString(&t, a, "name", tool.name);
        try putString(&t, a, "description", tool.description);
        try t.put(a, try a.dupe(u8, "inputSchema"), .{ .object = schema });
        try tools.append(.{ .object = t });
    }

    var out = std.json.ObjectMap{};
    try out.put(a, try a.dupe(u8, "tools"), .{ .array = tools });
    const value: std.json.Value = .{ .object = out };
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

/// Dispatch an MCP `tools/call` (params with `name` + `arguments`) through the
/// registry. Returns the MCP result content array:
/// `{"content":[{"type":"text","text":"<json>"}]}`.
pub fn handleToolCall(
    registry: *SkillRegistry,
    ctx: *SkillContext,
    params: std.json.Value,
) !std.json.Value {
    const obj = try json_shape.object(params);
    const name = (try json_shape.getString(obj, "name")) orelse return error.MissingToolName;
    const args = obj.get("arguments") orelse @as(std.json.Value, .{ .object = .{} });
    const result = try registry.dispatch(name, ctx, args);
    defer freeValue(ctx.allocator, result);
    const text = try std.json.Stringify.valueAlloc(ctx.allocator, result, .{});
    // The tree is built on the *caller's* allocator (this is the path with no
    // per-line arena), so each level is guarded on its own. `text` is released
    // unconditionally — `putJsonField` copies a `.string` value, so no level
    // ever owns this pointer and the copy inside `item` is the tree's own.
    defer ctx.allocator.free(text);
    var out = std.json.ObjectMap{};
    errdefer freeValue(ctx.allocator, .{ .object = out });
    var content = std.json.Array.init(ctx.allocator);
    {
        // The array hand-over is *outside* this block on purpose: `putJsonField`
        // releases a non-string value itself when the map refuses the field, so
        // a guard still armed at that call would free the same array twice.
        errdefer freeValue(ctx.allocator, .{ .array = content });
        var item = std.json.ObjectMap{};
        errdefer freeValue(ctx.allocator, .{ .object = item });
        try putString(&item, ctx.allocator, "type", "text");
        try putJsonField(ctx.allocator, &item, "text", .{ .string = text });
        try content.append(.{ .object = item });
    }
    try putJsonField(ctx.allocator, &out, "content", .{ .array = content });
    return .{ .object = out };
}

/// Minimal MCP server over stdin/stdout (JSON-RPC 2.0, newline-delimited).
/// Blocks until stdin closes. `ctx_template` provides the session identity
/// (tenant/user/permissions) for every skill dispatch.
pub fn serveStdio(
    io: std.Io,
    allocator: std.mem.Allocator,
    registry: *SkillRegistry,
    ctx_template: SkillContext,
) !void {
    var stdin_buf: [65536]u8 = undefined;
    var stdin_file = std.Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &stdin_buf);
    var stdout_buf: [65536]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var line_buf: [65536]u8 = undefined;
    while (true) {
        var line_dest = std.Io.Writer.fixed(&line_buf);
        const n = stdin_reader.interface.streamDelimiter(&line_dest, '\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        _ = stdin_reader.interface.takeByte() catch |err| {
            std.log.debug("[mcp] consuming frame delimiter failed: {s}", .{@errorName(err)});
        };
        if (n == 0) continue;
        const line = line_buf[0..n];

        var ctx = ctx_template;
        const resp = serveLine(allocator, registry, &ctx, line) catch |err| {
            const e = try rpcError(allocator, null, -32603, @errorName(err));
            defer allocator.free(e);
            try stdout.writeAll(e);
            try stdout.writeAll("\n");
            try stdout.flush();
            continue;
        };
        defer allocator.free(resp);
        if (resp.len == 0) continue;
        try stdout.writeAll(resp);
        try stdout.writeAll("\n");
        try stdout.flush();
    }
}

fn serveLine(
    allocator: std.mem.Allocator,
    registry: *SkillRegistry,
    ctx: *SkillContext,
    line: []const u8,
) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return rpcError(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();
    // `parsed` is whatever the peer sent: valid JSON that is not an object
    // (`123`, `[]`), or an object whose `method` is not a string. Both used to
    // abort the server on a union-tag mismatch.
    const root = json_shape.object(parsed.value) catch
        return rpcError(allocator, null, -32600, "Invalid Request");
    const method = (json_shape.getString(root, "method") catch
        return rpcError(allocator, null, -32600, "Method must be a string")) orelse
        return rpcError(allocator, null, -32600, "Missing method");
    const id: ?i64 = if (root.get("id")) |v| switch (v) {
        .integer => |i| i,
        else => null,
    } else null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    if (std.mem.eql(u8, method, "initialize")) {
        var info = std.json.ObjectMap{};
        try putString(&info, a, "protocolVersion", "2024-11-05");
        try putString(&info, a, "name", "zigmodu");
        try putString(&info, a, "version", "0.39.2");
        try putString(&info, a, "serverInfo", "zigmodu-ai");
        var capabilities = std.json.ObjectMap{};
        var tool_caps = std.json.ObjectMap{};
        try tool_caps.put(a, try a.dupe(u8, "listChanged"), .{ .bool = false });
        try capabilities.put(a, try a.dupe(u8, "tools"), .{ .object = tool_caps });
        try info.put(a, try a.dupe(u8, "capabilities"), .{ .object = capabilities });
        return rpcSuccess(allocator, a, id, .{ .object = info });
    } else if (std.mem.eql(u8, method, "tools/list")) {
        var list = std.json.ObjectMap{};
        const tools = try toMcpTools(registry, a);
        defer a.free(tools);
        var parsed_tools = try std.json.parseFromSlice(std.json.Value, a, tools, .{});
        defer parsed_tools.deinit();
        try list.put(a, try a.dupe(u8, "tools"), parsed_tools.value.object.get("tools").?);
        return rpcSuccess(allocator, a, id, .{ .object = list });
    } else if (std.mem.eql(u8, method, "tools/call")) {
        const params = root.get("params") orelse return rpcError(allocator, id, -32602, "Missing params");
        // `params` and `params.name` are peer-authored: a wrong shape is a
        // parameter error rather than the -32603 the stdio loop reports for an
        // internal failure — and rather than the abort it used to be.
        const result = handleToolCall(registry, ctx, params) catch |err| switch (err) {
            error.MalformedJson, error.MissingToolName => return rpcError(allocator, id, -32602, "Invalid params"),
            else => return err,
        };
        defer freeValue(ctx.allocator, result);
        return rpcSuccess(allocator, a, id, result);
    } else if (std.mem.eql(u8, method, "notifications/initialized")) {
        return if (id == null) allocator.dupe(u8, "") else rpcError(allocator, id, -32601, "Method not found");
    }
    return rpcError(allocator, id, -32601, "Method not found");
}

fn rpcSuccess(allocator: std.mem.Allocator, arena_alloc: std.mem.Allocator, id: ?i64, result: std.json.Value) ![]const u8 {
    var resp = std.json.ObjectMap{};
    try putString(&resp, arena_alloc, "jsonrpc", "2.0");
    if (id) |i| try resp.put(arena_alloc, try arena_alloc.dupe(u8, "id"), .{ .integer = i });
    try resp.put(arena_alloc, try arena_alloc.dupe(u8, "result"), result);
    const value: std.json.Value = .{ .object = resp };
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn rpcError(allocator: std.mem.Allocator, id: ?i64, code: i64, message: []const u8) ![]const u8 {
    // Every field goes in through `putJsonField`, which copies the key (and a
    // `.string` value) and releases what it cannot place. The tree is built on
    // the caller's allocator — this runs before the per-line arena exists, and
    // on the paths where it does not matter — so the guard below is what keeps
    // an error answer from stranding its keys and values when a later field or
    // the stringify fails.
    var resp = std.json.ObjectMap{};
    errdefer freeValue(allocator, .{ .object = resp });
    try putString(&resp, allocator, "jsonrpc", "2.0");
    if (id) |i| try putJsonField(allocator, &resp, "id", .{ .integer = i });
    // The error object gets its own scope: `putJsonField` takes ownership of an
    // `.object` value even when it fails, so a guard that outlived the hand-over
    // into `resp` would free the same map a second time.
    const err_obj = blk: {
        var err = std.json.ObjectMap{};
        errdefer freeValue(allocator, .{ .object = err });
        try putJsonField(allocator, &err, "code", .{ .integer = code });
        try putJsonField(allocator, &err, "message", .{ .string = message });
        break :blk err;
    };
    try putJsonField(allocator, &resp, "error", .{ .object = err_obj });
    const value: std.json.Value = .{ .object = resp };
    const out = try std.json.Stringify.valueAlloc(allocator, value, .{});
    // Freed here; the only statement left cannot fail, so the `errdefer` above
    // cannot double-free (the shape `skill.encodeJsonObject` uses too).
    freeValue(allocator, value);
    return out;
}

/// `ObjectMap` copies neither the key nor the value: `putJsonField` copies both
/// and hands the map ownership, so nothing is stranded by a failed `put`.
fn putString(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try putJsonField(allocator, obj, key, .{ .string = value });
}

test "a peer line of the wrong shape is answered, not fatal" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = allocator };

    // Valid JSON that is not a request object, and an object whose `method` is
    // not a string: both used to abort the server on a union-tag mismatch.
    inline for (.{ "123", "[]", "\"x\"", "{\"method\":5}" }) |line| {
        const resp = try serveLine(allocator, &registry, &ctx, line);
        defer allocator.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "-32600") != null);
    }

    // `params` is peer-authored too: a wrong shape is a parameter error, which
    // is also what keeps it out of the -32603 the stdio loop uses for failures.
    const resp = try serveLine(allocator, &registry, &ctx, "{\"method\":\"tools/call\",\"id\":1,\"params\":\"x\"}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "-32602") != null);
}

// `serveLine` answers a malformed line with `rpcError`, whose tree is built on
// the allocator the caller passed in — no per-line arena on that path — so the
// scan covers the field copies, the error sub-object and the stringify.
test "an RPC error answer hands back its tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    var ctx = SkillContext{ .allocator = allocator };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, c: *SkillContext) !void {
            const resp = try serveLine(a, reg, c, "not json");
            defer a.free(resp);
            try std.testing.expect(std.mem.indexOf(u8, resp, "-32700") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &ctx });
}

test "toMcpTools renders skills and handleToolCall dispatches" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "kpi.query",
        .description = "Query a business metric",
        .parameters = &.{
            .{ .name = "metric", .type = .string, .description = "Metric name", .required = true },
        },
        .handler = struct {
            fn h(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                return .{ .integer = 42 };
            }
        }.h,
    });

    const tools_json = try toMcpTools(&registry, allocator);
    defer allocator.free(tools_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, tools_json, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 1), tools.items.len);
    const t = tools.items[0].object;
    try std.testing.expectEqualStrings("kpi.query", t.get("name").?.string);
    const schema = t.get("inputSchema").?.object;
    try std.testing.expectEqualStrings("object", schema.get("type").?.string);
    try std.testing.expect(schema.get("properties").?.object.get("metric") != null);
    try std.testing.expectEqualStrings("metric", schema.get("required").?.array.items[0].string);

    var params = std.json.ObjectMap{};
    try putString(&params, allocator, "name", "kpi.query");
    var args = std.json.ObjectMap{};
    try putString(&args, allocator, "metric", "revenue");
    try params.put(allocator, try allocator.dupe(u8, "arguments"), .{ .object = args });
    var sctx = SkillContext{ .allocator = allocator };
    const result = try handleToolCall(&registry, &sctx, .{ .object = params });
    defer freeValue(allocator, result);
    defer freeValue(allocator, .{ .object = params });
    const content = result.object.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    try std.testing.expect(std.mem.indexOf(u8, content[0].object.get("text").?.string, "42") != null);
}

// `handleToolCall` is the one path in this file that builds its answer on the
// caller's allocator instead of the per-line arena, so every allocation point
// in it — the stringified payload, the `text` field, the content array and the
// root map — is reachable under an allocation failure.
test "handleToolCall hands back its content tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registry.register(.{
        .name = "kpi.query",
        .description = "Query a business metric",
        .parameters = &.{},
        .handler = struct {
            fn h(_: *SkillContext, _: std.json.Value) anyerror!std.json.Value {
                return .{ .integer = 42 };
            }
        }.h,
    });

    var params = std.json.ObjectMap{};
    defer freeValue(allocator, .{ .object = params });
    try putString(&params, allocator, "name", "kpi.query");

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, args: std.json.ObjectMap) !void {
            var sctx = SkillContext{ .allocator = a };
            const result = try handleToolCall(reg, &sctx, .{ .object = args });
            defer freeValue(a, result);
            const content = result.object.get("content").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), content.len);
            try std.testing.expect(std.mem.indexOf(u8, content[0].object.get("text").?.string, "42") != null);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, params });
}
