//! Opt-in **response compression** middleware (`Accept-Encoding: gzip` / `deflate`).
//!
//!   try server.addMiddleware(zigmodu.http.compressionMiddleware(.{}));
//!
//! The middleware wraps the rest of the chain and re-encodes whatever the
//! handler left in `ctx.response_body`. A response is encoded only when all of
//! these hold:
//!
//!   * the request asked for `gzip` or `deflate` (`q` weights honoured, `*`
//!     honoured, an unusable entry ignored),
//!   * the body is at least `CompressionConfig.min_size` bytes (1 KiB default),
//!   * the status may carry a representation (`200`, `404`, `500`, … — not
//!     `1xx` / `204` / `205` / `206` / `304`),
//!   * the `Content-Type` is compressible (`text/*`, any `+json` / `+xml`
//!     suffix, plus `CompressionConfig.compressible_types`),
//!   * the response is not streaming (`ctx.streaming`: SSE, chunked), not
//!     already encoded (`Content-Encoding` present) and not already chunked
//!     (`Transfer-Encoding` in the response headers),
//!   * and the encoded form is actually smaller than the original.
//!
//! `Vary: Accept-Encoding` is added whenever the response *could* have been
//! compressed — including when the client did not ask for it, or the body was
//! below the threshold. Without it a shared cache may hand a gzip body to a
//! client that never advertised support for it, or pin the identity variant for
//! everyone; one wasted header is cheaper than a wrong cache entry.
//!
//! Failure policy: a compression failure (allocation, encoder error) leaves the
//! response exactly as the handler wrote it — never a half-swapped body, never a
//! `Content-Encoding` the bytes do not honour — and logs a warning. A request
//! must not fail because the optimization failed.
//!
//! Deliberately out of scope: `br` / `zstd` (not in std), a per-request
//! compression level, incremental (streaming) gzip, and `406` for clients that
//! reject `identity` — this middleware never changes the status of a response it
//! cannot encode.
//!
//! STRUCTURE:
//!   §1  Configuration —— compressible types, threshold, level
//!   §2  Negotiation & policy —— Accept-Encoding, status and media-type rules
//!   §3  Middleware —— the encode path and its header/body bookkeeping
//!   §4  Tests —— unit tests for the policy, end-to-end tests for the middleware

const std = @import("std");
const api = @import("Server.zig");

const flate = std.compress.flate;
/// `std.compress.flate` re-exports the `Compress` namespace, not its `Options`.
const FlateOptions = flate.Compress.Options;

/// Encodings this middleware can produce. HTTP `deflate` is the **zlib** stream
/// (RFC 9110 §8.4.1.2), which `Container.zlib` is — raw deflate would be a wire
/// break for clients that follow the RFC.
const Encoding = enum { gzip, deflate };

// ==== §1  Configuration ====

/// Media types compressed in addition to `text/*` and the `+json` / `+xml`
/// structured suffixes. Already-compressed formats (`image/*`, `video/*`,
/// `audio/*`, `font/*`, `application/zip`, `application/gzip`, …) are
/// deliberately absent: re-deflating them spends CPU to save nothing. The
/// suffix rule still catches the text formats hiding under those
/// prefixes — `image/svg+xml` is XML, not a pre-packed raster.
pub const default_compressible_types = [_][]const u8{
    "application/json",
    "application/javascript",
    "application/ecmascript",
    "application/xml",
    "application/x-ndjson",
    "application/manifest+json",
    "application/problem+json",
    "application/ld+json",
    "application/wasm",
};

/// Response-compression settings. `compressible_types` is borrowed, not copied
/// (same contract as `CorsConfig.allow_origins`): the slice must outlive the
/// middleware, so a literal is the usual form.
pub const CompressionConfig = struct {
    /// Bodies below this size are sent as they are. Under ~1 KiB the deflate
    /// window setup and 20-byte container header cost about what they save, and
    /// the client pays a second decode step for no win.
    min_size: usize = 1024,
    /// Extra compressible media types, matched case-insensitively against the
    /// `Content-Type` with its parameters stripped. A list is *additive*: the
    /// structural rules (`text/*`, `+json`, `+xml`) apply regardless, so a
    /// response typed `text/html` stays compressible even with `&.{}` here.
    compressible_types: []const []const u8 = &default_compressible_types,
    /// zlib tuning: `.fastest` / `.default` / `.best`, or a hand-tuned
    /// `std.compress.flate.Compress.Options`. There is no per-request override —
    /// a "compress the fast way under load" mode is an application decision this
    /// middleware does not guess.
    level: FlateOptions = .default,
};

