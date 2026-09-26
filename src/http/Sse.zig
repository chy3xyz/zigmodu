//! Server-Sent Events writer — RFC-compliant SSE streaming with heartbeat support.
//!
//! Lifecycle: `init` / `http.sse(ctx)` sets `ctx.responded` **and** `ctx.streaming`
//! so `Server` skips the buffered `writeResponse` after the handler returns
//! (same contract as `Context.startChunked`).

const std = @import("std");
const sockread = @import("../core/sockread.zig");

/// Read `Last-Event-ID` from the request (EventSource reconnect). Header keys are lowercase.
pub fn lastEventId(ctx: anytype) ?[]const u8 {
    if (@hasDecl(@TypeOf(ctx.*), "header")) {
        return ctx.header("last-event-id");
    }
    return ctx.headers.get("last-event-id");
}

/// Write SSE `data:` lines, splitting on `\n` (and stripping trailing `\r`).
fn writeDataField(w: anytype, data: []const u8) !void {
    if (data.len == 0) {
        try w.write("data: \n");
        return;
    }
    var start: usize = 0;
    while (start <= data.len) {
        const rest = data[start..];
        if (rest.len == 0) break;
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line_raw = if (nl) |n| rest[0..n] else rest;
        const line = if (line_raw.len > 0 and line_raw[line_raw.len - 1] == '\r')
            line_raw[0 .. line_raw.len - 1]
        else
            line_raw;
        try w.write("data: ");
        try w.write(line);
        try w.write("\n");
        if (nl) |n| {
            start += n + 1;
            if (start == data.len) {
                // Trailing newline → empty data line per common SSE usage
                try w.write("data: \n");
                break;
            }
        } else break;
    }
}

fn appendDataField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), data: []const u8) !void {
    if (data.len == 0) {
        try buf.appendSlice(allocator, "data: \n");
        return;
    }
    var start: usize = 0;
    while (start <= data.len) {
        const rest = data[start..];
        if (rest.len == 0) break;
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line_raw = if (nl) |n| rest[0..n] else rest;
        const line = if (line_raw.len > 0 and line_raw[line_raw.len - 1] == '\r')
            line_raw[0 .. line_raw.len - 1]
        else
            line_raw;
        try buf.appendSlice(allocator, "data: ");
        try buf.appendSlice(allocator, line);
        try buf.appendSlice(allocator, "\n");
        if (nl) |n| {
            start += n + 1;
            if (start == data.len) {
                try buf.appendSlice(allocator, "data: \n");
                break;
            }
        } else break;
    }
}

/// Apply SSE response headers and streaming flags (no socket I/O).
/// `Server` skips buffered `writeResponse` when `responded && streaming`.
pub fn markSseResponse(ctx: anytype) !void {
    ctx.status_code = 200;
    try ctx.setHeader("Content-Type", "text/event-stream");
    try ctx.setHeader("Cache-Control", "no-cache");
    try ctx.setHeader("Connection", "keep-alive");
    try ctx.setHeader("X-Accel-Buffering", "no"); // nginx
    ctx.responded = true;
    ctx.streaming = true;
}

/// Whether this request asked for `HEAD` (RFC 9110 §9.3.2). `ctx` is `anytype`;
/// a context that carries no `method` is not a `HEAD` request.
fn isHeadRequest(ctx: anytype) bool {
    if (!@hasField(@TypeOf(ctx.*), "method")) return false;
    return ctx.method == .HEAD;
}

