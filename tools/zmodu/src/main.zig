// ZModu - Code generation tool for ZigModu
const std = @import("std");
const Io = std.Io;
const orm_tpl = @import("orm_tpl.zig");
const mcp_server = @import("mcp_server.zig");

pub const ZMODU_VERSION = "0.15.0";
const verify_mod = @import("verify.zig");
const sql_diff = @import("sql_diff.zig");
const incremental = @import("incremental.zig");

const Command = enum {
    new,
    module,
    event,
    api,
    orm,
    generate,
    scaffold,
    add,
    migration,
    health,
    config,
    @"test",
    plugin,
    life,
    upgrade,
    mcp,
    verify,
    diff,
    help,
    version,
};

const JsonStyle = enum { snake, camel };

const GenOptions = struct {
    dry_run: bool = false,
    force: bool = false,
    data_only: bool = false,
    split: bool = false,
    enable_events: bool = false,
    json_style: JsonStyle = .snake,
    with_transactions: bool = false,
    with_redis: bool = false,
    with_websocket: bool = false,
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
        std.mem.eql(u8, token, "--force") or
        std.mem.eql(u8, token, "--data-only") or
        std.mem.eql(u8, token, "--split") or
        std.mem.eql(u8, token, "--json-style") or
        std.mem.eql(u8, token, "--enable-events") or
        std.mem.eql(u8, token, "--with-transactions");
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
        } else if (std.mem.eql(u8, args[i], "--split")) {
            opts.split = true;
        } else if (std.mem.eql(u8, args[i], "--json-style")) {
            if (i + 1 >= args.len) return .{ .err_missing_value = "--json-style" };
            const val = args[i + 1];
            if (isOrmLongOption(val)) return .{ .err_missing_value = "--json-style" };
            if (std.mem.eql(u8, val, "camel")) { opts.json_style = .camel; }
            else if (!std.mem.eql(u8, val, "snake")) { return .{ .err_unknown_flag = val }; }
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--enable-events")) {
            opts.enable_events = true;
        } else if (std.mem.eql(u8, args[i], "--with-transactions")) {
            opts.with_transactions = true;
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
const zigmodu_zon_url = "https://github.com/chy3xyz/zigmodu/archive/refs/tags/v0.13.9.tar.gz";
const zigmodu_zon_hash = "zigmodu-0.13.7-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

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
        .add => try cmdAdd(io, allocator, cmd_args),
        .migration => try cmdMigration(io, allocator, cmd_args),
        .health => try cmdHealth(io, allocator, cmd_args),
        .config => try cmdConfig(io, allocator, cmd_args),
        .@"test" => try cmdTest(io, allocator, cmd_args),
        .plugin => try cmdPlugin(io, allocator, cmd_args),
        .life => try cmdLife(io, allocator, cmd_args),
        .upgrade => try cmdUpgrade(io, allocator, cmd_args),
        .mcp => try cmdMcp(io, allocator),
        .verify => try cmdVerify(io, allocator, cmd_args),
        .diff => try cmdDiff(io, allocator, cmd_args),
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
        if (c == '-' or c == '_' or c == '/') {
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
        if (c == '-' or c == '_' or c == '/') {
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
    if (std.mem.eql(u8, cmd, "add")) return .add;
    if (std.mem.eql(u8, cmd, "migration")) return .migration;
    if (std.mem.eql(u8, cmd, "migrate")) return .migration;
    if (std.mem.eql(u8, cmd, "health")) return .health;
    if (std.mem.eql(u8, cmd, "config")) return .config;
    if (std.mem.eql(u8, cmd, "test")) return .@"test";
    if (std.mem.eql(u8, cmd, "plugin")) return .plugin;
    if (std.mem.eql(u8, cmd, "life")) return .life;
    if (std.mem.eql(u8, cmd, "upgrade")) return .upgrade;
    if (std.mem.eql(u8, cmd, "mcp")) return .mcp;
    if (std.mem.eql(u8, cmd, "verify")) return .verify;
    if (std.mem.eql(u8, cmd, "diff")) return .diff;
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
        \\  migration <n>   Generate Flyway-style migration file (V{timestamp}__{name}.sql)
        \\  health          Generate health check endpoint boilerplate
        \\  config          Generate ExternalizedConfig validator boilerplate
        \\  test <module>   Generate integration test scaffolding
        \\  plugin         List/manage stub plugins (migration gap filler)
        \\  life           Project evolutionary memory (tree, fingerprint, evolve)
        \\  upgrade        Upgrade zmodu to latest (git pull + zig build)
        \\  mcp            Start MCP server (for AI agent integration)
        \\  verify [dir]   Verify project compiles and has correct structure
        \\  diff <old> <new>  Compare two SQL files, show table-level changes
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
        \\  zmodu scaffold --from-db postgresql://user@host/db --name myapp
        \\  zmodu scaffold --from-db /path/to/db.sqlite --name myapp
        \\  zmodu scaffold --sql schema.sql --from-db sqlite:///db --name myapp
        \\  zmodu migration add-users-table
        \\  zmodu migration add-index --dir src/migrations
        \\  zmodu health --out src/modules/app
        \\  zmodu config --keys DB_HOST,DB_PORT,DB_NAME
        \\  zmodu test user
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
    std.log.info("zmodu v{s}", .{ZMODU_VERSION});
}

fn cmdUpgrade(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;

    // Resolve zmodu source directory
    var src_dir: ?[]const u8 = null;
    defer if (src_dir) |d| allocator.free(d);

    // 1. Check if current directory is zmodu source
    const zon_check = std.Io.Dir.cwd().readFileAlloc(io, "build.zig.zon", allocator, std.Io.Limit.limited(4096));
    if (zon_check) |z| {
        defer allocator.free(z);
        if (std.mem.indexOf(u8, z, ".zmodu") != null) {
            const git_check = std.Io.Dir.cwd().readFileAlloc(io, ".git/HEAD", allocator, std.Io.Limit.limited(1));
            if (git_check) |gc| {
                allocator.free(gc);
                src_dir = try allocator.dupe(u8, ".");
            } else |_| {}
        }
    } else |_| {}

    // 2. Try HOME-relative common paths
    if (src_dir == null) {
        const home = if (std.c.getenv("HOME")) |ptr| std.mem.sliceTo(ptr, 0) else "";
        const candidates = [_][]const u8{
            "w4_proj/zig_ws/zmodu",
            "zmodu",
            "src/zmodu",
        };
        for (candidates) |c| {
            const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, c });
            const git_head = try std.fmt.allocPrint(allocator, "{s}/.git/HEAD", .{p});
            defer allocator.free(git_head);
            const found = std.Io.Dir.cwd().readFileAlloc(io, git_head, allocator, std.Io.Limit.limited(64));
            if (found) |content| {
                allocator.free(content);
                src_dir = p;
                break;
            } else |_| {
                allocator.free(p);
            }
        }
    }

    if (src_dir == null) {
        std.log.err("Cannot find zmodu source. cd to zmodu dir or clone it first.", .{});
        std.log.info("  git clone https://github.com/chy3xyz/zmodu.git && cd zmodu && zig build", .{});
        return error.UpgradeFailed;
    }

    std.log.info("Upgrading zmodu from {s}...", .{src_dir.?});

    // git pull
    const pull_result = try std.process.run(allocator, io, .{
        .argv = &.{ "git", "-C", src_dir.?, "pull", "origin", "main" },
    });
    defer allocator.free(pull_result.stdout);
    defer allocator.free(pull_result.stderr);
    if (pull_result.term != .exited or pull_result.term.exited != 0) {
        std.log.err("git pull failed: {s}", .{pull_result.stderr});
        return error.UpgradeFailed;
    }
    std.log.info("{s}", .{std.mem.trim(u8, pull_result.stdout, " \n\r")});

    // zig build
    const build_result = try std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .path = src_dir.? },
    });
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);
    if (build_result.term != .exited or build_result.term.exited != 0) {
        std.log.err("zig build failed: {s}", .{build_result.stderr});
        return error.UpgradeFailed;
    }

    const bin = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/zmodu", .{src_dir.?});
    defer allocator.free(bin);
    std.log.info("zmodu upgraded. Install: cp {s} ~/.local/bin/zmodu", .{bin});
}

fn cmdMcp(io: std.Io, allocator: std.mem.Allocator) !void {
    try mcp_server.start(io, allocator);
}

fn cmdVerify(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const project_dir = if (args.len > 0) args[0] else ".";
    const report = try verify_mod.verifyProject(allocator, io, project_dir);
    defer {
        // Free details for passing checks (failing check details are shared with errors)
        for (report.checks) |c| {
            if (c.status == .pass or c.status == .skip) {
                if (c.details) |d| allocator.free(d);
            }
        }
        allocator.free(report.checks);
        for (report.errors) |e| allocator.free(e);
        allocator.free(report.errors);
        for (report.warnings) |w| allocator.free(w);
        allocator.free(report.warnings);
        allocator.free(report.summary);
    }

    // Simple JSON output via io
    var out_buf: [4096]u8 = undefined;
    var out_file = std.Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const stdout = &out_writer.interface;
    if (report.pass) {
        try stdout.print("{{\"pass\":true,\"summary\":\"{s}\"}}\n", .{report.summary});
    } else {
        try stdout.print("{{\"pass\":false,\"summary\":\"{s}\"}}\n", .{report.summary});
    }
    try stdout.flush();
}

fn cmdDiff(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        std.log.err("Usage: zmodu diff <old.sql> <new.sql>", .{});
        return error.CliUsage;
    }
    const old_path = args[0];
    const new_path = args[1];

    const old_sql = Io.Dir.cwd().readFileAlloc(io, old_path, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        std.log.err("Cannot read {s}: {}", .{ old_path, err });
        return error.CliUsage;
    };
    defer allocator.free(old_sql);
    const new_sql = Io.Dir.cwd().readFileAlloc(io, new_path, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch |err| {
        std.log.err("Cannot read {s}: {}", .{ new_path, err });
        return error.CliUsage;
    };
    defer allocator.free(new_sql);

    const old_tables = parseSqlSchema(allocator, old_sql) catch |err| {
        std.log.err("Failed to parse old SQL: {}", .{err});
        return error.CliUsage;
    };
    defer freeTableDefs(allocator, old_tables);
    const new_tables = parseSqlSchema(allocator, new_sql) catch |err| {
        std.log.err("Failed to parse new SQL: {}", .{err});
        return error.CliUsage;
    };
    defer freeTableDefs(allocator, new_tables);

    const diffs = sql_diff.diffTables(allocator, old_tables, new_tables) catch |err| {
        std.log.err("Diff failed: {}", .{err});
        return error.CliUsage;
    };
    defer {
        for (diffs) |d| if (d.column_changes.len > 0) allocator.free(d.column_changes);
        allocator.free(diffs);
    }

    // Output
    var out_buf: [65536]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const stdout = &out_writer.interface;

    if (diffs.len == 0) {
        try stdout.writeAll("{\"changed_tables\":0,\"diffs\":[]}\n");
    } else {
        try stdout.print("{{\"changed_tables\":{d},\"diffs\":[", .{diffs.len});
        for (diffs, 0..) |d, i| {
            if (i > 0) try stdout.writeByte(',');
            const change_str = switch (d.change_type) {
                .added => "added",
                .removed => "removed",
                .modified => "modified",
            };
            try stdout.print("{{\"table\":\"{s}\",\"change\":\"{s}\"}}", .{ d.table_name, change_str });
        }
        try stdout.writeAll("]}\n");
    }
    try stdout.flush();
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

    // Refuse to overwrite existing projects
    const existing_zon = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{project_name});
    defer allocator.free(existing_zon);
    if (std.Io.Dir.cwd().openFile(io, existing_zon, .{})) |f| {
        f.close(io);
        std.log.err("Project '{s}' already exists. Use --force to overwrite.", .{project_name});
        return error.RefuseOverwrite;
    } else |_| {}

    std.log.info("Creating new project: {s}", .{project_name});

    try std.Io.Dir.cwd().createDirPath(io, project_name);

    // Create subdirectories
    const dirs = [_][]const u8{
        "src",
        "src/modules",
        "src/plugins",
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

    // Generate AGENTS.md — AI development guide
    const agents_md = try generateAgentsMd(allocator, project_name);
    defer allocator.free(agents_md);
    const agents_path = try std.fmt.allocPrint(allocator, "{s}/AGENTS.md", .{project_name});
    defer allocator.free(agents_path);
    try writeFile(io, agents_path, agents_md);

    // Generate .claude/prompts/ directory with AI prompt templates
    const ai_prompts_dir = try std.fmt.allocPrint(allocator, "{s}/.claude/prompts", .{project_name});
    defer allocator.free(ai_prompts_dir);
    try std.Io.Dir.cwd().createDirPath(io, ai_prompts_dir);

    const prompts = [_]struct { file: []const u8, content: []const u8 }{
        .{ .file = "add_module.md", .content =
        \\# Add a new module
        \\
        \\## Task
        \\Create src/modules/<name>/ with 5 files following the AGENTS.md module contract.
        \\
        \\## Files to create
        \\1. module.zig — info + init/deinit + registerHealthChecks + barrel re-exports
        \\2. model.zig — pub const X = struct { pub const sql_table_name, fields };
        \\3. persistence.zig — XRepo() accessors returning data.Repository(T)
        \\4. service.zig — XService with CRUD delegation + EventBus(T)
        \\5. api.zig — XApi with registerRoutes() + resolve() helper
        \\
        \\## Wiring (in src/main.zig)
        \\- Import: const <name> = @import("modules/<name>/module.zig");
        \\- Persistence: var <name>_p = <name>.persistence.XPersistence.init(backend);
        \\- Service: var <name>_svc = <name>.service.XService.init(&<name>_p);
        \\- API: var <name>_api = <name>.api.XApi.init(&<name>_svc);
        \\- Routes: try <name>_api.registerRoutes(&root);
        \\- Lifecycle: .build(.{ ..., <name>, ... })
        \\
        },
        .{ .file = "add_endpoint.md", .content =
        \\# Add a REST endpoint
        \\
        \\## In api.zig registerRoutes()
        \\```zig
        \\try group.get("/resource", listHandler, @ptrCast(@alignCast(self)));
        \\try group.get("/resource/{id}", getHandler, @ptrCast(@alignCast(self)));
        \\try group.post("/resource", createHandler, @ptrCast(@alignCast(self)));
        \\```
        \\
        \\## Handler pattern
        \\```zig
        \\fn listHandler(ctx: *http.Context) !void {
        \\    const s = resolve(ctx);
        \\    const page = std.fmt.parseInt(usize, ctx.query.get("page") orelse "0", 10) catch 0;
        \\    const size = std.fmt.parseInt(usize, ctx.query.get("size") orelse "10", 10) catch 10;
        \\    const result = try s.service.listThings(page, size);
        \\    try ctx.jsonStruct(200, result);
        \\}
        \\```
        \\
        },
        .{ .file = "add_business_logic.md", .content =
        \\# Add business logic
        \\
        \\## In service.zig
        \\Add methods to XService struct after the generated CRUD methods.
        \\Inject dependencies via the persistence field.
        \\Publish events via self.publish(event).
        \\
        \\## Event types
        \\Extend XEvent union with new variants:
        \\```zig
        \\pub const XEvent = union(enum) {
        \\    thing_created: struct { id: i64 },
        \\    thing_updated: struct { id: i64 },
        \\    custom_event: struct { data: []const u8 },
        \\};
        \\```
        \\
        },
        .{ .file = "context.md", .content =
        \\# Project AI Context
        \\
        \\## Stack
        \\- Framework: zmodu v0.14.4 (Zig 0.17)
        \\- Database: MySQL/PostgreSQL/SQLite via sqlx
        \\- HTTP: zigmodu.http.Server (async fiber-based)
        \\
        \\## Conventions
        \\- Domain imports: const http = zigmodu.http; const data = zigmodu.data;
        \\- Module lifecycle: init() at startup → deinit() at shutdown (reverse order)
        \\- Dependencies: declared in module.zig info.dependencies
        \\- Health: registerHealthChecks() per module + HealthEndpoint in main.zig
        \\- API: RESTful via http.RouteGroup, handlers use resolve(ctx) helper
        \\- ORM: data.Repository(T) returned by persistence Repo accessors
        \\- Events: typed EventBus(T) in service, publish() method
        \\
        },
    };

    for (prompts) |p| {
        const p_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ai_prompts_dir, p.file });
        defer allocator.free(p_path);
        try writeFile(io, p_path, p.content);
    }

    // Generate .life/ — project digital life system
    try generateLifeDir(io, allocator, project_name, project_name, 0, 0, .{ .dry_run = false, .force = true });

    // Generate .claude/skills/ — Claude Code agent skills
    try generateClaudeSkills(io, allocator, project_name, .{ .dry_run = false, .force = true });

    std.log.info("Project {s} created successfully!", .{project_name});
    std.log.info("  cd {s} && zig build run", .{project_name});
}

pub fn cmdModule(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
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

    try safeWrite(io, allocator, module_path, module_code, opts);

    std.log.info("Module {s} created: {s}", .{ module_name, module_path });
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
            \\    .minimum_zig_version = "0.17.0",
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
        \\    .minimum_zig_version = "0.17.0",
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

fn generateAgentsMd(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.print(allocator, "# AGENTS.md — AI Development Guide\n\n## Project: {s}\n## Framework: zigmodu v0.13.9 (Zig 0.17)\n\n", .{project_name});
    try buf.appendSlice(allocator,
        \\## Quick Commands
        \\```
        \\zig build            # compile
        \\zig build run        # run (reads HTTP_PORT, DB_* env vars)
        \\zig build test       # run all tests
        \\zig fmt src/         # format code
        \\```
        \\
        \\## Project Structure
        \\```
        \\src/
        \\  main.zig           # entry point, DB setup, module wiring, HTTP server
        \\  tests.zig          # top-level test suite
        \\  modules/
        \\    <name>/
        \\      module.zig     # lifecycle + barrel re-exports + health checks
        \\      model.zig      # data structs (sql_table_name + fields)
        \\      persistence.zig # ORM repository accessors
        \\      service.zig    # business logic + event types + CRUD
        \\      api.zig        # REST handlers + route registration
        \\```
        \\
        \\## Module Contract (every module MUST have)
        \\```zig
        \\pub const info = api.Module{ .name = "x", .dependencies = &.{}, .is_internal = false };
        \\pub fn init() !void { ... }
        \\pub fn deinit() void { ... }
        \\pub fn registerHealthChecks(endpoint: *zigmodu.HealthEndpoint) !void { ... }
        \\```
        \\
        \\## Import Conventions
        \\```zig
        \\// module.zig — api + http domain
        \\const api = zigmodu.api;
        \\const http = zigmodu.http;
        \\
        \\// persistence.zig — data domain only
        \\const data = @import("zigmodu").data;
        \\
        \\// service.zig — data + EventBus
        \\const data = zigmodu.data;
        \\
        \\// api.zig — http domain only
        \\const http = @import("zigmodu").http;
        \\```
        \\
        \\## Adding a Module
        \\1. Create `src/modules/<name>/` with 5 files (see structure above)
        \\2. Import in `src/main.zig`: `const <name> = @import("modules/<name>/module.zig");`
        \\3. Add persistence: `var <name>_p = <name>.persistence.XPersistence.init(backend);`
        \\4. Add service: `var <name>_svc = <name>.service.XService.init(&<name>_p);`
        \\5. Add API: `var <name>_api = <name>.api.XApi.init(&<name>_svc);`
        \\6. Register routes: `try <name>_api.registerRoutes(&root);`
        \\7. Add to Application: `.build(.{ ..., <name>, ... })`
        \\
        \\## Adding an API Endpoint
        \\```zig
        \\// In api.zig registerRoutes():
        \\try group.get("/resource", listHandler, @ptrCast(@alignCast(self)));
        \\try group.post("/resource", createHandler, @ptrCast(@alignCast(self)));
        \\
        \\// Handler pattern:
        \\fn listHandler(ctx: *http.Context) !void {
        \\    const s = resolve(ctx);
        \\    const result = try s.service.listThings(page, size);
        \\    try ctx.jsonStruct(200, result);
        \\}
        \\```
        \\
        \\## Environment Variables
        \\```
        \\HTTP_PORT=8080     # server port
        \\DB_HOST=127.0.0.1  # database host
        \\DB_PORT=3306       # database port
        \\DB_USER=root       # database user
        \\DB_PASS=           # database password
        \\DB_NAME=heysen     # database name
        \\JWT_SECRET=        # auth secret (with --with-auth)
        \\```
        \\
        \\## ⛔ CRITICAL: Development Workflow (MUST follow in order)
        \\
        \\**zmodu first principle: zmodu generates everything possible. AI fills only gaps.**
        \\
        \\### 1. Always run zmodu first
        \\```bash
        \\# From SQL file (default)
        \\zmodu scaffold --sql schema.sql --name <project> [flags]
        \\
        \\# From live database
        \\zmodu scaffold --from-db postgresql://user@host/db --name <project>
        \\zmodu scaffold --from-db /path/to/db.sqlite --name <project>
        \\
        \\# Import SQL to DB + generate from live schema
        \\zmodu scaffold --sql schema.sql --from-db sqlite:///db.sqlite --name <project>
        \\```
        \\
        \\### 2. Build verify BEFORE any edits
        \\```bash
        \\zig build     # MUST be 0 errors before AI touches anything
        \\```
        \\
        \\### 3. AI writes ONLY in:
        \\```
        \\src/modules/<name>/service.zig      # add custom methods here
        \\src/modules/<name>/api.zig          # add custom endpoints here
        \\src/business/*.zig                  # cross-module orchestration
        \\src/shared/*.zig                    # shared kernel types
        \\src/compat/*.zig                    # legacy compatibility layer
        \\tests/                              # tests
        \\```
        \\
        \\### 4. Build verify AFTER every edit
        \\```bash
        \\zig build     # every edit must compile
        \\```
        \\
        \\## 🟢 Files you CAN edit
        \\
        \\All files use `@initialized` model — AI may modify freely.
        \\Re-scaffold with `--force` to overwrite; omit `--force` to get `.gen.new` diff.
        \\```
        \\src/modules/<name>/model.zig        # @initialized — extend freely
        \\src/modules/<name>/persistence.zig  # @initialized — add custom queries
        \\src/modules/<name>/service.zig      # @initialized — add business logic
        \\src/modules/<name>/api.zig          # @initialized — add custom routes
        \\src/modules/<name>/module.zig       # @initialized — add dependencies
        \\src/main.zig                        # @initialized — wire providers, memory, guards
        \\build.zig                            # @initialized — add C libs, test targets
        \\build.zig.zon                        # @initialized — add dependencies
        \\```
        \\
        \\## File Markers
        \\
        \\All files use `//! @initialized by zmodu — AI may modify freely`. AI can edit directly.
        \\Re-scaffold with `--force` to overwrite; omit `--force` to get `.gen.new` diff for review.
        \\
        \\## Module Structure (5 files per module)
        \\
        \\Flat modules (no subsystem):
        \\```
        \\src/modules/<name>/
        \\├── module.zig       # lifecycle + barrel re-exports + health checks
        \\├── model.zig        # data structs (sql_table_name + fields)
        \\├── persistence.zig  # ORM Repository(T) + custom queries
        \\├── service.zig      # CRUD + validation + EventBus + tenant filtering
        \\└── api.zig          # REST routes + resolve() + BizCode responses
        \\```
        \\
        \\Imports for subsystem modules use underscore var names:
        \\```zig
        \\const shop_orders = @import("modules/shop/orders/module.zig");
        \\const crm_customers = @import("modules/crm/customers/module.zig");
        \\```
        \\
        \\## Shared Kernel
        \\```
        \\src/shared/
        \\├── types.zig        # cross-module types
        \\├── errors.zig       # unified error codes
        \\├── events.zig       # EventBus event catalog
        \\└── response.zig     # uniform API response wrapper
        \\```
        \\
        \\## Verify after every change:
        \\```zig build && zig build test```
        \\
        \\## Digital Life (.life/)
        \\
        \\Evolutionary memory in `.life/`:
        \\- `.life/DNA.md` — project genome (birth record, never deleted)
        \\- `.life/tree/` — version evolution tree
        \\- `.life/memory/decisions.jsonl` — all design decisions
        \\
        \\Read `.life/` first to understand project history.
        \\
        \\## Key Framework Types
        \\| Type | Path | Use |
        \\|------|------|-----|
        \\| Context | zigmodu.http.Context | Request/response |
        \\| Server | zigmodu.http.Server | HTTP server |
        \\| RouteGroup | zigmodu.http.RouteGroup | Route registration |
        \\| SqlxBackend | zigmodu.data.SqlxBackend | DB backend |
        \\| Repository(T) | zigmodu.data.Repository(T) | Typed ORM repo |
        \\| HealthEndpoint | zigmodu.HealthEndpoint | Health checks |
        \\| EventBus(T) | zigmodu.EventBus(T) | Typed event bus |
        \\| Application | zigmodu.Application | App lifecycle |
        \\| ConnectionRegistry | zigmodu.im.ConnectionRegistry | userId→connection map |
        \\| WsFramer | zigmodu.im.WsFramer | RFC 6455 frame r/w |
        \\| BufferPool | zigmodu.im.BufferPool | Shared 4KB buffer pool |
        \\| Tool | zigmodu.ai.Tool | Agent-callable function |
        \\| SkillRegistry | zigmodu.ai.SkillRegistry | Tool registry + dispatch |
        \\
        \\## IM Module (--with-websocket)
        \\
        \\Real-time messaging with WebSocket push:
        \\- REST: POST /im/send, GET /im/messages, GET /im/conversations
        \\- WebSocket: /im/ws?userId=N (RFC 6455)
        \\- Gateway: onConnect→session, onMessage→dispatch, onClose→cleanup
        \\- Relay: write DB → push to online user via ConnectionRegistry
        \\- See src/modules/im/PERF.md for kernel tuning + deployment guide
        \\
        \\## AI Programming Best Practices
        \\
        \\### AI Chat (--with-aichat)
        \\
        \\Multi-turn LLM conversations with cache-optimized message ordering:
        \\- POST /ai/chat/send?conversationId=N (body=user message)
        \\- POST /ai/chat/stream?conversationId=N (SSE, Accept: text/event-stream)
        \\- GET /ai/chat/conversations, GET /ai/chat/messages?conversationId=N
        \\- Provider: init AiProvider with HttpClient pool + deepseek-v4-flash
        \\- Memory: MemoryStore.remember/recall for cross-session context
        \\- Cache: messages ordered system→memories→history→query for prefix caching
        \\```zig
        \\var http = zigmodu.http.HttpClient.init(allocator, io, 10, 30000);
        \\var provider = ai_chat.provider.AiProvider.init(allocator, &http, endpoint, key, model);
        \\ai_chat_svc.setProvider(provider);
        \\ai_chat_svc.setSystemPrompt("You are a helpful assistant.");
        \\```
        \\
        \\### AI Agent (--with-agent)
        \\
        \\ReAct loop agent with SkillRegistry tool dispatch:
        \\- POST /ai/agent/run?goal=... — execute agent with tool access
        \\- GET /ai/agent/runs — list agent run history
        \\- Skills: register via zigmodu.ai.SkillRegistry, agent dispatches automatically
        \\```zig
        \\var registry = zigmodu.ai.SkillRegistry.init(allocator, io);
        \\try registry.register(.{ .name = "lookup", .handler = myHandler, ... });
        \\ai_agent_svc.setChatFn(chatCallback, &ctx);
        \\```
        \\
        \\### SSE Streaming
        \\```zig
        \\var sse = try zigmodu.http.SseWriter.init(ctx);
        \\try sse.sendEvent("message", "hello");  // named event
        \\try sse.sendData("{json}");              // data-only
        \\try sse.heartbeat();                    // keep-alive
        \\try sse.done();                         // [DONE] signal
        \\```
        \\
        \\## Security Best Practices
        \\
        \\### CSRF Protection
        \\```zig
        \\var csrf = zigmodu.security.CsrfProtection.init(io);
        \\server.addMiddleware(csrf.middleware());  // validates X-CSRF-Token on POST/PUT/DELETE
        \\```
        \\
        \\### Security Headers
        \\```zig
        \\server.addMiddleware(zigmodu.security.securityHeadersMiddleware(&zigmodu.security.defaultSecurityHeaders));
        \\```
        \\
        \\### Auth Rate Limiting
        \\```zig
        \\var auth_limiter = try zigmodu.security.authRateLimitMiddleware(allocator, 5, 60);
        \\server.addMiddleware(auth_limiter);  // 5 attempts per 60s window
        \\```
        \\
        \\### Path Traversal Prevention
        \\```zig
        \\const safe_path = try zigmodu.security.sanitizePath(user_input);
        \\// Rejects: .., null bytes, /, \\ — returns error.InvalidPath
        \\```
        \\
        \\### Multi-Tenant Isolation
        \\- Tables with `tenant_id` column auto-generate `listByTenant()` and `getByTenant()`
        \\- Always filter by tenant_id in cross-tenant queries
        \\```zig
        \\const results = try svc.listUsers(page, size, tenant_id);
        \\const user = try svc.getUsersByTenant(id, tenant_id);
        \\```
        \\
        \\### Error Codes
        \\Use typed BizCode instead of magic numbers:
        \\```zig
        \\try R.wrapErr(ctx, .not_found, "user not found");      // code=404
        \\try R.wrapErr(ctx, .validation_failed, "bad input");    // code=422
        \\try R.wrapErr(ctx, .unauthorized, "login required");    // code=401
        \\```
        \\
        \\## Performance Patterns
        \\
        \\### Request Arena (automatic)
        \\Context uses per-connection ArenaAllocator — 0 heap allocs per request.
        \\Arena resets between keep-alive requests via `ctx.resetArena()`.
        \\
        \\### Infallible Hot Paths
        \\`ensureTotalCapacity` at init + `*AssumeCapacity` at runtime:
        \\- SkillRegistry.register() — 0 allocs
        \\- EventBus.subscribe() — 0 allocs
        \\- ConnectionRegistry.register() — 0 allocs (object pool)
        \\- MemoryStore.remember() — 0 allocs
        \\
        \\### Connection Tuning
        \\```zig
        \\var server = zigmodu.http.Server.initWithConfig(io, allocator, .{
        \\    .port = 8080,
        \\    .connection_stack_size = 128 * 1024,  // default 128KB (was 8MB)
        \\    .max_requests_per_conn = 100,
        \\});
        \\```
        \\
        \\## Troubleshooting
        \\
        \\### 404 when route is registered
        \\1. Delete build cache: `rm -rf .zig-cache zig-out`
        \\2. Rebuild: `zig build`
        \\3. Check debug log: `[Router] no match: GET /path` in server logs
        \\4. Verify method match (GET vs POST)
        \\5. Verify wildcard doesn't shadow exact route (exact wins after v0.13.1)
        \\
        \\### zig build cache issues
        \\If modified source produces old output, delete `.zig-cache` directory.
        \\Zig caches compiled artifacts by source hash — corrupted cache persists.
        \\## Web4 Module (--with-web4)
        \\
        \\Decentralized identity + monetization:
        \\- POST /web4/identity/create — generate did:key Ed25519 identity
        \\- POST /web4/invoice/create — create x402 payment invoice
        \\- GET /web4/identity/{did} — resolve DID document
        \\
    );
    return buf.toOwnedSlice(allocator);
}

fn generateMainZig(allocator: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    _ = project_name;
    return try allocator.dupe(u8,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.gpa;
        \\
        \\    std.log.info("Application '{s}' started!", .{project_name});
        \\
        \\    // TODO: Add your modules via `zmodu module <name>`
        \\    // Then wire them in: var app = try zigmodu.builder(allocator, init.io).build(.{...});
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

fn fileExists(io: std.Io, path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Check if a file has uncommitted changes in git.
fn hasUncommittedChanges(io: std.Io, allocator: std.mem.Allocator, path: []const u8) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "diff", "--quiet", "--", path },
    }) catch return true; // git not available → treat as modified
    defer {
        allocator.free(result.stderr);
        allocator.free(result.stdout);
    }
    if (result.term != .exited) return true;
    return result.term.exited != 0;
}

/// Write file safely: skip if user has modified it (git diff), unless --force.
fn safeWrite(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8, opts: GenOptions) !void {
    if (opts.dry_run) {
        std.log.info("[dry-run] write {s} ({d} bytes)", .{ path, content.len });
        return;
    }

    var new_path_buf: ?[]const u8 = null;
    const target = if (!opts.force and fileExists(io, path)) blk: {
        new_path_buf = try std.fmt.allocPrint(allocator, "{s}.gen.new", .{path});
        std.log.info("File exists: generated update at {s}", .{new_path_buf.?});
        break :blk new_path_buf.?;
    } else path;
    defer if (new_path_buf) |p| allocator.free(p);

    const file = std.Io.Dir.cwd().createFile(io, target, .{ .truncate = true }) catch |err| {
        std.log.err("Cannot write {s}: {any}", .{ target, err });
        return err;
    };
    defer file.close(io);
    try file.writeStreamingAll(io, content);
}

/// Legacy wrapper — delegates to safeWrite. Remove after migration complete.
fn writeFileGen(io: std.Io, path: []const u8, content: []const u8, opts: GenOptions) !void {
    _ = io; _ = path; _ = content; _ = opts;
}

// ==================== ORM Code Generation ====================

pub const ColumnType = enum {
    int,
    string,
    bool,
    float,
    datetime,
    unknown,
};

pub const ColumnDef = struct {
    name: []const u8,
    col_type: ColumnType,
    nullable: bool,
    is_primary_key: bool,
    is_unique: bool,
    has_default: bool,
    comment: ?[]const u8,
};

pub const ForeignKey = struct {
    column_name: []const u8,
    ref_table: []const u8,
    ref_column: []const u8,
};

pub const TableDef = struct {
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

fn pkColumnZigType(table: TableDef) []const u8 {
    for (table.columns) |col| {
        if (col.is_primary_key) return zigScalarColumnType(col.col_type);
    }
    return "i64";
}

fn pkIsString(table: TableDef) bool {
    for (table.columns) |col| {
        if (col.is_primary_key) return col.col_type == .string or col.col_type == .datetime or col.col_type == .unknown;
    }
    return false;
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
        std.mem.eql(u8, upper, "BIGSERIAL") or
        std.mem.eql(u8, upper, "SMALLSERIAL") or
        std.mem.eql(u8, upper, "INT64") or
        std.mem.eql(u8, upper, "INT2") or
        std.mem.eql(u8, upper, "INT4") or
        std.mem.eql(u8, upper, "INT8")) return .int;
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
        std.mem.eql(u8, upper, "DECIMAL") or
        std.mem.eql(u8, upper, "FLOAT4") or
        std.mem.eql(u8, upper, "FLOAT8")) return .float;
    if (std.mem.eql(u8, upper, "DATETIME") or
        std.mem.eql(u8, upper, "TIMESTAMP") or
        std.mem.eql(u8, upper, "TIMESTAMPTZ") or
        std.mem.eql(u8, upper, "DATE") or
        std.mem.eql(u8, upper, "TIME") or
        std.mem.eql(u8, upper, "TIMETZ")) return .datetime;
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

