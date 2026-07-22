// MCP Server — JSON-RPC 2.0 over stdio for Model Context Protocol
const std = @import("std");
const Io = std.Io;
const mcp_types = @import("mcp_types.zig");
const verify_mod = @import("verify.zig");
const main_mod = @import("main.zig");
const sql_diff = @import("sql_diff.zig");

/// Start the MCP server loop on stdin/stdout.
/// Blocks until stdin is closed.
pub fn start(io: Io, allocator: std.mem.Allocator) !void {
    var stdin_buf: [65536]u8 = undefined;
    var stdin_file = Io.File.stdin();
    var stdin_reader = stdin_file.reader(io, &stdin_buf);

    var stdout_buf: [65536]u8 = undefined;
    var stdout_file = Io.File.stdout();
    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var line_buf: [65536]u8 = undefined;

    while (true) {
        var line_dest = Io.Writer.fixed(&line_buf);
        const n = stdin_reader.interface.streamDelimiter(&line_dest, '\n') catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        _ = stdin_reader.interface.takeByte() catch {};

        if (n == 0) continue;
        const line = line_buf[0..n];

        const response = handleMessage(io, allocator, line) catch |err| {
            const resp = try mcp_types.errorResponse(allocator, null, -32603, @errorName(err));
            defer allocator.free(resp);
            try stdout.writeAll(resp);
            try stdout.writeAll("\n");
            try stdout.flush();
            continue;
        };
        defer allocator.free(response);
        if (response.len == 0) continue;
        try stdout.writeAll(response);
        try stdout.writeAll("\n");
        try stdout.flush();
    }
}

