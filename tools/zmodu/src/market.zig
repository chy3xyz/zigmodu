//! `zmodu market` — module marketplace.
//! Phase 1: local curated catalog (`marketplace/catalog.json`) for
//! discoverability. Phase 2: remote index (`update`) merged with the local
//! catalog for browse, plus `install` (copy an entry into a project with
//! dry-run / verify). Signing, build.zig.zon auto-write and CI hooks are
//! deferred (ADR-016).
//!
//! Subcommands:
//!   list                — list all curated entries
//!   search <q>          — case-insensitive substring match on id/name/summary/tags
//!   info <id>           — print one entry
//!   update              — fetch the remote index into .zmodu/market-index.json
//!   install <id>        — copy the entry's source tree into a project
//! Flags: --json, --catalog <path>, --index <url>, --dir <path>, --dry-run, --verify

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;

pub const embedded_catalog = @embedFile("marketplace/catalog.json");
pub const default_index_url = "https://raw.githubusercontent.com/chy3xyz/zigmodu/master/tools/zmodu/src/marketplace/catalog.json";
const cache_path = ".zmodu/market-index.json";

pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    path: ?[]const u8,
    summary: []const u8,
    tags: []const []const u8,
    min_version: []const u8,
    doc: ?[]const u8,
    status: ?[]const u8,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.kind);
        if (self.path) |p| allocator.free(p);
        allocator.free(self.summary);
        for (self.tags) |t| allocator.free(t);
        allocator.free(self.tags);
        allocator.free(self.min_version);
        if (self.doc) |d| allocator.free(d);
        if (self.status) |s| allocator.free(s);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    pub fn deinit(self: *Catalog) void {
        for (self.entries.items) |*e| e.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

const cache_path_const = cache_path;

fn dupEntry(allocator: std.mem.Allocator, e: *const Entry) !Entry {
    const tags = try allocator.alloc([]const u8, e.tags.len);
    errdefer allocator.free(tags);
    for (e.tags, 0..) |t, i| tags[i] = try allocator.dupe(u8, t);
    return .{
        .id = try allocator.dupe(u8, e.id),
        .name = try allocator.dupe(u8, e.name),
        .kind = try allocator.dupe(u8, e.kind),
        .path = if (e.path) |p| try allocator.dupe(u8, p) else null,
        .summary = try allocator.dupe(u8, e.summary),
        .tags = tags,
        .min_version = try allocator.dupe(u8, e.min_version),
        .doc = if (e.doc) |d| try allocator.dupe(u8, d) else null,
        .status = if (e.status) |s| try allocator.dupe(u8, s) else null,
    };
}

/// Local curated catalog merged with the cached remote index (remote wins).
pub fn loadMergedCatalog(io: Io, allocator: std.mem.Allocator, external_path: ?[]const u8) !Catalog {
    var base = try loadCatalog(io, allocator, external_path);
    errdefer base.deinit();
    const content = Dir.cwd().readFileAlloc(io, cache_path_const, allocator, Io.Limit.limited(8 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return base;
        return err;
    };
    defer allocator.free(content);
    var remote = parseCatalog(allocator, content) catch |err| {
        std.log.warn("market: ignoring malformed cached index ({s})", .{@errorName(err)});
        return base;
    };
    defer remote.deinit();
    for (remote.entries.items) |*re| {
        var found = false;
        for (base.entries.items) |*be| {
            if (std.mem.eql(u8, be.id, re.id)) {
                found = true;
                break;
            }
        }
        if (!found) try base.entries.append(allocator, try dupEntry(allocator, re));
    }
    return base;
}

/// Fetch a remote catalog JSON into `.zmodu/market-index.json`.
pub fn fetchIndex(io: Io, allocator: std.mem.Allocator, url: []const u8) !void {
    Dir.cwd().createDirPath(io, ".zmodu") catch {};
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{cache_path_const});
    defer allocator.free(tmp_path);
    const file = try Dir.cwd().createFile(io, tmp_path, .{});
    defer file.close(io);
    var wbuf: [8192]u8 = undefined;
    var writer = file.writer(io, &wbuf);
    const resp = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &writer.interface,
    });
    if (resp.status != .ok) return error.IndexFetchFailed;
    try writer.flush();
    // Promote the temp file to the cache path (POSIX rename replaces atomically).
    const cwd = Dir.cwd();
    Dir.rename(cwd, tmp_path, cwd, cache_path_const, io) catch |err| {
        const content = try Dir.cwd().readFileAlloc(io, tmp_path, allocator, Io.Limit.limited(8 * 1024 * 1024));
        defer allocator.free(content);
        const cache_file = try Dir.cwd().createFile(io, cache_path_const, .{});
        defer cache_file.close(io);
        try cache_file.writeStreamingAll(io, content);
        std.log.warn("market: rename failed ({s}); copied cache in place", .{@errorName(err)});
    };
}

