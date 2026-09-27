//! Test-collection gate — a source file whose tests never run must fail the
//! build, not sit in the suite looking green.
//!
//! ## The hazard
//!
//! Zig collects a file's `test` declarations only when the file is reached from
//! the analysis of a **test body**. A file that production code imports and uses
//! can therefore carry tests that never execute, and a green suite says nothing
//! about them. Measured in this repository (Zig 0.17.0-dev.2151): a deliberate
//! `expect(false)` inside one of `tools/zmodu/src/incremental.zig`'s six tests
//! changed nothing — the CLI suite still reported `113/113 … exit 0` — and the
//! same held for `mcp_server.zig` (7 tests) and `mcp_types.zig` (3). Sixteen
//! tests, one deliberate failure, zero signal. Both batches were repaired the
//! same way, an `_ = @import(…)` line inside a test block — which is exactly the
//! edit nobody remembers to make.
//!
//! ## Why a count, not a reachability walk
//!
//! The cheap-looking mechanism — follow `@import("…")` edges textually from the
//! test roots and flag every file with tests that no edge reaches — does not
//! reproduce the compiler's rule, and three files in this tree prove it:
//!
//!   * `tools/zmodu/src/incremental.zig` is imported *and used* at the top level
//!     of the CLI's root file (`main.zig:32`, several call sites): its tests were
//!     NOT collected;
//!   * `tools/zmodu/src/orm_tpl.zig` sits in the same position (`main.zig:27`,
//!     used by the scaffold code) and is never named inside a `test` block
//!     either: its tests ARE collected;
//!   * `tools/zmodu/src/mcp_types.zig` is imported and used by `mcp_server.zig`
//!     (itself reached through a test-block import) — the same shape as
//!     `orm_tpl.zig` — and its tests were NOT collected.
//!
//! Two textually identical edges land on opposite sides, so no lexical rule
//! ("imports inside test blocks", "any import", "a reference inside a test
//! block") matches: the first is red on `orm_tpl.zig` today, the second reports
//! `mcp_types.zig` as reachable (the one case the gate exists to catch), the
//! third is red on `orm_tpl.zig` too. The check therefore does not model the
//! rule; it reads the compiler's own answer.
//!
//! ## Mechanism
//!
//! `builtin.test_functions` is the artifact's collected test list — the list the
//! test runner executes — and every entry's fully-qualified name starts with the
//! declaring file's path relative to the module root directory, separators
//! turned into dots (`core/Time.zig` → `core.Time.test.…`; checked against this
//! toolchain, where `sub/inner.zig` reports `sub.inner.test.…`). The gate walks
//! the tree, counts `test` declarations per file textually, counts collected
//! names per file, and fails unless all three of these hold:
//!
//!   1. every file that declares tests has at least one of them collected — the
//!      gate proper; the failure names the file and the count;
//!   2. no file has collected tests it does not declare — the textual counter
//!      cannot drift into silence, a shape it cannot see shows up here;
//!   3. the totals agree and every collected name belongs to a file in the tree
//!      — the walk is looking at the right tree and nothing leaks in from
//!      another module.
//!
//! (1) plus (3) is exact rather than heuristic: a file whose tests are not
//! collected is missing from the very list the runner iterates, so the counts
//! cannot agree by accident.
//!
//! ## Limits, stated
//!
//! * A file whose tests are compiled by a **different build step** is absent
//!   from this artifact and must be listed in `other_artifacts`. That entry is a
//!   claim about build.zig; `scripts/check-test-collection.sh` checks every entry
//!   is a real compile root in the package's build.zig, so the list cannot be
//!   used to silence a file whose tests nobody runs.
//! * The declaration counter is textual, and it is the *count* that is checked,
//!   not the shape: a declaration split across lines (`test` / `"name"` / `{`)
//!   is not seen — which trips (2)/(3) and fails the gate loudly rather than
//!   passing quietly. `\\…` multiline-string lines are skipped on purpose: this
//!   tree keeps Zig source templates inside them (`tools/zmodu/src/main.zig`
//!   alone has 37 `\\test "…" {` lines) and those are text, not declarations.
//! * The tree is anchored by a path relative to the directory `zig build` was
//!   invoked from (the same assumption the other tree-walking gates under
//!   `src/test/` make), and each artifact lists its candidates (`src`,
//!   `tools/zmodu/src`). A wrong anchor is a failure, never a silent skip: the
//!   marker file has to be there, and a walk that finds nothing cannot satisfy
//!   the totals.

const std = @import("std");
const builtin = @import("builtin");