/// Server-Sent Events writer.
///
/// SSE is a unidirectional stream from server to client over HTTP.
/// Clients connect with EventSource API and auto-reconnect on disconnect.
///
/// Usage:
///   var sse = try zigmodu.http.sse(ctx);
///   try sse.sendEvent("message", "hello");
///   try sse.sendEvent("update", json_data);
///   try sse.done();
pub const SseWriter = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    io: std.Io,
    /// The request was a `HEAD`: the field section `init` flushed is the whole
    /// response, and the events below are the body a `GET` would have received
    /// (RFC 9110 §9.3.2) — so none of them is written, the same shape
    /// `Context.writeChunk` takes under `HEAD`. A field section alone *is* a
    /// complete response to `HEAD` (RFC 9112 §6.3), so the connection stays
    /// framed for the next request on it.
    head_request: bool = false,
    last_id: ?[]const u8 = null,
    event_count: usize = 0,
    /// Send bound for every event this writer puts on the wire
    /// (`Context.write_timeout_ms`, i.e. `Config.response_write_timeout_ms`).
    /// An SSE loop runs *inside* the handler, so `writeResponse` — and the bound
    /// it applies — never gets a turn here; a subscriber that stops reading is
    /// otherwise able to park this fiber for as long as it likes, which is also
    /// as long as `stop()` waits.
    write_timeout_ms: u32 = 0,

    pub fn init(ctx: anytype) !SseWriter {
        const stream = ctx.stream orelse return error.NoStream;
        const io = ctx.io orelse return error.NoIo;

        try markSseResponse(ctx);
        try flushHeaders(ctx, stream, writeTimeoutOf(ctx));

        return SseWriter{
            .allocator = ctx.allocator,
            .stream = stream,
            .io = io,
            .head_request = isHeadRequest(ctx),
            .write_timeout_ms = writeTimeoutOf(ctx),
        };
    }

    /// The buffered, bounded writer one event goes through.
    fn writer(self: *SseWriter, buf: []u8) sockread.BoundedWriter {
        return sockread.BoundedWriter.init(self.stream, buf, self.write_timeout_ms);
    }

    /// Send a named event with data. Alias for sendEvent (backward compat).
    pub fn send(self: *SseWriter, event: []const u8, data: []const u8) !void {
        return self.sendEvent(event, data);
    }

    /// Send a named event with data (multi-line `data` split into multiple `data:` lines).
    pub fn sendEvent(self: *SseWriter, event: []const u8, data: []const u8) !void {
        if (self.head_request) return;
        var buf: [4096]u8 = undefined;
        var w = self.writer(&buf);

        if (self.last_id) |id| {
            try w.write("id: ");
            try w.write(id);
            try w.write("\n");
        }
        try w.write("event: ");
        try w.write(event);
        try w.write("\n");
        try writeDataField(&w, data);
        try w.write("\n");
        try w.flush();

        self.event_count += 1;
    }

    /// Send a data-only event (event type defaults to "message" in browsers).
    pub fn sendData(self: *SseWriter, data: []const u8) !void {
        if (self.head_request) return;
        var buf: [4096]u8 = undefined;
        var w = self.writer(&buf);

        if (self.last_id) |id| {
            try w.write("id: ");
            try w.write(id);
            try w.write("\n");
        }
        try writeDataField(&w, data);
        try w.write("\n");
        try w.flush();

        self.event_count += 1;
    }

    /// Send a multi-line data event. Each string in data_lines becomes a `data:` line.
    pub fn sendMultiLine(self: *SseWriter, event: []const u8, data_lines: []const []const u8) !void {
        if (self.head_request) return;
        var buf: [4096]u8 = undefined;
        var w = self.writer(&buf);

        if (self.last_id) |id| {
            try w.write("id: ");
            try w.write(id);
            try w.write("\n");
        }
        try w.write("event: ");
        try w.write(event);
        try w.write("\n");
        for (data_lines) |line| {
            try w.write("data: ");
            try w.write(line);
            try w.write("\n");
        }
        try w.write("\n");
        try w.flush();

        self.event_count += 1;
    }

    /// Set the event ID for reconnection. Subsequent events will include this ID.
    /// Clients send `Last-Event-ID` header on reconnect — see `lastEventId(ctx)`.
    pub fn setId(self: *SseWriter, id: []const u8) void {
        self.last_id = id;
    }

    /// Send a retry directive (milliseconds). Client waits this long before reconnecting.
    pub fn sendRetry(self: *SseWriter, ms: u64) !void {
        if (self.head_request) return;
        var write_buf: [64]u8 = undefined;
        var line_buf: [64]u8 = undefined;
        var w = self.writer(&write_buf);
        const retry_line = try std.fmt.bufPrint(&line_buf, "retry: {d}\n\n", .{ms});
        try w.write(retry_line);
        try w.flush();
    }

    /// Send an SSE comment (ignored by clients, useful for keep-alive).
    pub fn sendComment(self: *SseWriter, comment: []const u8) !void {
        if (self.head_request) return;
        var buf: [4096]u8 = undefined;
        var w = self.writer(&buf);
        try w.write(": ");
        try w.write(comment);
        try w.write("\n");
        try w.flush();
    }

    /// Send keep-alive comment (prevents proxy timeouts).
    pub fn heartbeat(self: *SseWriter) !void {
        if (self.head_request) return;
        var buf: [64]u8 = undefined;
        var w = self.writer(&buf);
        try w.write(": ping\n");
        try w.flush();
    }

    /// Send [DONE] event to signal stream completion.
    pub fn done(self: *SseWriter) !void {
        try self.sendEvent("done", "[DONE]");
    }

    /// Send an error event to the client.
    pub fn sendError(self: *SseWriter, message: []const u8) !void {
        try self.sendEvent("error", message);
    }

    /// One response head line at a time, through the same bounded writer the
    /// events use.
    ///
    /// The 256-byte `line_buf` this used to `bufPrint` into is gone: it silently
    /// capped a field line at 256 bytes, so an SSE response with a long
    /// `Set-Cookie`/`Access-Control-Allow-Origin` failed the whole stream with
    /// `error.NoSpaceLeft`. The buffer below is sized past every value
    /// `Context.setHeader` accepts (`max_response_header_value_bytes` = 8 KiB).
    fn flushHeaders(ctx: anytype, stream: std.Io.net.Stream, write_timeout_ms: u32) !void {
        var head_buf: [16 * 1024]u8 = undefined;
        var w = sockread.BoundedWriter.init(stream, &head_buf, write_timeout_ms);

        try w.print("HTTP/1.1 {d} OK\r\n", .{ctx.status_code});
        var hiter = ctx.response_headers.iterator();
        while (hiter.next()) |entry| {
            try w.print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        try w.write("\r\n");
        try w.flush();
    }

    /// The context's send bound where it has one: `Context.write_timeout_ms`.
    /// Context-shaped callers without it (tests, adapters) stay unbounded.
    fn writeTimeoutOf(ctx: anytype) u32 {
        if (!@hasField(@TypeOf(ctx.*), "write_timeout_ms")) return 0;
        return ctx.write_timeout_ms;
    }
};

