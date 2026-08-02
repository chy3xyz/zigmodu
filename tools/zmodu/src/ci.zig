//! `zmodu ci` — one-shot quality gate for ZigModu projects.
//!
//! Runs, in order: `zig build` (compile), `zig fmt --check`, `verify`
//! (structure/imports), `audit` (best-practice rules) and `deadcode`.
//! Exit: 0 all pass, 1 any step fails, 2 usage error.

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const verify_mod = @import("verify.zig");
const audit_mod = @import("audit.zig");
const deadcode_mod = @import("deadcode.zig");

pub const usage =
    \\Usage: zmodu ci [dir]
    \\
    \\One-shot quality gate: zig build + zig fmt --check + verify + audit + deadcode.
    \\
    \\Options:
    \\  -h, --help   show this help
    \\
;

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var dir: []const u8 = ".";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            writeOut(io, usage) catch return 1;
            return 0;
        }
        if (arg.len > 0 and arg[0] == '-') return 2;
        dir = arg;
    }

    var failed = false;
    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const stdout = &out_writer.interface;

    stdout.print("== zmodu ci (dir: {s}) ==\n", .{dir}) catch return 1;

    // 1. Compile (zig build).
    const build_res = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build" },
        .cwd = .{ .path = dir },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(8 * 1024 * 1024),
    }) catch |err| {
        stdout.print("[compile] ERROR: cannot run `zig build`: {s}\n", .{@errorName(err)}) catch {};
        stdout.flush() catch {};
        return 1;
    };
    defer {
        allocator.free(build_res.stdout);
        allocator.free(build_res.stderr);
    }
    const build_ok = build_res.term.success();
    if (build_ok) {
        stdout.print("[compile] PASS (zig build)\n", .{}) catch return 1;
    } else {
        failed = true;
        stdout.print("[compile] FAIL (zig build)\n", .{}) catch return 1;
        stdout.writeAll(build_res.stderr) catch {};
        stdout.writeAll(build_res.stdout) catch {};
    }

    // 2. zig fmt --check on existing top-level dirs (src/tools/examples).
    var fmt_args = std.ArrayList([]const u8).empty;
    defer fmt_args.deinit(allocator);
    fmt_args.appendSlice(allocator, &.{ "zig", "fmt", "--check" }) catch return 1;
    for ([_][]const u8{ "src", "tools", "examples" }) |sub| {
        const p = std.fs.path.join(allocator, &.{ dir, sub }) catch continue;
        defer allocator.free(p);
        if (dirExists(io, p)) {
            fmt_args.append(allocator, sub) catch return 1;
        }
    }
    if (fmt_args.items.len > 3) {
        const fmt_res = std.process.run(allocator, io, .{
            .argv = fmt_args.items,
            .cwd = .{ .path = dir },
            .stdout_limit = .limited(8 * 1024 * 1024),
            .stderr_limit = .limited(8 * 1024 * 1024),
        }) catch |err| {
            stdout.print("[fmt] ERROR: cannot run `zig fmt --check`: {s}\n", .{@errorName(err)}) catch {};
            stdout.flush() catch {};
            return 1;
        };
        defer {
            allocator.free(fmt_res.stdout);
            allocator.free(fmt_res.stderr);
        }
        const fmt_ok = fmt_res.term.success();
        if (fmt_ok) {
            stdout.print("[fmt] PASS (zig fmt --check)\n", .{}) catch return 1;
        } else {
            failed = true;
            stdout.print("[fmt] FAIL (zig fmt --check)\n", .{}) catch return 1;
            stdout.writeAll(fmt_res.stderr) catch {};
            stdout.writeAll(fmt_res.stdout) catch {};
        }
    } else {
        stdout.print("[fmt] SKIP (no src/tools/examples dirs)\n", .{}) catch return 1;
    }

    // 3. verify (structure/imports, in-process).
    const report = verify_mod.verifyProject(allocator, io, dir) catch |err| {
        stdout.print("[verify] ERROR: {s}\n", .{@errorName(err)}) catch {};
        stdout.flush() catch {};
        return 1;
    };
    defer {
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
    if (report.pass) {
        stdout.print("[verify] PASS ({s})\n", .{report.summary}) catch return 1;
    } else {
        failed = true;
        stdout.print("[verify] FAIL ({s})\n", .{report.summary}) catch return 1;
        for (report.errors) |e| stdout.print("  {s}\n", .{e}) catch {};
    }

    // 4. audit (best-practice rules, in-process).
    const audit_json = audit_mod.auditJsonFor(io, allocator, dir) catch |err| {
        stdout.print("[audit] ERROR: {s}\n", .{@errorName(err)}) catch {};
        stdout.flush() catch {};
        return 1;
    };
    defer allocator.free(audit_json);
    const audit_pass = jsonPassField(allocator, audit_json) catch false;
    if (audit_pass) {
        stdout.print("[audit] PASS\n", .{}) catch return 1;
    } else {
        failed = true;
        stdout.print("[audit] FAIL\n", .{}) catch return 1;
        stdout.writeAll(audit_json) catch {};
    }

    // 5. deadcode (in-process; prints its own report).
    var dc_paths = std.ArrayList([]const u8).empty;
    defer dc_paths.deinit(allocator);
    var dc_owned = std.ArrayList([]const u8).empty;
    defer {
        for (dc_owned.items) |p| allocator.free(p);
        dc_owned.deinit(allocator);
    }
    dc_paths.append(allocator, "-j") catch return 1;
    for ([_][]const u8{ "src", "tools" }) |sub| {
        const abs = std.fs.path.resolve(allocator, &.{ dir, sub }) catch continue;
        if (dirExists(io, abs)) {
            dc_owned.append(allocator, abs) catch return 1;
            dc_paths.append(allocator, abs) catch return 1;
        } else {
            allocator.free(abs);
        }
    }
    if (dc_paths.items.len > 1) {
        const dc_code = deadcode_mod.run(io, allocator, dc_paths.items);
        if (dc_code == 0) {
            stdout.print("[deadcode] PASS\n", .{}) catch return 1;
        } else if (dc_code == 1) {
            failed = true;
            stdout.print("[deadcode] FAIL (dead declarations found)\n", .{}) catch return 1;
        } else {
            stdout.print("[deadcode] SKIP ({d})\n", .{dc_code}) catch return 1;
        }
    } else {
        stdout.print("[deadcode] SKIP (no src/tools dirs)\n", .{}) catch return 1;
    }

    if (failed) {
        stdout.print("summary: FAIL\n", .{}) catch return 1;
    } else {
        stdout.print("summary: PASS\n", .{}) catch return 1;
    }
    stdout.flush() catch return 1;
    return if (failed) 1 else 0;
}

fn writeOut(io: Io, s: []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const stdout = &out_writer.interface;
    try stdout.writeAll(s);
    try stdout.flush();
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn jsonPassField(allocator: std.mem.Allocator, json: []const u8) !bool {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuditJson;
    const pass = parsed.value.object.get("pass") orelse return error.InvalidAuditJson;
    if (pass != .bool) return error.InvalidAuditJson;
    return pass.bool;
}