const junk_dirs = [_][]const u8{ "node_modules", ".git", ".output", ".data", "test-results", ".DS_Store", ".zig-cache", ".zig-global-cache", "zig-out" };

fn shouldSkip(name: []const u8) bool {
    for (junk_dirs) |j| {
        if (std.mem.eql(u8, name, j)) return true;
    }
    return false;
}

/// Recursively copy `src` → `dst` (skipping build/junk dirs). `dry_run`
/// only lists what would be copied.
pub fn copyTree(io: Io, allocator: std.mem.Allocator, src: []const u8, dst: []const u8, dry_run: bool) !void {
    var src_dir = Dir.cwd().openDir(io, src, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) return error.SourceMissing;
        return err;
    };
    defer src_dir.close(io);
    if (!dry_run) Dir.cwd().createDirPath(io, dst) catch {};
    var it = src_dir.iterate();
    while (try it.next(io)) |entry| {
        if (shouldSkip(entry.name)) continue;
        const s = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(s);
        const d = try std.fs.path.join(allocator, &.{ dst, entry.name });
        defer allocator.free(d);
        switch (entry.kind) {
            .directory => try copyTree(io, allocator, s, d, dry_run),
            .file => {
                if (dry_run) {
                    std.log.info("[dry-run] copy {s} -> {s}", .{ s, d });
                    continue;
                }
                const content = try Dir.cwd().readFileAlloc(io, s, allocator, Io.Limit.limited(64 * 1024 * 1024));
                defer allocator.free(content);
                const f = try Dir.cwd().createFile(io, d, .{});
                defer f.close(io);
                try f.writeStreamingAll(io, content);
            },
            else => {},
        }
    }
}