/// In-memory SSE recorder for unit tests (no socket). Same framing as `SseWriter`.
pub const SseRecorder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    event_count: usize = 0,
    last_id: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) SseRecorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SseRecorder) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn bytes(self: *const SseRecorder) []const u8 {
        return self.buf.items;
    }

    pub fn setId(self: *SseRecorder, id: []const u8) void {
        self.last_id = id;
    }

    pub fn sendEvent(self: *SseRecorder, event: []const u8, data: []const u8) !void {
        if (self.last_id) |id| {
            try self.buf.appendSlice(self.allocator, "id: ");
            try self.buf.appendSlice(self.allocator, id);
            try self.buf.appendSlice(self.allocator, "\n");
        }
        try self.buf.appendSlice(self.allocator, "event: ");
        try self.buf.appendSlice(self.allocator, event);
        try self.buf.appendSlice(self.allocator, "\n");
        try appendDataField(self.allocator, &self.buf, data);
        try self.buf.appendSlice(self.allocator, "\n");
        self.event_count += 1;
    }

    pub fn sendData(self: *SseRecorder, data: []const u8) !void {
        try appendDataField(self.allocator, &self.buf, data);
        try self.buf.appendSlice(self.allocator, "\n");
        self.event_count += 1;
    }

    pub fn done(self: *SseRecorder) !void {
        try self.sendEvent("done", "[DONE]");
    }

    pub fn heartbeat(self: *SseRecorder) !void {
        try self.buf.appendSlice(self.allocator, ": ping\n");
    }
};