const Dir = std.Io.Dir;

/// One test artifact's view of a source tree.
pub const Artifact = struct {
    /// Tree label for failure messages, e.g. `tools/zmodu/src`.
    label: []const u8,
    /// Candidate directories for the artifact's module root — the directory a
    /// file's fully-qualified name is relative to — most likely first, each
    /// relative to the directory `zig build` was invoked from. The first that
    /// exists *and* contains `marker` wins, so the same call site can serve the
    /// package's own build (`src`) and the root build (`tools/zmodu/src`).
    root_candidates: []const []const u8,
    /// File whose presence proves a candidate is the tree (the module root file
    /// of the artifact, e.g. `main.zig`).
    marker: []const u8,
    /// Files, relative to the tree root, whose tests a *different* build step
    /// compiles — they are legitimately absent from this artifact.
    other_artifacts: []const []const u8 = &.{},
};

const Report = struct {
    rel: []const u8,
    /// `core/Time.zig` → `core.Time.test` — the fully-qualified name prefix of
    /// every test the compiler collected from this file.
    fqn_prefix: []const u8,
    declared: usize,
    collected: usize,
    excluded: bool,
};

/// Fail with `error.TestCollectionViolation` when the artifact does not collect
/// every test the tree declares. Call it from a (named) test in the artifact's
/// module root file, so the gate itself is always collected.
pub fn assertAllCollected(io: std.Io, allocator: std.mem.Allocator, artifact: Artifact) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = resolveRoot(io, a, artifact) orelse {
        std.debug.print("[test-collection] {s}: none of the candidate roots contains `{s}`:", .{ artifact.label, artifact.marker });
        for (artifact.root_candidates) |cand| std.debug.print(" {s}", .{cand});
        std.debug.print(
            "\n[test-collection]   Run the gate from the package root (`zig build test`), or fix the candidate list.\n" ++
                "[test-collection]   A gate that cannot find its tree must not pass.\n",
            .{},
        );
        return error.TestCollectionViolation;
    };

    const rels = try zigFilesUnder(io, a, root);
    std.mem.sort([]const u8, rels.items, {}, pathLessThan);

    var reports: std.ArrayList(Report) = .empty;
    defer reports.deinit(a);
    for (rels.items) |rel| {
        const path = try std.fs.path.join(a, &.{ root, rel });
        const content = Dir.cwd().readFileAlloc(io, path, a, std.Io.Limit.limited(8 * 1024 * 1024)) catch |err| {
            std.debug.print("[test-collection] {s}: {s} is in the tree but unreadable ({s})\n", .{ artifact.label, rel, @errorName(err) });
            return error.TestCollectionViolation;
        };
        try reports.append(a, .{
            .rel = rel,
            .fqn_prefix = try fqnPrefix(a, rel),
            .declared = countTestDeclarations(content),
            .collected = 0,
            .excluded = contains(artifact.other_artifacts, rel),
        });
    }

    // Attribute every collected test to the file whose prefix it carries. The
    // longest match wins, so `a/test.zig` (`a.test`) and `a.zig` (`a`) cannot
    // steal each other's tests.
    var unattributed: usize = 0;
    for (builtin.test_functions) |tf| {
        var owner: ?usize = null;
        for (reports.items, 0..) |r, i| {
            if (!std.mem.startsWith(u8, tf.name, r.fqn_prefix)) continue;
            if (owner == null or reports.items[owner.?].fqn_prefix.len < r.fqn_prefix.len) owner = i;
        }
        if (owner) |i| {
            reports.items[i].collected += 1;
        } else {
            if (unattributed < 3) {
                std.debug.print("[test-collection] {s}: collected test `{s}` matches no file under {s}\n", .{ artifact.label, tf.name, root });
            }
            unattributed += 1;
        }
    }

    var missing: usize = 0;
    var inconsistent: usize = 0;
    var declared_total: usize = 0;
    var collected_total: usize = 0;
    for (reports.items) |r| {
        if (r.excluded) {
            // The entry claims another step compiles these tests. If they are
            // collected *here* the entry is wrong, and a stale entry is how this
            // list would start hiding files.
            if (r.collected != 0) {
                std.debug.print(
                    "[test-collection] {s}: {s} is listed in other_artifacts, but {d} of its test(s) are collected here — drop the entry\n",
                    .{ artifact.label, r.rel, r.collected },
                );
                inconsistent += 1;
            }
            continue;
        }
        declared_total += r.declared;
        collected_total += r.collected;
        if (r.declared > 0 and r.collected == 0) {
            std.debug.print("[test-collection] {s}: {s} declares {d} test(s); this test binary collects none of them.\n", .{ artifact.label, r.rel, r.declared });
            missing += 1;
        }
        if (r.collected > 0 and r.declared == 0) {
            std.debug.print(
                "[test-collection] {s}: {s} has {d} collected test(s) the declaration counter did not see — fix the counter in src/test/TestCollection.zig\n",
                .{ artifact.label, r.rel, r.collected },
            );
            inconsistent += 1;
        }
    }

    if (missing > 0) {
        std.debug.print(
            "[test-collection] {s}: {d} file(s) above declare tests that never run. Zig collects a file's tests only\n" ++
                "[test-collection]   when a test body reaches it — being imported by production code is not enough. Fix:\n" ++
                "[test-collection]       _ = @import(\"<file>.zig\");   // inside an existing test block\n" ++
                "[test-collection]   or, when another build step compiles that file's tests, add it to `other_artifacts`\n" ++
                "[test-collection]   (and scripts/check-test-collection.sh checks that claim against build.zig).\n",
            .{ artifact.label, missing },
        );
    }

    if (declared_total != collected_total) {
        std.debug.print(
            "[test-collection] {s}: {d} declared test(s) in the tree vs {d} collected by this binary — the totals must agree\n",
            .{ artifact.label, declared_total, collected_total },
        );
        inconsistent += 1;
    }

    if (missing != 0 or inconsistent != 0 or unattributed != 0) return error.TestCollectionViolation;
}