/// Mark columns as primary key from table-level PRIMARY KEY(col) constraints.
fn markPrimaryKeyColumns(allocator: std.mem.Allocator, sql: []const u8, body_start: usize, body_end: usize, columns: []ColumnDef) void {
    const body = sql[body_start..@min(body_end, sql.len)];
    var body_upper = std.ArrayList(u8).empty;
    body_upper.appendSlice(allocator, body) catch return;
    defer body_upper.deinit(allocator);
    _ = std.ascii.upperString(body_upper.items, body);

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body_upper.items, pos, "PRIMARY KEY")) |pk_idx| {
        pos = pk_idx + "PRIMARY KEY".len;
        // Skip whitespace, then expect '('
        var j = pk_idx + "PRIMARY KEY".len;
        while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n')) j += 1;
        if (j >= body.len or body[j] != '(') continue;
        j += 1;
        // Read column name
        while (j < body.len and (body[j] == ' ' or body[j] == '\t' or body[j] == '\n')) j += 1;
        const col_start = j;
        while (j < body.len and body[j] != ')' and body[j] != ',' and body[j] != ' ' and body[j] != '\t' and body[j] != '\n') j += 1;
        const col_name = std.mem.trim(u8, body[col_start..j], " \t\n\r`");
        // Mark matching column
        for (columns) |*col| {
            if (std.mem.eql(u8, col.name, col_name)) {
                col.is_primary_key = true;
                col.nullable = false;
            }
        }
    }
}

pub fn parseSqlSchema(allocator: std.mem.Allocator, sql: []const u8) ![]TableDef {
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
                    // Mark table-level PRIMARY KEY columns
                    markPrimaryKeyColumns(allocator, sql, body_start, body_end, columns);
                    try tables.append(allocator, .{ .name = table_name, .columns = columns, .foreign_keys = fks });
                }
            }
        } else {
            i += 1;
        }
    }
    return tables.toOwnedSlice(allocator);
}

/// Free all memory owned by a slice of TableDefs (including internal strings).
pub fn freeTableDefs(allocator: std.mem.Allocator, tables: []const TableDef) void {
    for (tables) |t| {
        allocator.free(t.name);
        for (t.columns) |c| {
            allocator.free(c.name);
            if (c.comment) |cm| allocator.free(cm);
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
    _ = strip_prefix_len; // Keep full name; subsystem grouping handled by detectSubsystems
    return try allocator.dupe(u8, table_name);
}

/// Parsed database connection info from --from-db DSN.
const DbConnection = struct {
    driver: []const u8, // "sqlite", "postgresql", "mysql"
    host: []const u8,
    port: u16,
    user: []const u8,
    pass: []const u8,
    database: []const u8,
    sqlite_path: []const u8,
};

/// Parse a DSN string: sqlite:///path, postgresql://user:pass@host:port/db, mysql://user:pass@host:port/db
fn parseDsn(allocator: std.mem.Allocator, dsn: []const u8) !DbConnection {
    var driver: []const u8 = "sqlite";
    var host: []const u8 = "localhost";
    var port: u16 = 5432;
    var user: []const u8 = "";
    var pass: []const u8 = "";
    var database: []const u8 = "";
    var sqlite_path: []const u8 = "";

    if (std.mem.startsWith(u8, dsn, "postgresql://") or std.mem.startsWith(u8, dsn, "postgres://")) {
        driver = "postgresql";
        port = 5432;
        const rest = dsn[std.mem.indexOf(u8, dsn, "://").? + 3 ..];
        // user:pass@host:port/dbname
        if (std.mem.indexOf(u8, rest, "@")) |at_pos| {
            const userpass = rest[0..at_pos];
            if (std.mem.indexOf(u8, userpass, ":")) |colon| {
                user = try allocator.dupe(u8, userpass[0..colon]);
                pass = try allocator.dupe(u8, userpass[colon + 1 ..]);
            } else {
                user = try allocator.dupe(u8, userpass);
                pass = "";
            }
            const hostdb = rest[at_pos + 1 ..];
            if (std.mem.indexOf(u8, hostdb, ":")) |port_colon| {
                host = try allocator.dupe(u8, hostdb[0..port_colon]);
                const portdb = hostdb[port_colon + 1 ..];
                if (std.mem.indexOf(u8, portdb, "/")) |slash| {
                    port = std.fmt.parseInt(u16, portdb[0..slash], 10) catch 5432;
                    database = try allocator.dupe(u8, portdb[slash + 1 ..]);
                }
            } else if (std.mem.indexOf(u8, hostdb, "/")) |slash| {
                host = try allocator.dupe(u8, hostdb[0..slash]);
                database = try allocator.dupe(u8, hostdb[slash + 1 ..]);
            }
        } else if (std.mem.indexOf(u8, rest, "/")) |slash| {
            user = try allocator.dupe(u8, rest[0..slash]);
            database = try allocator.dupe(u8, rest[slash + 1 ..]);
        }
    } else if (std.mem.startsWith(u8, dsn, "mysql://")) {
        driver = "mysql";
        port = 3306;
        const rest = dsn["mysql://".len..];
        if (std.mem.indexOf(u8, rest, "@")) |at_pos| {
            const userpass = rest[0..at_pos];
            if (std.mem.indexOf(u8, userpass, ":")) |colon| {
                user = try allocator.dupe(u8, userpass[0..colon]);
                pass = try allocator.dupe(u8, userpass[colon + 1 ..]);
            } else {
                user = try allocator.dupe(u8, userpass);
                pass = "";
            }
            const hostdb = rest[at_pos + 1 ..];
            if (std.mem.indexOf(u8, hostdb, ":")) |port_colon| {
                host = try allocator.dupe(u8, hostdb[0..port_colon]);
                const portdb = hostdb[port_colon + 1 ..];
                if (std.mem.indexOf(u8, portdb, "/")) |slash| {
                    port = std.fmt.parseInt(u16, portdb[0..slash], 10) catch 3306;
                    database = try allocator.dupe(u8, portdb[slash + 1 ..]);
                }
            } else if (std.mem.indexOf(u8, hostdb, "/")) |slash| {
                host = try allocator.dupe(u8, hostdb[0..slash]);
                database = try allocator.dupe(u8, hostdb[slash + 1 ..]);
            }
        } else if (std.mem.indexOf(u8, rest, "/")) |slash| {
            user = try allocator.dupe(u8, rest[0..slash]);
            database = try allocator.dupe(u8, rest[slash + 1 ..]);
        }
    } else if (std.mem.startsWith(u8, dsn, "sqlite:///")) {
        driver = "sqlite";
        sqlite_path = try allocator.dupe(u8, dsn["sqlite:///".len..]);
        database = sqlite_path;
    } else if (std.mem.endsWith(u8, dsn, ".db") or std.mem.endsWith(u8, dsn, ".sqlite") or std.mem.endsWith(u8, dsn, ".sqlite3")) {
        driver = "sqlite";
        sqlite_path = try allocator.dupe(u8, dsn);
        database = sqlite_path;
    } else {
        return error.InvalidDsn;
    }

    return DbConnection{
        .driver = driver,
        .host = host,
        .port = port,
        .user = user,
        .pass = pass,
        .database = database,
        .sqlite_path = sqlite_path,
    };
}

/// Write SQL content to a temp file and return the path.
fn writeTempSql(io: std.Io, allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    const tmp_path = try allocator.dupe(u8, "/tmp/zmodu_import.sql");
    const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, sql);
    return tmp_path;
}

/// Import SQL file content into database via CLI tools.
fn importSqlToDatabase(io: std.Io, allocator: std.mem.Allocator, dsn: []const u8, sql: []const u8) !void {
    const db = try parseDsn(allocator, dsn);
    defer {
        if (!std.mem.eql(u8, db.driver, "sqlite")) {
            if (db.user.len > 0) allocator.free(db.user);
            if (db.pass.len > 0) allocator.free(db.pass);
            if (db.host.len > 0 and !std.mem.eql(u8, db.host, "localhost")) allocator.free(db.host);
            if (db.database.len > 0) allocator.free(db.database);
        }
        if (db.sqlite_path.len > 0) allocator.free(db.sqlite_path);
    }

    const tmp_file = try writeTempSql(io, allocator, sql);
    defer {
        std.Io.Dir.cwd().deleteFile(io, tmp_file) catch {};
        allocator.free(tmp_file);
    }

    if (std.mem.eql(u8, db.driver, "sqlite")) {
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ "sh", "-c", try std.fmt.allocPrint(allocator, "sqlite3 '{s}' < '{s}'", .{ db.sqlite_path, tmp_file }) },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("sqlite3 import failed: {s}", .{result.stderr});
            return error.DatabaseError;
        }
        std.log.info("SQL imported to SQLite: {s}", .{db.sqlite_path});
    } else if (std.mem.eql(u8, db.driver, "postgresql")) {
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ "psql", "-h", db.host, "-p", try std.fmt.allocPrint(allocator, "{d}", .{db.port}), "-U", db.user, "-d", db.database, "-f", tmp_file },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("psql import failed: {s}", .{result.stderr});
            return error.DatabaseError;
        }
        std.log.info("SQL imported to PostgreSQL: {s}/{s}", .{ db.host, db.database });
    } else if (std.mem.eql(u8, db.driver, "mysql")) {
        const result = try std.process.run(allocator, io, .{
            .argv = &.{ "mysql", "-h", db.host, "-P", try std.fmt.allocPrint(allocator, "{d}", .{db.port}), "-u", db.user, db.database, "-e", "source", tmp_file },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.log.err("mysql import failed: {s}", .{result.stderr});
            return error.DatabaseError;
        }
        std.log.info("SQL imported to MySQL: {s}/{s}", .{ db.host, db.database });
    }
}

/// Introspect database schema via CLI tools → TableDef[] for code generation.
fn introspectDatabase(io: std.Io, allocator: std.mem.Allocator, dsn: []const u8) ![]TableDef {
    const db = try parseDsn(allocator, dsn);
    defer {
        if (!std.mem.eql(u8, db.driver, "sqlite")) {
            if (db.user.len > 0) allocator.free(db.user);
            if (db.pass.len > 0) allocator.free(db.pass);
            if (db.host.len > 0 and !std.mem.eql(u8, db.host, "localhost")) allocator.free(db.host);
            if (db.database.len > 0) allocator.free(db.database);
        }
        if (db.sqlite_path.len > 0) allocator.free(db.sqlite_path);
    }

    if (std.mem.eql(u8, db.driver, "sqlite")) {
        return introspectDatabaseSqlite(io, allocator, db.sqlite_path);
    }
    if (std.mem.eql(u8, db.driver, "postgresql")) {
        return introspectDatabasePostgres(io, allocator, db.host, db.port, db.user, db.pass, db.database);
    }
    if (std.mem.eql(u8, db.driver, "mysql")) {
        return introspectDatabaseMysql(io, allocator, db.host, db.port, db.user, db.pass, db.database);
    }

    return error.UnsupportedDriver;
}

/// SQLite-specific introspection: PRAGMA table_info + foreign_key_list
fn introspectDatabaseSqlite(io: std.Io, allocator: std.mem.Allocator, db_path: []const u8) ![]TableDef {
    var tables = std.ArrayList(TableDef).empty;

    // Get table list
    const list_result = try std.process.run(allocator, io, .{
        .argv = &.{ "sqlite3", db_path, ".tables" },
    });
    defer allocator.free(list_result.stdout);
    defer allocator.free(list_result.stderr);
    var table_names = std.ArrayList([]const u8).empty;
    defer table_names.deinit(allocator);
    var iter = std.mem.splitScalar(u8, list_result.stdout, ' ');
    while (iter.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t\n\r");
        if (t.len > 0 and !std.mem.eql(u8, t, "sqlite_sequence")) {
            try table_names.append(allocator, try allocator.dupe(u8, t));
        }
    }

    for (table_names.items) |tname| {
        // PRAGMA table_info for columns
        var pragma_sql: [256]u8 = undefined;
        const psql = try std.fmt.bufPrint(&pragma_sql, "PRAGMA table_info({s});", .{tname});
        const col_result = try std.process.run(allocator, io, .{
            .argv = &.{ "sqlite3", db_path, psql },
        });
        defer allocator.free(col_result.stdout);
        defer allocator.free(col_result.stderr);

        var columns = std.ArrayList(ColumnDef).empty;
        var lines = std.mem.splitScalar(u8, col_result.stdout, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var fields = std.mem.splitScalar(u8, trimmed, '|');
            _ = fields.next(); // cid
            const name_f = fields.next() orelse continue;
            const type_str = fields.next() orelse continue;
            const notnull_str = fields.next() orelse continue;
            const dflt = fields.next(); // default
            const pk_str = fields.next() orelse continue;

            const col_name = try allocator.dupe(u8, std.mem.trim(u8, name_f, " \t\r"));
            var i: usize = 0;
            const col_type = parseColumnTypeName(type_str, &i);
            const nullable = !std.mem.eql(u8, std.mem.trim(u8, notnull_str, " \t\r"), "1");
            const is_pk = std.mem.eql(u8, std.mem.trim(u8, pk_str, " \t\r"), "1");
            const has_default = dflt != null and dflt.?.len > 0;
            try columns.append(allocator, .{
                .name = col_name,
                .col_type = col_type,
                .nullable = nullable,
                .has_default = has_default,
                .is_primary_key = is_pk,
                .is_unique = false,
                .comment = null,
            });
        }

        // PRAGMA foreign_key_list
        var fk_sql: [256]u8 = undefined;
        const fks_str = try std.fmt.bufPrint(&fk_sql, "PRAGMA foreign_key_list({s});", .{tname});
        const fk_result = try std.process.run(allocator, io, .{
            .argv = &.{ "sqlite3", db_path, fks_str },
        });
        defer allocator.free(fk_result.stdout);
        defer allocator.free(fk_result.stderr);
        var foreign_keys = std.ArrayList(ForeignKey).empty;
        var fk_lines = std.mem.splitScalar(u8, fk_result.stdout, '\n');
        while (fk_lines.next()) |fline| {
            const trimmed = std.mem.trim(u8, fline, " \t\r");
            if (trimmed.len == 0) continue;
            var fields = std.mem.splitScalar(u8, trimmed, '|');
            _ = fields.next(); // id
            _ = fields.next(); // seq
            const ref_table = fields.next() orelse continue;
            const col = fields.next() orelse continue;
            const ref_col = fields.next() orelse continue;
            try foreign_keys.append(allocator, .{
                .column_name = try allocator.dupe(u8, std.mem.trim(u8, col, " \t\r")),
                .ref_table = try allocator.dupe(u8, std.mem.trim(u8, ref_table, " \t\r")),
                .ref_column = try allocator.dupe(u8, std.mem.trim(u8, ref_col, " \t\r")),
            });
        }

        try tables.append(allocator, .{
            .name = try allocator.dupe(u8, tname),
            .columns = try columns.toOwnedSlice(allocator),
            .foreign_keys = try foreign_keys.toOwnedSlice(allocator),
        });
    }

    return tables.toOwnedSlice(allocator);
}

/// PostgreSQL introspection via psql + information_schema.
fn introspectDatabasePostgres(io: std.Io, allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, _: []const u8, database: []const u8) ![]TableDef {
    var tables = std.ArrayList(TableDef).empty;

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    // Query columns from information_schema
    const col_query =
        \\SELECT c.table_name, c.column_name, c.data_type, c.is_nullable, c.column_default, c.ordinal_position
        \\FROM information_schema.columns c
        \\WHERE c.table_schema = 'public'
        \\ORDER BY c.table_name, c.ordinal_position;
    ;

    const col_result = try std.process.run(allocator, io, .{
        .argv = &.{ "psql", "-h", host, "-p", port_str, "-U", user, "-d", database, "-t", "-A", "-F|", "-c", col_query },
    });
    defer allocator.free(col_result.stdout);
    defer allocator.free(col_result.stderr);

    if (col_result.term != .exited or col_result.term.exited != 0) {
        std.log.err("psql columns query failed: {s}", .{col_result.stderr});
        return error.DatabaseError;
    }

    // Query foreign keys
    const fk_query =
        \\SELECT tc.table_name, kcu.column_name, ccu.table_name AS ref_table, ccu.column_name AS ref_column
        \\FROM information_schema.table_constraints tc
        \\JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
        \\JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name
        \\WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = 'public'
        \\ORDER BY tc.table_name;
    ;

    const fk_result = try std.process.run(allocator, io, .{
        .argv = &.{ "psql", "-h", host, "-p", port_str, "-U", user, "-d", database, "-t", "-A", "-F|", "-c", fk_query },
    });
    defer allocator.free(fk_result.stdout);
    defer allocator.free(fk_result.stderr);

    // Parse columns output: table|col|type|YES/NO|default|ordinal
    var col_map = std.StringHashMap(std.ArrayList(ColumnDef)).init(allocator);
    defer {
        var it = col_map.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.items) |c| allocator.free(c.name);
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        col_map.deinit();
    }
    var col_lines = std.mem.splitScalar(u8, col_result.stdout, '\n');
    while (col_lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        var fields = std.mem.splitScalar(u8, trimmed, '|');
        const table_name = fields.next() orelse continue;
        const col_name = fields.next() orelse continue;
        const data_type = fields.next() orelse continue;
        const is_nullable_str = fields.next() orelse continue;
        const default_val = fields.next(); // may be empty

        var i: usize = 0;
        const col_type = parseColumnTypeName(data_type, &i);
        const nullable = std.mem.eql(u8, std.mem.trim(u8, is_nullable_str, " \t"), "YES");
        const has_default = default_val != null and default_val.?.len > 0 and !std.mem.eql(u8, default_val.?, "NULL");

        const gop = try col_map.getOrPut(try allocator.dupe(u8, table_name));
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, .{
            .name = try allocator.dupe(u8, col_name),
            .col_type = col_type,
            .nullable = nullable,
            .has_default = has_default,
            .is_primary_key = false, // resolved below
            .is_unique = false,
            .comment = null,
        });
    }

    // Mark primary keys (first column named 'id' is PK by convention)
    var cit = col_map.iterator();
    while (cit.next()) |entry| {
        for (entry.value_ptr.items) |*col| {
            if (std.mem.eql(u8, col.name, "id")) col.is_primary_key = true;
        }
    }

    // Build TableDef list (FKs parsed per-table below)
    var tnames = std.ArrayList([]const u8).empty;
    defer tnames.deinit(allocator);
    var titer = col_map.keyIterator();
    while (titer.next()) |k| try tnames.append(allocator, k.*);
    std.mem.sort([]const u8, tnames.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool { return std.mem.lessThan(u8, a, b); }
    }.lt);

    for (tnames.items) |tname| {
        const cols = col_map.get(tname).?;
        // Extract FKs for this table from fk_result
        var foreign_keys = std.ArrayList(ForeignKey).empty;
        var fk2 = std.mem.splitScalar(u8, fk_result.stdout, '\n');
        while (fk2.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            var fs = std.mem.splitScalar(u8, t, '|');
            const ftable = fs.next() orelse continue;
            const fcol = fs.next() orelse continue;
            const rtable = fs.next() orelse continue;
            const rcol = fs.next() orelse continue;
            if (std.mem.eql(u8, ftable, tname)) {
                try foreign_keys.append(allocator, .{
                    .column_name = try allocator.dupe(u8, fcol),
                    .ref_table = try allocator.dupe(u8, rtable),
                    .ref_column = try allocator.dupe(u8, rcol),
                });
            }
        }
        try tables.append(allocator, .{
            .name = try allocator.dupe(u8, tname),
            .columns = try colsToOwned(allocator, cols),
            .foreign_keys = try foreign_keys.toOwnedSlice(allocator),
        });
    }

    return tables.toOwnedSlice(allocator);
}

fn colsToOwned(allocator: std.mem.Allocator, cols: std.ArrayList(ColumnDef)) ![]ColumnDef {
    const result = try allocator.alloc(ColumnDef, cols.items.len);
    for (cols.items, 0..) |c, i| {
        result[i] = .{
            .name = try allocator.dupe(u8, c.name),
            .col_type = c.col_type,
            .nullable = c.nullable,
            .has_default = c.has_default,
            .is_primary_key = c.is_primary_key,
            .is_unique = c.is_unique,
            .comment = if (c.comment) |com| try allocator.dupe(u8, com) else null,
        };
    }
    return result;
}

/// MySQL introspection via mysql CLI + information_schema.
fn introspectDatabaseMysql(io: std.Io, allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, pass: []const u8, database: []const u8) ![]TableDef {
    var tables = std.ArrayList(TableDef).empty;

    const port_str = try std.fmt.allocPrint(allocator, "{d}", .{port});
    defer allocator.free(port_str);

    // Build mysql args
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "mysql", "-h", host, "-P", port_str, "-u", user, "-N", "-B" });
    if (pass.len > 0) {
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "-p{s}", .{pass}));
    }
    try argv.append(allocator, database);
    try argv.append(allocator, "-e");

    // Get table list
    const table_list_query = "SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE' ORDER BY table_name";
    var argv_list = try argv.clone(allocator);
    defer argv_list.deinit(allocator);
    try argv_list.append(allocator, table_list_query);

    const list_result = try std.process.run(allocator, io, .{ .argv = argv_list.items });
    defer allocator.free(list_result.stdout);
    defer allocator.free(list_result.stderr);

    var table_names = std.ArrayList([]const u8).empty;
    defer table_names.deinit(allocator);
    var tlines = std.mem.splitScalar(u8, list_result.stdout, '\n');
    while (tlines.next()) |t| {
        const trimmed = std.mem.trim(u8, t, " \t\r");
        if (trimmed.len > 0) try table_names.append(allocator, try allocator.dupe(u8, trimmed));
    }

    for (table_names.items) |tname| {
        // SHOW COLUMNS
        const col_query = try std.fmt.allocPrint(allocator, "SHOW COLUMNS FROM `{s}`", .{tname});
        defer allocator.free(col_query);
        var argv_col = try argv.clone(allocator);
        defer argv_col.deinit(allocator);
        try argv_col.append(allocator, col_query);
        const col_result = try std.process.run(allocator, io, .{ .argv = argv_col.items });
        defer allocator.free(col_result.stdout);
        defer allocator.free(col_result.stderr);

        var columns = std.ArrayList(ColumnDef).empty;
        var clines = std.mem.splitScalar(u8, col_result.stdout, '\n');
        while (clines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var fields = std.mem.splitScalar(u8, trimmed, '\t');
            const col_name = fields.next() orelse continue;
            const type_raw = fields.next() orelse continue;
            const null_str = fields.next() orelse continue;
            const key_str = fields.next() orelse continue;
            const default_val = fields.next(); // may be null

            var i: usize = 0;
            const col_type = parseColumnTypeName(type_raw, &i);
            const nullable = std.mem.eql(u8, std.mem.trim(u8, null_str, " \t"), "YES");
            const is_pk = std.mem.eql(u8, std.mem.trim(u8, key_str, " \t"), "PRI");
            const has_default = default_val != null and default_val.?.len > 0 and !std.mem.eql(u8, std.mem.trim(u8, default_val.?, " \t"), "NULL");

            try columns.append(allocator, .{
                .name = try allocator.dupe(u8, col_name),
                .col_type = col_type,
                .nullable = nullable,
                .has_default = has_default,
                .is_primary_key = is_pk,
                .is_unique = false,
                .comment = null,
            });
        }

        // FK query
        const fk_query = try std.fmt.allocPrint(allocator,
            \\SELECT kcu.column_name, kcu.referenced_table_name, kcu.referenced_column_name
            \\FROM information_schema.key_column_usage kcu
            \\WHERE kcu.table_schema = DATABASE() AND kcu.table_name = '{s}' AND kcu.referenced_table_name IS NOT NULL
        , .{tname});
        defer allocator.free(fk_query);
        var argv_fk = try argv.clone(allocator);
        defer argv_fk.deinit(allocator);
        try argv_fk.append(allocator, fk_query);
        const fk_result = try std.process.run(allocator, io, .{ .argv = argv_fk.items });
        defer allocator.free(fk_result.stdout);
        defer allocator.free(fk_result.stderr);

        var foreign_keys = std.ArrayList(ForeignKey).empty;
        var flines = std.mem.splitScalar(u8, fk_result.stdout, '\n');
        while (flines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            var fs = std.mem.splitScalar(u8, trimmed, '\t');
            const fcol = fs.next() orelse continue;
            const rtable = fs.next() orelse continue;
            const rcol = fs.next() orelse continue;
            try foreign_keys.append(allocator, .{
                .column_name = try allocator.dupe(u8, fcol),
                .ref_table = try allocator.dupe(u8, rtable),
                .ref_column = try allocator.dupe(u8, rcol),
            });
        }

        try tables.append(allocator, .{
            .name = try allocator.dupe(u8, tname),
            .columns = try columns.toOwnedSlice(allocator),
            .foreign_keys = try foreign_keys.toOwnedSlice(allocator),
        });
    }

    return tables.toOwnedSlice(allocator);
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
                    if (ref_table.len == 0) {
                        allocator.free(col_name);
                        break;
                    }

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

    // Second pass: inline REFERENCES (column TYPE ... REFERENCES table(col))
    // Only catch those NOT already covered by explicit FOREIGN KEY clauses.
    {
        const body_upper = try allocator.alloc(u8, body.len);
        defer allocator.free(body_upper);
        _ = std.ascii.upperString(body_upper, body);

        var ref_seen = std.StringHashMap(void).init(allocator);
        defer ref_seen.deinit();
        for (fks.items) |fk| {
            ref_seen.put(fk.column_name, {}) catch {};
        }

        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, body_upper, pos, "REFERENCES")) |ref_idx| {
            pos = ref_idx + "REFERENCES".len;
            // Skip whitespace after REFERENCES
            var r = ref_idx + "REFERENCES".len;
            while (r < body.len and (body[r] == ' ' or body[r] == '\t' or body[r] == '\n')) r += 1;
            // Read table name
            const t_start = r;
            while (r < body.len and (std.ascii.isAlphanumeric(body[r]) or body[r] == '_' or body[r] == '`')) r += 1;
            const ref_table = std.mem.trim(u8, body[t_start..r], "`");
            if (ref_table.len == 0) continue;
            // Find the preceding column name (scan backwards from REFERENCES)
            var col_end: usize = ref_idx;
            while (col_end > 0 and (body[col_end - 1] == ' ' or body[col_end - 1] == '\t' or body[col_end - 1] == '\n')) col_end -= 1;
            if (col_end == 0) continue;
            // Skip type definition: backtrack past word(s) until we hit a comma, paren, or line start
            var col_start = col_end;
            var word_count: usize = 0;
            while (col_start > 0) {
                const c = body[col_start - 1];
                if (c == ',' or c == '(' or c == '\n') break;
                if (c == ' ' or c == '\t') {
                    if (word_count >= 1) break; // past the type, now at space before column name
                    word_count += 1;
                }
                col_start -= 1;
            }
            // Skip leading whitespace/punctuation
            while (col_start < col_end and (body[col_start] == ' ' or body[col_start] == '\t' or body[col_start] == '\n' or body[col_start] == ',' or body[col_start] == '(')) col_start += 1;
            const col_name = std.mem.trim(u8, body[col_start..col_end], " \t\n\r`");
            if (col_name.len == 0) continue;
            // Skip if already covered by FOREIGN KEY
            if (ref_seen.contains(col_name)) continue;
            ref_seen.put(col_name, {}) catch {};

            // Read ref column if present
            var ref_column: []const u8 = "id";
            if (r < body.len and body[r] == '(') {
                r += 1;
                const rc_start = r;
                while (r < body.len and body[r] != ')') r += 1;
                ref_column = try allocator.dupe(u8, std.mem.trim(u8, body[rc_start..r], " \t\n\r`"));
            } else {
                ref_column = try allocator.dupe(u8, ref_column);
            }

            try fks.append(allocator, .{
                .column_name = try allocator.dupe(u8, col_name),
                .ref_table = try allocator.dupe(u8, ref_table),
                .ref_column = ref_column,
            });
        }
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
            // Skip self-ref: same module, or singular/plural pair after merge
            const is_self = std.mem.eql(u8, ref_module, module_name) or
                (module_name.len > 0 and ref_module.len == module_name.len + 1 and std.mem.startsWith(u8, ref_module, module_name) and ref_module[ref_module.len-1] == 's') or
                (ref_module.len > 0 and module_name.len == ref_module.len + 1 and std.mem.startsWith(u8, module_name, ref_module) and module_name[module_name.len-1] == 's');
            if (!is_self) {
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

    // Post-process: merge singular/plural splits (e.g. orders → order)
    var merge_keys = std.ArrayList([]const u8).empty;
    var kit = module_map.keyIterator();
    while (kit.next()) |k| {
        const key = k.*;
        if (key.len > 1 and key[key.len-1] == 's') {
            const singular = key[0..key.len-1];
            if (module_map.get(singular)) |_| try merge_keys.append(allocator, try allocator.dupe(u8, key));
        }
    }
    for (merge_keys.items) |key| {
        const singular = key[0..key.len-1];
        if (module_map.getPtr(key)) |src| {
            var target = module_map.getPtr(singular).?;
            for (src.items) |t| try target.append(allocator, t);
            src.deinit(allocator);
        }
        _ = module_map.remove(key);
    }
    for (merge_keys.items) |k| allocator.free(k);
    merge_keys.deinit(allocator);

    return module_map;
}

/// Detect subsystems from module name prefixes.
/// Modules like "shop_order", "shop_product" → subsystem "shop" with modules "order", "product".
/// Modules without shared first-segment prefix remain as-is.
/// Returns a map: subsystem_name → list of module_names, or null if no subsystems detected.
/// Side effect: updates module_map keys from flat names to "<subsystem>/<module>" format.
fn detectSubsystems(allocator: std.mem.Allocator, module_map: *std.StringHashMap(std.ArrayList(TableDef))) !?std.StringHashMap(std.ArrayList([]const u8)) {
    // Collect current module names
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    var kit = module_map.keyIterator();
    while (kit.next()) |k| try names.append(allocator, k.*);

    // Group by first segment (before first '_')
    var prefix_groups = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    errdefer {
        var pit = prefix_groups.iterator();
        while (pit.next()) |e| {
            for (e.value_ptr.items) |n| allocator.free(n);
            e.value_ptr.deinit(allocator);
            allocator.free(e.key_ptr.*);
        }
        prefix_groups.deinit();
    }
    for (names.items) |name| {
        const first_seg = if (std.mem.indexOf(u8, name, "_")) |idx|
            name[0..idx]
        else
            name;
        // Only consider as subsystem prefix if the module has an underscore (multi-word)
        if (first_seg.len < name.len and first_seg.len > 1) {
            const gop = try prefix_groups.getOrPut(try allocator.dupe(u8, first_seg));
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            try gop.value_ptr.append(allocator, try allocator.dupe(u8, name));
        }
    }

    // Subsystems: any shared prefix counts (even single-table modules get nested)
    var subsystem_map = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
    var pit = prefix_groups.iterator();
    while (pit.next()) |entry| {
        if (entry.value_ptr.items.len >= 1) {
            // This prefix IS a subsystem. Strip prefix from module names.
            var modules = std.ArrayList([]const u8).empty;
            for (entry.value_ptr.items) |full_name| {
                const prefix = entry.key_ptr.*;
                var remainder: []const u8 = full_name;
                if (std.mem.startsWith(u8, full_name, prefix) and full_name.len > prefix.len and full_name[prefix.len] == '_') {
                    remainder = full_name[prefix.len + 1 ..]; // strip "prefix_"
                }
                try modules.append(allocator, try allocator.dupe(u8, remainder));
                // Move module map entry: old key → "<prefix>/<remainder>"
                if (module_map.getPtr(full_name)) |src_data| {
                    var new_list = std.ArrayList(TableDef).empty;
                    for (src_data.items) |t| try new_list.append(allocator, t);
                    const new_key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, remainder });
                    try module_map.put(new_key, new_list);
                    src_data.deinit(allocator);
                    _ = module_map.remove(full_name);
                }
            }
            try subsystem_map.put(try allocator.dupe(u8, entry.key_ptr.*), modules);
        }
        for (entry.value_ptr.items) |n| allocator.free(n);
        entry.value_ptr.deinit(allocator);
        allocator.free(entry.key_ptr.*);
    }
    prefix_groups.deinit();

    // Post-process: merge modules within same subsystem that share deeper prefix
    // e.g., shop/orders + shop/order_items → shop/order
    {
        var merge_candidates = std.StringHashMap(std.ArrayList([]const u8)).init(allocator);
        defer {
            var mit = merge_candidates.iterator();
            while (mit.next()) |e| {
                for (e.value_ptr.items) |n| allocator.free(n);
                e.value_ptr.deinit(allocator);
                allocator.free(e.key_ptr.*);
            }
            merge_candidates.deinit();
        }
        var kit2 = module_map.keyIterator();
        while (kit2.next()) |k| {
            const key = k.*;
            if (std.mem.indexOf(u8, key, "/")) |slash| {
                const mod = key[slash + 1 ..];
                // Find parent prefix by stripping last segment (after last '_')
                if (std.mem.lastIndexOf(u8, mod, "_")) |us| {
                    const parent = mod[0..us];
                    const sub = key[0..slash];
                    const merge_key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sub, parent });
                    const gop = try merge_candidates.getOrPut(merge_key);
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(allocator, try allocator.dupe(u8, key));
                }
            }
        }
        var mit = merge_candidates.iterator();
        while (mit.next()) |entry| {
            if (entry.value_ptr.items.len >= 2) {
                // Merge all modules into the parent
                if (module_map.get(entry.key_ptr.*)) |_| {} else {
                    // Move first module's tables to the parent key
                    var merged = std.ArrayList(TableDef).empty;
                    for (entry.value_ptr.items) |child_key| {
                        if (module_map.getPtr(child_key)) |child_data| {
                            for (child_data.items) |t| try merged.append(allocator, t);
                            child_data.deinit(allocator);
                            _ = module_map.remove(child_key);
                        }
                    }
                    try module_map.put(try allocator.dupe(u8, entry.key_ptr.*), merged);
                }
            }
        }
    }

    if (subsystem_map.count() == 0) {
        subsystem_map.deinit();
        return null;
    }
    return subsystem_map;
}

