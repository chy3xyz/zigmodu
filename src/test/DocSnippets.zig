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
//!
//! The 2026-09-17 source-doc audit turned up two more shapes that cannot compile,
//! and the corpus grew to match: markdown **and** Zig doc comments (`//!` / `///`)
//! are now checked for
//!
//! * `try app.runtime().spawn(…)` — `runtime()` returns `!*Runtime`, so `try` may
//!   cover the call but never the member access chained onto it;
//! * `Application.init(allocator, …)` — the first parameter is `io`
//!   (`init(io, allocator, name, modules, Config)`).
//!
//! Both rules judge the markdown corpus too, and the pre-0.16 snippets they
//! found there are fixed. The corpus is: the top-level guides (`AGENTS.md`,
//! `README.md`, `README.zh.md`), `docs/*.md`, and every `*.md` under `docs/`
//! recursively — `docs/dev/**` included since the follow-up pass, minus
//! `docs/superpowers/**` (a plugin's own plans/specs tree, not this project's
//! docs). Fences are what is judged; prose and table cells are shorthand.
//!
//! The 2026-09-18 pass added the two `Context`-accessor shapes that had been
//! shipping in `AGENTS.md`'s core code patterns — the most-copied snippet in
//! the repo — and were the ones the gate never looked at:
//!
//! * `ctx.json(200, .{ .ok = true })` — `json`'s second parameter is
//!   `[]const u8`, so the value form has to go through `ctx.jsonStruct`
//!   (alias `jsonValue`);
//! * `ctx.paramInt("id")` — `paramInt` is a generic taking the integer type
//!   first (`paramInt(comptime T, key)`); the string-only form cannot compile.
//!
//! Both are matched on the decidable half only: a numeric status literal plus a
//! second argument that opens a struct literal for the first rule, a string
//! literal as the first argument for the second. `ctx.json(200, body)` is the
//! legitimate string form, `jsonStruct` is a different call, and a line that
//! breaks after `(` is a fragment — none of them are flagged.
//!
//! One exemption applies to every rule: a full-line `//` comment inside a fence
//! is prose *about* code. The line that warns "the chained
//! `builder(…).build(…)` one-liner does not compile" names the broken shape
//! without offering it, and judging it would punish the warning itself.
//!
//! A block that shows an older signature on purpose — the v0.4
//! `Application.init` in `docs/MIGRATION_v04_to_v07.md` — is tagged `text`, not
//! `zig`: only `zig` and untagged fences are judged, so history stays readable
//! without tripping the gate.

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

const runtime_fix_hint =
    "  bind it first: const rt = try app.runtime();\n" ++
    "  then: const worker = try rt.spawn(W, .{}, capacity);\n";

const init_fix_hint =
    "  real signature: Application.init(io, allocator, name, modules, Config)\n" ++
    "  or bind the builder: var b = zmodu.builder(allocator, io); defer b.deinit();\n";

const json_fix_hint =
    "  `json` takes a pre-serialised `[]const u8` body;\n" ++
    "  for a value use: ctx.jsonStruct(status, value) (alias jsonValue)\n";

const param_int_fix_hint =
    "  real signature: ctx.paramInt(T, key)\n" ++
    "  e.g. ctx.paramInt(i64, \"id\")\n";

/// Optional per-corpus rules. Every corpus runs the whole set today; the struct
/// stays so a corpus can exempt a rule it has not been cleaned for yet.
const Rules = struct {
    /// Flag `Application.init(allocator…`.
    init_first_arg: bool = false,
};

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

/// The `try` trap: `app.runtime()` returns `!*Runtime`, so `try` may cover that
/// call — never the call *and* the member access chained onto it.
const runtime_call = "app.runtime()";

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when `text` contains the keyword `try` — not as part of a longer word
/// (`retry`), so `pretry = app.runtime()` is not mistaken for a `try`.
fn hasTryToken(text: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, "try")) |at| {
        const clean_before = at == 0 or !isIdentChar(text[at - 1]);
        const clean_after = at + 3 >= text.len or !isIdentChar(text[at + 3]);
        if (clean_before and clean_after) return true;
        from = at + 3;
    }
    return false;
}

