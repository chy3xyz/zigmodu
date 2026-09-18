// Verify — project verification module for zmodu
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const VerifyStatus = enum { pass, fail, warn, skip };

/// OWNERSHIP: `details` is always an allocation made with the allocator passed to
/// `verifyProject` (never a string literal), so callers may free it unconditionally.
pub const CheckResult = struct {
    name: []const u8,
    status: VerifyStatus,
    details: ?[]const u8 = null,
    duration_ms: ?u64 = null,
};

/// OWNERSHIP: `checks[i].details` is owned; `errors` / `warnings` entries *alias*
/// the details of the corresponding `.fail` / `.warn` check. Callers therefore free
/// pass/skip details plus every error/warning entry — and must not free a failing
/// check's details twice.
pub const VerifyReport = struct {
    pass: bool,
    checks: []CheckResult,
    errors: [][]const u8,
    warnings: [][]const u8,
    summary: []const u8,
};

pub const usage =
    \\Usage: zmodu verify [dir] [--json]
    \\
    \\Verify an existing ZigModu project: module layout, import resolution, compile.
    \\
    \\Arguments:
    \\  dir          project root (default: .)
    \\
    \\Options:
    \\  -j, --json   print the summary as JSON only (no per-check detail)
    \\  -h, --help   show this help
    \\
    \\Module layout rule (src/modules/<module>/):
    \\  Strict: model.zig, persistence.zig, service.zig, api.zig, module.zig, root.zig.
    \\  Loose rule: a module WITHOUT persistence.zig — the table-less / BFF convention
    \\  in docs/MODULITH_TENANT_SHOP.md (no persistence, no own tables) — is accepted
    \\  when its module.zig declares `pub const info`; then only api.zig, module.zig and
    \\  root.zig are required, and model.zig / service.zig may be omitted. Without
    \\  `pub const info` the strict list applies and persistence.zig is reported missing.
    \\  The check output always says when the loose rule was applied, and to which modules.
    \\
    \\Exit codes: 0 checks completed (read the summary), 2 invalid arguments
    \\
;

/// Run all verification checks against a generated project directory.
pub fn verifyProject(allocator: std.mem.Allocator, io: Io, project_dir: []const u8) !VerifyReport {
    var checks = std.ArrayList(CheckResult).empty;
    defer checks.deinit(allocator);

    var errs = std.ArrayList([]const u8).empty;
    defer errs.deinit(allocator);

    var warns = std.ArrayList([]const u8).empty;
    defer warns.deinit(allocator);

    // 1. Module integrity
    const integrity = checkModuleIntegrity(allocator, io, project_dir) catch |err| CheckResult{
        .name = "module_integrity",
        .status = .fail,
        .details = try std.fmt.allocPrint(allocator, "check error: {}", .{err}),
    };
    try checks.append(allocator, integrity);
    if (integrity.status == .warn) {
        if (integrity.details) |d| try warns.append(allocator, d);
    }
    if (integrity.status == .fail) {
        if (integrity.details) |d| try errs.append(allocator, d);
    }

    // 2. Import consistency
    const imports = checkImportConsistency(allocator, io, project_dir) catch |err| CheckResult{
        .name = "import_consistency",
        .status = .fail,
        .details = try std.fmt.allocPrint(allocator, "check error: {}", .{err}),
    };
    try checks.append(allocator, imports);
    if (imports.status == .warn) {
        if (imports.details) |d| try warns.append(allocator, d);
    }
    if (imports.status == .fail) {
        if (imports.details) |d| try errs.append(allocator, d);
    }

    // 3. Compile
    const compile = checkCompile(allocator, io, project_dir) catch |err| CheckResult{
        .name = "compile",
        .status = .fail,
        .details = try std.fmt.allocPrint(allocator, "check error: {}", .{err}),
    };
    try checks.append(allocator, compile);
    if (compile.status == .fail) {
        if (compile.details) |d| try errs.append(allocator, d);
    }

    var all_pass = true;
    for (checks.items) |c| {
        if (c.status == .fail) {
            all_pass = false;
            break;
        }
    }

    const summary_str = if (all_pass) "All checks passed" else "Some checks failed";
    const summary = try allocator.dupe(u8, summary_str);

    return VerifyReport{
        .pass = all_pass,
        .checks = try checks.toOwnedSlice(allocator),
        .errors = try errs.toOwnedSlice(allocator),
        .warnings = try warns.toOwnedSlice(allocator),
        .summary = summary,
    };
}

fn moduleDeclaresInfo(allocator: std.mem.Allocator, io: Io, mod_dir: Dir) bool {
    const src = mod_dir.readFileAlloc(io, "module.zig", allocator, Io.Limit.limited(256 * 1024)) catch return false;
    defer allocator.free(src);
    return std.mem.indexOf(u8, src, "pub const info") != null;
}

