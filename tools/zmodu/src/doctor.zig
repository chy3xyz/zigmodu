//! `zmodu doctor` — architecture health for a project, without compiling it.
//!
//! The framework checks the module graph at **compile time** when the set is a
//! comptime tuple (`ApplicationBuilder.build(.{...})` → `core/ModuleGraph`). That
//! check cannot see two things a reviewer cares about:
//!
//!   * a project whose modules are assembled dynamically (a plugin registry), and
//!   * **source-level entanglement** — `domain/service.zig` reaching into
//!     `infra/persistence.zig` directly, which no module declaration records.
//!
//! So `doctor` re-runs the *same* graph analysis on source it scanned, and adds the
//! import-level check: a file inside module A importing a file inside module B is
//! reported, because that is how a modulith rots — not by declaring a cycle, but by
//! reaching around the declared boundary one import at a time.
//!
//! ```bash
//! zmodu doctor                  # human report, exit 1 on blocking findings
//! zmodu doctor --json           # machine-readable (CI, dashboards)
//! zmodu doctor --max-deps 6     # tightening the advisory threshold
//! zmodu doctor --allow a->b     # acknowledge one entanglement (repeatable)
//! ```

const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const audit = @import("audit.zig");
const graph_mod = @import("module_graph");

pub const Error = error{CliUsage};

const Options = struct {
    dir: []const u8 = ".",
    json: bool = false,
    max_deps: usize = 8,
    /// Entanglements the project has decided to live with, as `"from->to"`.
    allowed: std.ArrayList([]const u8) = .empty,
    /// Skip the source-import scan (graph analysis only).
    skip_imports: bool = false,
};

/// A file in module A importing a file in module B.
const Entanglement = struct {
    from_module: []const u8,
    to_module: []const u8,
    file: []const u8,
    line: usize,
};

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var opts = Options{};
    defer {
        for (opts.allowed.items) |a| allocator.free(a);
        opts.allowed.deinit(allocator);
    }
    parseArgs(allocator, args, &opts) catch {
        std.debug.print(
            \\usage: zmodu doctor [dir] [--json] [--max-deps N] [--allow from->to] [--skip-imports]
            \\
        , .{});
        return 2;
    };

    var modules = std.ArrayList(audit.ModuleRec).empty;
    defer {
        for (modules.items) |*rec| rec.deinit(allocator);
        modules.deinit(allocator);
    }
    audit.collectModules(io, allocator, opts.dir, &modules) catch |err| {
        std.debug.print("doctor: cannot scan modules under '{s}': {s}\n", .{ opts.dir, @errorName(err) });
        return 2;
    };

    // Build the node list the shared analyser takes.
    const nodes = allocator.alloc(graph_mod.Node, modules.items.len) catch return 2;
    defer allocator.free(nodes);
    for (modules.items, 0..) |rec, i| {
        nodes[i] = .{
            .name = rec.name,
            .description = rec.description,
            .dependencies = rec.deps,
            .is_internal = false,
        };
    }

    var owned = graph_mod.analyzeRuntime(allocator, nodes, .{ .max_dependencies = opts.max_deps }) catch return 2;
    defer owned.deinit();

    // Source-level pass: who reaches into whom.
    var entanglements = std.ArrayList(Entanglement).empty;
    defer {
        for (entanglements.items) |e| {
            allocator.free(e.from_module);
            allocator.free(e.to_module);
            allocator.free(e.file);
        }
        entanglements.deinit(allocator);
    }
    if (!opts.skip_imports) {
        scanEntanglements(io, allocator, opts.dir, modules.items, &entanglements, opts.allowed.items) catch |err| {
            std.debug.print("doctor: import scan failed: {s}\n", .{@errorName(err)});
        };
    }

    if (opts.json) {
        var out_buf: [8192]u8 = undefined;
        var out_file = std.Io.File.stdout();
        var out_writer = out_file.writer(io, &out_buf);
        const w = &out_writer.interface;
        renderJson(owned.report, entanglements.items, w) catch return 2;
        w.flush() catch return 2;
    } else {
        var out_buf: [8192]u8 = undefined;
        var out_file = std.Io.File.stdout();
        var out_writer = out_file.writer(io, &out_buf);
        const w = &out_writer.interface;
        graph_mod.renderText(owned.report, w) catch return 2;
        if (entanglements.items.len > 0) {
            w.print("\nentangled imports ({d}):\n", .{entanglements.items.len}) catch return 2;
            for (entanglements.items) |e| {
                w.print("  [warn] {s} -> {s}  ({s}:{d})\n", .{ e.from_module, e.to_module, e.file, e.line }) catch return 2;
            }
            w.writeAll("  (declare the dependency, import the module barrel, or `--allow from->to`)\n") catch return 2;
        }
        w.flush() catch return 2;
    }

    // Blocking findings fail; entanglement is a warning (it is a design smell, not
    // a broken graph) — the same severity split the framework uses at compile time.
    return if (owned.report.ok()) 0 else 1;
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8, opts: *Options) !void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--skip-imports")) {
            opts.skip_imports = true;
        } else if (std.mem.eql(u8, a, "--max-deps")) {
            if (i + 1 >= args.len) return Error.CliUsage;
            i += 1;
            opts.max_deps = std.fmt.parseInt(usize, args[i], 10) catch return Error.CliUsage;
        } else if (std.mem.eql(u8, a, "--allow")) {
            if (i + 1 >= args.len) return Error.CliUsage;
            i += 1;
            try opts.allowed.append(allocator, try allocator.dupe(u8, args[i]));
        } else if (a.len > 0 and a[0] == '-') {
            return Error.CliUsage;
        } else {
            opts.dir = a;
        }
    }
}

