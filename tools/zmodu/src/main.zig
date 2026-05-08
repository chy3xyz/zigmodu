// ZModu - Code generation tool for ZigModu
const std = @import("std");
const orm_tpl = @import("orm_tpl.zig");

const Command = enum {
    new,
    module,
    event,
    api,
    orm,
    generate,
    scaffold,
    bigdemo,
    help,
    version,
};

const Config = struct {
    project_name: []const u8 = "",
    module_name: []const u8 = "",
    template_dir: []const u8 = "templates",
    output_dir: []const u8 = ".",
};

const CodeStyle = enum { default, java };

const GenOptions = struct {
    dry_run: bool = false,
    force: bool = false,
    data_only: bool = false,
    split: bool = false,
    enable_events: bool = false,
    style: CodeStyle = .default,
};

const OrmCli = struct {
    sql_path: ?[]const u8,
    out_dir: []const u8,
    forced_module: ?[]const u8,
    backend: []const u8,
    opts: GenOptions,
};

const ParseOrmCliResult = union(enum) {
    ok: OrmCli,
    err_unknown_flag: []const u8,
    err_missing_value: []const u8,
};

fn isOrmLongOption(token: []const u8) bool {
    return std.mem.eql(u8, token, "--sql") or
        std.mem.eql(u8, token, "--out") or
        std.mem.eql(u8, token, "--module") or
        std.mem.eql(u8, token, "--backend") or
        std.mem.eql(u8, token, "--style") or
        std.mem.eql(u8, token, "--dry-run") or
        std.mem.eql(u8, token, "--force") or
        std.mem.eql(u8, token, "--data-only") or
        std.mem.eql(u8, token, "--split") or
        std.mem.eql(u8, token, "--enable-events");
}

fn parseOrmCli(args: []const []const u8) ParseOrmCliResult {
    var sql_path: ?[]const u8 = null;
    var out_dir: []const u8 = "src/modules";
    var forced_module: ?[]const u8 = null;
    var backend: []const u8 = "sqlx";
    var opts: GenOptions = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--sql")) {
            if (i + 1 >= args.len) return .{ .err_missing_value = "--sql" };
            const val = args[i + 1];
            if (isOrmLongOption(val)) return .{ .err_missing_value = "--sql" };
            sql_path = val;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out")) {
            if (i + 1 >= args.len) return .{ .err_missing_value = "--out" };
            const val = args[i + 1];
            if (isOrmLongOption(val)) return .{ .err_missing_value = "--out" };
            out_dir = val;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--module")) {
            if (i + 1 >= args.len) return .{ .err_missing_value = "--module" };
            const val = args[i + 1];
            if (isOrmLongOption(val)) return .{ .err_missing_value = "--module" };
            forced_module = val;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--backend")) {
            if (i + 1 >= args.len) return .{ .err_missing_value = "--backend" };
            const val = args[i + 1];
            if (isOrmLongOption(val)) return .{ .err_missing_value = "--backend" };
            backend = val;
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, args[i], "--data-only")) {
            opts.data_only = true;
        } else if (std.mem.eql(u8, args[i], "--style")) {
            if (i + 1 >= args.len) return .{ .err_missing_value = "--style" };
            const val = args[i + 1];
            if (isOrmLongOption(val)) return .{ .err_missing_value = "--style" };
            if (std.mem.eql(u8, val, "java")) {
                opts.style = .java;
            } else if (!std.mem.eql(u8, val, "default")) {
                return .{ .err_unknown_flag = val };
            }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--split")) {
            opts.split = true;
        } else if (std.mem.eql(u8, args[i], "--enable-events")) {
            opts.enable_events = true;
        } else {
            return .{ .err_unknown_flag = args[i] };
        }
    }

    return .{ .ok = .{
        .sql_path = sql_path,
        .out_dir = out_dir,
        .forced_module = forced_module,
        .backend = backend,
        .opts = opts,
    } };
}

fn trimTrailingNewlines(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == '\n' or s[end - 1] == '\r')) end -= 1;
    return s[0..end];
}

/// Strip UTF-8 BOM (common from editors) and leading/trailing ASCII whitespace for SQL parsing.
fn stripUtf8BomAndTrimSql(s: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    const after_bom = if (std.mem.startsWith(u8, s, bom)) s[bom.len..] else s;
    return std.mem.trim(u8, after_bom, " \t\r\n");
}

fn pathContainsDotDot(path: []const u8) bool {
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "..")) return true;
    }
    return false;
}

/// `--module` must be one path segment (no `/`, `\`, or `..`).
fn isSafeModuleDirName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    if (pathContainsDotDot(name)) return false;
    return true;
}

/// Released tarball for `zmodu new` projects (hash from `zig build` / missing-hash hint, Zig 0.16).
const zigmodu_zon_url = "https://github.com/knot3bot/zigmodu/archive/refs/tags/v0.7.0.tar.gz";
const zigmodu_zon_hash = "zigmodu-0.6.0-U40vsx_tDAB5XXZFElS7CWizSWV_JA9ZZly21CxeYg2A";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    {
        var iter = init.minimal.args.iterate();
        while (iter.next()) |arg| {
            try args.append(allocator, arg);
        }
    }

    if (args.items.len < 2) {
        printUsage();
        return;
    }

    const command = parseCommand(args.items[1]) orelse {
        std.log.err("Unknown command: {s}", .{args.items[1]});
        printUsage();
        std.process.exit(1);
    };

    runCommand(init.io, allocator, command, args.items[2..]) catch |err| switch (err) {
        error.CliUsage => std.process.exit(2),
        error.RefuseOverwrite => std.process.exit(3),
        else => |e| return e,
    };
}

fn runCommand(io: std.Io, allocator: std.mem.Allocator, command: Command, cmd_args: []const []const u8) !void {
    switch (command) {
        .new => try cmdNew(io, allocator, cmd_args),
        .module => try cmdModule(io, allocator, cmd_args),
        .event => try cmdEvent(io, allocator, cmd_args),
        .api => try cmdApi(io, allocator, cmd_args),
        .orm => try cmdOrm(io, allocator, cmd_args),
        .generate => try cmdGenerate(io, allocator, cmd_args),
        .scaffold => try cmdScaffold(io, allocator, cmd_args),
        .bigdemo => try cmdBigdemo(io, allocator, cmd_args),
        .help => {
            if (cmd_args.len != 0) {
                std.log.err("`zmodu help` does not accept arguments (got {d}).", .{cmd_args.len});
                return error.CliUsage;
            }
            printUsage();
        },
        .version => {
            if (cmd_args.len != 0) {
                std.log.err("`zmodu version` does not accept arguments (got {d}).", .{cmd_args.len});
                return error.CliUsage;
            }
            printVersion();
        },
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

/// `build.zig.zon` `.name` must be a valid Zig identifier (enum literal suffix).
fn packageNameForZon(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    for (raw) |c| {
        if (c == '-' or c == ' ') {
            try list.append(allocator, '_');
        } else if (std.ascii.isAlphanumeric(c) or c == '_') {
            try list.append(allocator, std.ascii.toLower(c));
        }
    }
    if (list.items.len == 0) return try allocator.dupe(u8, "app");
    if (std.ascii.isDigit(list.items[0])) try list.insert(allocator, 0, '_');
    return try list.toOwnedSlice(allocator);
}

fn parseCommand(cmd: []const u8) ?Command {
    if (std.mem.eql(u8, cmd, "new")) return .new;
    if (std.mem.eql(u8, cmd, "module")) return .module;
    if (std.mem.eql(u8, cmd, "event")) return .event;
    if (std.mem.eql(u8, cmd, "api")) return .api;
    if (std.mem.eql(u8, cmd, "orm")) return .orm;
    if (std.mem.eql(u8, cmd, "generate")) return .generate;
    if (std.mem.eql(u8, cmd, "scaffold")) return .scaffold;
    if (std.mem.eql(u8, cmd, "bigdemo")) return .bigdemo;
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
        \\ZModu - Code generation tool for ZigModu
        \\
        \\Usage:
        \\  zmodu <command> [options]
        \\
        \\Commands:
        \\  new <name>      Create new ZigModu project
        \\  module <name>   Generate module boilerplate
        \\  event <name>    Generate event handler
        \\  api <name>      Generate API endpoint
        \\  orm             Generate ORM modules from SQL (auto-groups by prefix)
        \\  scaffold        One-shot: SQL -> full project with wiring
        \\  bigdemo         Regenerate shopdemo (152 tables → 42 modules)
        \\  generate <t>   Alias: generate module|event|api|orm [...]
        \\  help            Show help
        \\  version         Show version
        \\
        \\Examples:
        \\  zmodu new myapp
        \\  zmodu module user
        \\  zmodu module user --dry-run
        \\  zmodu event order-created
        \\  zmodu api users
        \\  zmodu orm --sql schema.sql --out src/modules
        \\  zmodu orm --sql schema.sql --out src/modules --module <name> --force
        \\  zmodu scaffold --sql schema.sql --name myapp
        \\  zmodu scaffold --sql schema.sql --name myapp --out ./myproject
        \\
        \\Flags (where supported):
        \\  --dry-run   Preview writes / mkdir; no files created
        \\  --data-only  Only generate model.zig + persistence.zig (not service/api/module/root)
        \\  --force     Overwrite existing generated files (default: refuse)
        \\
        \\Exit codes: 0 success, 1 unknown command or I/O, 2 invalid arguments, 3 refuse overwrite (use --force)
        \\
    ;
    std.log.info("{s}", .{usage});
}

fn printVersion() void {
    std.log.info("zmodu version 0.5.5", .{});
}

fn cmdNew(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zmodu new <project-name>", .{});
        return error.CliUsage;
    }
    if (args.len > 1) {
        std.log.err("Unexpected argument: {s}", .{args[1]});
        return error.CliUsage;
    }

    const project_name = args[0];
    if (std.mem.startsWith(u8, project_name, "-")) {
        std.log.err("Project name must not look like an option: {s}", .{project_name});
        return error.CliUsage;
    }

    std.log.info("Creating new project: {s}", .{project_name});

    // Create project directory
    try std.Io.Dir.cwd().createDirPath(io, project_name);

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
        try std.Io.Dir.cwd().createDirPath(io, full_path);
    }

    // Generate build.zig
    const build_zig = try generateBuildZig(allocator, project_name);
    defer allocator.free(build_zig);

    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_name});
    defer allocator.free(build_path);

    try writeFile(io, build_path, build_zig);

    // Generate build.zig.zon
    const build_zon = try generateBuildZonImpl(allocator, project_name, null);
    defer allocator.free(build_zon);

    const zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{project_name});
    defer allocator.free(zon_path);

    try writeFile(io, zon_path, build_zon);

    try finalizeBuildZigZonFingerprint(io, allocator, project_name, zon_path);

    // Generate main.zig
    const main_zig = try generateMainZig(allocator, project_name);
    defer allocator.free(main_zig);

    const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{project_name});
    defer allocator.free(main_path);

    try writeFile(io, main_path, main_zig);

    const tests_zig =
        \\const std = @import("std");
        \\
        \\test "placeholder" {
        \\    try std.testing.expect(true);
        \\}
        \\
    ;
    const tests_path = try std.fmt.allocPrint(allocator, "{s}/src/tests.zig", .{project_name});
    defer allocator.free(tests_path);
    try writeFile(io, tests_path, tests_zig);

    // Generate .ai/prompts/ directory with AI prompt templates
    const ai_prompts_dir = try std.fmt.allocPrint(allocator, "{s}/.ai/prompts", .{project_name});
    defer allocator.free(ai_prompts_dir);
    try std.Io.Dir.cwd().createDirPath(io, ai_prompts_dir);

    const add_module_prompt =
        \\# Add a new module to this project
        \\
        \\## Task
        \\Create a new ZigModu module following the standard structure:
        \\- module.zig — declaration layer (info, init, deinit)
        \\- model.zig — data structures
        \\- persistence.zig — ORM repositories
        \\- service.zig — business logic
        \\- api.zig — HTTP routes
        \\- root.zig — barrel exports
        \\- test.zig — tests
        \\- _ai.zig — AI context index
        \\
        \\## Steps
        \\1. Read src/modules/<existing>/_ai.zig for context pattern
        \\2. Create src/modules/<name>/ directory with all files
        \\3. Add module to src/main.zig scanModules call
        \\4. Run `zig build test` to verify
        \\
    ;
    const add_module_path = try std.fmt.allocPrint(allocator, "{s}/add_module.md", .{ai_prompts_dir});
    defer allocator.free(add_module_path);
    try writeFile(io, add_module_path, add_module_prompt);

    const project_context =
        \\# Project AI Context
        \\
        \\## Framework: ZigModu v0.7.0 (Zig 0.16.0)
        \\## Module structure: src/modules/<name>/module.zig
        \\## Entry point: src/main.zig
        \\
        \\## Key conventions:
        \\- Dependencies must be declared in module.zig info.dependencies
        \\- All modules have init() and deinit() lifecycle hooks
        \\- Extension points: service_ext.zig, api_ext.zig (survive regeneration)
        \\- AI context: each module has _ai.zig with metadata
        \\
    ;
    const context_path = try std.fmt.allocPrint(allocator, "{s}/context.md", .{ai_prompts_dir});
    defer allocator.free(context_path);
    try writeFile(io, context_path, project_context);

    std.log.info("Project {s} created successfully!", .{project_name});
    std.log.info("  cd {s} && zig build run", .{project_name});
}