/// Parse a JSON-RPC request line and dispatch to the appropriate handler.
/// Returns an owned string (caller must free with allocator).
pub fn handleMessage(io: Io, allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return mcp_types.errorResponse(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    const method = root.get("method") orelse return mcp_types.errorResponse(allocator, null, -32600, "Missing method");
    const method_str = method.string;
    const id_val = root.get("id");
    const id: ?i64 = if (id_val) |v| switch (v) {
        .integer => |i| i,
        else => null,
    } else null;

    // Use arena for building JSON response, then copy result to caller's allocator
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const response_value: std.json.Value = if (std.mem.eql(u8, method_str, "initialize"))
        try buildInitialize(aa, id)
    else if (std.mem.eql(u8, method_str, "tools/list"))
        try buildToolsList(aa, id)
    else if (std.mem.eql(u8, method_str, "tools/call"))
        try buildToolsCallResponse(io, aa, id, root.get("params"))
    else if (std.mem.eql(u8, method_str, "notifications/initialized"))
        return if (id == null) allocator.dupe(u8, "") else mcp_types.errorResponse(allocator, id, -32601, "Method not found")
    else
        return mcp_types.errorResponse(allocator, id, -32601, "Method not found");

    // Serialize under arena, then copy to caller's allocator
    const json_str = try std.json.Stringify.valueAlloc(aa, response_value, .{});
    return try allocator.dupe(u8, json_str);
}

fn buildInitialize(allocator: std.mem.Allocator, id: ?i64) !std.json.Value {
    var result: std.json.ObjectMap = .{};
    try result.put(allocator, "protocolVersion", .{ .string = "2024-11-05" });
    try result.put(allocator, "capabilities", .{ .object = .{} });
    var server_info: std.json.ObjectMap = .{};
    try server_info.put(allocator, "name", .{ .string = "zmodu" });
    try server_info.put(allocator, "version", .{ .string = main_mod.ZMODU_VERSION });
    try result.put(allocator, "serverInfo", .{ .object = server_info });
    return buildResponseValue(allocator, id, .{ .object = result });
}

fn buildToolsList(allocator: std.mem.Allocator, id: ?i64) !std.json.Value {
    var tools = std.json.Array.init(allocator);

    try tools.append(try makeToolSchema(allocator, "zmodu_scaffold", "Generate a full ZigModu project from SQL DDL", &.{
        .{ .name = "sql_path", .type = "string", .desc = "Path to SQL file" },
        .{ .name = "output_dir", .type = "string", .desc = "Output directory" },
        .{ .name = "diff_old_sql", .type = "string", .desc = "Path to old SQL file for diff (incremental)", .opt = true },
        .{ .name = "orm_backend", .type = "string", .desc = "ORM backend: sqlx (default) or zent", .opt = true },
    }));
    try tools.append(try makeToolSchema(allocator, "zmodu_module", "Generate a single module skeleton", &.{
        .{ .name = "name", .type = "string", .desc = "Module name (snake_case)" },
        .{ .name = "output_dir", .type = "string", .desc = "Project root directory", .opt = true },
    }));
    try tools.append(try makeToolSchema(allocator, "zmodu_version", "Get zmodu version info", &.{}));
    try tools.append(try makeToolSchema(allocator, "zmodu_verify", "Verify a generated project compiles and has correct structure", &.{
        .{ .name = "project_dir", .type = "string", .desc = "Path to the project directory" },
    }));
    try tools.append(try makeToolSchema(allocator, "zmodu_diff", "Compare two SQL files and show table-level changes", &.{
        .{ .name = "old_sql", .type = "string", .desc = "Path to the old SQL file" },
        .{ .name = "new_sql", .type = "string", .desc = "Path to the new SQL file" },
    }));

    var result: std.json.ObjectMap = .{};
    try result.put(allocator, "tools", .{ .array = tools });
    return buildResponseValue(allocator, id, .{ .object = result });
}

fn buildToolsCallResponse(io: Io, allocator: std.mem.Allocator, id: ?i64, params: ?std.json.Value) !std.json.Value {
    if (params == null) {
        return buildErrorResponseValue(allocator, id, -32602, "Missing params");
    }
    const p = params.?.object;
    const tool_name_val = p.get("name") orelse return buildErrorResponseValue(allocator, id, -32602, "Missing tool name");
    const tool_name = tool_name_val.string;
    const arguments = p.get("arguments");

    const result_text = if (std.mem.eql(u8, tool_name, "zmodu_version"))
        try callVersion(allocator)
    else if (std.mem.eql(u8, tool_name, "zmodu_scaffold"))
        try callScaffold(io, allocator, arguments)
    else if (std.mem.eql(u8, tool_name, "zmodu_module"))
        try callModuleCmd(io, allocator, arguments)
    else if (std.mem.eql(u8, tool_name, "zmodu_verify"))
        try callVerify(io, allocator, arguments)
    else if (std.mem.eql(u8, tool_name, "zmodu_diff"))
        try callDiff(io, allocator, arguments)
    else
        return buildErrorResponseValue(allocator, id, -32602, "Unknown tool");

    // Build MCP tool result
    const is_error = std.mem.startsWith(u8, result_text, "{\"error\":");
    var content_item: std.json.ObjectMap = .{};
    try content_item.put(allocator, "type", .{ .string = "text" });
    try content_item.put(allocator, "text", .{ .string = result_text });

    var content_arr = std.json.Array.init(allocator);
    try content_arr.append(.{ .object = content_item });

    var result: std.json.ObjectMap = .{};
    try result.put(allocator, "content", .{ .array = content_arr });
    try result.put(allocator, "isError", .{ .bool = is_error });

    return buildResponseValue(allocator, id, .{ .object = result });
}

// ── Tool implementations (stubs) ──

fn callVersion(allocator: std.mem.Allocator) ![]const u8 {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "version", .{ .string = main_mod.ZMODU_VERSION });
    try obj.put(allocator, "zig_version", .{ .string = "0.17.0" });
    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = obj }, .{});
}

fn callStub(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, "error", .{ .string = message });
    return try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = obj }, .{});
}

fn callScaffold(io: Io, allocator: std.mem.Allocator, arguments: ?std.json.Value) ![]const u8 {
    if (arguments == null) return callStub(allocator, "Missing arguments");
    const a = arguments.?.object;
    const sql_path = a.get("sql_path") orelse return callStub(allocator, "Missing sql_path");
    const output_dir = a.get("output_dir") orelse return callStub(allocator, "Missing output_dir");

    // Build CLI args for cmdScaffold
    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "--sql", sql_path.string, "--out", output_dir.string, "--name", "app" });
    if (a.get("diff_old_sql")) |diff_old| {
        try args.appendSlice(allocator, &.{ "--diff", diff_old.string });
    }
    if (a.get("orm_backend")) |backend| {
        if (std.mem.eql(u8, backend.string, "zent")) {
            // Zent not supported via this path yet
        }
    }

    main_mod.cmdScaffold(io, allocator, args.items) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"scaffold failed: {}\"}}", .{err});
    };
    return allocator.dupe(u8, "{\"success\":true,\"message\":\"Scaffold completed\"}");
}