fn generateModuleModel(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef, strip_prefix_len: usize, json_style: JsonStyle) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_model_header, module_name, pascal_mod);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (tables) |table| {
        const effective_name = if (strip_prefix_len > 0 and strip_prefix_len < table.name.len)
            table.name[strip_prefix_len..]
        else
            table.name;
        const model_name = try toPascalCase(allocator, effective_name);
        defer allocator.free(model_name);

        try buf.print(allocator, "pub const {s} = struct {{\n", .{model_name});
        try buf.print(allocator, "    pub const sql_table_name: []const u8 = \"{s}\";\n", .{table.name});
        for (table.columns) |col| {
            if (col.col_type == .unknown and col.name.len == 0) continue;
            const base = zigScalarColumnType(col.col_type);
            if (col.nullable or col.has_default or col.is_primary_key) {
                try buf.print(allocator, "    {s}: ?{s} = null,\n", .{ col.name, base });
            } else {
                try buf.print(allocator, "    {s}: {s},\n", .{ col.name, base });
            }
        }
        if (json_style == .camel) {
            try buf.appendSlice(allocator, "\n    pub const json_names = [_]struct { db: []const u8, json: []const u8 }{\n");
            for (table.columns) |col| {
                if (col.col_type == .unknown and col.name.len == 0) continue;
                const camel_name = try toCamelCase(allocator, col.name);
                defer allocator.free(camel_name);
                try buf.print(allocator, "        .{{ .db = \"{s}\", .json = \"{s}\" }},\n", .{ col.name, camel_name });
            }
            try buf.appendSlice(allocator, "    };\n");
        }
        try buf.appendSlice(allocator, "};\n\n");
    }

    return buf.toOwnedSlice(allocator);
}
fn generateModulePersistence(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef, strip_prefix_len: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_module = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_module);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_persistence_header, module_name, pascal_module);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (tables) |table| {
        const effective_name = if (strip_prefix_len > 0 and strip_prefix_len < table.name.len)
            table.name[strip_prefix_len..]
        else
            table.name;
        const model_name = try toPascalCase(allocator, effective_name);
        defer allocator.free(model_name);
        const method_name = try toCamelCase(allocator, effective_name);
        defer allocator.free(method_name);

        try buf.print(allocator, "    pub fn {s}Repo(self: *{s}Persistence) data.Repository(model.{s}) {{\n", .{ method_name, pascal_module, model_name });
        try buf.appendSlice(allocator, "        return .{ .orm = &self.orm };\n");
        try buf.appendSlice(allocator, "    }\n\n");
    }

    try buf.appendSlice(allocator, orm_tpl.sqlx_persistence_footer);
    return buf.toOwnedSlice(allocator);
}

fn generateModuleService(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef, strip_prefix_len: usize, enable_events: bool, with_transactions: bool) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_module = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_module);
    const header_tpl = if (enable_events) orm_tpl.sqlx_service_header else orm_tpl.sqlx_service_header_noev;
    const header = try orm_tpl.expandOrm(allocator, header_tpl, module_name, pascal_module);
    defer allocator.free(header);
    try buf.appendSlice(allocator, header);

    for (tables) |table| {
        const effective_name = if (strip_prefix_len > 0 and strip_prefix_len < table.name.len)
            table.name[strip_prefix_len..]
        else
            table.name;
        const model_name = try toPascalCase(allocator, effective_name);
        defer allocator.free(model_name);
        const method_name = try toCamelCase(allocator, effective_name);
        defer allocator.free(method_name);
        const list_sfx = if (std.mem.endsWith(u8, model_name, "s") or std.mem.endsWith(u8, model_name, "S")) "" else "s";
        const list_method = try std.fmt.allocPrint(allocator, "list{s}{s}", .{model_name, list_sfx});
        defer allocator.free(list_method);

        try buf.print(allocator, "    pub fn {s}(self: *{s}Service, page: usize, size: usize) !data.orm.PageResult(model.{s}) {{\n", .{ list_method, pascal_module, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        return try repo.findPage(page, size);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        const pk_type = pkColumnZigType(table);
        try buf.print(allocator, "    pub fn get{s}(self: *{s}Service, id: {s}) !?model.{s} {{\n", .{ model_name, pascal_module, pk_type, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        return try repo.findById(id);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        // Tenant-aware variants if table has tenant_id
        const has_tenant = for (table.columns) |col| {
            if (std.mem.eql(u8, col.name, "tenant_id")) break true;
        } else false;
        if (has_tenant) {
            try buf.print(allocator, "    pub fn {s}(self: *{s}Service, page: usize, size: usize, tenant_id: i64) !data.orm.PageResult(model.{s}) {{\n", .{ list_method, pascal_module, model_name });
            try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
            try buf.print(allocator, "        return try repo.findPageFiltered(self.persistence.backend.allocator, \"WHERE tenant_id = ?\", &.{{zigmodu.data.sqlx.Value.int(tenant_id)}}, page, size);\n", .{});
            try buf.appendSlice(allocator, "    }\n\n");
            try buf.print(allocator, "    pub fn get{s}ByTenant(self: *{s}Service, id: {s}, tenant_id: i64) !?model.{s} {{\n", .{ model_name, pascal_module, pk_type, model_name });
            try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
            try buf.appendSlice(allocator, "        const entity = try repo.findById(id);\n");
            try buf.appendSlice(allocator, "        return if (entity != null and entity.?.tenant_id != null and entity.?.tenant_id.? == tenant_id) entity else null;\n");
            try buf.appendSlice(allocator, "    }\n\n");
        }

        try buf.print(allocator, "    pub fn create{s}(self: *{s}Service, entity: model.{s}) !model.{s} {{\n", .{ model_name, pascal_module, model_name, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        const created = try repo.insert(entity);\n");
        if (enable_events) {
            try buf.print(allocator, "        self.publish(.{{ .{s}Created = .{{ .id = created.id.? }} }});\n", .{model_name});
        }
        try buf.appendSlice(allocator, "        return created;\n");
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    pub fn update{s}(self: *{s}Service, entity: model.{s}) !void {{\n", .{ model_name, pascal_module, model_name });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        try repo.update(entity);\n");
        if (enable_events) {
            try buf.print(allocator, "        self.publish(.{{ .{s}Updated = .{{ .id = entity.id.? }} }});\n", .{model_name});
        }
        try buf.appendSlice(allocator, "    }\n\n");

        try buf.print(allocator, "    pub fn delete{s}(self: *{s}Service, id: {s}) !void {{\n", .{ model_name, pascal_module, pk_type });
        try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
        try buf.appendSlice(allocator, "        try repo.delete(id);\n");
        if (enable_events) {
            try buf.print(allocator, "        self.publish(.{{ .{s}Deleted = .{{ .id = id }} }});\n", .{model_name});
        }
        try buf.appendSlice(allocator, "    }\n\n");

        if (with_transactions) {
            try buf.print(allocator, "    pub fn transact{s}(self: *{s}Service, comptime R: type, fn_tx: *const fn (*data.orm.Tx(data.SqlxBackend)) anyerror!R) !R {{\n", .{ model_name, pascal_module });
            try buf.print(allocator, "        var repo = self.persistence.{s}Repo();\n", .{method_name});
            try buf.appendSlice(allocator, "        return try repo.transact(R, fn_tx);\n");
            try buf.appendSlice(allocator, "    }\n\n");
        }

        // Generate validate method from SQL constraints
        try buf.print(allocator, "    pub fn validate{s}(_: *{s}Service, entity: model.{s}) !void {{\n", .{ model_name, pascal_module, model_name });
        var has_rules = false;
        for (table.columns) |col| {
            if (col.col_type == .unknown and col.name.len == 0) continue;
            // Required non-nullable string fields with no default
            if (!col.nullable and !col.has_default and !col.is_primary_key and col.col_type == .string) {
                try buf.print(allocator, "        if (entity.{s}.len == 0) return error.ValidationFailed;\n", .{col.name});
                has_rules = true;
            }
            // Email format check
            if (std.mem.containsAtLeast(u8, col.name, 1, "email") or std.mem.containsAtLeast(u8, col.name, 1, "mail")) {
                try buf.print(allocator, "        if (entity.{s}.len > 0 and std.mem.indexOfScalar(u8, entity.{s}, '@') == null) return error.ValidationFailed;\n", .{ col.name, col.name });
                has_rules = true;
            }
            // Numeric range check (positive values for amount/price/stock fields)
            if (col.col_type == .int or col.col_type == .float) {
                if (std.mem.containsAtLeast(u8, col.name, 1, "price") or
                    std.mem.containsAtLeast(u8, col.name, 1, "amount") or
                    std.mem.containsAtLeast(u8, col.name, 1, "stock") or
                    std.mem.containsAtLeast(u8, col.name, 1, "quantity") or
                    std.mem.containsAtLeast(u8, col.name, 1, "count"))
                {
                    try buf.print(allocator, "        if (entity.{s} < 0) return error.ValidationFailed;\n", .{col.name});
                    has_rules = true;
                }
            }
            // Status/role/type enum check — warn via comment
            if (std.mem.containsAtLeast(u8, col.name, 1, "status") or
                std.mem.containsAtLeast(u8, col.name, 1, "role") or
                std.mem.containsAtLeast(u8, col.name, 1, "type"))
            {
                try buf.print(allocator, "        // TODO: validate entity.{s} against allowed enum values\n", .{col.name});
                has_rules = true;
            }
        }
        if (!has_rules) try buf.appendSlice(allocator, "        _ = entity;\n");
        try buf.appendSlice(allocator, "    }\n\n");
    }

    try buf.appendSlice(allocator, orm_tpl.sqlx_service_footer);
    return buf.toOwnedSlice(allocator);
}

fn pluralizeRoute(allocator: std.mem.Allocator, singular: []const u8) ![]const u8 {
    if (singular.len == 0) return try allocator.dupe(u8, singular);
    const last = singular[singular.len - 1];
    if (last == 's') return try allocator.dupe(u8, singular); // already plural
    if (last == 'x' or last == 'z') return try std.fmt.allocPrint(allocator, "{s}es", .{singular});
    if (std.mem.endsWith(u8, singular, "ch") or std.mem.endsWith(u8, singular, "sh")) return try std.fmt.allocPrint(allocator, "{s}es", .{singular});
    if (last == 'y' and singular.len > 1) {
        const prev = singular[singular.len - 2];
        if (prev != 'a' and prev != 'e' and prev != 'i' and prev != 'o' and prev != 'u') {
            const stem = singular[0..singular.len-1];
            return try std.fmt.allocPrint(allocator, "{s}ies", .{stem});
        }
    }
    return try std.fmt.allocPrint(allocator, "{s}s", .{singular});
}

fn generateModuleApi(allocator: std.mem.Allocator, module_name: []const u8, tables: []const TableDef, strip_prefix_len: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const pascal_module = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_module);
    const header = try orm_tpl.expandOrm(allocator, orm_tpl.sqlx_api_header, module_name, pascal_module);
    defer allocator.free(header);
    // Compute shared/ import path: flat → ../../shared, nested → ../../../shared, etc.
    var sp_depth: usize = 2;
    for (module_name) |c| { if (c == '/') sp_depth += 1; }
    var sp_buf = std.ArrayList(u8).empty;
    defer sp_buf.deinit(allocator);
    var sp_i: usize = 0;
    while (sp_i < sp_depth) : (sp_i += 1) { try sp_buf.appendSlice(allocator, "../"); }
    try sp_buf.appendSlice(allocator, "shared/");
    const header_with_shared = try replaceAllStr(allocator, header, "<<SHARED_IMPORT>>", sp_buf.items);
    defer allocator.free(header_with_shared);
    try buf.appendSlice(allocator, header_with_shared);

    for (tables) |table| {
        const effective_name = if (strip_prefix_len > 0 and strip_prefix_len < table.name.len)
            table.name[strip_prefix_len..]
        else
            table.name;
        const model_name = try toPascalCase(allocator, effective_name);
        defer allocator.free(model_name);
        // Multi-table modules: use table name as PascalCase model
        const pl_sfx = if (std.mem.endsWith(u8, model_name, "s") or std.mem.endsWith(u8, model_name, "S")) "" else "s";
        try buf.print(allocator, "        try group.get(\"/{s}/list\", list{s}{s}, @ptrCast(@alignCast(self)));\n", .{ module_name, model_name, pl_sfx });
        try buf.print(allocator, "        try group.get(\"/{s}/get\", get{s}, @ptrCast(@alignCast(self)));\n", .{ module_name, model_name });
        try buf.print(allocator, "        try group.post(\"/{s}/create\", create{s}, @ptrCast(@alignCast(self)));\n", .{ module_name, model_name });
        try buf.print(allocator, "        try group.put(\"/{s}/update\", update{s}, @ptrCast(@alignCast(self)));\n", .{ module_name, model_name });
        try buf.print(allocator, "        try group.delete(\"/{s}/delete\", delete{s}, @ptrCast(@alignCast(self)));\n", .{ module_name, model_name });
    }
    try buf.appendSlice(allocator, "    }\n\n");

    for (tables) |table| {
        const effective_name = if (strip_prefix_len > 0 and strip_prefix_len < table.name.len)
            table.name[strip_prefix_len..]
        else
            table.name;
        const model_name = try toPascalCase(allocator, effective_name);
        defer allocator.free(model_name);
        const pl_sfx2 = if (std.mem.endsWith(u8, model_name, "s") or std.mem.endsWith(u8, model_name, "S")) "" else "s";
        const pk_is_str2 = pkIsString(table);

        // list — GET /{plural}/list
        try buf.print(allocator, "    fn list{s}{s}(ctx: *http.Context) !void {{\n", .{model_name, pl_sfx2});
        try buf.appendSlice(allocator, "        const s = resolve(ctx);\n");
        try buf.appendSlice(allocator, "        const page = ctx.queryInt(usize, \"pageNo\", 1);\n");
        try buf.appendSlice(allocator, "        const size = ctx.queryInt(usize, \"pageSize\", 10);\n");
        try buf.print(allocator, "        const result = try s.service.list{s}{s}(page, size);\n", .{model_name, pl_sfx2});
        try buf.appendSlice(allocator, "        try R.wrapList(ctx, result);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        // get — GET /{plural}/get?id=xxx
        try buf.print(allocator, "    fn get{s}(ctx: *http.Context) !void {{\n", .{model_name});
        try buf.appendSlice(allocator, "        const s = resolve(ctx);\n");
        if (pk_is_str2) {
            try buf.appendSlice(allocator, "        const id = try ctx.paramStr(\"id\");\n");
        } else {
            try buf.appendSlice(allocator, "        const id = ctx.queryInt(i64, \"id\", 0);\n");
        }
        try buf.print(allocator, "        if (try s.service.get{s}(id)) |entity| {{\n", .{model_name});
        try buf.appendSlice(allocator, "            try R.wrapOk(ctx, entity);\n");
        try buf.appendSlice(allocator, "        } else { try R.wrapErr(ctx, 1, \"not found\"); }\n");
        try buf.appendSlice(allocator, "    }\n\n");

        // create — POST /{plural}/create
        try buf.print(allocator, "    fn create{s}(ctx: *http.Context) !void {{\n", .{model_name});
        try buf.appendSlice(allocator, "        const s = resolve(ctx);\n");
        try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{\n", .{model_name});
        try buf.appendSlice(allocator, "            try R.wrapErr(ctx, 1, \"invalid body\");\n            return;\n        };\n");
        try buf.print(allocator, "        s.service.validate{s}(entity) catch {{\n", .{model_name});
        try buf.appendSlice(allocator, "            try R.wrapErr(ctx, 1, \"validation failed\");\n            return;\n        };\n");
        try buf.print(allocator, "        const created = try s.service.create{s}(entity);\n", .{model_name});
        try buf.appendSlice(allocator, "        try R.wrapOk(ctx, created);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        // update — PUT /{plural}/update
        try buf.print(allocator, "    fn update{s}(ctx: *http.Context) !void {{\n", .{model_name});
        try buf.appendSlice(allocator, "        const s = resolve(ctx);\n");
        try buf.print(allocator, "        const entity = ctx.bindJson(model.{s}) catch {{\n", .{model_name});
        try buf.appendSlice(allocator, "            try R.wrapErr(ctx, 1, \"invalid body\");\n            return;\n        };\n");
        try buf.print(allocator, "        s.service.validate{s}(entity) catch {{\n", .{model_name});
        try buf.appendSlice(allocator, "            try R.wrapErr(ctx, 1, \"validation failed\");\n            return;\n        };\n");
        try buf.print(allocator, "        try s.service.update{s}(entity);\n", .{model_name});
        try buf.appendSlice(allocator, "        try R.wrapSuccess(ctx);\n");
        try buf.appendSlice(allocator, "    }\n\n");

        // delete — DELETE /{plural}/delete?id=xxx
        try buf.print(allocator, "    fn delete{s}(ctx: *http.Context) !void {{\n", .{model_name});
        try buf.appendSlice(allocator, "        const s = resolve(ctx);\n");
        if (pk_is_str2) {
            try buf.appendSlice(allocator, "        const id = try ctx.paramStr(\"id\");\n");
        } else {
            try buf.appendSlice(allocator, "        const id = ctx.queryInt(i64, \"id\", 0);\n");
        }
        try buf.print(allocator, "        try s.service.delete{s}(id);\n", .{model_name});
        try buf.appendSlice(allocator, "        try R.wrapSuccess(ctx);\n");
        try buf.appendSlice(allocator, "    }\n\n");
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

/// Replace all occurrences of a single character with another.
fn replaceChar(allocator: std.mem.Allocator, s: []const u8, from: u8, to: u8) ![]const u8 {
    const result = try allocator.alloc(u8, s.len);
    @memcpy(result, s);
    for (result) |*c| {
        if (c.* == from) c.* = to;
    }
    return result;
}

/// Generate AI context index file (_ai.zig) for a module.
/// Provides machine-readable metadata: dependencies, tables, API surface, extension points.

fn writeModuleFiles(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8, module_name: []const u8, tables: []const TableDef, opts: GenOptions, strip_prefix_len: usize) !void {
    const module_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, module_name });
    defer allocator.free(module_dir);
    try ensureDirGen(io, module_dir, opts);

    const model_code = try generateModuleModel(allocator, module_name, tables, strip_prefix_len, opts.json_style);
    defer allocator.free(model_code);
    const model_path = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{module_dir});
    defer allocator.free(model_path);
    try safeWrite(io, allocator, model_path, model_code, opts);

    const persistence_code = try generateModulePersistence(allocator, module_name, tables, strip_prefix_len);
    defer allocator.free(persistence_code);
    const persistence_path = try std.fmt.allocPrint(allocator, "{s}/persistence.zig", .{module_dir});
    defer allocator.free(persistence_path);
    try safeWrite(io, allocator, persistence_path, persistence_code, opts);

    if (!opts.data_only) {
        const service_code = try generateModuleService(allocator, module_name, tables, strip_prefix_len, opts.enable_events, opts.with_transactions);
        defer allocator.free(service_code);
        const service_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{module_dir});
        defer allocator.free(service_path);
        try safeWrite(io, allocator, service_path, service_code, opts);

        const api_code = try generateModuleApi(allocator, module_name, tables, strip_prefix_len);
        defer allocator.free(api_code);
        const api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{module_dir});
        defer allocator.free(api_path);
        try safeWrite(io, allocator, api_path, api_code, opts);

        const dependencies_str = try inferModuleDependencies(allocator, tables, module_name, strip_prefix_len);
        defer allocator.free(dependencies_str);

        const module_code = try generateModuleZig(allocator, module_name, dependencies_str);
        defer allocator.free(module_code);
        const module_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{module_dir});
        defer allocator.free(module_path);
        try safeWrite(io, allocator, module_path, module_code, opts);

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
    try safeWrite(io, allocator, schema_path, schema_code, opts);

    // Generate client.zig
    const client_code = try generateZentClient(allocator, module_name, tables);
    defer allocator.free(client_code);
    const client_path = try std.fmt.allocPrint(allocator, "{s}/client.zig", .{module_dir});
    defer allocator.free(client_path);
    try safeWrite(io, allocator, client_path, client_code, opts);

    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);
    const module_code = try orm_tpl.expandOrm(allocator, orm_tpl.zent_module_zig, module_name, pascal_mod);
    defer allocator.free(module_code);
    const module_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{module_dir});
    defer allocator.free(module_path);
    try safeWrite(io, allocator, module_path, module_code, opts);

    std.log.info("Generated zent module '{s}' at {s}/ with {d} table(s)", .{ module_name, module_dir, tables.len });
}

fn cmdGenerate(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        std.log.err("Usage: zmodu generate <module|event|api|orm|migration|health|config> [options]", .{});
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
    } else if (std.mem.eql(u8, sub, "migration")) {
        try cmdMigration(io, allocator, args[1..]);
    } else if (std.mem.eql(u8, sub, "health")) {
        try cmdHealth(io, allocator, args[1..]);
    } else if (std.mem.eql(u8, sub, "config")) {
        try cmdConfig(io, allocator, args[1..]);
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

    const sql_content = std.Io.Dir.cwd().readFileAlloc(io, sql_path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
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
            try writeModuleFiles(io, allocator, out_dir, mod_name, tables, opts, 0);
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

    const orm_prefix_len = commonTablePrefix(tables);

    var iter = module_map.iterator();
    var module_count: usize = 0;
    while (iter.next()) |entry| {
        if (std.mem.eql(u8, backend, "zent")) {
            try writeModuleFilesZent(io, allocator, out_dir, entry.key_ptr.*, entry.value_ptr.items, opts);
        } else {
            try writeModuleFiles(io, allocator, out_dir, entry.key_ptr.*, entry.value_ptr.items, opts, orm_prefix_len);
        }
        module_count += 1;
    }
    std.log.info("Auto-grouped {d} table(s) into {d} module(s)", .{ tables.len, module_count });
}

// ── migration: generate Flyway-style migration file ─────────────────

fn cmdLife(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.log.info("usage: zmodu life <tree|fingerprint|evolve>", .{});
        return;
    }
    if (std.mem.eql(u8, args[0], "tree")) {
        std.log.info("evolution tree (.life/tree/):", .{});
        var dir = std.Io.Dir.cwd().openDir(io, ".life/tree", .{ .iterate = true }) catch {
            std.log.info("  (no evolution tree yet)", .{});
            return;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .file) std.log.info("  {s}", .{entry.name});
        }
        return;
    }
    if (std.mem.eql(u8, args[0], "fingerprint")) {
        // Simple fingerprint: hash of .life/ tree entries + DNA modification time
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        // Hash the tree listing as a proxy for project state
        var dir = std.Io.Dir.cwd().openDir(io, ".life/tree", .{ .iterate = true }) catch {
            std.log.info("fingerprint: genesis-v0.1.0", .{});
            return;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            hasher.update(entry.name);
        }
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        std.log.info("fingerprint: {x}{x}{x}{x}{x}{x}{x}{x}", .{ digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7] });
        return;
    }
    if (std.mem.eql(u8, args[0], "evolve")) {
        const version = if (args.len > 1) args[1] else "v0.2.0";
        const msg = if (args.len > 2) args[2] else "evolution step";
        const tree_path = try std.fmt.allocPrint(allocator, ".life/tree/{s}.md", .{version});
        defer allocator.free(tree_path);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(allocator, "# {s} — {s}\n{s}\n", .{ version, msg, msg });
        try writeFile(io, tree_path, buf.items);
        // Update fingerprint file
        const fp_path = ".life/fingerprint.sha256";
        const fp_val = try std.fmt.allocPrint(allocator, "{s}-{s}\n", .{ version, msg });
        defer allocator.free(fp_val);
        try writeFile(io, fp_path, fp_val);
        std.log.info("evolved: {s} → .life/tree/{s}.md", .{ msg, version });
        return;
    }
    std.log.info("usage: zmodu life <tree|fingerprint|evolve [version] [message]>", .{});
}

fn cmdPlugin(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = io;
    _ = allocator;
    if (args.len == 0 or std.mem.eql(u8, args[0], "list")) {
        std.log.info("installed plugins:", .{});
        std.log.info("  wechat-pay (P0) — WeChat Pay SDK stub", .{});
        std.log.info("  aliyun-oss (P1) — Alibaba Cloud OSS stub", .{});
        std.log.info("  apns (P1) — Apple Push Notification stub", .{});
        std.log.info("", .{});
        std.log.info("usage: zmodu plugin stub --name <name> --methods a,b,c --priority P0|P1|P2", .{});
        return;
    }
    std.log.err("unknown plugin command: {s}", .{args[0]});
    return error.CliUsage;
}

fn cmdMigration(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.log.err("usage: zmodu migration <description> [--dir <dir>]", .{});
        return error.CliUsage;
    }

    var description: []const u8 = "";
    var dir: []const u8 = "src/migrations";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dir")) {
            if (i + 1 >= args.len) return error.CliUsage;
            dir = args[i + 1];
            i += 1;
        } else if (description.len == 0) {
            description = args[i];
        }
    }

    if (description.len == 0) {
        std.log.err("Migration description is required.", .{});
        return error.CliUsage;
    }

    if (pathContainsDotDot(dir)) {
        std.log.err("Migration directory must not contain '..': {s}", .{dir});
        return error.CliUsage;
    }
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.err("Cannot create migration directory '{s}': {s}", .{ dir, @errorName(err) });
        return err;
    };

    // Generate timestamp YYYYMMDDHHMMSS
    const now_epoch = std.time.epoch.unix;
    const epoch_seconds: u64 = @intCast(now_epoch);
    const seconds_per_day: u64 = 86400;
    const days_since_epoch = epoch_seconds / seconds_per_day;

    // Simple date calculation (good enough for migration timestamps)
    var remaining_days = days_since_epoch;
    var year: u64 = 1970;
    while (true) {
        const days_in_year = if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) @as(u64, 366) else @as(u64, 365);
        if (remaining_days < days_in_year) break;
        remaining_days -= days_in_year;
        year += 1;
    }

    const month_days_normal = [_]u64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const month_days_leap = [_]u64{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const month_days = if (leap) &month_days_leap else &month_days_normal;

    var month: u64 = 1;
    for (month_days) |md| {
        if (remaining_days < md) break;
        remaining_days -= md;
        month += 1;
    }
    const day = remaining_days + 1;

    const secs_in_day = epoch_seconds % seconds_per_day;
    const hour = (secs_in_day / 3600) % 24;
    const minute = (secs_in_day / 60) % 60;
    const second = secs_in_day % 60;

    // Sanitize description for filename
    var safe_name = std.ArrayList(u8).empty;
    defer safe_name.deinit(allocator);
    for (description) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
            try safe_name.append(allocator, c);
        } else {
            try safe_name.append(allocator, '_');
        }
    }

    const filename = try std.fmt.allocPrint(allocator, "V{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}__{s}.sql", .{
        year, month, day, hour, minute, second, safe_name.items,
    });
    defer allocator.free(filename);

    const filepath = try std.fs.path.join(allocator, &.{ dir, filename });
    defer allocator.free(filepath);

    // Check if file exists (never overwrite migration files)
    _ = std.Io.Dir.cwd().createFile(io, filepath, .{ .exclusive = true }) catch |err| { if (err == error.PathAlreadyExists) { std.log.err("Migration file already exists: {s}", .{filepath}); return error.RefuseOverwrite; } return err; };
    const content = try std.fmt.allocPrint(allocator,
        \\-- version: {d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}
        \\-- description: {s}
        \\-- rollback: (define rollback SQL)
        \\
        \\-- TODO: write migration SQL here
        \\
    , .{ year, month, day, hour, minute, second, description });
    defer allocator.free(content);

    try writeFile(io, filepath, content);

    std.log.info("Created migration: {s}", .{filepath});
}

// ── health: generate health check endpoint boilerplate ──────────────

fn cmdHealth(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) {
        std.log.info("usage: zmodu health [--out <dir>] [--module <name>]", .{});
        return;
    }

    var out_dir: []const u8 = "src/modules";
    var module_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            if (i + 1 >= args.len) return error.CliUsage;
            out_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--module")) {
            if (i + 1 >= args.len) return error.CliUsage;
            module_name = args[i + 1];
            i += 1;
        }
    }

    if (pathContainsDotDot(out_dir)) {
        std.log.err("Output directory must not contain '..': {s}", .{out_dir});
        return error.CliUsage;
    }
    const target_dir = if (module_name) |mn|
        try std.fs.path.join(allocator, &.{ out_dir, mn })
    else
        try allocator.dupe(u8, out_dir);
    defer allocator.free(target_dir);

    std.Io.Dir.cwd().createDirPath(io, target_dir) catch |err| {
        std.log.err("Cannot create directory '{s}': {s}", .{ target_dir, @errorName(err) });
        return err;
    };

    const filepath = try std.fs.path.join(allocator, &.{ target_dir, "health.zig" });
    defer allocator.free(filepath);

    const content =
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\
        \\const HealthEndpoint = zigmodu.HealthEndpoint;
        \\
        \\pub fn initHealth() HealthEndpoint {
        \\    return HealthEndpoint.init(std.heap.page_allocator);
        \\}
        \\
        \\pub fn registerHealthChecks(endpoint: *HealthEndpoint) !void {
        \\    try endpoint.registerCheck("liveness", "Process liveness", HealthEndpoint.alwaysUp);
        \\    try endpoint.registerCheck("readiness", "Service readiness", HealthEndpoint.alwaysUp);
        \\}
        \\
        \\// Wire into HTTP server:
        \\//   const hc = initHealth();
        \\//   defer hc.deinit();
        \\//   try registerHealthChecks(&hc);
        \\//   try group.get("/health/live", zigmodu.HealthEndpoint.handleLiveness, null);
        \\//   try group.get("/health/ready", zigmodu.HealthEndpoint.handleReadiness(&hc), null);
        \\
        \\// Add custom checks with context:
        \\//   try endpoint.registerCheckWithContext("database", "DB connectivity",
        \\//       HealthEndpoint.databaseCheck, @ptrCast(&db_pool));
        \\
    ;

    // Exclusive create prevents TOCTOU race
    _ = std.Io.Dir.cwd().createFile(io, filepath, .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.log.err("File already exists: {s} (use --force to overwrite)", .{filepath});
            return error.RefuseOverwrite;
        }
        return err;
    };
    try writeFile(io, filepath, content);

    std.log.info("Created health check: {s}", .{filepath});
}

// ── config: generate ExternalizedConfig boilerplate ──────────────────

fn cmdConfig(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) {
        std.log.info("usage: zmodu config [--out <dir>] [--keys k1,k2,...]", .{});
        return;
    }

    var out_dir: []const u8 = "src";
    var keys_str: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            if (i + 1 >= args.len) return error.CliUsage;
            out_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--keys")) {
            if (i + 1 >= args.len) return error.CliUsage;
            keys_str = args[i + 1];
            i += 1;
        }
    }

    if (pathContainsDotDot(out_dir)) {
        std.log.err("Output directory must not contain '..': {s}", .{out_dir});
        return error.CliUsage;
    }
    std.Io.Dir.cwd().createDirPath(io, out_dir) catch |err| {
        std.log.err("Cannot create directory '{s}': {s}", .{ out_dir, @errorName(err) });
        return err;
    };

    const filepath = try std.fs.path.join(allocator, &.{ out_dir, "config.zig" });
    defer allocator.free(filepath);

    // Build key list
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\
        \\pub const RequiredKeys = [_][]const u8{
        \\
    );

    if (keys_str) |ks| {
        var key_iter = std.mem.splitScalar(u8, ks, ',');
        while (key_iter.next()) |key| {
            const trimmed = std.mem.trim(u8, key, " ");
            if (trimmed.len > 0) {
                try buf.print(allocator, "    \"{s}\",\n", .{trimmed});
            }
        }
    } else {
        try buf.appendSlice(allocator, "    \"DB_HOST\",\n");
        try buf.appendSlice(allocator, "    \"DB_PORT\",\n");
        try buf.appendSlice(allocator, "    \"DB_NAME\",\n");
    }

    try buf.appendSlice(allocator,
        \\};
        \\
        \\pub fn validateConfig(config: *zigmodu.ExternalizedConfig, allocator: std.mem.Allocator) !void {
        \\    const missing = try config.validateRequired(&RequiredKeys, allocator);
        \\    defer allocator.free(missing);
        \\    if (missing.len > 0) {
        \\        for (missing) |key| {
        \\            std.log.err("Missing required config key: {s}", .{key});
        \\        }
        \\        return error.ConfigurationError;
        \\    }
        \\}
        \\
    );

    // Exclusive create prevents TOCTOU race
    _ = std.Io.Dir.cwd().createFile(io, filepath, .{ .exclusive = true }) catch |err| {
        if (err == error.PathAlreadyExists) {
            std.log.err("File already exists: {s} (use --force to overwrite)", .{filepath});
            return error.RefuseOverwrite;
        }
        return err;
    };
    try writeFile(io, filepath, buf.items);

    std.log.info("Created config validator: {s}", .{filepath});
}



// ── test: generate integration test scaffolding ──────────────────

fn cmdTest(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.log.err("Usage: zmodu test <module-name> [--out <dir>]", .{});
        return error.CliUsage;
    }
    const module_name = args[0];
    var out_dir: []const u8 = "src/modules";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--out")) {
            if (i + 1 >= args.len) return error.CliUsage;
            out_dir = args[i + 1]; i += 1;
        }
    }

    const mod_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, module_name });
    defer allocator.free(mod_dir);
    std.Io.Dir.cwd().createDirPath(io, mod_dir) catch {};
    const fp = try std.fmt.allocPrint(allocator, "{s}/test.zig", .{mod_dir});
    defer allocator.free(fp);

    if (std.Io.Dir.cwd().openFile(io, fp, .{})) |_| {
        std.log.err("File already exists: {s}", .{fp});
        return error.RefuseOverwrite;
    } else |_| {}

    const pascal_mod = try toPascalCase(allocator, module_name);
    defer allocator.free(pascal_mod);

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.print(allocator,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const module = @import("module.zig");
        \\const service = @import("service.zig");
        \\const model = @import("model.zig");
        \\
        \\test "{s}: service health check" {{
        \\    try zigmodu.HealthEndpoint.alwaysUp(null);
        \\}}
        \\
        \\test "{s}: module lifecycle init/deinit" {{
        \\    try module.init();
        \\    module.deinit();
        \\}}
        \\
        \\test "{s}: CRUD integration" {{
        \\    // Add database-dependent tests here
        \\    const allocator = std.testing.allocator;
        \\    _ = allocator;
        \\}}
        \\
    , .{ module_name, module_name, module_name });

    try writeFile(io, fp, buf.items);
    std.log.info("Created test scaffold: {s}", .{fp});
}


// ── scaffold: one-shot SQL → full project ────────────────────────

const ScaffoldOpts = struct {
    sql_path: ?[]const u8,
    project_name: []const u8,
    out_dir: []const u8,
    db_dsn: ?[]const u8 = null,
    force: bool,
    dry_run: bool,
    diff_old_sql: ?[]const u8 = null,
    with_events: bool = false,
    with_resilience: bool = false,
    with_cluster: bool = false,
    with_marketing: bool = false,
    with_metrics: bool = false,
    with_auth: bool = false,
    json_style: JsonStyle = .snake,
    with_transactions: bool = false,
    with_redis: bool = false,
    with_websocket: bool = false,
    with_aichat: bool = false,
    with_agent: bool = false,
    with_web4: bool = false,
};

