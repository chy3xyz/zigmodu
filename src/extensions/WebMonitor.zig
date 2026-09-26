const std = @import("std");
const sockread = @import("../core/sockread.zig");
const Application = @import("../Application.zig").Application;
const ApplicationModules = @import("../core/Module.zig").ApplicationModules;
const ModuleInfo = @import("../core/Module.zig").ModuleInfo;

/// Web interface for module monitoring
pub const WebMonitor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    server: ?std.Io.net.Server,
    is_running: bool,
    modules: ?*ApplicationModules,
    buf: [8192]u8,
    /// Send bound for every response this monitor writes (`SO_SNDTIMEO` armed
    /// around the write). Each connection is handled by a **detached thread**, so
    /// a browser tab that stops reading would otherwise hold that thread for as
    /// long as it likes — and nobody joins these threads, so there is no other
    /// place to bound it. 0 = unbounded.
    write_timeout_ms: u32 = 30_000,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .port = port,
            .server = null,
            .is_running = false,
            .modules = null,
            .buf = undefined,
        };
    }

    /// Override the response send bound (`write_timeout_ms`; 0 = unbounded).
    pub fn setWriteTimeout(self: *Self, timeout_ms: u32) void {
        self.write_timeout_ms = timeout_ms;
    }

    /// Write one response with the send bound armed.
    ///
    /// Raw syscalls, not `stream.writer(io, …)`, for two reasons: the io writer
    /// cannot express the bound at all (it answers a timed-out send with
    /// `errnoBug`, which is `unreachable`), and — as these five handlers found out
    /// the hard way — `Writer.writeAll` only *buffers* what fits, so a response
    /// smaller than the buffer needs a `flush` this file never had: the bytes died
    /// with the local writer, the client got an empty socket, and nothing was
    /// logged (the old code's `catch` only ever saw a *socket* error, and there
    /// was none). `sockread.writeFullBounded` writes and flushes in one step, so
    /// delivery and the bound are the same call.
    fn writeResponse(self: *Self, stream: std.Io.net.Stream, response: []const u8) void {
        sockread.writeFullBounded(stream, response, self.write_timeout_ms) catch |err| {
            std.log.debug("[web-monitor] response write failed (peer gone or not reading?): {s}", .{@errorName(err)});
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.* = undefined;
    }

    /// Start the web server
    pub fn start(self: *Self, modules: *ApplicationModules) !void {
        if (self.is_running) return;

        self.modules = modules;

        var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.server = try address.listen(self.io, .{
            .reuse_address = true,
        });

        self.is_running = true;
        std.log.info("[WebMonitor] Server started on http://0.0.0.0:{d}", .{self.port});

        // Start server loop
        const thread = try std.Thread.spawn(.{}, serverLoop, .{self});
        thread.detach();
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.server) |*s| {
            // `shutdown` before `close`: on Linux `close` does not wake the
            // thread blocked in `accept`, so the loop would keep it alive.
            sockread.closeListener(self.io, s);
            self.server = null;
        }
    }

    fn serverLoop(self: *Self) void {
        while (self.is_running) {
            if (self.server) |*s| {
                const conn = s.accept(self.io) catch |err| {
                    if (self.is_running) {
                        std.log.err("[WebMonitor] Accept error: {}", .{err});
                    }
                    continue;
                };

                // Handle request
                const thread = std.Thread.spawn(.{}, handleRequest, .{ self, conn }) catch |err| {
                    std.log.err("[WebMonitor] Failed to spawn thread: {}", .{err});
                    conn.close(self.io);
                    continue;
                };
                thread.detach();
            }
        }
    }

    fn handleRequest(self: *Self, conn: std.Io.net.Stream) void {
        defer conn.close(self.io);

        var buf: [4096]u8 = undefined;
        var r = conn.reader(self.io, &buf);
        const bytes_read = r.readSliceShort(&buf) catch |err| {
            std.log.err("[WebMonitor] Read error: {}", .{err});
            return;
        };

        if (bytes_read == 0) return;

        const request = buf[0..bytes_read];

        // Simple HTTP parsing
        var lines = std.mem.splitSequence(u8, request, "\r\n");
        const first_line = lines.first();

        var parts = std.mem.splitSequence(u8, first_line, " ");
        _ = parts.first(); // method (GET, POST, etc.)
        const path = parts.next() orelse "/";

        // Route request
        if (std.mem.eql(u8, path, "/")) {
            self.handleIndex(conn);
        } else if (std.mem.eql(u8, path, "/api/modules")) {
            self.handleModules(conn);
        } else if (std.mem.eql(u8, path, "/api/health")) {
            self.handleHealth(conn);
        } else if (std.mem.eql(u8, path, "/api/metrics")) {
            self.handleMetrics(conn);
        } else {
            self.handle404(conn);
        }
    }

    fn handleIndex(self: *Self, stream: std.Io.net.Stream) void {
        const html =
            \\<!DOCTYPE html>
            \\u003chtml>
            \\u003chead>
            \\    <title>ZigModu Monitor</title>
            \\    <style>
            \\        body { font-family: sans-serif; margin: 40px; }
            \\        h1 { color: #333; }
            \\        .endpoint { background: #f5f5f5; padding: 10px; margin: 10px 0; border-radius: 5px; }
            \\        code { background: #e0e0e0; padding: 2px 6px; border-radius: 3px; }
            \\    </style>
            \\u003c/head>
            \\u003cbody>
            \\    <h1>ZigModu Module Monitor</h1>
            \\    <p>Real-time monitoring interface for ZigModu framework</p>
            \\    
            \\    <h2>API Endpoints</h2>
            \\    <div class="endpoint">
            \\        <code>GET /api/modules</code> - List all modules
            \\    </div>
            \\    <div class="endpoint">
            \\        <code>GET /api/health</code> - System health check
            \\    </div>
            \\    <div class="endpoint">
            \\        <code>GET /api/metrics</code> - System metrics
            \\    </div>
            \\u003c/body>
            \\u003c/html>
        ;

        var response_buf: [2048]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\n\r\n{s}", .{ html.len, html }) catch return;

        self.writeResponse(stream, response);
    }

    fn handleModules(self: *Self, stream: std.Io.net.Stream) void {
        const ArrayList = std.array_list.Managed;
        var json = ArrayList(u8).init(self.allocator);
        defer json.deinit();

        json.appendSlice("{\"modules\":[\"") catch return;

        if (self.modules) |modules| {
            var first = true;
            var iter = modules.modules.iterator();
            while (iter.next()) |entry| {
                if (!first) json.appendSlice(",\"") catch return;
                first = false;

                var mod_buf: [512]u8 = undefined;
                const module_json = std.fmt.bufPrint(&mod_buf, "{{\"name\":\"{s}\",\"description\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.desc }) catch continue;

                json.appendSlice(module_json) catch continue;
            }
        }

        json.appendSlice("]}") catch return;

        var response_buf: [8192]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ json.items.len, json.items }) catch return;

        self.writeResponse(stream, response);
    }

    fn handleHealth(self: *Self, stream: std.Io.net.Stream) void {
        const json = "{\"status\":\"healthy\",\"timestamp\":0}";

        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ json.len, json }) catch return;

        self.writeResponse(stream, response);
    }

    fn handleMetrics(self: *Self, stream: std.Io.net.Stream) void {
        var response_buf: [1024]u8 = undefined;

        const module_count = if (self.modules) |m| m.modules.count() else 0;

        const json = std.fmt.bufPrint(&response_buf, "{{\"module_count\":{d},\"uptime\":0,\"memory_usage\":0}}", .{module_count}) catch return;

        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ json.len, json }) catch return;

        self.writeResponse(stream, response);
    }

    fn handle404(self: *Self, stream: std.Io.net.Stream) void {
        const body = "Not Found";

        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch return;

        self.writeResponse(stream, response);
    }
};

