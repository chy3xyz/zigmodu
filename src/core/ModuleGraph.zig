//! ModuleGraph — the architecture engine: a dependency graph you can *check*,
//! not just describe.
//!
//! `Application` already refuses to start with a missing or circular module
//! dependency. That check happens at **startup**: the binary builds, deploys, and
//! the first thing it does is exit — which is a slow, expensive way to learn that
//! `order` depends on `billing` and `billing` depends on `order`.
//!
//! This module moves the same analysis to **comptime** for the common case (the
//! module set is a comptime tuple in `builder(...).build(.{A, B, C})`), and keeps
//! the result as data — so the CLI can print it, a test can assert on it, and a
//! reviewer can read it without running anything.
//!
//! What is checked where:
//!
//! | check | comptime (`validateOrFail`) | source scan (`zmodu doctor`) |
//! |---|---|---|
//! | missing dependency | yes | yes |
//! | self dependency | yes | yes |
//! | circular dependency | yes (full DFS) | yes |
//! | duplicate module name | yes | yes |
//! | orphan module | reported | reported |
//! | dependency-count threshold | yes | yes |
//! | cross-module direct file import | not expressible | yes (see `zmodu doctor`) |
//!
//! A rule like "domain must not import the database" cannot be checked from
//! module *declarations* — nothing in `pub const info` records what a file
//! imports. That is why the source-level half lives in the CLI: `zmodu doctor`
//! scans imports inside each module directory and reports the entanglement.
//! Declaring a rule that cannot be enforced is worse than not declaring it.

const std = @import("std");

/// One node of the graph, materialised from a module's `info`.
pub const Node = struct {
    name: []const u8,
    description: []const u8,
    dependencies: []const []const u8,
    is_internal: bool,
};

pub const Cycle = struct {
    /// Names in the order the cycle was walked, first repeated at the end:
    /// `{"alpha", "risk", "alpha"}`.
    path: []const []const u8,
};

pub const Finding = struct {
    pub const Kind = enum {
        missing_dependency,
        self_dependency,
        duplicate_name,
        cycle,
        too_many_dependencies,
        orphan,
    };

    kind: Kind,
    /// The module the finding is about.
    subject: []const u8,
    /// Detail: the missing dependency's name, the dependency count, …
    detail: []const u8 = "",
    /// 1-based position in the cycle path, when `kind == .cycle`.
    cycle: ?[]const []const u8 = null,
};

/// Thresholds. Defaults are deliberately permissive: the engine's job is to catch
/// *structural* mistakes (cycles, typos) not to have opinions about sizing.
pub const Limits = struct {
    max_dependencies: usize = 8,
    /// Report modules nobody depends on and that depend on nothing. Common for a
    /// leaf module (a `shared`/`util` barrel), so it is a finding, never an error.
    report_orphans: bool = true,
};

pub const Report = struct {
    nodes: []const Node = &.{},
    findings: []const Finding = &.{},
    /// Longest dependency chain (edges), for a "how deep is this thing" number.
    max_depth: usize = 0,

    pub inline fn ok(self: Report) bool {
        for (self.findings) |f| {
            switch (f.kind) {
                // Sizing and unused leaves are advisory; everything else means the
                // graph cannot be started, so it must not compile either.
                .too_many_dependencies, .orphan => {},
                else => return false,
            }
        }
        return true;
    }

    pub inline fn count(self: Report, kind: Finding.Kind) usize {
        var n: usize = 0;
        for (self.findings) |f| if (f.kind == kind) {
            n += 1;
        };
        return n;
    }
};

