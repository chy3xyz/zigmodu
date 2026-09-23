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
//!   - Bodies above `chunk_bytes` are streamed chunked straight from the file
//!     (peak memory per request stays one read chunk); smaller ones are written
//!     in one go, so their `Content-Length` is unchanged.
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
    /// Read chunk used while streaming the body, and the size at which a body
    /// stops being buffered: anything longer is streamed chunked, so this is also
    /// the per-request memory bound of the buffering path.
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

    const content_type = mimeFor(rel.?, mount.config);
    try ctx.setHeader("Content-Type", content_type);
    if (partial) {
        try ctx.setHeader("Content-Range", try std.fmt.allocPrint(a, "bytes {d}-{d}/{d}", .{ offset, offset + length - 1, stat.size }));
    }

    ctx.status_code = if (partial) 206 else 200;

    // Bodies above one read chunk are streamed chunked straight from the file:
    // the whole entity used to sit in the response buffer until the request
    // ended (a 1 GiB file = a 1 GiB peak). Smaller ones stay on the single-write
    // path, which keeps `Content-Length` on the wire — what HTTP/1.0 peers and
    // progress-reporting clients need. `HEAD` must answer with the same headers
    // as `GET` and no body at all, so it never takes the chunked path.
    const streamed = ctx.method == .GET and ctx.stream != null and ctx.io != null and
        length > @as(u64, mount.config.chunk_bytes);
    if (!streamed) try ctx.setHeader("Content-Length", try std.fmt.allocPrint(a, "{d}", .{length}));
    if (ctx.method == .HEAD) {
        ctx.responded = true;
        return;
    }
    if (streamed) try ctx.startChunked(ctx.status_code, content_type);

    // Chunked read so a large file does not need one exact-size allocation.
    const chunk = try a.alloc(u8, @min(@as(usize, @intCast(@min(length, mount.config.chunk_bytes))), mount.config.chunk_bytes));
    var remaining = length;
    var pos = offset;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, chunk.len));
        const got = file.readPositionalAll(mount.io, chunk[0..want], pos) catch {
            // Once headers are on the wire there is no status line left to
            // correct: a truncated chunked response is how the client finds out.
            if (streamed) return error.ReadFailed;
            try ctx.sendError(500, "ReadFailed");
            return;
        };
        if (got == 0) {
            // The file shrank under us. A short *chunked* body would look
            // complete to the client, so fail loudly instead of terminating it.
            if (streamed) return error.ReadFailed;
            break;
        }
        if (streamed) {
            try ctx.writeChunk(chunk[0..got]);
        } else {
            try ctx.response_body.appendSlice(ctx.allocator, chunk[0..got]);
        }
        pos += got;
        remaining -= got;
    }
    if (streamed) try ctx.endStream();
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