fn cmdModule(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zmodu module <name> [--dry-run] [--force]", .{});
        return error.CliUsage;
    }

    const module_name = args[0];
    if (std.mem.startsWith(u8, module_name, "-")) {
        std.log.err("Expected module name, got option-like token: {s}", .{module_name});
        std.log.err("Usage: zmodu module <name> [--dry-run] [--force]", .{});
        return error.CliUsage;
    }
    if (!isSafeModuleDirName(module_name)) {
        std.log.err("Module name must be a single directory segment (no '/', '\\', or '..'): {s}", .{module_name});
        return error.CliUsage;
    }

    var opts: GenOptions = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            opts.force = true;
        } else {
            std.log.err("Unknown option for module: {s}", .{args[i]});
            std.log.err("Usage: zmodu module <name> [--dry-run] [--force]", .{});
            return error.CliUsage;
        }
    }
    std.log.info("Generating module: {s}", .{module_name});

    // Generate module file
    const module_code = try generateModule(allocator, module_name);
    defer allocator.free(module_code);

    const module_dir = try std.fmt.allocPrint(allocator, "src/modules/{s}", .{module_name});
    defer allocator.free(module_dir);
    try ensureDirGen(io, module_dir, opts);

    const module_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{module_dir});
    defer allocator.free(module_path);

    try writeFileGen(io, module_path, module_code, opts);

    const pascal = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal);
    const root_code = try orm_tpl.expandOrm(allocator, orm_tpl.module_minimal_root_zig, module_name, pascal);
    defer allocator.free(root_code);
    const root_path = try std.fmt.allocPrint(allocator, "{s}/root.zig", .{module_dir});
    defer allocator.free(root_path);
    try writeFileGen(io, root_path, root_code, opts);

    std.log.info("Module {s} created: {s}, {s}", .{ module_name, module_path, root_path });
}

fn cmdEvent(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zmodu event <name>", .{});
        return error.CliUsage;
    }
    if (args.len > 1) {
        std.log.err("Unexpected argument: {s}", .{args[1]});
        return error.CliUsage;
    }

    const event_name = args[0];
    if (std.mem.startsWith(u8, event_name, "-")) {
        std.log.err("Expected event name, got option-like token: {s}", .{event_name});
        return error.CliUsage;
    }

    std.log.info("Generating event: {s}", .{event_name});

    // Generate event file
    const event_code = try generateEvent(allocator, event_name);
    defer allocator.free(event_code);

    const event_path = try std.fmt.allocPrint(allocator, "src/events/{s}.zig", .{event_name});
    defer allocator.free(event_path);

    try writeFile(io, event_path, event_code);

    std.log.info("Event {s} created at {s}", .{ event_name, event_path });
}

fn cmdApi(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zmodu api <name> [--module <module-name>]", .{});
        return error.CliUsage;
    }

    const api_name = args[0];
    if (std.mem.startsWith(u8, api_name, "-")) {
        std.log.err("Expected API name, got option-like token: {s}", .{api_name});
        return error.CliUsage;
    }

    var target_module: ?[]const u8 = null;

    if (args.len == 2 and std.mem.eql(u8, args[1], "--module")) {
        std.log.err("Missing value after --module", .{});
        return error.CliUsage;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--module")) {
        target_module = args[2];
        if (args.len > 3) {
            std.log.err("Unexpected argument after --module <name>: {s}", .{args[3]});
            return error.CliUsage;
        }
    } else if (args.len >= 2) {
        std.log.err("Unknown argument: {s}", .{args[1]});
        std.log.err("Usage: zmodu api <name> [--module <module-name>]", .{});
        return error.CliUsage;
    }

    std.log.info("Generating API: {s}", .{api_name});

    // Generate API file
    const api_code = try generateApi(allocator, api_name);
    defer allocator.free(api_code);

    const api_path = if (target_module) |mod_name|
        try std.fmt.allocPrint(allocator, "src/modules/{s}/api_{s}.zig", .{ mod_name, api_name })
    else
        try std.fmt.allocPrint(allocator, "src/api/{s}.zig", .{api_name});
    defer allocator.free(api_path);

    // Ensure directory exists
    if (target_module) |mod_name| {
        const dir_path = try std.fmt.allocPrint(allocator, "src/modules/{s}", .{mod_name});
        defer allocator.free(dir_path);
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
    }

    try writeFile(io, api_path, api_code);

    if (target_module) |mod_name| {
        std.log.info("API {s} created at {s} (in module {s})", .{ api_name, api_path, mod_name });
    } else {
        std.log.info("API {s} created at {s}", .{ api_name, api_path });
    }
}

// Template generators
fn generateBuildZig(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "const std = @import(\"std\");\n\n");
    try buf.appendSlice(allocator, "pub fn build(b: *std.Build) void {\n");
    try buf.appendSlice(allocator, "    const target = b.standardTargetOptions(.{});\n");
    try buf.appendSlice(allocator, "    const optimize = b.standardOptimizeOption(.{});\n");
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    const zigmodu_dep = b.dependency(\"zigmodu\", .{\n");
    try buf.appendSlice(allocator, "        .target = target,\n");
    try buf.appendSlice(allocator, "        .optimize = optimize,\n");
    try buf.appendSlice(allocator, "    });\n");
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    const exe_mod = b.createModule(.{ \n");
    try buf.appendSlice(allocator, "        .root_source_file = b.path(\"src/main.zig\"),\n");
    try buf.appendSlice(allocator, "        .target = target,\n");
    try buf.appendSlice(allocator, "        .optimize = optimize,\n");
    try buf.appendSlice(allocator, "    });\n");
    try buf.appendSlice(allocator, "    exe_mod.addImport(\"zigmodu\", zigmodu_dep.module(\"zigmodu\"));\n");
    try buf.appendSlice(allocator, "\n");
    try buf.print(allocator, "    const exe = b.addExecutable(.{{ .name = \"{s}\", .root_module = exe_mod }});\n", .{project_name});
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    b.installArtifact(exe);\n");
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    const run_cmd = b.addRunArtifact(exe);\n");
    try buf.appendSlice(allocator, "    run_cmd.step.dependOn(b.getInstallStep());\n");
    try buf.appendSlice(allocator, "    if (b.args) |args| {\n");
    try buf.appendSlice(allocator, "        run_cmd.addArgs(args);\n");
    try buf.appendSlice(allocator, "    }\n");
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    const run_step = b.step(\"run\", \"Run the app\");\n");
    try buf.appendSlice(allocator, "    run_step.dependOn(&run_cmd.step);\n");
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    const unit_tests_mod = b.createModule(.{ \n");
    try buf.appendSlice(allocator, "        .root_source_file = b.path(\"src/tests.zig\"),\n");
    try buf.appendSlice(allocator, "        .target = target,\n");
    try buf.appendSlice(allocator, "        .optimize = optimize,\n");
    try buf.appendSlice(allocator, "    });\n");
    try buf.appendSlice(allocator, "    unit_tests_mod.addImport(\"zigmodu\", zigmodu_dep.module(\"zigmodu\"));\n");
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    const unit_tests = b.addTest(.{ \n");
    try buf.appendSlice(allocator, "        .root_module = unit_tests_mod,\n");
    try buf.appendSlice(allocator, "    });\n");
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "    const run_unit_tests = b.addRunArtifact(unit_tests);\n");
    try buf.appendSlice(allocator, "    const test_step = b.step(\"test\", \"Run unit tests\");\n");
    try buf.appendSlice(allocator, "    test_step.dependOn(&run_unit_tests.step);\n");
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
}

fn generateBuildZonImpl(allocator: std.mem.Allocator, project_name: []const u8, fingerprint: ?u64) ![]const u8 {
    const pkg = try packageNameForZon(allocator, project_name);
    defer allocator.free(pkg);
    if (fingerprint) |fp| {
        return try std.fmt.allocPrint(allocator,
            \\.{{
            \\    .name = .{s},
            \\    .version = "0.1.0",
            \\    .fingerprint = 0x{x},
            \\    .minimum_zig_version = "0.16.0",
            \\    .dependencies = .{{
            \\        .zigmodu = .{{
            \\            .url = "{s}",
            \\            .hash = "{s}",
            \\        }},
            \\    }},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "src",
            \\    }},
            \\}}
            \\
        , .{ pkg, fp, zigmodu_zon_url, zigmodu_zon_hash });
    }
    return try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .minimum_zig_version = "0.16.0",
        \\    .dependencies = .{{
        \\        .zigmodu = .{{
        \\            .url = "{s}",
        \\            .hash = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    }},
        \\}}
        \\
    , .{ pkg, zigmodu_zon_url, zigmodu_zon_hash });
}

fn parseZigSuggestedFingerprint(diag: []const u8) ?u64 {
    const needle = "suggested value: ";
    var i: usize = 0;
    while (i < diag.len) {
        const idx = std.mem.indexOfPos(u8, diag, i, needle) orelse return null;
        var rest = diag[idx + needle.len ..];
        if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[0..nl];
        const trimmed = std.mem.trim(u8, rest, " \t\r");
        if (std.fmt.parseInt(u64, trimmed, 0)) |v| return v else |_| {}
        i = idx + 1;
    }
    return null;
}

fn finalizeBuildZigZonFingerprint(io: std.Io, allocator: std.mem.Allocator, project_name: []const u8, zon_path: []const u8) !void {
    const run = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .path = std.fs.path.dirname(zon_path) orelse return error.BadPath },
    });
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);

    const diag = try std.mem.concat(allocator, u8, &.{ run.stderr, run.stdout });
    defer allocator.free(diag);

    const fp = parseZigSuggestedFingerprint(diag) orelse {
        std.log.warn("Could not detect build.zig.zon fingerprint from zig output; add .fingerprint after running zig build in the new project.", .{});
        return;
    };

    const zon = try generateBuildZonImpl(allocator, project_name, fp);
    defer allocator.free(zon);
    try writeFile(io, zon_path, zon);
}

fn generateMainZig(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    _ = project_name;
    return try allocator.dupe(u8,
        \\const std = @import("std");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.gpa;
        \\    _ = allocator;
        \\
        \\
        \\    std.log.info("Application started!", .{});
        \\
        \\    // TODO: Add your modules here
        \\}
        \\
    );
}

fn generateModule(allocator: std.mem.Allocator, module_name: []const u8) ![]const u8 {
    // Same shape as ORM-generated modules (AGENTS.md: init/deinit, api.Module fields).
    return generateModuleZig(allocator, module_name, "&.{}");
}

fn generateEvent(allocator: std.mem.Allocator, event_name: []const u8) ![]const u8 {
    const pascal_name = try toPascalCase(allocator, event_name);
    defer allocator.free(pascal_name);
    return orm_tpl.expandTemplate(allocator, orm_tpl.event_tpl, &.{ "{{EVENT_NAME}}", "{{PASCAL_NAME}}" }, &.{ event_name, pascal_name });
}

fn generateApi(allocator: std.mem.Allocator, api_name: []const u8) ![]const u8 {
    const pascal_name = try toPascalCase(allocator, api_name);
    defer allocator.free(pascal_name);
    return orm_tpl.expandTemplate(allocator, orm_tpl.api_standalone_tpl, &.{ "{{API_NAME}}", "{{PASCAL_NAME}}" }, &.{ api_name, pascal_name });
}

fn writeFile(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

fn ensureDirGen(io: std.Io, path: []const u8, opts: GenOptions) !void {
    if (opts.dry_run) {
        std.log.info("[dry-run] mkdir -p {s}", .{path});
        return;
    }
    try std.Io.Dir.cwd().createDirPath(io, path);
}

fn writeFileGen(io: std.Io, path: []const u8, content: []const u8, opts: GenOptions) !void {
    if (opts.dry_run) {
        std.log.info("[dry-run] write {s} ({d} bytes)", .{ path, content.len });
        return;
    }

    const file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = !opts.force }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            std.log.err("Refusing to overwrite existing file: {s}", .{path});
            std.log.err("Re-run with --force to overwrite, or --dry-run to preview.", .{});
            return error.RefuseOverwrite;
        },
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, content);
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
    is_unique: bool,
    has_default: bool,
    comment: ?[]const u8,
};

const ForeignKey = struct {
    column_name: []const u8,
    ref_table: []const u8,
    ref_column: []const u8,
};