/// Analyse a comptime module set. Everything here runs at compile time when the
/// caller is `validateOrFail`; the same function is callable from a test, which is
/// how the checks themselves are verified (a `@compileError` cannot be).
///
/// Written entirely as comptime value concatenation (no runtime loops, no local
/// buffers escaping): a `@compileError` is only as good as the analysis behind it.
pub inline fn analyze(comptime modules: []const type, comptime limits: Limits) Report {
    const nodes = collect(modules);

    var findings: []const Finding = &.{};

    inline for (nodes, 0..) |node, i| {
        // Self dependency.
        inline for (node.dependencies) |dep| {
            if (std.mem.eql(u8, dep, node.name)) {
                findings = findings ++ &[_]Finding{.{ .kind = .self_dependency, .subject = node.name }};
            }
        }
        // Missing dependency.
        inline for (node.dependencies) |dep| {
            if (!hasNode(nodes, dep)) {
                findings = findings ++ &[_]Finding{.{
                    .kind = .missing_dependency,
                    .subject = node.name,
                    .detail = dep,
                }};
            }
        }
        // Duplicate module name (only against earlier nodes, so each pair reports once).
        inline for (nodes[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, node.name)) {
                findings = findings ++ &[_]Finding{.{ .kind = .duplicate_name, .subject = node.name }};
            }
        }
        // Dependency-count threshold.
        if (node.dependencies.len > limits.max_dependencies) {
            findings = findings ++ &[_]Finding{.{
                .kind = .too_many_dependencies,
                .subject = node.name,
                .detail = std.fmt.comptimePrint("{d}", .{node.dependencies.len}),
            }};
        }
    }

    // Cycles: the report carries the path so the compile error can spell it out.
    const cycle = findCycle(nodes);
    if (cycle.len > 0) {
        findings = findings ++ &[_]Finding{.{
            .kind = .cycle,
            .subject = cycle.names[0],
            .cycle = cycle.names[0..cycle.len],
        }};
    }

    // Orphans: nobody depends on it and it depends on nobody. Advisory — a leaf
    // (`shared`, `util`) is a normal shape, so this never blocks a build.
    if (limits.report_orphans and nodes.len > 1) {
        inline for (nodes) |node| {
            if (node.dependencies.len == 0 and !isDependedOn(nodes, node.name)) {
                findings = findings ++ &[_]Finding{.{ .kind = .orphan, .subject = node.name }};
            }
        }
    }

    return .{
        .nodes = nodes,
        .findings = findings,
        .max_depth = depth(nodes),
    };
}

/// Analyse, and refuse to compile when the graph cannot start. This is what
/// `ApplicationBuilder.build` calls, so a cyclic or misspelled dependency is a
/// compile error with the cycle spelled out rather than a startup abort.
///
/// **Blocking checks only** (missing / self / duplicate / cycle). The advisory
/// ones — dependency-count threshold, orphan leaves — take a *runtime*
/// configurable limit, so they live in startup validation and `zmodu doctor`
/// rather than in the comptime path; `report.ok()` already ignores them.
///
/// Opt out with `.withCompileTimeGraphCheck(false)` when the module set is
/// assembled at runtime (a plugin registry), in which case `validateModules`
/// still runs at startup.
pub fn validateOrFail(comptime modules: []const type) void {
    // The `comptime` block matters: `@compileError` is analysed even when its
    // branch is unreachable at runtime, so the condition has to be folded *before*
    // the body is analysed — otherwise every call site fails, including healthy
    // graphs. (`ok()` is `inline` for the same reason: a plain call is not folded.)
    comptime {
        const report = analyze(modules, .{});
        if (!report.ok()) @compileError(renderErrors(report));
    }
}

/// Human-readable failure text: every blocking finding, then a hint.
fn renderErrors(comptime report: Report) []const u8 {
    var text: []const u8 = "module graph is not startable:\n";
    inline for (report.findings) |f| {
        switch (f.kind) {
            .missing_dependency => text = text ++ "  - '" ++ f.subject ++ "' depends on unknown module '" ++ f.detail ++ "'\n",
            .self_dependency => text = text ++ "  - '" ++ f.subject ++ "' depends on itself\n",
            .duplicate_name => text = text ++ "  - duplicate module name '" ++ f.subject ++ "'\n",
            .cycle => {
                text = text ++ "  - circular dependency: ";
                inline for (f.cycle.?, 0..) |name, i| {
                    if (i > 0) text = text ++ " -> ";
                    text = text ++ name;
                }
                text = text ++ "\n";
            },
            else => {},
        }
    }
    return text ++ "  (fix the declarations, or pass .withCompileTimeGraphCheck(false) to build())";
}

fn collect(comptime modules: []const type) []const Node {
    var out: []const Node = &.{};
    inline for (modules) |mod| {
        const info = @field(mod, "info");
        out = out ++ &[_]Node{.{
            .name = info.name,
            .description = info.description,
            .dependencies = info.dependencies,
            .is_internal = info.is_internal,
        }};
    }
    return out;
}