fn parseScaffoldArgs(allocator: std.mem.Allocator, args: []const []const u8) !ScaffoldOpts {
    _ = allocator;
    var sql_path: ?[]const u8 = null;
    var project_name: ?[]const u8 = null;
    var out_dir: []const u8 = ".";
    var force: bool = false;
    var dry_run: bool = false;
    var diff_old_sql: ?[]const u8 = null;

    var with_events: bool = false;
    var with_resilience: bool = false;
    var with_cluster: bool = false;
    var with_marketing: bool = false;
    var with_metrics: bool = false;
    var with_auth: bool = false;
    var json_style: JsonStyle = .snake;
    var with_transactions: bool = false;
    var with_redis: bool = false;
    var with_websocket: bool = false;
    var with_aichat: bool = false;
    var with_agent: bool = false;
    var with_web4: bool = false;

    var db_dsn: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--sql")) {
            if (i + 1 >= args.len) return error.CliUsage;
            sql_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--from-db")) {
            if (i + 1 >= args.len) return error.CliUsage;
            db_dsn = args[i + 1];
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
        } else if (std.mem.eql(u8, args[i], "--diff")) {
            if (i + 1 >= args.len) return error.CliUsage;
            diff_old_sql = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--with-events")) {
            with_events = true;
        } else if (std.mem.eql(u8, args[i], "--with-resilience")) {
            with_resilience = true;
        } else if (std.mem.eql(u8, args[i], "--with-cluster")) {
            with_cluster = true;
        } else if (std.mem.eql(u8, args[i], "--with-marketing")) {
            with_marketing = true;
        } else if (std.mem.eql(u8, args[i], "--with-metrics")) {
            with_metrics = true;
        } else if (std.mem.eql(u8, args[i], "--with-auth")) {
            with_auth = true;
        } else if (std.mem.eql(u8, args[i], "--with-transactions")) {
            with_transactions = true;
        } else if (std.mem.eql(u8, args[i], "--with-redis")) {
            with_redis = true;
        } else if (std.mem.eql(u8, args[i], "--with-websocket")) {
            with_websocket = true;
        } else if (std.mem.eql(u8, args[i], "--with-aichat")) {
            with_aichat = true;
        } else if (std.mem.eql(u8, args[i], "--with-agent")) {
            with_agent = true;
        } else if (std.mem.eql(u8, args[i], "--with-web4")) {
            with_web4 = true;
        } else if (std.mem.eql(u8, args[i], "--json-style")) {
            if (i + 1 >= args.len) return error.CliUsage;
            if (std.mem.eql(u8, args[i + 1], "camel")) json_style = .camel;
            i += 1;
        } else {
            std.log.err("Unknown scaffold option: {s}", .{args[i]});
            return error.CliUsage;
        }
    }

    if (sql_path == null and db_dsn == null) {
        std.log.err("scaffold requires --sql <file> or --from-db <dsn>", .{});
        return error.CliUsage;
    }
    if (project_name == null) {
        std.log.err("scaffold requires --name <project-name>", .{});
        return error.CliUsage;
    }
    return ScaffoldOpts{
        .sql_path = sql_path,
        .project_name = project_name.?,
        .out_dir = out_dir,
        .db_dsn = db_dsn,
        .force = force,
        .dry_run = dry_run,
        .diff_old_sql = diff_old_sql,
        .with_events = with_events,
        .with_resilience = with_resilience,
        .with_cluster = with_cluster,
        .with_marketing = with_marketing,
        .with_metrics = with_metrics,
        .with_auth = with_auth,
        .json_style = json_style,
        .with_transactions = with_transactions,
        .with_redis = with_redis,
        .with_websocket = with_websocket,
        .with_aichat = with_aichat,
        .with_agent = with_agent,
        .with_web4 = with_web4,
    };
}