// ==== §2  Negotiation & policy ====

/// May a response with this status carry an encoded body?
///
/// `1xx` has no representation; `204` / `205` are bodyless by definition; `304`
/// carries no representation of its own; and `206` is a *range of the
/// uncompressed representation* — encoding it would invalidate both
/// `Content-Range` and the byte offsets the client asked for. Everything else,
/// `4xx` / `5xx` included, may be encoded (error bodies are often the biggest
/// JSON documents a service emits, and the size threshold gates the rest).
fn statusCompressible(status: u16) bool {
    return switch (status) {
        100...199, 204, 205, 206, 304 => false,
        else => true,
    };
}

/// Is this media type worth deflating?
///
/// True for `text/*`, for any `+json` / `+xml` structured suffix, and for an
/// entry of `extra` (case-insensitive). No entry for `application/octet-stream`:
/// an untyped blob may be an already-compressed archive, and guessing wrong
/// costs CPU on every response.
fn mediaTypeCompressible(media: []const u8, extra: []const []const u8) bool {
    for (extra) |candidate| {
        if (std.ascii.eqlIgnoreCase(candidate, media)) return true;
    }
    if (std.ascii.startsWithIgnoreCase(media, "text/")) return true;
    if (std.mem.indexOfScalar(u8, media, '/')) |slash| {
        const subtree = media[slash + 1 ..];
        if (std.ascii.endsWithIgnoreCase(subtree, "+json")) return true;
        if (std.ascii.endsWithIgnoreCase(subtree, "+xml")) return true;
    }
    return false;
}

/// `Content-Type` of the response with its parameters (`; charset=utf-8`)
/// stripped, or `null` when absent/blank — an untyped response is not a
/// compression candidate.
fn responseMediaType(headers: std.StringHashMap([]const u8)) ?[]const u8 {
    const raw = responseHeader(headers, "Content-Type") orelse return null;
    const end = std.mem.indexOfScalar(u8, raw, ';') orelse raw.len;
    const media = std.mem.trim(u8, raw[0..end], " \t");
    return if (media.len == 0) null else media;
}

/// The `q` value of one `Accept-Encoding` entry's parameters: `1` when the entry
/// carries none, and `0` for an unparsable one (the safe direction — an
/// encoding whose weight cannot be read is not assumed acceptable).
fn quality(parameters: []const u8) f32 {
    var it = std.mem.splitScalar(u8, parameters, ';');
    while (it.next()) |parameter| {
        const eq = std.mem.indexOfScalar(u8, parameter, '=') orelse continue;
        const key = std.mem.trim(u8, parameter[0..eq], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "q")) continue;
        const text = std.mem.trim(u8, parameter[eq + 1 ..], " \t");
        const q = std.fmt.parseFloat(f32, text) catch return 0;
        // Also rejects NaN and negatives (`!(q > 0)`), which parseFloat accepts
        // for "-1" and "nan".
        if (!(q > 0)) return 0;
        return @min(q, 1);
    }
    return 1;
}

/// Which encoding to use for this request, or `null` when neither is acceptable.
///
/// Weights decide: the highest `q` wins, ties go to gzip (better supported and
/// smaller). A coding not named explicitly falls back to `*`, and an explicit
/// `gzip;q=0` overrides a permissive `*` — the most specific match wins, as
/// RFC 9110 requires. `identity` is not part of the decision: it is always
/// available, and this middleware never refuses a response.
fn selectEncoding(accept_encoding: ?[]const u8) ?Encoding {
    var gzip_q: f32 = 0;
    var deflate_q: f32 = 0;
    var star_q: f32 = 0;
    var gzip_named = false;
    var deflate_named = false;
    var star_named = false;

    var it = std.mem.splitScalar(u8, accept_encoding orelse return null, ',');
    while (it.next()) |part| {
        const entry = std.mem.trim(u8, part, " \t");
        if (entry.len == 0) continue;
        const end = std.mem.indexOfScalar(u8, entry, ';') orelse entry.len;
        const name = std.mem.trim(u8, entry[0..end], " \t");
        const q = quality(entry[end..]);
        if (std.ascii.eqlIgnoreCase(name, "gzip")) {
            gzip_q = q;
            gzip_named = true;
        } else if (std.ascii.eqlIgnoreCase(name, "deflate")) {
            deflate_q = q;
            deflate_named = true;
        } else if (std.mem.eql(u8, name, "*")) {
            star_q = q;
            star_named = true;
        }
    }

    const gzip = if (gzip_named) gzip_q else if (star_named) star_q else 0;
    const deflate = if (deflate_named) deflate_q else if (star_named) star_q else 0;
    if (gzip <= 0 and deflate <= 0) return null;
    return if (gzip >= deflate) .gzip else .deflate;
}