fn hasNode(nodes: []const Node, name: []const u8) bool {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.name, name)) return true;
    }
    return false;
}

fn isDependedOn(nodes: []const Node, name: []const u8) bool {
    for (nodes) |other| {
        for (other.dependencies) |dep| {
            if (std.mem.eql(u8, dep, name)) return true;
        }
    }
    return false;
}

fn indexOf(nodes: []const Node, name: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return i;
    }
    return null;
}

/// Cycle search result, returned **by value** so no slice of a local buffer
/// escapes (the classic comptime footgun).
fn CyclePath(comptime max_nodes: usize) type {
    return struct {
        names: [max_nodes + 1][]const u8 = @splat(""),
        len: usize = 0,
    };
}

/// DFS with colours (0 = unvisited, 1 = on stack, 2 = done). Returns the cycle
/// path (`a -> b -> a`) when one exists, `len == 0` otherwise.
fn findCycle(nodes: []const Node) CyclePath(nodes.len) {
    // The DFS + name lookups are O(modules² · name_len) comptime branches;
    // large catalogs (17+ modules with multi-dep graphs) exceed the default
    // 1000 backwards-branch budget.
    @setEvalBranchQuota(100_000);
    if (nodes.len == 0) return .{};

    var colour: [nodes.len]u8 = @splat(0);
    var result: CyclePath(nodes.len) = .{};

    var start: usize = 0;
    while (start < nodes.len) : (start += 1) {
        if (colour[start] != 0) continue;
        if (dfs(nodes, start, &colour, &result)) return result;
    }
    return .{};
}

fn dfs(
    nodes: []const Node,
    at: usize,
    colour: *[nodes.len]u8,
    result: *CyclePath(nodes.len),
) bool {
    colour[at] = 1;
    result.names[result.len] = nodes[at].name;
    result.len += 1;

    for (nodes[at].dependencies) |dep| {
        const next = indexOf(nodes, dep) orelse continue; // missing deps are reported separately
        if (colour[next] == 1) {
            // Back edge: keep the path tail that starts at the repeated node.
            var from: usize = 0;
            for (0..result.len) |i| {
                if (std.mem.eql(u8, result.names[i], dep)) {
                    from = i;
                    break;
                }
            }
            var k: usize = from;
            while (k < result.len) : (k += 1) result.names[k - from] = result.names[k];
            result.names[result.len - from] = dep;
            result.len = result.len - from + 1;
            return true;
        }
        if (colour[next] == 0 and dfs(nodes, next, colour, result)) return true;
    }

    colour[at] = 2;
    result.len -= 1;
    return false;
}

/// Longest chain of dependencies, in edges.
fn depth(nodes: []const Node) usize {
    var best: usize = 0;
    for (nodes, 0..) |_, i| {
        const d = depthFrom(nodes, i, 0);
        if (d > best) best = d;
    }
    return best;
}

fn depthFrom(nodes: []const Node, at: usize, seen: usize) usize {
    if (seen > nodes.len) return 0; // cycle guard: analysis reports it, do not hang
    var best: usize = 0;
    for (nodes[at].dependencies) |dep| {
        const next = indexOf(nodes, dep) orelse continue;
        const d = 1 + depthFrom(nodes, next, seen + 1);
        if (d > best) best = d;
    }
    return best;
}

// ── runtime twin (the CLI's path) ────────────────────────────────────────
//
// The comptime analyser above works on types; the CLI works on source it scanned
// (`zmodu graph` / `zmodu doctor` must run without compiling the app). The two
// share `Report`, `Finding` and every renderer, and the cycle searches below are
// deliberate twins of each other (fixed arrays at comptime, allocation at
// runtime) — keep them in step, the tests cover both.

pub const OwnedReport = struct {
    report: Report,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedReport) void {
        for (self.report.findings) |f| {
            if (f.cycle) |path| self.allocator.free(path);
            if (f.detail.len > 0) self.allocator.free(f.detail);
            self.allocator.free(f.subject);
        }
        self.allocator.free(self.report.findings);
        self.allocator.free(self.report.nodes);
        self.* = undefined;
    }
};