test "SseRecorder matches wire format" {
    const allocator = std.testing.allocator;
    var rec = SseRecorder.init(allocator);
    defer rec.deinit();

    rec.setId("7");
    try rec.sendEvent("message", "{\"ok\":true}");
    try rec.done();

    try std.testing.expectEqual(@as(usize, 2), rec.event_count);
    try std.testing.expect(std.mem.indexOf(u8, rec.bytes(), "id: 7\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.bytes(), "event: message\ndata: {\"ok\":true}\n\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.bytes(), "event: done\ndata: [DONE]\n\n") != null);
}

test "SseRecorder splits multiline data" {
    const allocator = std.testing.allocator;
    var rec = SseRecorder.init(allocator);
    defer rec.deinit();

    try rec.sendEvent("update", "line1\nline2");
    try std.testing.expectEqualStrings("event: update\ndata: line1\ndata: line2\n\n", rec.bytes());
}

test "SseWriter sendMultiLine format" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    const event = "update";
    const lines = &[_][]const u8{ "{\"a\":1}", "{\"b\":2}" };

    try buf.appendSlice(allocator, "event: ");
    try buf.appendSlice(allocator, event);
    try buf.appendSlice(allocator, "\n");
    for (lines) |line| {
        try buf.appendSlice(allocator, "data: ");
        try buf.appendSlice(allocator, line);
        try buf.appendSlice(allocator, "\n");
    }
    try buf.appendSlice(allocator, "\n");

    try std.testing.expectStringStartsWith(buf.items, "event: update\n");
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data: {\"a\":1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data: {\"b\":2}") != null);
}

test "lastEventId reads lowercase header" {
    const Context = @import("../api/Server.zig").Context;
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "events");
    defer ctx.deinit();

    const k = try allocator.dupe(u8, "last-event-id");
    const v = try allocator.dupe(u8, "42");
    try ctx.headers.put(k, v);

    try std.testing.expectEqualStrings("42", lastEventId(&ctx).?);
}

// --- HEAD over loopback ---
//
// `SseWriter` writes the field section itself (`flushHeaders`) and then every
// event straight to `ctx.stream`, so the shape a `HEAD` request produces only
// exists on the wire: nothing else in `Server` assembles it.

/// Field section of an H1 response, status line included.
fn h1FieldSection(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return response;
    return response[0..end];
}

/// The bytes after the field section of an H1 response.
fn h1Body(response: []const u8) []const u8 {
    const end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return "";
    return response[end + 4 ..];
}

/// First value of field `name` in `response`'s field section, borrowed from
/// `response`; "" when the field is absent.
fn h1FieldValue(response: []const u8, name: []const u8) []const u8 {
    var lines = std.mem.splitSequence(u8, h1FieldSection(response), "\r\n");
    _ = lines.next(); // status line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return "";
}