fn resolveRoot(io: std.Io, a: std.mem.Allocator, artifact: Artifact) ?[]const u8 {
    for (artifact.root_candidates) |cand| {
        const marker = std.fs.path.join(a, &.{ cand, artifact.marker }) catch continue;
        _ = Dir.cwd().statFile(io, marker, .{}) catch continue;
        return cand;
    }
    return null;
}

/// Every `.zig` file under `root`, as paths relative to it (`/`-separated).
fn zigFilesUnder(io: std.Io, a: std.mem.Allocator, root: []const u8) !std.ArrayList([]const u8) {
    var files: std.ArrayList([]const u8) = .empty;
    errdefer files.deinit(a);
    try collect(io, a, root, "", &files);
    return files;
}

fn collect(io: std.Io, a: std.mem.Allocator, root: []const u8, rel: []const u8, out: *std.ArrayList([]const u8)) !void {
    const path = if (rel.len == 0) root else try std.fs.path.join(a, &.{ root, rel });
    var dir = try Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (isSkippedDir(entry.name)) continue;
                const sub = if (rel.len == 0)
                    try a.dupe(u8, entry.name)
                else
                    try std.fs.path.join(a, &.{ rel, entry.name });
                try collect(io, a, root, sub, out);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                const rel_path = if (rel.len == 0)
                    try a.dupe(u8, entry.name)
                else
                    try std.fs.path.join(a, &.{ rel, entry.name });
                try out.append(a, rel_path);
            },
            else => {},
        }
    }
}

fn isSkippedDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out");
}

fn pathLessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn contains(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

/// `core/Time.zig` → `core.Time.`: the prefix every fully-qualified name of a
/// test collected from that file starts with. A column-0 test is
/// `core.Time.test.name`; an unnamed block is `core.Time.test_0`; a test declared
/// inside a nested container is `core.Time.Reader.test.name` (measured:
/// `core.DistributedEventBus.DistributedEventBus.test.…`,
/// `http.HttpClient.HttpClient.test.…`). All three start with `core.Time.`, and
/// the trailing dot is what keeps `a.zig` from claiming `a/b.zig`'s tests.
fn fqnPrefix(a: std.mem.Allocator, rel: []const u8) ![]const u8 {
    const stem = rel[0 .. rel.len - ".zig".len];
    const out = try a.dupe(u8, stem);
    for (out) |*c| {
        if (c.* == '/' or c.* == '\\') c.* = '.';
    }
    return std.fmt.allocPrint(a, "{s}.", .{out});
}

/// Count the file's `test` declarations textually — see the module doc for the
/// limits this counter is checked against.
fn countTestDeclarations(content: []const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "\\\\")) continue; // multiline-string prose
        if (!std.mem.startsWith(u8, line, "test")) continue;
        const rest = std.mem.trimStart(u8, line["test".len..], " \t");
        if (rest.len == 0) continue;
        if (rest[0] == '"' or rest[0] == '{') n += 1;
    }
    return n;
}