/// Does a `Vary` value already cover `name`? `*` counts as covering everything.
fn varyHasEntry(vary: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, vary, ',');
    while (it.next()) |part| {
        const entry = std.mem.trim(u8, part, " \t");
        if (std.mem.eql(u8, entry, "*")) return true;
        if (std.ascii.eqlIgnoreCase(entry, name)) return true;
    }
    return false;
}

/// Case-insensitive response-header lookup. `setHeader` stores keys with the
/// caller's spelling, so a plain `get("Vary")` would miss a `vary` set by
/// another middleware.
fn responseHeader(headers: std.StringHashMap([]const u8), name: []const u8) ?[]const u8 {
    if (headers.get(name)) |value| return value;
    var it = headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
    }
    return null;
}

/// Drop a response header if present (case-insensitive). Never fails: the only
/// work left is a `fetchRemove` and two frees.
fn removeResponseHeader(ctx: *api.Context, name: []const u8) void {
    var found: ?[]const u8 = null;
    var it = ctx.response_headers.iterator();
    while (it.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) {
            found = entry.key_ptr.*;
            break;
        }
    }
    const key = found orelse return;
    if (ctx.response_headers.fetchRemove(key)) |old| {
        ctx.allocator.free(old.key);
        ctx.allocator.free(old.value);
    }
}

/// Add `Accept-Encoding` to the response's `Vary`, merging with whatever is
/// already there (`cors` sets `Vary: Origin`) instead of replacing it, and never
/// listing it twice — two middlewares on one chain must not produce
/// `Vary: Accept-Encoding, Accept-Encoding`.
fn varyAcceptEncoding(ctx: *api.Context) !void {
    const existing = responseHeader(ctx.response_headers, "Vary") orelse "";
    if (varyHasEntry(existing, "Accept-Encoding")) return;
    const merged = if (existing.len == 0)
        try ctx.allocator.dupe(u8, "Accept-Encoding")
    else
        try std.fmt.allocPrint(ctx.allocator, "{s}, Accept-Encoding", .{existing});
    defer ctx.allocator.free(merged);
    try ctx.setHeader("Vary", merged);
}

// ==== §3  Middleware ====

/// The middleware entry point: give it a `CompressionConfig`, register the
/// result on the server and it compresses what the rest of the chain produces.
///
/// Register it **before** `recover()` (global middleware runs in registration
/// order, first = outermost): an inner `recover` renders the 500 body *before*
/// this middleware's post-processing, so an oversized error body is compressed
/// too. Position relative to auth gates does not matter — they all wrap the
/// handler, and the body is final by the time the chain unwinds.
pub fn compressionMiddleware(config: CompressionConfig) api.Middleware {
    // Per-instance configuration on `user_data` (process lifetime), like `cors`
    // and `csrf`: two servers with different thresholds must not share state.
    const stored = std.heap.page_allocator.create(CompressionConfig) catch @panic("compression middleware setup: out of memory");
    stored.* = config;
    return .{ .func = compressionMw, .user_data = stored };
}

fn compressionMw(ctx: *api.Context, next: api.HandlerFn, user_data: ?*anyopaque) anyerror!void {
    // The rest of the chain first: compression is a response transform, and
    // `next` is what fills `ctx.response_body`.
    try next(ctx);
    const config: *const CompressionConfig = @ptrCast(@alignCast(user_data.?));
    compressResponse(ctx, config) catch |err| {
        std.log.warn("[compression] {s} {s}: response left uncompressed ({s})", .{
            ctx.method.toString(), ctx.raw_path, @errorName(err),
        });
    };
}

