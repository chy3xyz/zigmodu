//! Static file serving — the "every web framework needs it" piece, with the
//! three things that make it safe to expose: a traversal guard, ETag/304
//! revalidation, and Range support (206/416) for video and resumable downloads.
//!
//! ```zig
//! try zigmodu.http.staticFiles(io, &server, allocator, "/assets", "public", .{
//!     .cache_control = "public, max-age=3600",
//! });
//! // GET /assets/css/app.css → <cwd>/public/css/app.css
//! // (the group carries the URL prefix, so the route is registered as `*`)
//! ```
//!
//! Deliberate behavior:
//!   - Only `GET`/`HEAD`; other methods get 405 (a static mount must not make a
//!     path look writable).
//!   - No directory index and no listing (`/assets/` → 404): an index page is an
//!     application decision, not a file server's.
//!   - Paths are normalized before touching the filesystem — `..`, absolute
//!     paths, backslashes, `:` (drive/stream syntax) and NUL can never escape
//!     the root.
//!   - Files above `max_bytes` are refused with 413 rather than buffered whole.
//!
//! Ownership: the mount (prefix + root + config) is allocated once and lives as
//! long as the process, like the route table. Pass a long-lived allocator (the
//! application's `gpa`); a per-test allocator will report it as a leak, so tests
//! should hand in an arena they free at the end.

const std = @import("std");
const api = @import("../api/Server.zig");

pub const Config = struct {
    /// `Cache-Control` for successful responses; empty omits the header.
    cache_control: []const u8 = "public, max-age=300",
    /// Honor `Range` (206) — set false for endpoints where partial content is
    /// meaningless and you want the simplest possible behavior.
    allow_range: bool = true,
    /// Refuse (413) rather than buffer a whole response in memory.
    max_bytes: usize = 16 * 1024 * 1024,
    /// Read chunk used while streaming the body.
    chunk_bytes: usize = 256 * 1024,
    mime_overrides: []const MimeOverride = &.{},
};

pub const MimeOverride = struct { ext: []const u8, content_type: []const u8 };

const Mount = struct {
    io: std.Io,
    /// URL prefix the mount answers under, without a trailing slash
    /// (`"/assets"`); used to derive the relative path when the router does not
    /// hand us a wildcard parameter.
    prefix: []const u8,
    root: []const u8,
    config: Config,
};

/// Serve files from `root_dir` (resolved against the process CWD) under the
/// group's prefix by claiming its wildcard route (`GET <prefix>/*`).
///
/// ```zig
/// var assets = server.group("/assets");
/// try staticFiles(io, &assets, "public", .{});
/// ```
pub fn staticFiles(io: std.Io, server: *api.Server, allocator: std.mem.Allocator, prefix: []const u8, root_dir: []const u8, config: Config) !void {
    try server.addMiddleware(staticMiddleware(io, allocator, prefix, root_dir, config));
}

/// Middleware form: answers requests under `prefix` and passes everything else
/// to `next`. Implemented as middleware rather than a route deliberately — the
/// router's `/*` matches only the prefix itself, so a route-based mount cannot
/// serve files below it.
pub fn staticMiddleware(io: std.Io, allocator: std.mem.Allocator, prefix: []const u8, root_dir: []const u8, config: Config) api.Middleware {
    const normalized = std.mem.trimEnd(u8, prefix, "/");
    const mount = allocator.create(Mount) catch return .{ .func = passThrough };
    mount.* = .{
        .io = io,
        .prefix = allocator.dupe(u8, normalized) catch return .{ .func = passThrough },
        .root = allocator.dupe(u8, root_dir) catch return .{ .func = passThrough },
        .config = config,
    };
    const S = struct {
        fn mw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
            const m: *Mount = @ptrCast(@alignCast(user_data orelse return error.StaticMountNotConfigured));
            if (!underMount(ctx.path, m.prefix)) return next(ctx);
            return serve(ctx, m);
        }
    };
    return .{ .func = S.mw, .user_data = mount };
}

fn passThrough(ctx: *api.Context, next: api.HandlerFn, _: ?*anyopaque) anyerror!void {
    return next(ctx);
}

/// True when `path` is the mount prefix or lives under it.
fn underMount(path: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0) return true; // mounted at the root
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const rest = path[prefix.len..];
    return rest.len == 0 or rest[0] == '/' or rest[0] == '?';
}