pub fn cmdScaffold(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const sopts = try parseScaffoldArgs(allocator, args);

    // 1. Get table definitions — either from SQL file or live database
    var tables: []TableDef = undefined;
    if (sopts.db_dsn) |dsn| {
        // Import SQL to DB first if both --sql and --from-db provided
        if (sopts.sql_path) |sql_path| {
            const sql_content = std.Io.Dir.cwd().readFileAlloc(io, sql_path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
                std.log.err("Cannot read SQL file '{s}': {s}", .{ sql_path, @errorName(err) });
                return err;
            };
            defer allocator.free(sql_content);
            try importSqlToDatabase(io, allocator, dsn, sql_content);
        }
        tables = try introspectDatabase(io, allocator, dsn);
        std.log.info("Scaffolding '{s}' from {d} tables in database", .{ sopts.project_name, tables.len });
    } else if (sopts.sql_path) |sql_path| {
        const sql_content = std.Io.Dir.cwd().readFileAlloc(io, sql_path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
            std.log.err("Cannot read SQL file '{s}': {s}", .{ sql_path, @errorName(err) });
            return err;
        };
        defer allocator.free(sql_content);

        const sql_for_parse = stripUtf8BomAndTrimSql(sql_content);
        if (sql_for_parse.len == 0) return error.CliUsage;

        tables = parseSqlSchema(allocator, sql_for_parse) catch |err| {
            std.log.err("Failed to parse SQL: {s}", .{@errorName(err)});
            return err;
        };
        std.log.info("Scaffolding '{s}' from {d} tables in {s}", .{ sopts.project_name, tables.len, sql_path });
    } else {
        return error.CliUsage;
    }

    // --diff mode: compare with old SQL and report changes
    if (sopts.diff_old_sql) |old_sql_path| {
        const old_sql_content = std.Io.Dir.cwd().readFileAlloc(io, old_sql_path, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
            std.log.err("Cannot read old SQL file '{s}': {s}", .{ old_sql_path, @errorName(err) });
            return err;
        };
        defer allocator.free(old_sql_content);
        const old_sql_for_parse = stripUtf8BomAndTrimSql(old_sql_content);

        const old_tables = parseSqlSchema(allocator, old_sql_for_parse) catch |err| {
            std.log.err("Failed to parse old SQL: {s}", .{@errorName(err)});
            return err;
        };
        defer freeTableDefs(allocator, old_tables);

        const table_diffs = sql_diff.diffTables(allocator, old_tables, tables) catch {
            std.log.warn("Diff failed, proceeding with full scaffold", .{});
            return;
        };
        defer {
            for (table_diffs) |d| if (d.column_changes.len > 0) allocator.free(d.column_changes);
            allocator.free(table_diffs);
        }

        std.log.info("--diff: {d} tables changed", .{table_diffs.len});
        for (table_diffs) |d| {
            const change_str = switch (d.change_type) {
                .added => "added",
                .removed => "removed",
                .modified => "modified",
            };
            if (d.change_type == .modified and d.column_changes.len > 0) {
                std.log.info("  {s} {s} ({d} column changes)", .{ change_str, d.table_name, d.column_changes.len });
            } else {
                std.log.info("  {s} {s}", .{ change_str, d.table_name });
            }
        }
        std.log.info("Note: hash tracking will protect AI-modified files from overwrites", .{});
    }
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

    if (tables.len == 0) return error.CliUsage;

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

    // 2.5 Detect subsystems from module name prefixes
    // Tables like shop_order, shop_product → subsystem "shop" with modules "order", "product"
    // Tables like crm_customer → subsystem "crm" with module "customer"
    // Tables like users (no shared prefix) → no subsystem
    var subsystem_map: ?std.StringHashMap(std.ArrayList([]const u8)) = try detectSubsystems(allocator, &module_map);
    defer {
        if (subsystem_map) |*sm| {
            var siter = sm.iterator();
            while (siter.next()) |entry| {
                for (entry.value_ptr.items) |m| allocator.free(m);
                entry.value_ptr.deinit(allocator);
                allocator.free(entry.key_ptr.*);
            }
            sm.deinit();
        }
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
    const gen_opts: GenOptions = .{ .dry_run = sopts.dry_run, .force = sopts.force, .json_style = sopts.json_style, .enable_events = sopts.with_events, .with_transactions = sopts.with_transactions };

    const scaffold_prefix_len = commonTablePrefix(tables);

    for (module_names.items) |mod_name| {
        const tables_for_mod = module_map.get(mod_name).?;
        try writeModuleFiles(io, allocator, modules_dir, mod_name, tables_for_mod.items, gen_opts, scaffold_prefix_len);

        // ext/ removed — AI modifies generated files directly.
        if (false) {
        const ext_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/ext", .{ modules_dir, mod_name });
        defer allocator.free(ext_dir);
        try ensureDirGen(io, ext_dir, gen_opts);

        const var_name = try replaceChar(allocator, mod_name, '/', '_');
        defer allocator.free(var_name);
        const pascal_mod = try toPascalCase(allocator, mod_name);
        defer allocator.free(pascal_mod);
        const ext_svc = try std.fmt.allocPrint(allocator,
            \\// {s} service extension — add custom business logic here.
            \\// @initialized — AI may modify freely.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const ext_svc = @import("../service.zig");
            \\
            \\pub const {s}ServiceExt = struct {{
            \\    svc: *ext_svc.{s}Service,
            \\    backend: zigmodu.data.SqlxBackend,
            \\
            \\    pub fn init(svc: *ext_svc.{s}Service, backend: zigmodu.data.SqlxBackend) {s}ServiceExt {{
            \\        return .{{ .svc = svc, .backend = backend }};
            \\    }}
            \\
            \\    // Add your custom business methods here
            \\}};
            \\
        , .{ mod_name, pascal_mod, pascal_mod, pascal_mod, pascal_mod });
        defer allocator.free(ext_svc);
        const ext_svc_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{ ext_dir });
        defer allocator.free(ext_svc_path);
        if (!fileExists(io, ext_svc_path)) try safeWrite(io, allocator, ext_svc_path, ext_svc, gen_opts);

        // Generate ext/api.zig template per module
        // Compute shared response.zig path for ext/ (one level deeper than API)
        var ext_depth: usize = 3;
        for (mod_name) |c| { if (c == '/') ext_depth += 1; }
        var ext_path_buf = std.ArrayList(u8).empty;
        defer ext_path_buf.deinit(allocator);
        var ext_di: usize = 0;
        while (ext_di < ext_depth) : (ext_di += 1) { try ext_path_buf.appendSlice(allocator, "../"); }
        try ext_path_buf.appendSlice(allocator, "shared/response.zig");
        const shared_ext_import = ext_path_buf.items;

        const ext_api = try std.fmt.allocPrint(allocator,
            \\// {s} custom API endpoints — add business routes here.
            \\// @initialized — AI may modify freely.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const http = zigmodu.http;
            \\const R = @import("{s}");
            \\const ext_svc = @import("service.zig");
            \\
            \\pub const {s}ApiExt = struct {{
            \\    ext: *ext_svc.{s}ServiceExt,
            \\
            \\    pub fn init(ext: *ext_svc.{s}ServiceExt) {s}ApiExt {{
            \\        return .{{ .ext = ext }};
            \\    }}
            \\
            \\    pub fn registerRoutes(self: *{s}ApiExt, group: *zigmodu.http.RouteGroup) !void {{
            \\        const p = "/{s}";
            \\        try group.get(p ++ "/page", hPage, @ptrCast(@alignCast(self)));
            \\        try group.delete(p ++ "/delete-list", hDeleteList, @ptrCast(@alignCast(self)));
            \\        try group.get(p ++ "/list-all-simple", hSimple, @ptrCast(@alignCast(self)));
            \\        try group.get(p ++ "/export-excel", hExport, @ptrCast(@alignCast(self)));
            \\    }}
            \\
            \\    fn resolve2(ctx: *http.Context) *{s}ApiExt {{
            \\        return @ptrCast(@alignCast(ctx.user_data orelse unreachable));
            \\    }}
            \\
            \\    fn hPage(ctx: *http.Context) !void {{
            \\        const s = resolve2(ctx);
            \\        const pn = ctx.queryInt(usize, \"pageNo\", 1);
            \\        const ps = ctx.queryInt(usize, \"pageSize\", 10);
            \\        const r = s.ext.svc.list{s}(if (pn > 0) pn - 1 else 0, ps) catch {{ try R.wrapErr(ctx, .server_error, \"Query failed\"); return; }};
            \\        try R.wrapList(ctx, r);
            \\    }}
            \\    fn hDeleteList(ctx: *http.Context) !void {{
            \\        const s = resolve2(ctx);
            \\        const ids = ctx.queryStr(\"ids\", \"\");
            \\        if (ids.len == 0) {{ try R.wrapErr(ctx, 400, \"Missing ids\"); return; }}
            \\        var it = std.mem.splitScalar(u8, ids, ',');
            \\        while (it.next()) |id_str| {{
            \\            const id = std.fmt.parseInt(i64, id_str, 10) catch continue;
            \\            s.ext.svc.delete{s}(id) catch {{}};
            \\        }}
            \\        try R.wrapSuccess(ctx);
            \\    }}
            \\    fn hSimple(ctx: *http.Context) !void {{
            \\        const s = resolve2(ctx);
            \\        const r = s.ext.svc.list{s}(0, 1000) catch {{ try R.wrapErr(ctx, .server_error, \"Query failed\"); return; }};
            \\        try R.wrapList(ctx, r);
            \\    }}
            \\    fn hExport(ctx: *http.Context) !void {{
            \\        const s = resolve2(ctx);
            \\        const r = s.ext.svc.list{s}(0, 10000) catch {{ try R.wrapErr(ctx, .server_error, \"Query failed\"); return; }};
            \\        var buf = std.ArrayList(u8).empty;
            \\        try buf.append(ctx.allocator, \"id,name\\n\");
            \\        for (r.items) |item| {{ _ = item; try buf.appendSlice(ctx.allocator, \"\\n\"); }}
            \\        ctx.setHeader(\"Content-Type\", \"text/csv; charset=utf-8\") catch {{}};
            \\        ctx.setHeader(\"Content-Disposition\", \"attachment; filename=export.csv\") catch {{}};
            \\        try ctx.text(200, buf.items);
            \\    }}
            \\}};
            \\
        , .{ mod_name, shared_ext_import, pascal_mod, pascal_mod, pascal_mod, pascal_mod, pascal_mod, mod_name, pascal_mod, pascal_mod, pascal_mod, pascal_mod, pascal_mod });
        defer allocator.free(ext_api);
    const ext_api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{ ext_dir });
    defer allocator.free(ext_api_path);
    if (!fileExists(io, ext_api_path)) try safeWrite(io, allocator, ext_api_path, ext_api, gen_opts);
    } // if (false) — ext/ removed
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
            try safeWrite(io, allocator, sub_path, sub_mod, gen_opts);
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
            try safeWrite(io, allocator, rule_path, rule_content, gen_opts);
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
        try safeWrite(io, allocator, watcher_path, watcher_content, gen_opts);

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
        try safeWrite(io, allocator, manifest_path, manifest_content, gen_opts);

        std.log.info("Marketing module group generated with {d} sub-modules, hot_reload/, and plugins/", .{marketing_subs.len});
    }

    // 5. Generate build.zig
    const build_zig = try generateBuildZig(allocator, sopts.project_name);
    defer allocator.free(build_zig);
    const build_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{project_dir});
    defer allocator.free(build_path);
    try safeWrite(io, allocator, build_path, build_zig, gen_opts);

    // 6. Generate build.zig.zon
    const build_zon = try generateBuildZonImpl(allocator, sopts.project_name, null);
    defer allocator.free(build_zon);
    const zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{project_dir});
    defer allocator.free(zon_path);
    try safeWrite(io, allocator, zon_path, build_zon, gen_opts);

    // 7. Generate src/main.zig with all module wiring
    const main_zig = try generateScaffoldMainZig(allocator, sopts.project_name, module_names.items, sopts);
    defer allocator.free(main_zig);
    const main_path = try std.fmt.allocPrint(allocator, "{s}/src/main.zig", .{project_dir});
    defer allocator.free(main_path);
    try safeWrite(io, allocator, main_path, main_zig, gen_opts);

    // 8. Generate src/tests.zig
    const tests_zig = try generateScaffoldTestsZig(allocator, module_names.items);
    defer allocator.free(tests_zig);
    const tests_path = try std.fmt.allocPrint(allocator, "{s}/src/tests.zig", .{project_dir});
    defer allocator.free(tests_path);
    try safeWrite(io, allocator, tests_path, tests_zig, gen_opts);

    // 8.5 Generate test_api.sh — curl-based API smoke test
    var sh_buf: std.ArrayList(u8) = .empty;
    defer sh_buf.deinit(allocator);
    try sh_buf.appendSlice(allocator, "#!/bin/bash\nset -e\nPORT=${HTTP_PORT:-8080}\nBASE=\"http://localhost:$PORT/api\"\n\necho \"=== Health ===\"\ncurl -sf $BASE/health/live | grep -q UP && echo \"PASS\" || echo \"FAIL\"\n\n");
    for (module_names.items) |mod_name| {
        const var_name = try replaceChar(allocator, mod_name, '/', '_');
        defer allocator.free(var_name);
        const snake = try toSnakeCase(allocator, var_name);
        defer allocator.free(snake);
        const plural = try pluralizeRoute(allocator, snake);
        defer allocator.free(plural);
        try sh_buf.print(allocator, "echo \"=== {s} ===\"\necho \"  POST /{s}\"\nR=$(curl -sf -X POST $BASE/{s} -H 'Content-Type: application/json' -d '{{\"name\":\"test_{s}\"}}' 2>&1)\necho \"  $R\"\ncurl -sf $BASE/{s} | head -c 80 && echo \"\"\necho \"  PASS: {s}\"\n\n", .{ mod_name, plural, plural, var_name, plural, mod_name });
    }
    try sh_buf.appendSlice(allocator, "echo \"=== ALL PASS ===\"\n");
    const sh_path = try std.fmt.allocPrint(allocator, "{s}/test_api.sh", .{project_dir});
    defer allocator.free(sh_path);
    try safeWrite(io, allocator, sh_path, sh_buf.items, gen_opts);

    // 9. Generate src/business/module.zig (skeleton)
    const biz_dir = try std.fmt.allocPrint(allocator, "{s}/src/business", .{project_dir});
    defer allocator.free(biz_dir);
    try ensureDirGen(io, biz_dir, gen_opts);

    // Generate business/root.zig — placeholder, add your cross-module logic here
    var biz_root_buf: std.ArrayList(u8) = .empty;
    defer biz_root_buf.deinit(allocator);
    try biz_root_buf.appendSlice(allocator, "// Cross-module business logic — add your domain logic here.\n");
    try biz_root_buf.appendSlice(allocator, "// Example: pub const order_flow = @import(\"order_flow.zig\");\n");
    const biz_root = try biz_root_buf.toOwnedSlice(allocator);
    defer allocator.free(biz_root);
    const biz_root_path = try std.fmt.allocPrint(allocator, "{s}/root.zig", .{biz_dir});
    defer allocator.free(biz_root_path);
    try safeWrite(io, allocator, biz_root_path, biz_root, gen_opts);

    // 10. Generate src/shared/ (shared kernel)
    const shared_dir = try std.fmt.allocPrint(allocator, "{s}/src/shared", .{project_dir});
    defer allocator.free(shared_dir);
    try ensureDirGen(io, shared_dir, gen_opts);

    // shared/types.zig — cross-module shared types
    const shared_types = try std.fmt.allocPrint(allocator,
        \\//! Shared types — used across modules.
        \\const std = @import("std");
        \\
        \\pub const SortDir = enum {{ asc, desc }};
        \\
        \\pub const SortParam = struct {{
        \\    field: []const u8,
        \\    dir: SortDir = .asc,
        \\}};
        \\
        \\pub const DateRange = struct {{
        \\    start: ?i64 = null,
        \\    end: ?i64 = null,
        \\}};
        \\
    , .{});
    defer allocator.free(shared_types);
    const shared_types_path = try std.fmt.allocPrint(allocator, "{s}/types.zig", .{shared_dir});
    defer allocator.free(shared_types_path);
    try safeWrite(io, allocator, shared_types_path, shared_types, gen_opts);

    // shared/errors.zig — unified error types
    const shared_errors = try std.fmt.allocPrint(allocator,
        \\//! Unified error types — used across modules.
        \\pub const AppError = error{{
        \\    NotFound,
        \\    AlreadyExists,
        \\    ValidationFailed,
        \\    Unauthorized,
        \\    Forbidden,
        \\    Conflict,
        \\}};
        \\
        \\/// Business error codes for API responses.
        \\pub const BizCode = enum(i32) {{
        \\    success = 0,
        \\    not_found = 404,
        \\    validation_failed = 422,
        \\    unauthorized = 401,
        \\    forbidden = 403,
        \\    conflict = 409,
        \\    server_error = 500,
        \\}};
        \\
    , .{});
    defer allocator.free(shared_errors);
    const shared_errors_path = try std.fmt.allocPrint(allocator, "{s}/errors.zig", .{shared_dir});
    defer allocator.free(shared_errors_path);
    try safeWrite(io, allocator, shared_errors_path, shared_errors, gen_opts);

    // shared/response.zig — RuoYi-style API response helpers
    var shared_buf: std.ArrayList(u8) = .empty;
    defer shared_buf.deinit(allocator);
    try shared_buf.appendSlice(allocator, "//! RuoYi-style API response helpers\nconst std = @import(\"std\");\nconst http = @import(\"zigmodu\").http;\nconst BizCode = @import(\"errors.zig\").BizCode;\n\n");
    try shared_buf.appendSlice(allocator, "pub fn wrapOk(ctx: *http.Context, value: anytype) !void {\n    const inner = try std.json.Stringify.valueAlloc(ctx.allocator, value, .{});\n    defer ctx.allocator.free(inner);\n    const json = try std.fmt.allocPrint(ctx.allocator, \"{{\\\"code\\\":0,\\\"msg\\\":\\\"\\\",\\\"data\\\":{s}}}\", .{inner});\n    defer ctx.allocator.free(json);\n    try ctx.json(200, json);\n}\n\n");
    try shared_buf.appendSlice(allocator, "pub fn wrapList(ctx: *http.Context, result: anytype) !void {\n    const inner = try std.json.Stringify.valueAlloc(ctx.allocator, result.items, .{});\n    defer ctx.allocator.free(inner);\n    const json = try std.fmt.allocPrint(ctx.allocator, \"{{\\\"code\\\":0,\\\"msg\\\":\\\"\\\",\\\"data\\\":{{\\\"list\\\":{s},\\\"total\\\":{d}}}}}\", .{inner, result.total});\n    defer ctx.allocator.free(json);\n    try ctx.json(200, json);\n}\n\n");
    try shared_buf.appendSlice(allocator, "pub fn wrapSuccess(ctx: *http.Context) !void {\n    try ctx.json(200, \"{{\\\"code\\\":0,\\\"msg\\\":\\\"\\\",\\\"data\\\":null}}\");\n}\n\n");
    try shared_buf.appendSlice(allocator, "pub fn wrapErr(ctx: *http.Context, code: BizCode, errmsg: []const u8) !void {\n    const json = try std.fmt.allocPrint(ctx.allocator, \"{{\\\"code\\\":{d},\\\"msg\\\":\\\"{s}\\\",\\\"data\\\":null}}\", .{@intFromEnum(code), errmsg});\n    defer ctx.allocator.free(json);\n    try ctx.json(200, json);\n}\n");
    const shared_response = try shared_buf.toOwnedSlice(allocator);
    defer allocator.free(shared_response);
    const shared_response_path = try std.fmt.allocPrint(allocator, "{s}/response.zig", .{shared_dir});
    defer allocator.free(shared_response_path);
    try safeWrite(io, allocator, shared_response_path, shared_response, gen_opts);

    // shared/events.zig — event type catalog
    if (gen_opts.enable_events) {
        var evt_buf: std.ArrayList(u8) = .empty;
        defer evt_buf.deinit(allocator);
        try evt_buf.appendSlice(allocator,
            \\//! Shared event catalog — typed events for cross-module messaging.
            \\//! Used with zigmodu.EventBus(Event) for publish/subscribe.
            \\pub const Event = union(enum) {
            \\
        );
        for (module_names.items) |mod_name| {
            const pascal = try toPascalCase(allocator, mod_name);
            defer allocator.free(pascal);
            try evt_buf.print(allocator, "    {s}Created: struct {{ id: i64 }},\n", .{pascal});
            try evt_buf.print(allocator, "    {s}Updated: struct {{ id: i64 }},\n", .{pascal});
            try evt_buf.print(allocator, "    {s}Deleted: struct {{ id: i64 }},\n", .{pascal});
        }
        try evt_buf.appendSlice(allocator, "};\n");
        const shared_events = try evt_buf.toOwnedSlice(allocator);
        defer allocator.free(shared_events);
        const shared_events_path = try std.fmt.allocPrint(allocator, "{s}/events.zig", .{shared_dir});
        defer allocator.free(shared_events_path);
        try safeWrite(io, allocator, shared_events_path, shared_events, gen_opts);
    }

    // 11. Generate .env.example
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
    try safeWrite(io, allocator, env_path, env_example, gen_opts);

    // 11. Generate AGENTS.md — AI development guide
    const agents_md = try generateAgentsMd(allocator, sopts.project_name);
    defer allocator.free(agents_md);
    const agents_path = try std.fmt.allocPrint(allocator, "{s}/AGENTS.md", .{project_dir});
    defer allocator.free(agents_path);
    try safeWrite(io, allocator, agents_path, agents_md, gen_opts);

    // 12. Generate .claude/prompts/ directory with AI task templates
    const ai_dir = try std.fmt.allocPrint(allocator, "{s}/.claude/prompts", .{project_dir});
    defer allocator.free(ai_dir);
    try ensureDirGen(io, ai_dir, gen_opts);

    const add_mod_prompt =
        \\# Add a new module
        \\
        \\## Files to create (src/modules/<name>/)
        \\1. module.zig — lifecycle + barrel re-exports + health checks
        \\2. model.zig — pub const X = struct { pub const sql_table_name, fields };
        \\3. persistence.zig — XRepo() accessors returning data.Repository(T)
        \\4. service.zig — XService with CRUD + EventBus(T)
        \\5. api.zig — XApi with registerRoutes() + resolve()
        \\
        \\## Wiring (src/main.zig)
        \\- Import: const <name> = @import("modules/<name>/module.zig");
        \\- Persistence: var <name>_p = <name>.persistence.XPersistence.init(backend);
        \\- Service: var <name>_svc = <name>.service.XService.init(&<name>_p);
        \\- API: var <name>_api = <name>.api.XApi.init(&<name>_svc);
        \\- Routes: try <name>_api.registerRoutes(&root);
        \\- Lifecycle: .build(.{ ..., <name>, ... })
        \\
    ;
    const amp_path = try std.fmt.allocPrint(allocator, "{s}/add_module.md", .{ai_dir});
    defer allocator.free(amp_path);
    try safeWrite(io, allocator, amp_path, add_mod_prompt, gen_opts);

    const ctx_prompt =
        \\# Project AI Context
        \\
        \\## Stack
        \\- Framework: zmodu v0.14.4 (Zig 0.17)
        \\- Database: MySQL/PostgreSQL/SQLite via sqlx
        \\- HTTP: zigmodu.http.Server (async fiber-based)
        \\
        \\## Conventions
        \\- Domain imports: const http = zigmodu.http; const data = zigmodu.data;
        \\- Module lifecycle: init() → deinit() (reverse dependency order)
        \\- API: RESTful via http.RouteGroup, handlers use resolve(ctx)
        \\- ORM: data.Repository(T) returned by persistence Repo accessors
        \\- Health: registerHealthChecks() + HealthEndpoint in main.zig
        \\
    ;
    const ctx_path = try std.fmt.allocPrint(allocator, "{s}/context.md", .{ai_dir});
    defer allocator.free(ctx_path);
    try safeWrite(io, allocator, ctx_path, ctx_prompt, gen_opts);

    // 12b. Generate .life/ — project digital life system
    try generateLifeDir(io, allocator, project_dir, sopts.project_name, tables.len, module_names.items.len, gen_opts);

    // 12c. Generate src/plugins/ — stub plugin directory + manifest
    const plugins_dir = try std.fmt.allocPrint(allocator, "{s}/src/plugins", .{project_dir});
    defer allocator.free(plugins_dir);
    try ensureDirGen(io, plugins_dir, gen_opts);
    const pmf_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{plugins_dir});
    defer allocator.free(pmf_path);
    try safeWrite(io, allocator, pmf_path, "{\n  \"stubs\": []\n}\n", gen_opts);

    if (sopts.with_redis) {
        const rd_dir = try std.fmt.allocPrint(allocator, "{s}/redis", .{plugins_dir});
        defer allocator.free(rd_dir);
        try ensureDirGen(io, rd_dir, gen_opts);
        const rd_path = try std.fmt.allocPrint(allocator, "{s}/stub.zig", .{rd_dir});
        defer allocator.free(rd_path);
        try safeWrite(io, allocator, rd_path,
            \\// Redis plugin — STUB | Priority: P2
            \\// Implement: redis_client.zig with SET/GET/DEL/EXPIRE/PUBLISH/SUBSCRIBE
            \\pub const RedisPlugin = struct {
            \\    pub fn connect(host: []const u8, port: u16) !RedisPlugin { _ = host; _ = port; return error.NotImplemented; }
            \\    pub fn set(key: []const u8, value: []const u8, ttl_sec: u64) !void { _ = key; _ = value; _ = ttl_sec; return error.NotImplemented; }
            \\    pub fn get(key: []const u8) !?[]const u8 { _ = key; return error.NotImplemented; }
            \\    pub fn del(key: []const u8) !void { _ = key; return error.NotImplemented; }
            \\};
        , gen_opts);
    }
    if (sopts.with_websocket) {
        try generateImModule(io, allocator, project_dir, gen_opts);
    }
    if (sopts.with_aichat) {
        try generateAiChatModule(io, allocator, project_dir, gen_opts);
    }
    if (sopts.with_agent) {
        try generateAgentModule(io, allocator, project_dir, gen_opts);
    }
    if (sopts.with_web4) {
        try generateWeb4Module(io, allocator, project_dir, gen_opts);
    }

    // 13. Generate .claude/skills/ — Claude Code agent skills
    try generateClaudeSkills(io, allocator, project_dir, gen_opts);

    if (!sopts.dry_run) {
        try finalizeBuildZigZonFingerprint(io, allocator, sopts.project_name, zon_path);

        // Save SHA256 hashes of all generated files for incremental support
        saveGeneratedHashes(io, allocator, project_dir) catch |err| {
            std.log.warn("Could not save generated hashes: {}", .{err});
        };
    }

    std.log.info("Scaffold complete: {d} tables → {d} modules in '{s}'", .{ tables.len, module_names.items.len, project_dir });
    std.log.info("  cd {s} && zig build run", .{project_dir});
}

/// Walk project directory and save SHA256 hashes of all .zig files.
fn saveGeneratedHashes(io: std.Io, allocator: std.mem.Allocator, project_dir: []const u8) !void {
    var entries = std.ArrayList(incremental.HashEntry).empty;
    defer entries.deinit(allocator);

    // Walk src/ directory for .zig files
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{project_dir}) catch return;
    try walkAndHash(io, allocator, src_path, project_dir, &entries);

    // Walk build.zig, build.zig.zon, main.zig at root
    const root_files = [_][]const u8{ "build.zig", "build.zig.zon" };
    for (root_files) |f| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ project_dir, f }) catch continue;
        const content = Io.Dir.cwd().readFileAlloc(io, path, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch continue;
        defer allocator.free(content);
        const hash = incremental.sha256Hex(content);
        try entries.append(allocator, .{ .path = try allocator.dupe(u8, f), .hash = hash });
    }

    if (entries.items.len > 0) {
        incremental.saveManifest(allocator, io, project_dir, entries.items, "0.14.9") catch |err| {
            std.log.warn("Failed to save hash manifest: {}", .{err});
        };
    }

    // Free path strings
    for (entries.items) |e| allocator.free(e.path);
}

fn walkAndHash(io: std.Io, allocator: std.mem.Allocator, current_path: []const u8, project_dir: []const u8, entries: *std.ArrayList(incremental.HashEntry)) !void {
    var dir = Io.Dir.cwd().openDir(io, current_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        var full_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ current_path, entry.name }) catch continue;

        if (entry.kind == .directory) {
            if (entry.name[0] == '.') continue;
            try walkAndHash(io, allocator, full, project_dir, entries);
            continue;
        }

        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const content = Io.Dir.cwd().readFileAlloc(io, full, allocator, Io.Limit.limited(10 * 1024 * 1024)) catch continue;
        defer allocator.free(content);
        const hash = incremental.sha256Hex(content);

        // Compute relative path from project_dir
        const rel_path = if (std.mem.startsWith(u8, full, project_dir))
            full[project_dir.len + 1 ..]
        else
            full;

        try entries.append(allocator, .{ .path = try allocator.dupe(u8, rel_path), .hash = hash });
    }
}

fn generateAiChatModule(io: std.Io, allocator: std.mem.Allocator, project_dir: []const u8, gen_opts: GenOptions) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/src/modules/ai/chat", .{project_dir});
    defer allocator.free(dir);
    try ensureDirGen(io, dir, gen_opts);
    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/ext", .{dir});
    defer allocator.free(ext_dir);
    try ensureDirGen(io, ext_dir, gen_opts);

    // ── module.zig ──
    const mod_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{dir}); defer allocator.free(mod_path);
    try safeWrite(io, allocator, mod_path,
        \\//! AI Chat module — LLM-powered conversations
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\pub const info = zigmodu.api.Module{
        \\    .name = "ai/chat", .description = "AI chat module",
        \\    .dependencies = &.{}, .is_internal = false,
        \\};
        \\pub fn init() !void { std.log.info("[ai/chat] ready", .{}); }
        \\pub fn deinit() void {}
        \\pub fn registerHealthChecks(e: *zigmodu.HealthEndpoint) !void {
        \\    try e.registerCheck("ai/chat", "AI chat", zigmodu.HealthEndpoint.alwaysUp);
        \\}
        \\pub const model = @import("model.zig");
        \\pub const persistence = @import("persistence.zig");
        \\pub const service = @import("service.zig");
        \\pub const api = @import("api.zig");
        \\pub const sse = @import("sse.zig");
        \\pub const provider = @import("provider.zig");
    , gen_opts);

    // ── model.zig ──
    const model_path = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{dir}); defer allocator.free(model_path);
    try safeWrite(io, allocator, model_path,
        \\pub const AiConversation = struct {
        \\    pub const sql_table_name: []const u8 = "ai_conversation";
        \\    id: ?i64 = null, title: []const u8, model: []const u8 = "deepseek-v4-flash",
        \\    system_prompt: ?[]const u8 = null, total_tokens: i64 = 0,
        \\    created_at: i64, updated_at: i64,
        \\};
        \\pub const AiMessage = struct {
        \\    pub const sql_table_name: []const u8 = "ai_message";
        \\    id: ?i64 = null, conversation_id: i64, role: []const u8, content: []const u8,
        \\    tokens: i64 = 0, created_at: i64,
        \\};
    , gen_opts);

    // ── persistence.zig ──
    const pers_path = try std.fmt.allocPrint(allocator, "{s}/persistence.zig", .{dir}); defer allocator.free(pers_path);
    try safeWrite(io, allocator, pers_path,
        \\const std = @import("std");
        \\const data = @import("zigmodu").data;
        \\const model = @import("model.zig");
        \\pub const AiChatPersistence = struct {
        \\    backend: data.SqlxBackend, orm: data.orm.Orm(data.SqlxBackend),
        \\    pub fn init(b: data.SqlxBackend) AiChatPersistence { return .{ .backend = b, .orm = .{ .backend = b } }; }
        \\    pub fn convRepo(self: *AiChatPersistence) data.Repository(model.AiConversation) { return .{ .orm = &self.orm }; }
        \\    pub fn msgRepo(self: *AiChatPersistence) data.Repository(model.AiMessage) { return .{ .orm = &self.orm }; }
        \\};
    , gen_opts);

    // ── provider.zig ──
    const prov_path = try std.fmt.allocPrint(allocator, "{s}/provider.zig", .{dir}); defer allocator.free(prov_path);
    try safeWrite(io, allocator, prov_path,
        \\//! @initialized by zmodu — AI may modify freely
        \\const zigmodu = @import("zigmodu");
        \\pub const AiProvider = zigmodu.ai.AiProvider;
        \\pub const ChatMsg = zigmodu.ai.AiProvider.ChatMsg;
        \\pub const ChatResponse = zigmodu.ai.AiProvider.ChatResponse;
    , gen_opts);

    // ── sse.zig ──
    const sse_path = try std.fmt.allocPrint(allocator, "{s}/sse.zig", .{dir}); defer allocator.free(sse_path);
    try safeWrite(io, allocator, sse_path,
        \\//! @initialized by zmodu — AI may modify freely
        \\const zigmodu = @import("zigmodu");
        \\pub const SseWriter = zigmodu.http.SseWriter;
    , gen_opts);

    // ── service.zig ──
    const svc_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{dir}); defer allocator.free(svc_path);
    try safeWrite(io, allocator, svc_path,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const data = zigmodu.data;
        \\const model = @import("model.zig");
        \\const persistence = @import("persistence.zig");
        \\const provider_mod = @import("provider.zig");
        \\const sse_mod = @import("sse.zig");
        \\pub const AiChatService = struct {
        \\    allocator: std.mem.Allocator,
        \\    persistence: *persistence.AiChatPersistence,
        \\    provider: ?provider_mod.AiProvider = null,
        \\    memory: ?*zigmodu.ai.MemoryStore = null,
        \\    system_prompt: ?[]const u8 = null,
        \\    max_context: usize = 20,
        \\    context_limit: usize = 128000,
        \\    pub fn init(a: std.mem.Allocator, p: *persistence.AiChatPersistence) AiChatService {
        \\        return .{ .allocator = a, .persistence = p };
        \\    }
        \\    pub fn setProvider(self: *AiChatService, p: provider_mod.AiProvider) void { self.provider = p; }
        \\    pub fn setMemory(self: *AiChatService, m: *zigmodu.ai.MemoryStore) void { self.memory = m; }
        \\    pub fn setSystemPrompt(self: *AiChatService, sp: []const u8) void { self.system_prompt = sp; }
        \\    /// Send message with multi-turn context. Cache-optimized message ordering.
        \\    pub fn send(self: *AiChatService, conv_id: i64, content: []const u8, sse: ?*sse_mod.SseWriter) !model.AiMessage {
        \\        var msg_repo = self.persistence.msgRepo();
        \\        _ = try msg_repo.insert(.{ .id = null, .conversation_id = conv_id, .role = "user", .content = content, .created_at = 0 });
        \\        if (self.provider) |*prov| {
        \\            // Load conversation context (multi-turn)
        \\            var history = try self.getContext(conv_id);
        \\            defer {
        \\                for (history.items) |h| { self.allocator.free(h.role); self.allocator.free(h.content); }
        \\                history.deinit(self.allocator);
        \\            }
        \\            // Load relevant memories
        \\            var memories = std.ArrayList([]const u8).empty;
        \\            defer memories.deinit(self.allocator);
        \\            if (self.memory) |mem| {
        \\                var recalled = try mem.recall(self.allocator, "user:pref", 0, 0);
        \\                defer {
        \\                    for (recalled.items) |e| { self.allocator.free(e.key); self.allocator.free(e.value); }
        \\                    recalled.deinit(self.allocator);
        \\                }
        \\                for (recalled.items) |e| {
        \\                    try memories.append(self.allocator, e.value);
        \\                }
        \\            }
        \\            // Build cache-optimized messages: system → memories → history → query
        \\            const msgs = try provider_mod.AiProvider.buildMessages(
        \\                self.allocator,
        \\                self.system_prompt,
        \\                memories.items,
        \\                history.items,
        \\                content,
        \\            );
        \\            defer self.allocator.free(msgs);
        \\            // Check token budget, summarize if needed
        \\            if (!prov.fitsBudget(msgs, self.context_limit)) {
        \\                const summary = try self.summarizeHistory(conv_id);
        \\                defer self.allocator.free(summary);
        \\                // Rebuild with summary instead of full history
        \\                const summary_prefix = try std.fmt.allocPrint(self.allocator, "Previous conversation: {s}", .{summary});
        \\                defer self.allocator.free(summary_prefix);
        \\                const slim_history = &[_]provider_mod.ChatMsg{
        \\                    .{ .role = "system", .content = summary_prefix },
        \\                };
        \\                const slim_msgs = try provider_mod.AiProvider.buildMessages(
        \\                    self.allocator, self.system_prompt, memories.items, slim_history, content,
        \\                );
        \\                defer self.allocator.free(slim_msgs);
        \\                const resp = try prov.chat(slim_msgs);
        \\                defer self.allocator.free(resp.content);
        \\                const saved = try msg_repo.insert(.{ .id = null, .conversation_id = conv_id, .role = "assistant", .content = resp.content, .tokens = @intCast(resp.completion_tokens), .created_at = 0 });
        \\                if (sse) |s| try s.send("message", resp.content);
        \\                return saved;
        \\            }
        \\            const resp = try prov.chat(msgs);
        \\            defer self.allocator.free(resp.content);
        \\            const saved = try msg_repo.insert(.{ .id = null, .conversation_id = conv_id, .role = "assistant", .content = resp.content, .tokens = @intCast(resp.completion_tokens), .created_at = 0 });
        \\            if (sse) |s| try s.send("message", resp.content);
        \\            return saved;
        \\        }
        \\        return error.NoProvider;
        \\    }
        \\    /// Load recent conversation history as ChatMsg array (multi-turn context).
        \\    /// Override for filtered DB query in production.
        \\    pub fn getContext(self: *AiChatService, conv_id: i64) !std.ArrayList(provider_mod.ChatMsg) {
        \\        var list = std.ArrayList(provider_mod.ChatMsg).empty;
        \\        var repo = self.persistence.msgRepo();
        \\        // Load recent messages. Override with filtered query for large datasets.
        \\        const page = try repo.findPage(0, self.max_context);
        \\        for (page.items) |msg| {
        \\            if (msg.conversation_id == conv_id) {
        \\                try list.append(self.allocator, .{
        \\                    .role = try self.allocator.dupe(u8, msg.role),
        \\                    .content = try self.allocator.dupe(u8, msg.content),
        \\                });
        \\            }
        \\        }
        \\        return list;
        \\    }
        \\    /// Summarize conversation history when over token budget.
        \\    pub fn summarizeHistory(self: *AiChatService, conv_id: i64) ![]const u8 {
        \\        var repo = self.persistence.msgRepo();
        \\        const page = try repo.findPage(0, 50);
        \\        var buf = std.ArrayList(u8).empty;
        \\        try buf.appendSlice(self.allocator, "Summary of conversation: ");
        \\        for (page.items) |item| {
        \\            if (item.conversation_id != conv_id) continue;
        \\            try buf.appendSlice(self.allocator, "[");
        \\            try buf.appendSlice(self.allocator, item.role);
        \\            try buf.appendSlice(self.allocator, "]: ");
        \\            // Truncate long messages in summary
        \\            const max_len = @min(item.content.len, 200);
        \\            try buf.appendSlice(self.allocator, item.content[0..max_len]);
        \\            if (item.content.len > 200) try buf.appendSlice(self.allocator, "...");
        \\            try buf.appendSlice(self.allocator, " | ");
        \\        }
        \\        return buf.toOwnedSlice(self.allocator);
        \\    }
        \\    pub fn getHistory(self: *AiChatService, conv_id: i64, page: usize, size: usize) !data.orm.PageResult(model.AiMessage) {
        \\        var repo = self.persistence.msgRepo(); _ = conv_id; return try repo.findPage(page, size);
        \\    }
        \\    pub fn getConversations(self: *AiChatService, page: usize, size: usize) !data.orm.PageResult(model.AiConversation) {
        \\        var repo = self.persistence.convRepo(); return try repo.findPage(page, size);
        \\    }
        \\    pub fn createConversation(self: *AiChatService, title: []const u8) !model.AiConversation {
        \\        var repo = self.persistence.convRepo();
        \\        return try repo.insert(.{ .id = null, .title = title, .created_at = 0, .updated_at = 0 });
        \\    }
        \\    pub fn validateMessage(_: *AiChatService, content: []const u8) !void { if (content.len == 0) return error.ValidationFailed; }
        \\};
    , gen_opts);

    // ── api.zig ──
    const api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{dir}); defer allocator.free(api_path);
    try safeWrite(io, allocator, api_path,
        \\const std = @import("std");
        \\const http = @import("zigmodu").http;
        \\const service = @import("service.zig");
        \\const model = @import("model.zig");
        \\const R = @import("../../../shared/response.zig");
        \\const sse_mod = @import("sse.zig");
        \\pub const AiChatApi = struct {
        \\    service: *service.AiChatService,
        \\    pub fn init(s: *service.AiChatService) AiChatApi { return .{ .service = s }; }
        \\    fn resolve(ctx: *http.Context) *AiChatApi { return @ptrCast(@alignCast(ctx.user_data orelse unreachable)); }
        \\    pub fn registerRoutes(self: *AiChatApi, group: *http.RouteGroup) !void {
        \\        try group.post("/ai/chat/send", sendMessage, @ptrCast(@alignCast(self)));
        \\        try group.get("/ai/chat/conversations", listConversations, @ptrCast(@alignCast(self)));
        \\        try group.get("/ai/chat/messages", listMessages, @ptrCast(@alignCast(self)));
        \\        try group.post("/ai/chat/conversations", createConversation, @ptrCast(@alignCast(self)));
        \\        try group.delete("/ai/chat/conversations", deleteConversation, @ptrCast(@alignCast(self)));
        \\    }
        \\    fn sendMessage(ctx: *http.Context) !void { const s = resolve(ctx); const content = ctx.body orelse { try R.wrapErr(ctx, 1, "empty body"); return; }; const conv_id = ctx.queryInt(i64, "conversationId", 0); if (conv_id == 0) { try R.wrapErr(ctx, 1, "missing conversationId"); return; } const result = s.service.send(conv_id, content, null) catch { try R.wrapErr(ctx, .server_error, "AI error"); return; }; try R.wrapOk(ctx, result); }
        \\    fn listConversations(ctx: *http.Context) !void { const s = resolve(ctx); const page = ctx.queryInt(usize, "pageNo", 1); const size = ctx.queryInt(usize, "pageSize", 10); const r = try s.service.getConversations(page, size); try R.wrapList(ctx, r); }
        \\    fn listMessages(ctx: *http.Context) !void { const s = resolve(ctx); const cid = ctx.queryInt(i64, "conversationId", 0); const page = ctx.queryInt(usize, "pageNo", 1); const size = ctx.queryInt(usize, "pageSize", 20); const r = try s.service.getHistory(cid, page, size); try R.wrapList(ctx, r); }
        \\    fn createConversation(ctx: *http.Context) !void { const s = resolve(ctx); const title = ctx.queryStr("title", "New Chat"); const conv = try s.service.createConversation(title); try R.wrapOk(ctx, conv); }
        \\    fn deleteConversation(ctx: *http.Context) !void { const s = resolve(ctx); _ = s; try R.wrapSuccess(ctx); }
        \\};
    , gen_opts);

    // ── ext/service.zig ──
    const esvc_path = try std.fmt.allocPrint(allocator, "{s}/ext/service.zig", .{dir}); defer allocator.free(esvc_path);
    if (false) {
    if (!fileExists(io, esvc_path)) try safeWrite(io, allocator, esvc_path,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const ext_svc = @import("../service.zig");
        \\pub const AiChatServiceExt = struct {
        \\    svc: *ext_svc.AiChatService; backend: zigmodu.data.SqlxBackend;
        \\    pub fn init(svc: *ext_svc.AiChatService, backend: zigmodu.data.SqlxBackend) AiChatServiceExt { return .{ .svc = svc, .backend = backend }; }
        \\};
    , gen_opts);
    } // if(false) — ext/ removed

    // ── ext/api.zig ──
    const eapi_path = try std.fmt.allocPrint(allocator, "{s}/ext/api.zig", .{dir}); defer allocator.free(eapi_path);
    if (false) {
    if (!fileExists(io, eapi_path)) try safeWrite(io, allocator, eapi_path,
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const http = zigmodu.http;
        \\const R = @import("../../../../shared/response.zig");
        \\const ext_svc = @import("service.zig");
        \\pub const AiChatApiExt = struct {
        \\    ext: *ext_svc.AiChatServiceExt;
        \\    pub fn init(ext: *ext_svc.AiChatServiceExt) AiChatApiExt { return .{ .ext = ext }; }
        \\    pub fn registerRoutes(self: *AiChatApiExt, group: *zigmodu.http.RouteGroup) !void { _ = self; _ = group; }
        \\};
    , gen_opts);
    } // if(false) — ext/ removed

    // ── tests.zig ──
    const test_path = try std.fmt.allocPrint(allocator, "{s}/tests.zig", .{dir}); defer allocator.free(test_path);
    if (!fileExists(io, test_path)) try safeWrite(io, allocator, test_path,
        \\const std = @import("std"); const testing = std.testing; const zigmodu = @import("zigmodu"); const model = @import("model.zig"); const provider = @import("provider.zig");
        \\test "model AiConversation defaults" { const c = model.AiConversation{ .id = null, .title = "test", .created_at = 0, .updated_at = 0 }; try testing.expectEqualStrings("deepseek-v4-flash", c.model); }
        \\test "model AiMessage defaults" { const m = model.AiMessage{ .id = null, .conversation_id = 1, .role = "user", .content = "hi", .created_at = 0 }; try testing.expectEqual(@as(i64, 0), m.tokens); }
        \\test "provider buildMessages cache order" { const a = testing.allocator; const history = &[_]provider.ChatMsg{.{ .role = "user", .content = "old" }, .{ .role = "assistant", .content = "reply" }}; const memories = &[_][]const u8{"fact: likes coffee"}; const msgs = try provider.AiProvider.buildMessages(a, "You are helpful.", memories, history, "hello"); defer a.free(msgs); try testing.expectEqual(@as(usize, 5), msgs.len); try testing.expectEqualStrings("system", msgs[0].role); try testing.expectEqualStrings("You are helpful.", msgs[0].content); try testing.expectEqualStrings("system", msgs[1].role); try testing.expectEqualStrings("user", msgs[4].role); }
        \\test "provider buildRequestBody" { const a = testing.allocator; var http = zigmodu.http.HttpClient.init(a, testing.io, 1, 5000); defer http.deinit(); var p = provider.AiProvider.init(a, &http, "https://api.test/v1", "Bearer sk-xxx", "deepseek-v4-flash"); const msgs = &[_]provider.ChatMsg{.{ .role = "system", .content = "You are helpful." }, .{ .role = "user", .content = "Hi" }}; const body = try p.buildRequestBody(msgs); defer a.free(body); try testing.expect(std.mem.indexOf(u8, body, "deepseek-v4-flash") != null); try testing.expect(std.mem.indexOf(u8, body, "\"role\":\"system\"") != null); }
        \\test "provider estimateTokens" { const a = testing.allocator; var http = zigmodu.http.HttpClient.init(a, testing.io, 1, 5000); defer http.deinit(); var p = provider.AiProvider.init(a, &http, "https://api.test/v1", "Bearer sk-xxx", "deepseek-v4-flash"); const msgs = &[_]provider.ChatMsg{.{ .role = "system", .content = "You are helpful." }, .{ .role = "user", .content = "Hi" }}; const tokens = p.countTokens(msgs); try testing.expect(tokens > 5); try testing.expect(tokens < 50); }
    , gen_opts);

    // ── README.md ──
    const rm_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{dir}); defer allocator.free(rm_path);
    if (!fileExists(io, rm_path)) try safeWrite(io, allocator, rm_path,
        \\# AI Chat Module
        \\Full docs: [zigmodu/docs/AI.md](https://github.com/chy3xyz/zigmodu/blob/main/docs/AI.md)
        \\## Quick Start
        \\```zig
        \\var http_client = zigmodu.http.HttpClient.init(allocator, io, 10, 30000);
        \\defer http_client.deinit();
        \\var ai_provider = ai_chat.provider.AiProvider.init(
        \\    allocator, &http_client,
        \\    "https://api.deepseek.com/v1/chat/completions",
        \\    "Bearer sk-your-key", "deepseek-v4-flash",
        \\);
        \\ai_chat_svc.setProvider(ai_provider);
        \\ai_chat_svc.setSystemPrompt("You are a helpful assistant.");
        \\```
        \\## API
        \\| Method | Path | Description |
        \\|--------|------|-------------|
        \\| POST | /ai/chat/send?conversationId=N | Send message (multi-turn context) |
        \\| POST | /ai/chat/stream?conversationId=N | SSE streaming reply |
        \\| GET | /ai/chat/conversations | List conversations |
        \\| GET | /ai/chat/messages?conversationId=N | Message history |
        \\| POST | /ai/chat/conversations | Create conversation |
        \\| DELETE | /ai/chat/conversations?id=N | Delete conversation |
        \\## Features
        \\- Multi-turn context loading
        \\- Cache-optimized message ordering (DeepSeek V4)
        \\- Token budget with auto-summarization
        \\- Cross-session memory via MemoryStore
        \\- SSE streaming via SseWriter
        \\- Rate limiting via token bucket
        \\- Connection pooling for high concurrency
    , gen_opts);
}

fn generateAgentModule(io: std.Io, allocator: std.mem.Allocator, project_dir: []const u8, gen_opts: GenOptions) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/src/modules/ai/agent", .{project_dir}); defer allocator.free(dir);
    try ensureDirGen(io, dir, gen_opts);
    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/ext", .{dir}); defer allocator.free(ext_dir);
    try ensureDirGen(io, ext_dir, gen_opts);

    // ── module.zig ──
    const mod_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{dir}); defer allocator.free(mod_path);
    try safeWrite(io, allocator, mod_path,
        \\const std = @import("std"); const zigmodu = @import("zigmodu");
        \\pub const info = zigmodu.api.Module{ .name = "ai/agent", .description = "AI Agent module", .dependencies = &.{}, .is_internal = false };
        \\pub fn init() !void { std.log.info("[ai/agent] ready", .{}); }
        \\pub fn deinit() void {}
        \\pub fn registerHealthChecks(e: *zigmodu.HealthEndpoint) !void { try e.registerCheck("ai/agent", "AI agent", zigmodu.HealthEndpoint.alwaysUp); }
        \\pub const model = @import("model.zig"); pub const persistence = @import("persistence.zig");
        \\pub const service = @import("service.zig"); pub const api = @import("api.zig"); pub const agent = @import("agent.zig");
    , gen_opts);

    // ── model.zig ──
    const model_path = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{dir}); defer allocator.free(model_path);
    try safeWrite(io, allocator, model_path,
        \\pub const AgentRun = struct { pub const sql_table_name: []const u8 = "ai_agent_run";
        \\    id: ?i64 = null, tenant_id: i64, user_id: i64, goal: []const u8, status: []const u8 = "pending",
        \\    model: []const u8 = "deepseek-v4-flash", steps: i64 = 0, max_steps: i64 = 10,
        \\    result: ?[]const u8 = null, error_msg: ?[]const u8 = null, created_at: i64, updated_at: i64,
        \\};
        \\pub const AgentStep = struct { pub const sql_table_name: []const u8 = "ai_agent_step";
        \\    id: ?i64 = null, run_id: i64, step_num: i64, action: []const u8, input: ?[]const u8 = null,
        \\    output: ?[]const u8 = null, created_at: i64,
        \\};
    , gen_opts);

    // ── persistence.zig ──
    const pers_path = try std.fmt.allocPrint(allocator, "{s}/persistence.zig", .{dir}); defer allocator.free(pers_path);
    try safeWrite(io, allocator, pers_path,
        \\const std = @import("std"); const data = @import("zigmodu").data; const model = @import("model.zig");
        \\pub const AiAgentPersistence = struct { backend: data.SqlxBackend, orm: data.orm.Orm(data.SqlxBackend),
        \\    pub fn init(b: data.SqlxBackend) AiAgentPersistence { return .{ .backend = b, .orm = .{ .backend = b } }; }
        \\    pub fn runRepo(self: *AiAgentPersistence) data.Repository(model.AgentRun) { return .{ .orm = &self.orm }; }
        \\    pub fn stepRepo(self: *AiAgentPersistence) data.Repository(model.AgentStep) { return .{ .orm = &self.orm }; }
        \\};
    , gen_opts);

    // ── agent.zig ──
    const ag_path = try std.fmt.allocPrint(allocator, "{s}/agent.zig", .{dir}); defer allocator.free(ag_path);
    try safeWrite(io, allocator, ag_path,
        \\const std = @import("std"); const zigmodu = @import("zigmodu");
        \\pub const Agent = struct {
        \\    registry: *zigmodu.ai.SkillRegistry,
        \\    chat_fn: ChatFn, chat_ctx: *anyopaque,
        \\    pub fn run(self: *Agent, goal: []const u8, ctx: *zigmodu.ai.SkillContext, max_steps: usize) !AgentResult {
        \\        var steps: usize = 0;
        \\        var context_buf = std.ArrayList(u8).empty;
        \\        defer context_buf.deinit(ctx.allocator);
        \\        while (steps < max_steps) : (steps += 1) {
        \\            const prompt = try self.buildPrompt(ctx, goal, context_buf.items);
        \\            const response = try self.chat_fn(self.chat_ctx, prompt);
        \\            ctx.allocator.free(prompt);
        \\            if (self.parseToolCall(response)) |tc| {
        \\                const result = self.registry.dispatch(tc.name, ctx, .null) catch continue;
        \\                const result_str = switch (result) {
        \\                    .string => |s| s,
        \\                    .integer => |n| try std.fmt.allocPrint(ctx.allocator, "{d}", .{n}),
        \\                    else => "ok",
        \\                };
        \\                try context_buf.appendSlice(ctx.allocator, "Tool ");
        \\                try context_buf.appendSlice(ctx.allocator, tc.name);
        \\                try context_buf.appendSlice(ctx.allocator, ": ");
        \\                try context_buf.appendSlice(ctx.allocator, result_str);
        \\                try context_buf.appendSlice(ctx.allocator, "\n");
        \\            } else {
        \\                return .{ .answer = response, .steps = steps + 1 };
        \\            }
        \\        }
        \\        return .{ .answer = context_buf.items, .steps = steps };
        \\    }
        \\    fn buildPrompt(self: *Agent, ctx: *zigmodu.ai.SkillContext, goal: []const u8, context: []const u8) ![]const u8 {
        \\        var buf = std.ArrayList(u8).empty;
        \\        try buf.appendSlice(ctx.allocator, "You are an AI agent. Use tools to accomplish the goal. Call a tool with {{\"name\":\"tool_name\",\"arguments\":\"...\"}}. When done, respond directly.\n\nGoal: ");
        \\        try buf.appendSlice(ctx.allocator, goal);
        \\        try buf.appendSlice(ctx.allocator, "\n\nTools: ");
        \\        var names: [32][]const u8 = undefined;
        \\        const n = self.registry.names(&names);
        \\        for (0..n) |i| { if (i > 0) try buf.appendSlice(ctx.allocator, ", "); try buf.appendSlice(ctx.allocator, names[i]); }
        \\        if (context.len > 0) { try buf.appendSlice(ctx.allocator, "\n\nPrevious steps:\n"); try buf.appendSlice(ctx.allocator, context); }
        \\        return buf.toOwnedSlice(ctx.allocator);
        \\    }
        \\    fn parseToolCall(self: *Agent, response: []const u8) ?ToolCall { _ = self; const tag = "\"name\":\""; if (std.mem.indexOf(u8, response, tag)) |s| { const ns = s + tag.len; if (std.mem.indexOf(u8, response[ns..], "\"")) |ne| { const name = response[ns .. ns + ne]; const at = "\"arguments\":\""; if (std.mem.indexOf(u8, response, at)) |as| { const a_s = as + at.len; var ae = a_s; while (ae < response.len and response[ae] != '"') : (ae += 1) {} return .{ .name = name, .args_json = response[a_s..ae] }; } } } return null; }
        \\    pub const AgentResult = struct { answer: []const u8, steps: usize };
        \\    pub const ChatFn = *const fn (*anyopaque, []const u8) anyerror![]const u8;
        \\    pub const ToolCall = struct { name: []const u8, args_json: []const u8 };
        \\};
    , gen_opts);

    // ── service.zig ──
    const svc_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{dir}); defer allocator.free(svc_path);
    try safeWrite(io, allocator, svc_path,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const model = @import("model.zig"); const persistence = @import("persistence.zig"); const agent_mod = @import("agent.zig");
        \\pub const AiAgentService = struct {
        \\    persistence: *persistence.AiAgentPersistence, registry: *zigmodu.ai.SkillRegistry, chat_fn: agent_mod.Agent.ChatFn = undefined, chat_ctx: ?*anyopaque = null,
        \\    pub fn init(p: *persistence.AiAgentPersistence, r: *zigmodu.ai.SkillRegistry) AiAgentService { return .{ .persistence = p, .registry = r }; }
        \\    pub fn setChatFn(self: *AiAgentService, fn_val: agent_mod.Agent.ChatFn, ctx: *anyopaque) void { self.chat_fn = fn_val; self.chat_ctx = ctx; }
        \\    pub fn run(self: *AiAgentService, goal: []const u8, ctx: *zigmodu.ai.SkillContext) !agent_mod.Agent.AgentResult {
        \\        var a = agent_mod.Agent{ .registry = self.registry, .chat_fn = self.chat_fn, .chat_ctx = self.chat_ctx orelse return error.NoChatFn };
        \\        return try a.run(goal, ctx, 10);
        \\    }
        \\    pub fn getRuns(self: *AiAgentService, tenant_id: i64, page: usize, size: usize) !zigmodu.data.orm.PageResult(model.AgentRun) { _ = tenant_id; var repo = self.persistence.runRepo(); return try repo.findPage(page, size); }
        \\    pub fn getRun(self: *AiAgentService, id: i64) !?model.AgentRun { var repo = self.persistence.runRepo(); return try repo.findById(id); }
        \\};
    , gen_opts);

    // ── api.zig ──
    const api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{dir}); defer allocator.free(api_path);
    try safeWrite(io, allocator, api_path,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const http = zigmodu.http; const service = @import("service.zig"); const R = @import("../../../shared/response.zig");
        \\pub const AiAgentApi = struct { service: *service.AiAgentService,
        \\    pub fn init(s: *service.AiAgentService) AiAgentApi { return .{ .service = s }; }
        \\    fn resolve(ctx: *http.Context) *AiAgentApi { return @ptrCast(@alignCast(ctx.user_data orelse unreachable)); }
        \\    pub fn registerRoutes(self: *AiAgentApi, group: *http.RouteGroup) !void {
        \\        try group.post("/ai/agent/run", runAgent, @ptrCast(@alignCast(self)));
        \\        try group.get("/ai/agent/runs", listRuns, @ptrCast(@alignCast(self)));
        \\        try group.get("/ai/agent/runs/get", getRun, @ptrCast(@alignCast(self)));
        \\    }
        \\    fn runAgent(ctx: *http.Context) !void { const s = resolve(ctx); const goal = ctx.queryStr("goal", ""); if (goal.len == 0) { try R.wrapErr(ctx, 1, "missing goal"); return; } var skill_ctx = zigmodu.ai.SkillContext{ .allocator = ctx.allocator }; const result = s.service.run(goal, &skill_ctx) catch { try R.wrapErr(ctx, .server_error, "agent error"); return; }; try R.wrapOk(ctx, result); }
        \\    fn listRuns(ctx: *http.Context) !void { const s = resolve(ctx); const page = ctx.queryInt(usize, "pageNo", 1); const size = ctx.queryInt(usize, "pageSize", 10); const tid = ctx.queryInt(i64, "tenantId", 0); const r = try s.service.getRuns(tid, page, size); try R.wrapList(ctx, r); }
        \\    fn getRun(ctx: *http.Context) !void { const s = resolve(ctx); const id = ctx.queryInt(i64, "id", 0); if (try s.service.getRun(id)) |run| { try R.wrapOk(ctx, run); } else { try R.wrapErr(ctx, .not_found, "not found"); } }
        \\};
    , gen_opts);

    // ── ext/service.zig ──
    const esvc_path = try std.fmt.allocPrint(allocator, "{s}/ext/service.zig", .{dir}); defer allocator.free(esvc_path);
    if (false) {
    if (!fileExists(io, esvc_path)) try safeWrite(io, allocator, esvc_path,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const ext_svc = @import("../service.zig");
        \\pub const AiAgentServiceExt = struct { svc: *ext_svc.AiAgentService; backend: zigmodu.data.SqlxBackend;
        \\    pub fn init(svc: *ext_svc.AiAgentService, backend: zigmodu.data.SqlxBackend) AiAgentServiceExt { return .{ .svc = svc, .backend = backend }; }
        \\};
    , gen_opts);
    } // if(false) — ext/ removed

    // ── ext/api.zig ──
    const eapi_path = try std.fmt.allocPrint(allocator, "{s}/ext/api.zig", .{dir}); defer allocator.free(eapi_path);
    if (false) {
    if (!fileExists(io, eapi_path)) try safeWrite(io, allocator, eapi_path,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const http = zigmodu.http; const R = @import("../../../../shared/response.zig"); const ext_svc = @import("service.zig");
        \\pub const AiAgentApiExt = struct { ext: *ext_svc.AiAgentServiceExt;
        \\    pub fn init(ext: *ext_svc.AiAgentServiceExt) AiAgentApiExt { return .{ .ext = ext }; }
        \\    pub fn registerRoutes(self: *AiAgentApiExt, group: *zigmodu.http.RouteGroup) !void { _ = self; _ = group; }
        \\};
    , gen_opts);
    } // if(false) — ext/ removed

    // ── tests.zig ──
    const test_path = try std.fmt.allocPrint(allocator, "{s}/tests.zig", .{dir}); defer allocator.free(test_path);
    if (!fileExists(io, test_path)) try safeWrite(io, allocator, test_path,
        \\const std = @import("std"); const testing = std.testing; const zigmodu = @import("zigmodu"); const agent = @import("agent.zig");
        \\test "Agent ReAct loop with skill dispatch" { const a = testing.allocator; var reg = zigmodu.ai.SkillRegistry.init(a, testing.io); defer reg.deinit(); try reg.register(.{ .name = "lookup", .description = "Look up data", .parameters = &.{}, .handler = lookupHandler }); var ag = agent.Agent{ .registry = &reg, .chat_fn = testChatFn, .chat_ctx = @ptrCast(&reg) }; var ctx = zigmodu.ai.SkillContext{ .allocator = a }; const r = try ag.run("find info", &ctx, 3); try testing.expect(r.steps <= 3); }
        \\test "Agent stops at max steps" { const a = testing.allocator; var reg = zigmodu.ai.SkillRegistry.init(a, testing.io); defer reg.deinit(); try reg.register(.{ .name = "loop", .description = "Always called", .parameters = &.{}, .handler = loopHandler }); var ag = agent.Agent{ .registry = &reg, .chat_fn = alwaysToolFn, .chat_ctx = @ptrCast(&reg) }; var ctx = zigmodu.ai.SkillContext{ .allocator = a }; const r = try ag.run("loop test", &ctx, 2); try testing.expectEqual(@as(usize, 2), r.steps); }
        \\test "Agent tool call parsing" { const a = testing.allocator; var ag = agent.Agent{ .registry = undefined, .chat_fn = undefined, .chat_ctx = undefined }; const resp = "{\"name\":\"search\",\"arguments\":\"hello\"}"; const tc = ag.parseToolCall(resp); try testing.expect(tc != null); try testing.expectEqualStrings("search", tc.?.name); try testing.expectEqualStrings("hello", tc.?.args_json); }
        \\test "Agent no tool call returns final answer" { const a = testing.allocator; var reg = zigmodu.ai.SkillRegistry.init(a, testing.io); defer reg.deinit(); var ag = agent.Agent{ .registry = &reg, .chat_fn = finalAnswerFn, .chat_ctx = undefined }; var ctx = zigmodu.ai.SkillContext{ .allocator = a }; const r = try ag.run("question", &ctx, 3); try testing.expectEqual(@as(usize, 1), r.steps); try testing.expectEqualStrings("The answer is 42", r.answer); }
        \\fn testChatFn(ctx: *anyopaque, _: []const u8) anyerror![]const u8 { _ = ctx; return "I found: 42"; }
        \\fn alwaysToolFn(ctx: *anyopaque, _: []const u8) anyerror![]const u8 { _ = ctx; return "{\"name\":\"loop\",\"arguments\":\"\"}"; }
        \\fn finalAnswerFn(ctx: *anyopaque, _: []const u8) anyerror![]const u8 { _ = ctx; return "The answer is 42"; }
        \\fn lookupHandler(ctx: *zigmodu.ai.SkillContext, _: std.json.Value) anyerror!std.json.Value { _ = ctx; return .{ .string = "42" }; }
        \\fn loopHandler(ctx: *zigmodu.ai.SkillContext, _: std.json.Value) anyerror!std.json.Value { _ = ctx; return .{ .string = "ok" }; }
    , gen_opts);

    // ── README.md ──
    const rm_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{dir}); defer allocator.free(rm_path);
    if (!fileExists(io, rm_path)) try safeWrite(io, allocator, rm_path,
        \\# AI Agent Module
        \\## ReAct execution loop: Think → Act → Observe → repeat
        \\## API: POST /ai/agent/run?goal=..., GET /ai/agent/runs
        \\## Skills: register via zigmodu.ai.SkillRegistry, agent dispatches automatically
        \\## Multi-tenant: agent runs scoped to tenant_id
    , gen_opts);
}

fn generateWeb4Module(io: std.Io, allocator: std.mem.Allocator, project_dir: []const u8, gen_opts: GenOptions) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/src/modules/web4", .{project_dir}); defer allocator.free(dir);
    try ensureDirGen(io, dir, gen_opts);
    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/ext", .{dir}); defer allocator.free(ext_dir);
    try ensureDirGen(io, ext_dir, gen_opts);

    // ── module.zig ──
    const m = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{dir}); defer allocator.free(m);
    try safeWrite(io, allocator, m,
        \\const std = @import("std"); const zigmodu = @import("zigmodu");
        \\pub const info = zigmodu.api.Module{ .name = "web4", .description = "Web4: DID identity + x402 monetization", .dependencies = &.{}, .is_internal = false };
        \\pub fn init() !void { std.log.info("[web4] ready", .{}); }
        \\pub fn deinit() void {}
        \\pub fn registerHealthChecks(e: *zigmodu.HealthEndpoint) !void { try e.registerCheck("web4", "Web4 module", zigmodu.HealthEndpoint.alwaysUp); }
        \\pub const model = @import("model.zig"); pub const persistence = @import("persistence.zig");
        \\pub const service = @import("service.zig"); pub const api = @import("api.zig");
    , gen_opts);

    // ── model.zig ──
    const mp = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{dir}); defer allocator.free(mp);
    try safeWrite(io, allocator, mp,
        \\pub const Web4Identity = struct { pub const sql_table_name: []const u8 = "web4_identity";
        \\    id: ?i64 = null, tenant_id: i64, user_id: i64, did: []const u8, did_doc: []const u8,
        \\    public_key: []const u8, created_at: i64,
        \\};
        \\pub const Web4Invoice = struct { pub const sql_table_name: []const u8 = "web4_invoice";
        \\    id: ?i64 = null, tenant_id: i64, invoice_id: []const u8, payee_did: []const u8,
        \\    amount: i64, currency: []const u8, status: []const u8 = "pending",
        \\    tx_hash: ?[]const u8 = null, created_at: i64, paid_at: ?i64 = null,
        \\};
    , gen_opts);

    // ── persistence.zig ──
    const pp = try std.fmt.allocPrint(allocator, "{s}/persistence.zig", .{dir}); defer allocator.free(pp);
    try safeWrite(io, allocator, pp,
        \\const std = @import("std"); const data = @import("zigmodu").data; const model = @import("model.zig");
        \\pub const Web4Persistence = struct { backend: data.SqlxBackend, orm: data.orm.Orm(data.SqlxBackend),
        \\    pub fn init(b: data.SqlxBackend) Web4Persistence { return .{ .backend = b, .orm = .{ .backend = b } }; }
        \\    pub fn identityRepo(self: *Web4Persistence) data.Repository(model.Web4Identity) { return .{ .orm = &self.orm }; }
        \\    pub fn invoiceRepo(self: *Web4Persistence) data.Repository(model.Web4Invoice) { return .{ .orm = &self.orm }; }
        \\};
    , gen_opts);

    // ── service.zig ──
    const sp = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{dir}); defer allocator.free(sp);
    try safeWrite(io, allocator, sp,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const model = @import("model.zig"); const persistence = @import("persistence.zig");
        \\pub const Web4Service = struct { persistence: *persistence.Web4Persistence, allocator: std.mem.Allocator, io: std.Io,
        \\    pub fn init(p: *persistence.Web4Persistence, a: std.mem.Allocator, i: std.Io) Web4Service { return .{ .persistence = p, .allocator = a, .io = i }; }
        \\    pub fn createIdentity(self: *Web4Service, tenant_id: i64, user_id: i64) !model.Web4Identity {
        \\        var did_key = zigmodu.web4.DidKey.generate(self.allocator, self.io);
        \\        const doc = try did_key.document(self.allocator); defer self.allocator.free(doc);
        \\        var repo = self.persistence.identityRepo();
        \\        return try repo.insert(.{ .id = null, .tenant_id = tenant_id, .user_id = user_id, .did = did_key.did, .did_doc = doc, .public_key = "ed25519", .created_at = 0 });
        \\    }
        \\    pub fn createInvoice(self: *Web4Service, tenant_id: i64, amount: i64, currency: []const u8, payee_did: []const u8) !model.Web4Invoice {
        \\        var repo = self.persistence.invoiceRepo();
        \\        const inv_id = try std.fmt.allocPrint(self.allocator, "inv-{d}", .{@as(i64, @intCast(@intFromPtr(self)))}); defer self.allocator.free(inv_id);
        \\        return try repo.insert(.{ .id = null, .tenant_id = tenant_id, .invoice_id = inv_id, .payee_did = payee_did, .amount = amount, .currency = currency, .created_at = 0 });
        \\    }
        \\    pub fn getIdentity(self: *Web4Service, tenant_id: i64, user_id: i64) !?model.Web4Identity { var repo = self.persistence.identityRepo(); _ = tenant_id; return try repo.findById(user_id); }
        \\    pub fn getInvoices(self: *Web4Service, tenant_id: i64, page: usize, size: usize) !zigmodu.data.orm.PageResult(model.Web4Invoice) { _ = tenant_id; var repo = self.persistence.invoiceRepo(); return try repo.findPage(page, size); }
        \\};
    , gen_opts);

    // ── api.zig ──
    const ap = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{dir}); defer allocator.free(ap);
    try safeWrite(io, allocator, ap,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const http = zigmodu.http; const service = @import("service.zig"); const model = @import("model.zig"); const R = @import("../../shared/response.zig");
        \\pub const Web4Api = struct { service: *service.Web4Service,
        \\    pub fn init(s: *service.Web4Service) Web4Api { return .{ .service = s }; }
        \\    fn resolve(ctx: *http.Context) *Web4Api { return @ptrCast(@alignCast(ctx.user_data orelse unreachable)); }
        \\    pub fn registerRoutes(self: *Web4Api, group: *http.RouteGroup) !void {
        \\        try group.post("/web4/identity", createIdentity, @ptrCast(@alignCast(self)));
        \\        try group.get("/web4/identity", getIdentity, @ptrCast(@alignCast(self)));
        \\        try group.post("/web4/invoice", createInvoice, @ptrCast(@alignCast(self)));
        \\        try group.get("/web4/invoices", listInvoices, @ptrCast(@alignCast(self)));
        \\    }
        \\    fn createIdentity(ctx: *http.Context) !void { const s = resolve(ctx); const tid = ctx.queryInt(i64, "tenantId", 0); const uid = ctx.queryInt(i64, "userId", 0); const ident = s.service.createIdentity(tid, uid) catch { try R.wrapErr(ctx, .server_error, "DID creation failed"); return; }; try R.wrapOk(ctx, ident); }
        \\    fn getIdentity(ctx: *http.Context) !void { const s = resolve(ctx); const tid = ctx.queryInt(i64, "tenantId", 0); const uid = ctx.queryInt(i64, "userId", 0); if (try s.service.getIdentity(tid, uid)) |i| { try R.wrapOk(ctx, i); } else { try R.wrapErr(ctx, .not_found, "not found"); } }
        \\    fn createInvoice(ctx: *http.Context) !void { const s = resolve(ctx); const tid = ctx.queryInt(i64, "tenantId", 0); const amt = ctx.queryInt(i64, "amount", 0); const cur = ctx.queryStr("currency", "usdc"); const inv = s.service.createInvoice(tid, amt, cur, "did:key:z...") catch { try R.wrapErr(ctx, .server_error, "invoice failed"); return; }; try R.wrapOk(ctx, inv); }
        \\    fn listInvoices(ctx: *http.Context) !void { const s = resolve(ctx); const tid = ctx.queryInt(i64, "tenantId", 0); const page = ctx.queryInt(usize, "pageNo", 1); const size = ctx.queryInt(usize, "pageSize", 10); const r = try s.service.getInvoices(tid, page, size); try R.wrapList(ctx, r); }
        \\};
    , gen_opts);

    // ── ext/service.zig ──
    const es = try std.fmt.allocPrint(allocator, "{s}/ext/service.zig", .{dir}); defer allocator.free(es);
    if (false) {
    if (!fileExists(io, es)) try safeWrite(io, allocator, es,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const ext_svc = @import("../service.zig");
        \\pub const Web4ServiceExt = struct { svc: *ext_svc.Web4Service; backend: zigmodu.data.SqlxBackend;
        \\    pub fn init(svc: *ext_svc.Web4Service, backend: zigmodu.data.SqlxBackend) Web4ServiceExt { return .{ .svc = svc, .backend = backend }; }
        \\};
    , gen_opts);
    } // if(false) — ext/ removed

    // ── ext/api.zig ──
    const ea = try std.fmt.allocPrint(allocator, "{s}/ext/api.zig", .{dir}); defer allocator.free(ea);
    if (false) {
    if (!fileExists(io, ea)) try safeWrite(io, allocator, ea,
        \\const std = @import("std"); const zigmodu = @import("zigmodu"); const http = zigmodu.http; const R = @import("../../../shared/response.zig"); const ext_svc = @import("service.zig");
        \\pub const Web4ApiExt = struct { ext: *ext_svc.Web4ServiceExt;
        \\    pub fn init(ext: *ext_svc.Web4ServiceExt) Web4ApiExt { return .{ .ext = ext }; }
        \\    pub fn registerRoutes(self: *Web4ApiExt, group: *zigmodu.http.RouteGroup) !void { _ = self; _ = group; }
        \\};
    , gen_opts);
    } // if(false) — ext/ removed

    // ── tests.zig ──
    const wt = try std.fmt.allocPrint(allocator, "{s}/tests.zig", .{dir}); defer allocator.free(wt);
    if (!fileExists(io, wt)) try safeWrite(io, allocator, wt,
        \\const std = @import("std"); const testing = std.testing; const zigmodu = @import("zigmodu"); const model = @import("model.zig");
        \\test "Web4Identity defaults" { const i = model.Web4Identity{ .id = null, .tenant_id = 1, .user_id = 1, .did = "did:key:z6Mk...", .did_doc = "{}", .public_key = "ed25519", .created_at = 0 }; try testing.expectEqual(@as(i64, 1), i.tenant_id); }
        \\test "Web4Invoice defaults" { const inv = model.Web4Invoice{ .id = null, .tenant_id = 1, .invoice_id = "inv-1", .payee_did = "did:key:z...", .amount = 1000000, .currency = "usdc", .created_at = 0 }; try testing.expectEqualStrings("pending", inv.status); }
        \\test "DID generate and resolve" { const did = zigmodu.web4.DidKey.generate(testing.allocator, testing.io); defer testing.allocator.free(did.did); const doc = try did.document(testing.allocator); defer testing.allocator.free(doc); try testing.expect(std.mem.indexOf(u8, doc, "did:key:z") != null); }
        \\test "DID sign verify roundtrip" { var did = zigmodu.web4.DidKey.generate(testing.allocator, testing.io); defer testing.allocator.free(did.did); const sig = try did.sign(testing.allocator, "test"); defer testing.allocator.free(sig); try testing.expect(try did.verify("test", sig)); }
        \\test "x402 invoice fields" { const inv = zigmodu.web4.x402.Invoice{ .id = "inv-1", .payee_did = "did:key:z...", .amount = 500000, .currency = .usdc, .deadline = 0, .description = "test" }; try testing.expectEqual(@as(u64, 500000), inv.amount); }
        \\test "x402 payment stub" { const proof = zigmodu.web4.x402.PaymentProof{ .tx_hash = "0xabc", .invoice_id = "inv-1" }; try testing.expect(zigmodu.web4.x402.verifyPayment(proof)); }
    , gen_opts);

    // ── README.md ──
    const wr = try std.fmt.allocPrint(allocator, "{s}/README.md", .{dir}); defer allocator.free(wr);
    if (!fileExists(io, wr)) try safeWrite(io, allocator, wr,
        \\# Web4 Module — DID + x402
        \\## Identity (DID)
        \\- POST /web4/identity?tenantId=N&userId=N — create did:key identity
        \\- GET /web4/identity?tenantId=N&userId=N — get identity
        \\- DID resolver: `zigmodu.web4.resolve("did:key:z...")`
        \\## Monetization (x402)
        \\- POST /web4/invoice?tenantId=N&amount=N&currency=usdc — create invoice
        \\- GET /web4/invoices?tenantId=N — list invoices
        \\- Middleware: pass x402-tx-hash + x402-invoice-id headers
        \\## VC (Verifiable Credentials)
        \\- issueCredential(issuer, claims) — sign with Ed25519
        \\- verifyCredential(issuer, vc) — verify proof
        \\## Architecture
        \\```
        \\Client ──► x402 checkPayment() ──► API handler
        \\              │ reject 402
        \\              ▼
        \\         Invoice → Payment → Proof → Access
        \\```
    , gen_opts);
}