test "static files: bodies above chunk_bytes stream chunked over a real socket" {
    const allocator = std.testing.allocator;
    const http_client = @import("HttpClient.zig");
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;
    const io = std.testing.io;

    const dir_name = "zigmodu_static_stream_test";
    std.Io.Dir.cwd().createDirPath(io, dir_name) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir_name) catch {};

    // 5 KiB served with a 1 KiB read chunk: five chunks have to reach the socket.
    const big = try allocator.alloc(u8, 5 * 1024);
    defer allocator.free(big);
    for (big, 0..) |*b, i| b.* = @intCast(i % 253);
    {
        const f = try std.Io.Dir.cwd().createFile(io, dir_name ++ "/big.bin", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, big);
    }
    {
        const f = try std.Io.Dir.cwd().createFile(io, dir_name ++ "/small.txt", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "small static body");
    }

    var server = api.Server.init(io, allocator, 0);
    defer server.deinit();
    var mount_arena = std.heap.ArenaAllocator.init(allocator);
    defer mount_arena.deinit();
    try staticFiles(io, &server, mount_arena.allocator(), "/static", dir_name, .{ .chunk_bytes = 1024 });

    // `Testkit.dispatch` has no socket at all, so the in-process path keeps
    // buffering — that is what the test above covers. These assertions need the
    // wire, because only a socket-attached request takes the streaming path.
    const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
        fn run(s: *api.Server) void {
            s.start() catch {};
        }
    }.run, .{&server});
    defer th.join();
    defer server.stop();

    var port: u16 = 0;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        if (server.listener) |*l| {
            port = l.socket.address.getPort();
            break;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real) catch {};
    }
    try std.testing.expect(port != 0);

    // Raw syscalls only: the io scheduler is shared with the server thread, and
    // an io-path read here can stall.
    const Exchange = struct {
        fn send(alloc: std.mem.Allocator, port_: u16, request: []const u8) ![]u8 {
            const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port_);
            var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
            defer stream.close(std.testing.io);

            var sent: usize = 0;
            while (sent < request.len) {
                const rc = std.posix.system.write(stream.socket.handle, request.ptr + sent, request.len - sent);
                if (std.posix.errno(rc) != .SUCCESS) return error.ConnectionFailed;
                const n: usize = @intCast(rc);
                if (n == 0) return error.ConnectionFailed;
                sent += n;
            }

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(alloc);
            var buf: [4096]u8 = undefined;
            var fds = [_]std.posix.pollfd{.{
                .fd = stream.socket.handle,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};
            while (true) {
                if ((std.posix.poll(&fds, 3000) catch 0) == 0) break;
                const n = std.posix.read(stream.socket.handle, &buf) catch break;
                if (n == 0) break;
                try out.appendSlice(alloc, buf[0..n]);
            }
            return try out.toOwnedSlice(alloc);
        }
    };

    const Raw = struct {
        head: []const u8,
        body: []const u8,

        fn init(raw: []const u8) @This() {
            const i = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return .{ .head = raw, .body = "" };
            return .{ .head = raw[0..i], .body = raw[i + 4 ..] };
        }

        fn header(self: @This(), name: []const u8) ?[]const u8 {
            var it = std.mem.splitSequence(u8, self.head, "\r\n");
            while (it.next()) |line| {
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
                    return std.mem.trim(u8, line[colon + 1 ..], " \t");
                }
            }
            return null;
        }
    };

    {
        // Below the threshold: single write, `Content-Length` preserved.
        const raw = try Exchange.send(allocator, port, "GET /static/small.txt HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer allocator.free(raw);
        const resp = Raw.init(raw);
        try std.testing.expect(std.mem.startsWith(u8, resp.head, "HTTP/1.1 200 "));
        try std.testing.expectEqualStrings("17", resp.header("content-length").?);
        try std.testing.expect(resp.header("transfer-encoding") == null);
        try std.testing.expectEqualStrings("small static body", resp.body);
    }
    {
        // Above the threshold: chunked, no `Content-Length`, streamed per read
        // chunk (5 × 1 KiB chunks + the terminal chunk on the wire).
        const raw = try Exchange.send(allocator, port, "GET /static/big.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer allocator.free(raw);
        const resp = Raw.init(raw);
        try std.testing.expect(std.mem.startsWith(u8, resp.head, "HTTP/1.1 200 "));
        try std.testing.expectEqualStrings("chunked", resp.header("transfer-encoding").?);
        try std.testing.expect(resp.header("content-length") == null);
        try std.testing.expectEqualStrings("bytes", resp.header("accept-ranges").?);
        try std.testing.expectEqual(@as(usize, 5 * (5 + 1024 + 2) + 5), resp.body.len);
        try std.testing.expect(std.mem.startsWith(u8, resp.body, "400\r\n"));
        const decoded = try http_client.HttpClient.decodeChunkedBuffer(allocator, resp.body);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, big, decoded);
    }
    {
        // HEAD: same headers as GET, no body, `Content-Length` kept.
        const raw = try Exchange.send(allocator, port, "HEAD /static/big.bin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
        defer allocator.free(raw);
        const resp = Raw.init(raw);
        try std.testing.expect(std.mem.startsWith(u8, resp.head, "HTTP/1.1 200 "));
        try std.testing.expectEqualStrings("5120", resp.header("content-length").?);
        try std.testing.expect(resp.header("transfer-encoding") == null);
        try std.testing.expectEqualStrings("", resp.body);
    }
    {
        // Range on the streamed path: 206 + `Content-Range`, body still streamed.
        const raw = try Exchange.send(allocator, port, "GET /static/big.bin HTTP/1.1\r\nHost: x\r\nRange: bytes=1024-4095\r\nConnection: close\r\n\r\n");
        defer allocator.free(raw);
        const resp = Raw.init(raw);
        try std.testing.expect(std.mem.startsWith(u8, resp.head, "HTTP/1.1 206 "));
        try std.testing.expectEqualStrings("bytes 1024-4095/5120", resp.header("content-range").?);
        try std.testing.expectEqualStrings("chunked", resp.header("transfer-encoding").?);
        const decoded = try http_client.HttpClient.decodeChunkedBuffer(allocator, resp.body);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, big[1024..4096], decoded);
    }
    {
        // Unsatisfiable range: unchanged (416 + the total size).
        const raw = try Exchange.send(allocator, port, "GET /static/big.bin HTTP/1.1\r\nHost: x\r\nRange: bytes=99999-\r\nConnection: close\r\n\r\n");
        defer allocator.free(raw);
        const resp = Raw.init(raw);
        try std.testing.expect(std.mem.startsWith(u8, resp.head, "HTTP/1.1 416 "));
        try std.testing.expectEqualStrings("bytes */5120", resp.header("content-range").?);
    }
}
