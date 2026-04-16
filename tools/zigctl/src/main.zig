// ZigCtl - Code generation tool for ZigModu
const std = @import("std");

const Command = enum {
    new,
    module,
    event,
    api,
    orm,
    help,
    version,
};

const Config = struct {
    project_name: []const u8 = "",
    module_name: []const u8 = "",
    template_dir: []const u8 = "templates",
    output_dir: []const u8 = ".",
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = parseCommand(args[1]) orelse {
        std.log.err("Unknown command: {s}", .{args[1]});
        printUsage();
        std.process.exit(1);
    };

    switch (command) {
        .new => try cmdNew(allocator, args[2..]),
        .module => try cmdModule(allocator, args[2..]),
        .event => try cmdEvent(allocator, args[2..]),
        .api => try cmdApi(allocator, args[2..]),
        .orm => try cmdOrm(allocator, args[2..]),
        .help => printUsage(),
        .version => printVersion(),
    }
}

fn toPascalCase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, input.len);
    var i: usize = 0;
    var j: usize = 0;
    var capitalize = true;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '-' or c == '_') {
            capitalize = true;
        } else if (capitalize) {
            result[j] = std.ascii.toUpper(c);
            j += 1;
            capitalize = false;
        } else {
            result[j] = c;
            j += 1;
        }
    }
    return try allocator.realloc(result, j);
}

fn toCamelCase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, input.len);
    var i: usize = 0;
    var j: usize = 0;
    var capitalize = false;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (c == '-' or c == '_') {
            capitalize = true;
        } else if (capitalize) {
            result[j] = std.ascii.toUpper(c);
            j += 1;
            capitalize = false;
        } else {
            result[j] = c;
            j += 1;
        }
    }
    return try allocator.realloc(result, j);
}

fn toSnakeCase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try allocator.alloc(u8, input.len);
    var j: usize = 0;
    for (input) |c| {
        if (c == '-') {
            result[j] = '_';
            j += 1;
        } else {
            result[j] = c;
            j += 1;
        }
    }
    return try allocator.realloc(result, j);
}

fn parseCommand(cmd: []const u8) ?Command {
    if (std.mem.eql(u8, cmd, "new")) return .new;
    if (std.mem.eql(u8, cmd, "module")) return .module;
    if (std.mem.eql(u8, cmd, "event")) return .event;
    if (std.mem.eql(u8, cmd, "api")) return .api;
    if (std.mem.eql(u8, cmd, "orm")) return .orm;
    if (std.mem.eql(u8, cmd, "help")) return .help;
    if (std.mem.eql(u8, cmd, "version")) return .version;
    if (std.mem.eql(u8, cmd, "--help")) return .help;
    if (std.mem.eql(u8, cmd, "--version")) return .version;
    if (std.mem.eql(u8, cmd, "-h")) return .help;
    if (std.mem.eql(u8, cmd, "-v")) return .version;
    return null;
}

fn printUsage() void {
    const usage =
        \\ZigCtl - Code generation tool for ZigModu
        \\
        \\Usage:
        \\  zigctl <command> [options]
        \\
        \\Commands:
        \\  new <name>      Create new ZigModu project
        \\  module <name>   Generate module boilerplate
        \\  event <name>    Generate event handler
        \\  api <name>      Generate API endpoint
        \\  orm             Generate ORM models and repositories from SQL
        \\  help            Show help
        \\  version         Show version
        \\
        \\Examples:
        \\  zigctl new myapp
        \\  zigctl module user
        \\  zigctl event order-created
        \\  zigctl api users
        \\  zigctl orm --sql schema.sql --out src/modules
        \\
        \\  help            Show help
        \\  version         Show version
        \\
        \\Examples:
        \\  zigctl new myapp
        \\  zigctl module user
        \\  zigctl event order-created
        \\  zigctl api users
        \\
    ;
    std.log.info("{s}", .{usage});
}

fn printVersion() void {
    std.log.info("zigctl version 0.1.0", .{});
}