/// Analyse a graph built at runtime (names and dependencies as slices). `nodes`
/// is copied, so the caller keeps ownership of what it passed.
pub fn analyzeRuntime(allocator: std.mem.Allocator, nodes_in: []const Node, limits: Limits) !OwnedReport {
    const nodes = try allocator.dupe(Node, nodes_in);
    errdefer allocator.free(nodes);

    var findings = std.ArrayList(Finding).empty;
    errdefer {
        for (findings.items) |f| {
            if (f.cycle) |path| allocator.free(path);
            if (f.detail.len > 0) allocator.free(f.detail);
            allocator.free(f.subject);
        }
        findings.deinit(allocator);
    }

    for (nodes, 0..) |node, i| {
        for (node.dependencies) |dep| {
            if (std.mem.eql(u8, dep, node.name)) {
                try findings.append(allocator, .{
                    .kind = .self_dependency,
                    .subject = try allocator.dupe(u8, node.name),
                });
            }
        }
        for (node.dependencies) |dep| {
            if (!hasNode(nodes, dep)) {
                try findings.append(allocator, .{
                    .kind = .missing_dependency,
                    .subject = try allocator.dupe(u8, node.name),
                    .detail = try allocator.dupe(u8, dep),
                });
            }
        }
        for (nodes[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, node.name)) {
                try findings.append(allocator, .{
                    .kind = .duplicate_name,
                    .subject = try allocator.dupe(u8, node.name),
                });
            }
        }
        if (node.dependencies.len > limits.max_dependencies) {
            try findings.append(allocator, .{
                .kind = .too_many_dependencies,
                .subject = try allocator.dupe(u8, node.name),
                .detail = try std.fmt.allocPrint(allocator, "{d}", .{node.dependencies.len}),
            });
        }
    }

    if (try findCycleRuntime(allocator, nodes)) |path| {
        try findings.append(allocator, .{
            .kind = .cycle,
            .subject = try allocator.dupe(u8, path[0]),
            .cycle = path,
        });
    }

    if (limits.report_orphans and nodes.len > 1) {
        for (nodes) |node| {
            if (node.dependencies.len == 0 and !isDependedOn(nodes, node.name)) {
                try findings.append(allocator, .{
                    .kind = .orphan,
                    .subject = try allocator.dupe(u8, node.name),
                });
            }
        }
    }

    return .{
        .report = .{
            .nodes = nodes,
            .findings = try findings.toOwnedSlice(allocator),
            .max_depth = depth(nodes),
        },
        .allocator = allocator,
    };
}

/// Runtime twin of `findCycle`. Returns an allocated path (`a -> b -> a`) or null.
fn findCycleRuntime(allocator: std.mem.Allocator, nodes: []const Node) !?[]const []const u8 {
    if (nodes.len == 0) return null;
    const colour = try allocator.alloc(u8, nodes.len);
    defer allocator.free(colour);
    @memset(colour, 0);

    var path = std.ArrayList([]const u8).empty;
    defer path.deinit(allocator);

    var cycle: ?[]const []const u8 = null;
    for (0..nodes.len) |start| {
        if (colour[start] != 0) continue;
        if (try dfsRuntime(allocator, nodes, start, colour, &path, &cycle)) return cycle;
    }
    return null;
}

/// `out_cycle` receives the allocated cycle when a back edge is found — the DFS
/// stack itself is not the answer (it holds the walk, not the loop).
fn dfsRuntime(
    allocator: std.mem.Allocator,
    nodes: []const Node,
    at: usize,
    colour: []u8,
    path: *std.ArrayList([]const u8),
    out_cycle: *?[]const []const u8,
) !bool {
    colour[at] = 1;
    try path.append(allocator, nodes[at].name);

    for (nodes[at].dependencies) |dep| {
        const next = indexOf(nodes, dep) orelse continue;
        if (colour[next] == 1) {
            // Copy the tail of the stack (the cycle body), then close it with the
            // repeated node. The copy bound is the *stack* tail length, not the
            // destination length — the destination has one extra slot for `dep`.
            var from: usize = 0;
            for (path.items, 0..) |name, i| {
                if (std.mem.eql(u8, name, dep)) {
                    from = i;
                    break;
                }
            }
            const tail_len = path.items.len - from;
            const cycle = try allocator.alloc([]const u8, tail_len + 1);
            for (0..tail_len) |k| cycle[k] = path.items[from + k];
            cycle[tail_len] = dep;
            out_cycle.* = cycle;
            return true;
        }
    }
    for (nodes[at].dependencies) |dep| {
        const next = indexOf(nodes, dep) orelse continue;
        if (colour[next] == 0 and try dfsRuntime(allocator, nodes, next, colour, path, out_cycle)) return true;
    }

    colour[at] = 2;
    _ = path.pop();
    return false;
}

