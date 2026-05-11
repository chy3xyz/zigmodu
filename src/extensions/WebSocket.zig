const std = @import("std");
const ApplicationModules = @import("../core/Module.zig").ApplicationModules;

/// WebSocket support for real-time monitoring
/// Provides RFC 6455 WebSocket server functionality for live module updates
/// WebSocket support for real-time monitoring
/// Provides RFC 6455 WebSocket server functionality for live module updates
pub const WebSocketServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
    server: ?std.Io.net.Server,
    is_running: bool,
    clients: std.array_list.Managed(*WebSocketClient),
    clients_mutex: std.Io.Mutex,
    accept_fiber_started: bool,
    /// Group that owns the `acceptLoop` fiber and every spawned
    /// `handleConnection` fiber. Awaited in `stop()` so no futures leak.
    fiber_group: std.Io.Group,
    on_connect_cb: ?*const fn (*WebSocketClient) void,
    on_message_cb: ?*const fn (*WebSocketClient, []const u8) void,
    allowed_origins: []const []const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .port = port,
            .server = null,
            .is_running = false,
            .clients = std.array_list.Managed(*WebSocketClient).init(allocator),
            .clients_mutex = std.Io.Mutex.init,
            .accept_fiber_started = false,
            .fiber_group = .init,
            .on_connect_cb = null,
            .on_message_cb = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        self.clients_mutex.lock(self.io) catch return;
        defer self.clients_mutex.unlock(self.io);

        for (self.clients.items) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.clients.deinit();
    }

    pub fn start(self: *Self) !void {
        if (self.is_running) return;

        var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.server = try address.listen(self.io, .{ .reuse_address = true });
        self.is_running = true;
        self.accept_fiber_started = true;

        std.log.info("[WebSocketServer] Started on ws://0.0.0.0:{d}", .{self.port});
        // Start accept loop asynchronously as a member of `fiber_group`.
        self.fiber_group.async(self.io, acceptLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.server) |*s| {
            s.deinit(self.io);
            self.server = null;
        }
        // Drain any in-flight accept/connection fibers so their futures do
        // not leak. Safe to call repeatedly because `Group.await` is idempotent.
        self.fiber_group.await(self.io) catch {};
    }

    fn acceptLoop(self: *Self) void {
        while (self.is_running) {
            if (self.server) |*s| {
                const conn = s.accept(self.io) catch |err| {
                    if (self.is_running) {
                        std.log.err("[WebSocketServer] Accept error: {}", .{err});
                    }
                    continue;
                };
                self.fiber_group.async(self.io, handleConnection, .{ self, conn });
            }
        }
    }

    fn handleConnection(self: *Self, conn: std.Io.net.Stream) void {
        defer conn.close(self.io);

        var buf: [4096]u8 = undefined;
        var read_buf: [4096]u8 = undefined;
        var r = conn.reader(self.io, &read_buf);
        const bytes_read = r.interface.readSliceShort(&buf) catch |err| {
            std.log.err("[WebSocketServer] Read error: {}", .{err});
            return;
        };

        if (bytes_read == 0) return;
        const request = buf[0..bytes_read];

        // Parse WebSocket key from headers
        const ws_key = extractHeaderValue(request, "Sec-WebSocket-Key: ") orelse {
            // Not a WebSocket upgrade request - send HTTP response
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            var write_buf: [256]u8 = undefined;
            var w = conn.writer(self.io, &write_buf);
            _ = w.writeAll(response) catch {};
            return;
        };
        // Validate Origin header if allowed_origins is configured
        if (self.allowed_origins.len > 0) {
            const origin = extractHeaderValue(request, "Origin: ");
            if (origin) |o| {
                var origin_allowed = false;
                for (self.allowed_origins) |allowed| {
                    if (std.mem.eql(u8, allowed, o)) {
                        origin_allowed = true;
                        break;
                    }
                }
                if (!origin_allowed) {
                    const response = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
                    var write_buf: [256]u8 = undefined;
                    var w = conn.writer(self.io, &write_buf);
                    _ = w.writeAll(response) catch {};
                    return;
                }
            }
        }

        // Generate accept key
        // Generate accept key
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var hash_input: [60]u8 = undefined;
        const hash_len = ws_key.len + magic.len;
        @memcpy(hash_input[0..ws_key.len], ws_key);
        @memcpy(hash_input[ws_key.len..hash_len], magic);

        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(hash_input[0..hash_len]);
        var digest: [20]u8 = undefined;
        sha1.final(&digest);

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &digest);

        // Send handshake response
        const response = std.fmt.bufPrint(&buf, "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n", .{accept_key}) catch return;

        var write_buf: [4096]u8 = undefined;
        var w = conn.writer(self.io, &write_buf);
        _ = w.writeAll(response) catch |err| {
            std.log.err("[WebSocketServer] Handshake write error: {}", .{err});
            return;
        };

        // Create client
        const client = self.allocator.create(WebSocketClient) catch |err| {
            std.log.err("[WebSocketServer] Failed to allocate client: {}", .{err});
            return;
        };
        errdefer self.allocator.destroy(client);

        client.* = WebSocketClient.init(self.allocator, conn, self.io, self);

        self.clients_mutex.lock(self.io) catch return;
        self.clients.append(client) catch |err| {
            self.clients_mutex.unlock(self.io);
            std.log.err("[WebSocketServer] Failed to add client: {}", .{err});
            client.deinit();
            self.allocator.destroy(client);
            return;
        };
        self.clients_mutex.unlock(self.io);

        if (self.on_connect_cb) |cb| {
            cb(client);
        }

        client.run();

        // Remove client after disconnect
        self.clients_mutex.lock(self.io) catch return;
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        self.clients_mutex.unlock(self.io);

        client.deinit();
        self.allocator.destroy(client);
    }

    fn extractHeaderValue(request: []const u8, header_name: []const u8) ?[]const u8 {
        if (std.mem.indexOf(u8, request, header_name)) |idx| {
            const value_start = idx + header_name.len;
            if (std.mem.indexOf(u8, request[value_start..], "\r\n")) |end| {
                return std.mem.trim(u8, request[value_start .. value_start + end], " \t");
            }
        }
        return null;
    }

    pub fn broadcast(self: *Self, message: []const u8) void {
        self.clients_mutex.lock(self.io) catch return;
        defer self.clients_mutex.unlock(self.io);

        for (self.clients.items) |client| {
            client.sendText(message) catch |err| {
                std.log.err("[WebSocketServer] Broadcast error to client: {}", .{err});
            };
        }
    }

    pub fn clientCount(self: *Self) usize {
        self.clients_mutex.lock(self.io) catch return 0;
        defer self.clients_mutex.unlock(self.io);
        return self.clients.items.len;
    }

    pub fn onConnect(self: *Self, callback: *const fn (*WebSocketClient) void) void {
        self.on_connect_cb = callback;
    }

    pub fn onMessage(self: *Self, callback: *const fn (*WebSocketClient, []const u8) void) void {
        self.on_message_cb = callback;
    }
};