const TableDef = struct {
    name: []const u8,
    columns: []ColumnDef,
    foreign_keys: []ForeignKey,
};

fn zigScalarColumnType(col_type: ColumnType) []const u8 {
    return switch (col_type) {
        .int => "i64",
        .string => "[]const u8",
        .bool => "bool",
        .float => "f64",
        .datetime => "[]const u8",
        .unknown => "[]const u8",
    };
}

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
            return ColumnDef{ .name = try allocator.dupe(u8, ""), .col_type = .unknown, .nullable = true, .is_primary_key = false, .is_unique = false, .has_default = false, .comment = null };
        }
    }

    const name = try parseIdentifier(allocator, text, &i);
    skipWhitespaceAndComments(text, &i);
    const col_type = parseColumnTypeName(text, &i);

    var nullable = true;
    var is_primary_key = false;
    var is_unique = false;
    var has_default = false;

    // scan remainder for NOT NULL / PRIMARY KEY / UNIQUE / DEFAULT
    const rest = text[i..];
    const rest_upper_buf = try allocator.alloc(u8, rest.len);
    defer allocator.free(rest_upper_buf);
    _ = std.ascii.upperString(rest_upper_buf, rest);
    const rest_upper = rest_upper_buf;

    if (std.mem.indexOf(u8, rest_upper, "NOT NULL") != null) nullable = false;
    if (std.mem.indexOf(u8, rest_upper, "PRIMARY KEY") != null) is_primary_key = true;
    if (is_primary_key) nullable = false;
    if (std.mem.indexOf(u8, rest_upper, "UNIQUE") != null) is_unique = true;
    if (std.mem.indexOf(u8, rest_upper, "DEFAULT") != null) has_default = true;
    // Parse COMMENT '...'
    var comment: ?[]const u8 = null;
    const comment_upper = "COMMENT";
    if (std.mem.indexOf(u8, rest_upper, comment_upper)) |cidx| {
        var ci = i + cidx + comment_upper.len;
        skipWhitespaceAndComments(text, &ci);
        if (ci < text.len and text[ci] == '\'') {
            ci += 1;
            const cstart = ci;
            while (ci < text.len and text[ci] != '\'') ci += 1;
            comment = try allocator.dupe(u8, text[cstart..ci]);
        }
    }

    return ColumnDef{ .name = name, .col_type = col_type, .nullable = nullable, .is_primary_key = is_primary_key, .is_unique = is_unique, .has_default = has_default, .comment = comment };
}

fn parseColumns(allocator: std.mem.Allocator, text: []const u8, i: *usize) ![]ColumnDef {
    var cols: std.ArrayList(ColumnDef) = std.ArrayList(ColumnDef).empty;
    defer cols.deinit(allocator);
    var depth: usize = 0;
    var in_single_quote: bool = false;
    var in_double_quote: bool = false;
    var in_backtick: bool = false;
    var start = i.*;
    while (i.* < text.len) {
        const c = text[i.*];
        if (c == '\'' and !in_double_quote and !in_backtick) in_single_quote = !in_single_quote;
        if (c == '"' and !in_single_quote and !in_backtick) in_double_quote = !in_double_quote;
        if (c == '`' and !in_single_quote and !in_double_quote) in_backtick = !in_backtick;
        if (!in_single_quote and !in_double_quote and !in_backtick) {
            if (c == '(') depth += 1;
            if (c == ')') {
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
            if (c == ',' and depth == 0) {
                const col = try parseColumnDef(allocator, text[start..i.*]);
                        if (col.name.len > 0) try cols.append(allocator, col) else allocator.free(col.name);
                i.* += 1;
                start = i.*;
                continue;
            }
        }
        i.* += 1;
    }
    return cols.toOwnedSlice(allocator);
}

fn parseSqlSchema(allocator: std.mem.Allocator, sql: []const u8) ![]TableDef {
    var tables: std.ArrayList(TableDef) = std.ArrayList(TableDef).empty;
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
                    const body_start = i;
                    const columns = try parseColumns(allocator, sql, &i);
                    const body_end = i;
                    const fks = try extractForeignKeys(allocator, sql, body_start, body_end);
                    try tables.append(allocator, .{ .name = table_name, .columns = columns, .foreign_keys = fks });
                }
            }
        } else {
            i += 1;
        }
    }
    return tables.toOwnedSlice(allocator);
}

/// Find the longest common prefix (up to and including '_') shared by all table names.
/// Returns 0 if no common prefix exists (tables are heterogeneous).
fn commonTablePrefix(tables: []const TableDef) usize {
    if (tables.len < 2) return 0;
    const first = tables[0].name;
    var prefix_len: usize = 0;
    for (first, 0..) |c, i| {
        for (tables[1..]) |t| {
            if (i >= t.name.len or t.name[i] != c) {
                // Backtrack to last '_' boundary for a clean prefix
                while (prefix_len > 0 and first[prefix_len - 1] != '_') prefix_len -= 1;
                return prefix_len;
            }
        }
        prefix_len = i + 1;
    }
    // All tables start with the same full prefix — backtrack to last '_'
    while (prefix_len > 0 and first[prefix_len - 1] != '_') prefix_len -= 1;
    return prefix_len;
}

/// Infer the module name for a table, optionally stripping a common prefix.
fn inferModuleName(allocator: std.mem.Allocator, table_name: []const u8, strip_prefix_len: usize) ![]const u8 {
    const effective = if (strip_prefix_len > 0 and strip_prefix_len < table_name.len)
        table_name[strip_prefix_len..]
    else
        table_name;
    if (std.mem.indexOf(u8, effective, "_")) |idx| {
        return try allocator.dupe(u8, effective[0..idx]);
    }
    return try allocator.dupe(u8, effective);
}

/// Extract FOREIGN KEY references from raw SQL body text.
fn extractForeignKeys(allocator: std.mem.Allocator, sql: []const u8, body_start: usize, body_end: usize) ![]ForeignKey {
    var fks: std.ArrayList(ForeignKey) = std.ArrayList(ForeignKey).empty;
    const body = sql[body_start..@min(body_end, sql.len)];

    var i: usize = 0;
    while (i + 7 < body.len) {
        const rest = body[i..];
        const rest_upper_buf = try allocator.alloc(u8, rest.len);
        defer allocator.free(rest_upper_buf);
        _ = std.ascii.upperString(rest_upper_buf, rest);
        const ru = rest_upper_buf;

        const fk_pos = std.mem.indexOf(u8, ru, "FOREIGN KEY") orelse break;
        i += fk_pos + "FOREIGN KEY".len;

        // Find the column name in parentheses after FOREIGN KEY
        var j: usize = fk_pos + "FOREIGN KEY".len;
        while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t' or rest[j] == '\n' or rest[j] == '\r')) j += 1;
        if (j < rest.len and rest[j] == '(') {
            j += 1;
            const col_start = j;
            while (j < rest.len and rest[j] != ')') j += 1;
            const col_name = try allocator.dupe(u8, std.mem.trim(u8, rest[col_start..j], " \t\n\r`"));
            j += 1;

            // Find REFERENCES
            while (j + 10 < rest.len) : (j += 1) {
                const sub_rest = rest[j..];
                const sub_buf = try allocator.alloc(u8, sub_rest.len);
                defer allocator.free(sub_buf);
                _ = std.ascii.upperString(sub_buf, sub_rest);
                if (std.mem.startsWith(u8, sub_buf, "REFERENCES")) {
                    j += "REFERENCES".len;
                    while (j < rest.len and (rest[j] == ' ' or rest[j] == '\t')) j += 1;
                    const ref_start = j;
                    while (j < rest.len and (std.ascii.isAlphanumeric(rest[j]) or rest[j] == '_' or rest[j] == '`')) j += 1;
                    const ref_table = std.mem.trim(u8, rest[ref_start..j], "`");
                    if (ref_table.len == 0) break;

                    // Skip ref column in parens if present
                    var ref_column: []const u8 = "id";
                    if (j < rest.len and rest[j] == '(') {
                        j += 1;
                        const rc_start = j;
                        while (j < rest.len and rest[j] != ')') j += 1;
                        ref_column = try allocator.dupe(u8, std.mem.trim(u8, rest[rc_start..j], " \t\n\r`"));
                        j += 1;
                    } else {
                        ref_column = try allocator.dupe(u8, ref_column);
                    }

                    try fks.append(allocator, .{
                        .column_name = col_name,
                        .ref_table = try allocator.dupe(u8, ref_table),
                        .ref_column = ref_column,
                    });
                    break;
                }
            }
        }
        i += 1; // advance past this FK to find more
    }
    return fks.toOwnedSlice(allocator);
}

/// Infer module-level dependencies from FOREIGN KEY relationships.
/// Maps referenced table names → module names using the same prefix-stripping logic.
fn inferModuleDependencies(allocator: std.mem.Allocator, tables: []const TableDef, module_name: []const u8, strip_prefix_len: usize) ![]const u8 {
    var deps: std.ArrayList([]const u8) = std.ArrayList([]const u8).empty;
    var seen: std.StringHashMap(void) = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (tables) |table| {
        for (table.foreign_keys) |fk| {
            const ref_module = try inferModuleName(allocator, fk.ref_table, strip_prefix_len);
            // Only add dependency if the referenced module is different from current module
            if (!std.mem.eql(u8, ref_module, module_name)) {
                if (!seen.contains(ref_module)) {
                    try seen.put(ref_module, {});
                    try deps.append(allocator, ref_module);
                } else {
                    allocator.free(ref_module);
                }
            } else {
                allocator.free(ref_module);
            }
        }
    }

    if (deps.items.len == 0) return try allocator.dupe(u8, "&.{}");

    // Build the dependencies literal: &.{ "dep1", "dep2" }
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator, "&.{ ");
    for (deps.items, 0..) |dep, idx| {
        if (idx > 0) try buf.appendSlice(allocator, ", ");
        try buf.print(allocator, "\"{s}\"", .{dep});
        allocator.free(dep);
    }
    try buf.appendSlice(allocator, " }");
    deps.deinit(allocator);
    return buf.toOwnedSlice(allocator);
}

/// Build a module→tables map, auto-detecting the common table prefix for smart grouping.
fn groupTablesByModule(allocator: std.mem.Allocator, tables: []const TableDef) !std.StringHashMap(std.ArrayList(TableDef)) {
    const prefix_len = commonTablePrefix(tables);

    var module_map = std.StringHashMap(std.ArrayList(TableDef)).init(allocator);
    errdefer {
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        module_map.deinit();
    }

    for (tables) |table| {
        const mod_name = try inferModuleName(allocator, table.name, prefix_len);
        const gop = try module_map.getOrPut(mod_name);
        if (!gop.found_existing) {
            gop.key_ptr.* = mod_name;
            gop.value_ptr.* = .empty;
        } else {
            allocator.free(mod_name);
        }
        try gop.value_ptr.append(allocator, table);
    }

    return module_map;
}

fn generateModuleModel(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_model_header, module_name, pascal_mod);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);

        try buf.print(allocator, "pub const {s} = struct {{\n", .{model_name});
        try buf.print(allocator, "    pub const sql_table_name: []const u8 = \"{s}\";\n", .{table.name});
        for (table.columns) |col| {
            if (col.col_type == .unknown and col.name.len == 0) continue;
            const base = zigScalarColumnType(col.col_type);
            if (col.nullable) {
                try buf.print(allocator, "    {s}: ?{s},\n", .{ col.name, base });
            } else {
                try buf.print(allocator, "    {s}: {s},\n", .{ col.name, base });
            }
        }
        try buf.appendSlice(allocator, "\n    pub fn jsonStringify(self: @This(), jws: anytype) !void {\n");
        try buf.appendSlice(allocator, "        try jws.beginObject();\n");
        for (table.columns) |col| {
            if (col.col_type == .unknown and col.name.len == 0) continue;
            try buf.print(allocator, "        try jws.objectField(\"{s}\");\n", .{col.name});
            if (col.nullable) {
                try buf.print(allocator, "        if (self.{s}) |v| try jws.write(v) else try jws.write(null);\n", .{col.name});
            } else {
                try buf.print(allocator, "        try jws.write(self.{s});\n", .{col.name});
            }
        }
        try buf.appendSlice(allocator, "        try jws.endObject();\n");
        try buf.appendSlice(allocator, "    }\n");
        try buf.appendSlice(allocator, "};\n\n");
    }

    return buf.toOwnedSlice(allocator);
}

fn generateModulePersistence(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_module = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_module);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_persistence_header, module_name, pascal_module);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);
        const method_name = try toCamelCase(allocator, table.name);
        defer allocator.free(method_name);

        try buf.print(allocator, "    pub fn {s}Repo(self: *{s}Persistence) zigmodu.orm.Orm(zigmodu.SqlxBackend).Repository(model.{s}) {{\n", .{ method_name, pascal_module, model_name });
        try buf.appendSlice(allocator, "        return .{ .orm = &self.orm };\n");
        try buf.appendSlice(allocator, "    }\n\n");
    }

    try buf.appendSlice(allocator, orm_tpl.sqlx_persistence_footer);
    return buf.toOwnedSlice(allocator);
}

