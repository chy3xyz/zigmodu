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
//! A third, **advisory** pass reads the DI/event wiring a Zig compiler would resolve
//! and this tool cannot: `ctx.service(T, "name")` sites cross-checked against
//! `withService(T, "name", …)` registrations (unresolved services), per-service
//! consumer counts, and `eventBus(T)` acquisition sites (event topology). Every rule
//! there is a text heuristic over source, so it only ever warns — and when the text
//! does not carry the answer (a non-literal service name, a bus passed through a
//! struct field), it says `n/a (静态分析不可得)` instead of inventing a number.
//!
//! ```bash
//! zmodu doctor                  # human report, exit 1 on blocking findings
//! zmodu doctor --json           # machine-readable (CI, dashboards)
//! zmodu doctor --max-deps 6     # tightening the advisory threshold
//! zmodu doctor --max-consumers 4  # service consumer threshold (advisory)
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
    /// Advisory threshold for "one service, how many modules ask for it".
    max_consumers: usize = 8,
    /// Entanglements the project has decided to live with, as `"from->to"`.
    allowed: std.ArrayList([]const u8) = .empty,
    /// Skip the source scans (graph analysis only).
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
            \\usage: zmodu doctor [dir] [--json] [--max-deps N] [--max-consumers N]
            \\                    [--allow from->to] [--skip-imports]
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

    // Advisory pass: DI/event wiring. Text heuristics only — never a blocking
    // finding, and honest about what it cannot see (see `renderWiring`).
    var wiring = Wiring{};
    defer wiring.deinit(allocator);
    if (!opts.skip_imports) {
        scanWiring(io, allocator, opts.dir, &wiring) catch |err| {
            std.debug.print("doctor: wiring scan failed: {s}\n", .{@errorName(err)});
        };
    }

    if (opts.json) {
        var out_buf: [8192]u8 = undefined;
        var out_file = std.Io.File.stdout();
        var out_writer = out_file.writer(io, &out_buf);
        const w = &out_writer.interface;
        renderJson(owned.report, entanglements.items, wiring, w) catch return 2;
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
        renderWiring(wiring, opts.max_consumers, w) catch return 2;
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
        } else if (std.mem.eql(u8, a, "--max-consumers")) {
            if (i + 1 >= args.len) return Error.CliUsage;
            i += 1;
            opts.max_consumers = std.fmt.parseInt(usize, args[i], 10) catch return Error.CliUsage;
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
///
/// A package import (`std`, `zigmodu`) crosses no module boundary and returns null:
/// the name is only meaningful once the import has stepped out of its own directory.
fn moduleOfImport(target: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, target, "..") == null) return null;
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

// ─────────────────────────────────────────────────
// Advisory pass: DI / event wiring
//
// The module graph says which modules may talk. It does not say whether the
// container can answer `ctx.service(T, "db")`, or whether anything subscribes to
// the events a module publishes. Both live in *source* text that only a Zig
// compiler resolves, so this pass is deliberately a text heuristic:
//
//   * it reads literals, never evaluates expressions;
//   * it attributes publish/subscribe to the file that acquired the bus, not to
//     the handler (a bus stored in a struct field is invisible);
//   * whatever it cannot see is reported as `n/a (静态分析不可得)`.
//
// Nothing here can change the exit code — every finding is a `[warn]`.
// ─────────────────────────────────────────────────

/// A `ctx.service(T, "name")` site: a module asking the container for a service.
const ServiceRef = struct {
    name: []const u8,
    module: []const u8,
    file: []const u8,
    line: usize,
};

/// A `withService(T, "name", instance)` site: where a service gets registered.
const ServiceDecl = struct {
    name: []const u8,
    file: []const u8,
    line: usize,
};

/// A `…eventBus(T)` site (bus acquisition). `publishes` / `subscribes` describe
/// the **file** the site lives in, which is as close as static text gets.
const EventRef = struct {
    event: []const u8,
    module: []const u8,
    file: []const u8,
    line: usize,
    publishes: bool,
    subscribes: bool,
};

