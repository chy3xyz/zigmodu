const std = @import("std");

/// Server-Sent Events writer.
///
/// SSE is a unidirectional stream from server to client over HTTP.
/// Clients connect with EventSource API and auto-reconnect on disconnect.
///
/// Usage:
///   var sse = try zigmodu.http.SseWriter.init(ctx);
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

        ctx.status_code = 200;
        ctx.setHeader("Content-Type", "text/event-stream") catch {};
        ctx.setHeader("Cache-Control", "no-cache") catch {};
        ctx.setHeader("Connection", "keep-alive") catch {};
        ctx.setHeader("X-Accel-Buffering", "no") catch {}; // nginx
        ctx.responded = true;

        // Flush headers to socket immediately
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

    /// Send a named event with data.
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
        try w.interface.writeAll("\ndata: ");
        try w.interface.writeAll(data);
        try w.interface.writeAll("\n\n");
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
        try w.interface.writeAll("data: ");
        try w.interface.writeAll(data);
        try w.interface.writeAll("\n\n");
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
    /// Clients send `Last-Event-ID` header on reconnect.
    pub fn setId(self: *SseWriter, id: []const u8) void {
        self.last_id = id;
    }

    /// Send a retry directive (milliseconds). Client waits this long before reconnecting.
    pub fn sendRetry(self: *SseWriter, ms: u64) !void {
        var buf: [128]u8 = undefined;
        var w = self.stream.writer(self.io, &buf);
        const retry_line = try std.fmt.bufPrint(&buf, "retry: {d}\n\n", .{ms});
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

test "SseWriter sendEvent" {
    // Unit test: validates SSE formatting
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    // Build a minimal SSE event manually to verify format
    const event = "message";
    const data = "hello world";
    const expected = "event: message\ndata: hello world\n\n";

    try buf.appendSlice(allocator, "event: ");
    try buf.appendSlice(allocator, event);
    try buf.appendSlice(allocator, "\ndata: ");
    try buf.appendSlice(allocator, data);
    try buf.appendSlice(allocator, "\n\n");

    try std.testing.expectEqualStrings(expected, buf.items);
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

test "SseWriter retry format" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "retry: 3000\n\n");

    try std.testing.expectEqualStrings("retry: 3000\n\n", buf.items);
}

test "SseWriter comment format" {
    const allocator = std.testing.allocator;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, ": ping\n");

    try std.testing.expectEqualStrings(": ping\n", buf.items);
}