fn generateModuleService(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_module = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_module);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_service_header, module_name, pascal_module);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);
        const method_name = try toCamelCase(allocator, table.name);
        defer allocator.free(method_name);
        const list_method = try std.fmt.allocPrint(allocator, "list{s}s", .{model_name});
        defer allocator.free(list_method);

        try buf.print(allocator, "    pub fn {s}(self: *{s}Service, page: usize, size: usize) !zigmodu.orm.PageResult(model.{s}) {{\n", .{ list_method, pascal_module, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        return try repo.findPage(page, size);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    pub fn get{s}(self: *{s}Service, id: i64) !?model.{s} {{\n", .{ model_name, pascal_module, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        return try repo.findById(id);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    pub fn create{s}(self: *{s}Service, entity: model.{s}) !model.{s} {{\n", .{ model_name, pascal_module, model_name, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        return try repo.insert(entity);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    pub fn update{s}(self: *{s}Service, entity: model.{s}) !void {{\n", .{ model_name, pascal_module, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        return try repo.update(entity);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    pub fn delete{s}(self: *{s}Service, id: i64) !void {{\n", .{ model_name, pascal_module });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        return try repo.delete(id);\n");
        try buf.appendSlice(allocator, "    }\n\n");
    }

    try buf.appendSlice(allocator, orm_tpl.sqlx_service_footer);
    return buf.toOwnedSlice(allocator);
}

fn generateModuleApi(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef, style: CodeStyle) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_module = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_module);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_api_header, module_name, pascal_module);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);
        const snake_name = try toSnakeCase(allocator, table.name);
        defer allocator.free(snake_name);
        const list_fn = try std.fmt.allocPrint(allocator, "list{s}s", .{model_name});
        defer allocator.free(list_fn);
        const get_fn = try std.fmt.allocPrint(allocator, "get{s}", .{model_name});
        defer allocator.free(get_fn);
        const create_fn = try std.fmt.allocPrint(allocator, "create{s}", .{model_name});
        defer allocator.free(create_fn);
        const update_fn = try std.fmt.allocPrint(allocator, "update{s}", .{model_name});
        defer allocator.free(update_fn);
        const delete_fn = try std.fmt.allocPrint(allocator, "delete{s}", .{model_name});
        defer allocator.free(delete_fn);

        if (style == .java) {
            // Route base = table name minus "system_" prefix, with _ → - for kebab-case URLs
            const route_base = blk: {
                const stripped = if (std.mem.startsWith(u8, snake_name, "system_")) snake_name["system_".len..] else snake_name;
                // Replace _ with - for URL-friendly kebab-case
                var kebab = try allocator.alloc(u8, stripped.len);
                for (stripped, 0..) |c, idx| { kebab[idx] = if (c == '_') '-' else c; }
                break :blk kebab;
            };
            try buf.print(allocator, "        try group.get(\"/system/{s}/page\", {s}, @ptrCast(@alignCast(self)));\n", .{ route_base, list_fn });
            try buf.print(allocator, "        try group.get(\"/system/{s}/get\", {s}, @ptrCast(@alignCast(self)));\n", .{ route_base, get_fn });
            try buf.print(allocator, "        try group.post(\"/system/{s}/create\", {s}, @ptrCast(@alignCast(self)));\n", .{ route_base, create_fn });
            try buf.print(allocator, "        try group.put(\"/system/{s}/update\", {s}, @ptrCast(@alignCast(self)));\n", .{ route_base, update_fn });
            try buf.print(allocator, "        try group.delete(\"/system/{s}/delete\", {s}, @ptrCast(@alignCast(self)));\n", .{ route_base, delete_fn });
        } else {
            try buf.print(allocator, "        try group.get(\"/{s}s\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, list_fn });
            try buf.print(allocator, "        try group.get(\"/{s}s/:id\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, get_fn });
            try buf.print(allocator, "        try group.post(\"/{s}s\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, create_fn });
            try buf.print(allocator, "        try group.put(\"/{s}s/:id\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, update_fn });
            try buf.print(allocator, "        try group.delete(\"/{s}s/:id\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, delete_fn });
        }
    }
    try buf.appendSlice(allocator, "    }\n\n");

    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);
        const list_fn = try std.fmt.allocPrint(allocator, "list{s}s", .{model_name});
        defer allocator.free(list_fn);
        const get_fn = try std.fmt.allocPrint(allocator, "get{s}", .{model_name});
        defer allocator.free(get_fn);
        const create_fn = try std.fmt.allocPrint(allocator, "create{s}", .{model_name});
        defer allocator.free(create_fn);
        const update_fn = try std.fmt.allocPrint(allocator, "update{s}", .{model_name});
        defer allocator.free(update_fn);
        const delete_fn = try std.fmt.allocPrint(allocator, "delete{s}", .{model_name});
        defer allocator.free(delete_fn);

        if (style == .java) {
            // -- Java-style list handler (pageNo/pageSize → page, sendPageResult)
            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{list_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.appendSlice(allocator, "        const pageNo = std.fmt.parseInt(usize, ctx.query.get(\"pageNo\") orelse \"1\", 10) catch 1;\n");
            try buf.appendSlice(allocator, "        const pageSize = std.fmt.parseInt(usize, ctx.query.get(\"pageSize\") orelse \"10\", 10) catch 10;\n");
            try buf.print(allocator, "        const result = try self.service.{s}(if (pageNo > 0) pageNo - 1 else 0, pageSize);\n", .{list_fn});
            try buf.appendSlice(allocator, "        var itemsBuf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };\n");
            try buf.appendSlice(allocator, "        try itemsBuf.appendSlice(ctx.allocator, \"[\");\n");
            try buf.appendSlice(allocator, "        for (result.items, 0..) |item, i| {\n");
            try buf.appendSlice(allocator, "            if (i > 0) try itemsBuf.appendSlice(ctx.allocator, \",\");\n");
            try buf.appendSlice(allocator, "            try itemsBuf.appendSlice(ctx.allocator, try std.fmt.allocPrint(ctx.allocator, \"{any}\", .{std.json.fmt(item, .{})}));\n");
            try buf.appendSlice(allocator, "        }\n");
            try buf.appendSlice(allocator, "        try itemsBuf.appendSlice(ctx.allocator, \"]\");\n");
            try buf.appendSlice(allocator, "        try ctx.sendPageResult(itemsBuf.items, result.total);\n");
            try buf.appendSlice(allocator, "    }\n\n");

            // Java-style get handler (query param id)
            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{get_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.appendSlice(allocator, "        const id = std.fmt.parseInt(i64, ctx.query.get(\"id\") orelse \"\", 10) catch 0;\n");
            try buf.print(allocator, "        if (try self.service.{s}(id)) |entity| {{\n", .{get_fn});
            try buf.appendSlice(allocator, "            try ctx.sendSuccess(try std.fmt.allocPrint(ctx.allocator, \"{any}\", .{std.json.fmt(entity, .{})}));\n");
            try buf.appendSlice(allocator, "        } else { try ctx.sendFail(404, \"Not found\"); }\n");
            try buf.appendSlice(allocator, "    }\n\n");

            // Java-style create handler
            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{create_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{ try ctx.sendFail(400, \"Invalid body\"); return; }};\n", .{model_name});
            try buf.print(allocator, "        const created = try self.service.{s}(entity);\n", .{create_fn});
            try buf.appendSlice(allocator, "        try ctx.sendSuccess(try std.fmt.allocPrint(ctx.allocator, \"{\\\"id\\\":{d}}\", .{created.id}));\n");
            try buf.appendSlice(allocator, "    }\n\n");

            // Java-style update handler
            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{update_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{ try ctx.sendFail(400, \"Invalid body\"); return; }};\n", .{model_name});
            try buf.print(allocator, "        try self.service.{s}(entity);\n", .{update_fn});
            try buf.appendSlice(allocator, "        try ctx.sendSuccess(\"true\");\n");
            try buf.appendSlice(allocator, "    }\n\n");

            // Java-style delete handler
            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{delete_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.appendSlice(allocator, "        const id = std.fmt.parseInt(i64, ctx.query.get(\"id\") orelse \"\", 10) catch 0;\n");
            try buf.print(allocator, "        try self.service.{s}(id);\n", .{delete_fn});
            try buf.appendSlice(allocator, "        try ctx.sendSuccess(\"true\");\n");
            try buf.appendSlice(allocator, "    }\n\n");
        } else {
            // Default-style handlers (unchanged)
            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{list_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.appendSlice(allocator, "        const page_str = ctx.query.get(\"page\") orelse \"0\";\n");
            try buf.appendSlice(allocator, "        const size_str = ctx.query.get(\"size\") orelse \"10\";\n");
            try buf.appendSlice(allocator, "        const page = std.fmt.parseInt(usize, page_str, 10) catch {\n");
            try buf.print(allocator, "            std.log.warn(\"[{s}] list: invalid page\", .{{}});\n", .{module_name});
            try buf.appendSlice(allocator, "            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), \"invalid page\");\n");
            try buf.appendSlice(allocator, "            return;\n");
            try buf.appendSlice(allocator, "        };\n");
            try buf.appendSlice(allocator, "        const size = std.fmt.parseInt(usize, size_str, 10) catch {\n");
            try buf.print(allocator, "            std.log.warn(\"[{s}] list: invalid size\", .{{}});\n", .{module_name});
            try buf.appendSlice(allocator, "            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), \"invalid size\");\n");
            try buf.appendSlice(allocator, "            return;\n");
            try buf.appendSlice(allocator, "        };\n");
            try buf.print(allocator, "        const result = try self.service.{s}(page, size);\n", .{list_fn});
            try buf.appendSlice(allocator, "        try ctx.jsonStruct(200, result);\n");
            try buf.appendSlice(allocator, "    }\n\n");

            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{get_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.appendSlice(allocator, "        const id_str = ctx.params.get(\"id\") orelse {\n");
            try buf.print(allocator, "            std.log.warn(\"[{s}] get: missing id\", .{{}});\n", .{module_name});
            try buf.appendSlice(allocator, "            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), \"missing id\");\n");
            try buf.appendSlice(allocator, "            return;\n");
            try buf.appendSlice(allocator, "        };\n");
            try buf.appendSlice(allocator, "        const id = std.fmt.parseInt(i64, id_str, 10) catch {\n");
            try buf.print(allocator, "            std.log.warn(\"[{s}] get: invalid id\", .{{}});\n", .{module_name});
            try buf.appendSlice(allocator, "            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), \"invalid id\");\n");
            try buf.appendSlice(allocator, "            return;\n");
            try buf.appendSlice(allocator, "        };\n");
            try buf.print(allocator, "        const entity = try self.service.{s}(id);\n", .{get_fn});
            try buf.appendSlice(allocator, "        try ctx.jsonStruct(200, entity);\n");
            try buf.appendSlice(allocator, "    }\n\n");

            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{create_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{\n", .{model_name});
            try buf.print(allocator, "            std.log.warn(\"[{s}] create: invalid body\", .{{}});\n", .{module_name});
            try buf.appendSlice(allocator, "            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), \"invalid body\");\n");
            try buf.appendSlice(allocator, "            return;\n");
            try buf.appendSlice(allocator, "        };\n");
            try buf.print(allocator, "        const created = try self.service.{s}(entity);\n", .{create_fn});
            try buf.appendSlice(allocator, "        try ctx.jsonStruct(201, created);\n");
            try buf.appendSlice(allocator, "    }\n\n");

            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{update_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{\n", .{model_name});
            try buf.print(allocator, "            std.log.warn(\"[{s}] update: invalid body\", .{{}});\n", .{module_name});
            try buf.appendSlice(allocator, "            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), \"invalid body\");\n");
            try buf.appendSlice(allocator, "            return;\n");
            try buf.appendSlice(allocator, "        };\n");
            try buf.print(allocator, "        try self.service.{s}(entity);\n", .{update_fn});
            try buf.appendSlice(allocator, "        try ctx.jsonStruct(200, entity);\n");
            try buf.appendSlice(allocator, "    }\n\n");

            try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Context) !void {{\n", .{delete_fn});
            try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data orelse return error.InternalError));\n", .{pascal_module});
            try buf.appendSlice(allocator, "        const id_str = ctx.params.get(\"id\") orelse {\n");
            try buf.print(allocator, "            std.log.warn(\"[{s}] delete: missing id\", .{{}});\n", .{module_name});
            try buf.appendSlice(allocator, "            try ctx.sendErrorResponse(400, @intFromEnum(zigmodu.HttpCode.BadRequest), \"invalid id\");\n");
            try buf.appendSlice(allocator, "            return;\n");
            try buf.appendSlice(allocator, "        };\n");
            try buf.print(allocator, "        try self.service.{s}(id);\n", .{delete_fn});
            try buf.appendSlice(allocator, "        try ctx.json(204, \"\");\n");
            try buf.appendSlice(allocator, "    }\n\n");
        }
    }

    try buf.appendSlice(allocator, orm_tpl.sqlx_api_footer);
    return buf.toOwnedSlice(allocator);
}

fn generateModuleZig(allocator: std.mem.Allocator, module_name: []const u8, dependencies: []const u8) ![]const u8 {
    const pascal = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal);
    const template = orm_tpl.sqlx_module_zig;
    // Replace <<MODULE_NAME>> and <<PASCAL_MODULE>> first
    const s1 = try orm_tpl.expandOrm(allocator, template, module_name, pascal);
    defer allocator.free(s1);
    // Then replace <<DEPS>> with actual dependencies
    return replaceAllStr(allocator, s1, "<<DEPS>>", dependencies);
}

fn replaceAllStr(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
            try out.appendSlice(allocator, replacement);
            i += needle.len;
        } else {
            try out.append(allocator, haystack[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Generate AI context index file (_ai.zig) for a module.
/// Provides machine-readable metadata: dependencies, tables, API surface, extension points.
fn generateAiContext(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef, dependencies: []const u8) ![]const u8 {
    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);

    var buf: std.ArrayList(u8) = .empty;

    try buf.appendSlice(allocator, "// ═══════════════════════════════════════════════════════════\n");
    try buf.appendSlice(allocator, "// AI Context: ");
    try buf.appendSlice(allocator, module_name);
    try buf.appendSlice(allocator, " module\n");
    try buf.appendSlice(allocator, "// ═══════════════════════════════════════════════════════════\n");
    try buf.appendSlice(allocator, "// Dependencies: ");
    try buf.appendSlice(allocator, dependencies);
    try buf.appendSlice(allocator, "\n");
    try buf.appendSlice(allocator, "// Tables:\n");
    for (tables) |table| {
        try buf.print(allocator, "//   {s} — ", .{table.name});
        var col_count: usize = 0;
        for (table.columns) |col| {
            if (col.col_type == .unknown and col.name.len == 0) continue;
            col_count += 1;
        }
        try buf.print(allocator, "{d} columns", .{col_count});
        if (table.foreign_keys.len > 0) {
            try buf.appendSlice(allocator, ", FK: ");
            for (table.foreign_keys, 0..) |fk, idx| {
                if (idx > 0) try buf.appendSlice(allocator, ", ");
                try buf.print(allocator, "{s}→{s}", .{ fk.column_name, fk.ref_table });
            }
        }
        try buf.appendSlice(allocator, "\n");
    }
    try buf.appendSlice(allocator, "//\n");
    try buf.appendSlice(allocator, "// Public API: service.zig\n");
    for (tables) |table| {
        const model_name = try toPascalCase(allocator, table.name);
        defer allocator.free(model_name);
        try buf.print(allocator, "//   list{s}s / get{s} / create{s} / update{s} / delete{s}\n", .{ model_name, model_name, model_name, model_name, model_name });
    }
    try buf.appendSlice(allocator, "//\n");
    try buf.appendSlice(allocator, "// Extension points:\n");
    try buf.appendSlice(allocator, "//   service_ext.zig — custom business logic (survives regeneration)\n");
    try buf.appendSlice(allocator, "//   api_ext.zig — custom HTTP endpoints (survives regeneration)\n");
    try buf.appendSlice(allocator, "//\n");
    try buf.appendSlice(allocator, "// File map:\n");
    try buf.appendSlice(allocator, "//   module.zig — declaration layer (module contract)\n");
    try buf.appendSlice(allocator, "//   model.zig — data structures + jsonStringify\n");
    try buf.appendSlice(allocator, "//   persistence.zig — ORM repositories\n");
    try buf.appendSlice(allocator, "//   service.zig — CRUD delegation + event hooks\n");
    try buf.appendSlice(allocator, "//   api.zig — HTTP routes + JSON handlers\n");
    try buf.appendSlice(allocator, "//   root.zig — barrel exports\n");
    try buf.appendSlice(allocator, "//   test.zig — smoke tests\n");
    try buf.appendSlice(allocator, "// ═══════════════════════════════════════════════════════════\n");

    return buf.toOwnedSlice(allocator);
}

fn writeModuleFiles(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8, module_name: []const u8, tables: []const TableDef, opts: GenOptions) !void {
    const module_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, module_name });
    defer allocator.free(module_dir);
    try ensureDirGen(io, module_dir, opts);

    const model_code = try generateModuleModel(allocator, module_name, tables);
    defer allocator.free(model_code);
    const model_path = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{module_dir});
    defer allocator.free(model_path);
    try writeFileGen(io, model_path, model_code, opts);

    const persistence_code = try generateModulePersistence(allocator, module_name, tables);
    defer allocator.free(persistence_code);
    const persistence_path = try std.fmt.allocPrint(allocator, "{s}/persistence.zig", .{module_dir});
    defer allocator.free(persistence_path);
    try writeFileGen(io, persistence_path, persistence_code, opts);

    if (!opts.data_only) {
        const service_code = try generateModuleService(allocator, module_name, tables);
        defer allocator.free(service_code);
        const service_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{module_dir});
        defer allocator.free(service_path);
        try writeFileGen(io, service_path, service_code, opts);

        const api_code = try generateModuleApi(allocator, module_name, tables, opts.style);
        defer allocator.free(api_code);
        const api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{module_dir});
        defer allocator.free(api_path);
        try writeFileGen(io, api_path, api_code, opts);

        const dependencies_str = try inferModuleDependencies(allocator, tables, module_name, 0);
        defer allocator.free(dependencies_str);

        const module_code = try generateModuleZig(allocator, module_name, dependencies_str);
        defer allocator.free(module_code);
        const module_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{module_dir});
        defer allocator.free(module_path);
        try writeFileGen(io, module_path, module_code, opts);

        const pascal_mod = try toPascalCase(allocator, module_name);
        defer allocator.free(pascal_mod);
        const root_code = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_root_zig, module_name, pascal_mod);
        defer allocator.free(root_code);
        const root_path = try std.fmt.allocPrint(allocator, "{s}/root.zig", .{module_dir});
        defer allocator.free(root_path);
        try writeFileGen(io, root_path, root_code, opts);

        // Generate test.zig
        const test_code = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_test_zig, module_name, pascal_mod);
        defer allocator.free(test_code);
        const test_path = try std.fmt.allocPrint(allocator, "{s}/test.zig", .{module_dir});
        defer allocator.free(test_path);
        try writeFileGen(io, test_path, test_code, opts);

        // Generate _ai.zig — AI context index
        const ai_ctx = try generateAiContext(allocator, module_name, tables, dependencies_str);
        defer allocator.free(ai_ctx);
        const ai_path = try std.fmt.allocPrint(allocator, "{s}/_ai.zig", .{module_dir});
        defer allocator.free(ai_path);
        try writeFileGen(io, ai_path, ai_ctx, opts);

        // Generate _arch_test.zig — architecture verification tests
        const arch_tpl = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_arch_test_zig, module_name, pascal_mod);
        defer allocator.free(arch_tpl);
        const arch_with_deps = try replaceAllStr(allocator, arch_tpl, "<<DEPS>>", dependencies_str);
        defer allocator.free(arch_with_deps);
        const arch_path = try std.fmt.allocPrint(allocator, "{s}/_arch_test.zig", .{module_dir});
        defer allocator.free(arch_path);
        try writeFileGen(io, arch_path, arch_with_deps, opts);
    }

    std.log.info("Generated module '{s}' at {s}/ with {d} table(s)", .{ module_name, module_dir, tables.len });
}

fn generateZentSchema(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef) ![]const u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.zent_schema_header, module_name, pascal_mod);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);
    try buf.appendSlice(allocator, orm_tpl.zent_schema_imports);

    // Generate schema for each table
    for (tables) |table| {
        const schema_name = try toPascalCase(allocator, table.name);
        defer allocator.free(schema_name);

        // Check if table has created_at or updated_at for TimeMixin
        var has_time_fields = false;
        for (table.columns) |col| {
            if (std.mem.eql(u8, col.name, "created_at") or
                std.mem.eql(u8, col.name, "updated_at")) {
                has_time_fields = true;
                break;
            }
        }

        try buf.print(allocator, "const {s} = Schema(\"{s}\", .{{", .{ schema_name, schema_name });
        try buf.appendSlice(allocator, "\n    .fields = &.{\n");

        for (table.columns) |col| {
            if (col.col_type == .unknown and col.name.len == 0) continue;
            const col_name = col.name;
            const is_pk = col.is_primary_key;

            // Build field definition with chain methods
            var field_buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
            defer field_buf.deinit(allocator);

            // Field constructor
            const constructor = switch (col.col_type) {
                .int => "Int",
                .string => "String",
                .bool => "Bool",
                .float => "Float",
                .datetime => "Time",
                .unknown => "String",
            };
            try field_buf.print(allocator, "        field.{s}(\"{s}\")", .{ constructor, col_name });

            // Chain modifiers
            if (is_pk) {
                try field_buf.appendSlice(allocator, ".Unique()");
            } else if (col.is_unique) {
                try field_buf.appendSlice(allocator, ".Unique()");
            }

            if (is_pk) {
                try field_buf.appendSlice(allocator, ".Required()");
            } else if (!col.nullable) {
                try field_buf.appendSlice(allocator, ".Required()");
            } else {
                try field_buf.appendSlice(allocator, ".Optional()");
            }

            if (col.has_default) {
                try field_buf.appendSlice(allocator, ".Default(\"\")");
            }

            try field_buf.appendSlice(allocator, ",\n");
            try buf.appendSlice(allocator, field_buf.items);
        }

        try buf.appendSlice(allocator, "    },\n");

        if (has_time_fields) {
            try buf.appendSlice(allocator, "    .mixins = &.{zent.core.mixin.TimeMixin},\n");
        }

        try buf.appendSlice(allocator, "});\n\n");
    }

    return buf.toOwnedSlice(allocator);
}

fn generateZentClient(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef) ![]const u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);
    const head = try orm_tpl.expandOrm(allocator, orm_tpl.zent_client_header, module_name, pascal_mod);
    defer allocator.free(head);
    try buf.appendSlice(allocator, trimTrailingNewlines(head));

    for (tables, 0..tables.len) |table, idx| {
        const schema_name = try toPascalCase(allocator, table.name);
        defer allocator.free(schema_name);
        if (idx == tables.len - 1) {
            try buf.print(allocator, "{s}", .{schema_name});
        } else {
            try buf.print(allocator, "{s}, ", .{schema_name});
        }
    }

    try buf.appendSlice(allocator, orm_tpl.zent_client_footer);

    return buf.toOwnedSlice(allocator);
}

fn writeModuleFilesZent(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8, module_name: []const u8, tables: []const TableDef, opts: GenOptions) !void {
    const module_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, module_name });
    defer allocator.free(module_dir);
    try ensureDirGen(io, module_dir, opts);

    // Generate schema.zig
    const schema_code = try generateZentSchema(allocator, module_name, tables);
    defer allocator.free(schema_code);
    const schema_path = try std.fmt.allocPrint(allocator, "{s}/schema.zig", .{module_dir});
    defer allocator.free(schema_path);
    try writeFileGen(io, schema_path, schema_code, opts);

    // Generate client.zig
    const client_code = try generateZentClient(allocator, module_name, tables);
    defer allocator.free(client_code);
    const client_path = try std.fmt.allocPrint(allocator, "{s}/client.zig", .{module_dir});
    defer allocator.free(client_path);
    try writeFileGen(io, client_path, client_code, opts);

    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);
    const module_code = try orm_tpl.expandOrm(allocator, orm_tpl.zent_module_zig, module_name, pascal_mod);
    defer allocator.free(module_code);
    const module_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{module_dir});
    defer allocator.free(module_path);
    try writeFileGen(io, module_path, module_code, opts);

    const root_code = try orm_tpl.expandOrm(allocator, orm_tpl.zent_root_zig, module_name, pascal_mod);
    defer allocator.free(root_code);
    const root_path = try std.fmt.allocPrint(allocator, "{s}/root.zig", .{module_dir});
    defer allocator.free(root_path);
    try writeFileGen(io, root_path, root_code, opts);

    std.log.info("Generated zent module '{s}' at {s}/ with {d} table(s)", .{ module_name, module_dir, tables.len });
}