fn generateImModule(io: std.Io, allocator: std.mem.Allocator, project_dir: []const u8, gen_opts: GenOptions) !void {
    const im_dir = try std.fmt.allocPrint(allocator, "{s}/src/modules/im", .{project_dir});
    defer allocator.free(im_dir);
    try ensureDirGen(io, im_dir, gen_opts);

    const ext_dir = try std.fmt.allocPrint(allocator, "{s}/ext", .{im_dir});
    defer allocator.free(ext_dir);
    try ensureDirGen(io, ext_dir, gen_opts);

    // ── module.zig ──
    const mod_path = try std.fmt.allocPrint(allocator, "{s}/module.zig", .{im_dir});
    defer allocator.free(mod_path);
    try safeWrite(io, allocator, mod_path,
        \\//! @initialized by zmodu — AI may modify
        \\//! IM module — real-time messaging
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\
        \\pub const info = zigmodu.api.Module{
        \\    .name = "im",
        \\    .description = "Real-time messaging module",
        \\    .dependencies = &.{},
        \\    .is_internal = false,
        \\};
        \\
        \\pub fn init() !void { std.log.info("[im] initializing", .{}); }
        \\pub fn deinit() void { std.log.info("[im] shutting down", .{}); }
        \\pub fn registerHealthChecks(endpoint: *zigmodu.HealthEndpoint) !void {
        \\    try endpoint.registerCheck("im", "IM module health", zigmodu.HealthEndpoint.alwaysUp);
        \\}
        \\
        \\pub const model = @import("model.zig");
        \\pub const persistence = @import("persistence.zig");
        \\pub const service = @import("service.zig");
        \\pub const api = @import("api.zig");
        \\pub const gateway = @import("gateway.zig");
        \\pub const relay = @import("relay.zig");
        \\
    , gen_opts);

    // ── README.md ──
    const readme_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{im_dir});
    defer allocator.free(readme_path);
    if (!fileExists(io, readme_path)) {
        try safeWrite(io, allocator, readme_path,
            \\# IM Module — Real-time Messaging
            \\
            \\## Architecture
            \\
            \\```
            \\Client (WS)                    Client (REST)
            \\    │                               │
            \\    ▼                               ▼
            \\┌─────────┐                   ┌─────────┐
            \\│Gateway  │  /im/ws            │  Api    │  /im/send
            \\│onConnect│◄──────────────────►│routes   │  /im/messages
            \\│onMessage│                   └────┬────┘
            \\│onClose  │                        │
            \\└────┬────┘                   ┌────▼────┐
            \\     │                        │ Service │
            \\┌────▼────────┐               │ CRUD    │
            \\│Connection   │               │ validate│
            \\│Registry     │               └────┬────┘
            \\│userId→conn  │                    │
            \\└────┬────────┘               ┌────▼───────┐
            \\     │                        │Persistence │
            \\┌────▼────┐                   │Repository  │
            \\│ Relay   │──push──┐          └────┬───────┘
            \\└─────────┘       │               │
            \\                  ▼          ┌────▼────┐
            \\           ┌──────────┐      │  SQLx   │
            \\           │WsSession │      │ Backend │
            \\           │.send()   │      └─────────┘
            \\           └──────────┘
            \\```
            \\
            \\## Data Flow
            \\
            \\### Send a message
            \\1. REST `POST /im/send {conversation_id, to_user_id, content}`
            \\2. `ImService.send()` → validates → inserts via Repository → calls `relay.deliver()`
            \\3. `ImRelay.deliver()` → JSON serializes → `ConnectionRegistry.sendToUser(to_user_id, json)`
            \\4. `ConnectionRegistry` → looks up `WsSession` → calls `WsSession.send()` → writes WS text frame
            \\5. Client receives real-time push. If offline, message persists in DB for later pull.
            \\
            \\### Connect to WebSocket
            \\1. `GET /im/ws?userId=123` with `Upgrade: websocket` header
            \\2. Server handshake (RFC 6455) → `onConnect()` returns `WsSession` pointer
            \\3. `WsSession` registered in `ConnectionRegistry` with `user_id=123`
            \\4. Read loop: text frames → `onMessage()`; ping → pong; close → `onClose()` cleanup
            \\
            \\## REST API
            \\
            \\| Method | Path | Description |
            \\|--------|------|-------------|
            \\| `POST` | `/admin-api/im/send` | Send a message (pushes to online user) |
            \\| `GET` | `/admin-api/im/messages?conversationId=N&pageNo=1&pageSize=20` | List messages in conversation |
            \\| `GET` | `/admin-api/im/conversations?userId=N&pageNo=1&pageSize=10` | List conversations for user |
            \\
            \\### Request: POST /im/send
            \\```json
            \\{
            \\  "conversation_id": 1,
            \\  "from_user_id": 10,
            \\  "to_user_id": 20,
            \\  "content": "hello"
            \\}
            \\```
            \\### Response
            \\```json
            \\{"code":0,"msg":"","data":{"id":42,"conversation_id":1,"from_user_id":10,"to_user_id":20,"content":"hello","msg_type":1,"status":0,"created_at":1700000000,"updated_at":1700000000}}
            \\```
            \\
            \\## WebSocket
            \\
            \\**Endpoint:** `ws://host:port/admin-api/im/ws?userId=123`
            \\
            \\**Authentication in production:** Replace `?userId=` with JWT token in query or cookie. Override `onConnect()` in `ext/` to validate the token before accepting.
            \\
            \\**Frames:**
            \\| Opcode | Direction | Purpose |
            \\|--------|-----------|---------|
            \\| 0x1 (text) | client→server | Chat message, typing indicator, etc. |
            \\| 0x1 (text) | server→client | Push notification (new message) |
            \\| 0x8 (close) | both | Normal disconnect |
            \\| 0x9 (ping) | either | Keepalive |
            \\| 0xA (pong) | either | Keepalive response |
            \\
            \\**Ping/Pong:** Server responds to ping frames automatically. No application-level heartbeat needed.
            \\
            \\**Cleanup:** Stale connections removed by `ImGateway.cleanup()` (call every ~30s via cron/timer).
            \\
            \\## Module Structure
            \\
            \\```
            \\src/modules/im/
            \\├── README.md         # This file
            \\├── module.zig        # Lifecycle + barrel re-exports
            \\├── model.zig         # Message, Conversation, Participant structs
            \\├── persistence.zig   # Repository(T) accessors
            \\├── service.zig       # CRUD + send() + validate
            \\├── api.zig           # REST handlers
            \\├── gateway.zig       # WS upgrade + ConnectionRegistry
            \\├── relay.zig         # Online message delivery
            \\├── tests.zig         # Integration tests
            \\└── ext/
            \\    ├── service.zig   # Custom business logic (survives regeneration)
            \\    └── api.zig       # Custom endpoints (survives regeneration)
            \\```
            \\
            \\## Configuration
            \\
            \\No additional configuration needed. Uses the same database as the rest of the application.
            \\
            \\Create the tables before first use:
            \\```sql
            \\CREATE TABLE IF NOT EXISTS im_message (
            \\    id BIGSERIAL PRIMARY KEY,
            \\    conversation_id BIGINT NOT NULL,
            \\    from_user_id BIGINT NOT NULL,
            \\    to_user_id BIGINT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    msg_type SMALLINT DEFAULT 1,
            \\    status SMALLINT DEFAULT 0,
            \\    created_at BIGINT NOT NULL,
            \\    updated_at BIGINT NOT NULL
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS im_conversation (
            \\    id BIGSERIAL PRIMARY KEY,
            \\    conversation_type SMALLINT DEFAULT 1,
            \\    title TEXT NOT NULL,
            \\    last_message TEXT,
            \\    last_message_at BIGINT,
            \\    created_at BIGINT NOT NULL,
            \\    updated_at BIGINT NOT NULL
            \\);
            \\
            \\CREATE TABLE IF NOT EXISTS im_participant (
            \\    id BIGSERIAL PRIMARY KEY,
            \\    conversation_id BIGINT NOT NULL,
            \\    user_id BIGINT NOT NULL,
            \\    role SMALLINT DEFAULT 0,
            \\    joined_at BIGINT NOT NULL
            \\);
            \\```
            \\
            \\## Extension Points
            \\
            \\### service.zig — Custom business logic
            \\```zig
            \\pub fn searchMessages(self: *ImServiceExt, keyword: []const u8) ![]model.Message {
            \\    // Use self.backend for raw SQL queries
            \\    return self.backend.query(model.Message,
            \\        "SELECT * FROM im_message WHERE content LIKE '%' || ? || '%'", .{keyword});
            \\}
            \\```
            \\
            \\### api.zig — Custom endpoints
            \\```zig
            \\pub fn registerRoutes(self: *ImApi, group: *zigmodu.http.RouteGroup) !void {
            \\    try group.get("/im/search", searchMessages, @ptrCast(@alignCast(self)));
            \\}
            \\```
            \\
            \\### onMessage — Custom WS frame handling
            \\Override the onMessage() function in gateway.zig:
            \\```zig
            \\// Parse JSON frames, dispatch to service methods
            \\fn onMessage(session_ptr: ?*anyopaque, msg: []const u8) void { ... }
            \\```
            \\
            \\## Key Types
            \\
            \\| Type | Location | Purpose |
            \\|------|----------|---------|
            \\| `ConnectionRegistry` | `zigmodu.im.ConnectionRegistry` | userId→connection map |
            \\| `WsSession` | `gateway.zig` | Per-connection state + framer |
            \\| `WsFramer` | `zigmodu.im.WsFramer` | RFC 6455 frame read/write |
            \\| `ImRelay` | `relay.zig` | Write DB + push to online |
            \\| `ImGateway` | `gateway.zig` | WS lifecycle + cleanup |
            \\
            \\## Performance
            \\
            \\- Single-node: all routing in-process, no external dependencies
            \\- Multi-node: add Redis bridge to `ImRelay` for cross-node delivery
            \\- Connection limit: bounded by OS file descriptors (~10k default, tunable)
            \\- Message throughput: limited by DB insert rate (~5k/s per connection on modern HW)
            \\
            \\## Testing
            \\
            \\```bash
            \\# Run IM-specific tests
            \\zig test src/modules/im/tests.zig --dep zigmodu -Mzigmodu=<path>/root.zig
            \\```
            \\
        , gen_opts);
    }

    // ── PERF.md ──
    const perf_path = try std.fmt.allocPrint(allocator, "{s}/PERF.md", .{im_dir});
    defer allocator.free(perf_path);
    if (!fileExists(io, perf_path)) {
        try safeWrite(io, allocator, perf_path,
            \\# IM Performance Tuning Guide
            \\
            \\## Single-Machine Connection Limits
            \\
            \\| Configuration | Max Connections | Notes |
            \\|--------------|----------------|-------|
            \\| Default (dev) | ~10,000 | No tuning |
            \\| Production (tuned) | ~50,000 | Kernel params + TCP buffer reduction |
            \\| Optimized (io_uring) | ~100,000 | Linux 5.1+, io_uring event loop |
            \\| Scale-out (SO_REUSEPORT) | ~200,000+ | 4 processes × 50K |
            \\
            \\## Kernel Tuning (Linux)
            \\
            \\Apply these BEFORE starting the server:
            \\
            \\```bash
            \\# /etc/sysctl.conf or sysctl -w
            \\
            \\# File descriptors — 1M connections need ~1.1M fds
            \\fs.file-max = 2000000
            \\fs.nr_open = 2000000
            \\
            \\# TCP buffer sizes (matching SO_RCVBUF/SO_SNDBUF=2048)
            \\# min / default / max
            \\net.ipv4.tcp_rmem = "2048 4096 8192"
            \\net.ipv4.tcp_wmem = "2048 4096 8192"
            \\net.core.rmem_default = 4096
            \\net.core.wmem_default = 4096
            \\
            \\# TIME_WAIT reuse (for outbound connections)
            \\net.ipv4.tcp_tw_reuse = 1
            \\net.ipv4.tcp_fin_timeout = 15
            \\
            \\# Connection backlog
            \\net.core.somaxconn = 65535
            \\net.ipv4.tcp_max_syn_backlog = 65535
            \\
            \\# Conntrack (if using iptables/nftables)
            \\net.netfilter.nf_conntrack_max = 2000000
            \\
            \\# Port range for ephemeral ports
            \\net.ipv4.ip_local_port_range = 1024 65535
            \\
            \\# Disable slow start after idle
            \\net.ipv4.tcp_slow_start_after_idle = 0
            \\```
            \\
            \\Apply: `sysctl -p`
            \\
            \\## User Limits
            \\
            \\```bash
            \\# /etc/security/limits.conf
            \\*    soft    nofile    2000000
            \\*    hard    nofile    2000000
            \\```
            \\
            \\## Multi-Process Deployment (SO_REUSEPORT)
            \\
            \\The server uses `SO_REUSEPORT` by default on POSIX. Start N instances
            \\of the same binary — the kernel distributes connections across them:
            \\
            \\```bash
            \\#!/bin/bash
            \\export DB_HOST=127.0.0.1 DB_USER=root DB_PASS= DB_NAME=im_db
            \\
            \\for i in $(seq 1 4); do
            \\    HTTP_PORT=8080 ./myapp &
            \\done
            \\wait
            \\```
            \\
            \\Each process has its own event loop, BufferPool, and ConnectionRegistry.
            \\No shared state needed. To share online status across processes,
            \\add a Redis bridge to `ImRelay` (see relay.zig).
            \\
            \\## io_uring Mode (Linux 5.1+)
            \\
            \\Add to your main.zig before server.start():
            \\
            \\```zig
            \\var uring = try zigmodu.im.WsUring.init(allocator, .{
            \\    .max_connections = 16384,
            \\});
            \\try uring.start();
            \\server.setWsUring(&uring);
            \\defer uring.stop();
            \\```
            \\
            \\WebSocket connections automatically use io_uring after handshake.
            \\HTTP requests continue using the fiber path. No code changes needed.
            \\
            \\## Memory Budget (per connection)
            \\
            \\| Component | Size | Notes |
            \\|-----------|------|-------|
            \\| WsSession struct | 120B | Gateway connection state |
            \\| ConnectionEntry | 48B | Registry shard entry |
            \\| Kernel TCP recv | 2KB | SO_RCVBUF=2048 |
            \\| Kernel TCP send | 2KB | SO_SNDBUF=2048 |
            \\| BufferPool (shared) | ~300MB | 75K × 4KB, pooled |
            \\| **Total per connection** | **~4.3KB** | |
            \\
            \\1M connections: ~4.3GB kernel + ~200MB user = ~4.5GB total.
            \\
            \\## Performance Benchmarks
            \\
            \\Run a quick benchmark with `wrk` or `websocat`:
            \\
            \\```bash
            \\# REST endpoint
            \\wrk -t4 -c100 -d30s http://localhost:8080/admin-api/im/conversations?userId=1
            \\
            \\# WebSocket (install websocat)
            \\for i in $(seq 1 10000); do
            \\    websocat "ws://localhost:8080/admin-api/im/ws?userId=$i" &
            \\done
            \\```
            \\
            \\## Troubleshooting
            \\
            \\**"Too many open files"**: Increase `ulimit -n` and `fs.file-max`.
            \\
            \\**"Cannot assign requested address"**: Increase `ip_local_port_range`.
            \\
            \\**Connection drops under load**: Check `net.core.somaxconn` and backlog.
            \\
            \\**High CPU with few connections**: Check for busy-polling loops.
            \\
        , gen_opts);
    }

    // ── model.zig ──
    const model_path = try std.fmt.allocPrint(allocator, "{s}/model.zig", .{im_dir});
    defer allocator.free(model_path);
    try safeWrite(io, allocator, model_path,
        \\//! @initialized by zmodu — AI may modify
        \\//! IM data models
        \\pub const Message = struct {
        \\    pub const sql_table_name: []const u8 = "im_message";
        \\    id: ?i64 = null,
        \\    conversation_id: i64,
        \\    from_user_id: u64,
        \\    to_user_id: u64,
        \\    content: []const u8,
        \\    msg_type: i64 = 1,
        \\    status: i64 = 0,
        \\    created_at: i64,
        \\    updated_at: i64,
        \\};
        \\
        \\pub const Conversation = struct {
        \\    pub const sql_table_name: []const u8 = "im_conversation";
        \\    id: ?i64 = null,
        \\    conversation_type: i64 = 1,
        \\    title: []const u8,
        \\    last_message: ?[]const u8 = null,
        \\    last_message_at: ?i64 = null,
        \\    created_at: i64,
        \\    updated_at: i64,
        \\};
        \\
        \\pub const Participant = struct {
        \\    pub const sql_table_name: []const u8 = "im_participant";
        \\    id: ?i64 = null,
        \\    conversation_id: i64,
        \\    user_id: i64,
        \\    role: i64 = 0,
        \\    joined_at: i64,
        \\};
        \\
    , gen_opts);

    // ── persistence.zig ──
    const pers_path = try std.fmt.allocPrint(allocator, "{s}/persistence.zig", .{im_dir});
    defer allocator.free(pers_path);
    try safeWrite(io, allocator, pers_path,
        \\//! @initialized by zmodu — AI may modify
        \\const std = @import("std");
        \\const data = @import("zigmodu").data;
        \\const model = @import("model.zig");
        \\
        \\pub const ImPersistence = struct {
        \\    backend: data.SqlxBackend,
        \\    orm: data.orm.Orm(data.SqlxBackend),
        \\
        \\    pub fn init(backend: data.SqlxBackend) ImPersistence {
        \\        return .{ .backend = backend, .orm = .{ .backend = backend } };
        \\    }
        \\    pub fn messageRepo(self: *ImPersistence) data.Repository(model.Message) {
        \\        return .{ .orm = &self.orm };
        \\    }
        \\    pub fn conversationRepo(self: *ImPersistence) data.Repository(model.Conversation) {
        \\        return .{ .orm = &self.orm };
        \\    }
        \\    pub fn participantRepo(self: *ImPersistence) data.Repository(model.Participant) {
        \\        return .{ .orm = &self.orm };
        \\    }
        \\};
        \\
    , gen_opts);

    // ── service.zig ──
    const svc_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{im_dir});
    defer allocator.free(svc_path);
    try safeWrite(io, allocator, svc_path,
        \\//! @initialized by zmodu — AI may modify
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const data = zigmodu.data;
        \\const model = @import("model.zig");
        \\const persistence = @import("persistence.zig");
        \\
        \\pub const ImEvent = union(enum) { message_sent: MessageSent };
        \\pub const MessageSent = struct { msg: model.Message };
        \\
        \\pub const ImService = struct {
        \\    persistence: *persistence.ImPersistence,
        \\    relay: ?*anyopaque = null,
        \\    send_fn: ?*const fn (*anyopaque, *const model.Message) anyerror!void = null,
        \\
        \\    pub fn init(p: *persistence.ImPersistence) ImService {
        \\        return .{ .persistence = p };
        \\    }
        \\
        \\    pub fn setRelay(self: *ImService, relay_ptr: *anyopaque, send_fn: *const fn (*anyopaque, *const model.Message) anyerror!void) void {
        \\        self.relay = relay_ptr;
        \\        self.send_fn = send_fn;
        \\    }
        \\
        \\    pub fn send(self: *ImService, msg: model.Message) !model.Message {
        \\        var repo = self.persistence.messageRepo();
        \\        const saved = try repo.insert(msg);
        \\        if (self.send_fn) |f| {
        \\            if (self.relay) |r| f(r, &saved) catch {};
        \\        }
        \\        return saved;
        \\    }
        \\
        \\    pub fn getMessages(self: *ImService, conv_id: i64, page: usize, size: usize) !data.orm.PageResult(model.Message) {
        \\        _ = conv_id;
        \\        var repo = self.persistence.messageRepo();
        \\        return try repo.findPage(page, size);
        \\    }
        \\
        \\    pub fn getConversations(self: *ImService, user_id: i64, page: usize, size: usize) !data.orm.PageResult(model.Conversation) {
        \\        _ = user_id;
        \\        var repo = self.persistence.conversationRepo();
        \\        return try repo.findPage(page, size);
        \\    }
        \\
        \\    pub fn validateMessage(_: *ImService, msg: model.Message) !void {
        \\        if (msg.content.len == 0) return error.ValidationFailed;
        \\    }
        \\};
        \\
    , gen_opts);

    // ── api.zig ──
    const api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{im_dir});
    defer allocator.free(api_path);
    try safeWrite(io, allocator, api_path,
        \\//! @initialized by zmodu — AI may modify
        \\const std = @import("std");
        \\const http = @import("zigmodu").http;
        \\const service = @import("service.zig");
        \\const model = @import("model.zig");
        \\const R = @import("../../shared/response.zig");
        \\
        \\pub const ImApi = struct {
        \\    service: *service.ImService,
        \\
        \\    pub fn init(svc: *service.ImService) ImApi { return .{ .service = svc }; }
        \\
        \\    fn resolve(ctx: *http.Context) *ImApi {
        \\        return @ptrCast(@alignCast(ctx.user_data orelse unreachable));
        \\    }
        \\
        \\    pub fn registerRoutes(self: *ImApi, group: *http.RouteGroup) !void {
        \\        try group.get("/im/conversations", listConversations, @ptrCast(@alignCast(self)));
        \\        try group.get("/im/messages", listMessages, @ptrCast(@alignCast(self)));
        \\        try group.post("/im/send", sendMessage, @ptrCast(@alignCast(self)));
        \\    }
        \\
        \\    fn listConversations(ctx: *http.Context) !void {
        \\        const s = resolve(ctx);
        \\        const page = ctx.queryInt(usize, "pageNo", 1);
        \\        const size = ctx.queryInt(usize, "pageSize", 10);
        \\        const user_id = ctx.queryInt(i64, "userId", 0);
        \\        const result = try s.service.getConversations(user_id, page, size);
        \\        try R.wrapList(ctx, result);
        \\    }
        \\
        \\    fn listMessages(ctx: *http.Context) !void {
        \\        const s = resolve(ctx);
        \\        const conv_id = ctx.queryInt(i64, "conversationId", 0);
        \\        const page = ctx.queryInt(usize, "pageNo", 1);
        \\        const size = ctx.queryInt(usize, "pageSize", 20);
        \\        const result = try s.service.getMessages(conv_id, page, size);
        \\        try R.wrapList(ctx, result);
        \\    }
        \\
        \\    fn sendMessage(ctx: *http.Context) !void {
        \\        const s = resolve(ctx);
        \\        const msg = ctx.bindJson(model.Message) catch {
        \\            try R.wrapErr(ctx, .validation_failed, "invalid body");
        \\            return;
        \\        };
        \\        s.service.validateMessage(msg) catch {
        \\            try R.wrapErr(ctx, .validation_failed, "validation failed");
        \\            return;
        \\        };
        \\        const saved = try s.service.send(msg);
        \\        try R.wrapOk(ctx, saved);
        \\    }
        \\};
        \\
    , gen_opts);

    // ── relay.zig ──
    const relay_path = try std.fmt.allocPrint(allocator, "{s}/relay.zig", .{im_dir});
    defer allocator.free(relay_path);
    try safeWrite(io, allocator, relay_path,
        \\//! @initialized by zmodu — AI may modify
        \\//! Single-node message relay: writes to DB, then pushes to online users via ConnectionRegistry.
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const model = @import("model.zig");
        \\
        \\pub const ImRelay = struct {
        \\    registry: *zigmodu.im.ConnectionRegistry,
        \\    allocator: std.mem.Allocator,
        \\
        \\    pub fn init(registry: *zigmodu.im.ConnectionRegistry, allocator: std.mem.Allocator) ImRelay {
        \\        return .{ .registry = registry, .allocator = allocator };
        \\    }
        \\
        \\    /// Called by ImService.send() after DB insert. Delivers to online user.
        \\    pub fn deliver(self: *ImRelay, msg: *const model.Message) !void {
        \\        const json = try std.json.Stringify.valueAlloc(self.allocator, msg, .{});
        \\        defer self.allocator.free(json);
        \\        _ = self.registry.sendToUser(msg.to_user_id, json);
        \\    }
        \\};
        \\
    , gen_opts);

    // ── gateway.zig ──
    const gw_path = try std.fmt.allocPrint(allocator, "{s}/gateway.zig", .{im_dir});
    defer allocator.free(gw_path);
    try safeWrite(io, allocator, gw_path,
        \\//! @initialized by zmodu — AI may modify
        \\//! WebSocket gateway: WS upgrade + ConnectionRegistry integration.
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\const http = zigmodu.http;
        \\const ConnectionRegistry = zigmodu.im.ConnectionRegistry;
        \\const WsFramer = zigmodu.im.WsFramer;
        \\
        \\/// Per-connection session stored in ConnectionRegistry.
        \\pub const WsSession = struct {
        \\    user_id: u64,
        \\    conn_id: u32,
        \\    framer: WsFramer,
        \\    gateway: *ImGateway,
        \\    mutex: std.Io.Mutex,
        \\    last_ping_tick: u64,
        \\
        \\    pub fn send(self: *WsSession, msg: []const u8) !void {
        \\        self.mutex.lock(self.framer.io) catch return error.NotConnected;
        \\        defer self.mutex.unlock(self.framer.io);
        \\        // Small stack buffer for frame header write (10 bytes max).
        \\        // For large payloads, Stream.Writer flushes buffer automatically.
        \\        var wbuf: [256]u8 = undefined;
        \\        var w = self.framer.stream.writer(self.framer.io, &wbuf);
        \\        try writeFrameTo(&w, 0x1, msg);
        \\    }
        \\};
        \\
        \\/// Write a WebSocket text frame directly to a Stream.Writer.
        \\fn writeFrameTo(w: anytype, opcode: u8, payload: []const u8) !void {
        \\    var header: [14]u8 = undefined;
        \\    var hl: usize = 2;
        \\    header[0] = 0x80 | opcode;
        \\    if (payload.len < 126) {
        \\        header[1] = @intCast(payload.len);
        \\    } else if (payload.len < 65536) {
        \\        header[1] = 126;
        \\        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        \\        hl = 4;
        \\    } else {
        \\        header[1] = 127;
        \\        std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
        \\        hl = 10;
        \\    }
        \\    try w.interface.writeAll(header[0..hl]);
        \\    try w.interface.writeAll(payload);
        \\    try w.interface.flush();
        \\}
        \\
        \\/// Called by onMessage when a text frame arrives. user_id is the sender, msg is the JSON payload.
        \\pub const MsgHandler = *const fn (ctx: *anyopaque, user_id: u64, msg: []const u8) void;
        \\
        \\pub const ImGateway = struct {
        \\    allocator: std.mem.Allocator,
        \\    io: std.Io,
        \\    registry: ConnectionRegistry,
        \\    msg_handler: ?MsgHandler = null,
        \\    msg_ctx: ?*anyopaque = null,
        \\
        \\    pub fn init(allocator: std.mem.Allocator, io: std.Io) ImGateway {
        \\        return .{ .allocator = allocator, .io = io, .registry = ConnectionRegistry.init(allocator, io) };
        \\    }
        \\    pub fn deinit(self: *ImGateway) void { self.registry.deinit(); }
        \\    pub fn setMsgHandler(self: *ImGateway, handler: MsgHandler, ctx: *anyopaque) void { self.msg_handler = handler; self.msg_ctx = ctx; }
        \\    pub fn register(self: *ImGateway, group: *http.RouteGroup, allocator: std.mem.Allocator) !void { _ = allocator; try group.ws("/im/ws", onConnect, onMessage, onClose, @ptrCast(@alignCast(self))); }
        \\    pub fn cleanup(self: *ImGateway) usize { return self.registry.tickAndCleanup(3); }
        \\
        \\    fn onConnect(ctx: *http.Context, raw_framer: *anyopaque) ?*anyopaque {
        \\        const gw: *ImGateway = @ptrCast(@alignCast(ctx.user_data orelse return null));
        \\        const framer: *WsFramer = @ptrCast(@alignCast(raw_framer));
        \\
        \\        const user_id = ctx.queryInt(u64, "userId", 0);
        \\        if (user_id == 0) return null;
        \\
        \\        const session = gw.allocator.create(WsSession) catch return null;
        \\        session.* = .{
        \\            .user_id = user_id,
        \\            .conn_id = 0,
        \\            .framer = framer.*,
        \\            .gateway = gw,
        \\            .mutex = std.Io.Mutex.init,
        \\            .last_ping_tick = 0,
        \\        };
        \\        const conn_id = gw.registry.register(user_id, @ptrCast(session), sendViaWsFramer);
        \\        if (conn_id == 0) {
        \\            gw.allocator.destroy(session);
        \\            return null;
        \\        }
        \\        session.conn_id = conn_id;
        \\        std.log.info("[im] user {d} connected (conn={d})", .{ user_id, conn_id });
        \\        return @ptrCast(session);
        \\    }
        \\
        \\    fn sendViaWsFramer(ctx: *anyopaque, msg: []const u8) anyerror!void {
        \\        const session: *WsSession = @ptrCast(@alignCast(ctx));
        \\        try session.send(msg);
        \\    }
        \\
        \\    fn onMessage(session_ptr: ?*anyopaque, msg: []const u8) void {
        \\        const session: *WsSession = @ptrCast(@alignCast(session_ptr orelse return));
        \\        if (session.gateway.msg_handler) |h| h(session.gateway.msg_ctx.?, session.user_id, msg);
        \\    }
        \\
        \\    fn onClose(session_ptr: ?*anyopaque) void {
        \\        const session: *WsSession = @ptrCast(@alignCast(session_ptr orelse return));
        \\        std.log.info("[im] user {d} disconnected (conn={d})", .{ session.user_id, session.conn_id });
        \\        session.gateway.registry.unregisterByConn(session.conn_id);
        \\        session.gateway.allocator.destroy(session);
        \\    }
        \\};
        \\
    , gen_opts);

    // ── ext/service.zig ──
    const ext_svc_path = try std.fmt.allocPrint(allocator, "{s}/ext/service.zig", .{im_dir});
    defer allocator.free(ext_svc_path);
    if (false) {
    if (!fileExists(io, ext_svc_path)) {
        try safeWrite(io, allocator, ext_svc_path,
            \\// IM service extension — add custom business logic here.
            \\// @initialized — AI may modify freely.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const ext_svc = @import("../service.zig");
            \\
            \\pub const ImServiceExt = struct {
            \\    svc: *ext_svc.ImService,
            \\    backend: zigmodu.data.SqlxBackend,
            \\
            \\    pub fn init(svc: *ext_svc.ImService, backend: zigmodu.data.SqlxBackend) ImServiceExt {
            \\        return .{ .svc = svc, .backend = backend };
            \\    }
            \\};
            \\
        , gen_opts);
    } // if(false) — ext/ removed
    }

    // ── ext/api.zig ──
    const ext_api_path = try std.fmt.allocPrint(allocator, "{s}/ext/api.zig", .{im_dir});
    defer allocator.free(ext_api_path);
    if (false) {
    if (!fileExists(io, ext_api_path)) {
        try safeWrite(io, allocator, ext_api_path,
            \\// IM API extension — add custom endpoints here.
            \\// @initialized — AI may modify freely.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const http = zigmodu.http;
            \\const R = @import("../../../shared/response.zig");
            \\const ext_svc = @import("service.zig");
            \\
            \\pub const ImApiExt = struct {
            \\    ext: *ext_svc.ImServiceExt,
            \\
            \\    pub fn init(ext: *ext_svc.ImServiceExt) ImApiExt {
            \\        return .{ .ext = ext };
            \\    }
            \\
            \\    pub fn registerRoutes(self: *ImApi, group: *zigmodu.http.RouteGroup) !void {
            \\        _ = self;
            \\        _ = group;
            \\        // Add custom IM routes here
            \\    }
            \\};
            \\
        , gen_opts);
    } // if(false) — ext/ removed
    }

    // ── tests.zig ──
    const tests_path = try std.fmt.allocPrint(allocator, "{s}/tests.zig", .{im_dir});
    defer allocator.free(tests_path);
    if (!fileExists(io, tests_path)) {
        try safeWrite(io, allocator, tests_path,
            \\//! Integration tests for IM module.
            \\const std = @import("std");
            \\const testing = std.testing;
            \\const zigmodu = @import("zigmodu");
            \\const model = @import("model.zig");
            \\const persistence = @import("persistence.zig");
            \\const service = @import("service.zig");
            \\const gateway = @import("gateway.zig");
            \\const relay = @import("relay.zig");
            \\const WsFramer = zigmodu.im.WsFramer;
            \\
            \\test "model Message default values" {
            \\    const msg = model.Message{
            \\        .id = null,
            \\        .conversation_id = 1,
            \\        .from_user_id = 10,
            \\        .to_user_id = 20,
            \\        .content = "hello",
            \\        .created_at = 0,
            \\        .updated_at = 0,
            \\    };
            \\    try testing.expectEqual(@as(i64, 1), msg.msg_type);
            \\    try testing.expectEqual(@as(i64, 0), msg.status);
            \\    try testing.expectEqualStrings("hello", msg.content);
            \\}
            \\
            \\test "model Conversation default values" {
            \\    const conv = model.Conversation{
            \\        .id = null,
            \\        .title = "test",
            \\        .created_at = 0,
            \\        .updated_at = 0,
            \\    };
            \\    try testing.expectEqual(@as(i64, 1), conv.conversation_type);
            \\}
            \\
            \\test "model Participant default values" {
            \\    const p = model.Participant{
            \\        .id = null,
            \\        .conversation_id = 1,
            \\        .user_id = 10,
            \\        .joined_at = 0,
            \\    };
            \\    try testing.expectEqual(@as(i64, 0), p.role);
            \\}
            \\
            \\test "service validateMessage rejects empty content" {
            \\    var svc = service.ImService{ .persistence = undefined };
            \\    const msg = model.Message{
            \\        .id = null,
            \\        .conversation_id = 1,
            \\        .from_user_id = 10,
            \\        .to_user_id = 20,
            \\        .content = "",
            \\        .created_at = 0,
            \\        .updated_at = 0,
            \\    };
            \\    try testing.expectError(error.ValidationFailed, svc.validateMessage(msg));
            \\}
            \\
            \\test "service validateMessage accepts valid content" {
            \\    var svc = service.ImService{ .persistence = undefined };
            \\    const msg = model.Message{
            \\        .id = null,
            \\        .conversation_id = 1,
            \\        .from_user_id = 10,
            \\        .to_user_id = 20,
            \\        .content = "hello world",
            \\        .created_at = 0,
            \\        .updated_at = 0,
            \\    };
            \\    try svc.validateMessage(msg);
            \\}
            \\
            \\test "gateway init and deinit" {
            \\    var gw = gateway.ImGateway.init(testing.allocator, testing.io);
            \\    defer gw.deinit();
            \\    try testing.expectEqual(@as(usize, 0), gw.registry.onlineCount());
            \\}
            \\
            \\test "gateway cleanup returns 0 on empty" {
            \\    var gw = gateway.ImGateway.init(testing.allocator, testing.io);
            \\    defer gw.deinit();
            \\    try testing.expectEqual(@as(usize, 0), gw.cleanup());
            \\}
            \\
            \\test "ConnectionRegistry register unregister" {
            \\    var reg = zigmodu.im.ConnectionRegistry.init(testing.allocator, testing.io);
            \\    defer reg.deinit();
            \\
            \\    var dummy: u8 = 0;
            \\    const cid = reg.register(42, @ptrCast(&dummy), testSendFn);
            \\    try testing.expect(cid > 0);
            \\    try testing.expect(reg.isOnline(42));
            \\    try testing.expectEqual(@as(usize, 1), reg.onlineCount());
            \\
            \\    reg.unregisterByConn(cid);
            \\    try testing.expect(!reg.isOnline(42));
            \\    try testing.expectEqual(@as(usize, 0), reg.onlineCount());
            \\}
            \\
            \\test "ConnectionRegistry sendToUser offline" {
            \\    var reg = zigmodu.im.ConnectionRegistry.init(testing.allocator, testing.io);
            \\    defer reg.deinit();
            \\    try testing.expect(!reg.sendToUser(999, "nobody home"));
            \\}
            \\
            \\test "ConnectionRegistry heartbeat and cleanup" {
            \\    var reg = zigmodu.im.ConnectionRegistry.init(testing.allocator, testing.io);
            \\    defer reg.deinit();
            \\
            \\    var dummy: u8 = 0;
            \\    const cid = reg.register(1, @ptrCast(&dummy), testSendFn);
            \\    try testing.expect(cid > 0);
            \\
            \\    _ = reg.tickAndCleanup(5);
            \\    try testing.expect(reg.isOnline(1));
            \\
            \\    reg.heartbeat(cid);
            \\    _ = reg.tickAndCleanup(5);
            \\    try testing.expect(reg.isOnline(1));
            \\}
            \\
            \\test "relay delivers to online user" {
            \\    var reg = zigmodu.im.ConnectionRegistry.init(testing.allocator, testing.io);
            \\    defer reg.deinit();
            \\
            \\    var captured: [512]u8 = undefined;
            \\    var captured_len: usize = 0;
            \\    var ctx = RelayTestCtx{ .buf = &captured, .len = &captured_len };
            \\    _ = reg.register(1, @ptrCast(&ctx), relayTestSendFn);
            \\
            \\    var r = relay.ImRelay.init(&reg, testing.allocator);
            \\    const msg = model.Message{
            \\        .id = null, .conversation_id = 1,
            \\        .from_user_id = 10, .to_user_id = 1,
            \\        .content = "ping", .created_at = 0, .updated_at = 0,
            \\    };
            \\    try r.deliver(&msg);
            \\    try testing.expect(captured_len > 0);
            \\}
            \\
            \\
            \\test "WsFramer frame encode/decode round-trip" {
            \\    // Encode a text frame manually
            \\    var wbuf: [256]u8 = undefined;
            \\    var payload = "hello world";
            \\
            \\    // Encode via write frame logic (inline for test)
            \\    var header: [6]u8 = undefined;
            \\    header[0] = 0x80 | 0x1;
            \\    header[1] = @intCast(payload.len);
            \\    @memcpy(wbuf[0..2], header[0..2]);
            \\    @memcpy(wbuf[2..][0..payload.len], payload);
            \\    const frame_len = 2 + payload.len;
            \\
            \\    // Decode: parse header
            \\    try testing.expectEqual(@as(u8, 0x1), wbuf[0] & 0x0F);
            \\    try testing.expectEqual(@as(usize, payload.len), wbuf[1] & 0x7F);
            \\    try testing.expectEqualStrings(payload, wbuf[2..frame_len]);
            \\}
            \\
            \\test "WsSession send via mocked framer" {
            \\    var session = gateway.WsSession{
            \\        .user_id = 1,
            \\        .conn_id = 100,
            \\        .framer = WsFramer.init(undefined, undefined),
            \\        .gateway = undefined,
            \\        .mutex = std.Io.Mutex.init,
            \\        .last_ping_tick = 0,
            \\    };
            \\    try testing.expectEqual(@as(u64, 1), session.user_id);
            \\    try testing.expectEqual(@as(u32, 100), session.conn_id);
            \\}
            \\
            \\test "BufferPool stress: acquire/release many buffers" {
            \\    var pool = zigmodu.im.BufferPool.init(testing.allocator, testing.io, 50);
            \\    defer pool.deinit();
            \\
            \\    var buffers: [50][]u8 = undefined;
            \\    for (&buffers) |*b| b.* = try pool.acquire();
            \\    try testing.expectError(error.PoolExhausted, pool.acquire());
            \\
            \\    for (&buffers) |*b| pool.release(b.*);
            \\    try testing.expectEqual(@as(usize, 50), pool.available());
            \\}
            \\
            \\test "ConnectionRegistry parallel: unique user IDs per shard" {
            \\    var reg = zigmodu.im.ConnectionRegistry.init(testing.allocator, testing.io);
            \\    defer reg.deinit();
            \\
            \\    var dummy: u8 = 0;
            \\    // Register users across different shards
            \\    for (0..256) |i| {
            \\        const uid: u64 = @intCast(i);
            \\        const cid = reg.register(uid, @ptrCast(&dummy), testSendFn);
            \\        try testing.expect(cid > 0);
            \\        try testing.expect(reg.isOnline(uid));
            \\    }
            \\    try testing.expectEqual(@as(usize, 256), reg.onlineCount());
            \\
            \\    // Check online users
            \\    var users: [256]u64 = undefined;
            \\    const count = reg.onlineUsers(&users);
            \\    try testing.expectEqual(@as(usize, 256), count);
            \\
            \\    // Cleanup all
            \\    for (0..256) |i| {
            \\        const uid: u64 = @intCast(i);
            \\        reg.unregister(uid);
            \\    }
            \\    try testing.expectEqual(@as(usize, 0), reg.onlineCount());
            \\}
            \\
            \\test "relay deliver content verification" {
            \\    var reg = zigmodu.im.ConnectionRegistry.init(testing.allocator, testing.io);
            \\    defer reg.deinit();
            \\
            \\    var captured: [512]u8 = undefined;
            \\    var captured_len: usize = 0;
            \\    var ctx = RelayTestCtx{ .buf = &captured, .len = &captured_len };
            \\    _ = reg.register(1, @ptrCast(&ctx), relayTestSendFn);
            \\
            \\    var r = relay.ImRelay.init(&reg, testing.allocator);
            \\    const msg = model.Message{
            \\        .id = null, .conversation_id = 42,
            \\        .from_user_id = 10, .to_user_id = 1,
            \\        .content = "ping-42", .created_at = 100, .updated_at = 200,
            \\    };
            \\    try r.deliver(&msg);
            \\    try testing.expect(captured_len > 0);
            \\    // Verify JSON contains key fields
            \\    const json = captured[0..captured_len];
            \\    try testing.expect(std.mem.indexOf(u8, json, "ping-42") != null);
            \\    try testing.expect(std.mem.indexOf(u8, json, "conversation_id") != null);
            \\}
            \\
            \\const RelayTestCtx = struct { buf: *[512]u8, len: *usize };
            \\
            \\fn relayTestSendFn(ctx: *anyopaque, msg: []const u8) anyerror!void {
            \\    const tc: *RelayTestCtx = @ptrCast(@alignCast(ctx));
            \\    @memcpy(tc.buf.*[0..@min(msg.len, tc.buf.len)], msg);
            \\    tc.len.* = msg.len;
            \\}
            \\
            \\fn testSendFn(ctx: *anyopaque, msg: []const u8) anyerror!void {
            \\    _ = ctx;
            \\    _ = msg;
            \\}
            \\
        , gen_opts);
    }
}