/// Offset of `app.runtime()` in `line`, or null. A match that follows an
/// identifier character does not count — `retry_app.runtime()` is somebody
/// else's call, not this application's runtime.
fn indexOfRuntimeCall(line: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, runtime_call)) |at| {
        if (at == 0 or !isIdentChar(line[at - 1])) return at;
        from = at + 1;
    }
    return null;
}

/// Returns the chained member (`.spawn(`) when the line puts `try` in front of a
/// whole `app.runtime().member` chain.
fn tryWrapsRuntimeChain(line: []const u8) ?[]const u8 {
    const at = indexOfRuntimeCall(line) orelse return null;
    if (!hasTryToken(line[0..at])) return null;
    const tail = std.mem.trimStart(u8, line[at + runtime_call.len ..], " \t");
    if (tail.len == 0 or tail[0] != '.') return null;
    const paren = std.mem.indexOfScalar(u8, tail, '(') orelse return tail[0..@min(tail.len, 24)];
    return tail[0 .. paren + 1];
}

/// True when the `try app.runtime()` expression on this line continues (no `;`
/// yet), i.e. a `.member(` on the next line completes the broken chain.
fn tryCoversRuntimeContinues(line: []const u8) bool {
    const at = indexOfRuntimeCall(line) orelse return false;
    if (!hasTryToken(line[0..at])) return false;
    return std.mem.indexOfScalar(u8, line[at..], ';') == null;
}

/// True when the first argument of `Application.init(` is an allocator: `alloc`,
/// `allocator`, `std.testing.allocator`, `std.heap.…` all fail the same way, and
/// the real first parameter is `io`. The argument *count* is not decidable from a
/// fragment; "the first argument is not `io`" is the decidable half.
fn initStartsWithAllocator(line: []const u8) bool {
    const at = std.mem.indexOf(u8, line, "Application.init(") orelse return false;
    // `MyApplication.init(…` is a different (unknown) call — require a boundary.
    if (at > 0 and isIdentChar(line[at - 1])) return false;
    const arg = std.mem.trimStart(u8, line[at + "Application.init(".len ..], " \t");
    return std.mem.startsWith(u8, arg, "alloc") or
        std.mem.startsWith(u8, arg, "std.testing.allocator") or
        std.mem.startsWith(u8, arg, "std.heap") or
        std.mem.startsWith(u8, arg, "arena");
}

/// Byte offset of a `ctx.<method>(` call that is not glued to a longer
/// identifier: `self.ctx.json(` is still this `ctx`, `mini_ctx.json(` is
/// somebody else's object.
fn indexOfCtxCall(line: []const u8, comptime call: []const u8) ?usize {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, call)) |at| {
        if (at == 0 or !isIdentChar(line[at - 1])) return at;
        from = at + 1;
    }
    return null;
}

fn digitsPrefix(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and (std.ascii.isDigit(text[i]) or text[i] == '_')) i += 1;
    return i;
}

/// `ctx.json(200, .{ … })` — the second parameter is `[]const u8`, so a struct
/// literal there cannot compile; the value form is `ctx.jsonStruct(status, value)`
/// (alias `jsonValue`). Both halves have to hold, so the decidable cases stay
/// clear: a numeric status literal (a variable status is unknowable from one
/// line) *and* a second argument that starts a struct literal —
/// `ctx.json(200, body)` is the legitimate string form and is left alone.
fn jsonGetsStructLiteral(line: []const u8) ?[]const u8 {
    const call = "ctx.json(";
    const at = indexOfCtxCall(line, call) orelse return null;
    var rest = std.mem.trimStart(u8, line[at + call.len ..], " \t");
    const digits = digitsPrefix(rest);
    if (digits == 0) return null;
    rest = std.mem.trimStart(u8, rest[digits..], " \t");
    if (rest.len == 0 or rest[0] != ',') return null;
    rest = std.mem.trimStart(u8, rest[1..], " \t");
    if (!std.mem.startsWith(u8, rest, ".{")) return null;
    return line[at .. line.len - rest.len + 2];
}