/// Walk `<dir>/src/modules/<mod>/**/*.zig` and report imports that cross a module
/// boundary by **file path** (`@import("../../other/service.zig")`). Importing the
/// other module's `root.zig` barrel is the sanctioned direction; reaching a leaf
/// file is what this flags.
fn scanEntanglements(
    io: Io,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    modules: []const audit.ModuleRec,
    out: *std.ArrayList(Entanglement),
    allowed: []const []const u8,
) !void {
    for (modules) |mod| {
        const mod_dir = try std.fs.path.join(allocator, &.{ project_dir, "src", "modules", mod.name });
        defer allocator.free(mod_dir);

        var dir = Dir.cwd().openDir(io, mod_dir, .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) continue;
            return err;
        };
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

            const full = try std.fs.path.join(allocator, &.{ mod_dir, entry.path });
            defer allocator.free(full);
            const content = Dir.cwd().readFileAlloc(io, full, allocator, Io.Limit.limited(1 << 20)) catch continue;
            defer allocator.free(content);

            var line_no: usize = 0;
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                line_no += 1;
                const trimmed = std.mem.trim(u8, line, " \t");
                if (std.mem.startsWith(u8, trimmed, "//")) continue;
                const at = std.mem.indexOf(u8, line, "@import(") orelse continue;
                const rest = line[at + "@import(".len ..];
                if (rest.len == 0 or rest[0] != '"') continue;
                const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse continue;
                const target = rest[1 .. 1 + end];

                // Only relative file imports cross modules; package imports
                // ("zigmodu", "std") are not a boundary question.
                if (target.len == 0 or target[0] == '/') continue;
                if (std.mem.indexOf(u8, target, "..") == null) continue;

                const target_module = moduleOfImport(target) orelse continue;
                if (std.mem.eql(u8, target_module, mod.name)) continue; // same module: fine
                if (!isKnownModule(modules, target_module)) continue; // relative import out of the module tree

                // `--allow from->to` acknowledges one direction.
                const pair = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ mod.name, target_module });
                defer allocator.free(pair);
                var skip = false;
                for (allowed) |a| {
                    if (std.mem.eql(u8, a, pair)) skip = true;
                }
                if (skip) continue;

                try out.append(allocator, .{
                    .from_module = try allocator.dupe(u8, mod.name),
                    .to_module = try allocator.dupe(u8, target_module),
                    .file = try std.fs.path.join(allocator, &.{ "src", "modules", mod.name, entry.path }),
                    .line = line_no,
                });
            }
        }
    }
}

/// Candidate module name behind a relative import: strip the leading `..` run and
/// take the first real segment (`../../billing/x.zig` → `billing`, for any number
/// of `..`). The caller then checks it against the project's module list, so a
/// relative import into a non-module directory (`../../shared/util.zig`) simply
/// does not match and is ignored.
///
/// Counting `..` against the importing file's depth would be the "correct" way and
/// is what an earlier version did — it also rejected every import written from a
/// module **root** file, which is the common case. Matching the module list is both
/// simpler and harder to get wrong.
fn moduleOfImport(target: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, target, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) continue; // pop whatever came before; we do not need the count
        return seg;
    }
    return null;
}

fn isKnownModule(modules: []const audit.ModuleRec, name: []const u8) bool {
    for (modules) |m| {
        if (std.mem.eql(u8, m.name, name)) return true;
    }
    return false;
}

fn renderJson(report: graph_mod.Report, entanglements: []const Entanglement, w: anytype) !void {
    try w.writeAll("{\"modules\":[");
    for (report.nodes, 0..) |node, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"dependencies\":[", .{node.name});
        for (node.dependencies, 0..) |d, k| {
            if (k > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{d});
        }
        try w.writeAll("]}");
    }
    try w.print("],\"max_depth\":{d},\"ok\":{},\"findings\":[", .{ report.max_depth, report.ok() });
    for (report.findings, 0..) |f, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"kind\":\"{s}\",\"subject\":\"{s}\",\"detail\":\"{s}\"", .{ @tagName(f.kind), f.subject, f.detail });
        if (f.cycle) |path| {
            try w.writeAll(",\"cycle\":[");
            for (path, 0..) |name, k| {
                if (k > 0) try w.writeAll(",");
                try w.print("\"{s}\"", .{name});
            }
            try w.writeAll("]");
        }
        try w.writeAll("}");
    }
    try w.writeAll("],\"entanglements\":[");
    for (entanglements, 0..) |e, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"from\":\"{s}\",\"to\":\"{s}\",\"file\":\"{s}\",\"line\":{d}}}", .{ e.from_module, e.to_module, e.file, e.line });
    }
    try w.writeAll("]}\n");
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "moduleOfImport finds the module name behind any number of .." {
    try std.testing.expectEqualStrings("billing", moduleOfImport("../billing/x.zig").?);
    try std.testing.expectEqualStrings("billing", moduleOfImport("../../billing/x.zig").?);
    try std.testing.expectEqualStrings("billing", moduleOfImport("../../../billing/service.zig").?);
    try std.testing.expectEqualStrings("billing", moduleOfImport("./../billing/x.zig").?);
    try std.testing.expect(moduleOfImport("std") == null);
    try std.testing.expect(moduleOfImport("zigmodu") == null);
}

test "doctor JSON reports the graph and the findings" {
    const report = graph_mod.Report{
        .nodes = &.{.{ .name = "a", .description = "", .dependencies = &.{}, .is_internal = false }},
        .findings = &.{.{ .kind = .orphan, .subject = "a" }},
        .max_depth = 0,
    };
    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderJson(report, &.{}, &stream);
    const json = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"modules\":[{\"name\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"orphan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
}