/// Deflate `body` into a freshly allocated buffer (caller owns it).
///
/// All encoder state is heap-allocated on purpose: `std.compress.flate.Compress`
/// is ~230 KiB (a 32 K-token buffer plus two 32 K-entry hash chains) and the
/// history window another 64 KiB. A quarter of a megabyte of stack frame would
/// be touched on a connection thread many times a second, on top of whatever the
/// handler already used. It comes from the request allocator, so in production
/// the connection arena reclaims it between requests (and the tests here prove
/// nothing leaks when it is a real allocator).
fn encodeBody(
    allocator: std.mem.Allocator,
    container: flate.Container,
    level: FlateOptions,
    body: []const u8,
) ![]u8 {
    const Encoder = struct {
        state: flate.Compress,
        window: [flate.max_window_len]u8,
    };
    const encoder = try allocator.create(Encoder);
    defer allocator.destroy(encoder);

    // `Compress.init` asserts the output buffer is longer than 8 bytes.
    var out = try std.Io.Writer.Allocating.initCapacity(allocator, body.len / 2 + 64);
    errdefer out.deinit();

    encoder.state = try flate.Compress.init(&out.writer, &encoder.window, container, level);
    try encoder.state.writer.writeAll(body);
    try flate.Compress.finish(&encoder.state);
    return out.toOwnedSlice();
}

/// Encode `ctx.response_body` in place when the policy in the module docs
/// allows it. Errors are for the caller to log: the response is left untouched
/// (or, at worst, without the compression-only bookkeeping) on every exit path.
///
/// The order of the steps below is the safety property, not a style choice:
/// the encoded bytes are fully built before a single header changes, the body
/// swap is capacity-reserved *before* `Content-Encoding` is set, and the only
/// mutation that can no longer fail (`appendSliceAssumeCapacity` + dropping the
/// stale `Content-Length`) happens last. A failure therefore never leaves a
/// `Content-Encoding` on a body that does not honour it.
fn compressResponse(ctx: *api.Context, config: *const CompressionConfig) !void {
    if (!ctx.responded or ctx.streaming) return;
    if (!statusCompressible(ctx.status_code)) return;

    const media = responseMediaType(ctx.response_headers) orelse return;
    if (!mediaTypeCompressible(media, config.compressible_types)) return;

    // From here on the response is a compression *candidate*, so its cache
    // variant depends on the request's `Accept-Encoding` whether or not we end
    // up encoding it: `Vary` is set before any of the early returns below.
    try varyAcceptEncoding(ctx);

    const body = ctx.response_body.items;
    if (body.len < config.min_size) return;
    // Someone already encoded it (`br`, a pre-compressed asset, an application
    // that gzipped upstream). Encoding again would corrupt it.
    if (responseHeader(ctx.response_headers, "Content-Encoding") != null) return;
    // The body below is chunk-framed bytes; encoding them would corrupt the
    // framing, and `ctx.streaming` is only one way to get here.
    if (responseHeader(ctx.response_headers, "Transfer-Encoding") != null) return;

    const encoding = selectEncoding(ctx.header("accept-encoding")) orelse return;
    const container: flate.Container = switch (encoding) {
        .gzip => .gzip,
        // HTTP "deflate" is the zlib-wrapped stream, not raw deflate.
        .deflate => .zlib,
    };

    const encoded = try encodeBody(ctx.allocator, container, config.level, body);
    defer ctx.allocator.free(encoded);
    // Incompressible payloads (already-packed binary, random ids) come out
    // slightly *larger*. Sending those would cost a decode step for nothing, so
    // the original bytes stay (and `Vary` above keeps the caches honest).
    if (encoded.len >= body.len) return;

    try ctx.response_body.ensureTotalCapacity(ctx.allocator, encoded.len);
    try ctx.setHeader("Content-Encoding", switch (encoding) {
        .gzip => "gzip",
        .deflate => "deflate",
    });
    ctx.response_body.clearRetainingCapacity();
    ctx.response_body.appendSliceAssumeCapacity(encoded);
    // `writeResponse` derives `Content-Length` from the body it actually sends,
    // so a length the handler set is now stale — and leaving it would put a
    // second, conflicting `Content-Length` on the wire.
    removeResponseHeader(ctx, "Content-Length");
}

// ==== §4  Tests ====

/// `len` bytes of very compressible JSON, built at comptime so the test bodies
/// stay readable and no fixture file is needed.
fn compressiblePayload(comptime len: usize) [len]u8 {
    @setEvalBranchQuota(len * 4);
    var buf: [len]u8 = undefined;
    const unit = "{\"id\":12345,\"name\":\"widget\",\"active\":true},";
    for (&buf, 0..) |*byte, i| byte.* = unit[i % unit.len];
    return buf;
}