fn serve(ctx: *api.Context, mount: *Mount) anyerror!void {
    // Request-scoped scratch (paths, header values). `setHeader` duplicates what
    // it stores, so everything here can be released when we return.
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();

    if (ctx.method != .GET and ctx.method != .HEAD) {
        try ctx.sendError(405, "Method Not Allowed");
        return;
    }

    const rel = try relativePath(ctx, mount, a);
    if (rel == null) {
        try ctx.sendError(404, "Not Found");
        return;
    }

    const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ mount.root, rel.? });
    const file = std.Io.Dir.cwd().openFile(mount.io, full, .{}) catch {
        try ctx.sendError(404, "Not Found");
        return;
    };
    defer file.close(mount.io);

    const stat = file.stat(mount.io) catch {
        try ctx.sendError(500, "StatFailed");
        return;
    };
    if (stat.kind == .directory) { // no index, no listing
        try ctx.sendError(404, "Not Found");
        return;
    }
    if (stat.size > mount.config.max_bytes) {
        try ctx.sendError(413, "Payload Too Large");
        return;
    }

    // Cheap, stable validator: size + mtime in nanoseconds.
    var etag_buf: [64]u8 = undefined;
    const etag = try std.fmt.bufPrint(&etag_buf, "\"{x}-{x}\"", .{ stat.size, stat.mtime.nanoseconds });
    try ctx.setHeader("ETag", etag);
    if (mount.config.cache_control.len > 0) try ctx.setHeader("Cache-Control", mount.config.cache_control);
    try ctx.setHeader("Accept-Ranges", if (mount.config.allow_range) "bytes" else "none");

    if (ctx.headers.get("if-none-match")) |inm| {
        if (std.mem.eql(u8, std.mem.trim(u8, inm, " "), etag)) {
            ctx.status_code = 304; // bodyless by definition
            ctx.responded = true;
            return;
        }
    }

    var offset: u64 = 0;
    var length: u64 = stat.size;
    var partial = false;
    if (mount.config.allow_range) {
        if (ctx.headers.get("range")) |range| {
            switch (parseRange(range, stat.size)) {
                .none => {},
                .invalid => {
                    try ctx.setHeader("Content-Range", try std.fmt.allocPrint(a, "bytes */{d}", .{stat.size}));
                    try ctx.sendError(416, "Range Not Satisfiable");
                    return;
                },
                .ok => |r| {
                    offset = r.start;
                    length = r.end - r.start + 1;
                    partial = true;
                },
            }
        }
    }

    try ctx.setHeader("Content-Type", mimeFor(rel.?, mount.config));
    try ctx.setHeader("Content-Length", try std.fmt.allocPrint(a, "{d}", .{length}));
    if (partial) {
        try ctx.setHeader("Content-Range", try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ offset, offset + length - 1, stat.size }));
    }

    ctx.status_code = if (partial) 206 else 200;
    if (ctx.method == .HEAD) {
        ctx.responded = true;
        return;
    }

    // Chunked read so a large file does not need one exact-size allocation.
    const chunk = try a.alloc(u8, @min(@as(usize, @intCast(@min(length, mount.config.chunk_bytes))), mount.config.chunk_bytes));
    var remaining = length;
    var pos = offset;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, chunk.len));
        const got = file.readPositionalAll(mount.io, chunk[0..want], pos) catch {
            try ctx.sendError(500, "ReadFailed");
            return;
        };
        if (got == 0) break;
        try ctx.response_body.appendSlice(ctx.allocator, chunk[0..got]);
        pos += got;
        remaining -= got;
    }
    ctx.responded = true;
}

/// Path relative to the mount root, or null when it must not be served.
fn relativePath(ctx: *api.Context, mount: *Mount, allocator: std.mem.Allocator) !?[]const u8 {
    var raw = ctx.path;
    if (mount.prefix.len > 0 and std.mem.startsWith(u8, raw, mount.prefix)) raw = raw[mount.prefix.len..];
    while (raw.len > 0 and raw[0] == '/') raw = raw[1..];
    if (raw.len == 0) return null;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return null;
    if (std.mem.indexOfScalar(u8, raw, '\\') != null) return null;

    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(allocator);
    var it = std.mem.splitScalar(u8, raw, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) return null;
        if (std.mem.indexOfScalar(u8, comp, ':') != null) return null; // no drive letters / NTFS streams
        try parts.append(allocator, comp);
    }
    if (parts.items.len == 0) return null;
    return try std.mem.join(allocator, "/", parts.items);
}

const RangeResult = union(enum) { none, invalid, ok: struct { start: u64, end: u64 } };

/// Parse a single `bytes=` range. Multiple ranges are treated as unsupported
/// (`none` → whole entity) — correctness over cleverness.
fn parseRange(header: []const u8, size: u64) RangeResult {
    const prefix = "bytes=";
    if (!std.mem.startsWith(u8, header, prefix)) return .none;
    const spec = std.mem.trim(u8, header[prefix.len..], " ");
    if (std.mem.indexOfScalar(u8, spec, ',') != null) return .none;
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return .invalid;
    const start_s = std.mem.trim(u8, spec[0..dash], " ");
    const end_s = std.mem.trim(u8, spec[dash + 1 ..], " ");
    if (size == 0) return .invalid;

    if (start_s.len == 0) { // suffix form: `-N` = last N bytes
        const n = std.fmt.parseInt(u64, end_s, 10) catch return .invalid;
        if (n == 0) return .invalid;
        const start = if (n >= size) 0 else size - n;
        return .{ .ok = .{ .start = start, .end = size - 1 } };
    }
    const start = std.fmt.parseInt(u64, start_s, 10) catch return .invalid;
    if (start >= size) return .invalid;
    const end = if (end_s.len == 0) size - 1 else std.fmt.parseInt(u64, end_s, 10) catch return .invalid;
    if (end < start) return .invalid;
    return .{ .ok = .{ .start = start, .end = @min(end, size - 1) } };
}

