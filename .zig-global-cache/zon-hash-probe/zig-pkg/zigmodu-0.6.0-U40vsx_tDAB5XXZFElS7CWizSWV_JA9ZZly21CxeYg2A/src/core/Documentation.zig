const std = @import("std");
const ApplicationModules = @import("./Module.zig").ApplicationModules;
const ModuleInfo = @import("./Module.zig").ModuleInfo;

pub fn generateDocs(modules: *ApplicationModules, path: []const u8, allocator: std.mem.Allocator, io: std.Io) !void {
    if (path.len == 0) return error.InvalidPath;

    if (std.fs.path.dirname(path)) |dir| {
        try std.Io.Dir.cwd().createDirPath(io, dir);
    }

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "@startuml\n");
    try buf.appendSlice(allocator, "!theme plain\n\n");

    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        try buf.print(allocator, "component [{s}] {{\n", .{m.name});
        try buf.print(allocator, "  {s}\n", .{m.desc});
        try buf.appendSlice(allocator, "}\n\n");

        for (m.deps) |d| {
            try buf.print(allocator, "{s} --> {s}\n", .{ m.name, d });
        }
    }

    try buf.appendSlice(allocator, "\n@enduml\n");
    try file.writeStreamingAll(io, buf.items);
}

pub fn generateJsonDocs(modules: *ApplicationModules, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\n");
    try buf.appendSlice(allocator, "  \"modules\": [\n");

    var iter = modules.modules.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        if (count > 0) {
            try buf.appendSlice(allocator, ",\n");
        }
        try buf.print(allocator, "    {{\n", .{});
        try buf.print(allocator, "      \"name\": \"{s}\",\n", .{m.name});
        try buf.print(allocator, "      \"description\": \"{s}\",\n", .{m.desc});
        try buf.appendSlice(allocator, "      \"dependencies\": [");
        for (m.deps, 0..) |d, i| {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            try buf.print(allocator, "\"{s}\"", .{d});
        }
        try buf.appendSlice(allocator, "]\n    }");
        count += 1;
    }

    try buf.appendSlice(allocator, "\n  ]\n");
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
}

pub fn generateMarkdownDocs(modules: *ApplicationModules, allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "# Module Documentation\n\n");
    try buf.appendSlice(allocator, "## Module Dependency Graph\n\n");
    try buf.appendSlice(allocator, "```mermaid\n");
    try buf.appendSlice(allocator, "graph TD\n");

    var iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        try buf.print(allocator, "    {s}[{s}] --> ", .{ m.name, m.name });
        for (m.deps) |d| {
            try buf.print(allocator, "{s}, ", .{d});
        }
        try buf.appendSlice(allocator, "\n");
    }

    try buf.appendSlice(allocator, "```\n\n");
    try buf.appendSlice(allocator, "## Module Details\n\n");

    iter = modules.modules.iterator();
    while (iter.next()) |entry| {
        const m = entry.value_ptr.*;
        try buf.print(allocator, "### {s}\n\n", .{m.name});
        try buf.print(allocator, "{s}\n\n", .{m.desc});
        try buf.appendSlice(allocator, "**Dependencies:** ");
        if (m.deps.len == 0) {
            try buf.appendSlice(allocator, "None\n\n");
        } else {
            for (m.deps) |d| {
                try buf.print(allocator, "{s} ", .{d});
            }
            try buf.appendSlice(allocator, "\n\n");
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