/// Well past the 1 KiB default threshold.
const big_json = compressiblePayload(4096);
/// Below the default threshold, but long enough that deflating it is still a
/// win — which is what makes the threshold the thing under test.
const small_json = compressiblePayload(256);

/// A handler that produces a response the way `ctx.json` would, without a live
/// socket: content type plus body, and `responded` set (which is what makes the
/// server write anything at all).
fn handlerFor(comptime content_type: []const u8, comptime payload: []const u8) api.HandlerFn {
    return struct {
        fn handle(ctx: *api.Context) anyerror!void {
            try ctx.setHeader("Content-Type", content_type);
            try ctx.response_body.appendSlice(ctx.allocator, payload);
            ctx.responded = true;
        }
    }.handle;
}

/// For tests that pre-fill the response and only want the middleware's own work.
fn noopHandler(_: *api.Context) anyerror!void {}

fn putRequestHeader(ctx: *api.Context, key: []const u8, value: []const u8) !void {
    const k = try ctx.allocator.dupe(u8, key);
    errdefer ctx.allocator.free(k);
    const v = try ctx.allocator.dupe(u8, value);
    errdefer ctx.allocator.free(v);
    try ctx.headers.put(k, v);
}

/// Inflate `encoded` with `container` (caller owns the returned bytes).
fn decodeBody(allocator: std.mem.Allocator, container: flate.Container, encoded: []const u8) ![]u8 {
    var source: std.Io.Reader = .fixed(encoded);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate = flate.Decompress.init(&source, container, &window);
    return inflate.reader.allocRemaining(allocator, .unlimited);
}

fn expectHeader(ctx: *api.Context, name: []const u8, expected: []const u8) !void {
    const actual = responseHeader(ctx.response_headers, name) orelse "<missing>";
    try std.testing.expectEqualStrings(expected, actual);
}

test "Compression: statuses and media types that must not be encoded" {
    try std.testing.expect(!statusCompressible(100));
    try std.testing.expect(!statusCompressible(199));
    try std.testing.expect(!statusCompressible(204));
    try std.testing.expect(!statusCompressible(205));
    try std.testing.expect(!statusCompressible(206));
    try std.testing.expect(!statusCompressible(304));
    try std.testing.expect(statusCompressible(200));
    try std.testing.expect(statusCompressible(201));
    try std.testing.expect(statusCompressible(404));
    try std.testing.expect(statusCompressible(500));

    const extra = &default_compressible_types;
    try std.testing.expect(mediaTypeCompressible("application/json", extra));
    try std.testing.expect(mediaTypeCompressible("Application/JSON", extra));
    try std.testing.expect(mediaTypeCompressible("text/html", extra));
    try std.testing.expect(mediaTypeCompressible("application/vnd.api+json", extra));
    try std.testing.expect(mediaTypeCompressible("application/atom+xml", extra));
    try std.testing.expect(!mediaTypeCompressible("image/png", extra));
    try std.testing.expect(!mediaTypeCompressible("image/jpeg", extra));
    try std.testing.expect(!mediaTypeCompressible("video/mp4", extra));
    try std.testing.expect(!mediaTypeCompressible("application/zip", extra));
    try std.testing.expect(!mediaTypeCompressible("application/gzip", extra));
    try std.testing.expect(!mediaTypeCompressible("application/octet-stream", extra));
    // `+xml` / `+json` are text formats even under `image/`: `image/svg+xml` is
    // the standard counter-example to "never touch image/*" and deflates well.
    try std.testing.expect(mediaTypeCompressible("image/svg+xml", extra));
    // A `text/*` type stays compressible even when the caller passes a list
    // that does not name it (the rules are additive, not a replacement).
    try std.testing.expect(mediaTypeCompressible("text/plain", &.{}));
}

