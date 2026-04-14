const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

pub fn generateDocs(modules: *ApplicationModules, path: []const u8, allocator: std.mem.Allocator) !void {
    if (path.len == 0) return error.InvalidPath;

    if (std.fs.path.dirname(path)) |dir| {
        try std.fs.cwd().makePath(dir);
    }

    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);

    try writer.writeAll("@startuml\n");
    try writer.writeAll("!theme plain\n\n");

    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        try writer.print("component [{s}] {{\n", .{m.name});
        try writer.print("  {s}\n", .{m.desc});
        try writer.writeAll("}\n\n");

        for (m.deps) |d| {
            try writer.print("{s} --> {s}\n", .{ m.name, d });
        }
    }

    try writer.writeAll("\n@enduml\n");
    try file.writeAll(buf.items);
}

pub fn generateJsonDocs(modules: *ApplicationModules, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\n");
    try writer.writeAll("  \"modules\": [\n");

    var iter = modules.modules.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        if (count > 0) {
            try writer.writeAll(",\n");
        }
        try writer.print("    {{\n", .{});
        try writer.print("      \"name\": \"{s}\",\n", .{m.name});
        try writer.print("      \"description\": \"{s}\",\n", .{m.desc});
        try writer.writeAll("      \"dependencies\": [");
        for (m.deps, 0..) |d, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{d});
        }
        try writer.writeAll("]\n    }");
        count += 1;
    }

    try writer.writeAll("\n  ]\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice(allocator);
}

pub fn generateMarkdownDocs(modules: *ApplicationModules, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("# Module Documentation\n\n");
    try writer.writeAll("## Module Dependency Graph\n\n");
    try writer.writeAll("```mermaid\n");
    try writer.writeAll("graph TD\n");

    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        try writer.print("    {s}[{s}] --> ", .{ m.name, m.name });
        for (m.deps) |d| {
            try writer.print("{s}, ", .{d});
        }
        try writer.writeAll("\n");
    }

    try writer.writeAll("```\n\n");
    try writer.writeAll("## Module Details\n\n");

    iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        try writer.print("### {s}\n\n", .{m.name});
        try writer.print("{s}\n\n", .{m.desc});
        try writer.writeAll("**Dependencies:** ");
        if (m.deps.len == 0) {
            try writer.writeAll("None\n\n");
        } else {
            for (m.deps) |d| {
                try writer.print("{s} ", .{d});
            }
            try writer.writeAll("\n\n");
        }
    }

    return buf.toOwnedSlice(allocator);
}

test "generateJsonDocs" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    try modules.register(ModuleInfo.init("order", "Order module", &.{"inventory"}, undefined));
    try modules.register(ModuleInfo.init("inventory", "Inventory module", &.{}, undefined));

    const json = try generateJsonDocs(&modules, allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"name\": \"order\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"name\": \"inventory\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, json, 1, "\"dependencies\": [\"inventory\"]"));
}

test "generateMarkdownDocs" {
    const allocator = std.testing.allocator;
    var modules = ApplicationModules.init(allocator);
    defer modules.deinit();

    try modules.register(ModuleInfo.init("user", "User module", &.{}, undefined));

    const md = try generateMarkdownDocs(&modules, allocator);
    defer allocator.free(md);

    try std.testing.expect(std.mem.containsAtLeast(u8, md, 1, "# Module Documentation"));
    try std.testing.expect(std.mem.containsAtLeast(u8, md, 1, "### user"));
}
