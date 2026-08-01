//! Recursive Zig source file discovery with simple `.gitignore` support.

const std = @import("std");
const Dir = std.Io.Dir;

pub const Options = struct {
    /// Honor `.gitignore` files found during the walk.
    gitignore: bool = true,
};

pub const File = struct {
    /// Canonical absolute path.
    path: []const u8,
    /// Path used in reports, relative to the invocation directory when possible.
    display: []const u8,
};

const Rule = struct {
    pattern: []const u8,
    /// Relative directory (from the scan root) containing the `.gitignore`.
    base: []const u8,
    negated: bool = false,
    dir_only: bool = false,
    anchored: bool = false,
    has_slash: bool = false,
};

pub const Gitignore = struct {
    alloc: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,

    pub fn deinit(self: *Gitignore) void {
        self.rules.deinit(self.alloc);
    }

    pub fn addContent(self: *Gitignore, base_rel: []const u8, content: []const u8) !void {
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var rule = Rule{
                .pattern = line,
                .base = base_rel,
            };
            if (rule.pattern[0] == '!') {
                rule.negated = true;
                rule.pattern = rule.pattern[1..];
                if (rule.pattern.len == 0) continue;
            }
            if (rule.pattern[0] == '/') {
                rule.anchored = true;
                rule.pattern = rule.pattern[1..];
            }
            if (std.mem.endsWith(u8, rule.pattern, "/")) {
                rule.dir_only = true;
                rule.pattern = rule.pattern[0 .. rule.pattern.len - 1];
            }
            if (rule.pattern.len == 0) continue;
            rule.has_slash = std.mem.indexOfScalar(u8, rule.pattern, '/') != null;
            try self.rules.append(self.alloc, rule);
        }
    }

    /// Returns true when `rel_path` is ignored. The last matching rule wins.
    pub fn isIgnored(self: *const Gitignore, rel_path: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.rules.items) |r| {
            if (r.dir_only and !is_dir) continue;
            const rel_from_base = if (r.base.len == 0)
                rel_path
            else
                stripBase(r.base, rel_path) orelse continue;
            const matched = if (!r.anchored and !r.has_slash)
                basenameMatches(r.pattern, rel_path)
            else if (r.anchored and !r.has_slash)
                // `/name` matches the entry `name` relative to the
                // .gitignore's directory (which also ignores its contents).
                globMatch(r.pattern, firstSegment(rel_from_base))
            else
                globMatch(r.pattern, rel_from_base);
            if (matched) ignored = !r.negated;
        }
        return ignored;
    }
};

fn firstSegment(path: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, path, '/') orelse return path;
    return path[0..idx];
}

fn stripBase(base: []const u8, rel_path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rel_path, base)) return null;
    if (rel_path.len == base.len) return "";
    if (rel_path[base.len] == '/') return rel_path[base.len + 1 ..];
    return null;
}

fn basenameMatches(pattern: []const u8, rel_path: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel_path, '/');
    while (it.next()) |segment| {
        if (globMatch(pattern, segment)) return true;
    }
    return false;
}

/// Minimal glob: `*` matches any run of characters (including `/`), `?` one
/// character. `**` is treated like `*`.
pub fn globMatch(pattern: []const u8, s: []const u8) bool {
    if (pattern.len == 0) return s.len == 0;
    switch (pattern[0]) {
        '*' => {
            var i: usize = 1;
            while (i < pattern.len and pattern[i] == '*') i += 1;
            if (i == pattern.len) return true;
            var j: usize = 0;
            while (j <= s.len) : (j += 1) {
                if (globMatch(pattern[i..], s[j..])) return true;
            }
            return false;
        },
        '?' => return s.len > 0 and globMatch(pattern[1..], s[1..]),
        else => return s.len > 0 and pattern[0] == s[0] and globMatch(pattern[1..], s[1..]),
    }
}

const WalkContext = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    root_abs: []const u8,
    out: *std.StringHashMap(File),
    gitignore_enabled: bool,
    ignore: Gitignore,
};

