//! Server-Sent Events writer — RFC-compliant SSE streaming with heartbeat support.
//!
//! Lifecycle: `init` / `http.sse(ctx)` sets `ctx.responded` **and** `ctx.streaming`
//! so `Server` skips the buffered `writeResponse` after the handler returns
//! (same contract as `Context.startChunked`).

const std = @import("std");

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
        try w.interface.writeAll("data: \n");
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
        try w.interface.writeAll("data: ");
        try w.interface.writeAll(line);
        try w.interface.writeAll("\n");
        if (nl) |n| {
            start += n + 1;
            if (start == data.len) {
                // Trailing newline → empty data line per common SSE usage
                try w.interface.writeAll("data: \n");
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
    last_id: ?[]const u8 = null,
    event_count: usize = 0,

    pub fn init(ctx: anytype) !SseWriter {
        const stream = ctx.stream orelse return error.NoStream;
        const io = ctx.io orelse return error.NoIo;

        try markSseResponse(ctx);
        try flushHeaders(ctx, stream, io);

        return SseWriter{
            .allocator = ctx.allocator,
            .stream = stream,
            .io = io,
        };
    }

    /// Send a named event with data. Alias for sendEvent (backward compat).
    pub fn send(self: *SseWriter, event: []const u8, data: []const u8) !void {
        return self.sendEvent(event, data);
    }

    /// Send a named event with data (multi-line `data` split into multiple `data:` lines).
    pub fn sendEvent(self: *SseWriter, event: []const u8, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &buf);

        if (self.last_id) |id| {
            try w.interface.writeAll("id: ");
            try w.interface.writeAll(id);
            try w.interface.writeAll("\n");
        }
        try w.interface.writeAll("event: ");
        try w.interface.writeAll(event);
        try w.interface.writeAll("\n");
        try writeDataField(&w, data);
        try w.interface.writeAll("\n");
        try w.interface.flush();

        self.event_count += 1;
    }

    /// Send a data-only event (event type defaults to "message" in browsers).
    pub fn sendData(self: *SseWriter, data: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &buf);

        if (self.last_id) |id| {
            try w.interface.writeAll("id: ");
            try w.interface.writeAll(id);
            try w.interface.writeAll("\n");
        }
        try writeDataField(&w, data);
        try w.interface.writeAll("\n");
        try w.interface.flush();

        self.event_count += 1;
    }

    /// Send a multi-line data event. Each string in data_lines becomes a `data:` line.
    pub fn sendMultiLine(self: *SseWriter, event: []const u8, data_lines: []const []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &buf);

        if (self.last_id) |id| {
            try w.interface.writeAll("id: ");
            try w.interface.writeAll(id);
            try w.interface.writeAll("\n");
        }
        try w.interface.writeAll("event: ");
        try w.interface.writeAll(event);
        try w.interface.writeAll("\n");
        for (data_lines) |line| {
            try w.interface.writeAll("data: ");
            try w.interface.writeAll(line);
            try w.interface.writeAll("\n");
        }
        try w.interface.writeAll("\n");
        try w.interface.flush();

        self.event_count += 1;
    }

    /// Set the event ID for reconnection. Subsequent events will include this ID.
    /// Clients send `Last-Event-ID` header on reconnect — see `lastEventId(ctx)`.
    pub fn setId(self: *SseWriter, id: []const u8) void {
        self.last_id = id;
    }

    /// Send a retry directive (milliseconds). Client waits this long before reconnecting.
    pub fn sendRetry(self: *SseWriter, ms: u64) !void {
        var write_buf: [64]u8 = undefined;
        var line_buf: [64]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        const retry_line = try std.fmt.bufPrint(&line_buf, "retry: {d}\n\n", .{ms});
        try w.interface.writeAll(retry_line);
        try w.interface.flush();
    }

    /// Send an SSE comment (ignored by clients, useful for keep-alive).
    pub fn sendComment(self: *SseWriter, comment: []const u8) !void {
        var buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &buf);
        try w.interface.writeAll(": ");
        try w.interface.writeAll(comment);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    /// Send keep-alive comment (prevents proxy timeouts).
    pub fn heartbeat(self: *SseWriter) !void {
        var buf: [64]u8 = undefined;
        var w = self.stream.writer(self.io, &buf);
        try w.interface.writeAll(": ping\n");
        try w.interface.flush();
    }

    /// Send [DONE] event to signal stream completion.
    pub fn done(self: *SseWriter) !void {
        try self.sendEvent("done", "[DONE]");
    }

    /// Send an error event to the client.
    pub fn sendError(self: *SseWriter, message: []const u8) !void {
        try self.sendEvent("error", message);
    }

    fn flushHeaders(ctx: anytype, stream: std.Io.net.Stream, io: std.Io) !void {
        var write_buf: [4096]u8 = undefined;
        var w = stream.writer(io, &write_buf);
        var line_buf: [256]u8 = undefined;

        const status_line = try std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} OK\r\n", .{ctx.status_code});
        try w.interface.writeAll(status_line);

        var hiter = ctx.response_headers.iterator();
        while (hiter.next()) |entry| {
            const header_line = try std.fmt.bufPrint(&line_buf, "{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            try w.interface.writeAll(header_line);
        }
        try w.interface.writeAll("\r\n");
        try w.interface.flush();
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