// ── rendering (shared by tests, docs and the CLI) ────────────────────────

/// Mermaid `graph LR` — paste into a Markdown block and GitHub renders it.
pub fn renderMermaid(report: Report, writer: anytype) !void {
    try writer.writeAll("graph LR\n");
    for (report.nodes) |node| {
        try writer.print("    {s}[\"{s}\"]\n", .{ node.name, node.name });
    }
    for (report.nodes) |node| {
        for (node.dependencies) |dep| {
            try writer.print("    {s} --> {s}\n", .{ node.name, dep });
        }
    }
}

/// Graphviz DOT — `dot -Tsvg`.
pub fn renderDot(report: Report, writer: anytype) !void {
    try writer.writeAll("digraph modules {\n  rankdir=LR;\n");
    for (report.nodes) |node| {
        try writer.print("  \"{s}\";\n", .{node.name});
    }
    for (report.nodes) |node| {
        for (node.dependencies) |dep| {
            try writer.print("  \"{s}\" -> \"{s}\";\n", .{ node.name, dep });
        }
    }
    try writer.writeAll("}\n");
}

/// Plain text: the graph, then the findings. What `zmodu doctor` prints when
/// stdout is a terminal.
pub fn renderText(report: Report, writer: anytype) !void {
    try writer.print("modules: {d}   dependency depth: {d}\n", .{ report.nodes.len, report.max_depth });
    for (report.nodes) |node| {
        try writer.print("  {s}", .{node.name});
        if (node.is_internal) try writer.writeAll(" (internal)");
        if (node.dependencies.len == 0) {
            try writer.writeAll("  →  (no dependencies)\n");
        } else {
            try writer.writeAll("  →  ");
            for (node.dependencies, 0..) |dep, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.writeAll(dep);
            }
            try writer.writeByte('\n');
        }
    }
    if (report.findings.len == 0) {
        try writer.writeAll("architecture: OK\n");
        return;
    }
    try writer.writeAll("\nfindings:\n");
    for (report.findings) |f| {
        const severity = switch (f.kind) {
            .too_many_dependencies, .orphan => "warn",
            else => "ERROR",
        };
        try writer.print("  [{s}] {s}: ", .{ severity, @tagName(f.kind) });
        switch (f.kind) {
            .cycle => {
                for (f.cycle.?, 0..) |name, i| {
                    if (i > 0) try writer.writeAll(" → ");
                    try writer.writeAll(name);
                }
                try writer.writeByte('\n');
            },
            .missing_dependency => try writer.print("{s} depends on unknown module '{s}'\n", .{ f.subject, f.detail }),
            .self_dependency => try writer.print("{s} depends on itself\n", .{f.subject}),
            .duplicate_name => try writer.print("duplicate module name '{s}'\n", .{f.subject}),
            .too_many_dependencies => try writer.print("{s} has {s} dependencies\n", .{ f.subject, f.detail }),
            .orphan => try writer.print("{s} has no dependencies and nothing depends on it\n", .{f.subject}),
        }
    }
}

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

/// Test fixture. Deliberately *not* `api.Module`: the analyser reads `info.name`,
/// `info.description`, `info.dependencies` and `info.is_internal` through
/// `@field`, so any type with those fields is a valid module here — which is also
/// why this file has no framework imports and can be handed to the CLI as a module.
fn makeModule(comptime name: []const u8, comptime deps: []const []const u8) type {
    return struct {
        pub const Info = struct {
            name: []const u8,
            description: []const u8 = "",
            dependencies: []const []const u8 = &.{},
            is_internal: bool = false,
        };
        pub const info = Info{
            .name = name,
            .description = "test module",
            .dependencies = deps,
        };
        pub fn init() !void {}
        pub fn deinit() void {}
    };
}