/// One HTTP/1.1 exchange against a running `Server`: send `request`, then read
/// until EOF (the caller's `Connection: close` is what ends it, and pipelined
/// requests are answered in order before it does).
fn h1Exchange(port: u16, request: []const u8, out: []u8) ![]const u8 {
    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var stream = try addr.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);

    try @import("../core/sockread.zig").writeFull(stream, request);

    var total: usize = 0;
    while (total < out.len) {
        var fds = [_]std.posix.pollfd{.{ .fd = stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&fds, 3000) catch break;
        if (ready == 0) break;
        const n = std.posix.read(stream.socket.handle, out[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return out[0..total];
}

test "a HEAD request to an SSE handler writes no event bytes" {
    const allocator = std.testing.allocator;
    if (!@import("../test/NetworkProbe.zig").available()) return error.SkipZigTest;

    const api = @import("../api/Server.zig");
    const Server = api.Server;
    const Context = api.Context;

    var server = Server.initWithConfig(std.testing.io, allocator, .{ .port = 0, .name = "h1-head-sse" });
    defer server.deinit();

    const Harness = struct {
        thread: std.Thread,
        port: u16,

        fn start(srv: *Server) !@This() {
            const th = try std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, struct {
                fn run(s: *Server) void {
                    s.start() catch |err| std.log.warn("[sse head] test accept loop ended: {s}", .{@errorName(err)});
                }
            }.run, .{srv});

            var port: u16 = 0;
            var tries: usize = 0;
            while (tries < 200) : (tries += 1) {
                if (srv.listener) |*l| {
                    port = l.socket.address.getPort();
                    break;
                }
                std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(10), .real) catch |err|
                    std.log.debug("[sse head] poll sleep failed: {s}", .{@errorName(err)});
            }
            if (port == 0) {
                srv.stop();
                th.join();
                return error.ServerNeverListened;
            }
            return .{ .thread = th, .port = port };
        }

        fn stop(self: *@This(), srv: *Server) void {
            srv.stop();
            self.thread.join();
        }
    };

    // Every write path the writer has, then the handler returns. The same
    // handler serves both methods, so the method is the only variable between
    // the exchanges below.
    const everyWrite = struct {
        fn h(ctx: *Context) anyerror!void {
            var writer = try SseWriter.init(ctx);
            try writer.sendRetry(1000);
            try writer.heartbeat();
            try writer.sendEvent("tick", "1");
            try writer.sendData("2");
            try writer.sendMultiLine("multi", &.{ "a", "b" });
            try writer.sendComment("keep");
            try writer.done();
        }
    }.h;

    var group = server.group("");
    try group.get("ev", everyWrite, null);
    try group.head("ev", everyWrite, null);

    var running = try Harness.start(&server);
    defer running.stop(&server);

    {
        // The `GET` first: it proves the handler really streams, so the `HEAD`
        // assertions below are about the method and not about a dead route — and
        // it pins the framing the `HEAD` response has to be free of.
        var out: [4096]u8 = undefined;
        const response = try h1Exchange(running.port, "GET /ev HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        try std.testing.expectEqualStrings("text/event-stream", h1FieldValue(response, "content-type"));
        try std.testing.expectEqualStrings(
            "retry: 1000\n\n" ++
                ": ping\n" ++
                "event: tick\ndata: 1\n\n" ++
                "data: 2\n\n" ++
                "event: multi\ndata: a\ndata: b\n\n" ++
                ": keep\n" ++
                "event: done\ndata: [DONE]\n\n",
            h1Body(response),
        );
    }
    {
        // RFC 9110 §9.3.2: the field section is the `GET`'s and the message ends
        // there. The event bytes a `HEAD` client would have to skip are exactly
        // what desynchronises the connection for the next request on it.
        var out: [4096]u8 = undefined;
        const response = try h1Exchange(running.port, "HEAD /ev HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", &out);
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        try std.testing.expectEqualStrings("text/event-stream", h1FieldValue(response, "content-type"));
        try std.testing.expectEqualStrings("", h1Body(response));
    }
    {
        // Two requests on one connection: a response to `HEAD` is terminated by
        // the first empty line after the field section (RFC 9112 §6.3), so the
        // pipelined `GET` has to begin exactly there — and be answered in full,
        // which is what "the connection is still usable" means.
        var out: [4096]u8 = undefined;
        const response = try h1Exchange(
            running.port,
            "HEAD /ev HTTP/1.1\r\nHost: x\r\n\r\n" ++ "GET /ev HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n",
            &out,
        );
        try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
        const first_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.NoHeadFieldSection;
        try std.testing.expectEqualStrings("text/event-stream", h1FieldValue(response, "content-type"));
        try std.testing.expect(std.mem.startsWith(u8, response[first_end + 4 ..], "HTTP/1.1 200"));
        try std.testing.expect(std.mem.endsWith(u8, response, "event: done\ndata: [DONE]\n\n"));
    }
}

test "markSseResponse sets streaming so Server skips buffered rewrite" {
    const Context = @import("../api/Server.zig").Context;
    const allocator = std.testing.allocator;
    var ctx = try Context.init(allocator, .GET, "events");
    defer ctx.deinit();

    try markSseResponse(&ctx);
    try std.testing.expect(ctx.responded);
    try std.testing.expect(ctx.streaming);
    // Same predicate Server uses before writeResponse:
    try std.testing.expect(!(ctx.responded and !ctx.streaming));
    try std.testing.expectEqualStrings("text/event-stream", ctx.response_headers.get("Content-Type").?);
}
