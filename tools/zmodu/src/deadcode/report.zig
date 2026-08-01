//! Report formatting: human-readable and JSON output.

const std = @import("std");
const analyze = @import("analyze.zig");

pub const Options = struct {
    json: bool = false,
    verbose: bool = false,
};

const Buf = struct {
    list: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn writeAll(self: Buf, s: []const u8) !void {
        try self.list.appendSlice(self.alloc, s);
    }

    fn writeByte(self: Buf, b: u8) !void {
        try self.list.append(self.alloc, b);
    }

    fn print(self: Buf, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.list.appendSlice(self.alloc, s);
    }
};

pub fn kindLabel(kind: analyze.Kind, parent_kind: ?analyze.Kind) []const u8 {
    if (kind == .field) {
        return switch (parent_kind orelse analyze.Kind.struct_decl) {
            .enum_decl => "enum variant",
            .union_decl => "union field",
            .error_set_decl => "error",
            else => "field",
        };
    }
    return kind.label();
}

fn parentName(decls: []const analyze.Decl, parent: ?usize) []const u8 {
    if (parent) |p| return decls[p].name;
    return "";
}

pub fn formatHuman(
    alloc: std.mem.Allocator,
    result: *const analyze.Result,
    files: []const analyze.File,
    options: Options,
) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    const w = Buf{ .list = &list, .alloc = alloc };

    for (result.findings) |f| {
        const file = files[f.file];
        const pk = if (f.parent) |p| result.decls[p].kind else null;
        const label = kindLabel(f.kind, pk);
        const parent = parentName(result.decls, f.parent);
        if (parent.len > 0) {
            try w.print("{s}:{d}:{d}: unused {s} '{s}' of '{s}'\n", .{
                file.display_path, f.line, f.column, label, f.name, parent,
            });
        } else {
            try w.print("{s}:{d}:{d}: unused {s} '{s}'\n", .{
                file.display_path, f.line, f.column, label, f.name,
            });
        }
    }

    for (result.unused_files) |fi| {
        try w.print("{s}: module is never imported\n", .{files[fi].display_path});
    }

    if (result.findings.len > 0 or result.unused_files.len > 0) {
        try w.writeAll("\n");
    }

    const s = result.summary;
    const pct: f64 = if (s.decls == 0) 0 else @as(f64, @floatFromInt(s.dead)) * 100.0 / @as(f64, @floatFromInt(s.decls));
    try w.print(
        "{d} dead declaration{s} out of {d} ({d:.1}%), {d} file{s} scanned, {d} parse error{s}\n",
        .{
            s.dead,
            if (s.dead == 1) "" else "s",
            s.decls,
            pct,
            s.files_scanned,
            if (s.files_scanned == 1) "" else "s",
            s.parse_errors,
            if (s.parse_errors == 1) "" else "s",
        },
    );
    if (options.verbose) {
        try w.print(
            "verbose: {d} live, {d} reference edges, {d} imports, {d} unused modules\n",
            .{ s.live, s.refs, s.imports, s.unused_files },
        );
    }
    return list.toOwnedSlice(alloc);
}

pub fn formatJson(
    alloc: std.mem.Allocator,
    result: *const analyze.Result,
    files: []const analyze.File,
) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    const w = Buf{ .list = &list, .alloc = alloc };

    try w.writeAll("{\n  \"dead_declarations\": [");
    for (result.findings, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        const pk = if (f.parent) |p| result.decls[p].kind else null;
        try w.writeAll("\n    {\"file\": ");
        try writeJsonString(w, files[f.file].display_path);
        try w.print(", \"line\": {d}, \"column\": {d}, \"kind\": ", .{ f.line, f.column });
        try writeJsonString(w, kindLabel(f.kind, pk));
        try w.writeAll(", \"name\": ");
        try writeJsonString(w, f.name);
        try w.writeAll(", \"parent\": ");
        if (f.parent) |p| {
            try writeJsonString(w, result.decls[p].name);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}");
    }
    try w.writeAll("\n  ],\n  \"unused_modules\": [");
    for (result.unused_files, 0..) |fi, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("\n    ");
        try writeJsonString(w, files[fi].display_path);
    }
    try w.writeAll("\n  ],\n  \"summary\": {");
    const s = result.summary;
    try w.print(
        "\n    \"files\": {d}, \"declarations\": {d}, \"live\": {d}, \"dead\": {d}, \"parse_errors\": {d}, \"refs\": {d}, \"imports\": {d}\n",
        .{ s.files_scanned, s.decls, s.live, s.dead, s.parse_errors, s.refs, s.imports },
    );
    try w.writeAll("  }\n}\n");
    return list.toOwnedSlice(alloc);
}

fn writeJsonString(w: Buf, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeAll("\"");
}