const Alpha = makeModule("alpha", &.{});
const Risk = makeModule("risk", &.{"alpha"});
const Exec = makeModule("exec", &.{"risk"});
const CycleA = makeModule("cycle-a", &.{"cycle-b"});
const CycleB = makeModule("cycle-b", &.{"cycle-a"});
const SelfDep = makeModule("self-dep", &.{"self-dep"});
const Typo = makeModule("typo", &.{"no-such-module"});
const Dupe = makeModule("alpha", &.{});
const Wide = makeModule("wide", &.{ "alpha", "risk", "exec", "cycle-a", "cycle-b", "self-dep", "typo", "dupe", "extra" });
const Lonely = makeModule("lonely", &.{});

test "ModuleGraph: a healthy graph has no findings and measures depth" {
    const report = comptime analyze(&.{ Alpha, Risk, Exec }, .{});
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 0), report.findings.len);
    try std.testing.expectEqual(@as(usize, 3), report.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), report.max_depth); // exec → risk → alpha
}

test "ModuleGraph: cycle is reported with the path, and blocks" {
    const report = comptime analyze(&.{ CycleA, CycleB }, .{});
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.count(.cycle));
    const path = report.findings[0].cycle.?;
    try std.testing.expect(path.len >= 3); // a → b → a
    try std.testing.expectEqualStrings(path[0], path[path.len - 1]);
}

test "ModuleGraph: self dependency and unknown dependency block" {
    const report = comptime analyze(&.{ SelfDep, Typo }, .{});
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.count(.self_dependency));
    try std.testing.expectEqual(@as(usize, 1), report.count(.missing_dependency));
    try std.testing.expectEqualStrings("no-such-module", report.findings[1].detail);
}

test "ModuleGraph: duplicate names block (two modules cannot own one name)" {
    const report = comptime analyze(&.{ Alpha, Dupe }, .{});
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.count(.duplicate_name));
}

test "ModuleGraph: sizing and orphans are advisory, not blocking" {
    const report = comptime analyze(&.{ Alpha, Risk, Exec, Wide }, .{ .max_dependencies = 3 });
    try std.testing.expectEqual(@as(usize, 1), report.count(.too_many_dependencies));
    // Alpha is depended on, so not an orphan; the wide module is not either.
    try std.testing.expectEqual(@as(usize, 0), report.count(.orphan));

    // A module nobody depends on and that depends on nothing *is* an orphan.
    const lonely = comptime analyze(&.{ Alpha, Risk, Lonely }, .{});
    try std.testing.expectEqual(@as(usize, 1), lonely.count(.orphan));
    try std.testing.expectEqualStrings("lonely", lonely.findings[0].subject);
    // Orphans are warnings: a graph with one still compiles.
    try std.testing.expect(lonely.ok());
}

test "ModuleGraph: renderers emit the edges they were given" {
    const report = comptime analyze(&.{ Alpha, Risk, Exec }, .{});
    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    try renderMermaid(report, &stream);
    const mermaid = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "graph LR") != null);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "exec --> risk") != null);

    var dot_buf: [1024]u8 = undefined;
    var dot_stream = std.Io.Writer.fixed(&dot_buf);
    try renderDot(report, &dot_stream);
    try std.testing.expect(std.mem.indexOf(u8, dot_stream.buffered(), "\"exec\" -> \"risk\"") != null);

    var text_buf: [2048]u8 = undefined;
    var text_stream = std.Io.Writer.fixed(&text_buf);
    try renderText(report, &text_stream);
    const text = text_stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "architecture: OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "exec  →  risk") != null);

    // A broken graph renders its errors with the cycle spelled out.
    const bad = comptime analyze(&.{ CycleA, CycleB }, .{});
    var bad_buf: [2048]u8 = undefined;
    var bad_stream = std.Io.Writer.fixed(&bad_buf);
    try renderText(bad, &bad_stream);
    const bad_text = bad_stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, bad_text, "[ERROR] cycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_text, "cycle-a → cycle-b → cycle-a") != null);
}

test "renderErrors names every blocking finding" {
    const bad = comptime analyze(&.{ CycleA, CycleB, Typo }, .{});
    const text = comptime renderErrors(bad);
    std.debug.print("\n[renderErrors]\n{s}\n", .{text});
    try std.testing.expect(std.mem.indexOf(u8, text, "circular dependency") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unknown module") != null);
}
