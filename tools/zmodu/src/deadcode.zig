//! Dead-code analysis for Zig projects, modeled after rustc's `dead_code`
//! lint (upstream: github.com/chy3xyz/zdeadcode). Integrated as the
//! `zmodu deadcode` command: scans Zig source files and reports declarations
//! that are never used — unused top-level fns/consts/vars, container fields,
//! enum variants, methods, nested types, and never-imported modules.

const std = @import("std");
const analyze = @import("deadcode/analyze.zig");
const scanner = @import("deadcode/scanner.zig");
const report = @import("deadcode/report.zig");

const usage =
    \\Usage: zmodu deadcode [options] [path ...]
    \\
    \\Scans Zig source files and reports declarations that are never used.
    \\If no path is given, the current directory is scanned.
    \\
    \\Options:
    \\  -b, --binary       binary mode: 'main' is an entry point and modules
    \\                     that are never imported are reported
    \\  -p, --include-pub  also report unused pub declarations
    \\  -n, --no-tests     do not treat test declarations as entry points
    \\  -m, --no-members   disable the container member heuristic ('.name' = use)
    \\  -F, --no-files     disable never-imported module reporting
    \\  -g, --no-gitignore ignore .gitignore files during scanning
    \\  -j, --json         emit machine-readable JSON
    \\  -v, --verbose      print scan statistics
    \\  -h, --help         show this help
    \\
;

const Cli = struct {
    binary: bool = false,
    include_pub: bool = false,
    no_tests: bool = false,
    no_members: bool = false,
    no_files: bool = false,
    no_gitignore: bool = false,
    json: bool = false,
    verbose: bool = false,
    help: bool = false,
    paths: std.ArrayList([]const u8) = .empty,
};

fn applyFlag(cli: *Cli, arg: []const u8) bool {
    if (std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "--binary")) {
        cli.binary = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--include-pub")) {
        cli.include_pub = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-n") or std.mem.eql(u8, arg, "--no-tests")) {
        cli.no_tests = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--no-members")) {
        cli.no_members = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "--no-files")) {
        cli.no_files = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--no-gitignore")) {
        cli.no_gitignore = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--json")) {
        cli.json = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
        cli.verbose = true;
        return true;
    }
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        cli.help = true;
        return true;
    }
    return false;
}

/// Run the analyzer. `args` are the command-line arguments after `deadcode`
/// (paths + flags). Returns the process exit code (0 clean, 1 findings,
/// 2 scan failed).
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var cli: Cli = .{};
    for (args) |arg| {
        if (!applyFlag(&cli, arg)) {
            cli.paths.append(alloc, arg) catch return fail("out of memory", .{});
        }
    }

    if (cli.help) {
        writeOut(io, usage) catch return 1;
        return 0;
    }

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch |err| {
        return fail("cannot determine current directory: {s}", .{@errorName(err)});
    };
    const cwd = cwd_buf[0..cwd_len];

    const files = scanner.scan(alloc, io, cwd, cli.paths.items, .{
        .gitignore = !cli.no_gitignore,
    }) catch |err| return fail("scan failed: {s}", .{@errorName(err)});

    if (files.len == 0) {
        writeOut(io, "zmodu deadcode: no .zig files found\n") catch return 1;
        return 2;
    }

    var sources: std.ArrayList(analyze.File) = .empty;
    var root_paths: std.ArrayList([]const u8) = .empty;
    for (files) |f| {
        const content = std.Io.Dir.cwd().readFileAlloc(io, f.path, alloc, .unlimited) catch |err| {
            std.debug.print("zmodu deadcode: cannot read {s}: {s}\n", .{ f.display, @errorName(err) });
            continue;
        };
        const source: [:0]u8 = alloc.allocSentinel(u8, content.len, 0) catch |err| {
            return fail("out of memory: {s}", .{@errorName(err)});
        };
        @memcpy(source[0..content.len], content);
        source[content.len] = 0;
        sources.append(alloc, .{ .path = f.path, .display_path = f.display, .source = source }) catch |err| {
            return fail("out of memory: {s}", .{@errorName(err)});
        };
    }

    // Explicitly named files are never reported as never-imported.
    for (cli.paths.items) |p| {
        const abs = std.fs.path.resolve(alloc, &.{ cwd, p }) catch continue;
        root_paths.append(alloc, abs) catch |err| {
            return fail("out of memory: {s}", .{@errorName(err)});
        };
    }

    var result = analyze.analyze(alloc, sources.items, .{
        .include_pub = cli.include_pub,
        .no_tests = cli.no_tests,
        .no_members = cli.no_members,
        .binary = cli.binary,
        .no_files = cli.no_files,
        .root_file_paths = root_paths.items,
    }) catch |err| return fail("analysis failed: {s}", .{@errorName(err)});
    defer result.deinit();

    const output = if (cli.json)
        report.formatJson(alloc, &result, sources.items) catch |err| {
            return fail("formatting failed: {s}", .{@errorName(err)});
        }
    else
        report.formatHuman(alloc, &result, sources.items, .{
            .json = false,
            .verbose = cli.verbose,
        }) catch |err| {
            return fail("formatting failed: {s}", .{@errorName(err)});
        };

    writeOut(io, output) catch |err| {
        return fail("cannot write output: {s}", .{@errorName(err)});
    };

    return if (result.findings.len > 0 or result.unused_files.len > 0) 1 else 0;
}

fn writeOut(io: std.Io, bytes: []const u8) !void {
    try std.Io.File.writeStreamingAll(std.Io.File.stdout(), io, bytes);
}

fn fail(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("zmodu deadcode: " ++ fmt ++ "\n", args);
    return 1;
}