fn cmdGenerate(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zmodu generate <module|event|api|orm> [options]", .{});
        return error.CliUsage;
    }

    const sub = args[0];
    if (std.mem.eql(u8, sub, "module")) {
        if (args.len >= 3 and std.mem.eql(u8, args[1], "--sql")) {
            try cmdOrm(io, allocator, args[1..]);
        } else if (args.len >= 2) {
            try cmdModule(io, allocator, args[1..]);
        } else {
            std.log.err("Usage: zmodu generate module <name> [--dry-run] [--force] | zmodu generate module --sql <file> [--out …] [--backend …] [--dry-run] [--force]", .{});
            return error.CliUsage;
        }
    } else if (std.mem.eql(u8, sub, "event")) {
        try cmdEvent(io, allocator, args[1..]);
    } else if (std.mem.eql(u8, sub, "api")) {
        try cmdApi(io, allocator, args[1..]);
    } else if (std.mem.eql(u8, sub, "orm")) {
        try cmdOrm(io, allocator, args[1..]);
    } else {
        std.log.err("Unknown generate target: {s}", .{sub});
        return error.CliUsage;
    }
}

fn cmdOrm(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const cli = switch (parseOrmCli(args)) {
        .ok => |c| c,
        .err_unknown_flag => |flag| {
            std.log.err("Unknown orm option: {s}", .{flag});
            return error.CliUsage;
        },
        .err_missing_value => |flag| {
            std.log.err("Missing value after {s}.", .{flag});
            return error.CliUsage;
        },
    };

    if (cli.sql_path == null) {
        std.log.err("Usage: zmodu orm --sql <file> [--out <dir>] [--module <name>] [--backend sqlx|zent] [--dry-run] [--force]", .{});
        return error.CliUsage;
    }

    if (!std.mem.eql(u8, cli.backend, "sqlx") and !std.mem.eql(u8, cli.backend, "zent")) {
        std.log.err("Unknown backend: {s}. Supported: sqlx, zent", .{cli.backend});
        return error.CliUsage;
    }

    const sql_path = cli.sql_path.?;
    const out_dir = cli.out_dir;
    const forced_module = cli.forced_module;
    const backend = cli.backend;
    const opts = cli.opts;

    if (pathContainsDotDot(out_dir)) {
        std.log.err("--out must not contain '..': {s}", .{out_dir});
        return error.CliUsage;
    }
    if (forced_module) |m| {
        if (!isSafeModuleDirName(m)) {
            std.log.err("--module must be a single directory name (no '/', '\\', or '..'): {s}", .{m});
            return error.CliUsage;
        }
    }

    const sql_content = std.Io.Dir.cwd().readFileAlloc(io, sql_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        std.log.err("Cannot read SQL file '{s}': {s}", .{ sql_path, @errorName(err) });
        return err;
    };
    defer allocator.free(sql_content);

    const sql_for_parse = stripUtf8BomAndTrimSql(sql_content);
    if (sql_for_parse.len == 0) {
        if (opts.dry_run) {
            std.log.warn("SQL file '{s}' is empty after stripping BOM/whitespace (--dry-run: nothing to preview).", .{sql_path});
            return;
        }
        std.log.err("SQL file '{s}' is empty (or only whitespace/BOM).", .{sql_path});
        return error.CliUsage;
    }

    const tables = parseSqlSchema(allocator, sql_for_parse) catch |err| {
        std.log.err("Failed to parse SQL in '{s}': {s}", .{ sql_path, @errorName(err) });
        return err;
    };
    defer {
        for (tables) |t| {
            allocator.free(t.name);
            for (t.columns) |c| {
                allocator.free(c.name);
                if (c.comment) |com| allocator.free(com);
            }
            allocator.free(t.columns);
            for (t.foreign_keys) |fk| {
                allocator.free(fk.column_name);
                allocator.free(fk.ref_table);
                allocator.free(fk.ref_column);
            }
            allocator.free(t.foreign_keys);
        }
        allocator.free(tables);
    }

    if (tables.len == 0) {
        if (opts.dry_run) {
            std.log.warn("No CREATE TABLE found in '{s}' (--dry-run: no writes; would fail without --dry-run).", .{sql_path});
            return;
        }
        std.log.err("No CREATE TABLE found in '{s}'. Add at least one table or check the file path.", .{sql_path});
        return error.CliUsage;
    }

    std.log.info("Parsed {d} table(s) from {s}", .{ tables.len, sql_path });

    if (forced_module) |mod_name| {
        // --module <name>: force all tables into a single module
        if (std.mem.eql(u8, backend, "zent")) {
            try writeModuleFilesZent(io, allocator, out_dir, mod_name, tables, opts);
        } else {
            try writeModuleFiles(io, allocator, out_dir, mod_name, tables, opts);
        }
        std.log.info("All {d} table(s) placed in module '{s}'", .{ tables.len, mod_name });
        return;
    }

    // Auto-group: smart prefix detection + multi-module generation
    var module_map = try groupTablesByModule(allocator, tables);
    defer {
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        module_map.deinit();
    }

    try ensureDirGen(io, out_dir, opts);

    var iter = module_map.iterator();
    var module_count: usize = 0;
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, backend, "zent")) {
            try writeModuleFilesZent(io, allocator, out_dir, entry.key_ptr.*, entry.value_ptr.items, opts);
        } else {
            try writeModuleFiles(io, allocator, out_dir, entry.key_ptr.*, entry.value_ptr.items, opts);
        }
        module_count += 1;
    }
    std.log.info("Auto-grouped {d} table(s) into {d} module(s)", .{ tables.len, module_count });
}