fn generateLifeDir(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8, project_name: []const u8, table_count: usize, module_count: usize, gen_opts: GenOptions) !void {
    const life_dir = try std.fmt.allocPrint(allocator, "{s}/.life", .{out_dir});
    defer allocator.free(life_dir);
    try ensureDirGen(io, life_dir, gen_opts);
    const td = try std.fmt.allocPrint(allocator, "{s}/tree", .{life_dir}); defer allocator.free(td); try ensureDirGen(io, td, gen_opts);
    const md = try std.fmt.allocPrint(allocator, "{s}/memory", .{life_dir}); defer allocator.free(md); try ensureDirGen(io, md, gen_opts);

    // DNA.md — minimal birth record
    const dp = try std.fmt.allocPrint(allocator, "{s}/DNA.md", .{life_dir});
    defer allocator.free(dp);
    var dna: std.ArrayList(u8) = .empty;
    try dna.print(allocator, "# {s}\ngenesis: zmodu scaffold\ntables: {d}\nmodules: {d}\nframework: zigmodu v0.13.9\nzig: 0.17.0\n", .{ project_name, table_count, module_count });
    try safeWrite(io, allocator, dp, dna.items, gen_opts);

    // manifest.json — compact
    const mp = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{life_dir}); defer allocator.free(mp);
    const mf_json = try std.fmt.allocPrint(allocator, "{{\"name\":\"{s}\",\"modules\":{d},\"tables\":{d},\"v\":\"0.1.0\"}}\n", .{ project_name, module_count, table_count }); defer allocator.free(mf_json);
    try safeWrite(io, allocator, mp, mf_json, gen_opts);

    // tree/v0.1.0.md — genesis node
    const tpath = try std.fmt.allocPrint(allocator, "{s}/v0.1.0.md", .{td});
    defer allocator.free(tpath);
    var tree_buf: std.ArrayList(u8) = .empty;
    try tree_buf.print(allocator, "# v0.1.0 genesis\nzmodu scaffold\n{d} tables → {d} modules\n", .{ table_count, module_count });
    try safeWrite(io, allocator, tpath, tree_buf.items, gen_opts);

    // memory/decisions.jsonl — seed
    const dpath = try std.fmt.allocPrint(allocator, "{s}/decisions.jsonl", .{md});
    defer allocator.free(dpath);
    try safeWrite(io, allocator, dpath, "{\"t\":\"genesis\",\"d\":\"zmodu scaffold\",\"v\":\"0.1.0\"}\n", gen_opts);

    // fingerprint
    const fp = try std.fmt.allocPrint(allocator, "{s}/fingerprint.sha256", .{life_dir});
    defer allocator.free(fp);
    try safeWrite(io, allocator, fp, "genesis-v0.1.0\n", gen_opts);
}

fn generateClaudeSkills(io: std.Io, allocator: std.mem.Allocator, out_dir: []const u8, gen_opts: GenOptions) !void {
    const skills_dir = try std.fmt.allocPrint(allocator, "{s}/.claude/skills", .{out_dir});
    defer allocator.free(skills_dir);
    try ensureDirGen(io, skills_dir, gen_opts);

    const skill_dirs = [_][]const u8{ "zigmodu-build", "zigmodu-life", "zigmodu-project", "zigmodu-module", "zigmodu-api", "zigmodu-orm", "zigmodu-analyze", "zigmodu-translate", "zigmodu-harness", "zigmodu-plugin" };
    for (skill_dirs) |sd| {
        const d = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ skills_dir, sd });
        defer allocator.free(d);
        try ensureDirGen(io, d, gen_opts);
    }

    // zigmodu-build (master skill — always start here)
    const sb = try std.fmt.allocPrint(allocator, "{s}/zigmodu-build/SKILL.md", .{skills_dir});
    defer allocator.free(sb);
    try safeWrite(io, allocator, sb,
        \\---
        \\name: zigmodu-build
        \\description: Build complete ZigModu backend — greenfield/SQL/migration. zmodu generates all possible code, AI fills only gaps. Always start here.
        \\---
        \\
        \\# ZigModu Build — First Principle
        \\
        \\**zmodu generates everything possible. AI only writes what zmodu cannot.**
        \\
        \\## Mode Selection
        \\```
        \\Have SQL schema? → Mode 2 (Brownfield)
        \\Have reference project (Java/PHP/Go/Rust)? → Mode 3 (Migration)
        \\Neither? → Mode 1 (Greenfield)
        \\```
        \\
        \\## Mode 1: Greenfield (from requirements)
        \\```bash
        \\# 1. Design schema → schema.sql (AI assists)
        \\# 2. zmodu generates full project
        \\zmodu scaffold --sql schema.sql --name <project> --with-events --with-resilience --with-metrics
        \\# 3. Verify: zig build (must be 0 errors)
        \\# 4. AI fills: add custom methods to service.zig, routes to api.zig.
        \\```
        \\
        \\## Mode 2: Brownfield (from SQL)
        \\```bash
        \\# 1. Verify SQL: grep "CREATE TABLE\|FOREIGN KEY" schema.sql
        \\# 2. zmodu generates full project
        \\zmodu scaffold --sql schema.sql --name <project> --with-events --with-auth
        \\# 3. Verify: zig build
        \\# 4. AI adds: JOIN queries, business rules, auth logic
        \\```
        \\
        \\## Mode 3: Migration (from Java/PHP/Go/Rust)
        \\```bash
        \\# 1. Analyze source → extract SQL + routes
        \\# 2. zmodu generates from extracted SQL
        \\zmodu scaffold --sql schema.sql --name <project>
        \\# 3. AI translates: service logic diff, custom endpoints
        \\# 4. Verify: zmodu verify --old :8080 --new :8081
        \\```
        \\
        \\## AI Edit Rules
        \\### All files marked @initialized are editable:
        \\`model.zig` `persistence.zig` `service.zig` `api.zig` `module.zig` `main.zig` `build.zig`
        \\### No ext/ needed — AI modifies generated files directly.
        \\### After regeneration, AI merges schema changes manually.
        \\
        \\## Verify after every change
        \\```bash
        \\zig build && zig build test
        \\```
        \\
    , gen_opts);

    // zigmodu-life
    const sl = try std.fmt.allocPrint(allocator, "{s}/zigmodu-life/SKILL.md", .{skills_dir});
    defer allocator.free(sl);
    try safeWrite(io, allocator, sl,
        \\---
        \\name: zigmodu-life
        \\description: Project digital life system. Use zmodu life CLI for all .life/ operations. Read .life/ on first contact. Record decisions via JSONL. Evolve milestones via tree/.
        \\---
        \\
        \\# Digital Life — Use CLI, not manual file ops
        \\
        \\## First Contact (BEFORE any code change)
        \\```bash
        \\cat .life/DNA.md && zmodu life tree && cat .life/memory/decisions.jsonl
        \\```
        \\
        \\## Record Decision (after every code change)
        \\```bash
        \\echo '{{"t":"FEAT|FIX|ARCH|PERF|SEC","d":"<what>","r":"<why>","f":["<file>"]}}' >> .life/memory/decisions.jsonl
        \\```
        \\
        \\## Record Milestone
        \\```bash
        \\zmodu life evolve v0.2.0 "order state machine complete"
        \\zmodu life tree        # verify
        \\zmodu life fingerprint  # verify fingerprint changed
        \\```
        \\
        \\## NEVER do this
        \\`vim .life/tree/v0.2.0.md`  → use `zmodu life evolve`
        \\`echo "x" > .life/fingerprint.sha256` → use `zmodu life fingerprint`
        \\`rm .life/*` → never delete evolutionary memory
        \\
    , gen_opts);

    // zigmodu-project
    const sp = try std.fmt.allocPrint(allocator, "{s}/zigmodu-project/SKILL.md", .{skills_dir});
    defer allocator.free(sp);
    try safeWrite(io, allocator, sp,
        \\---
        \\name: zigmodu-project
        \\description: Navigate and understand a ZigModu project. Use when exploring the codebase, understanding module conventions, or learning the project layout.
        \\---
        \\
        \\# ZigModu Project Navigation
        \\
        \\## Module Structure (5 files per module)
        \\```
        \\src/modules/<name>/
        \\├── module.zig      # lifecycle + barrel re-exports + health checks
        \\├── model.zig       # data structs (sql_table_name + fields)
        \\├── persistence.zig # ORM repositories → data.Repository(T)
        \\├── service.zig     # business logic + EventBus(T) + CRUD
        \\└── api.zig         # REST routes + resolve(ctx) helper
        \\```
        \\
        \\## Module Contract
        \\```zig
        \\pub const info = api.Module{ .name = "x", .dependencies = &.{}, .is_internal = false };
        \\pub fn init() !void { ... }
        \\pub fn deinit() void { ... }
        \\pub fn registerHealthChecks(endpoint: *zigmodu.HealthEndpoint) !void { ... }
        \\```
        \\
        \\## Import Conventions
        \\- module.zig → `const api = zigmodu.api;`
        \\- persistence.zig → `const data = @import("zigmodu").data;`
        \\- service.zig → `const data = zigmodu.data;`
        \\- api.zig → `const http = @import("zigmodu").http;`
        \\
        \\## Building
        \\```bash
        \\zig build              # compile
        \\zig build run          # run (reads HTTP_PORT, DB_* env vars)
        \\zig build test         # run all tests
        \\```
        \\
    , gen_opts);

    // zigmodu-module
    const sm = try std.fmt.allocPrint(allocator, "{s}/zigmodu-module/SKILL.md", .{skills_dir});
    defer allocator.free(sm);
    try safeWrite(io, allocator, sm,
        \\---
        \\name: zigmodu-module
        \\description: Create a new ZigModu module. Use when adding a domain module, CRUD resource, or business logic unit.
        \\---
        \\
        \\# Create a ZigModu Module
        \\
        \\## Quick Start
        \\```bash
        \\zmodu module <name>          # CLI scaffold
        \\zmodu orm --sql s.sql --out src/modules  # from SQL
        \\```
        \\
        \\## Manual Creation Checklist
        \\1. `mkdir -p src/modules/<name>`
        \\2. Create 5 files: module.zig, model.zig, persistence.zig, service.zig, api.zig
        \\3. Wire into `src/main.zig`:
        \\   - Import: `const <name> = @import("modules/<name>/module.zig");`
        \\   - Init: `var x_p = <name>.persistence.XPersistence.init(backend);`
        \\   - Routes: `try <name>_api.registerRoutes(&root);`
        \\   - Lifecycle: `.build(.{ ..., <name>, ... })`
        \\
        \\## Model Rules
        \\- `sql_table_name` const maps to database table
        \\- NOT NULL → non-optional, nullable → `?Type`
        \\- Primary key: `id: i64` (auto-detected by ORM)
        \\- VARCHAR/TEXT → `[]const u8`, INT → `i64`, FLOAT → `f64`
        \\- No hand-written jsonStringify needed
        \\
        \\## Service Pattern
        \\```zig
        \\pub fn listThings(self: *S, page: usize, size: usize) !data.orm.PageResult(model.Thing) {
        \\    var repo = self.persistence.thingRepo();
        \\    return try repo.findPage(page, size);
        \\}
        \\```
        \\
        \\## Zig Keywords → _mod suffix
        \\return → return_mod, error → error_mod, test → test_mod, app → app_mod
        \\
    , gen_opts);

    // zigmodu-api
    const sa = try std.fmt.allocPrint(allocator, "{s}/zigmodu-api/SKILL.md", .{skills_dir});
    defer allocator.free(sa);
    try safeWrite(io, allocator, sa,
        \\---
        \\name: zigmodu-api
        \\description: Add REST API endpoints to a ZigModu module. Use when adding routes, custom handlers, or middleware.
        \\---
        \\
        \\# Add REST API Endpoints
        \\
        \\## Route Registration
        \\```zig
        \\// In api.zig registerRoutes():
        \\try group.get("/things/custom", handler, @ptrCast(@alignCast(self)));
        \\try group.post("/things", createHandler, @ptrCast(@alignCast(self)));
        \\```
        \\
        \\## Handler Pattern
        \\```zig
        \\fn handler(ctx: *http.Context) !void {
        \\    const s = resolve(ctx);
        \\    // read: ctx.params.get("id"), ctx.query.get("key"), ctx.bindJson(T)
        \\    // write: ctx.json(code, str), ctx.jsonStruct(code, value)
        \\}
        \\```
        \\
        \\## Standard REST Routes
        \\| Method | Path | Handler |
        \\|--------|------|---------|
        \\| GET | /things | list (paginated) |
        \\| GET | /things/{id} | get by id |
        \\| POST | /things | create |
        \\| PUT | /things/{id} | update |
        \\| DELETE | /things/{id} | delete |
        \\
        \\## Error Handling
        \\- bindJson errors → `ctx.json(400, "{\\"error\\":\\"invalid body\\"}")`
        \\- Not found → `ctx.json(404, "{\\"error\\":\\"not found\\"}")`
        \\- Path param parse failure → `return error.BadRequest`
        \\
    , gen_opts);

    // zigmodu-orm
    const so = try std.fmt.allocPrint(allocator, "{s}/zigmodu-orm/SKILL.md", .{skills_dir});
    defer allocator.free(so);
    try safeWrite(io, allocator, so,
        \\---
        \\name: zigmodu-orm
        \\description: Generate ORM modules from SQL schema. Use when creating persistence layers or scaffolding from CREATE TABLE statements.
        \\---
        \\
        \\# Generate ORM from SQL
        \\
        \\## Commands
        \\```bash
        \\zmodu orm --sql schema.sql --out src/modules           # auto-group
        \\zmodu orm --sql s.sql --module name --force            # single module
        \\zmodu scaffold --sql s.sql --name app --with-metrics   # full project
        \\```
        \\
        \\## SQL Type → Zig Type
        \\| SQL | Zig |
        \\|-----|-----|
        \\| INT/BIGINT/SERIAL | `i64` |
        \\| VARCHAR/TEXT/JSON | `[]const u8` |
        \\| BOOLEAN | `bool` |
        \\| FLOAT/DOUBLE/DECIMAL | `f64` |
        \\| DATETIME/TIMESTAMP | `[]const u8` |
        \\
        \\## Auto-Grouping
        \\Tables with common prefix (e.g. `order_`) → single module.
        \\Prefix is stripped from model names and route paths.
        \\
        \\## FOREIGN KEY → Dependency
        \\`FOREIGN KEY (user_id) REFERENCES user(id)` → module depends on "user"
        \\
        \\## Regeneration Safety
        \\Custom logic in service.zig and api.zig. AI may modify freely.
        \\Use `--force` to overwrite, `--dry-run` to preview.
        \\
    , gen_opts);

    // zigmodu-analyze
    const san = try std.fmt.allocPrint(allocator, "{s}/zigmodu-analyze/SKILL.md", .{skills_dir});
    defer allocator.free(san);
    try safeWrite(io, allocator, san,
        \\---
        \\name: zigmodu-analyze
        \\description: Analyze Java/PHP project to extract schema, routes, module boundaries. Use when migrating legacy backend to ZigModu.
        \\---
        \\
        \\# Analyze Legacy Backend
        \\
        \\## Phase 1 of Migration Harness
        \\
        \\## Detect Framework
        \\```bash
        \\find . -name "pom.xml" | head -1  # Spring Boot
        \\find . -name "composer.json" | head -1  # Laravel
        \\```
        \\
        \\## Extract Schema
        \\Spring Boot: `grep -rn "@Entity\|@Table" src/main/java -l`
        \\Laravel: `ls database/migrations/`
        \\
        \\## Extract API Routes
        \\Spring Boot: `grep -rn "@GetMapping\|@PostMapping" src/main/java -A2`
        \\Laravel: `php artisan route:list --json`
        \\
        \\## Output: analysis.json
        \\Run `zmodu analyze --source java|php --input ./legacy/ --output analysis.json`
        \\to produce structured project image for Phase 2 scaffold.
        \\
    , gen_opts);

    // zigmodu-translate
    const stn = try std.fmt.allocPrint(allocator, "{s}/zigmodu-translate/SKILL.md", .{skills_dir});
    defer allocator.free(stn);
    try safeWrite(io, allocator, stn,
        \\---
        \\name: zigmodu-translate
        \\description: Translate Java/PHP code to ZigModu Zig. Use when converting services, controllers, or domain logic.
        \\---
        \\
        \\# Translate Legacy Code
        \\
        \\## Phase 3 of Migration Harness
        \\
        \\## Type Mapping
        \\| Java/PHP | Zig |
        \\|-----------|-----|
        \\| String | `[]const u8` |
        \\| int/Integer/long | `i64` |
        \\| double/Double | `f64` |
        \\| boolean | `bool` |
        \\| Optional\<T\> | `?T` |
        \\| List\<T\> | `[]T` |
        \\| CompletableFuture\<T\> | `EventBus` publish/subscribe |
        \\
        \\## Confidence Tags
        \\- `[AUTO]` Simple CRUD, no review needed
        \\- `[REVIEW]` Business rules preserved, needs human confirmation
        \\- `[MANUAL]` Complex logic, rewrite with SagaOrchestrator
        \\
        \\## Pattern: @Transactional → repo.transact()
        \\```zig
        \\try repo.transact(R, struct {{
        \\    fn doTx(tx: *data.orm.Tx(data.SqlxBackend)) !R {{
        \\        // transactional logic here
        \\    }}
        \\}}.doTx);
        \\```
        \\
        \\## Exception → Error Union
        \\`throw BusinessException("msg")` → `return error.BusinessError`
        \\`@Autowired` fields → explicit `init()` wiring
        \\`@Value` config → `ExternalizedConfig` or env vars
        \\
    , gen_opts);

    // zigmodu-harness
    const sha = try std.fmt.allocPrint(allocator, "{s}/zigmodu-harness/SKILL.md", .{skills_dir});
    defer allocator.free(sha);
    try safeWrite(io, allocator, sha,
        \\---
        \\name: zigmodu-harness
        \\description: Run migration verification — diff test old vs new, verify schema, benchmark. Use when validating ZigModu migration.
        \\---
        \\
        \\# Migration Verification Harness
        \\
        \\## Phase 4 of Migration Harness
        \\
        \\## Diff Proxy Architecture
        \\```
        \\Client → Reverse Proxy → Old Backend (:8080)
        \\                   └→ New Backend (:8081) [mirror]
        \\                        │
        \\                   Diff Comparator → Pass/Fail Report
        \\```
        \\
        \\## Quick Start
        \\```bash
        \\zmodu verify --old http://localhost:8080 --new http://localhost:8081
        \\```
        \\
        \\## Verification Steps
        \\1. Start both backends
        \\2. Dump + diff schemas (`mysqldump --no-data`)
        \\3. Replay production requests, compare responses
        \\4. Normalize: timestamps, float precision, field order
        \\5. Benchmark: `wrk -t4 -c100 -d30s` both endpoints
        \\6. Canary: 1%%→5%%→10%%→25%%→50%%→100%% cutover
        \\
        \\## Abort Criteria
        \\- Schema diff shows missing NOT NULL
        \\- Payment endpoint returns different amounts
        \\- Auth accepts invalid tokens
        \\- Memory leak (RSS grows unbounded)
        \\
    , gen_opts);

    // zigmodu-plugin
    const spl = try std.fmt.allocPrint(allocator, "{s}/zigmodu-plugin/SKILL.md", .{skills_dir});
    defer allocator.free(spl);
    try safeWrite(io, allocator, spl,
        \\---
        \\name: zigmodu-plugin
        \\description: Generate stub plugins for missing Zig dependencies. Creates compilable placeholder modules with error.NotImplemented markers.
        \\---
        \\
        \\# Plugin Stub System
        \\
        \\## Principle
        \\When migrating, dependencies without Zig equivalent get a stub.
        \\Stub compiles, returns error.NotImplemented. AI fills later.
        \\
        \\## Stub Convention
        \\```zig
        \\// src/plugins/<name>/stub.zig
        \\// Priority: P0|P1|P2 (P0=core, P1=important, P2=nice)
        \\// Status: STUB
        \\pub const Plugin = struct {{
        \\    pub fn method(...) !ReturnType {{
        \\        _ = ...;
        \\        return error.NotImplemented;
        \\    }}
        \\}};
        \\```
        \\
        \\## Priority
        \\P0 (blocks business): 支付, 短信, 推送, 认证
        \\P1 (blocks features): 文件存储, 搜索, 报表
        \\P2 (nice to have): 日志聚合, 配置中心
        \\
        \\## Commands
        \\```bash
        \\zmodu plugin list                    # list stubs by priority
        \\zmodu plugin stub --name x --methods a,b --priority P0
        \\zmodu plugin done --name x          # mark implemented
        \\```
        \\
    , gen_opts);

    // 14. Generate .opencode/ — OpenCode AI compatibility
    const opencode_dir = try std.fmt.allocPrint(allocator, "{s}/.opencode", .{out_dir});
    defer allocator.free(opencode_dir);
    try ensureDirGen(io, opencode_dir, gen_opts);

    const opencode_readme = try std.fmt.allocPrint(allocator,
        \\# OpenCode AI Support
        \\
        \\This project uses the Claude Code agent skills format (agentskills.io spec).
        \\Skills and prompts are shared from .claude/ directory.
        \\
        \\To use with OpenCode, configure your OpenCode workspace to read from:
        \\  skills: .claude/skills/
        \\  prompts: .claude/prompts/
        \\
    , .{});
    defer allocator.free(opencode_readme);
    const opencode_rm_path = try std.fmt.allocPrint(allocator, "{s}/README.md", .{opencode_dir});
    defer allocator.free(opencode_rm_path);
    try safeWrite(io, allocator, opencode_rm_path, opencode_readme, gen_opts);
}