/// Everything the wiring pass could read out of the project's source.
const Wiring = struct {
    services: std.ArrayList(ServiceRef) = .empty,
    declarations: std.ArrayList(ServiceDecl) = .empty,
    events: std.ArrayList(EventRef) = .empty,
    /// `ctx.service(…)` calls whose name argument is not a literal.
    dynamic_services: usize = 0,
    /// `.publish(` / `.subscribe(` sites in files that never show which bus they
    /// came from (the bus was handed in, stored in a field, …).
    blind_bus_calls: usize = 0,
    files_scanned: usize = 0,

    fn deinit(self: *Wiring, allocator: std.mem.Allocator) void {
        for (self.services.items) |r| {
            allocator.free(r.name);
            allocator.free(r.module);
            allocator.free(r.file);
        }
        self.services.deinit(allocator);
        for (self.declarations.items) |d| {
            allocator.free(d.name);
            allocator.free(d.file);
        }
        self.declarations.deinit(allocator);
        for (self.events.items) |e| {
            allocator.free(e.event);
            allocator.free(e.module);
            allocator.free(e.file);
        }
        self.events.deinit(allocator);
        self.* = undefined;
    }

    fn isRegistered(self: Wiring, name: []const u8) bool {
        for (self.declarations.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return true;
        }
        return false;
    }
};

/// Walk `<dir>/src/**/*.zig` (plus `<dir>/*.zig`, where `main.zig` sometimes
/// lives) and read the wiring out of it. Directories that only hold build output
/// are skipped; a file larger than 1 MiB is not wiring, so it is skipped too.
fn scanWiring(io: Io, allocator: std.mem.Allocator, project_dir: []const u8, out: *Wiring) !void {
    const src_path = try std.fs.path.join(allocator, &.{ project_dir, "src" });
    defer allocator.free(src_path);

    if (Dir.cwd().openDir(io, src_path, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var walker = try Dir.walkSelectively(dir, allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (!isSkippedDir(entry.basename)) try walker.enter(io, entry);
                },
                .file => {
                    if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                    const rel = try std.fs.path.join(allocator, &.{ "src", entry.path });
                    defer allocator.free(rel);
                    const content = entry.dir.readFileAlloc(io, entry.basename, allocator, Io.Limit.limited(1 << 20)) catch continue;
                    defer allocator.free(content);
                    try scanWiringSource(allocator, rel, content, out);
                },
                else => {},
            }
        }
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    // Root-level Zig files: `app.zig` / `main.zig` are sometimes kept there.
    if (Dir.cwd().openDir(io, project_dir, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
            if (std.mem.startsWith(u8, entry.name, "build")) continue;
            const full = try std.fs.path.join(allocator, &.{ project_dir, entry.name });
            defer allocator.free(full);
            const content = Dir.cwd().readFileAlloc(io, full, allocator, Io.Limit.limited(1 << 20)) catch continue;
            defer allocator.free(content);
            try scanWiringSource(allocator, entry.name, content, out);
        }
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
}

fn isSkippedDir(name: []const u8) bool {
    const skipped = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out", "node_modules" };
    for (skipped) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

/// Read one file's wiring. `rel_file` is project-relative (`src/modules/x/api.zig`).
fn scanWiringSource(allocator: std.mem.Allocator, rel_file: []const u8, content: []const u8, out: *Wiring) !void {
    out.files_scanned += 1;
    const module = try moduleDirOfPath(allocator, rel_file);
    defer allocator.free(module);

    const publishes = std.mem.indexOf(u8, content, ".publish(") != null;
    const subscribes = std.mem.indexOf(u8, content, ".subscribe(") != null;
    if (std.mem.indexOf(u8, content, "eventBus(") == null) {
        out.blind_bus_calls += busCallSites(content);
    }

    var i: usize = 0;
    while (indexOfUncommented(content, "withService(", i)) |at| {
        i = at + "withService(".len;
        const file = try allocator.dupe(u8, rel_file);
        errdefer allocator.free(file);
        if (stringArgAt(content, at)) |name| {
            try out.declarations.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .file = file,
                .line = lineOf(content, at),
            });
        } else {
            allocator.free(file);
            out.dynamic_services += 1;
        }
    }

    i = 0;
    while (indexOfUncommented(content, "ctx.service(", i)) |at| {
        i = at + "ctx.service(".len;
        const file = try allocator.dupe(u8, rel_file);
        errdefer allocator.free(file);
        if (stringArgAt(content, at)) |name| {
            try out.services.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .module = try allocator.dupe(u8, module),
                .file = file,
                .line = lineOf(content, at),
            });
        } else {
            allocator.free(file);
            out.dynamic_services += 1;
        }
    }

    i = 0;
    while (indexOfUncommented(content, "eventBus(", i)) |at| {
        i = at + "eventBus(".len;
        const event = typeArgAt(content, at) orelse {
            out.blind_bus_calls += 1;
            continue;
        };
        try out.events.append(allocator, .{
            .event = try allocator.dupe(u8, event),
            .module = try allocator.dupe(u8, module),
            .file = try allocator.dupe(u8, rel_file),
            .line = lineOf(content, at),
            .publishes = publishes,
            .subscribes = subscribes,
        });
    }
}