test "Compression: Accept-Encoding negotiation" {
    try std.testing.expectEqual(@as(?Encoding, .gzip), selectEncoding("gzip"));
    try std.testing.expectEqual(@as(?Encoding, .deflate), selectEncoding("deflate"));
    try std.testing.expectEqual(@as(?Encoding, .gzip), selectEncoding("gzip, deflate"));
    try std.testing.expectEqual(@as(?Encoding, .gzip), selectEncoding("deflate;q=0.5, gzip;q=1.0"));
    try std.testing.expectEqual(@as(?Encoding, .deflate), selectEncoding("gzip;q=0, deflate"));
    try std.testing.expectEqual(@as(?Encoding, .gzip), selectEncoding("gzip ; q = 0.8"));
    try std.testing.expectEqual(@as(?Encoding, .gzip), selectEncoding("*"));
    try std.testing.expectEqual(@as(?Encoding, .gzip), selectEncoding("br, *;q=0.5"));

    // Nothing we can produce.
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding(null));
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding(""));
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding("identity"));
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding("br, zstd"));
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding("gzip;q=0"));
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding("gzip;q=0, *;q=0"));
    // An explicit refusal wins over a permissive wildcard (most specific match).
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding("gzip;q=0, deflate;q=0, *"));
    // An unreadable weight is not an acceptable weight.
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding("gzip;q=bogus"));
    try std.testing.expectEqual(@as(?Encoding, null), selectEncoding("gzip;q=-1"));
}

test "Compression: gzip round-trips a large JSON body" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "gzip");

    try mw.func(&ctx, handlerFor("application/json; charset=utf-8", &big_json), mw.user_data);

    try expectHeader(&ctx, "Content-Encoding", "gzip");
    try expectHeader(&ctx, "Vary", "Accept-Encoding");
    try std.testing.expect(ctx.response_body.items.len < big_json.len);

    const plain = try decodeBody(allocator, .gzip, ctx.response_body.items);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings(&big_json, plain);
}

test "Compression: the registered middleware encodes on the server chain" {
    const allocator = std.testing.allocator;
    const Testkit = @import("../http/Testkit.zig");
    var server = api.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    try server.addMiddleware(compressionMiddleware(.{}));
    var group = server.group("");
    try group.get("items", handlerFor("application/json", &big_json), null);

    const headers = [_]Testkit.HeaderPair{.{ "accept-encoding", "gzip" }};
    var resp = try Testkit.dispatchOpts(&server, .GET, "/items", .{ .headers = &headers });
    defer resp.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(resp.body.len < big_json.len);
    // What the client would hand its decoder, byte for byte.
    const plain = try decodeBody(allocator, .gzip, resp.body);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings(&big_json, plain);
}

test "Compression: deflate is the zlib stream and round-trips too" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "deflate");

    try mw.func(&ctx, handlerFor("text/plain", &big_json), mw.user_data);

    try expectHeader(&ctx, "Content-Encoding", "deflate");
    try expectHeader(&ctx, "Vary", "Accept-Encoding");
    const plain = try decodeBody(allocator, .zlib, ctx.response_body.items);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings(&big_json, plain);
}

test "Compression: no Accept-Encoding means no encoding, but Vary is still set" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();

    try mw.func(&ctx, handlerFor("application/json", &big_json), mw.user_data);

    try std.testing.expect(responseHeader(ctx.response_headers, "Content-Encoding") == null);
    try std.testing.expectEqualStrings(&big_json, ctx.response_body.items);
    // Cache correctness: the same URL returns a different body once
    // `Accept-Encoding: gzip` shows up, so the variant has to be declared even
    // on the response we chose not to encode.
    try expectHeader(&ctx, "Vary", "Accept-Encoding");
}

test "Compression: a body below the threshold stays uncompressed" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "gzip");

    try mw.func(&ctx, handlerFor("application/json", &small_json), mw.user_data);

    try std.testing.expect(responseHeader(ctx.response_headers, "Content-Encoding") == null);
    try std.testing.expectEqualStrings(&small_json, ctx.response_body.items);
    try expectHeader(&ctx, "Vary", "Accept-Encoding");

    // The same body *is* encoded once the threshold allows it, which is what
    // makes the assertion above about the threshold rather than the payload.
    const zero_mw = compressionMiddleware(.{ .min_size = 0 });
    var zero = try api.Context.init(allocator, .GET, "/api/items");
    defer zero.deinit();
    try putRequestHeader(&zero, "accept-encoding", "gzip");
    try zero_mw.func(&zero, handlerFor("application/json", &small_json), zero_mw.user_data);
    try expectHeader(&zero, "Content-Encoding", "gzip");

    // A payload with nothing to gain still stays uncompressed even with the
    // threshold out of the way: the encoded form would be *larger*.
    var tiny = try api.Context.init(allocator, .GET, "/api/items");
    defer tiny.deinit();
    try putRequestHeader(&tiny, "accept-encoding", "gzip");
    try zero_mw.func(&tiny, handlerFor("application/json", "{\"ok\":true}"), zero_mw.user_data);
    try std.testing.expect(responseHeader(tiny.response_headers, "Content-Encoding") == null);
    try std.testing.expectEqualStrings("{\"ok\":true}", tiny.response_body.items);
}