fn callModuleCmd(io: Io, allocator: std.mem.Allocator, arguments: ?std.json.Value) ![]const u8 {
    if (arguments == null) return callStub(allocator, "Missing arguments");
    const a = arguments.?.object;
    const name = a.get("name") orelse return callStub(allocator, "Missing name");

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    try args.append(allocator, name.string);

    main_mod.cmdModule(io, allocator, args.items) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"module failed: {}\"}}", .{err});
    };
    return std.fmt.allocPrint(allocator, "{{\"success\":true,\"module\":\"{s}\"}}", .{name.string});
}

fn callVerify(io: Io, allocator: std.mem.Allocator, arguments: ?std.json.Value) ![]const u8 {
    var project_dir: []const u8 = ".";
    if (arguments) |a| {
        if (a.object.get("project_dir")) |v| {
            project_dir = v.string;
        }
    }

    const report = verify_mod.verifyProject(allocator, io, project_dir) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"verify failed: {}\"}}", .{err});
    };
    defer {
        for (report.checks) |c| {
            if (c.details) |d| allocator.free(d);
        }
        allocator.free(report.checks);
        for (report.errors) |e| allocator.free(e);
        allocator.free(report.errors);
        for (report.warnings) |w| allocator.free(w);
        allocator.free(report.warnings);
        allocator.free(report.summary);
    }

    // Build detailed JSON output with proper escaping
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(allocator);

    try parts.appendSlice(allocator, "{\"pass\":");
    try parts.appendSlice(allocator, if (report.pass) "true" else "false");

    const esc_summary = try jsonEscape(allocator, report.summary);
    defer allocator.free(esc_summary);
    try parts.appendSlice(allocator, ",\"summary\":\"");
    try parts.appendSlice(allocator, esc_summary);
    try parts.appendSlice(allocator, "\",\"checks\":[");
    for (report.checks, 0..) |c, i| {
        if (i > 0) try parts.appendSlice(allocator, ",");
        const status_str = switch (c.status) {
            .pass => "pass",
            .fail => "fail",
            .warn => "warn",
            .skip => "skip",
        };
        const esc_name = try jsonEscape(allocator, c.name);
        defer allocator.free(esc_name);
        if (c.details) |d| {
            const esc_details = try jsonEscape(allocator, d);
            defer allocator.free(esc_details);
            const entry = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"status\":\"{s}\",\"details\":\"{s}\"}}", .{ esc_name, status_str, esc_details });
            defer allocator.free(entry);
            try parts.appendSlice(allocator, entry);
        } else {
            const entry = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ esc_name, status_str });
            defer allocator.free(entry);
            try parts.appendSlice(allocator, entry);
        }
    }
    try parts.appendSlice(allocator, "],\"errors\":[");
    for (report.errors, 0..) |e, i| {
        if (i > 0) try parts.appendSlice(allocator, ",");
        const esc_e = try jsonEscape(allocator, e);
        defer allocator.free(esc_e);
        try parts.appendSlice(allocator, "\"");
        try parts.appendSlice(allocator, esc_e);
        try parts.appendSlice(allocator, "\"");
    }
    try parts.appendSlice(allocator, "],\"warnings\":[");
    for (report.warnings, 0..) |warn, i| {
        if (i > 0) try parts.appendSlice(allocator, ",");
        const esc_w = try jsonEscape(allocator, warn);
        defer allocator.free(esc_w);
        try parts.appendSlice(allocator, "\"");
        try parts.appendSlice(allocator, esc_w);
        try parts.appendSlice(allocator, "\"");
    }
    try parts.appendSlice(allocator, "]}");

    return parts.toOwnedSlice(allocator);
}