fn cmdNew(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zigctl new <project-name>", .{});
        return;
    }

    const project_name = args[0];
    std.log.info("Creating new project: {s}", .{project_name});

    // Create project directory
    try std.fs.cwd().makePath(project_name);

    // Create subdirectories
    const dirs = [_][]const u8{
        "src",
        "src/modules",
        "src/events",
        "src/api",
        "tests",
    };

    for (dirs) |dir| {
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_name, dir });
        defer allocator.free(full_path);
        try std.fs.cwd().makePath(full_path);
    }

    // Generate build.zig
    const build_zig = try generateBuildZig(allocator, project_name);
    defer allocator.free(build_zig);

    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_name});
    defer allocator.free(build_path);

    try writeFile(build_path, build_zig);

    // Generate build.zig.zon
    const build_zon = try generateBuildZon(allocator, project_name);
    defer allocator.free(build_zon);

    const zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{project_name});
    defer allocator.free(zon_path);

    try writeFile(zon_path, build_zon);

    // Generate main.zig
    const main_zig = try generateMainZig(allocator, project_name);
    defer allocator.free(main_zig);

    const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{project_name});
    defer allocator.free(main_path);

    try writeFile(main_path, main_zig);

    std.log.info("Project {s} created successfully!", .{project_name});
    std.log.info("  cd {s} && zig build run", .{project_name});
}

fn cmdModule(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zigctl module <name>", .{});
        return;
    }

    const module_name = args[0];
    std.log.info("Generating module: {s}", .{module_name});

    // Generate module file
    const module_code = try generateModule(allocator, module_name);
    defer allocator.free(module_code);

    const module_path = try std.fmt.allocPrint(allocator, "src/modules/{s}.zig", .{module_name});
    defer allocator.free(module_path);

    try writeFile(module_path, module_code);

    std.log.info("Module {s} created at {s}", .{ module_name, module_path });
}

fn cmdEvent(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zigctl event <name>", .{});
        return;
    }

    const event_name = args[0];
    std.log.info("Generating event: {s}", .{event_name});

    // Generate event file
    const event_code = try generateEvent(allocator, event_name);
    defer allocator.free(event_code);

    const event_path = try std.fmt.allocPrint(allocator, "src/events/{s}.zig", .{event_name});
    defer allocator.free(event_path);

    try writeFile(event_path, event_code);

    std.log.info("Event {s} created at {s}", .{ event_name, event_path });
}

fn cmdApi(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zigctl api <name>", .{});
        return;
    }

    const api_name = args[0];
    std.log.info("Generating API: {s}", .{api_name});

    // Generate API file
    const api_code = try generateApi(allocator, api_name);
    defer allocator.free(api_code);

    const api_path = try std.fmt.allocPrint(allocator, "src/api/{s}.zig", .{api_name});
    defer allocator.free(api_path);

    try writeFile(api_path, api_code);

    std.log.info("API {s} created at {s}", .{ api_name, api_path });
}