/// `ctx.paramInt("id")` — the generic takes the integer type first
/// (`paramInt(comptime T, key)`), so a string literal as the first argument
/// cannot compile. `paramInt(i64, "id")`, `paramInt(T, "id")` and the
/// line-broken fragment `ctx.paramInt(` are not judged.
fn paramIntMissingType(line: []const u8) bool {
    const call = "ctx.paramInt(";
    const at = indexOfCtxCall(line, call) orelse return false;
    const arg = std.mem.trimStart(u8, line[at + call.len ..], " \t");
    return arg.len > 0 and (arg[0] == '"' or arg[0] == '\'');
}

/// `doc_line` turns a raw file line into the text to judge, or `null` when the
/// line is not part of the document (code outside doc comments — which also ends
/// any pending chain).
fn scanText(
    path: []const u8,
    text: []const u8,
    doc_line: *const fn ([]const u8) ?[]const u8,
    rules: Rules,
    violations: *usize,
) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_fence = false;
    var fence_is_zig = false;
    var pending_builder = false;
    var pending_runtime = false;
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = doc_line(raw) orelse {
            pending_builder = false;
            pending_runtime = false;
            continue;
        };

        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            if (in_fence) {
                in_fence = false;
                fence_is_zig = false;
            } else {
                in_fence = true;
                const tag = std.mem.trim(u8, std.mem.trimStart(u8, line, " \t")[3..], " \t\r");
                fence_is_zig = tag.len == 0 or std.mem.eql(u8, tag, "zig");
            }
            pending_builder = false;
            pending_runtime = false;
            continue;
        }
        if (!fence_is_zig) continue;

        // A full-line `//` comment is prose *about* code — the line that warns
        // "the chained `builder(…).build(…)` one-liner does not compile" names
        // the broken shape without offering it, and judging it would punish the
        // very warning the gate exists to spread. Nothing in a comment is meant
        // to be copied, so no detector runs on it; a pending chain survives it.
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "//")) continue;

        if (chainedOnSameLine(line)) |method| {
            std.debug.print("[doc-snippets] {s}:{d}: `builder(…){s}…` cannot compile\n{s}", .{ path, line_no, method, fix_hint });
            violations.* += 1;
            pending_builder = false;
            pending_runtime = false;
            continue;
        }
        if (tryWrapsRuntimeChain(line)) |member| {
            std.debug.print("[doc-snippets] {s}:{d}: `try app.runtime(){s}…` cannot compile — `runtime()` returns `!*Runtime`\n{s}", .{ path, line_no, member, runtime_fix_hint });
            violations.* += 1;
            pending_builder = false;
            pending_runtime = false;
            continue;
        }
        if (rules.init_first_arg and initStartsWithAllocator(line)) {
            std.debug.print("[doc-snippets] {s}:{d}: `Application.init(allocator…` cannot compile\n{s}", .{ path, line_no, init_fix_hint });
            violations.* += 1;
            pending_builder = false;
            pending_runtime = false;
            continue;
        }
        if (jsonGetsStructLiteral(line)) |snippet| {
            std.debug.print("[doc-snippets] {s}:{d}: `{s}…` cannot compile — the second parameter is `[]const u8`\n{s}", .{ path, line_no, snippet, json_fix_hint });
            violations.* += 1;
            pending_builder = false;
            pending_runtime = false;
            continue;
        }
        if (paramIntMissingType(line)) {
            std.debug.print("[doc-snippets] {s}:{d}: `ctx.paramInt(\"…\")` lacks the type parameter\n{s}", .{ path, line_no, param_int_fix_hint });
            violations.* += 1;
            pending_builder = false;
            pending_runtime = false;
            continue;
        }
        if (std.mem.indexOf(u8, line, "builder(") != null) {
            pending_builder = continuesAfterBuilder(line);
            pending_runtime = false;
            continue;
        }
        if (indexOfRuntimeCall(line) != null) {
            pending_runtime = tryCoversRuntimeContinues(line);
            pending_builder = false;
            continue;
        }
        if (pending_builder) {
            pending_builder = false;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '.') {
                std.debug.print("[doc-snippets] {s}:{d}: `builder(…)` chain continues with `{s}`\n{s}", .{ path, line_no, trimmed[0..@min(trimmed.len, 24)], fix_hint });
                violations.* += 1;
            }
        }
        if (pending_runtime) {
            pending_runtime = false;
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] == '.') {
                std.debug.print("[doc-snippets] {s}:{d}: `try app.runtime()` chain continues with `{s}`\n{s}", .{ path, line_no, trimmed[0..@min(trimmed.len, 24)], runtime_fix_hint });
                violations.* += 1;
            }
        }
    }
}