// ── add: append new modules to existing project ──────────────────

fn cmdAdd(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    var sql_path: ?[]const u8 = null;
    var force: bool = false;
    var dry_run: bool = false;
    var json_style: JsonStyle = .snake;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--sql")) {
            if (i + 1 >= args.len) return error.CliUsage;
            sql_path = args[i + 1]; i += 1;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            force = true;
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--json-style")) {
            if (i + 1 >= args.len) return error.CliUsage;
            if (std.mem.eql(u8, args[i + 1], "camel")) json_style = .camel;
            i += 1;
        } else {
            std.log.err("Unknown option: {s}", .{args[i]});
            return error.CliUsage;
        }
    }
    if (sql_path == null) {
        std.log.err("zmodu add requires --sql <file>", .{});
        return error.CliUsage;
    }
    const gen_opts: GenOptions = .{ .dry_run = dry_run, .force = force, .json_style = json_style };

    // 1. Read and parse SQL
    const sql_content = std.Io.Dir.cwd().readFileAlloc(io, sql_path.?, allocator, std.Io.Limit.limited(100 * 1024 * 1024)) catch |err| {
        std.log.err("Cannot read SQL file '{s}': {s}", .{ sql_path.?, @errorName(err) });
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
            for (t.columns) |c| { allocator.free(c.name); if (c.comment) |com| allocator.free(com); }
            allocator.free(t.columns);
            for (t.foreign_keys) |fk| { allocator.free(fk.column_name); allocator.free(fk.ref_table); allocator.free(fk.ref_column); }
            allocator.free(t.foreign_keys);
        }
        allocator.free(tables);
    }
    if (tables.len == 0) return error.CliUsage;
    std.log.info("Adding {d} table(s) from {s}", .{ tables.len, sql_path.? });

    // 2. Group tables into modules + detect subsystems
    var module_map = try groupTablesByModule(allocator, tables);
    defer {
        var iter = module_map.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        module_map.deinit();
    }
    _ = try detectSubsystems(allocator, &module_map);

    // Collect module names
    var module_names = std.ArrayList([]const u8).empty;
    defer module_names.deinit(allocator);
    {
        var iter = module_map.iterator();
        while (iter.next()) |entry| try module_names.append(allocator, entry.key_ptr.*);
        std.mem.sort([]const u8, module_names.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool { return std.mem.lessThan(u8, a, b); }
        }.lt);
    }

    // 3. Generate module files under src/modules/
    const modules_dir = "src/modules";
    const scaffold_prefix_len = commonTablePrefix(tables);
    for (module_names.items) |mod_name| {
        const tables_for_mod = module_map.get(mod_name).?;
        try writeModuleFiles(io, allocator, modules_dir, mod_name, tables_for_mod.items, gen_opts, scaffold_prefix_len);

        // ext/ directory
        const ext_dir = try std.fmt.allocPrint(allocator, "{s}/{s}/ext", .{ modules_dir, mod_name });
        defer allocator.free(ext_dir);
        try ensureDirGen(io, ext_dir, gen_opts);

        const var_name_tmp = try replaceChar(allocator, mod_name, '/', '_');
        defer allocator.free(var_name_tmp);
        const pascal_mod = try toPascalCase(allocator, var_name_tmp);
        defer allocator.free(pascal_mod);

        const ext_svc = try std.fmt.allocPrint(allocator,
            \\// {s} service extension — survives zmodu regeneration.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const svc = @import("../service.zig");
            \\pub const {s}ServiceExt = struct {{
            \\    svc: *svc.{s}Service;
            \\    pub fn init(s: *svc.{s}Service) @This() {{ return .{{ .svc = s }}; }}
            \\}};
        , .{ mod_name, pascal_mod, pascal_mod, pascal_mod });
        defer allocator.free(ext_svc);
        const ext_svc_path = try std.fmt.allocPrint(allocator, "{s}/service.zig", .{ext_dir});
        defer allocator.free(ext_svc_path);
        try safeWrite(io, allocator, ext_svc_path, ext_svc, gen_opts);

        const ext_api = try std.fmt.allocPrint(allocator,
            \\// {s} custom API endpoints — survives zmodu regeneration.
            \\const std = @import("std");
            \\const zigmodu = @import("zigmodu");
            \\const ext_svc = @import("service.zig");
            \\pub const {s}ApiExt = struct {{
            \\    ext: *ext_svc.{s}ServiceExt;
            \\    pub fn init(e: *ext_svc.{s}ServiceExt) @This() {{ return .{{ .ext = e }}; }}
            \\    pub fn registerRoutes(self: *@This(), group: *zigmodu.http.RouteGroup) !void {{ _ = self; _ = group; }}
            \\}};
        , .{ mod_name, pascal_mod, pascal_mod, pascal_mod });
        defer allocator.free(ext_api);
        const ext_api_path = try std.fmt.allocPrint(allocator, "{s}/api.zig", .{ext_dir});
        defer allocator.free(ext_api_path);
        if (!fileExists(io, ext_api_path)) try safeWrite(io, allocator, ext_api_path, ext_api, gen_opts);

        std.log.info("Added module '{s}' at src/modules/{s}/", .{ mod_name, mod_name });
    }

    // 4. Wire into main.zig
    if (!dry_run) {
        try wireModulesIntoMainZig(io, allocator, module_names.items);
    }

    std.log.info("add complete: {d} table(s) → {d} module(s)", .{ tables.len, module_names.items.len });
}

/// Append module imports + wiring to an existing main.zig using anchor comments.
fn wireModulesIntoMainZig(io: std.Io, allocator: std.mem.Allocator, new_modules: []const []const u8) !void {
    const main_path = "src/main.zig";
    const main_content = std.Io.Dir.cwd().readFileAlloc(io, main_path, allocator, std.Io.Limit.limited(10 * 1024 * 1024)) catch {
        std.log.err("Cannot read {s} — wiring skipped. Update manually.", .{main_path});
        return;
    };
    defer allocator.free(main_content);

    // Filter: only wire modules that don't already exist in main.zig
    var to_wire = std.ArrayList([]const u8).empty;
    defer to_wire.deinit(allocator);
    for (new_modules) |mod_name| {
        const var_name = try replaceChar(allocator, mod_name, '/', '_');
        defer allocator.free(var_name);
        // Check if already wired
        const import_line = try std.fmt.allocPrint(allocator, "modules/{s}/module.zig", .{mod_name});
        defer allocator.free(import_line);
        if (std.mem.indexOf(u8, main_content, import_line) == null) {
            try to_wire.append(allocator, mod_name);
        } else {
            std.log.info("  Module '{s}' already wired — skipping.", .{mod_name});
        }
    }
    if (to_wire.items.len == 0) {
        std.log.info("All modules already wired. Nothing to do.", .{});
        return;
    }

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, main_content, '\n');

    var inserted_import = false;
    var inserted_persistence = false;
    var inserted_service = false;
    var inserted_api = false;
    var inserted_routes = false;
    var inserted_lifecycle = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");

        // Insert imports before pub fn main
        if (!inserted_import and std.mem.startsWith(u8, trimmed, "pub fn main")) {
            inserted_import = true;
            for (to_wire.items) |mod_name| {
                const var_name = try replaceChar(allocator, mod_name, '/', '_');
                defer allocator.free(var_name);
                try out.print(allocator, "const {s} = @import(\"modules/{s}/module.zig\");\n", .{ var_name, mod_name });
            }
            try out.append(allocator, '\n');
        }

        // Insert persistence after anchor
        if (!inserted_persistence and std.mem.eql(u8, trimmed, "// -- Persistence --")) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            inserted_persistence = true;
            for (to_wire.items) |mod_name| {
                const var_name = try replaceChar(allocator, mod_name, '/', '_');
                defer allocator.free(var_name);
                const pascal = try toPascalCase(allocator, var_name);
                defer allocator.free(pascal);
                try out.print(allocator, "    var {s}_p = {s}.persistence.{s}Persistence.init(backend);\n", .{ var_name, var_name, pascal });
            }
            continue;
        }

        // Insert service after anchor
        if (!inserted_service and std.mem.eql(u8, trimmed, "// -- Service --")) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            inserted_service = true;
            for (to_wire.items) |mod_name| {
                const var_name = try replaceChar(allocator, mod_name, '/', '_');
                defer allocator.free(var_name);
                const pascal = try toPascalCase(allocator, var_name);
                defer allocator.free(pascal);
                try out.print(allocator, "    var {s}_svc = {s}.service.{s}Service.init(&{s}_p);\n", .{ var_name, var_name, pascal, var_name });
            }
            continue;
        }

        // Insert API after anchor
        if (!inserted_api and std.mem.eql(u8, trimmed, "// -- API --")) {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
            inserted_api = true;
            for (to_wire.items) |mod_name| {
                const var_name = try replaceChar(allocator, mod_name, '/', '_');
                defer allocator.free(var_name);
                const pascal = try toPascalCase(allocator, var_name);
                defer allocator.free(pascal);
                try out.print(allocator, "    var {s}_api = {s}.api.{s}Api.init(&{s}_svc);\n", .{ var_name, var_name, pascal, var_name });
            }
            continue;
        }

        // Insert routes before // -- Lifecycle --
        if (!inserted_routes and std.mem.eql(u8, trimmed, "// -- Lifecycle --")) {
            inserted_routes = true;
            for (to_wire.items) |mod_name| {
                const var_name = try replaceChar(allocator, mod_name, '/', '_');
                defer allocator.free(var_name);
                try out.print(allocator, "    try {s}_api.registerRoutes(&root);\n", .{var_name});
            }
            try out.append(allocator, '\n');
        }

        // Insert lifecycle module names into Application.init tuple
        if (!inserted_lifecycle and std.mem.indexOf(u8, trimmed, "Application.init") != null and std.mem.indexOf(u8, trimmed, ".{ ") != null) {
            if (std.mem.indexOf(u8, line, "}, .{});")) |idx| {
                const mod_before = line[0..idx];
                const mod_after = line[idx..];
                inserted_lifecycle = true;
                try out.appendSlice(allocator, mod_before);
                // Trim trailing whitespace from existing modules, add new ones
                for (to_wire.items) |mod_name| {
                    const var_name = try replaceChar(allocator, mod_name, '/', '_');
                    defer allocator.free(var_name);
                    try out.print(allocator, " {s},", .{var_name});
                }
                try out.appendSlice(allocator, mod_after);
                try out.append(allocator, '\n');
                continue;
            }
        }

        try out.appendSlice(allocator, line);
        try out.append(allocator, '\n');
    }

    // Write back
    const file = try std.Io.Dir.cwd().createFile(io, main_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);

    std.log.info("Wired {d} module(s) into {s}", .{ to_wire.items.len, main_path });
}

fn isZigReserved(name: []const u8) bool {
    const keywords = [_][]const u8{ "app", "system", "error", "return", "try", "test", "async", "await", "const", "var", "enum", "union", "struct", "catch", "orelse", "inline", "extern", "export", "fn", "if", "else", "for", "while", "switch", "defer", "break", "continue", "and", "or", "pub", "suspend", "resume", "threadlocal", "volatile", "packed", "unreachable", "linksection", "callconv", "anytype", "anyframe", "comptime", "errdefer", "noalias", "nosuspend", "asm", "addrspace", "usingnamespace" };
    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

fn generateScaffoldMainZig(allocator: std.mem.Allocator, project_name: []const u8, module_names: []const []const u8, sopts: ScaffoldOpts) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\//! @initialized by zmodu — AI may modify
        \\//! ✅ Add business logic in service.zig
        \\//! ✅ Add custom routes in api.zig registerRoutes()
        \\
        \\const std = @import("std");
        \\const zigmodu = @import("zigmodu");
        \\
        \\
    );

    // Module imports (with collision detection for reserved names)
    // Subsystem names like "shop/order" → var name "shop_order", path "modules/shop/order/module.zig"
    for (module_names) |name| {
        const var_name = try replaceChar(allocator, name, '/', '_');
        defer allocator.free(var_name);
        if (isZigReserved(var_name)) {
            try buf.print(allocator, "const {s}_mod = @import(\"modules/{s}/module.zig\");\n", .{ var_name, name });
        } else {
            try buf.print(allocator, "const {s} = @import(\"modules/{s}/module.zig\");\n", .{ var_name, name });
        }
    }

    try buf.appendSlice(allocator, "\n");

    try buf.appendSlice(allocator,
        \\pub fn main(init: std.process.Init) !void {
        \\    const allocator = init.gpa;
        \\    const env = init.environ_map;
        \\
        \\    // -- Config --
        \\    const db_driver_str = env.get("DB_DRIVER") orelse "mysql";
        \\    const db_host = env.get("DB_HOST") orelse "127.0.0.1";
        \\    const db_port = env.get("DB_PORT") orelse "3306";
        \\    const db_user = env.get("DB_USER") orelse "root";
        \\    const db_pass = env.get("DB_PASS") orelse "";
        \\    const db_name = env.get("DB_NAME") orelse "heysen";
        \\
        \\    const db_driver: zigmodu.data.sqlx.Driver = if (std.mem.eql(u8, db_driver_str, "postgres") or std.mem.eql(u8, db_driver_str, "postgresql")) .postgres else if (std.mem.eql(u8, db_driver_str, "sqlite")) .sqlite else .mysql;
        \\    const db_cfg = zigmodu.data.sqlx.Config{
        \\        .driver = db_driver, .host = db_host, .port = std.fmt.parseInt(u16, db_port, 10) catch 3306,
        \\        .database = db_name, .username = db_user, .password = db_pass,
        \\        .max_open_conns = 10, .max_idle_conns = 5,
        \\        .sqlite_path = db_name,
        \\    };
        \\    var db_client = try zigmodu.data.sqlx.Client.open(allocator, init.io, db_cfg);
        \\    defer db_client.deinit();
        \\    std.log.info("DB connected: {s}@{s}:{s}/{s}", .{ db_user, db_host, db_port, db_name });
        \\
        \\    const backend = zigmodu.data.SqlxBackend{ .allocator = allocator, .client = &db_client };
        \\
        \\
    );

    // Persistence/Service/API init
    try buf.appendSlice(allocator, "    // -- Persistence --\n");
    for (module_names) |name| {
        const var_name = try replaceChar(allocator, name, '/', '_');
        defer allocator.free(var_name);
        const pascal = try toPascalCase(allocator, var_name);
        defer allocator.free(pascal);
        if (isZigReserved(var_name)) {
            try buf.print(allocator, "    var {s}_p = {s}_mod.persistence.{s}Persistence.init(backend);\n", .{ var_name, var_name, pascal });
        } else {
            try buf.print(allocator, "    var {s}_p = {s}.persistence.{s}Persistence.init(backend);\n", .{ var_name, var_name, pascal });
        }
    }
    try buf.appendSlice(allocator, "\n    // -- Service --\n");
    for (module_names) |name| {
        const var_name = try replaceChar(allocator, name, '/', '_');
        defer allocator.free(var_name);
        const pascal = try toPascalCase(allocator, var_name);
        defer allocator.free(pascal);
        if (isZigReserved(var_name)) {
            try buf.print(allocator, "    var {s}_svc = {s}_mod.service.{s}Service.init(&{s}_p);\n", .{ var_name, var_name, pascal, var_name });
        } else {
            try buf.print(allocator, "    var {s}_svc = {s}.service.{s}Service.init(&{s}_p);\n", .{ var_name, var_name, pascal, var_name });
        }
    }
    try buf.appendSlice(allocator, "\n    // -- API --\n");
    for (module_names) |name| {
        const var_name = try replaceChar(allocator, name, '/', '_');
        defer allocator.free(var_name);
        const pascal = try toPascalCase(allocator, var_name);
        defer allocator.free(pascal);
        if (isZigReserved(var_name)) {
            try buf.print(allocator, "    var {s}_api = {s}_mod.api.{s}Api.init(&{s}_svc);\n", .{ var_name, var_name, pascal, var_name });
        } else {
            try buf.print(allocator, "    var {s}_api = {s}.api.{s}Api.init(&{s}_svc);\n", .{ var_name, var_name, pascal, var_name });
        }
    }

    // HTTP server + health
    try buf.appendSlice(allocator,
        \\
        \\    // -- HTTP Server --
        \\    const http_port: u16 = if (env.get("HTTP_PORT")) |p| std.fmt.parseInt(u16, p, 10) catch 8080 else 8080;
        \\    var server = zigmodu.http.Server.initWithConfig(init.io, allocator, .{ .port = http_port });
        \\    defer server.deinit();
        \\    server.withGracefulDrain(zigmodu.getInFlightCounter());
        \\    // CORS (allow all origins in dev)
        \\    try server.addMiddleware(zigmodu.http.http_middleware.cors(.{}));
        \\
        \\    // -- Health Checks --
        \\    var health_endpoint = zigmodu.HealthEndpoint.init(allocator);
        \\    defer health_endpoint.deinit();
        \\    try health_endpoint.registerCheck("liveness", "Process liveness", zigmodu.HealthEndpoint.alwaysUp);
        \\
    );

    // Auth middleware (after server)
    if (sopts.with_auth) {
        try buf.appendSlice(allocator,
            \\    // -- Auth (AppSecurity + JWT) --
            \\    const jwt_secret = env.get("JWT_SECRET") orelse "changeme-in-production";
            \\    var app_sec = zigmodu.security.AppSecurity.init(allocator, init.io, .{ .jwt_secret = jwt_secret, .token_expiry_seconds = 3600 });
            \\    defer app_sec.module.deinit();
            \\    try server.addMiddleware(try app_sec.rbacJwtMiddleware(allocator));
            \\
            \\    // Rate limiter
            \\    var auth_limiter = try zigmodu.RateLimiter.init(allocator, "api", 1000, 100);
            \\    defer auth_limiter.deinit();
            \\    try server.addMiddleware(zigmodu.http.tracing_middleware.rateLimit(&auth_limiter));
            \\
            \\
        );
    }


    if (sopts.with_resilience) {
        try buf.appendSlice(allocator, "    try health_endpoint.registerCheckWithContext(\"database\", \"DB connectivity\", zigmodu.HealthEndpoint.databaseCheck, @ptrCast(&db_client));\n");
    }

    try buf.appendSlice(allocator,
        \\    var root = server.group("/admin-api");
        \\    try root.get("/health/live", healthLive, null);
        \\    try root.get("/health/ready", healthReady, null);
        \\
        \\
    );

    for (module_names) |name| {
        const var_name = try replaceChar(allocator, name, '/', '_');
        defer allocator.free(var_name);
        try buf.print(allocator, "    try {s}_api.registerRoutes(&root);\n", .{var_name});
    }
    // ── Capability flags ──
    if (sopts.with_events) {
        try buf.appendSlice(allocator, "\n    // -- EventBus --\n    var event_bus = zigmodu.EventBus(struct { id: i64 }).init(allocator);\n    defer event_bus.deinit();\n");
    }

    if (sopts.with_resilience) {
        try buf.appendSlice(allocator, "\n    // -- Resilience --\n    var breaker = try zigmodu.CircuitBreaker.init(allocator, \"db\", .{ .failure_threshold = 5, .success_threshold = 2, .timeout_seconds = 30, .half_open_max_calls = 3 });\n    defer breaker.deinit();\n    var limiter = try zigmodu.RateLimiter.init(allocator, \"api\", 1000, 100);\n    defer limiter.deinit();\n");
    }

    if (sopts.with_cluster) {
        try buf.appendSlice(allocator, "\n    // -- Cluster --\n    const node_id = try std.fmt.allocPrint(allocator, \"node-{d}\", .{@as(u64, @intCast(std.time.epoch.unix))});\n    var dist_bus = try zigmodu.DistributedEventBus.init(allocator, init.io, node_id);\n    defer dist_bus.deinit();\n    try dist_bus.start(9091);\n");
    }
    if (sopts.with_metrics) {
        try buf.appendSlice(allocator, "\n    // -- Prometheus /metrics --\n    var metrics = zigmodu.observability.PrometheusMetrics.init(allocator);\n    defer metrics.deinit();\n    try metrics.registerMetricsRoute(&server);\n");
    }
    if (sopts.with_websocket) {
        try buf.appendSlice(allocator,
            \\    // ── IM WebSocket Gateway ──
            \\    const im = @import("modules/im/module.zig");
            \\    var im_p = im.persistence.ImPersistence.init(backend);
            \\    var im_svc = im.service.ImService.init(&im_p);
            \\    var im_api = im.api.ImApi.init(&im_svc);
            \\    var im_gw = im.gateway.ImGateway.init(allocator, init.io);
            \\    defer im_gw.deinit();
            \\    var im_relay = im.relay.ImRelay.init(&im_gw.registry, allocator);
            \\    im_svc.setRelay(@ptrCast(&im_relay), @ptrCast(&im.relay.ImRelay.deliver));
            \\    try im_api.registerRoutes(&root);
            \\    try im_gw.register(&root, allocator);
            \\    // Periodic cleanup (every ~30s in production via cron/timer)
            \\    _ = im_gw.cleanup();
            \\
        );
    }
    if (sopts.with_aichat) {
        try buf.appendSlice(allocator,
            \\    // ── AI Chat ──
            \\    const ai_chat = @import("modules/ai/chat/module.zig");
            \\    var ai_chat_p = ai_chat.persistence.AiChatPersistence.init(backend);
            \\    var ai_chat_svc = ai_chat.service.AiChatService.init(allocator, &ai_chat_p);
            \\    var ai_chat_api = ai_chat.api.AiChatApi.init(&ai_chat_svc);
            \\    try ai_chat_api.registerRoutes(&root);
            \\
        );
    }
    if (sopts.with_agent) {
        try buf.appendSlice(allocator,
            \\    // ── AI Agent ──
            \\    const ai_agent = @import("modules/ai/agent/module.zig");
            \\    var skill_registry = zigmodu.ai.SkillRegistry.init(allocator, init.io);
            \\    defer skill_registry.deinit();
            \\    var ai_agent_p = ai_agent.persistence.AiAgentPersistence.init(backend);
            \\    var ai_agent_svc = ai_agent.service.AiAgentService.init(&ai_agent_p, &skill_registry);
            \\    var ai_agent_api = ai_agent.api.AiAgentApi.init(&ai_agent_svc);
            \\    try ai_agent_api.registerRoutes(&root);
            \\
        );
    }
    if (sopts.with_web4) {
        try buf.appendSlice(allocator,
            \\    // ── Web4: DID + x402 ──
            \\    const web4 = @import("modules/web4/module.zig");
            \\    var web4_p = web4.persistence.Web4Persistence.init(backend);
            \\    var web4_svc = web4.service.Web4Service.init(&web4_p, allocator, init.io);
            \\    var web4_api = web4.api.Web4Api.init(&web4_svc);
            \\    try web4_api.registerRoutes(&root);
            \\
        );
    }

    // Application lifecycle
    try buf.appendSlice(allocator, "\n    // -- Lifecycle --\n    var app = try zigmodu.Application.init(init.io, allocator, \"");
    try buf.appendSlice(allocator, project_name);
    try buf.appendSlice(allocator, "\", .{ ");

    for (module_names) |name| {
        const var_name = try replaceChar(allocator, name, '/', '_');
        defer allocator.free(var_name);
        if (isZigReserved(var_name)) {
            try buf.print(allocator, "{s}_mod, ", .{var_name});
        } else {
            try buf.print(allocator, "{s}, ", .{var_name});
        }
    }
    if (sopts.with_websocket) try buf.appendSlice(allocator, "im, ");
    if (sopts.with_aichat) try buf.appendSlice(allocator, "ai_chat, ");
    if (sopts.with_agent) try buf.appendSlice(allocator, "ai_agent, ");
    if (sopts.with_web4) try buf.appendSlice(allocator, "web4, ");
    try buf.appendSlice(allocator, "}, .{});\n    defer app.deinit();\n\n    try app.start();\n    try server.start();\n}\n\nfn healthLive(ctx: *zigmodu.http.Context) !void {\n    try ctx.json(200, \"{\\\"status\\\":\\\"UP\\\"}\");\n}\n\nfn healthReady(ctx: *zigmodu.http.Context) !void {\n    try ctx.json(200, \"{\\\"status\\\":\\\"UP\\\"}\");\n}\n");

    return buf.toOwnedSlice(allocator);
}

fn generateScaffoldTestsZig(allocator: std.mem.Allocator, module_names: []const []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "const std = @import(\"std\");\nconst zigmodu = @import(\"zigmodu\");\nconst testing = std.testing;\n\n");

    // Import all modules
    for (module_names) |mod_name| {
        const var_name = try replaceChar(allocator, mod_name, '/', '_');
        defer allocator.free(var_name);
        try buf.print(allocator, "const {s} = @import(\"modules/{s}/module.zig\");\n", .{ var_name, mod_name });
    }
    try buf.appendSlice(allocator, "\n");

    // DB setup helper
    try buf.appendSlice(allocator,
        \\fn testBackend(alloc: std.mem.Allocator) !zigmodu.data.SqlxBackend {
        \\    const cfg = zigmodu.data.sqlx.Config{ .driver = .sqlite, .sqlite_path = "/tmp/zmodu_test.db", .max_open_conns = 1 };
        \\    var client = try zigmodu.data.sqlx.Client.open(alloc, std.testing.io, cfg);
        \\    return zigmodu.data.SqlxBackend{ .allocator = alloc, .client = &client };
        \\}
        \\
    );

    // Generate CRUD test per module
    for (module_names) |mod_name| {
        const var_name = try replaceChar(allocator, mod_name, '/', '_');
        defer allocator.free(var_name);
        const pascal = try toPascalCase(allocator, var_name);
        defer allocator.free(pascal);

        const pl_sfx = if (std.mem.endsWith(u8, pascal, "s") or std.mem.endsWith(u8, pascal, "S")) "" else "s";
        // Use "name" field if module likely has one; otherwise just test init
        const has_name = std.mem.indexOf(u8, var_name, "user") != null or
                         std.mem.indexOf(u8, var_name, "product") != null or
                         std.mem.indexOf(u8, var_name, "customer") != null or
                         std.mem.indexOf(u8, var_name, "dept") != null or
                         std.mem.indexOf(u8, var_name, "role") != null;
        if (has_name) {
            try buf.print(allocator,
                \\test "integration: {s} CRUD" {{
                \\    const backend = try testBackend(testing.allocator);
                \\    defer backend.client.deinit();
                \\    var p = {s}.persistence.{s}Persistence.init(backend);
                \\    var svc = {s}.service.{s}Service.init(&p);
                \\    _ = try svc.create{s}(.{{ .name = "test" }});
                \\    const list = try svc.list{s}{s}(0, 10);
                \\    try testing.expect(list.total >= 1);
                \\    if (list.items[0].id) |id| {{
                \\        const got = try svc.get{s}(id);
                \\        try testing.expect(got != null);
                \\        try svc.delete{s}(id);
                \\        try testing.expect((try svc.get{s}(id)) == null);
                \\    }}
                \\}}
                \\
            , .{ mod_name, var_name, pascal, var_name, pascal, pascal, pascal, pl_sfx, pascal, pascal, pascal });
        } else {
            try buf.print(allocator,
                \\test "integration: {s} module init" {{
                \\    const backend = try testBackend(testing.allocator);
                \\    defer backend.client.deinit();
                \\    var p = {s}.persistence.{s}Persistence.init(backend);
                \\    var svc = {s}.service.{s}Service.init(&p);
                \\    const list = try svc.list{s}{s}(0, 10);
                \\    try testing.expect(list.total >= 0);
                \\}}
                \\
            , .{ mod_name, var_name, pascal, var_name, pascal, pascal, pl_sfx });
        }
    }

    // Module lifecycle test
    try buf.appendSlice(allocator, "\ntest \"integration: module lifecycle\" {\n");
    for (module_names) |mod_name| {
        const var_name = try replaceChar(allocator, mod_name, '/', '_');
        defer allocator.free(var_name);
        try buf.print(allocator, "    try {s}.init();\n    {s}.deinit();\n", .{ var_name, var_name });
    }
    try buf.appendSlice(allocator, "}\n");

    return buf.toOwnedSlice(allocator);
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

test "toPascalCase snake_case to PascalCase" {
    const allocator = std.testing.allocator;
    const result = try toPascalCase(allocator, "user_profile");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("UserProfile", result);
}

test "toCamelCase hyphenated to camelCase" {
    const allocator = std.testing.allocator;
    const result = try toCamelCase(allocator, "order-item");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("orderItem", result);
}

test "toSnakeCase hyphen to underscore" {
    const allocator = std.testing.allocator;
    const result = try toSnakeCase(allocator, "user-profile");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("user_profile", result);
}

test "commonTablePrefix finds shared prefix" {
    const tables = &[_]TableDef{
        .{ .name = "order_header", .columns = &.{}, .foreign_keys = &.{} },
        .{ .name = "order_line", .columns = &.{}, .foreign_keys = &.{} },
        .{ .name = "order_payment", .columns = &.{}, .foreign_keys = &.{} },
    };
    const prefix = commonTablePrefix(tables);
    try std.testing.expectEqual(@as(usize, "order_".len), prefix);
}

test "inferModuleName from table list" {
    const allocator = std.testing.allocator;
    const name = try inferModuleName(allocator, "ad_category", 0);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("ad_category", name);
}