// ── bigdemo: shortcut to regenerate the full shopdemo ──────────────

fn cmdBigdemo(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args; // no extra args — everything is hardcoded
    const embedded_sql = @embedFile("shopdemo/init.sql");

    // Write embedded SQL to a temp file so cmdScaffold can read it
    const tmp_path = ".zmodu_bigdemo_tmp.sql";
    const tmp_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    try tmp_file.writeStreamingAll(io, embedded_sql);
    tmp_file.close(io);
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    // Delegate to scaffold with all capability flags
    const scaffold_args = [_][]const u8{
        "--sql",        tmp_path,
        "--name",       "shopdemo",
        "--out",        ".",
        "--with-events",
        "--with-resilience",
        "--with-cluster",
        "--with-marketing",
        "--force",
    };

    std.log.info("🚀 zmodu bigdemo — regenerating shopdemo (152 tables, 42 modules)...", .{});
    try cmdScaffold(io, allocator, &scaffold_args);
    std.log.info("✅ bigdemo complete — shopdemo/ ready with 484 .zig files", .{});
}

// ── scaffold: one-shot SQL → full project ────────────────────────

const ScaffoldOpts = struct {
    sql_path: []const u8,
    project_name: []const u8,
    out_dir: []const u8,
    force: bool,
    dry_run: bool,
    with_events: bool = false,
    with_resilience: bool = false,
    with_cluster: bool = false,
    with_marketing: bool = false,
};

fn parseScaffoldArgs(allocator: std.mem.Allocator, args: []const []const u8) !ScaffoldOpts {
    _ = allocator;
    var sql_path: ?[]const u8 = null;
    var project_name: ?[]const u8 = null;
    var out_dir: []const u8 = ".";
    var force: bool = false;
    var dry_run: bool = false;

    var with_events: bool = false;
    var with_resilience: bool = false;
    var with_cluster: bool = false;
    var with_marketing: bool = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--sql")) {
            if (i + 1 >= args.len) return error.CliUsage;
            sql_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--name")) {
            if (i + 1 >= args.len) return error.CliUsage;
            project_name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--out")) {
            if (i + 1 >= args.len) return error.CliUsage;
            out_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            force = true;
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--with-events")) {
            with_events = true;
        } else if (std.mem.eql(u8, args[i], "--with-resilience")) {
            with_resilience = true;
        } else if (std.mem.eql(u8, args[i], "--with-cluster")) {
            with_cluster = true;
        } else if (std.mem.eql(u8, args[i], "--with-marketing")) {
            with_marketing = true;
        } else {
            std.log.err("Unknown scaffold option: {s}", .{args[i]});
            return error.CliUsage;
        }
    }

    if (sql_path == null) {
        std.log.err("scaffold requires --sql <file>", .{});
        return error.CliUsage;
    }
    if (project_name == null) {
        std.log.err("scaffold requires --name <project-name>", .{});
        return error.CliUsage;
    }
    return ScaffoldOpts{
        .sql_path = sql_path.?,
        .project_name = project_name.?,
        .out_dir = out_dir,
        .force = force,
        .dry_run = dry_run,
        .with_events = with_events,
        .with_resilience = with_resilience,
        .with_cluster = with_cluster,
        .with_marketing = with_marketing,
    };
}