/// `src/modules/<module>/…` → `<module>`; anything else is app-level wiring.
fn moduleDirOfPath(allocator: std.mem.Allocator, rel_file: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, rel_file, '/');
    var prev: ?[]const u8 = null;
    while (it.next()) |seg| {
        if (prev) |p| {
            if (std.mem.eql(u8, p, "modules")) return allocator.dupe(u8, seg);
        }
        prev = seg;
    }
    return allocator.dupe(u8, "(app)");
}

/// `.publish(` / `.subscribe(` sites whose receiver *looks like a bus* —
/// `bus.publish(…)`, `self.event_bus.subscribe(…)`. The receiver's name is the
/// cheap stand-in for its type, and it is what keeps a domain method that merely
/// happens to be called `subscribe` (`self.svc.subscribe(tenant, plan)`) out of
/// the event numbers.
fn busCallSites(content: []const u8) usize {
    var n: usize = 0;
    for ([_][]const u8{ ".publish(", ".subscribe(" }) |needle| {
        var i: usize = 0;
        while (indexOfUncommented(content, needle, i)) |at| {
            i = at + needle.len;
            if (receiverLooksLikeBus(content, at)) n += 1;
        }
    }
    return n;
}

fn receiverLooksLikeBus(content: []const u8, dot_index: usize) bool {
    var start = dot_index;
    while (start > 0) {
        const c = content[start - 1];
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
            start -= 1;
        } else break;
    }
    const receiver = content[start..dot_index];
    const last = if (std.mem.lastIndexOfScalar(u8, receiver, '.')) |dot| receiver[dot + 1 ..] else receiver;
    return std.mem.indexOf(u8, last, "bus") != null;
}

/// First non-comment occurrence of `needle` at or after `from`.
fn indexOfUncommented(content: []const u8, needle: []const u8, from: usize) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, content, i, needle)) |at| {
        if (!isCommented(content, at)) return at;
        i = at + needle.len;
    }
    return null;
}

fn isCommented(content: []const u8, index: usize) bool {
    var start = index;
    while (start > 0 and content[start - 1] != '\n') start -= 1;
    const line = std.mem.trim(u8, content[start..index], " \t");
    return std.mem.startsWith(u8, line, "//");
}

fn lineOf(content: []const u8, index: usize) usize {
    var line: usize = 1;
    for (content[0..@min(index, content.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

/// First `"…"` literal inside the call whose `(` follows `call_index`, or null
/// when the argument is not a literal (a variable, a const, an expression) —
/// those are reported as unresolvable rather than guessed at. Multi-line calls
/// are handled; nested calls just move the paren depth, so the *outer* literal
/// wins.
fn stringArgAt(content: []const u8, call_index: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, content, call_index, '(') orelse return null;
    var depth: usize = 0;
    var i = open;
    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return null;
            },
            '"' => {
                const end = std.mem.indexOfScalarPos(u8, content, i + 1, '"') orelse return null;
                return content[i + 1 .. end];
            },
            else => {},
        }
    }
    return null;
}