test "WebMonitor init stop" {
    const allocator = std.testing.allocator;
    var monitor = WebMonitor.init(allocator, std.testing.io, 19999);
    defer monitor.deinit();

    try std.testing.expectEqual(@as(u16, 19999), monitor.port);
    try std.testing.expect(!monitor.is_running);
}

test "a monitor response reaches the socket instead of dying in the writer's buffer" {
    // Red, measured on the previous implementation: every handler wrote through
    // `stream.writer(io, &buf)` + `Writer.writeAll` and **never flushed**, so a
    // response smaller than the buffer was dropped — the client got an empty
    // socket and nothing was logged, because the `catch` there only ever saw
    // socket errors and there was none. (`extensions/WebSocket.zig` carries the
    // same warning about the flush being the delivery; these five sites had
    // missed it.)
    const allocator = std.testing.allocator;
    var fds: [2]std.posix.socket_t = undefined;
    const rc = std.posix.system.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.SkipZigTest,
    }
    const server_side = std.Io.net.Stream{ .socket = .{ .handle = fds[0], .address = undefined } };
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var monitor = WebMonitor.init(allocator, std.testing.io, 0);

    // Three handlers on one socket, in order: the field section of each has to be
    // on the wire.
    monitor.handleIndex(server_side);
    monitor.handleMetrics(server_side);
    monitor.handle404(server_side);

    var buf: [8192]u8 = undefined;
    var got: usize = 0;
    var polls = [_]std.posix.pollfd{.{ .fd = fds[1], .events = std.posix.POLL.IN, .revents = 0 }};
    while (got < buf.len) {
        const ready = std.posix.poll(&polls, 200) catch break;
        if (ready == 0) break;
        const n = std.posix.read(fds[1], buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    const wire = buf[0..got];
    try std.testing.expect(std.mem.indexOf(u8, wire, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "ZigModu Module Monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, wire, "HTTP/1.1 404 Not Found") != null);
}