/// Markdown corpus. Scans only **fenced code blocks** (```` ```zig ```` or
/// untagged) — that is where runnable snippets live. Prose and table cells are
/// shorthand, not code to copy. Fences run the same checks as source doc
/// comments; `Rules` decides which of them apply.
fn scan(allocator: std.mem.Allocator, path: []const u8, rules: Rules, violations: *usize) void {
    const content = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        std.Io.Limit.limited(1 << 20),
    ) catch return;
    defer allocator.free(content);

    scanText(path, content, &everythingIsDoc, rules, violations);
}

/// A markdown file has no comment markers: every line belongs to the document.
fn everythingIsDoc(line: []const u8) ?[]const u8 {
    return line;
}

/// A Zig file documents itself in `//!` / `///`; every other line is code, and
/// code that does not compile never ships — so only doc comments are judged.
fn zigDocLine(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    for ([_][]const u8{ "//!", "///" }) |marker| {
        if (std.mem.startsWith(u8, trimmed, marker)) return trimmed[marker.len..];
    }
    return null;
}

/// Source corpus: one file's doc comments.
fn scanZigDocComments(allocator: std.mem.Allocator, path: []const u8, rules: Rules, violations: *usize) void {
    const content = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        std.Io.Limit.limited(1 << 20),
    ) catch return;
    defer allocator.free(content);

    scanText(path, content, &zigDocLine, rules, violations);
}

/// Source corpus: `*.zig` under `dir_path`, recursively (the doc-comment audit
/// found its snippets in `src/Application.zig` and the two `runtime` files, so
/// the whole tree is covered rather than a hand-kept list of files).
fn scanZigTree(allocator: std.mem.Allocator, dir_path: []const u8, rules: Rules, violations: *usize) void {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.debug("[doc-snippets] {s} unreadable ({s}), skipped", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(std.testing.io);

    var it = dir.iterate();
    while (it.next(std.testing.io) catch return) |entry| {
        const path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch return;
        defer allocator.free(path);
        switch (entry.kind) {
            .directory => scanZigTree(allocator, path, rules, violations),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
                // This file documents the broken shapes on purpose (module header
                // and detector tests); scanning it would flag itself.
                if (std.mem.eql(u8, path, "src/test/DocSnippets.zig")) continue;
                scanZigDocComments(allocator, path, rules, violations);
            },
            else => {},
        }
    }
}

/// Markdown corpus: every `*.md` under `dir_path`, recursively. `skip` names
/// subdirectories to leave alone — `docs/superpowers/**` is a plugin's own tree
/// (plans/specs), not this project's docs.
fn scanMarkdownTree(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    skip: []const []const u8,
    rules: Rules,
    violations: *usize,
) void {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true }) catch |err| {
        std.log.debug("[doc-snippets] {s} unreadable ({s}), skipped", .{ dir_path, @errorName(err) });
        return;
    };
    defer dir.close(std.testing.io);

    var it = dir.iterate();
    while (it.next(std.testing.io) catch return) |entry| {
        var excluded = false;
        for (skip) |name| {
            if (std.mem.eql(u8, entry.name, name)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;

        const path = std.fs.path.join(allocator, &.{ dir_path, entry.name }) catch return;
        defer allocator.free(path);
        switch (entry.kind) {
            .directory => scanMarkdownTree(allocator, path, skip, rules, violations),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".md")) continue;
                scan(allocator, path, rules, violations);
            },
            else => {},
        }
    }
}

/// True when the text contains a Han character — the English README must stay
/// English (the Chinese one is `README.zh.md`). Cheap check, real regression:
/// five rows of the docs/example tables had drifted into Chinese.
fn hasHan(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch {
            i += 1;
            continue;
        };
        if (cp >= 0x4E00 and cp <= 0x9FFF) return true; // CJK Unified Ideographs
        i += len;
    }
    return false;
}