// Template generators
fn generateBuildZig(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    _ = project_name;
    return try allocator.dupe(u8,
        \\const std = @import("std");
        \\
        \\pub fn build(b: *std.Build) void {
        \\    const target = b.standardTargetOptions(.{});
        \\    const optimize = b.standardOptimizeOption(.{});
        \\
        \\    const exe = b.addExecutable(.{
        \\        .name = "app",
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/main.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\
        \\    b.installArtifact(exe);
        \\
        \\    const run_cmd = b.addRunArtifact(exe);
        \\    run_cmd.step.dependOn(b.getInstallStep());
        \\    if (b.args) |args| {
        \\        run_cmd.addArgs(args);
        \\    }
        \\
        \\    const run_step = b.step("run", "Run the app");
        \\    run_step.dependOn(&run_cmd.step);
        \\
        \\    const unit_tests = b.addTest(.{
        \\        .root_module = b.createModule(.{
        \\            .root_source_file = b.path("src/tests.zig"),
        \\            .target = target,
        \\            .optimize = optimize,
        \\        }),
        \\    });
        \\
        \\    const run_unit_tests = b.addRunArtifact(unit_tests);
        \\    const test_step = b.step("test", "Run unit tests");
        \\    test_step.dependOn(&run_unit_tests.step);
        \\}
        \\
    );
}

fn generateBuildZon(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    _ = project_name;
    return try allocator.dupe(u8,
        \\.{
        \\    .name = .myapp,
        \\    .version = "0.1.0",
        \\    .fingerprint = 0x0000000000000000,
        \\    .minimum_zig_version = "0.15.2",
        \\    .dependencies = .{
        \\        .zigmodu = .{
        \\            .path = "../zigmodu",
        \\        },
        \\    },
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
        \\
    );
}

fn generateMainZig(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    _ = project_name;
    return try allocator.dupe(u8,
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        \\    defer _ = gpa.deinit();
        \\    const allocator = gpa.allocator();
        \\
        \\    std.log.info("Application started!", .{});
        \\
        \\    // TODO: Add your modules here
        \\}
        \\
    );
}

fn generateModule(allocator: std.mem.Allocator, module_name: []const u8) ![]const u8 {
    const template =
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\
        \\const Self = @This();
        \\
        \\pub const info = zigmodu.api.Module{{
        \\    .name = "{s}",
        \\    .description = "{s} module",
        \\    .dependencies = &.{{}},
        \\}};
        \\
        \\allocator: std.mem.Allocator,
        \\
        \\pub fn init(allocator: std.mem.Allocator) !Self {{
        \\    std.log.info("{{s}} module initialized", .{{"{s}"}});
        \\    return Self{{ .allocator = allocator }};
        \\}}
        \\
        \\pub fn deinit(self: *Self) void {{
        \\    _ = self;
        \\    std.log.info("{{s}} module cleaned up", .{{"{s}"}});
        \\}}
        \\
    ;
    return try std.fmt.allocPrint(allocator, template, .{ module_name, module_name, module_name, module_name });
}

fn generateEvent(allocator: std.mem.Allocator, event_name: []const u8) ![]const u8 {
    const struct_name = try toPascalCase(allocator, event_name);
    defer allocator.free(struct_name);

    const part1 = "const std = @import(\"std\");\n\npub const ";
    const part2 = "Event = struct {\n    id: u64,\n    timestamp: i64,\n    data: []const u8,\n};\n\npub fn handle";
    const part3 = "(event: ";
    const part4 = "Event) void {\n    std.log.info(\"Handling ";
    const part5 = " event: id=\" ++ \"{}\", .{ event.id });\n    // TODO: Add event handling logic\n}\n";

    return try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}{s}{s}{s}{s}", .{ part1, struct_name, part2, struct_name, part3, struct_name, part4, event_name, part5 });
}

fn generateApi(allocator: std.mem.Allocator, api_name: []const u8) ![]const u8 {
    const struct_name = try toPascalCase(allocator, api_name);
    defer allocator.free(struct_name);
    const method_name = try toPascalCase(allocator, api_name);
    defer allocator.free(method_name);

    const pieces = [_][]const u8{
        "const std = @import(\"std\");\n" ++
            "const zigmodu = @import(\"zigmodu\");\n\n" ++
            "pub const ",
        struct_name,
        "Api = struct {\n" ++
            "    const Self = @This();\n\n" ++
            "    router: *zigmodu.api.Router,\n\n" ++
            "    pub fn init(router: *zigmodu.api.Router) !Self {\n" ++
            "        var self = Self{ .router = router };\n" ++
            "        try self.registerRoutes();\n" ++
            "        return self;\n" ++
            "    }\n\n" ++
            "    fn registerRoutes(self: *Self) !void {\n" ++
            "        try self.router.get(\"/",
        api_name,
        "\", &Self.get",
        method_name,
        ");\n" ++
            "        try self.router.post(\"/",
        api_name,
        "\", &Self.create",
        method_name,
        ");\n" ++
            "        try self.router.put(\"/",
        api_name,
        "/{id}\", &Self.update",
        method_name,
        ");\n" ++
            "        try self.router.delete(\"/",
        api_name,
        "/{id}\", &Self.delete",
        method_name,
        ");\n" ++
            "    }\n\n" ++
            "    fn get",
        method_name,
        "(req: zigmodu.api.Router.Request, res: *zigmodu.api.Router.Response) !void {\n" ++
            "        _ = req;\n" ++
            "        try res.json(.{ .message = \"GET ",
        api_name,
        "\" });\n" ++
            "    }\n\n" ++
            "    fn create",
        method_name,
        "(req: zigmodu.api.Router.Request, res: *zigmodu.api.Router.Response) !void {\n" ++
            "        _ = req;\n" ++
            "        try res.json(.{ .message = \"CREATE ",
        api_name,
        "\", .status = \"success\" });\n" ++
            "    }\n\n" ++
            "    fn update",
        method_name,
        "(req: zigmodu.api.Router.Request, res: *zigmodu.api.Router.Response) !void {\n" ++
            "        _ = req;\n" ++
            "        try res.json(.{ .message = \"UPDATE ",
        api_name,
        "\", .status = \"success\" });\n" ++
            "    }\n\n" ++
            "    fn delete",
        method_name,
        "(req: zigmodu.api.Router.Request, res: *zigmodu.api.Router.Response) !void {\n" ++
            "        _ = req;\n" ++
            "        try res.json(.{ .message = \"DELETE ",
        api_name,
        "\", .status = \"success\" });\n" ++
            "    }\n};\n",
    };

    var total_len: usize = 0;
    for (pieces) |p| total_len += p.len;

    var result = try allocator.alloc(u8, total_len);
    var offset: usize = 0;
    for (pieces) |p| {
        @memcpy(result[offset .. offset + p.len], p);
        offset += p.len;
    }
    return result;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// ==================== ORM Code Generation ====================

const ColumnType = enum {
    int,
    string,
    bool,
    float,
    datetime,
    unknown,
};

const ColumnDef = struct {
    name: []const u8,
    col_type: ColumnType,
    nullable: bool,
    is_primary_key: bool,
};

const TableDef = struct {
    name: []const u8,
    columns: []ColumnDef,
};

fn skipWhitespaceAndComments(text: []const u8, i: *usize) void {
    while (i.* < text.len) {
        if (std.ascii.isWhitespace(text[i.*])) {
            i.* += 1;
            continue;
        }
        if (text[i.*] == '-' and i.* + 1 < text.len and text[i.* + 1] == '-') {
            i.* += 2;
            while (i.* < text.len and text[i.*] != '\n') i.* += 1;
            continue;
        }
        if (text[i.*] == '/' and i.* + 1 < text.len and text[i.* + 1] == '*') {
            i.* += 2;
            while (i.* + 1 < text.len and !(text[i.*] == '*' and text[i.* + 1] == '/')) i.* += 1;
            i.* += 2;
            continue;
        }
        break;
    }
}

fn parseKeyword(text: []const u8, i: *usize, keyword: []const u8) bool {
    skipWhitespaceAndComments(text, i);
    const end = i.* + keyword.len;
    if (end > text.len) return false;
    const slice = text[i.* .. end];
    if (!std.mem.eql(u8, &[_]u8{std.ascii.toUpper(slice[0])}, &[_]u8{std.ascii.toUpper(keyword[0])}) and slice.len != keyword.len) {
        // quick check
    }
    for (slice, keyword) |c, k| {
        if (std.ascii.toUpper(c) != std.ascii.toUpper(k)) return false;
    }
    // ensure boundary
    if (end < text.len and (std.ascii.isAlphabetic(text[end]) or text[end] == '_')) return false;
    i.* = end;
    return true;
}

fn parseIdentifier(allocator: std.mem.Allocator, text: []const u8, i: *usize) ![]const u8 {
    skipWhitespaceAndComments(text, i);
    if (i.* < text.len and text[i.*] == '`') {
        i.* += 1;
        const name_start = i.*;
        while (i.* < text.len and text[i.*] != '`') i.* += 1;
        const name = text[name_start..i.*];
        if (i.* < text.len and text[i.*] == '`') i.* += 1;
        return try allocator.dupe(u8, name);
    }
    if (i.* < text.len and text[i.*] == '"') {
        i.* += 1;
        const name_start = i.*;
        while (i.* < text.len and text[i.*] != '"') i.* += 1;
        const name = text[name_start..i.*];
        if (i.* < text.len and text[i.*] == '"') i.* += 1;
        return try allocator.dupe(u8, name);
    }
    const name_start = i.*;
    while (i.* < text.len and (std.ascii.isAlphanumeric(text[i.*]) or text[i.*] == '_')) i.* += 1;
    return try allocator.dupe(u8, text[name_start..i.*]);
}
fn parseColumnTypeName(text: []const u8, i: *usize) ColumnType {
    skipWhitespaceAndComments(text, i);
    const start = i.*;
    while (i.* < text.len and !std.ascii.isWhitespace(text[i.*]) and text[i.*] != '(' and text[i.*] != ')' and text[i.*] != ',') i.* += 1;
    const type_name = text[start..i.*];
    var upper_buf: [64]u8 = undefined;
    if (type_name.len > upper_buf.len) return .unknown;
    const upper = std.ascii.upperString(&upper_buf, type_name);

    if (std.mem.eql(u8, upper, "INT") or
        std.mem.eql(u8, upper, "INTEGER") or
        std.mem.eql(u8, upper, "BIGINT") or
        std.mem.eql(u8, upper, "SMALLINT") or
        std.mem.eql(u8, upper, "TINYINT") or
        std.mem.eql(u8, upper, "SERIAL") or
        std.mem.eql(u8, upper, "INT64")) return .int;
    if (std.mem.eql(u8, upper, "VARCHAR") or
        std.mem.eql(u8, upper, "TEXT") or
        std.mem.eql(u8, upper, "CHAR") or
        std.mem.eql(u8, upper, "NVARCHAR") or
        std.mem.eql(u8, upper, "JSON") or
        std.mem.eql(u8, upper, "JSONB") or
        std.mem.eql(u8, upper, "UUID")) return .string;
    if (std.mem.eql(u8, upper, "BOOLEAN") or
        std.mem.eql(u8, upper, "BOOL")) return .bool;
    if (std.mem.eql(u8, upper, "FLOAT") or
        std.mem.eql(u8, upper, "DOUBLE") or
        std.mem.eql(u8, upper, "REAL") or
        std.mem.eql(u8, upper, "NUMERIC") or
        std.mem.eql(u8, upper, "DECIMAL")) return .float;
    if (std.mem.eql(u8, upper, "DATETIME") or
        std.mem.eql(u8, upper, "TIMESTAMP") or
        std.mem.eql(u8, upper, "DATE") or
        std.mem.eql(u8, upper, "TIME")) return .datetime;
    return .unknown;
}

fn parseColumnDef(allocator: std.mem.Allocator, text: []const u8) !ColumnDef {
    var i: usize = 0;
    skipWhitespaceAndComments(text, &i);

    // skip table-level constraints
    if (i + 3 <= text.len) {
        const first_word = text[i..@min(i + 11, text.len)];
        var ubuf: [11]u8 = undefined;
        _ = std.ascii.upperString(&ubuf, first_word);
        const ustr = ubuf[0..first_word.len];
        if (std.mem.startsWith(u8, ustr, "CONSTRAINT") or
            std.mem.startsWith(u8, ustr, "PRIMARY") or
            std.mem.startsWith(u8, ustr, "FOREIGN") or
            std.mem.startsWith(u8, ustr, "UNIQUE") or
            std.mem.startsWith(u8, ustr, "INDEX") or
            std.mem.startsWith(u8, ustr, "KEY")) {
            return ColumnDef{ .name = try allocator.dupe(u8, ""), .col_type = .unknown, .nullable = true, .is_primary_key = false };
        }
    }

    const name = try parseIdentifier(allocator, text, &i);
    skipWhitespaceAndComments(text, &i);
    const col_type = parseColumnTypeName(text, &i);

    var nullable = true;
    var is_primary_key = false;

    // scan remainder for NOT NULL / PRIMARY KEY
    const rest = text[i..];
    const rest_upper_buf = try allocator.alloc(u8, rest.len);
    defer allocator.free(rest_upper_buf);
    _ = std.ascii.upperString(rest_upper_buf, rest);
    const rest_upper = rest_upper_buf;

    if (std.mem.indexOf(u8, rest_upper, "NOT NULL") != null) nullable = false;
    if (std.mem.indexOf(u8, rest_upper, "PRIMARY KEY") != null) is_primary_key = true;

    return ColumnDef{ .name = name, .col_type = col_type, .nullable = nullable, .is_primary_key = is_primary_key };
}

fn parseColumns(allocator: std.mem.Allocator, text: []const u8, i: *usize) ![]ColumnDef {
    var cols: std.ArrayList(ColumnDef) = .{};
    defer cols.deinit(allocator);
    var depth: usize = 0;
    var start = i.*;
    while (i.* < text.len) {
        if (text[i.*] == '(') depth += 1;
        if (text[i.*] == ')') {
            if (depth == 0) {
                if (i.* > start) {
                    const col = try parseColumnDef(allocator, text[start..i.*]);
                    if (col.name.len > 0) try cols.append(allocator, col) else allocator.free(col.name);
                }
                i.* += 1;
                skipWhitespaceAndComments(text, i);
                if (i.* < text.len and text[i.*] == ';') i.* += 1;
                break;
            } else {
                depth -= 1;
            }
        }
        if (text[i.*] == ',' and depth == 0) {
            const col = try parseColumnDef(allocator, text[start..i.*]);
                    if (col.name.len > 0) try cols.append(allocator, col) else allocator.free(col.name);
            i.* += 1;
            start = i.*;
            continue;
        }
        i.* += 1;
    }
    return cols.toOwnedSlice(allocator);
}

fn parseSqlSchema(allocator: std.mem.Allocator, sql: []const u8) ![]TableDef {
    var tables: std.ArrayList(TableDef) = .{};
    defer tables.deinit(allocator);
    var i: usize = 0;
    while (i < sql.len) {
        skipWhitespaceAndComments(sql, &i);
        if (i >= sql.len) break;
        if (parseKeyword(sql, &i, "CREATE")) {
            if (parseKeyword(sql, &i, "TABLE")) {
                const table_name = try parseIdentifier(allocator, sql, &i);
                skipWhitespaceAndComments(sql, &i);
                if (i < sql.len and sql[i] == '(') {
                    i += 1;
                    const columns = try parseColumns(allocator, sql, &i);
                    try tables.append(allocator, .{ .name = table_name, .columns = columns });
                }
            }
        } else {
            i += 1;
        }
    }
    return tables.toOwnedSlice(allocator);
}

fn inferModuleName(allocator: std.mem.Allocator, table_name: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, table_name, "_")) |idx| {
        return try allocator.dupe(u8, table_name[0..idx]);
    }
    return try allocator.dupe(u8, table_name);
}