fn cmdScaffold(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const sopts = try parseScaffoldArgs(allocator, args);

    // 1. Read SQL
    const sql_content = std.Io.Dir.cwd().readFileAlloc(io, sopts.sql_path, allocator, std.Io.Limit.limited(1024 * 1024)) catch |err| {
        std.log.err("Cannot read SQL file '{s}': {s}", .{ sopts.sql_path, @errorName(err) });
        return err;
    };
    defer allocator.free(sql_content);

    const sql_for_parse = stripUtf8BomAndTrimSql(sql_content);
    if (sql_for_parse.len == 0) return error.CliUsage;

    const tables = parseSqlSchema(allocator, sql_for_parse) catch |err| {
        std.log.err("Failed to parse SQL: {s}", .{@errorName(err)});
        return err;
    };
    defer {
        for (tables) |t| {
            allocator.free(t.name);
            for (t.columns) |c| {
                allocator.free(c.name);
                if (c.comment) |com| allocator.free(com);
            }
            allocator.free(t.columns);
            for (t.foreign_keys) |fk| {
                allocator.free(fk.column_name);
                allocator.free(fk.ref_table);
                allocator.free(fk.ref_column);
            }
            allocator.free(t.foreign_keys);
        }
        allocator.free(tables);
    }

    if (tables.len == 0) {
        std.log.err("No CREATE TABLE found in '{s}'", .{sopts.sql_path});
        return error.CliUsage;
    }

    std.log.info("Scaffolding '{s}' from {d} tables in {s}", .{ sopts.project_name, tables.len, sopts.sql_path });

    // 2. Auto-group tables into modules
    var module_map = try groupTablesByModule(allocator, tables);
    defer {
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        module_map.deinit();
    }

    // Collect sorted module names for deterministic codegen
    var module_names: std.ArrayList([]const u8) = .empty;
    defer module_names.deinit(allocator);
    {
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            try module_names.append(allocator, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, module_names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool { return std.mem.lessThan(u8, a, b); }
        }.lt);
    }

    // 3. Create project directory structure
    const project_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sopts.out_dir, sopts.project_name });
    defer allocator.free(project_dir);

    if (sopts.dry_run) {
        std.log.info("[dry-run] mkdir -p {s}", .{project_dir});
    } else {
        try std.Io.Dir.cwd().createDirPath(io, project_dir);
    }

    // 4. Generate modules under src/modules/
    const modules_dir = try std.fmt.allocPrint(allocator, "{s}/src/modules", .{project_dir});
    defer allocator.free(modules_dir);
    const gen_opts: GenOptions = .{ .dry_run = sopts.dry_run, .force = sopts.force };

    for (module_names.items) |mod_name| {
        const tables_for_mod = module_map.get(mod_name).?;
        try writeModuleFiles(io, allocator, modules_dir, mod_name, tables_for_mod.items, gen_opts);

        // Generate service_ext.zig template per module
        const pascal_mod = try toPascalCase(allocator, mod_name);
        defer allocator.free(pascal_mod);
        const ext_svc = try std.fmt.allocPrint(allocator,
            \\// {s} service extension — add custom business logic here.
            \\// Survives zmodu regeneration.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const {s}_svc = @import("service.zig");
            \\
            \\pub const {s}ServiceExt = struct {{
            \\    svc: *{s}_svc.{s}Service,
            \\    backend: zigmodu.SqlxBackend,
            \\
            \\    pub fn init(svc: *{s}_svc.{s}Service, backend: zigmodu.SqlxBackend) {s}ServiceExt {{
            \\        return .{{ .svc = svc, .backend = backend }};
            \\    }}
            \\
            \\    // Add your custom business methods here
            \\}};
            \\
        , .{ mod_name, mod_name, pascal_mod, mod_name, pascal_mod, mod_name, pascal_mod, pascal_mod });
        defer allocator.free(ext_svc);
        const ext_svc_path = try std.fmt.allocPrint(allocator, "{s}/{s}/service_ext.zig", .{ modules_dir, mod_name });
        defer allocator.free(ext_svc_path);
        try writeFileGen(io, ext_svc_path, ext_svc, gen_opts);

        // Generate api_ext.zig template per module
        const ext_api = try std.fmt.allocPrint(allocator,
            \\// {s} custom API endpoints — add business routes here.
            \\// Survives zmodu regeneration.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const {s}_ext = @import("service_ext.zig");
            \\
            \\pub const {s}ApiExt = struct {{
            \\    ext: *{s}_ext.{s}ServiceExt,
            \\
            \\    pub fn init(ext: *{s}_ext.{s}ServiceExt) {s}ApiExt {{
            \\        return .{{ .ext = ext }};
            \\    }}
            \\
            \\    pub fn registerRoutes(self: *{s}ApiExt, group: *zigmodu.http_server.RouteGroup) !void {{
            \\        _ = self;
            \\        // Add custom routes:
            \\        // try group.get("/{s}/custom", myHandler, @ptrCast(@alignCast(self)));
            \\    }}
            \\}};
            \\
        , .{ mod_name, mod_name, pascal_mod, mod_name, pascal_mod, mod_name, pascal_mod, pascal_mod, pascal_mod, mod_name });
        defer allocator.free(ext_api);
        const ext_api_path = try std.fmt.allocPrint(allocator, "{s}/{s}/api_ext.zig", .{ modules_dir, mod_name });
        defer allocator.free(ext_api_path);
        try writeFileGen(io, ext_api_path, ext_api, gen_opts);
    }

    // 4.5 Generate marketing module group (--with-marketing)
    if (sopts.with_marketing) {
        const marketing_dir = try std.fmt.allocPrint(allocator, "{s}/marketing", .{modules_dir});
        defer allocator.free(marketing_dir);
        try ensureDirGen(io, marketing_dir, gen_opts);

        const marketing_subs = [_][]const u8{ "coupon", "promotion", "points", "affiliate", "recommendation" };
        for (marketing_subs) |sub| {
            const sub_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ marketing_dir, sub });
            defer allocator.free(sub_dir);
            try ensureDirGen(io, sub_dir, gen_opts);

            const sub_mod = try std.fmt.allocPrint(allocator,
                \\const std = @import("std");
                \\const zigmodu = @import("zigmodu");
                \\
                \\pub const info = zigmodu.api.Module{{
                \\    .name = "marketing.{s}",
                \\    .description = "Marketing {s} sub-module",
                \\    .dependencies = &.{{"marketing"}},
                \\    .is_internal = false,
                \\}};
                \\
                \\pub fn init() !void {{ std.log.info("marketing.{s} initialized", .{{}}); }}
                \\pub fn deinit() void {{ std.log.info("marketing.{s} cleaned up", .{{}}); }}
                \\
            , .{ sub, sub, sub, sub });
            defer allocator.free(sub_mod);
            const sub_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{sub_dir});
            defer allocator.free(sub_path);
            try writeFileGen(io, sub_path, sub_mod, gen_opts);
        }

        // Generate hot_reload/targets/ for marketing rules
        const hot_dir = try std.fmt.allocPrint(allocator, "{s}/hot_reload/targets", .{project_dir});
        defer allocator.free(hot_dir);
        try ensureDirGen(io, hot_dir, gen_opts);

        const hot_rules = [_][]const u8{ "coupon_rules.zig", "promotion_rules.zig", "ab_test_config.zig" };
        for (hot_rules) |rule_file| {
            const rule_content = try std.fmt.allocPrint(allocator,
                \\// Hot-reloadable {s} — edit without restarting the server.
                \\// Watched by: zigmodu.HotReloader
                \\pub const Rules = struct {{
                \\    pub fn evaluate() bool {{ return true; }}
                \\}};
                \\
            , .{rule_file});
            defer allocator.free(rule_content);
            const rule_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ hot_dir, rule_file });
            defer allocator.free(rule_path);
            try writeFileGen(io, rule_path, rule_content, gen_opts);
        }

        // Generate hot_reload/watcher.zig
        const watcher_content =
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\
            \\pub fn initWatcher(allocator: std.mem.Allocator, io: std.Io) !zigmodu.HotReloader {
            \\    var reloader = zigmodu.HotReloader.init(allocator, io);
            \\    try reloader.watchPath("hot_reload/targets/");
            \\    reloader.onChange(struct {
            \\        fn cb(path: []const u8) void {
            \\            std.log.info("[HotReload] Marketing rules changed: {s}", .{path});
            \\        }
            \\    }.cb);
            \\    return reloader;
            \\}
            \\
        ;
        const watcher_path = try std.fmt.allocPrint(allocator, "{s}/hot_reload/watcher.zig", .{project_dir});
        defer allocator.free(watcher_path);
        try writeFileGen(io, watcher_path, watcher_content, gen_opts);

        // Generate plugins/ directory
        const plugins_dir = try std.fmt.allocPrint(allocator, "{s}/plugins", .{project_dir});
        defer allocator.free(plugins_dir);
        try ensureDirGen(io, plugins_dir, gen_opts);

        const premium_dir = try std.fmt.allocPrint(allocator, "{s}/premium", .{plugins_dir});
        defer allocator.free(premium_dir);
        try ensureDirGen(io, premium_dir, gen_opts);

        const community_dir = try std.fmt.allocPrint(allocator, "{s}/community", .{plugins_dir});
        defer allocator.free(community_dir);
        try ensureDirGen(io, community_dir, gen_opts);

        // Plugin manifest
        const manifest_content =
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\
            \\pub const PluginEntry = struct {
            \\    name: []const u8,
            \\    version: []const u8,
            \\    license_key: ?[]const u8 = null,
            \\    init_fn: *const fn () anyerror!void,
            \\};
            \\
            \\pub var registry: std.StringHashMap(PluginEntry) = undefined;
            \\
            \\pub fn init(allocator: std.mem.Allocator) void {
            \\    registry = std.StringHashMap(PluginEntry).init(allocator);
            \\}
            \\
            \\pub fn register(name: []const u8, entry: PluginEntry) !void {
            \\    try registry.put(name, entry);
            \\    std.log.info("[Plugin] Registered: {s} v{s}", .{ name, entry.version });
            \\}
            \\
        ;
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.zig", .{plugins_dir});
        defer allocator.free(manifest_path);
        try writeFileGen(io, manifest_path, manifest_content, gen_opts);

        std.log.info("Marketing module group generated with {d} sub-modules, hot_reload/, and plugins/", .{marketing_subs.len});
    }

    // 5. Generate build.zig
    const build_zig = try generateBuildZig(allocator, sopts.project_name);
    defer allocator.free(build_zig);
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_dir});
    defer allocator.free(build_path);
    try writeFileGen(io, build_path, build_zig, gen_opts);

    // 6. Generate build.zig.zon
    const build_zon = try generateBuildZonImpl(allocator, sopts.project_name, null);
    defer allocator.free(build_zon);
    const zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{project_dir});
    defer allocator.free(zon_path);
    try writeFileGen(io, zon_path, build_zon, gen_opts);

    // 7. Generate src/main.zig with all module wiring
    const main_zig = try generateScaffoldMainZig(allocator, sopts.project_name, module_names.items, sopts);
    defer allocator.free(main_zig);
    const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{project_dir});
    defer allocator.free(main_path);
    try writeFileGen(io, main_path, main_zig, gen_opts);

    // 8. Generate src/tests.zig
    const tests_zig = try generateScaffoldTestsZig(allocator, module_names.items);
    defer allocator.free(tests_zig);
    const tests_path = try std.fmt.allocPrint(allocator, "{s}/src/tests.zig", .{project_dir});
    defer allocator.free(tests_path);
    try writeFileGen(io, tests_path, tests_zig, gen_opts);

    // 9. Generate src/business/root.zig (skeleton)
    const biz_dir = try std.fmt.allocPrint(allocator, "{s}/src/business", .{project_dir});
    defer allocator.free(biz_dir);
    try ensureDirGen(io, biz_dir, gen_opts);

    // Generate business/root.zig with real module stubs
    var biz_root_buf: std.ArrayList(u8) = .empty;
    defer biz_root_buf.deinit(allocator);
    try biz_root_buf.appendSlice(allocator, "// Business logic modules — add your domain logic here.\n");
    try biz_root_buf.appendSlice(allocator, "pub const enums = @import(\"enums.zig\");\n");
    try biz_root_buf.appendSlice(allocator, "pub const commission = @import(\"commission.zig\");\n");
    try biz_root_buf.appendSlice(allocator, "pub const agent = @import(\"agent.zig\");\n");
    try biz_root_buf.appendSlice(allocator, "pub const referral = @import(\"referral.zig\");\n");
    try biz_root_buf.appendSlice(allocator, "pub const order_flow = @import(\"order_flow.zig\");\n");
    try biz_root_buf.appendSlice(allocator, "pub const points = @import(\"points.zig\");\n");
    try biz_root_buf.appendSlice(allocator, "pub const coupon = @import(\"coupon.zig\");\n");
    const biz_root = try biz_root_buf.toOwnedSlice(allocator);
    defer allocator.free(biz_root);
    const biz_root_path = try std.fmt.allocPrint(allocator, "{s}/root.zig", .{biz_dir});
    defer allocator.free(biz_root_path);
    try writeFileGen(io, biz_root_path, biz_root, gen_opts);

    // 10. Generate .env.example
    const env_example =
        \\# Database
        \\DB_HOST=127.0.0.1
        \\DB_PORT=3306
        \\DB_USER=root
        \\DB_PASS=
        \\DB_NAME=heysen
        \\DB_MAX_OPEN=10
        \\DB_MAX_IDLE=5
        \\
        \\# HTTP
        \\HTTP_PORT=8080
        \\
        \\# Agent Distribution
        \\AGENT_LEVEL=2
        \\AGENT_SETTLE_DAYS=7
        \\AGENT_SELF_BUY=false
        \\AGENT_FIRST_RATE=10
        \\AGENT_SECOND_RATE=5
        \\
        \\# Order
        \\ORDER_CLOSE_DAYS=3
        \\ORDER_RECEIVE_DAYS=7
        \\ORDER_REFUND_DAYS=7
        \\
    ;
    const env_path = try std.fmt.allocPrint(allocator, "{s}/.env.example", .{project_dir});
    defer allocator.free(env_path);
    try writeFileGen(io, env_path, env_example, gen_opts);

    if (!sopts.dry_run) {
        try finalizeBuildZigZonFingerprint(io, allocator, sopts.project_name, zon_path);
    }

    std.log.info("Scaffold complete: {d} tables → {d} modules in '{s}'", .{ tables.len, module_names.items.len, project_dir });
    std.log.info("  cd {s} && zig build run", .{project_dir});
}