test "docs: the English README contains no Chinese (README.zh.md is the Chinese one)" {
    const allocator = std.testing.allocator;
    const content = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "README.md",
        allocator,
        std.Io.Limit.limited(1 << 20),
    ) catch |err| {
        std.log.debug("[english-docs] README.md unreadable ({s}), skipped", .{@errorName(err)});
        return;
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var line_no: usize = 0;
    var hits: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (!hasHan(line)) continue;
        hits += 1;
        std.debug.print("[english-docs] README.md:{d} contains Chinese: {s}\n", .{ line_no, line[0..@min(line.len, 100)] });
    }
    if (hits > 0) return error.ChineseInEnglishReadme;

    // The Chinese README, by contrast, must actually be Chinese (a sanity check
    // that keeps the two files from being swapped by accident).
    const zh = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "README.zh.md",
        allocator,
        std.Io.Limit.limited(1 << 20),
    ) catch return;
    defer allocator.free(zh);
    if (!hasHan(zh)) return error.EnglishInChineseReadme;
}

test "doc snippets: the markdown corpus carries none of the known-uncompilable shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var violations: usize = 0;

    // Top-level guides.
    for ([_][]const u8{ "AGENTS.md", "README.md", "README.zh.md" }) |path| scan(allocator, path, .{ .init_first_arg = true }, &violations);

    // Every markdown file under docs/, recursively. `docs/dev/**` carries the
    // pre-implementation design notes the follow-up pass cleaned; the plugin's
    // own tree under `docs/superpowers/**` is not this project's docs.
    scanMarkdownTree(allocator, "docs", &.{"superpowers"}, .{ .init_first_arg = true }, &violations);

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

test "doc snippets: source scans find the `try app.runtime()` chain and clear the bound form" {
    // The broken shape: `runtime()` is fallible, so this `try` covers the chain.
    try std.testing.expectEqualStrings(".spawn(", tryWrapsRuntimeChain(
        "const worker = try app.runtime().spawn(W, .{}, 256);",
    ).?);
    try std.testing.expectEqualStrings(".stats(", tryWrapsRuntimeChain(
        "const s = try app.runtime().stats();",
    ).?);
    // Multi-line: `try app.runtime()` on its own line, `.spawn(` on the next.
    try std.testing.expect(tryWrapsRuntimeChain("const worker = try app.runtime()") == null);
    try std.testing.expect(tryCoversRuntimeContinues("const worker = try app.runtime()"));

    // The working forms: `try` covers the call, the result is bound.
    try std.testing.expect(tryWrapsRuntimeChain("const rt = try app.runtime();") == null);
    try std.testing.expect(!tryCoversRuntimeContinues("const rt = try app.runtime();"));
    try std.testing.expect(tryWrapsRuntimeChain("const worker = try rt.spawn(W, .{}, 256);") == null);
    // A call that merely mentions the runtime, or an infallible one, is fine.
    try std.testing.expect(tryWrapsRuntimeChain("// app.runtime() is created on first use") == null);
    try std.testing.expect(tryWrapsRuntimeChain("const rt = try retry_app.runtime().stats();") == null);
}

test "doc snippets: the init detector flags an allocator-first call and clears the io-first one" {
    // The broken shape: the pre-0.16 signature, allocator first.
    try std.testing.expect(initStartsWithAllocator(
        "var app = try zigmodu.Application.init(allocator, .{ .name = \"shop\" });",
    ));
    try std.testing.expect(initStartsWithAllocator(
        "var app = try Application.init(alloc, \"app\", .{M});",
    ));
    try std.testing.expect(initStartsWithAllocator(
        "var app = try Application.init(std.testing.allocator, \"app\", .{M}, .{});",
    ));

    // The working forms: `io` first, however it is spelled.
    try std.testing.expect(!initStartsWithAllocator(
        "var app = try zigmodu.Application.init(io, allocator, \"shop\", .{M}, .{});",
    ));
    try std.testing.expect(!initStartsWithAllocator(
        "var app = try Application.init(std.testing.io, allocator, \"app\", .{M}, .{});",
    ));
    // `ApplicationBuilder.init` really does take the allocator first — not this rule.
    try std.testing.expect(!initStartsWithAllocator("var b = zigmodu.ApplicationBuilder.init(allocator, io);"));
    // A fragment that breaks the line after `(` is not judged (docs' multi-line form).
    try std.testing.expect(!initStartsWithAllocator("var app = try zigmodu.Application.init("));
}