/// The event type behind `eventBus(T)` — `T` as written, reduced to its last
/// path segment (`order_mod.service.OrderEvent` → `OrderEvent`). Null when the
/// argument is not a plain type path, which is exactly when the bus type is not
/// statically known.
fn typeArgAt(content: []const u8, call_index: usize) ?[]const u8 {
    const open = std.mem.indexOfScalarPos(u8, content, call_index, '(') orelse return null;
    var depth: usize = 0;
    var i = open;
    var close: ?usize = null;
    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    close = i;
                    break;
                }
            },
            else => {},
        }
    }
    const raw = std.mem.trim(u8, content[open + 1 .. close orelse return null], " \t\r\n");
    if (raw.len == 0 or std.mem.indexOfAny(u8, raw, "(\"") != null) return null;
    const last = if (std.mem.lastIndexOfScalar(u8, raw, '.')) |dot| raw[dot + 1 ..] else raw;
    if (last.len == 0) return null;
    for (last) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    return last;
}

/// How many *distinct modules* ask for this service — the size of the fan-in.
/// Written as a scan rather than a set so the number is exactly the number of
/// modules found (a capped map would quietly under-report, which is the one
/// thing an advisory number must never do).
fn consumersOf(wiring: Wiring, name: []const u8) usize {
    var n: usize = 0;
    for (wiring.services.items, 0..) |ref, i| {
        if (!std.mem.eql(u8, ref.name, name)) continue;
        var seen = false;
        for (wiring.services.items[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, ref.name) and std.mem.eql(u8, earlier.module, ref.module)) seen = true;
        }
        if (!seen) n += 1;
    }
    return n;
}

fn renderWiring(wiring: Wiring, max_consumers: usize, w: anytype) !void {
    try w.print("\nwiring (advisory — {d} file(s) scanned, never blocks):\n", .{wiring.files_scanned});

    if (wiring.services.items.len == 0 and wiring.declarations.items.len == 0) {
        try w.writeAll("  services: n/a (静态分析不可得)\n");
    } else {
        try w.print("  services: {d} referenced, {d} registered\n", .{ wiring.services.items.len, wiring.declarations.items.len });
        for (wiring.services.items) |ref| {
            if (wiring.isRegistered(ref.name)) continue;
            try w.print("  [warn] unresolved service '{s}'  ({s}:{d})\n", .{ ref.name, ref.file, ref.line });
        }
        if (wiring.declarations.items.len == 0) {
            try w.writeAll("  (registrations may happen outside the scanned tree — n/a (静态分析不可得))\n");
        }
        for (wiring.services.items, 0..) |ref, i| {
            var seen = false;
            for (wiring.services.items[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.name, ref.name)) seen = true;
            }
            if (seen) continue;

            const consumers = consumersOf(wiring, ref.name);
            try w.print("    consumers: {s} = {d}\n", .{ ref.name, consumers });
            if (consumers > max_consumers) {
                try w.print("  [warn] service '{s}' has {d} consumers (threshold {d})\n", .{ ref.name, consumers, max_consumers });
            }
        }
    }
    if (wiring.dynamic_services > 0) {
        try w.print("  {d} service call(s) with a non-literal name — n/a (静态分析不可得)\n", .{wiring.dynamic_services});
    }

    if (wiring.events.items.len == 0) {
        try w.writeAll("  events: n/a (静态分析不可得)\n");
    } else {
        try w.print("  events: {d} bus site(s)\n", .{wiring.events.items.len});
        for (wiring.events.items, 0..) |ref, i| {
            var seen = false;
            for (wiring.events.items[0..i]) |earlier| {
                if (std.mem.eql(u8, earlier.event, ref.event)) seen = true;
            }
            if (seen) continue;

            var sites: usize = 0;
            var subs: usize = 0;
            var pubs: usize = 0;
            for (wiring.events.items) |other| {
                if (!std.mem.eql(u8, other.event, ref.event)) continue;
                sites += 1;
                if (other.subscribes) subs += 1;
                if (other.publishes) pubs += 1;
            }
            try w.print("    {s}: {d} acquisition(s), {d} subscribe site(s), {d} publish site(s)\n", .{ ref.event, sites, subs, pubs });
            if (subs == 0) {
                try w.print("  [warn] event '{s}' has no subscribe site in the file(s) that acquire its bus\n", .{ref.event});
            }
        }
    }
    if (wiring.blind_bus_calls > 0) {
        try w.print("  {d} `.publish(`/`.subscribe(` site(s) on a bus whose event type is not visible here — n/a (静态分析不可得)\n", .{wiring.blind_bus_calls});
    }
}