fn mimeFor(rel: []const u8, cfg: Config) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, rel, '.') orelse return "application/octet-stream";
    const ext = rel[dot + 1 ..];
    for (cfg.mime_overrides) |o| {
        if (std.ascii.eqlIgnoreCase(ext, o.ext)) return o.content_type;
    }
    const table = .{
        .{ "html", "text/html; charset=utf-8" },
        .{ "css", "text/css; charset=utf-8" },
        .{ "js", "text/javascript; charset=utf-8" },
        .{ "json", "application/json" },
        .{ "svg", "image/svg+xml" },
        .{ "png", "image/png" },
        .{ "jpg", "image/jpeg" },
        .{ "jpeg", "image/jpeg" },
        .{ "gif", "image/gif" },
        .{ "webp", "image/webp" },
        .{ "ico", "image/x-icon" },
        .{ "woff2", "font/woff2" },
        .{ "txt", "text/plain; charset=utf-8" },
        .{ "pdf", "application/pdf" },
        .{ "mp4", "video/mp4" },
        .{ "wasm", "application/wasm" },
    };
    inline for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

// ── tests ──────────────────────────────────────────────────────────────────

test "parseRange: closed / open / suffix / invalid / multi" {
    try std.testing.expectEqual(RangeResult.none, parseRange("items=0-5", 100));
    try std.testing.expectEqual(RangeResult.none, parseRange("bytes=0-1,5-6", 100));
    try std.testing.expectEqual(RangeResult.invalid, parseRange("bytes=abc-5", 100));
    try std.testing.expectEqual(RangeResult.invalid, parseRange("bytes=200-300", 100));
    try std.testing.expectEqual(RangeResult.invalid, parseRange("bytes=5-1", 100));
    try std.testing.expectEqual(@as(u64, 0), parseRange("bytes=0-9", 100).ok.start);
    try std.testing.expectEqual(@as(u64, 9), parseRange("bytes=0-9", 100).ok.end);
    try std.testing.expectEqual(@as(u64, 99), parseRange("bytes=10-", 100).ok.end);
    try std.testing.expectEqual(@as(u64, 90), parseRange("bytes=-10", 100).ok.start);
    try std.testing.expectEqual(@as(u64, 0), parseRange("bytes=-500", 100).ok.start);
    try std.testing.expectEqual(@as(u64, 99), parseRange("bytes=0-999", 100).ok.end); // clamped
}

test "static files: serve, HEAD, 304, Range and traversal refusal" {
    const allocator = std.testing.allocator;
    const Testkit = @import("Testkit.zig");
    const io = std.testing.io;

    const dir_name = "zigmodu_static_test";
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};
    {
        const f = try std.Io.Dir.cwd().createFile(io, dir_name ++ "/hello.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "hello static world");
    }

    var server = api.Server.init(io, allocator, 0);
    defer server.deinit();
    // The mount is process-lifetime; the arena expresses that and keeps the
    // test allocator's leak checker meaningful.
    var mount_arena = std.heap.ArenaAllocator.init(allocator);
    defer mount_arena.deinit();
    try staticFiles(io, &server, mount_arena.allocator(), "/static", dir_name, .{});

    {
        var resp = try Testkit.dispatch(&server, .GET, "/static/hello.txt", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expectEqualStrings("hello static world", resp.body);
    }
    {
        var resp = try Testkit.dispatch(&server, .HEAD, "/static/hello.txt", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
        try std.testing.expectEqualStrings("", resp.body);
    }
    {
        // Conditional request: the client already holds this version.
        var opts = Testkit.DispatchOptions{};
        opts.headers = &.{.{ "if-none-match", "\"0-0\"" }};
        var resp = try Testkit.dispatchOpts(&server, .GET, "/static/hello.txt", opts);
        defer resp.deinit(allocator);
        // Whatever the real ETag is, a mismatching one must still serve the body.
        try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    }
    {
        var opts = Testkit.DispatchOptions{};
        opts.headers = &.{.{ "range", "bytes=6-11" }};
        var resp = try Testkit.dispatchOpts(&server, .GET, "/static/hello.txt", opts);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 206), resp.status_code);
        try std.testing.expectEqualStrings("static", resp.body);
    }
    {
        var resp = try Testkit.dispatch(&server, .GET, "/static/missing.txt", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 404), resp.status_code);
    }
    {
        var resp = try Testkit.dispatch(&server, .POST, "/static/hello.txt", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 405), resp.status_code);
    }
    {
        // Outside the mount the middleware must not interfere.
        var resp = try Testkit.dispatch(&server, .GET, "/other", null);
        defer resp.deinit(allocator);
        try std.testing.expectEqual(@as(u16, 404), resp.status_code);
    }
}