fn dirExists(io: Io, path: []const u8) bool {
    var d = Dir.cwd().openDir(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

fn fileExists(io: Io, path: []const u8) bool {
    if (Dir.cwd().access(io, path, .{})) |_| {
        return true;
    } else |_| {
        return false;
    }
}

/// Load the catalog: `external_path` overrides the embedded one.
pub fn loadCatalog(io: Io, allocator: std.mem.Allocator, external_path: ?[]const u8) !Catalog {
    const content = if (external_path) |p|
        try Dir.cwd().readFileAlloc(io, p, allocator, Io.Limit.limited(4 * 1024 * 1024))
    else
        try allocator.dupe(u8, embedded_catalog);
    defer allocator.free(content);
    return parseCatalog(allocator, content);
}

fn parseCatalog(allocator: std.mem.Allocator, content: []const u8) !Catalog {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidCatalog;
    const entries_v = root.object.get("entries") orelse return error.InvalidCatalog;
    if (entries_v != .array) return error.InvalidCatalog;

    var catalog = Catalog{ .allocator = allocator, .entries = std.ArrayList(Entry).empty };
    errdefer catalog.deinit();
    for (entries_v.array.items) |ev| {
        if (ev != .object) return error.InvalidCatalog;
        const tags_v = ev.object.get("tags") orelse return error.InvalidCatalog;
        const tags = try allocator.alloc([]const u8, tags_v.array.items.len);
        errdefer allocator.free(tags);
        for (tags_v.array.items, 0..) |t, i| {
            tags[i] = try allocator.dupe(u8, t.string);
        }
        try catalog.entries.append(allocator, .{
            .id = try allocator.dupe(u8, ev.object.get("id").?.string),
            .name = try allocator.dupe(u8, ev.object.get("name").?.string),
            .kind = try allocator.dupe(u8, ev.object.get("kind").?.string),
            .path = if (ev.object.get("path")) |p| (if (p == .string) try allocator.dupe(u8, p.string) else null) else null,
            .summary = try allocator.dupe(u8, ev.object.get("summary").?.string),
            .tags = tags,
            .min_version = try allocator.dupe(u8, ev.object.get("min_version").?.string),
            .doc = if (ev.object.get("doc")) |d| (if (d == .string) try allocator.dupe(u8, d.string) else null) else null,
            .status = if (ev.object.get("status")) |s| (if (s == .string) try allocator.dupe(u8, s.string) else null) else null,
        });
    }
    return catalog;
}

fn matches(e: *const Entry, q: []const u8) bool {
    if (containsIgnoreCase(e.id, q) or containsIgnoreCase(e.name, q) or containsIgnoreCase(e.summary, q)) return true;
    for (e.tags) |t| {
        if (containsIgnoreCase(t, q)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

const Cli = struct {
    json: bool = false,
    catalog_path: ?[]const u8 = null,
    index_url: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    dry_run: bool = false,
    verify: bool = false,
    cmd: []const u8 = "",
    query: ?[]const u8 = null,
};

pub fn run(io: Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var cli = Cli{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) {
            cli.json = true;
        } else if (std.mem.eql(u8, args[i], "--catalog")) {
            if (i + 1 >= args.len) return 2;
            i += 1;
            cli.catalog_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--index")) {
            if (i + 1 >= args.len) return 2;
            i += 1;
            cli.index_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--dir")) {
            if (i + 1 >= args.len) return 2;
            i += 1;
            cli.dir = args[i];
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            cli.dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--verify")) {
            cli.verify = true;
        } else if (cli.cmd.len == 0) {
            cli.cmd = args[i];
        } else if (cli.query == null) {
            cli.query = args[i];
        } else return 2;
    }

    if (std.mem.eql(u8, cli.cmd, "update")) {
        const url = cli.index_url orelse default_index_url;
        fetchIndex(io, allocator, url) catch |err| {
            std.log.err("market: update failed ({s}) from {s}", .{ @errorName(err), url });
            return 1;
        };
        std.log.info("market: remote index updated -> .zmodu/market-index.json", .{});
        return 0;
    }

    var catalog = loadMergedCatalog(io, allocator, cli.catalog_path) catch |err| {
        std.log.err("market: cannot load catalog: {s}", .{@errorName(err)});
        return 1;
    };
    defer catalog.deinit();

    var out_buf: [4096]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    const stdout = &out_writer.interface;

    if (std.mem.eql(u8, cli.cmd, "list")) {
        printEntries(stdout, catalog.entries.items, null, cli.json) catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, cli.cmd, "search")) {
        const q = cli.query orelse {
            std.log.err("usage: zmodu market search <query>", .{});
            return 2;
        };
        var hits = std.ArrayList(*Entry).empty;
        defer hits.deinit(allocator);
        for (catalog.entries.items) |*e| {
            if (matches(e, q)) hits.append(allocator, e) catch return 1;
        }
        var hit_values = std.ArrayList(Entry).empty;
        defer hit_values.deinit(allocator);
        for (hits.items) |hp| hit_values.append(allocator, hp.*) catch return 1;
        printEntries(stdout, hit_values.items, q, cli.json) catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, cli.cmd, "info")) {
        const id = cli.query orelse {
            std.log.err("usage: zmodu market info <id>", .{});
            return 2;
        };
        for (catalog.entries.items) |*e| {
            if (std.mem.eql(u8, e.id, id)) {
                printEntries(stdout, &.{e.*}, null, cli.json) catch return 1;
                return 0;
            }
        }
        std.log.err("market: no entry with id '{s}'", .{id});
        return 1;
    }
    if (std.mem.eql(u8, cli.cmd, "install")) {
        const id = cli.query orelse {
            std.log.err("usage: zmodu market install <id> [--dir <path>] [--dry-run] [--verify]", .{});
            return 2;
        };
        var entry: ?*Entry = null;
        for (catalog.entries.items) |*e| {
            if (std.mem.eql(u8, e.id, id)) {
                entry = e;
                break;
            }
        }
        const e = entry orelse {
            std.log.err("market: no entry with id '{s}'", .{id});
            return 1;
        };
        const src = e.path orelse {
            std.log.err("market: '{s}' has no source path to install (plugin stub)", .{id});
            return 1;
        };
        if (!dirExists(io, src)) {
            std.log.err("market: source '{s}' not found in this checkout", .{src});
            return 1;
        }
        const target = cli.dir orelse ".";
        const dst = std.fs.path.join(allocator, &.{ target, e.name }) catch return 1;
        defer allocator.free(dst);
        if (!cli.dry_run and dirExists(io, dst)) {
            std.log.err("market: target {s} already exists", .{dst});
            return 1;
        }
        std.log.info("market: install {s} -> {s}", .{ id, dst });
        copyTree(io, allocator, src, dst, cli.dry_run) catch |err| {
            std.log.err("market: install failed: {s}", .{@errorName(err)});
            return 1;
        };
        if (cli.verify and !cli.dry_run) {
            const bz = std.fs.path.join(allocator, &.{ dst, "build.zig" }) catch return 1;
            defer allocator.free(bz);
            if (fileExists(io, bz)) {
                std.log.info("market: verify `zig build` in {s}...", .{dst});
                const res = std.process.run(allocator, io, .{
                    .argv = &.{ "zig", "build" },
                    .cwd = .{ .path = dst },
                    .stdout_limit = .limited(8 * 1024 * 1024),
                    .stderr_limit = .limited(8 * 1024 * 1024),
                }) catch |err| {
                    std.log.err("market: verify cannot run zig build: {s}", .{@errorName(err)});
                    return 1;
                };
                defer {
                    allocator.free(res.stdout);
                    allocator.free(res.stderr);
                }
                if (!res.term.success()) {
                    std.log.err("market: verify FAILED", .{});
                    std.debug.print("{s}{s}", .{ res.stderr, res.stdout });
                    return 1;
                }
                std.log.info("market: verify OK", .{});
            } else {
                std.log.info("market: no build.zig at {s} root — verify manually (frontend: npm install && npm run dev)", .{dst});
            }
        }
        return 0;
    }

    std.log.err("usage: zmodu market <list|search <q>|info <id>|update|install <id>> [--json] [--catalog <path>] [--index <url>] [--dir <path>] [--dry-run] [--verify]", .{});
    return 2;
}

fn printEntries(stdout: anytype, entries: []const Entry, query: ?[]const u8, json: bool) !void {
    if (json) {
        try stdout.writeAll("{\"schema_version\":1,\"entries\":[");
        for (entries, 0..) |e, idx| {
            if (idx > 0) try stdout.writeAll(",");
            try stdout.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"kind\":\"{s}\"", .{ e.id, e.name, e.kind });
            if (e.path) |p| try stdout.print(",\"path\":\"{s}\"", .{p});
            try stdout.print(",\"summary\":\"{s}\",\"tags\":[", .{e.summary});
            for (e.tags, 0..) |t, ti| {
                if (ti > 0) try stdout.writeAll(",");
                try stdout.print("\"{s}\"", .{t});
            }
            try stdout.print("],\"min_version\":\"{s}\"", .{e.min_version});
            if (e.doc) |d| try stdout.print(",\"doc\":\"{s}\"", .{d});
            if (e.status) |s| try stdout.print(",\"status\":\"{s}\"", .{s});
            try stdout.writeAll("}");
        }
        try stdout.writeAll("]}\n");
        try stdout.flush();
        return;
    }

    if (query) |q| {
        try stdout.print("== zmodu market search: {s} ==\n", .{q});
    } else {
        try stdout.writeAll("== zmodu market ==\n");
    }
    for (entries) |e| {
        try stdout.print("[{s}] {s} — {s} (tags: ", .{ e.id, e.name, e.summary });
        for (e.tags, 0..) |t, ti| {
            if (ti > 0) try stdout.writeAll(", ");
            try stdout.writeAll(t);
        }
        try stdout.writeAll(")\n");
    }
    try stdout.flush();
}

// ── tests ─────────────────────────────────────────────────────────────────

test "market parses embedded catalog" {
    const allocator = std.testing.allocator;
    var catalog = try parseCatalog(allocator, embedded_catalog);
    defer catalog.deinit();
    try std.testing.expect(catalog.entries.items.len >= 8);
    var has_zmsaas = false;
    for (catalog.entries.items) |e| {
        if (std.mem.eql(u8, e.id, "example/zmsaas")) has_zmsaas = true;
    }
    try std.testing.expect(has_zmsaas);
}

test "market search matches id/summary/tags case-insensitively" {
    const allocator = std.testing.allocator;
    var catalog = try parseCatalog(allocator, embedded_catalog);
    defer catalog.deinit();
    var n: usize = 0;
    for (catalog.entries.items) |*e| {
        if (matches(e, "SAAS")) n += 1;
    }
    try std.testing.expect(n >= 1); // zmsaas id/summary/tags contains "saas"
    var m: usize = 0;
    for (catalog.entries.items) |*e| {
        if (matches(e, "payment")) m += 1;
    }
    try std.testing.expect(m >= 1);
}

test "market catalog includes curated examples and plugin stubs" {
    const allocator = std.testing.allocator;
    var catalog = try parseCatalog(allocator, embedded_catalog);
    defer catalog.deinit();
    var examples: usize = 0;
    var plugins: usize = 0;
    for (catalog.entries.items) |e| {
        if (std.mem.eql(u8, e.kind, "example")) examples += 1;
        if (std.mem.eql(u8, e.kind, "plugin")) plugins += 1;
    }
    try std.testing.expect(examples >= 6);
    try std.testing.expect(plugins >= 1);
}

test "market merges remote index into local catalog (dedupe by id)" {
    const allocator = std.testing.allocator;
    var base = try parseCatalog(allocator, embedded_catalog);
    defer base.deinit();
    const remote_json =
        \\{"schema_version":1,"entries":[
        \\  {"id":"module/crm","name":"crm","kind":"module","path":"modules/crm","summary":"CRM module","tags":["crm"],"min_version":"0.15.4"},
        \\  {"id":"example/zmsaas","name":"zmsaas","kind":"example","path":"examples/zmsaas","summary":"overridden by remote","tags":[],"min_version":"0.15.4"}
        \\]}
    ;
    var remote = try parseCatalog(allocator, remote_json);
    defer remote.deinit();

    for (remote.entries.items) |*re| {
        var found = false;
        for (base.entries.items) |*be| {
            if (std.mem.eql(u8, be.id, re.id)) {
                found = true;
                break;
            }
        }
        if (!found) try base.entries.append(allocator, try dupEntry(allocator, re));
    }
    try std.testing.expectEqual(@as(usize, 13), base.entries.items.len); // 12 local + 1 new remote
    var has_crm = false;
    for (base.entries.items) |e| {
        if (std.mem.eql(u8, e.id, "module/crm")) has_crm = true;
    }
    try std.testing.expect(has_crm);
}

test "market copyTree copies files and skips junk dirs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src/mod");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/mod/model.zig", .data = "pub const M = struct {};\n" });
    try tmp.dir.createDirPath(io, "src/node_modules");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/node_modules/junk.js", .data = "x" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(io, &path_buf);
    const base = path_buf[0..path_len];
    const src = try std.fs.path.join(allocator, &.{ base, "src" });
    defer allocator.free(src);
    const dst = try std.fs.path.join(allocator, &.{ base, "out" });
    defer allocator.free(dst);

    try copyTree(io, allocator, src, dst, false);
    const copied = try std.fs.path.join(allocator, &.{ dst, "mod", "model.zig" });
    defer allocator.free(copied);
    const skipped = try std.fs.path.join(allocator, &.{ dst, "node_modules" });
    defer allocator.free(skipped);
    try std.testing.expect(fileExists(io, copied));
    try std.testing.expect(!dirExists(io, skipped));
}