/// Check every subdirectory in `src/modules/`:
///   * strict — the 6 files model.zig, persistence.zig, service.zig, api.zig,
///     module.zig, root.zig;
///   * loose rule — a module without `persistence.zig` whose `module.zig` declares
///     `pub const info` is a table-less module (BFF; docs/MODULITH_TENANT_SHOP.md
///     §「BFF 约定」), so only api.zig, module.zig and root.zig are required.
///     Without `pub const info` the strict list applies, so a stray directory still
///     reports persistence.zig as missing.
fn checkModuleIntegrity(allocator: std.mem.Allocator, io: Io, project_dir: []const u8) !CheckResult {
    const required_files = [_][]const u8{ "model.zig", "persistence.zig", "service.zig", "api.zig", "module.zig", "root.zig" };
    const tableless_required_files = [_][]const u8{ "api.zig", "module.zig", "root.zig" };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const modules_path = std.fmt.bufPrint(&path_buf, "{s}/src/modules", .{project_dir}) catch
        return CheckResult{ .name = "module_integrity", .status = .fail, .details = try allocator.dupe(u8, "path too long") };

    const dir = Dir.cwd().openDir(io, modules_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            return CheckResult{ .name = "module_integrity", .status = .warn, .details = try allocator.dupe(u8, "src/modules/ directory not found (new project?)") };
        }
        return CheckResult{ .name = "module_integrity", .status = .fail, .details = try allocator.dupe(u8, "cannot open src/modules/") };
    };
    defer dir.close(io);

    var module_count: usize = 0;
    var tableless_count: usize = 0;
    var tableless_names = std.ArrayList(u8).empty;
    defer tableless_names.deinit(allocator);
    var missing_list = std.ArrayList(u8).empty;
    defer missing_list.deinit(allocator);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        module_count += 1;

        const mod_dir = dir.openDir(io, entry.name, .{}) catch continue;
        defer mod_dir.close(io);

        const owns_tables = blk: {
            mod_dir.access(io, "persistence.zig", .{}) catch break :blk false;
            break :blk true;
        };
        const tableless = !owns_tables and moduleDeclaresInfo(allocator, io, mod_dir);
        if (tableless) {
            tableless_count += 1;
            if (tableless_names.items.len > 0) try tableless_names.appendSlice(allocator, ", ");
            try tableless_names.appendSlice(allocator, entry.name);
        }

        const req_files: []const []const u8 = if (tableless) &tableless_required_files else &required_files;
        for (req_files) |req| {
            mod_dir.access(io, req, .{}) catch {
                try missing_list.appendSlice(allocator, entry.name);
                try missing_list.appendSlice(allocator, "/");
                try missing_list.appendSlice(allocator, req);
                try missing_list.appendSlice(allocator, "\n");
            };
        }
    }

    if (missing_list.items.len > 0) {
        return CheckResult{
            .name = "module_integrity",
            .status = .fail,
            .details = try missing_list.toOwnedSlice(allocator),
        };
    }

    const details = if (tableless_count == 0)
        try std.fmt.allocPrint(allocator, "{d} modules found, all complete", .{module_count})
    else
        try std.fmt.allocPrint(
            allocator,
            "{d} modules found, all complete (loose rule: {d} table-less module(s) accepted without persistence.zig: {s})",
            .{ module_count, tableless_count, tableless_names.items },
        );
    return CheckResult{
        .name = "module_integrity",
        .status = .pass,
        .details = details,
    };
}

/// Walk all `.zig` files in `src/` and verify that every `@import("...")`
/// resolves to an existing file. Skips `std` and `builtin` imports.
fn checkImportConsistency(allocator: std.mem.Allocator, io: Io, project_dir: []const u8) !CheckResult {
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path = std.fmt.bufPrint(&src_buf, "{s}/src", .{project_dir}) catch
        return CheckResult{ .name = "import_consistency", .status = .warn, .details = try allocator.dupe(u8, "path too long") };

    const src_dir = Dir.cwd().openDir(io, src_path, .{ .iterate = true }) catch
        return CheckResult{ .name = "import_consistency", .status = .warn, .details = try allocator.dupe(u8, "src/ directory not found") };
    defer src_dir.close(io);

    var missing_list = std.ArrayList(u8).empty;
    defer missing_list.deinit(allocator);

    try walkAndCheckImports(allocator, io, src_dir, src_path, &missing_list);

    if (missing_list.items.len > 0) {
        return CheckResult{
            .name = "import_consistency",
            .status = .warn,
            .details = try missing_list.toOwnedSlice(allocator),
        };
    }

    return CheckResult{
        .name = "import_consistency",
        .status = .pass,
        .details = try allocator.dupe(u8, "all imports resolved"),
    };
}