pub const WebSocketClient = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    io: std.Io,
    server: *WebSocketServer,
    is_connected: bool,

    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream, io: std.Io, server: *WebSocketServer) Self {
        return .{
            .allocator = allocator,
            .stream = stream,
            .io = io,
            .server = server,
            .is_connected = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.is_connected = false;
        self.stream.close(self.io);
    }

    pub fn run(self: *Self) void {
        var buf: [4096]u8 = undefined;
        var read_buf: [4096]u8 = undefined;
        var r = self.stream.reader(self.io, &read_buf);
        while (self.is_connected) {
            const frame = self.readFrame(&r, &buf) catch |err| {
                if (self.is_connected) {
                    std.log.debug("[WebSocketClient] Frame read error: {}", .{err});
                }
                break;
            };

            switch (frame.opcode) {
                0x1 => { // Text frame
                    if (self.server.on_message_cb) |cb| {
                        cb(self, frame.payload);
                    }
                },
                0x8 => { // Close frame
                    self.is_connected = false;
                    break;
                },
                0x9 => { // Ping
                    self.sendPong() catch {};
                },
                else => {},
            }
        }
    }

    const Frame = struct {
        opcode: u8,
        payload: []const u8,
    };

    fn readFull(r: *std.Io.net.Stream.Reader, buf: []u8) !void {
        _ = try r.interface.readSliceAll(buf);
    }

    fn readFrame(self: *Self, r: *std.Io.net.Stream.Reader, buf: []u8) !Frame {
        _ = self;
        var header: [2]u8 = undefined;
        try readFull(r, &header);

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: usize = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try readFull(r, &ext);
            payload_len = @as(usize, @intCast(std.mem.readInt(u16, &ext, .big)));
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try readFull(r, &ext);
            payload_len = @as(usize, @intCast(std.mem.readInt(u64, &ext, .big)));
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            try readFull(r, &mask_key);
        }

        if (payload_len > buf.len) return error.PayloadTooLarge;
        try readFull(r, buf[0..payload_len]);

        if (masked) {
            for (buf[0..payload_len], 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        return .{
            .opcode = opcode,
            .payload = buf[0..payload_len],
        };
    }

    pub fn sendText(self: *Self, payload: []const u8) !void {
        try self.sendFrame(0x1, payload);
    }

    pub fn sendJson(self: *Self, payload: []const u8) !void {
        try self.sendFrame(0x1, payload);
    }

    fn sendPong(self: *Self) !void {
        try self.sendFrame(0xA, &[_]u8{});
    }

    fn sendFrame(self: *Self, opcode: u8, payload: []const u8) !void {
        if (!self.is_connected) return error.NotConnected;

        var header_buf: [14]u8 = undefined;
        var header_len: usize = 2;

        header_buf[0] = 0x80 | opcode;

        if (payload.len < 126) {
            header_buf[1] = @intCast(payload.len);
        } else if (payload.len < 65536) {
            header_buf[1] = 126;
            std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header_buf[1] = 127;
            std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        var write_buf: [4096]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        _ = w.writeAll(header_buf[0..header_len]) catch return error.NotConnected;
        _ = w.writeAll(payload) catch return error.NotConnected;
    }
};

/// Integration with WebMonitor to provide real-time updates via WebSocket
pub const WebSocketMonitor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    ws_server: WebSocketServer,
    modules: ?*ApplicationModules,
    update_thread: ?std.Thread,
    is_running: bool,
    update_group: std.Io.Group,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) Self {
        return .{
            .allocator = allocator,
            .ws_server = WebSocketServer.init(allocator, io, port),
            .modules = null,
            .update_thread = null,
            .is_running = false,
            .update_group = .init,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();
        self.ws_server.deinit();
    }

    pub fn start(self: *Self, modules: *ApplicationModules) !void {
        self.modules = modules;
        try self.ws_server.start();
        self.is_running = true;
        self.update_thread = null;
        // Run update loop asynchronously, owned by `update_group` so its
        // future gets released on shutdown.
        self.update_group.async(self.ws_server.io, updateLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        self.ws_server.stop();
        self.update_thread = null;
        self.update_group.await(self.ws_server.io) catch {};
    }

    fn updateLoop(self: *Self) void {
        while (self.is_running) {
            self.broadcastMetrics() catch |err| {
                std.log.err("[WebSocketMonitor] Broadcast error: {}", .{err});
            };
            // Broadcast every 5 seconds
            std.Io.sleep(self.ws_server.io, .{ .nanoseconds = 5_000_000_000 }, .real) catch break;
        }
    }

    fn broadcastMetrics(self: *Self) !void {
        const module_count = if (self.modules) |m| m.modules.count() else 0;

        var json_buf: [1024]u8 = undefined;
        const json = try std.fmt.bufPrint(&json_buf, "{{\"type\":\"metrics\",\"module_count\":{d},\"clients\":{d},\"timestamp\":{d}}}", .{ module_count, self.ws_server.clientCount(), 0 });

        self.ws_server.broadcast(json);
    }
};

// ========================================
// Tests
// ========================================

test "WebSocketServer initialization" {
    const allocator = std.testing.allocator;
    var server = WebSocketServer.init(allocator, std.testing.io, 19001);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 19001), server.port);
    try std.testing.expectEqual(@as(usize, 0), server.clientCount());
}

test "WebSocketMonitor initialization" {
    const allocator = std.testing.allocator;
    var monitor = WebSocketMonitor.init(allocator, std.testing.io, 19002);
    defer monitor.deinit();

    try std.testing.expectEqual(@as(u16, 19002), monitor.ws_server.port);
}