fn callDiff(io: Io, allocator: std.mem.Allocator, arguments: ?std.json.Value) ![]const u8 {
    if (arguments == null) return callStub(allocator, "Missing arguments");
    const a = arguments.?.object;
    const old_sql_path = a.get("old_sql") orelse return callStub(allocator, "Missing old_sql");
    const new_sql_path = a.get("new_sql") orelse return callStub(allocator, "Missing new_sql");

    const old_sql = Io.Dir.cwd().readFileAlloc(io, old_sql_path.string, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"cannot read old_sql: {}\"}}", .{err});
    };
    defer allocator.free(old_sql);
    const new_sql = Io.Dir.cwd().readFileAlloc(io, new_sql_path.string, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"cannot read new_sql: {}\"}}", .{err});
    };
    defer allocator.free(new_sql);

    const old_tables = main_mod.parseSqlSchema(allocator, old_sql) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"parse old SQL failed: {}\"}}", .{err});
    };
    defer main_mod.freeTableDefs(allocator, old_tables);
    const new_tables = main_mod.parseSqlSchema(allocator, new_sql) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"parse new SQL failed: {}\"}}", .{err});
    };
    defer main_mod.freeTableDefs(allocator, new_tables);

    const diffs = sql_diff.diffTables(allocator, old_tables, new_tables) catch |err| {
        return std.fmt.allocPrint(allocator, "{{\"error\":\"diff failed: {}\"}}", .{err});
    };
    defer {
        for (diffs) |d| if (d.column_changes.len > 0) allocator.free(d.column_changes);
        allocator.free(diffs);
    }

    if (diffs.len == 0) {
        return allocator.dupe(u8, "{\"changed_tables\":0,\"diffs\":[]}");
    }

    // Build simple JSON output using allocPrint
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(allocator);
    try parts.appendSlice(allocator, "{\"changed_tables\":");
    const count_str = try std.fmt.allocPrint(allocator, "{d}", .{diffs.len});
    defer allocator.free(count_str);
    try parts.appendSlice(allocator, count_str);
    try parts.appendSlice(allocator, ",\"diffs\":[");
    for (diffs, 0..) |d, i| {
        if (i > 0) try parts.appendSlice(allocator, ",");
        const change_str = switch (d.change_type) {
            .added => "added",
            .removed => "removed",
            .modified => "modified",
        };
        const esc_table = try jsonEscape(allocator, d.table_name);
        defer allocator.free(esc_table);
        const entry = try std.fmt.allocPrint(allocator, "{{\"table\":\"{s}\",\"change\":\"{s}\"", .{ esc_table, change_str });
        defer allocator.free(entry);
        try parts.appendSlice(allocator, entry);

        // Include column changes for modified tables
        if (d.column_changes.len > 0) {
            try parts.appendSlice(allocator, ",\"column_changes\":[");
            for (d.column_changes, 0..) |cc, ci| {
                if (ci > 0) try parts.appendSlice(allocator, ",");
                const cc_type = switch (cc.change_type) {
                    .added => "added",
                    .removed => "removed",
                    .type_changed => "type_changed",
                    .nullable_changed => "nullable_changed",
                    .default_changed => "default_changed",
                };
                const esc_col = try jsonEscape(allocator, cc.column_name);
                defer allocator.free(esc_col);
                if (cc.old_type) |ot| {
                    const esc_ot = try jsonEscape(allocator, ot);
                    defer allocator.free(esc_ot);
                    const esc_nt = try jsonEscape(allocator, cc.new_type orelse "");
                    defer allocator.free(esc_nt);
                    const cc_entry = try std.fmt.allocPrint(allocator, "{{\"column\":\"{s}\",\"change\":\"{s}\",\"old_type\":\"{s}\",\"new_type\":\"{s}\"}}", .{ esc_col, cc_type, esc_ot, esc_nt });
                    defer allocator.free(cc_entry);
                    try parts.appendSlice(allocator, cc_entry);
                } else {
                    const cc_entry = try std.fmt.allocPrint(allocator, "{{\"column\":\"{s}\",\"change\":\"{s}\"}}", .{ esc_col, cc_type });
                    defer allocator.free(cc_entry);
                    try parts.appendSlice(allocator, cc_entry);
                }
            }
            try parts.appendSlice(allocator, "]");
        }

        try parts.appendSlice(allocator, "}");
    }
    try parts.appendSlice(allocator, "]}");
    return parts.toOwnedSlice(allocator);
}

// ── Helpers ──