fn renderJson(
    report: graph_mod.Report,
    entanglements: []const Entanglement,
    wiring: Wiring,
    w: anytype,
) !void {
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
    try w.writeAll("],\"wiring\":{\"services\":{\"referenced\":[");
    for (wiring.services.items, 0..) |ref, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"module\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"resolved\":{}}}", .{
            ref.name, ref.module, ref.file, ref.line, wiring.isRegistered(ref.name),
        });
    }
    try w.writeAll("],\"registered\":[");
    for (wiring.declarations.items, 0..) |d, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"file\":\"{s}\",\"line\":{d}}}", .{ d.name, d.file, d.line });
    }
    try w.writeAll("],\"consumers\":[");
    var emitted: usize = 0;
    for (wiring.services.items, 0..) |ref, i| {
        var seen = false;
        for (wiring.services.items[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, ref.name)) seen = true;
        }
        if (seen) continue;
        if (emitted > 0) try w.writeAll(",");
        emitted += 1;
        try w.print("{{\"name\":\"{s}\",\"consumers\":{d}}}", .{ ref.name, consumersOf(wiring, ref.name) });
    }
    try w.print("],\"dynamic\":{d}}},\"events\":[", .{wiring.dynamic_services});
    for (wiring.events.items, 0..) |ref, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"event\":\"{s}\",\"module\":\"{s}\",\"file\":\"{s}\",\"line\":{d},\"publishes\":{},\"subscribes\":{}}}", .{
            ref.event, ref.module, ref.file, ref.line, ref.publishes, ref.subscribes,
        });
    }
    try w.print("],\"blind_bus_calls\":{d}", .{wiring.blind_bus_calls});
    try w.writeAll("}}\n");
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
    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderJson(report, &.{}, .{}, &stream);
    const json = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"modules\":[{\"name\":\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"orphan\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"wiring\":{\"services\":{\"referenced\":[]") != null);
}

test "stringArgAt reads literals and refuses expressions" {
    const src =
        \\const a = ctx.service(Db, "db") orelse return error.MissingService;
        \\const b = try ctx.service(
        \\    Cache,
        \\    "cache",
        \\) orelse return null;
        \\const c = ctx.service(Db, service_name) orelse return null;
    ;
    const first = indexOfUncommented(src, "ctx.service(", 0).?;
    try std.testing.expectEqualStrings("db", stringArgAt(src, first).?);
    const second = indexOfUncommented(src, "ctx.service(", first + 1).?;
    try std.testing.expectEqualStrings("cache", stringArgAt(src, second).?);
    const third = indexOfUncommented(src, "ctx.service(", second + 1).?;
    try std.testing.expect(stringArgAt(src, third) == null);
}

test "typeArgAt reduces an eventBus argument to its type name" {
    try std.testing.expectEqualStrings("OrderEvent", typeArgAt("const b = try app.eventBus(order_mod.service.OrderEvent);", 0).?);
    try std.testing.expectEqualStrings("Tick", typeArgAt("const bus = try ctx.eventBus(Tick);", 0).?);
    try std.testing.expect(typeArgAt("const bus = try ctx.eventBus(pickEvent(flag));", 0) == null);
}

