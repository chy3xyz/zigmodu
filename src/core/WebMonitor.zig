const std = @import("std");
const Application = @import("../Application.zig").Application;
const ApplicationModules = @import("Module.zig").ApplicationModules;
const ModuleInfo = @import("Module.zig").ModuleInfo;

// ⚠️ EXPERIMENTAL: This module is incomplete and not production-ready.
/// Web interface for module monitoring
/// Provides HTTP endpoints for viewing module status, metrics, and health
pub const WebMonitor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    server: ?std.Io.net.Server,
    is_running: bool,
    modules: ?*ApplicationModules,
    buf: [8192]u8,

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

    pub fn deinit(self: *Self) void {
        self.stop();
    }

    /// Start the web server
    pub fn start(self: *Self, modules: *ApplicationModules) !void {
        if (self.is_running) return;

        self.modules = modules;

        const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.server = try std.Io.net.listen(&address, self.io, .{
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
            s.deinit(self.io);
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
                    conn.stream.close(self.io);
                    continue;
                };
                thread.detach();
            }
        }
    }

    fn handleRequest(self: *Self, conn: std.Io.net.Server.Connection) void {
        defer conn.stream.close(self.io);

        var buf: [4096]u8 = undefined;
        var r = std.Io.net.Stream.reader(conn.stream, self.io, &buf);
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
            self.handleIndex(conn.stream);
        } else if (std.mem.eql(u8, path, "/api/modules")) {
            self.handleModules(conn.stream);
        } else if (std.mem.eql(u8, path, "/api/health")) {
            self.handleHealth(conn.stream);
        } else if (std.mem.eql(u8, path, "/api/metrics")) {
            self.handleMetrics(conn.stream);
        } else {
            self.handle404(conn.stream);
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

        var write_buf: [2048]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, self.io, &write_buf);
        _ = w.writeAll(response) catch {};
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

        var write_buf: [8192]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, self.io, &write_buf);
        _ = w.writeAll(response) catch {};
    }

    fn handleHealth(self: *Self, stream: std.Io.net.Stream) void {

        const json = "{\"status\":\"healthy\",\"timestamp\":0}";

        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ json.len, json }) catch return;

        var write_buf: [256]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, self.io, &write_buf);
        _ = w.writeAll(response) catch {};
    }

    fn handleMetrics(self: *Self, stream: std.Io.net.Stream) void {
        var response_buf: [1024]u8 = undefined;

        const module_count = if (self.modules) |m| m.modules.count() else 0;

        const json = std.fmt.bufPrint(&response_buf, "{{\"module_count\":{d},\"uptime\":0,\"memory_usage\":0}}", .{module_count}) catch return;

        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ json.len, json }) catch return;

        var write_buf: [1024]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, self.io, &write_buf);
        _ = w.writeAll(response) catch {};
    }

    fn handle404(self: *Self, stream: std.Io.net.Stream) void {

        const body = "Not Found";

        var response_buf: [256]u8 = undefined;
        const response = std.fmt.bufPrint(&response_buf, "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body }) catch return;

        var write_buf: [256]u8 = undefined;
        var w = std.Io.net.Stream.writer(stream, self.io, &write_buf);
        _ = w.writeAll(response) catch {};
    }
};

test "WebMonitor init stop" {
    const allocator = std.testing.allocator;
    var monitor = WebMonitor.init(allocator, std.testing.io, 19999);
    defer monitor.deinit();

    try std.testing.expectEqual(@as(u16, 19999), monitor.port);
    try std.testing.expect(!monitor.is_running);
}