fn buildResponseValue(allocator: std.mem.Allocator, id: ?i64, result: std.json.Value) std.json.Value {
    var resp: std.json.ObjectMap = .{};
    resp.put(allocator, "jsonrpc", .{ .string = "2.0" }) catch unreachable;
    if (id) |i| {
        resp.put(allocator, "id", .{ .integer = i }) catch unreachable;
    } else {
        resp.put(allocator, "id", .null) catch unreachable;
    }
    resp.put(allocator, "result", result) catch unreachable;
    return .{ .object = resp };
}

fn buildErrorResponseValue(allocator: std.mem.Allocator, id: ?i64, code: i64, message: []const u8) std.json.Value {
    var resp: std.json.ObjectMap = .{};
    resp.put(allocator, "jsonrpc", .{ .string = "2.0" }) catch unreachable;
    if (id) |i| {
        resp.put(allocator, "id", .{ .integer = i }) catch unreachable;
    } else {
        resp.put(allocator, "id", .null) catch unreachable;
    }
    var err_obj: std.json.ObjectMap = .{};
    err_obj.put(allocator, "code", .{ .integer = code }) catch unreachable;
    err_obj.put(allocator, "message", .{ .string = message }) catch unreachable;
    resp.put(allocator, "error", .{ .object = err_obj }) catch unreachable;
    return .{ .object = resp };
}

/// Escape a string for safe JSON embedding (handles \, ", control chars).
/// Caller owns returned memory.
fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const esc = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(esc);
                try buf.appendSlice(allocator, esc);
            },
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}

const ParamDef = struct {
    name: []const u8,
    type: []const u8,
    desc: []const u8,
    opt: bool = false,
};

fn makeToolSchema(allocator: std.mem.Allocator, name: []const u8, description: []const u8, params: []const ParamDef) !std.json.Value {
    var properties: std.json.ObjectMap = .{};
    var required_arr = std.json.Array.init(allocator);

    for (params) |p| {
        var prop: std.json.ObjectMap = .{};
        try prop.put(allocator, "type", .{ .string = p.type });
        try prop.put(allocator, "description", .{ .string = p.desc });
        try properties.put(allocator, p.name, .{ .object = prop });
        if (!p.opt) {
            try required_arr.append(.{ .string = p.name });
        }
    }

    var schema: std.json.ObjectMap = .{};
    try schema.put(allocator, "type", .{ .string = "object" });
    try schema.put(allocator, "properties", .{ .object = properties });
    if (required_arr.items.len > 0) {
        try schema.put(allocator, "required", .{ .array = required_arr });
    }

    var tool: std.json.ObjectMap = .{};
    try tool.put(allocator, "name", .{ .string = name });
    try tool.put(allocator, "description", .{ .string = description });
    try tool.put(allocator, "inputSchema", .{ .object = schema });
    return std.json.Value{ .object = tool };
}

// ── Tests ──

test "handleMessage returns error for invalid JSON" {
    const allocator = std.testing.allocator;
    const resp = try handleMessage(std.testing.io, allocator, "not json");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Parse error") != null);
}

test "handleMessage dispatches initialize" {
    const allocator = std.testing.allocator;
    const resp = try handleMessage(std.testing.io, allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "zmodu") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "protocolVersion") != null);
}

test "handleMessage dispatches tools/list" {
    const allocator = std.testing.allocator;
    const resp = try handleMessage(std.testing.io, allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "zmodu_scaffold") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "zmodu_version") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "zmodu_verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "zmodu_diff") != null);
}

test "handleMessage returns error for unknown method" {
    const allocator = std.testing.allocator;
    const resp = try handleMessage(std.testing.io, allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"unknown\"}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Method not found") != null);
}

test "handleMessage dispatches tools/call for version" {
    const allocator = std.testing.allocator;
    const resp = try handleMessage(std.testing.io, allocator, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"zmodu_version\",\"arguments\":{}}}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "0.14.9") != null);
}

test "handleMessage handles notification (no id)" {
    const allocator = std.testing.allocator;
    const resp = try handleMessage(std.testing.io, allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}");
    defer allocator.free(resp);
    try std.testing.expectEqual(@as(usize, 0), resp.len);
}

test "handleMessage returns error for tools/call with unknown tool" {
    const allocator = std.testing.allocator;
    const resp = try handleMessage(std.testing.io, allocator, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"unknown_tool\",\"arguments\":{}}}");
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "Unknown tool") != null);
}
