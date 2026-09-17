//! Doc snippets are code, and one of them was wrong in twelve places.
//!
//! Found the hard way: `AGENTS.md`, `README.md` ×2, `README.zh.md`, six files
//! under `docs/`, two source comments and the CLI's generated text all showed
//!
//! ```zig
//! var app = try zmodu.builder(allocator, io).withName("app").build(.{ModuleA});
//! ```
//!
//! which does not compile: `ApplicationBuilder`'s methods take `*Self`, and a
//! function-call temporary materialises as `*const` —
//! `error: expected type '*T', found '*const T'`. Nothing checked doc snippets, so
//! every reader copied a snippet that could not build. The working form is to bind
//! the builder first:
//!
//! ```zig
//! var b = zmodu.builder(allocator, io);
//! defer b.deinit();
//! var app = try b.withName("app").build(.{ModuleA});
//! ```
//!
//! This test is the cheap half of the fix: it scans the docs for a builder method
//! chained straight off the temporary (same line, or the next line starting with
//! `.`) and names the file. Compiling every fenced block would be the thorough
//! half and is not worth it here — most snippets are fragments or pseudo-code.

const std = @import("std");

/// Builder methods that cannot be called on a temporary (they take `*Self`).
const builder_methods = [_][]const u8{
    ".withName(",
    ".withService(",
    ".withValidation(",
    ".withDocsPath(",
    ".withAutoDocs(",
    ".withMaxDependencies(",
    ".withCompileTimeGraphCheck(",
    ".security(",
    ".build(",
};

const fix_hint =
    "  bind it first: var b = zmodu.builder(allocator, io); defer b.deinit();\n" ++
    "  then: var app = try b.withName(…).build(.{…});\n";

/// Returns the offending method when `line` chains one straight off the
/// `builder(` temporary on the same line.
fn chainedOnSameLine(line: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, "builder(") orelse return null;
    const tail = line[at + "builder(".len ..];
    for (builder_methods) |m| {
        if (std.mem.indexOf(u8, tail, m) != null) return m;
    }
    return null;
}

/// True when the `builder(...)` expression on this line continues (no `;` yet),
/// i.e. the next non-empty line's leading `.method(` is part of the same chain.
fn continuesAfterBuilder(line: []const u8) bool {
    const at = std.mem.indexOf(u8, line, "builder(") orelse return false;
    return std.mem.indexOfScalar(u8, line[at..], ';') == null;
}

/// Scans only **fenced code blocks** (` ```zig ` or untagged) — that is where
/// runnable snippets live. Prose and table cells are shorthand, not code to copy.
fn scan(allocator: std.mem.Allocator, path: []const u8, violations: *usize) void {
    const content = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        std.Io.Limit.limited(1 << 20),
    ) catch return;
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var pending_chain = false;
    var in_fence = false;
    var fence_is_zig = false;
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;

        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            if (in_fence) {
                in_fence = false;
                fence_is_zig = false;
            } else {
                in_fence = true;
                const tag = std.mem.trim(u8, std.mem.trimStart(u8, line, " \t")[3..], " \t\r");
                fence_is_zig = tag.len == 0 or std.mem.eql(u8, tag, "zig");
            }
            pending_chain = false;
            continue;
        }
        if (!fence_is_zig) continue;

        if (chainedOnSameLine(line)) |method| {
            std.debug.print("[doc-snippets] {s}:{d}: `builder(…){s}…` cannot compile\n{s}", .{ path, line_no, method, fix_hint });
            violations.* += 1;
            pending_chain = false;
            continue;
        }
        if (std.mem.indexOf(u8, line, "builder(") != null) {
            pending_chain = continuesAfterBuilder(line);
            continue;
        }
        if (pending_chain) {
            pending_chain = false;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '.') {
                std.debug.print("[doc-snippets] {s}:{d}: `builder(…)` chain continues with `{s}`\n{s}", .{ path, line_no, trimmed[0..@min(trimmed.len, 24)], fix_hint });
                violations.* += 1;
            }
        }
    }
}

test "doc snippets: no builder method is chained straight off the temporary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var violations: usize = 0;

    // Top-level guides.
    for ([_][]const u8{ "AGENTS.md", "README.md", "README.zh.md" }) |path| scan(allocator, path, &violations);

    // Every markdown file under docs/ (dev notes included: they are read too).
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, "docs", .{ .iterate = true }) catch |err| {
        std.log.debug("[doc-snippets] docs/ unreadable ({s}), skipped", .{@errorName(err)});
        return;
    };
    defer dir.close(std.testing.io);

    var it = dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
        const path = try std.fs.path.join(allocator, &.{ "docs", entry.name });
        scan(allocator, path, &violations);
    }

    if (violations > 0) {
        std.debug.print("[doc-snippets] {d} snippet(s) that cannot compile\n", .{violations});
        return error.DocSnippetViolation;
    }
}

test "doc snippets: the detector flags the chained form and clears the bound form" {
    // The broken shape (this is what twelve places looked like).
    try std.testing.expectEqualStrings(".withName(", chainedOnSameLine(
        "var app = try zmodu.builder(allocator, io).withName(\"app\").build(.{M});",
    ).?);
    try std.testing.expectEqualStrings(".build(", chainedOnSameLine(
        "var app = try zmodu.builder(allocator, io).build(.{M});",
    ).?);
    // Multi-line: the line carries the temporary, the next one starts the chain.
    try std.testing.expect(chainedOnSameLine("var app = try zmodu.builder(allocator, io)") == null);
    try std.testing.expect(continuesAfterBuilder("var app = try zmodu.builder(allocator, io)"));

    // The working forms: bound to a variable first.
    try std.testing.expect(chainedOnSameLine("var b = zmodu.builder(allocator, io);") == null);
    try std.testing.expect(!continuesAfterBuilder("var b = zmodu.builder(allocator, io);"));
    try std.testing.expect(chainedOnSameLine("var app = try b.withName(\"app\").build(.{M});") == null);
    // A different call that happens to be a temporary is not this rule's business.
    try std.testing.expect(chainedOnSameLine("const x = try registry.dispatch(\"a\").run();") == null);
}
