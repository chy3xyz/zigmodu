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
    help,
    version,
};

const Config = struct {
    project_name: []const u8 = "",
    module_name: []const u8 = "",
    template_dir: []const u8 = "templates",
    output_dir: []const u8 = ".",
};

const GenOptions = struct {
    dry_run: bool = false,
    force: bool = false,
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
        std.mem.eql(u8, token, "--dry-run") or
        std.mem.eql(u8, token, "--force");
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
        \\  orm             Generate ORM models and repositories from SQL
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
        \\  zmodu orm --sql schema.sql --out src/modules --dry-run
        \\  (--out must not contain '..'; --module is one name, no '/' or '\\')
        \\  zmodu generate module --sql schema.sql --out src/modules
        \\  zmodu generate orm --sql schema.sql --out src/modules --force
        \\
        \\Flags (where supported):
        \\  --dry-run   Preview writes / mkdir; no files created
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
    _ = project_name;

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
    try buf.appendSlice(allocator, "    const exe = b.addExecutable(.{ \n");
    try buf.appendSlice(allocator, "        .name = \"app\",\n");
    try buf.appendSlice(allocator, "        .root_module = exe_mod,\n");
    try buf.appendSlice(allocator, "    });\n");
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
    return generateModuleZig(allocator, module_name);
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

    const template =
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const Server = zigmodu.http_server.Server;
        \\const RouteGroup = Server.RouteGroup;
        \\const Context = Server.Context;
        \\
        \\pub const {s}Api = struct {{
        \\    pub fn init(group: *RouteGroup) !void {{
        \\        try group.get("/{s}s", list, null);
        \\        try group.get("/{s}s/{{id}}", get, null);
        \\        try group.post("/{s}s", create, null);
        \\        try group.put("/{s}s/{{id}}", update, null);
        \\        try group.delete("/{s}s/{{id}}", delete_, null);
        \\    }}
        \\
        \\    fn list(ctx: *Context) !void {{
        \\        try ctx.json(200, "{{\"message\": \"GET /{s}s\"}}");
        \\    }}
        \\
        \\    fn get(ctx: *Context) !void {{
        \\        const id = ctx.params.get("id") orelse return error.BadRequest;
        \\        try ctx.jsonStruct(200, .{{ .id = id }});
        \\    }}
        \\
        \\    fn create(ctx: *Context) !void {{
        \\        _ = ctx;
        \\        try ctx.json(201, "{{\"message\": \"CREATE /{s}s\"}}");
        \\    }}
        \\
        \\    fn update(ctx: *Context) !void {{
        \\        _ = ctx;
        \\        try ctx.json(200, "{{\"message\": \"UPDATE /{s}s\"}}");
        \\    }}
        \\
        \\    fn delete_(ctx: *Context) !void {{
        \\        _ = ctx;
        \\        try ctx.json(204, "");
        \\    }}
        \\}};
        \\
    ;

    return try std.fmt.allocPrint(allocator, template, .{
        struct_name, api_name, api_name, api_name, api_name, api_name,
        api_name, api_name, api_name,
    });
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

const TableDef = struct {
    name: []const u8,
    columns: []ColumnDef,
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

fn generateModuleApi(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef) ![]const u8 {
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

        try buf.print(allocator, "        try group.get(\"/{s}s\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, list_fn });
        try buf.print(allocator, "        try group.get(\"/{s}s/:id\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, get_fn });
        try buf.print(allocator, "        try group.post(\"/{s}s\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, create_fn });
        try buf.print(allocator, "        try group.put(\"/{s}s/:id\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, update_fn });
        try buf.print(allocator, "        try group.delete(\"/{s}s/:id\", {s}, @ptrCast(@alignCast(self)));\n", .{ snake_name, delete_fn });
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

        try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Server.Context) !void {{\n", .{list_fn});
        try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data.?));\n", .{pascal_module});
        try buf.appendSlice(allocator, "        const page_str = ctx.query.get(\"page\") orelse \"0\";\n");
        try buf.appendSlice(allocator, "        const size_str = ctx.query.get(\"size\") orelse \"10\";\n");
        try buf.appendSlice(allocator, "        const page = std.fmt.parseInt(usize, page_str, 10) catch {\n");
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"invalid page\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.appendSlice(allocator, "        const size = std.fmt.parseInt(usize, size_str, 10) catch {\n");
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"invalid size\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.print(allocator, "        const result = try self.service.{s}(page, size);\n", .{list_fn});
        try buf.appendSlice(allocator, "        try ctx.jsonStruct(200, result);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Server.Context) !void {{\n", .{get_fn});
        try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data.?));\n", .{pascal_module});
        try buf.appendSlice(allocator, "        const id_str = ctx.params.get(\"id\") orelse {\n");
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"missing id\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.appendSlice(allocator, "        const id = std.fmt.parseInt(i64, id_str, 10) catch {\n");
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"invalid id\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.print(allocator, "        const item = try self.service.{s}(id);\n", .{get_fn});
        try buf.appendSlice(allocator, "        if (item) |v| {\n");
        try buf.appendSlice(allocator, "            try ctx.jsonStruct(200, v);\n");
        try buf.appendSlice(allocator, "        } else {\n");
        try buf.appendSlice(allocator, "            try ctx.sendError(404, \"not found\");\n");
        try buf.appendSlice(allocator, "        }\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Server.Context) !void {{\n", .{create_fn});
        try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data.?));\n", .{pascal_module});
        try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{\n", .{model_name});
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"invalid json body\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.print(allocator, "        const created = try self.service.{s}(entity);\n", .{create_fn});
        try buf.appendSlice(allocator, "        try ctx.jsonStruct(201, created);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Server.Context) !void {{\n", .{update_fn});
        try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data.?));\n", .{pascal_module});
        try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{\n", .{model_name});
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"invalid json body\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.print(allocator, "        try self.service.{s}(entity);\n", .{update_fn});
        try buf.appendSlice(allocator, "        try ctx.jsonStruct(200, entity);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    fn {s}(ctx: *zigmodu.http_server.Server.Context) !void {{\n", .{delete_fn});
        try buf.print(allocator, "        const self: *{s}Api = @ptrCast(@alignCast(ctx.user_data.?));\n", .{pascal_module});
        try buf.appendSlice(allocator, "        const id_str = ctx.params.get(\"id\") orelse {\n");
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"missing id\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.appendSlice(allocator, "        const id = std.fmt.parseInt(i64, id_str, 10) catch {\n");
        try buf.appendSlice(allocator, "            try ctx.sendError(400, \"invalid id\");\n");
        try buf.appendSlice(allocator, "            return;\n");
        try buf.appendSlice(allocator, "        };\n");
        try buf.print(allocator, "        try self.service.{s}(id);\n", .{delete_fn});
        try buf.appendSlice(allocator, "        try ctx.json(204, \"\");\n");
        try buf.appendSlice(allocator, "    }\n\n");
    }

    try buf.appendSlice(allocator, orm_tpl.sqlx_api_footer);
    return buf.toOwnedSlice(allocator);
}

fn generateModuleZig(allocator: std.mem.Allocator, module_name: []const u8) ![]const u8 {
    const pascal = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal);
    return orm_tpl.expandOrm(allocator, orm_tpl.sqlx_module_zig, module_name, pascal);
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

    const service_code = try generateModuleService(allocator, module_name, tables);
    defer allocator.free(service_code);
    const service_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{module_dir});
    defer allocator.free(service_path);
    try writeFileGen(io, service_path, service_code, opts);

    const api_code = try generateModuleApi(allocator, module_name, tables);
    defer allocator.free(api_code);
    const api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{module_dir});
    defer allocator.free(api_path);
    try writeFileGen(io, api_path, api_code, opts);

    const module_code = try generateModuleZig(allocator, module_name);
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

    if (std.mem.eql(u8, backend, "zent")) {
        // zent backend
        if (forced_module) |mod_name| {
            try writeModuleFilesZent(io, allocator, out_dir, mod_name, tables, opts);
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
                    gop.value_ptr.* = std.ArrayList(TableDef).empty;
                } else {
                    allocator.free(mod_name);
                }
                try gop.value_ptr.append(allocator, table);
            }

            try ensureDirGen(io, out_dir, opts);
            var iter = module_map.iterator();
            while (iter.next()) |entry| {
                try writeModuleFilesZent(io, allocator, out_dir, entry.key_ptr.*, entry.value_ptr.items, opts);
            }
        }
        return;
    }

    // Default sqlx backend
    if (forced_module) |mod_name| {
        try writeModuleFiles(io, allocator, out_dir, mod_name, tables, opts);
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
                gop.value_ptr.* = std.ArrayList(TableDef).empty;
            } else {
                allocator.free(mod_name);
            }
            try gop.value_ptr.append(allocator, table);
        }

        try ensureDirGen(io, out_dir, opts);
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            try writeModuleFiles(io, allocator, out_dir, entry.key_ptr.*, entry.value_ptr.items, opts);
        }
    }
}

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
    const table = TableDef{ .name = try a.dupe(u8, "line_item"), .columns = cols[0..] };
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
        .{ .name = try a.dupe(u8, "alpha"), .columns = cols[0..] },
        .{ .name = try a.dupe(u8, "beta"), .columns = cols[0..] },
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
    const table = TableDef{ .name = try a.dupe(u8, "log"), .columns = cols[0..] };
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