fn generateModulePersistence(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef) ![]const u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("//! Auto-generated ORM persistence for module: ");
    try writer.writeAll(module_name);
    try writer.writeAll("\n//! Generated by zigctl orm\n//! Do not modify manually\n\n");
    try writer.writeAll("const std = @import(\"std\");\n");
    try writer.writeAll("const zigmodu = @import(\"zigmodu\");\n\n");

    // Models
    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);

        try writer.print("pub const {s} = struct {{\n", .{model_name});
        for (table.columns) |col| {
            if (col.col_type == .unknown and col.name.len == 0) continue;
            const zig_type = switch (col.col_type) {
                .int => "i64",
                .string => "[]const u8",
                .bool => "bool",
                .float => "f64",
                .datetime => "[]const u8",
                .unknown => "[]const u8",
            };
            try writer.print("    {s}: {s},\n", .{ col.name, zig_type });
        }
        try writer.writeAll("};\n\n");
    }

    // Persistence struct
    const pascal_module = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_module);

    try writer.print("pub const {s}Persistence = struct {{\n", .{pascal_module});
    try writer.writeAll("    backend: zigmodu.SqlxBackend,\n");
    try writer.writeAll("    orm: zigmodu.orm.Orm(zigmodu.SqlxBackend),\n\n");
    try writer.print("    pub fn init(backend: zigmodu.SqlxBackend) {s}Persistence {{\n", .{pascal_module});
    try writer.writeAll("        return .{ .backend = backend, .orm = .{ .backend = backend } };\n");
    try writer.writeAll("    }\n\n");

    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);
        const repo_type = try std.fmt.allocPrint(allocator, "zigmodu.orm.Orm(zigmodu.SqlxBackend).Repository({s})", .{model_name});
        defer allocator.free(repo_type);
        const method_name = try toCamelCase(allocator, table.name);
        defer allocator.free(method_name);

        try writer.print("    pub fn {s}Repo(self: *{s}Persistence) {s} {{\n", .{ method_name, pascal_module, repo_type });
        try writer.writeAll("        return .{ .orm = &self.orm };\n");
        try writer.writeAll("    }\n\n");
    }

    try writer.writeAll("};\n");
    return buf.toOwnedSlice(allocator);
}