/// Recursively walk directories and check `.zig` file imports.
fn walkAndCheckImports(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Dir,
    base_path: []const u8,
    missing: *std.ArrayList(u8),
) !void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        var entry_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const entry_path = std.fmt.bufPrint(&entry_path_buf, "{s}/{s}", .{ base_path, entry.name }) catch continue;

        if (entry.kind == .directory) {
            const sub_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close(io);
            try walkAndCheckImports(allocator, io, sub_dir, entry_path, missing);
        } else if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".zig")) {
            try checkFileImports(allocator, io, dir, entry.name, entry_path, missing);
        }
    }
}

/// Scan a single `.zig` file for `@import("...")` and verify each target exists.
fn checkFileImports(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Dir,
    file_name: []const u8,
    file_abs_path: []const u8,
    missing: *std.ArrayList(u8),
) !void {
    const content = dir.readFileAlloc(io, file_name, allocator, Io.Limit.limited(1024 * 1024)) catch return;
    defer allocator.free(content);

    // Scan for both @import("...") and @embedFile("...")
    const import_prefix = "@import(\"";
    const embedfile_prefix = "@embedFile(\"";
    var pos: usize = 0;
    while (pos < content.len) {
        const import_start = std.mem.indexOfPos(u8, content, pos, import_prefix);
        const embed_start = std.mem.indexOfPos(u8, content, pos, embedfile_prefix);
        const start = blk: {
            if (import_start == null and embed_start == null) break;
            if (import_start == null) break :blk embed_start.?;
            if (embed_start == null) break :blk import_start.?;
            break :blk @min(import_start.?, embed_start.?);
        };
        const is_embed = embed_start != null and start == embed_start.?;
        const prefix_len = if (is_embed) embedfile_prefix.len else import_prefix.len;
        const val_start = start + prefix_len;
        const val_end = std.mem.indexOfScalarPos(u8, content, val_start, '"') orelse break;
        const import_path = content[val_start..val_end];

        // Skip std, builtin, and third-party package imports
        if (!is_embed and (std.mem.eql(u8, import_path, "std") or
            std.mem.eql(u8, import_path, "builtin") or
            std.mem.startsWith(u8, import_path, "zigmodu")))
        {
            pos = val_end + 1;
            continue;
        }

        // Resolve relative to the file's directory
        const file_dir = std.fs.path.dirname(file_abs_path) orelse ".";
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = std.fmt.bufPrint(&resolved_buf, "{s}/{s}", .{ file_dir, import_path }) catch {
            pos = val_end + 1;
            continue;
        };

        // Check if the resolved file exists
        Dir.cwd().access(io, resolved, .{}) catch {
            try missing.appendSlice(allocator, file_abs_path);
            try missing.appendSlice(allocator, " -> ");
            try missing.appendSlice(allocator, import_path);
            try missing.appendSlice(allocator, "\n");
        };

        pos = val_end + 1;
    }
}

/// Spawn `zig build` in the project directory and check if it succeeds.
fn checkCompile(allocator: std.mem.Allocator, io: Io, project_dir: []const u8) !CheckResult {
    return checkCompileWith(allocator, io, project_dir, "zig");
}

/// `zig_exe` is a parameter so tests can exercise the "binary not found" path
/// without mutating PATH. Every `details` string returned here is an allocation
/// (never a literal) — callers free it.
fn checkCompileWith(
    allocator: std.mem.Allocator,
    io: Io,
    project_dir: []const u8,
    zig_exe: []const u8,
) !CheckResult {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ zig_exe, "build" },
        .cwd = .{ .path = project_dir },
    }) catch |err| {
        const msg = if (err == error.FileNotFound)
            try std.fmt.allocPrint(allocator, "zig compiler not found in PATH (or project dir {s} missing): {s}", .{ project_dir, @errorName(err) })
        else
            try std.fmt.allocPrint(allocator, "failed to run zig build in {s}: {}", .{ project_dir, err });
        return CheckResult{
            .name = "compile",
            .status = .fail,
            .details = msg,
        };
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    if (result.term.success()) {
        return CheckResult{ .name = "compile", .status = .pass };
    }

    // Extract first error line from stderr
    var first_line: []const u8 = "unknown error";
    if (result.stderr.len > 0) {
        if (std.mem.indexOfScalar(u8, result.stderr, '\n')) |nl| {
            first_line = std.mem.trim(u8, result.stderr[0..nl], " \r\t");
        } else {
            first_line = std.mem.trim(u8, result.stderr, " \r\t");
        }
    }

    return CheckResult{
        .name = "compile",
        .status = .fail,
        .details = try std.fmt.allocPrint(allocator, "zig build failed: {s}", .{first_line}),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "checkModuleIntegrity detects missing files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create module directory with all files except root.zig
    try tmp.dir.createDirPath(io, "src/modules/testmod");
    const required = [_][]const u8{ "model.zig", "persistence.zig", "service.zig", "api.zig", "module.zig" };
    for (required) |name| {
        var sub_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub = try std.fmt.bufPrint(&sub_buf, "src/modules/testmod/{s}", .{name});
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "// placeholder" });
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const path = path_buf[0..path_len];

    const result = try checkModuleIntegrity(allocator, io, path);
    defer if (result.details) |d| allocator.free(d);
    try std.testing.expect(result.status == .fail);
    try std.testing.expect(result.details != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?, "testmod/root.zig") != null);
}