test "doc snippets: source doc comments carry no stale snippets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var violations: usize = 0;
    scanZigTree(allocator, "src", .{ .init_first_arg = true }, &violations);

    if (violations > 0) {
        std.debug.print("[doc-snippets] {d} source doc snippet(s) that cannot compile\n", .{violations});
        return error.DocSnippetViolation;
    }
}

test "doc snippets: the json detector flags the value form and clears the string form" {
    // The broken shape: a struct literal where `[]const u8` is expected.
    try std.testing.expectEqualStrings("ctx.json(200, .{", jsonGetsStructLiteral(
        "try ctx.json(200, .{ .ok = true });",
    ).?);
    try std.testing.expectEqualStrings("ctx.json(201, .{", jsonGetsStructLiteral(
        "try ctx.json(201, .{ .code = 0, .msg = \"\", .data = data });",
    ).?);
    // Inside a longer receiver is still this `ctx`.
    try std.testing.expect(jsonGetsStructLiteral("try self.ctx.json(200, .{ .ok = true });") != null);

    // The working forms: a `[]const u8` body, a value through `jsonStruct`.
    try std.testing.expect(jsonGetsStructLiteral("try ctx.json(200, \"{\\\"ok\\\":true}\");") == null);
    try std.testing.expect(jsonGetsStructLiteral("try ctx.json(200, body);") == null);
    try std.testing.expect(jsonGetsStructLiteral("const r = try std.fmt.allocPrint(ctx.allocator, \"{{\\\"id\\\":{d}}}\", .{id});") == null);
    try std.testing.expect(jsonGetsStructLiteral("try ctx.json(200, try std.fmt.allocPrint(ctx.allocator, \"{{}}\", .{}));") == null);
    try std.testing.expect(jsonGetsStructLiteral("try ctx.jsonStruct(200, .{ .ok = true });") == null);
    try std.testing.expect(jsonGetsStructLiteral("try ctx.jsonValue(200, .{ .ok = true });") == null);
    // A status the fragment does not pin down is not judged.
    try std.testing.expect(jsonGetsStructLiteral("try ctx.json(status, .{ .ok = true });") == null);
    // A different object's `json(…)` is not this rule's business.
    try std.testing.expect(jsonGetsStructLiteral("try mini_ctx.json(200, .{ .ok = true });") == null);
}

test "doc snippets: the paramInt detector flags the type-less form and clears the generic one" {
    // The broken shape: the key in the type position.
    try std.testing.expect(paramIntMissingType("const id = try ctx.paramInt(\"id\");"));
    try std.testing.expect(paramIntMissingType("const id = try ctx.paramInt( 'id' );"));

    // The working forms: the integer type first, however it is spelled.
    try std.testing.expect(!paramIntMissingType("const id = try ctx.paramInt(i64, \"id\");"));
    try std.testing.expect(!paramIntMissingType("const n = try ctx.paramInt(u32, \"page\");"));
    try std.testing.expect(!paramIntMissingType("const id = try ctx.paramInt(UserId, \"id\");"));
    // A different object, a different method.
    try std.testing.expect(!paramIntMissingType("const id = try mini_ctx.paramInt(\"id\");"));
    try std.testing.expect(!paramIntMissingType("const n = ctx.queryInt(i64, \"page\", 1);"));
    // A fragment that breaks the line after `(` is not judged.
    try std.testing.expect(!paramIntMissingType("const id = try ctx.paramInt("));
}

test "doc snippets: a full-line comment inside a fence is prose, not a snippet" {
    const block =
        "```zig\n" ++
        "// the chained builder(allocator, io).build(.{M}) one-liner does not compile\n" ++
        "// ctx.json(200, .{ .ok = true }) is the wrong shape too\n" ++
        "var app = try zmodu.builder(allocator, io).build(.{M});\n" ++
        "```\n";

    var violations: usize = 0;
    scanText("inline", block, &everythingIsDoc, .{ .init_first_arg = true }, &violations);
    // Only the line that actually offers the shape counts.
    try std.testing.expectEqual(@as(usize, 1), violations);
}