fn cmdOrm(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var sql_path: ?[]const u8 = null;
    var out_dir: []const u8 = "src/modules";
    var forced_module: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--sql") and i + 1 < args.len) {
            sql_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out") and i + 1 < args.len) {
            out_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--module") and i + 1 < args.len) {
            forced_module = args[i + 1];
            i += 1;
        }
    }

    if (sql_path == null) {
        std.log.err("Usage: zigctl orm --sql <file> [--out <dir>] [--module <name>]", .{});
        return;
    }

    const sql_content = try std.fs.cwd().readFileAlloc(allocator, sql_path.?, 1024 * 1024);
    defer allocator.free(sql_content);

    const tables = try parseSqlSchema(allocator, sql_content);
    defer {
        for (tables) |t| {
            allocator.free(t.name);
            for (t.columns) |c| allocator.free(c.name);
            allocator.free(t.columns);
        }
        allocator.free(tables);
    }

    if (forced_module) |mod_name| {
        const code = try generateModulePersistence(allocator, mod_name, tables);
        defer allocator.free(code);
        const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}_persistence.zig", .{ out_dir, mod_name });
        defer allocator.free(out_path);
        try std.fs.cwd().makePath(out_dir);
        try writeFile(out_path, code);
        std.log.info("Generated ORM persistence: {s}", .{out_path});
    } else {
        var module_map = std.StringHashMap(std.ArrayList(TableDef)).init(allocator);
        defer {
            var iter = module_map.iterator();
            while (iter.next()) |entry| {
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            module_map.deinit();
        }

        for (tables) |table| {
            const mod_name = try inferModuleName(allocator, table.name);
            const gop = try module_map.getOrPut(mod_name);
            if (!gop.found_existing) {
                gop.key_ptr.* = mod_name;
                gop.value_ptr.* = std.ArrayList(TableDef){};
            } else {
                allocator.free(mod_name);
            }
            try gop.value_ptr.append(allocator, table);
        }

        try std.fs.cwd().makePath(out_dir);
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            const code = try generateModulePersistence(allocator, entry.key_ptr.*, entry.value_ptr.items);
            defer allocator.free(code);
            const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}_persistence.zig", .{ out_dir, entry.key_ptr.* });
            defer allocator.free(out_path);
            try writeFile(out_path, code);
            std.log.info("Generated ORM persistence: {s} ({d} tables)", .{ out_path, entry.value_ptr.items.len });
        }
    }
}