fn generateScaffoldMainZig(allocator: std.mem.Allocator, project_name: []const u8, module_names: []const []const u8, sopts: ScaffoldOpts) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\
        \\
    );

    // Module imports (with collision detection for reserved names)
    for (module_names) |name| {
        if (std.mem.eql(u8, name, "app") or std.mem.eql(u8, name, "system")) {
            try buf.print(allocator, "const {s}_mod = @import(\"modules/{s}/root.zig\");\n", .{ name, name });
        } else {
            try buf.print(allocator, "const {s} = @import(\"modules/{s}/root.zig\");\n", .{ name, name });
        }
    }

    try buf.appendSlice(allocator, "\nconst business = @import(\"business/root.zig\");\n\n");

    try buf.appendSlice(allocator,
        \\fn envOr(map: *std.process.Environ.Map, allocator: std.mem.Allocator, key: []const u8, default: []const u8) []const u8 {
        \\    if (map.get(key)) |val| return allocator.dupe(u8, val) catch default;
        \\    return default;
        \\}
        \\
        \\fn envU16Or(map: *std.process.Environ.Map, key: []const u8, default: u16) u16 {
        \\    const val = map.get(key) orelse return default;
        \\    return std.fmt.parseInt(u16, val, 10) catch default;
        \\}
        \\
        \\fn envF64Or(map: *std.process.Environ.Map, key: []const u8, default: f64) f64 {
        \\    const val = map.get(key) orelse return default;
        \\    return std.fmt.parseFloat(f64, val) catch default;
        \\}
        \\
        \\fn envBoolOr(map: *std.process.Environ.Map, key: []const u8, default: bool) bool {
        \\    const val = map.get(key) orelse return default;
        \\    return std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
        \\}
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.gpa;
        \\    const env = init.environ_map;
        \\
        \\    const db_host = envOr(env, allocator, "DB_HOST", "127.0.0.1");
        \\    const db_port = envU16Or(env, "DB_PORT", 3306);
        \\    const db_user = envOr(env, allocator, "DB_USER", "root");
        \\    const db_pass = envOr(env, allocator, "DB_PASS", "");
        \\    const db_name = envOr(env, allocator, "DB_NAME", "heysen");
        \\    const db_max_open = envU16Or(env, "DB_MAX_OPEN", 10);
        \\    const db_max_idle = envU16Or(env, "DB_MAX_IDLE", 5);
        \\    const http_port = envU16Or(env, "HTTP_PORT", 8080);
        \\
        \\    const db_cfg = zigmodu.sqlx.Config{
        \\        .driver = .mysql, .host = db_host, .port = @intCast(db_port),
        \\        .database = db_name, .username = db_user, .password = db_pass,
        \\        .max_open_conns = @intCast(db_max_open), .max_idle_conns = @intCast(db_max_idle),
        \\    };
        \\
        \\    var db_client = zigmodu.sqlx.Client.init(allocator, init.io, db_cfg);
        \\    defer db_client.deinit();
        \\    try db_client.connect();
        \\    std.log.info("DB: {s}@{s}:{d}/{s} (pool={d}/{d})", .{ db_user, db_host, db_port, db_name, db_max_open, db_max_idle });
        \\
        \\    const backend = zigmodu.SqlxBackend{ .allocator = allocator, .client = &db_client };
        \\
        \\
    );

    // Persistence init (with collision-aware naming)
    try buf.appendSlice(allocator, "    // -- Persistence --\n");
    for (module_names) |name| {
        const pascal = try toPascalCase(allocator, name);
        defer allocator.free(pascal);
        if (std.mem.eql(u8, name, "app") or std.mem.eql(u8, name, "system")) {
            try buf.print(allocator, "    var {s}_p = {s}_mod.persistence.{s}Persistence.init(backend);\n", .{ name, name, pascal });
        } else {
            try buf.print(allocator, "    var {s}_p = {s}.persistence.{s}Persistence.init(backend);\n", .{ name, name, pascal });
        }
    }

    // Service init
    try buf.appendSlice(allocator, "\n    // -- Service --\n");
    for (module_names) |name| {
        const pascal = try toPascalCase(allocator, name);
        defer allocator.free(pascal);
        if (std.mem.eql(u8, name, "app") or std.mem.eql(u8, name, "system")) {
            try buf.print(allocator, "    var {s}_s = {s}_mod.service.{s}Service.init(&{s}_p);\n", .{ name, name, pascal, name });
        } else {
            try buf.print(allocator, "    var {s}_s = {s}.service.{s}Service.init(&{s}_p);\n", .{ name, name, pascal, name });
        }
    }

    // API init
    try buf.appendSlice(allocator, "\n    // -- API --\n");
    for (module_names) |name| {
        const pascal = try toPascalCase(allocator, name);
        defer allocator.free(pascal);
        if (std.mem.eql(u8, name, "app") or std.mem.eql(u8, name, "system")) {
            try buf.print(allocator, "    var {s}_api = {s}_mod.api.{s}Api.init(&{s}_s);\n", .{ name, name, pascal, name });
        } else {
            try buf.print(allocator, "    var {s}_api = {s}.api.{s}Api.init(&{s}_s);\n", .{ name, name, pascal, name });
        }
    }

    // HTTP server + health check + route registration
    try buf.appendSlice(allocator,
        \\
        \\    // -- HTTP Server --
        \\    var server = zigmodu.http_server.Server.init(init.io, allocator, http_port);
        \\    defer server.deinit();
        \\    var root = server.group("/api");
        \\
        \\    // Health check
        \\    try root.get("/health", healthCheck, null);
        \\
        \\
    );

    for (module_names) |name| {
        try buf.print(allocator, "    try {s}_api.registerRoutes(&root);\n", .{name});
    }

    try buf.appendSlice(allocator,
        \\
        \\    // Custom business endpoints (add your api_ext routes here):
        \\    // const my_ext = @import("modules/my_module/api_ext.zig");
        \\    // var my_api = my_ext.MyApiExt.init(&my_ext_svc);
        \\    // try my_api.registerRoutes(&root);
        \\
        \\
    );

    // ── Capability: Events (Stage B) ──
    if (sopts.with_events) {
        try buf.appendSlice(allocator, "\n    // -- EventBus (Stage B) --\n    const event_bus = zigmodu.TypedEventBus(struct { id: i64, name: []const u8 }).init(allocator);\n    defer event_bus.deinit();\n");
    }

    // ── Capability: Resilience (Stage C) ──
    if (sopts.with_resilience) {
        try buf.appendSlice(allocator, "\n    // -- Resilience (Stage C) --\n    var breaker = try zigmodu.CircuitBreaker.init(allocator, \"db\", .{ .failure_threshold = 5, .success_threshold = 2, .timeout_seconds = 30, .half_open_max_calls = 3 });\n    defer breaker.deinit();\n    var limiter = try zigmodu.RateLimiter.init(allocator, \"api\", 1000, 100);\n    defer limiter.deinit();\n");
    }

    // ── Capability: Cluster (Stage D) ──
    if (sopts.with_cluster) {
        try buf.appendSlice(allocator, "\n    // -- Cluster (Stage D) --\n    const node_id = try std.fmt.allocPrint(allocator, \"node-{d}\", .{@as(u64, @intCast(std.time.milliTimestamp()))});\n    var dist_bus = try zigmodu.DistributedEventBus.init(allocator, init.io, node_id);\n    defer dist_bus.deinit();\n    try dist_bus.start(9091);\n");
    }

    // Module count + lifecycle
    var count_buf: [16]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{module_names.len});

    try buf.appendSlice(allocator, "\n    std.log.info(\"");
    try buf.appendSlice(allocator, count_str);
    try buf.appendSlice(allocator, " modules + health check on :{d}\", .{ http_port });\n\n    // -- Lifecycle --\n    var app = try zigmodu.Application.init(\n        init.io, allocator, \"");
    try buf.appendSlice(allocator, project_name);
    try buf.appendSlice(allocator, "\",\n        .{ ");

    for (module_names) |name| {
        if (std.mem.eql(u8, name, "app") or std.mem.eql(u8, name, "system")) {
            try buf.print(allocator, "{s}_mod.module, ", .{name});
        } else {
            try buf.print(allocator, "{s}.module, ", .{name});
        }
    }
    try buf.appendSlice(allocator, "},\n        .{},\n    );\n    defer app.deinit();\n\n    try app.start();\n    try server.start();\n}\n\nfn healthCheck(ctx: *zigmodu.http_server.Context) !void {\n    try ctx.json(200, \"{\\\"status\\\":\\\"ok\\\"}\");\n}\n");

    return buf.toOwnedSlice(allocator);
}

fn generateScaffoldTestsZig(allocator: std.mem.Allocator, module_names: []const []const u8) ![]const u8 {
    _ = module_names;
    return allocator.dupe(u8,
        \\const std = @import("std");
        \\const business = @import("business/root.zig");
        \\
        \\test "suite" {
        \\    _ = business;
        \\    try std.testing.expect(true);
        \\}
        \\
    );
}

// ── Tests ────────────────────────────────────────────────────────

test "parseColumnDef: PRIMARY KEY implies non-optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const col = try parseColumnDef(alloc, "id BIGINT PRIMARY KEY");
    try std.testing.expectEqualStrings("id", col.name);
    try std.testing.expectEqual(ColumnType.int, col.col_type);
    try std.testing.expect(!col.nullable);
    try std.testing.expect(col.is_primary_key);
}

test "parseColumnDef: nullable when no NOT NULL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const col = try parseColumnDef(alloc, "bio VARCHAR(255)");
    try std.testing.expectEqualStrings("bio", col.name);
    try std.testing.expect(col.nullable);
    try std.testing.expect(!col.is_primary_key);
}

test "trimTrailingNewlines" {
    try std.testing.expectEqualStrings("foo", trimTrailingNewlines("foo\n\r\n"));
    try std.testing.expectEqualStrings("bar ", trimTrailingNewlines("bar \n"));
}

test "generateModule: aligns with zigmodu.api.Module + lifecycle" {
    const a = std.testing.allocator;
    const code = try generateModule(a, "billing");
    defer a.free(code);
    try std.testing.expect(std.mem.indexOf(u8, code, ".is_internal = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub fn init() !void") != null);
    try std.testing.expect(std.mem.indexOf(u8, code, "pub fn deinit() void") != null);
}

test "generateZentClient: buildGraph types on one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cols = [_]ColumnDef{.{
        .name = try a.dupe(u8, "id"),
        .col_type = .int,
        .nullable = false,
        .is_primary_key = true,
        .is_unique = false,
        .has_default = false,
        .comment = null,
    }};
    const table = TableDef{ .name = try a.dupe(u8, "line_item"), .columns = cols[0..], .foreign_keys = &.{} };
    const code = try generateZentClient(a, "order", &.{table});
    try std.testing.expect(std.mem.indexOf(u8, code, "buildGraph(&.{ LineItem });") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, code, "buildGraph(&.{\n"));
}

test "generateZentClient: two tables comma-separated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cols = [_]ColumnDef{.{
        .name = try a.dupe(u8, "id"),
        .col_type = .int,
        .nullable = false,
        .is_primary_key = true,
        .is_unique = false,
        .has_default = false,
        .comment = null,
    }};
    const tables = [_]TableDef{
        .{ .name = try a.dupe(u8, "alpha"), .columns = cols[0..], .foreign_keys = &.{} },
        .{ .name = try a.dupe(u8, "beta"), .columns = cols[0..], .foreign_keys = &.{} },
    };
    const code = try generateZentClient(a, "mix", &tables);
    try std.testing.expect(std.mem.indexOf(u8, code, "buildGraph(&.{ Alpha, Beta });") != null);
}

test "generateZentSchema: TimeMixin when created_at present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cols = [_]ColumnDef{
        .{
            .name = try a.dupe(u8, "id"),
            .col_type = .int,
            .nullable = false,
            .is_primary_key = true,
            .is_unique = false,
            .has_default = false,
            .comment = null,
        },
        .{
            .name = try a.dupe(u8, "created_at"),
            .col_type = .datetime,
            .nullable = true,
            .is_primary_key = false,
            .is_unique = false,
            .has_default = false,
            .comment = null,
        },
    };
    const table = TableDef{ .name = try a.dupe(u8, "log"), .columns = cols[0..], .foreign_keys = &.{} };
    const code = try generateZentSchema(a, "audit", &.{table});
    try std.testing.expect(std.mem.indexOf(u8, code, "TimeMixin") != null);
}

test "parseOrmCli: dry-run and force" {
    const a = [_][]const u8{ "--sql", "s.sql", "--out", "mods", "--dry-run", "--force" };
    const r = parseOrmCli(&a);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqualStrings("s.sql", r.ok.sql_path.?);
    try std.testing.expectEqualStrings("mods", r.ok.out_dir);
    try std.testing.expect(r.ok.opts.dry_run);
    try std.testing.expect(r.ok.opts.force);
}

test "parseOrmCli: unknown flag" {
    const a = [_][]const u8{ "--sql", "s.sql", "--bogus" };
    const r = parseOrmCli(&a);
    try std.testing.expect(r == .err_unknown_flag);
    try std.testing.expectEqualStrings("--bogus", r.err_unknown_flag);
}

test "parseOrmCli: backend and module" {
    const a = [_][]const u8{ "--sql", "x.sql", "--backend", "zent", "--module", "foo" };
    const r = parseOrmCli(&a);
    try std.testing.expect(r == .ok);
    try std.testing.expectEqualStrings("zent", r.ok.backend);
    try std.testing.expectEqualStrings("foo", r.ok.forced_module.?);
}

test "parseOrmCli: missing value after --sql" {
    const a = [_][]const u8{"--sql"};
    const r = parseOrmCli(&a);
    try std.testing.expect(r == .err_missing_value);
    try std.testing.expectEqualStrings("--sql", r.err_missing_value);
}

test "parseOrmCli: --sql followed by another flag" {
    const a = [_][]const u8{ "--sql", "--dry-run" };
    const r = parseOrmCli(&a);
    try std.testing.expect(r == .err_missing_value);
    try std.testing.expectEqualStrings("--sql", r.err_missing_value);
}

test "parseOrmCli: missing value after --out" {
    const a = [_][]const u8{ "--sql", "a.sql", "--out" };
    const r = parseOrmCli(&a);
    try std.testing.expect(r == .err_missing_value);
    try std.testing.expectEqualStrings("--out", r.err_missing_value);
}

test "parseSqlSchema: no CREATE TABLE yields empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tables = try parseSqlSchema(a, "-- just comments\nSELECT 1;");
    defer {
        for (tables) |t| {
            a.free(t.name);
            for (t.columns) |c| {
                a.free(c.name);
                if (c.comment) |com| a.free(com);
            }
            a.free(t.columns);
        }
        a.free(tables);
    }
    try std.testing.expectEqual(@as(usize, 0), tables.len);
}

test "stripUtf8BomAndTrimSql" {
    const bom = "\xEF\xBB\xBF";
    const s = bom ++ "  \nCREATE TABLE t (id INT);\n  ";
    const t = stripUtf8BomAndTrimSql(s);
    try std.testing.expect(std.mem.startsWith(u8, t, "CREATE TABLE"));
}

test "pathContainsDotDot" {
    try std.testing.expect(pathContainsDotDot("src/../mods"));
    try std.testing.expect(pathContainsDotDot("..\\x"));
    try std.testing.expect(!pathContainsDotDot("src/modules"));
    try std.testing.expect(!pathContainsDotDot("foo..bar"));
}

test "isSafeModuleDirName" {
    try std.testing.expect(isSafeModuleDirName("user"));
    try std.testing.expect(!isSafeModuleDirName("a/b"));
    try std.testing.expect(!isSafeModuleDirName(".."));
    try std.testing.expect(!isSafeModuleDirName(""));
}