test "checkModuleIntegrity passes when all files present" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create module directory with all 6 required files
    try tmp.dir.createDirPath(io, "src/modules/testmod");
    const required = [_][]const u8{ "model.zig", "persistence.zig", "service.zig", "api.zig", "module.zig", "root.zig" };
    for (required) |name| {
        var sub_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sub = try std.fmt.bufPrint(&sub_buf, "src/modules/testmod/{s}", .{name});
        try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "// placeholder" });
    }

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const path = path_buf[0..path_len];

    const result = try checkModuleIntegrity(allocator, io, path);
    defer if (result.details) |d| allocator.free(d);
    try std.testing.expect(result.status == .pass);
    try std.testing.expect(result.details != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?, "1 modules found") != null);
}

test "checkImportConsistency finds missing import" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Create src/ directory first, then write the .zig file
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data = "const std = @import(\"std\");\nconst foo = @import(\"nonexistent.zig\");\n",
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const path = path_buf[0..path_len];

    const result = try checkImportConsistency(allocator, io, path);
    defer if (result.details) |d| allocator.free(d);
    try std.testing.expect(result.status == .warn);
    try std.testing.expect(result.details != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?, "nonexistent.zig") != null);
}

fn writeModuleFile(tmp: anytype, sub_path: []const u8, data: []const u8) !void {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = data });
}

test "checkModuleIntegrity accepts table-less (BFF) module without persistence.zig" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/modules/shop_bff");
    try writeModuleFile(&tmp, "src/modules/shop_bff/module.zig", "pub const info = zigmodu.api.Module{ .name = \"shop_bff\" };\n");
    try writeModuleFile(&tmp, "src/modules/shop_bff/api.zig", "// placeholder");
    try writeModuleFile(&tmp, "src/modules/shop_bff/root.zig", "// placeholder");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);

    const result = try checkModuleIntegrity(allocator, io, path_buf[0..path_len]);
    defer if (result.details) |d| allocator.free(d);
    try std.testing.expect(result.status == .pass);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?, "loose rule") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?, "shop_bff") != null);
}

test "checkModuleIntegrity rejects table-less-looking dir without pub const info" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/modules/orphan");
    try writeModuleFile(&tmp, "src/modules/orphan/module.zig", "// no info here");
    try writeModuleFile(&tmp, "src/modules/orphan/api.zig", "// placeholder");
    try writeModuleFile(&tmp, "src/modules/orphan/root.zig", "// placeholder");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);

    const result = try checkModuleIntegrity(allocator, io, path_buf[0..path_len]);
    defer if (result.details) |d| allocator.free(d);
    try std.testing.expect(result.status == .fail);
    try std.testing.expect(std.mem.indexOf(u8, result.details.?, "orphan/persistence.zig") != null);
}

/// Mirrors the free sequence used by `main.zig cmdVerify` / `ci.zig` so the
/// ownership contract of VerifyReport is exercised, not just assumed.
fn freeReportForTest(allocator: std.mem.Allocator, report: VerifyReport) void {
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

test "verifyProject on a missing directory returns an owned report (no literal details)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const missing_dir = "/nonexistent-zmodu-verify-test";
    const report = try verifyProject(allocator, io, missing_dir);
    defer freeReportForTest(allocator, report);

    try std.testing.expect(!report.pass);
    try std.testing.expect(report.errors.len > 0);
    // Freeing above only stays honest if the compile failure is an allocation:
    // it used to be the literal "zig compiler not found in PATH", which aborted
    // the CLI at exit-134. The message must carry the directory, which a literal
    // cannot.
    try std.testing.expect(std.mem.indexOf(u8, report.errors[0], missing_dir) != null);
}

test "checkCompile reports a missing zig binary as an owned string" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "proj");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const project_dir = path_buf[0..path_len];

    const result = try checkCompileWith(allocator, io, project_dir, "zmodu-no-such-zig-binary");
    // Freeing proves the allocation is owned; the interpolated path proves the
    // failure is not a bare string literal.
    defer if (result.details) |d| allocator.free(d);
    try std.testing.expect(result.status == .fail);
    const details = result.details.?;
    try std.testing.expect(std.mem.indexOf(u8, details, "not found in PATH") != null);
    try std.testing.expect(std.mem.indexOf(u8, details, project_dir) != null);
}
