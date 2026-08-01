//! Core dead-code analysis for Zig source files.
//!
//! Methodology (modeled after rustc's `dead_code` lint):
//!   1. Parse every scanned file.
//!   2. Collect declarations: top-level `fn`/`const`/`var`/`test` plus the
//!      members of named containers (struct fields, enum variants, union
//!      fields, methods, nested declarations).
//!   3. Collect references: every identifier token that is not a declaration
//!      site. Same-file references resolve by name; `@import` aliases resolve
//!      qualified references across files (`alias.name`); `@import("x").name`
//!      resolves inline. Member accesses (`.name`) feed a whole-project
//!      heuristic.
//!   4. Reachability: roots are `pub` declarations (unless `include_pub`),
//!      exported declarations, `test` blocks (unless `no_tests`), `@export`
//!      targets, and (in binary mode) declarations named `main`. A declaration
//!      is live when reachable from a root through the reference graph.
//!   5. Everything not live is reported as dead.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// Report unused `pub` declarations too (by default `pub` is an API root).
    include_pub: bool = false,
    /// Do not treat `test` blocks as entry points.
    no_tests: bool = false,
    /// Disable the container-member heuristic (any `.name` anywhere counts as a use).
    no_members: bool = false,
    /// Binary mode: `main` is an entry point and never-imported files are reported.
    binary: bool = false,
    /// Disable never-imported-file reporting.
    no_files: bool = false,
    /// Paths (canonical) of files explicitly named on the command line.
    /// These are never reported as never-imported.
    root_file_paths: []const []const u8 = &.{},
};

pub const File = struct {
    /// Canonical absolute path; used as identity and for `@import` resolution.
    path: []const u8,
    /// Path used in reports (usually relative to the invocation directory).
    display_path: []const u8,
    source: [:0]const u8,
};

pub const Kind = enum {
    fn_decl,
    const_decl,
    var_decl,
    struct_decl,
    enum_decl,
    union_decl,
    opaque_decl,
    error_set_decl,
    test_decl,
    field,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .fn_decl => "function",
            .const_decl => "constant",
            .var_decl => "variable",
            .struct_decl => "struct",
            .enum_decl => "enum",
            .union_decl => "union",
            .opaque_decl => "opaque type",
            .error_set_decl => "error set",
            .test_decl => "test",
            .field => "field",
        };
    }
};

pub const Decl = struct {
    file: usize,
    name: []const u8,
    kind: Kind,
    line: u32,
    column: u32,
    is_pub: bool = false,
    is_export: bool = false,
    parent: ?usize = null,
    start_tok: u32 = 0,
    end_tok: u32 = 0,
    live: bool = false,
};

pub const Finding = struct {
    file: usize,
    name: []const u8,
    kind: Kind,
    line: u32,
    column: u32,
    parent: ?usize,
};

pub const Summary = struct {
    files_scanned: usize = 0,
    files_parsed: usize = 0,
    parse_errors: usize = 0,
    decls: usize = 0,
    live: usize = 0,
    dead: usize = 0,
    unused_files: usize = 0,
    refs: usize = 0,
    imports: usize = 0,
};

pub const Result = struct {
    arena: *std.heap.ArenaAllocator,
    backing_alloc: std.mem.Allocator,
    decls: []Decl,
    findings: []Finding,
    unused_files: []usize,
    summary: Summary,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.backing_alloc.destroy(self.arena);
    }
};

const AliasInfo = struct {
    file: usize,
    decl: usize,
};

const FileMaps = struct {
    decl_sites: std.AutoHashMap(u32, usize),
    name_map: std.StringHashMap(usize),
    aliases: std.StringHashMap(AliasInfo),
    line_starts: std.ArrayList(usize),
    decl_indices: std.ArrayList(usize),
    /// Decl index of `const X = @This();`, if the file uses the
    /// file-as-container pattern.
    self_decl: ?usize = null,
};

const LineCol = struct {
    line: u32,
    column: u32,
};

const Analyzer = struct {
    alloc: std.mem.Allocator,
    opts: Options,
    files: []const File,
    asts: []Ast,
    parsed: []bool,
    file_by_path: std.StringHashMap(usize),
    file_maps: []FileMaps,
    decls: std.ArrayList(Decl),
    adj: std.ArrayList(std.ArrayList(usize)),
    root_refs: std.ArrayList(usize),
    export_roots: std.ArrayList(usize),
    member_refs: std.StringHashMap(void),
    imported_files: std.AutoHashMap(usize, void),
    summary: Summary,

    fn deinit(self: *Analyzer) void {
        for (self.asts, 0..) |*ast, i| {
            if (self.parsed[i]) ast.deinit(self.alloc);
        }
        for (self.file_maps) |*fm| {
            fm.decl_sites.deinit();
            fm.name_map.deinit();
            fm.aliases.deinit();
            fm.line_starts.deinit(self.alloc);
            fm.decl_indices.deinit(self.alloc);
        }
        self.file_by_path.deinit();
        self.decls.deinit(self.alloc);
        for (self.adj.items) |*list| list.deinit(self.alloc);
        self.adj.deinit(self.alloc);
        self.root_refs.deinit(self.alloc);
        self.export_roots.deinit(self.alloc);
        self.member_refs.deinit();
        self.imported_files.deinit();
    }
};