test "doctor reports unresolved services, consumer counts and event topology" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/modules/cart");
    try tmp.dir.createDirPath(io, "src/modules/order");
    // The cart module asks for a service nobody registers, and for one that is
    // registered — the first is unresolved, the second is a consumer.
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/modules/cart/module.zig",
        .data =
        \\const std = @import("std");
        \\pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        \\    const db = ctx.service(Db, "db") orelse return error.MissingService;
        \\    const cache = ctx.service(Cache, "cache") orelse return error.MissingService;
        \\    _ = .{ db, cache };
        \\}
        ,
    });
    // The order module acquires an event bus and never subscribes to it.
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/modules/order/module.zig",
        .data =
        \\pub fn initWith(ctx: *zmodu.ModuleContext) !void {
        \\    const bus = try ctx.eventBus(order_mod.service.OrderEvent);
        \\    _ = bus;
        \\}
        ,
    });
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/main.zig",
        .data =
        \\pub fn main() !void {
        \\    var b = zmodu.builder(gpa, io);
        \\    _ = try b.withService(Db, "db", &db);
        \\}
        ,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const dir = path_buf[0..path_len];

    var wiring = Wiring{};
    defer wiring.deinit(allocator);
    try scanWiring(io, allocator, dir, &wiring);

    try std.testing.expectEqual(@as(usize, 2), wiring.services.items.len);
    try std.testing.expectEqual(@as(usize, 1), wiring.declarations.items.len);
    try std.testing.expectEqualStrings("db", wiring.declarations.items[0].name);
    try std.testing.expect(wiring.isRegistered("db"));
    try std.testing.expect(!wiring.isRegistered("cache"));
    try std.testing.expectEqual(@as(usize, 1), consumersOf(wiring, "db"));
    try std.testing.expectEqual(@as(usize, 1), wiring.events.items.len);
    try std.testing.expectEqualStrings("OrderEvent", wiring.events.items[0].event);
    try std.testing.expectEqualStrings("order", wiring.events.items[0].module);
    try std.testing.expect(!wiring.events.items[0].subscribes);

    var buf: [8192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderWiring(wiring, 0, &stream);
    const text = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "[warn] unresolved service 'cache'") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "consumers: db = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "OrderEvent: 1 acquisition(s), 0 subscribe site(s), 0 publish site(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[warn] event 'OrderEvent' has no subscribe site") != null);
}

test "doctor says n/a instead of inventing wiring it cannot see" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/modules/user");
    try tmp.dir.writeFile(io, .{
        .sub_path = "src/modules/user/service.zig",
        .data =
        \\const name = "db";
        \\pub fn init(ctx: *zmodu.ModuleContext) !void {
        \\    const db = ctx.service(Db, name) orelse return null;
        \\    try self.event_bus.publish(.{ .id = 1 });
        \\    self.svc.subscribe(tenant, plan); // a domain call, not a bus
        \\}
        ,
    });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);

    var wiring = Wiring{};
    defer wiring.deinit(allocator);
    try scanWiring(io, allocator, path_buf[0..path_len], &wiring);

    // A non-literal name is not guessed at, and a bus whose type never appears
    // is counted as a blind call rather than attributed to some event.
    try std.testing.expectEqual(@as(usize, 0), wiring.services.items.len);
    try std.testing.expectEqual(@as(usize, 1), wiring.dynamic_services);
    try std.testing.expectEqual(@as(usize, 1), wiring.blind_bus_calls);
    try std.testing.expectEqual(@as(usize, 0), wiring.events.items.len);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try renderWiring(wiring, 8, &stream);
    const text = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "services: n/a (静态分析不可得)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "events: n/a (静态分析不可得)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "non-literal name — n/a (静态分析不可得)") != null);
}