test "Compression: an already-encoded response is never encoded twice" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "gzip");
    try ctx.setHeader("Content-Type", "application/json");
    try ctx.setHeader("Content-Encoding", "br");
    try ctx.response_body.appendSlice(allocator, &big_json);
    ctx.responded = true;

    try mw.func(&ctx, noopHandler, mw.user_data);

    try expectHeader(&ctx, "Content-Encoding", "br");
    try std.testing.expectEqualStrings(&big_json, ctx.response_body.items);
}

test "Compression: streaming responses are left alone" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/events");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "gzip");
    try ctx.setHeader("Content-Type", "text/event-stream");
    try ctx.response_body.appendSlice(allocator, &big_json);
    ctx.responded = true;
    // Buffering a stream to encode it would break every later event's position.
    ctx.streaming = true;

    try mw.func(&ctx, noopHandler, mw.user_data);

    try std.testing.expect(responseHeader(ctx.response_headers, "Content-Encoding") == null);
    try expectHeader(&ctx, "Content-Type", "text/event-stream");
    try std.testing.expectEqualStrings(&big_json, ctx.response_body.items);
}

test "Compression: Vary merges with an existing value and is not duplicated" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();
    try ctx.setHeader("Content-Type", "application/json");
    try ctx.setHeader("Vary", "Origin"); // what `cors` writes
    try ctx.response_body.appendSlice(allocator, &big_json);
    ctx.responded = true;

    try mw.func(&ctx, noopHandler, mw.user_data);
    try expectHeader(&ctx, "Vary", "Origin, Accept-Encoding");

    // Second pass (an untouched, uncompressed response): no repeat entry.
    try mw.func(&ctx, noopHandler, mw.user_data);
    try expectHeader(&ctx, "Vary", "Origin, Accept-Encoding");
}

test "Compression: non-compressible media types get neither encoding nor Vary" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/img/logo.bin");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "gzip");

    try mw.func(&ctx, handlerFor("image/png", &big_json), mw.user_data);

    try std.testing.expect(responseHeader(ctx.response_headers, "Content-Encoding") == null);
    try std.testing.expect(responseHeader(ctx.response_headers, "Vary") == null);
    try std.testing.expectEqualStrings(&big_json, ctx.response_body.items);
}

test "Compression: a stale Content-Length is dropped with the original body" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "gzip");
    try ctx.setHeader("Content-Type", "application/json");
    try ctx.setHeader("Content-Length", "4096");
    try ctx.response_body.appendSlice(allocator, &big_json);
    ctx.responded = true;

    try mw.func(&ctx, noopHandler, mw.user_data);

    try expectHeader(&ctx, "Content-Encoding", "gzip");
    // The server writes `Content-Length` from the bytes it sends; a handler's
    // now-stale value would go out as a second, conflicting header.
    try std.testing.expect(responseHeader(ctx.response_headers, "Content-Length") == null);
    try std.testing.expect(ctx.response_body.items.len < big_json.len);
}

test "Compression: an allocation failure leaves the response untouched" {
    const allocator = std.testing.allocator;
    const mw = compressionMiddleware(.{});
    var ctx = try api.Context.init(allocator, .GET, "/api/items");
    defer ctx.deinit();
    try putRequestHeader(&ctx, "accept-encoding", "gzip");
    try ctx.setHeader("Content-Type", "application/json");
    // Pre-set, so the first allocation the middleware makes is the encoder
    // state — the failure this test is about.
    try ctx.setHeader("Vary", "Accept-Encoding");
    try ctx.response_body.appendSlice(allocator, &big_json);
    ctx.responded = true;

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    ctx.allocator = failing.allocator();
    try mw.func(&ctx, noopHandler, mw.user_data);

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(responseHeader(ctx.response_headers, "Content-Encoding") == null);
    try expectHeader(&ctx, "Vary", "Accept-Encoding");
    try std.testing.expectEqualStrings(&big_json, ctx.response_body.items);
}