/// Runs the analysis over the provided files. The returned `Result` owns all
/// memory derived from the analysis; free it with `result.deinit()`.
pub fn analyze(
    backing_alloc: std.mem.Allocator,
    files: []const File,
    options: Options,
) !Result {
    const arena = try backing_alloc.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(backing_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var an = Analyzer{
        .alloc = alloc,
        .opts = options,
        .files = files,
        .asts = try alloc.alloc(Ast, files.len),
        .parsed = try alloc.alloc(bool, files.len),
        .file_by_path = std.StringHashMap(usize).init(alloc),
        .file_maps = try alloc.alloc(FileMaps, files.len),
        .decls = .empty,
        .adj = .empty,
        .root_refs = .empty,
        .export_roots = .empty,
        .member_refs = std.StringHashMap(void).init(alloc),
        .imported_files = std.AutoHashMap(usize, void).init(alloc),
        .summary = .{},
    };
    errdefer an.deinit();

    an.summary.files_scanned = files.len;

    for (files, 0..) |f, i| {
        try an.file_by_path.put(f.path, i);
        an.parsed[i] = false;
        an.file_maps[i] = .{
            .decl_sites = std.AutoHashMap(u32, usize).init(alloc),
            .name_map = std.StringHashMap(usize).init(alloc),
            .aliases = std.StringHashMap(AliasInfo).init(alloc),
            .line_starts = .empty,
            .decl_indices = .empty,
        };
        try buildLineStarts(&an, i);
    }

    // Parse.
    for (files, 0..) |f, i| {
        var ast = Ast.parse(alloc, f.source, .{}) catch |err| {
            an.summary.parse_errors += 1;
            std.debug.print("zdeadcode: failed to parse {s}: {s}\n", .{ f.display_path, @errorName(err) });
            continue;
        };
        if (ast.errors.len != 0) {
            an.summary.parse_errors += 1;
            std.debug.print("zdeadcode: parse error in {s}\n", .{f.display_path});
            ast.deinit(alloc);
            continue;
        }
        an.asts[i] = ast;
        an.parsed[i] = true;
        an.summary.files_parsed += 1;
    }

    // Collect declarations.
    for (files, 0..) |_, i| {
        if (!an.parsed[i]) continue;
        try collectFile(&an, i);
    }

    // Link top-level declarations of `@This()` modules to the self alias so
    // that `.member` references and pub ancestry apply to them.
    for (files, 0..) |_, fi| {
        const self_decl = an.file_maps[fi].self_decl;
        if (self_decl == null) continue;
        for (an.file_maps[fi].decl_indices.items) |d| {
            if (d != self_decl.? and
                an.decls.items[d].parent == null and
                an.decls.items[d].kind != .test_decl)
            {
                an.decls.items[d].parent = self_decl;
            }
        }
    }

    // Build the reference adjacency structure.
    for (an.decls.items) |_| {
        try an.adj.append(alloc, .empty);
    }

    // Scan references.
    for (files, 0..) |_, i| {
        if (!an.parsed[i]) continue;
        try scanFile(&an, i);
    }

    // Reachability.
    try computeLiveness(&an);

    // Assemble the result.
    var findings: std.ArrayList(Finding) = .empty;
    var unused: std.ArrayList(usize) = .empty;
    var live_count: usize = 0;
    for (an.decls.items, 0..) |_, i| {
        if (an.decls.items[i].live) {
            live_count += 1;
        } else {
            try findings.append(alloc, .{
                .file = an.decls.items[i].file,
                .name = an.decls.items[i].name,
                .kind = an.decls.items[i].kind,
                .line = an.decls.items[i].line,
                .column = an.decls.items[i].column,
                .parent = an.decls.items[i].parent,
            });
        }
    }
    std.mem.sort(Finding, findings.items, {}, findingLessThan);

    if (options.binary and !options.no_files) {
        for (files, 0..) |f, fi| {
            if (an.imported_files.contains(fi)) continue;
            var is_root = false;
            for (options.root_file_paths) |rp| {
                if (std.mem.eql(u8, rp, f.path)) {
                    is_root = true;
                    break;
                }
            }
            if (!is_root and fileHasMain(&an, fi)) is_root = true;
            if (!is_root) try unused.append(alloc, fi);
        }
    }

    const decls = try an.decls.toOwnedSlice(alloc);
    const finding_slice = try findings.toOwnedSlice(alloc);
    const unused_slice = try unused.toOwnedSlice(alloc);

    an.summary.decls = decls.len;
    an.summary.live = live_count;
    an.summary.dead = finding_slice.len;
    an.summary.unused_files = unused_slice.len;

    an.deinit();

    return .{
        .arena = arena,
        .backing_alloc = backing_alloc,
        .decls = decls,
        .findings = finding_slice,
        .unused_files = unused_slice,
        .summary = an.summary,
    };
}

/// True when the file declares something named `main` (the binary entry point).
fn fileHasMain(an: *Analyzer, fi: usize) bool {
    for (an.file_maps[fi].decl_indices.items) |d| {
        if (std.mem.eql(u8, an.decls.items[d].name, "main")) return true;
    }
    return false;
}

fn findingLessThan(_: void, a: Finding, b: Finding) bool {
    if (a.file != b.file) return a.file < b.file;
    if (a.line != b.line) return a.line < b.line;
    if (a.column != b.column) return a.column < b.column;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn buildLineStarts(an: *Analyzer, fi: usize) !void {
    const source = an.files[fi].source;
    const starts = &an.file_maps[fi].line_starts;
    try starts.append(an.alloc, 0);
    for (source, 0..) |c, i| {
        if (c == '\n') try starts.append(an.alloc, i + 1);
    }
}

fn lineCol(an: *Analyzer, fi: usize, byte_offset: usize) LineCol {
    const starts = an.file_maps[fi].line_starts.items;
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (starts[mid] <= byte_offset) lo = mid else hi = mid;
    }
    return .{ .line = @intCast(lo + 1), .column = @intCast(byte_offset - starts[lo] + 1) };
}

fn fileAst(an: *Analyzer, fi: usize) Ast {
    return an.asts[fi];
}

// ---------------------------------------------------------------------------
// Declaration collection
// ---------------------------------------------------------------------------

fn collectFile(an: *Analyzer, fi: usize) Allocator.Error!void {
    const ast = fileAst(an, fi);
    for (ast.rootDecls()) |node| {
        try collectDecl(an, fi, node, null);
    }
}

fn collectDecl(an: *Analyzer, fi: usize, node: Ast.Node.Index, parent: ?usize) Allocator.Error!void {
    const ast = fileAst(an, fi);
    switch (ast.nodeTag(node)) {
        .fn_decl, .fn_proto => {
            var buf: [1]Ast.Node.Index = undefined;
            const fp = ast.fullFnProto(&buf, node) orelse return;
            const name_tok = fp.name_token orelse return; // anonymous fn types are not decls
            const is_export = fp.extern_export_inline_token != null and
                ast.tokenTag(fp.extern_export_inline_token.?) == .keyword_export;
            const is_extern = fp.extern_export_inline_token != null and
                ast.tokenTag(fp.extern_export_inline_token.?) == .keyword_extern;
            _ = is_extern; // extern linkage alone does not make a decl live
            _ = try addDecl(an, fi, node, name_tok, ast.tokenSlice(name_tok), .fn_decl, fp.visib_token != null, is_export, parent);
        },
        .global_var_decl, .simple_var_decl, .aligned_var_decl => {
            const vd = ast.fullVarDecl(node) orelse return;
            // In 0.17, `mut_token` is the `const`/`var` keyword itself; the
            // declaration name is the identifier that follows it.
            const name_tok = vd.ast.mut_token + 1;
            const name = ast.tokenSlice(name_tok);
            const is_export = vd.extern_export_token != null and
                ast.tokenTag(vd.extern_export_token.?) == .keyword_export;
            const kind: Kind = if (ast.tokenTag(vd.ast.mut_token) == .keyword_const)
                .const_decl
            else
                .var_decl;
            const d = try addDecl(an, fi, node, name_tok, name, kind, vd.visib_token != null, is_export, parent);

            const init_node = vd.ast.init_node.unwrap();
            if (init_node) |init| {
                if (containerKind(an, fi, init)) |ck| {
                    an.decls.items[d].kind = ck;
                    try collectMembers(an, fi, init, d);
                } else if (ast.nodeTag(init) == .error_set_decl) {
                    an.decls.items[d].kind = .error_set_decl;
                    try collectErrorSetMembers(an, fi, init, d);
                }

                // `const X = @This();` marks a file-as-container module.
                if (parent == null and importPathOf(an, fi, init) == null and
                    isThisCall(an, fi, init))
                {
                    an.file_maps[fi].self_decl = d;
                }

                if (importPathOf(an, fi, init)) |target_file| {
                    try an.file_maps[fi].aliases.put(name, .{ .file = target_file, .decl = d });
                }
            }
        },
        .container_field, .container_field_init, .container_field_align => {
            const cf = ast.fullContainerField(node) orelse return;
            // Enum variants are also `tuple_like`; only skip unnamed tuple
            // fields of structs and unions.
            const parent_kind: ?Kind = if (parent) |p| an.decls.items[p].kind else null;
            if (cf.ast.tuple_like and parent_kind != .enum_decl) return;
            const name_tok = cf.ast.main_token;
            _ = try addDecl(an, fi, node, name_tok, ast.tokenSlice(name_tok), .field, false, false, parent);
        },
        .test_decl => {
            const main_tok = ast.nodeMainToken(node);
            const name: []const u8 = if (ast.tokenTag(main_tok + 1) == .string_literal)
                try unquoteString(an, ast.tokenSlice(main_tok + 1))
            else
                "<anonymous>";
            _ = try addDecl(an, fi, node, main_tok, name, .test_decl, false, false, parent);
        },
        else => {},
    }
}

fn isThisCall(an: *Analyzer, fi: usize, node: Ast.Node.Index) bool {
    const ast = fileAst(an, fi);
    const tag = ast.nodeTag(node);
    if (tag != .builtin_call and tag != .builtin_call_comma and
        tag != .builtin_call_two and tag != .builtin_call_two_comma)
    {
        return false;
    }
    return std.mem.eql(u8, ast.tokenSlice(ast.nodeMainToken(node)), "@This");
}

fn addDecl(
    an: *Analyzer,
    fi: usize,
    node: Ast.Node.Index,
    name_tok: u32,
    name: []const u8,
    kind: Kind,
    is_pub: bool,
    is_export: bool,
    parent: ?usize,
) Allocator.Error!usize {
    const ast = fileAst(an, fi);
    const idx = an.decls.items.len;
    const pos = lineCol(an, fi, ast.tokenStart(name_tok));
    try an.decls.append(an.alloc, .{
        .file = fi,
        .name = name,
        .kind = kind,
        .line = pos.line,
        .column = pos.column,
        .is_pub = is_pub,
        .is_export = is_export,
        .parent = parent,
        .start_tok = ast.firstToken(node),
        .end_tok = ast.lastToken(node),
    });
    try an.file_maps[fi].decl_sites.put(name_tok, idx);
    // Test declarations use their string name (e.g. `test "foo"`), which is a
    // display name, not a referencable identifier. Container members are
    // referenced via '.' and must never shadow a top-level declaration of the
    // same name (e.g. `const deadcode = @import(...)` + `enum { deadcode }`).
    // Both cases would otherwise resolve references to the wrong decl and
    // misreport the top-level declaration as dead.
    if (kind != .test_decl) {
        if (parent != null) {
            if (!an.file_maps[fi].name_map.contains(name)) {
                try an.file_maps[fi].name_map.put(name, idx);
            }
        } else {
            try an.file_maps[fi].name_map.put(name, idx);
        }
    }
    try an.file_maps[fi].decl_indices.append(an.alloc, idx);
    return idx;
}

fn collectMembers(an: *Analyzer, fi: usize, container_node: Ast.Node.Index, parent: usize) Allocator.Error!void {
    const ast = fileAst(an, fi);
    var buf: [2]Ast.Node.Index = undefined;
    const cd = ast.fullContainerDecl(&buf, container_node) orelse return;
    for (cd.ast.members) |m| {
        try collectDecl(an, fi, m, parent);
    }
}

fn collectErrorSetMembers(an: *Analyzer, fi: usize, error_set_node: Ast.Node.Index, parent: usize) Allocator.Error!void {
    const ast = fileAst(an, fi);
    const braces = ast.nodeData(error_set_node).token_and_token;
    var t = braces[0] + 1;
    while (t < braces[1]) : (t += 1) {
        if (ast.tokenTag(t) == .identifier) {
            _ = try addDecl(an, fi, error_set_node, t, ast.tokenSlice(t), .field, false, false, parent);
        }
    }
}

fn containerKind(an: *Analyzer, fi: usize, node: Ast.Node.Index) ?Kind {
    const ast = fileAst(an, fi);
    return switch (ast.nodeTag(node)) {
        .container_decl,
        .container_decl_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        => switch (ast.tokenTag(ast.nodeMainToken(node))) {
            .keyword_struct => .struct_decl,
            .keyword_enum => .enum_decl,
            .keyword_union => .union_decl,
            .keyword_opaque => .opaque_decl,
            else => .struct_decl,
        },
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Reference collection
// ---------------------------------------------------------------------------

fn scanFile(an: *Analyzer, fi: usize) !void {
    const ast = fileAst(an, fi);
    const fm = &an.file_maps[fi];

    // Sort this file's decls by start token so we can track, for any token,
    // the innermost declaration containing it.
    const sorted = try an.alloc.dupe(usize, fm.decl_indices.items);
    std.mem.sort(usize, sorted, an.decls.items, declStartLessThan);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(an.alloc);
    var si: usize = 0;

    const token_count = ast.tokens.len;
    var t: u32 = 0;
    while (t < token_count) : (t += 1) {
        while (si < sorted.len and an.decls.items[sorted[si]].start_tok == t) : (si += 1) {
            try stack.append(an.alloc, sorted[si]);
        }
        while (stack.items.len > 0 and
            an.decls.items[stack.items[stack.items.len - 1]].end_tok < t)
        {
            _ = stack.pop();
        }
        const origin: ?usize = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null;

        switch (ast.tokenTag(t)) {
            .identifier => try scanIdent(an, fi, t, origin),
            .builtin => try scanBuiltin(an, fi, t, origin),
            else => {},
        }
    }
}

fn declStartLessThan(decls: []Decl, a: usize, b: usize) bool {
    return decls[a].start_tok < decls[b].start_tok;
}

fn prevNonDoc(ast: Ast, t: u32) ?u32 {
    var i = t;
    while (i > 0) {
        i -= 1;
        if (ast.tokenTag(i) != .doc_comment) return i;
    }
    return null;
}

fn nextNonDoc(ast: Ast, t: u32) ?u32 {
    var i = t + 1;
    while (i < ast.tokens.len) : (i += 1) {
        if (ast.tokenTag(i) != .doc_comment) return i;
    }
    return null;
}

fn scanIdent(an: *Analyzer, fi: usize, t: u32, origin: ?usize) !void {
    const ast = fileAst(an, fi);
    const fm = &an.file_maps[fi];
    const name = ast.tokenSlice(t);

    if (fm.decl_sites.contains(t)) return;

    const prev = prevNonDoc(ast, t);
    const next = nextNonDoc(ast, t);

    // Member-style reference: `.name`
    if (prev != null and ast.tokenTag(prev.?) == .period) {
        if (!an.opts.no_members) try an.member_refs.put(name, {});
        // Resolve the chain base for cross-file references: `alias.a.b.c`
        // walking back over `period identifier` pairs.
        var base: i64 = @intCast(prev.?);
        while (base - 2 >= 0 and
            ast.tokenTag(@intCast(base - 1)) == .identifier and
            ast.tokenTag(@intCast(base - 2)) == .period)
        {
            base -= 2;
        }
        if (base - 1 >= 0 and ast.tokenTag(@intCast(base - 1)) == .identifier) {
            const base_name = ast.tokenSlice(@intCast(base - 1));
            if (fm.aliases.get(base_name)) |ai| {
                const seg2_tok: u32 = @intCast(base + 1);
                if (seg2_tok < ast.tokens.len and ast.tokenTag(seg2_tok) == .identifier) {
                    if (resolveDeclInFile(an, ai.file, ast.tokenSlice(seg2_tok))) |td| {
                        try addRef(an, origin, td);
                    }
                }
            }
        }
        return;
    }

    // Chain base: `name.member...`
    if (next != null and ast.tokenTag(next.?) == .period) {
        if (fm.aliases.get(name)) |ai| {
            const seg2_tok: u32 = next.? + 1;
            if (seg2_tok < ast.tokens.len and ast.tokenTag(seg2_tok) == .identifier) {
                if (resolveDeclInFile(an, ai.file, ast.tokenSlice(seg2_tok))) |td| {
                    try addRef(an, origin, td);
                }
            }
        }
        // The base itself is a use of the same-file declaration.
        if (fm.name_map.get(name)) |d| try addRef(an, origin, d);
        return;
    }

    // Plain identifier.
    if (fm.name_map.get(name)) |d| try addRef(an, origin, d);
}

fn scanBuiltin(an: *Analyzer, fi: usize, t: u32, origin: ?usize) !void {
    const ast = fileAst(an, fi);
    const bname = ast.tokenSlice(t);

    if (std.mem.eql(u8, bname, "@import")) {
        var i: u32 = t + 1;
        var import_path: ?[]const u8 = null;
        var rparen: ?u32 = null;
        while (i < ast.tokens.len) : (i += 1) {
            const tag = ast.tokenTag(i);
            if (tag == .string_literal and import_path == null) {
                import_path = try unquoteString(an, ast.tokenSlice(i));
            } else if (tag == .r_paren) {
                rparen = i;
                break;
            }
        }
        if (import_path) |raw_path| {
            if (resolveImportPath(an, fi, raw_path)) |target_fi| {
                try an.imported_files.put(target_fi, {});
                an.summary.imports += 1;
                if (rparen) |rp| {
                    const j = rp + 1;
                    if (j + 1 < ast.tokens.len and ast.tokenTag(j) == .period and
                        ast.tokenTag(j + 1) == .identifier)
                    {
                        if (resolveDeclInFile(an, target_fi, ast.tokenSlice(j + 1))) |td| {
                            try addRef(an, origin, td);
                        }
                    }
                }
            }
        }
        return;
    }

    if (std.mem.eql(u8, bname, "@export")) {
        // The first argument is the exported value: `&foo`, `foo`, or `.member`.
        var i: u32 = t + 1;
        while (i < ast.tokens.len) : (i += 1) {
            const tag = ast.tokenTag(i);
            if (tag == .r_paren or tag == .comma) break;
            if (tag == .identifier) {
                if (an.file_maps[fi].name_map.get(ast.tokenSlice(i))) |d| {
                    try an.export_roots.append(an.alloc, d);
                }
                break;
            }
            if (tag == .period and i + 1 < ast.tokens.len and ast.tokenTag(i + 1) == .identifier) {
                try an.member_refs.put(ast.tokenSlice(i + 1), {});
                break;
            }
        }
    }
}

fn addRef(an: *Analyzer, origin: ?usize, to: usize) !void {
    an.summary.refs += 1;
    if (origin) |o| {
        if (o == to) return;
        try an.adj.items[o].append(an.alloc, to);
    } else {
        try an.root_refs.append(an.alloc, to);
    }
}

fn resolveDeclInFile(an: *Analyzer, fi: usize, name: []const u8) ?usize {
    return an.file_maps[fi].name_map.get(name);
}

fn resolveImportPath(an: *Analyzer, fi: usize, raw_path: []const u8) ?usize {
    // Skip package imports and exotic paths.
    if (std.mem.startsWith(u8, raw_path, "@")) return null;
    if (std.mem.indexOfScalar(u8, raw_path, '\\') != null) return null;
    if (!std.mem.endsWith(u8, raw_path, ".zig")) return null;

    const file_path = an.files[fi].path;
    const dir = std.fs.path.dirname(file_path) orelse return null;
    const joined = std.fs.path.resolve(an.alloc, &.{ dir, raw_path }) catch return null;
    defer an.alloc.free(joined);
    return an.file_by_path.get(joined);
}

fn importPathOf(an: *Analyzer, fi: usize, node: Ast.Node.Index) ?usize {
    const ast = fileAst(an, fi);
    const tag = ast.nodeTag(node);
    if (tag != .builtin_call and tag != .builtin_call_comma and
        tag != .builtin_call_two and tag != .builtin_call_two_comma)
    {
        return null;
    }
    const main_tok = ast.nodeMainToken(node);
    if (!std.mem.eql(u8, ast.tokenSlice(main_tok), "@import")) return null;

    var buf: [2]Ast.Node.Index = undefined;
    const params = ast.builtinCallParams(&buf, node) orelse return null;
    if (params.len == 0) return null;
    if (ast.nodeTag(params[0]) != .string_literal) return null;
    const raw = unquoteString(an, ast.tokenSlice(ast.nodeMainToken(params[0]))) catch return null;
    return resolveImportPath(an, fi, raw);
}

fn unquoteString(an: *Analyzer, raw: []const u8) ![]const u8 {
    var s = raw;
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s = s[1 .. s.len - 1];
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len and (s[i + 1] == '/' or s[i + 1] == '\\')) {
            try out.append(an.alloc, s[i + 1]);
            i += 1;
        } else {
            try out.append(an.alloc, s[i]);
        }
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// Reachability
// ---------------------------------------------------------------------------

fn computeLiveness(an: *Analyzer) !void {
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(an.alloc);

    for (an.decls.items, 0..) |_, i| {
        if (isRoot(an, i)) try markLive(an, &queue, i);
    }
    for (an.export_roots.items) |d| {
        try markLive(an, &queue, d);
    }
    for (an.root_refs.items) |d| {
        try markLive(an, &queue, d);
    }
    if (!an.opts.no_members) {
        for (an.decls.items, 0..) |d, i| {
            // Any container member (including top-level fields of `@This()`
            // style modules) referenced via `.name` anywhere is live.
            const is_member = d.parent != null or d.kind == .field;
            if (is_member and an.member_refs.contains(d.name)) {
                try markLive(an, &queue, i);
                if (d.parent) |p| try markLive(an, &queue, p);
            }
        }
    }

    while (queue.items.len > 0) {
        const d = queue.pop().?;
        for (an.adj.items[d].items) |to| try markLive(an, &queue, to);
    }
}

fn markLive(an: *Analyzer, queue: *std.ArrayList(usize), i: usize) !void {
    if (an.decls.items[i].live) return;
    an.decls.items[i].live = true;
    try queue.append(an.alloc, i);
}

fn isRoot(an: *Analyzer, i: usize) bool {
    const d = an.decls.items[i];
    if (d.kind == .test_decl and !an.opts.no_tests) return true;
    if (d.is_export) return true;
    if (!an.opts.include_pub) {
        // Pub declarations are API roots, and so are members of pub
        // containers: in Zig, container members are externally accessible.
        var cur: ?usize = i;
        while (cur) |c| {
            if (an.decls.items[c].is_pub) return true;
            cur = an.decls.items[c].parent;
        }
    }
    if (an.opts.binary and std.mem.eql(u8, d.name, "main")) return true;
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_files = [_]File{
    .{ .path = "/proj/main.zig", .display_path = "main.zig", .source =
    \\const std = @import("std");
    \\
    \\fn unused_fn() void {}
    \\
    \\fn used_helper() i32 {
    \\    return 42;
    \\}
    \\
    \\fn dead_calls_dead() void {
    \\    dead_helper();
    \\}
    \\
    \\fn dead_helper() void {}
    \\
    \\pub fn main() void {
    \\    _ = used_helper();
    \\}
    \\
    },
};

test "single file: unused declarations and transitive dead code" {
    var result = try analyze(std.testing.allocator, &test_files, .{});
    defer result.deinit();

    // dead: unused import `std`, unused_fn, dead_calls_dead, dead_helper
    try std.testing.expectEqual(@as(usize, 4), result.findings.len);
    try std.testing.expectEqual(@as(usize, 6), result.summary.decls);
    try std.testing.expectEqual(@as(usize, 2), result.summary.live);
    try std.testing.expectEqual(@as(usize, 4), result.summary.dead);
}

test "test name equal to function name does not shadow references" {
    const files = [_]File{
        .{ .path = "/proj/main.zig", .display_path = "main.zig", .source =
        \\const std = @import("std");
        \\fn trimTrailingNewlines(s: []const u8) []const u8 { return s; }
        \\pub fn main() void {
        \\    _ = trimTrailingNewlines;
        \\}
        \\test "trimTrailingNewlines" {
        \\    try std.testing.expectEqualStrings("foo", trimTrailingNewlines("foo"));
        \\}
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.findings.len);
}

test "container member does not shadow a same-named top-level import" {
    const files = [_]File{
        .{ .path = "/proj/main.zig", .display_path = "main.zig", .source =
        \\const deadcode = @import("h.zig");
        \\const Command = enum { ai, deadcode };
        \\pub fn main() void {
        \\    _ = Command.deadcode;
        \\    _ = Command.ai;
        \\    _ = deadcode.run();
        \\}
        },
        .{ .path = "/proj/h.zig", .display_path = "h.zig", .source =
        \\pub fn run() u8 { return 0; }
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 0), result.findings.len);
}

test "containers: unused fields, variants, methods" {
    const files = [_]File{
        .{ .path = "/proj/c.zig", .display_path = "c.zig", .source =
        \\const S = struct {
        \\    used: i32,
        \\    unused_field: i32,
        \\    fn methodUsed() void {}
        \\    fn methodDead() void {}
        \\};
        \\
        \\const E = enum {
        \\    Red,
        \\    Green,
        \\    Blue,
        \\};
        \\
        \\pub fn main() void {
        \\    const s = S{ .used = 1 };
        \\    _ = s;
        \\    S.methodUsed();
        \\    _ = E.Red;
        \\}
        \\
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();

    // unused_field, methodDead, Green, Blue
    try std.testing.expectEqual(@as(usize, 4), result.findings.len);

    var found_field = false;
    var found_method = false;
    var found_green = false;
    var found_blue = false;
    for (result.findings) |f| {
        if (std.mem.eql(u8, f.name, "unused_field")) found_field = true;
        if (std.mem.eql(u8, f.name, "methodDead")) found_method = true;
        if (std.mem.eql(u8, f.name, "Green")) found_green = true;
        if (std.mem.eql(u8, f.name, "Blue")) found_blue = true;
    }
    try std.testing.expect(found_field);
    try std.testing.expect(found_method);
    try std.testing.expect(found_green);
    try std.testing.expect(found_blue);
}

test "cross-file: alias-qualified references" {
    const files = [_]File{
        .{ .path = "/proj/lib.zig", .display_path = "lib.zig", .source =
        \\pub fn used_from_alias() void {}
        \\fn unused_in_lib() void {}
        \\
        },
        .{ .path = "/proj/main.zig", .display_path = "main.zig", .source =
        \\const lib = @import("lib.zig");
        \\pub fn main() void {
        \\    lib.used_from_alias();
        \\}
        \\
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.findings.len);
    try std.testing.expectEqualStrings("unused_in_lib", result.findings[0].name);
}

test "cross-file: inline @import member access" {
    const files = [_]File{
        .{ .path = "/proj/lib.zig", .display_path = "lib.zig", .source =
        \\pub const helper = struct {
        \\    pub const value: i32 = 7;
        \\};
        \\
        },
        .{ .path = "/proj/main.zig", .display_path = "main.zig", .source =
        \\pub fn main() void {
        \\    _ = @import("lib.zig").helper.value;
        \\}
        \\
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();

    // `helper` is used; `value` is a member used via `.value` (heuristic).
    try std.testing.expectEqual(@as(usize, 0), result.findings.len);
}

test "binary mode: main is the only entry point" {
    const files = [_]File{
        .{ .path = "/proj/main.zig", .display_path = "main.zig", .source =
        \\pub fn helper() void {}
        \\fn main() void {}
        \\
        },
    };
    // Library mode: helper is pub => live, main is private and unused => dead.
    var lib_result = try analyze(std.testing.allocator, &files, .{});
    defer lib_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), lib_result.findings.len);
    try std.testing.expectEqualStrings("main", lib_result.findings[0].name);

    // Binary mode: main is a root, pub helper is still a root (default).
    var bin_result = try analyze(std.testing.allocator, &files, .{ .binary = true });
    defer bin_result.deinit();
    try std.testing.expectEqual(@as(usize, 0), bin_result.findings.len);

    // Binary + include_pub: everything not reachable from main is dead.
    var strict_result = try analyze(std.testing.allocator, &files, .{ .binary = true, .include_pub = true });
    defer strict_result.deinit();
    try std.testing.expectEqual(@as(usize, 1), strict_result.findings.len);
    try std.testing.expectEqualStrings("helper", strict_result.findings[0].name);
}

test "error set members" {
    const files = [_]File{
        .{ .path = "/proj/e.zig", .display_path = "e.zig", .source =
        \\const Errors = error {
        \\    UsedError,
        \\    UnusedError,
        \\};
        \\
        \\pub fn main() void {
        \\    _ = Errors.UsedError;
        \\}
        \\
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.findings.len);
    try std.testing.expectEqualStrings("UnusedError", result.findings[0].name);
}

test "unused files reported in binary mode" {
    const files = [_]File{
        .{ .path = "/proj/main.zig", .display_path = "main.zig", .source =
        \\const helper = @import("helper.zig");
        \\pub fn main() void {
        \\    helper.foo();
        \\}
        \\
        },
        .{ .path = "/proj/helper.zig", .display_path = "helper.zig", .source =
        \\pub fn foo() void {}
        \\
        },
        .{ .path = "/proj/orphan.zig", .display_path = "orphan.zig", .source =
        \\pub fn bar() void {}
        \\
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{ .binary = true });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.unused_files.len);
    try std.testing.expectEqual(@as(usize, 2), result.unused_files[0]);
}

test "test blocks are entry points" {
    const files = [_]File{
        .{ .path = "/proj/t.zig", .display_path = "t.zig", .source =
        \\fn helper() void {}
        \\
        \\test "calls helper" {
        \\    helper();
        \\}
        \\
        \\fn unused() void {}
        \\
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.findings.len);
    try std.testing.expectEqualStrings("unused", result.findings[0].name);
}

test "file-as-container (@This) member references" {
    const files = [_]File{
        .{ .path = "/proj/mod.zig", .display_path = "mod.zig", .source =
        \\const Mod = @This();
        \\
        \\counter: i32 = 0,
        \\
        \\fn usedMethod() void {}
        \\fn deadFn() void {}
        \\
        \\pub fn main() void {
        \\    var m: Mod = .{ .counter = 1 };
        \\    m.usedMethod();
        \\}
        \\
        },
    };
    var result = try analyze(std.testing.allocator, &files, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.findings.len);
    try std.testing.expectEqualStrings("deadFn", result.findings[0].name);
}