/// Scans `args` (files and/or directories) for `.zig` files. `cwd_path` is the
/// canonical path of the current directory, used to build display paths.
pub fn scan(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    args: []const []const u8,
    options: Options,
) ![]File {
    var out = std.StringHashMap(File).init(alloc);
    defer out.deinit();

    var ctx = WalkContext{
        .alloc = alloc,
        .io = io,
        .cwd_path = cwd_path,
        .root_abs = cwd_path,
        .out = &out,
        .gitignore_enabled = options.gitignore,
        .ignore = .{ .alloc = alloc },
    };
    defer ctx.ignore.deinit();

    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(alloc);

    const targets = if (args.len == 0) &[_][]const u8{"."} else args;
    for (targets) |arg| {
        const abs = std.fs.path.resolve(alloc, &.{ cwd_path, arg }) catch |err| {
            std.debug.print("zdeadcode: cannot resolve {s}: {s}\n", .{ arg, @errorName(err) });
            continue;
        };

        const maybe_dir = Dir.cwd().openDir(io, abs, .{ .iterate = true });
        if (maybe_dir) |dir| {
            defer dir.close(io);
            ctx.root_abs = abs;
            try walkDir(&ctx, dir, "");
        } else |err| {
            if (err == error.NotDir) {
                if (!std.mem.endsWith(u8, abs, ".zig")) continue;
                try addFile(&ctx, abs);
            } else {
                std.debug.print("zdeadcode: cannot open {s}: {s}\n", .{ arg, @errorName(err) });
            }
        }
    }

    // Deterministic output: sort by path.
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(alloc);
    var it = out.keyIterator();
    while (it.next()) |k| try keys.append(alloc, k.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    const files = try alloc.alloc(File, keys.items.len);
    for (keys.items, 0..) |k, i| {
        files[i] = out.get(k).?;
    }
    return files;
}

fn walkDir(ctx: *WalkContext, dir: Dir, rel: []const u8) !void {
    if (ctx.gitignore_enabled and rel.len == 0) {
        // Root-level `.gitignore` only, applied to the whole tree.
        if (readGitignore(ctx, dir, "")) |content| {
            try ctx.ignore.addContent("", content);
        } else |_| {}
    }

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(ctx.io)) |entry| {
        const name = entry.name;
        if (isAlwaysSkipped(name)) continue;
        const full_rel = if (rel.len == 0)
            try ctx.alloc.dupe(u8, name)
        else
            try std.fs.path.join(ctx.alloc, &.{ rel, name });

        switch (entry.kind) {
            .directory => {
                if (ctx.ignore.isIgnored(full_rel, true)) continue;
                const sub = try dir.openDir(ctx.io, name, .{ .iterate = true });
                defer sub.close(ctx.io);
                try walkDir(ctx, sub, full_rel);
            },
            .file => {
                if (!std.mem.endsWith(u8, name, ".zig")) continue;
                if (ctx.ignore.isIgnored(full_rel, false)) continue;
                const abs = try std.fs.path.resolve(ctx.alloc, &.{ ctx.root_abs, full_rel });
                try addFileAt(ctx, abs);
            },
            else => {},
        }
    }
}

fn isAlwaysSkipped(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, ".svn") or
        std.mem.eql(u8, name, ".hg");
}

fn readGitignore(ctx: *WalkContext, dir: Dir, base_rel: []const u8) ![]const u8 {
    _ = base_rel;
    return dir.readFileAlloc(ctx.io, ".gitignore", ctx.alloc, .unlimited);
}

fn addFile(ctx: *WalkContext, abs: []const u8) !void {
    try addFileAt(ctx, abs);
}

fn addFileAt(ctx: *WalkContext, abs: []const u8) !void {
    if (ctx.out.contains(abs)) return;
    const display = displayPath(ctx.alloc, ctx.cwd_path, abs) catch abs;
    try ctx.out.put(abs, .{ .path = abs, .display = display });
}

fn displayPath(alloc: std.mem.Allocator, cwd_path: []const u8, abs: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, abs, cwd_path)) {
        const rest = abs[cwd_path.len..];
        if (rest.len > 0 and rest[0] == '/') return alloc.dupe(u8, rest[1..]);
    }
    return alloc.dupe(u8, abs);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "glob matching" {
    try std.testing.expect(globMatch("*.zig", "main.zig"));
    try std.testing.expect(!globMatch("*.zig", "main.txt"));
    try std.testing.expect(globMatch("foo/*", "foo/bar"));
    try std.testing.expect(globMatch("a?c", "abc"));
    try std.testing.expect(!globMatch("a?c", "abbc"));
    try std.testing.expect(globMatch("*", "anything/at/all"));
    try std.testing.expect(globMatch("", ""));
}

test "gitignore basics" {
    var ignore = Gitignore{ .alloc = std.testing.allocator };
    defer ignore.deinit();
    try ignore.addContent("", "zig-out/\n*.txt\n!keep.txt\n/build\n");

    try std.testing.expect(ignore.isIgnored("zig-out/bin/app", true));
    try std.testing.expect(ignore.isIgnored("foo.txt", false));
    try std.testing.expect(!ignore.isIgnored("keep.txt", false));
    try std.testing.expect(!ignore.isIgnored("sub/keep.txt", false)); // negation applies at any level; last rule wins
    try std.testing.expect(ignore.isIgnored("build/x", true));
}

test "gitignore negation with base directory" {
    var ignore = Gitignore{ .alloc = std.testing.allocator };
    defer ignore.deinit();
    try ignore.addContent("sub", "ignored.zig\n!keep.zig\n");

    try std.testing.expect(ignore.isIgnored("sub/ignored.zig", false));
    try std.testing.expect(!ignore.isIgnored("sub/keep.zig", false));
    try std.testing.expect(!ignore.isIgnored("other/ignored.zig", false));
}
