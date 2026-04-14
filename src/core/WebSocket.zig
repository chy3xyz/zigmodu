const std = @import("std");
const ApplicationModules = @import("Module.zig").ApplicationModules;

/// WebSocket support for real-time monitoring
/// Provides RFC 6455 WebSocket server functionality for live module updates
pub const WebSocketServer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    port: u16,
    server: ?std.net.Server,
    is_running: bool,
    clients: std.array_list.Managed(*WebSocketClient),
    clients_mutex: std.Thread.Mutex,
    on_connect_cb: ?*const fn (*WebSocketClient) void,
    on_message_cb: ?*const fn (*WebSocketClient, []const u8) void,

    pub fn init(allocator: std.mem.Allocator, port: u16) Self {
        return .{
            .allocator = allocator,
            .port = port,
            .server = null,
            .is_running = false,
            .clients = std.array_list.Managed(*WebSocketClient).init(allocator),
            .clients_mutex = .{},
            .on_connect_cb = null,
            .on_message_cb = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (self.clients.items) |client| {
            client.deinit();
            self.allocator.destroy(client);
        }
        self.clients.deinit();
    }

    pub fn start(self: *Self) !void {
        if (self.is_running) return;

        const address = try std.net.Address.parseIp4("0.0.0.0", self.port);
        self.server = try address.listen(.{ .reuse_address = true });
        self.is_running = true;

        std.log.info("[WebSocketServer] Started on ws://0.0.0.0:{d}", .{self.port});

        const thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        thread.detach();
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
    }

    fn acceptLoop(self: *Self) void {
        while (self.is_running) {
            if (self.server) |*s| {
                const conn = s.accept() catch |err| {
                    if (self.is_running) {
                        std.log.err("[WebSocketServer] Accept error: {}", .{err});
                    }
                    continue;
                };

                const thread = std.Thread.spawn(.{}, handleConnection, .{ self, conn }) catch |err| {
                    std.log.err("[WebSocketServer] Failed to spawn thread: {}", .{err});
                    conn.stream.close();
                    continue;
                };
                thread.detach();
            }
        }
    }

    fn handleConnection(self: *Self, conn: std.net.Server.Connection) void {
        defer conn.stream.close();

        var buf: [4096]u8 = undefined;
        const bytes_read = conn.stream.read(&buf) catch |err| {
            std.log.err("[WebSocketServer] Read error: {}", .{err});
            return;
        };

        if (bytes_read == 0) return;
        const request = buf[0..bytes_read];

        // Parse WebSocket key from headers
        const ws_key = extractHeaderValue(request, "Sec-WebSocket-Key: ") orelse {
            // Not a WebSocket upgrade request - send HTTP response
            const response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n";
            _ = conn.stream.write(response) catch {};
            return;
        };

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
            "\r\n", .{&accept_key}) catch return;

        _ = conn.stream.write(response) catch |err| {
            std.log.err("[WebSocketServer] Handshake write error: {}", .{err});
            return;
        };

        // Create client
        const client = self.allocator.create(WebSocketClient) catch |err| {
            std.log.err("[WebSocketServer] Failed to allocate client: {}", .{err});
            return;
        };
        errdefer self.allocator.destroy(client);

        client.* = WebSocketClient.init(self.allocator, conn.stream, self);

        self.clients_mutex.lock();
        self.clients.append(client) catch |err| {
            self.clients_mutex.unlock();
            std.log.err("[WebSocketServer] Failed to add client: {}", .{err});
            client.deinit();
            self.allocator.destroy(client);
            return;
        };
        self.clients_mutex.unlock();

        if (self.on_connect_cb) |cb| {
            cb(client);
        }

        client.run();

        // Remove client after disconnect
        self.clients_mutex.lock();
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.orderedRemove(i);
                break;
            }
        }
        self.clients_mutex.unlock();

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
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();

        for (self.clients.items) |client| {
            client.sendText(message) catch |err| {
                std.log.err("[WebSocketServer] Broadcast error to client: {}", .{err});
            };
        }
    }

    pub fn clientCount(self: *Self) usize {
        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
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
    stream: std.net.Stream,
    server: *WebSocketServer,
    is_connected: bool,

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream, server: *WebSocketServer) Self {
        return .{
            .allocator = allocator,
            .stream = stream,
            .server = server,
            .is_connected = true,
        };
    }

    pub fn deinit(self: *Self) void {
        self.is_connected = false;
        self.stream.close();
    }

    pub fn run(self: *Self) void {
        var buf: [4096]u8 = undefined;
        while (self.is_connected) {
            const frame = self.readFrame(&buf) catch |err| {
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

    fn readFull(self: *Self, buf: []u8) !void {
        var read_count: usize = 0;
        while (read_count < buf.len) {
            const n = try self.stream.read(buf[read_count..]);
            if (n == 0) return error.ConnectionClosed;
            read_count += n;
        }
    }

    fn readFrame(self: *Self, buf: []u8) !Frame {
        var header: [2]u8 = undefined;
        const h1 = self.stream.read(&header) catch |err| return err;
        if (h1 < 2) return error.InvalidFrame;

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: usize = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try self.readFull(&ext);
            payload_len = @as(usize, @intCast(std.mem.readInt(u16, &ext, .big)));
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try self.readFull(&ext);
            payload_len = @as(usize, @intCast(std.mem.readInt(u64, &ext, .big)));
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            try self.readFull(&mask_key);
        }

        if (payload_len > buf.len) return error.PayloadTooLarge;
        try self.readFull(buf[0..payload_len]);

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

        _ = try self.stream.write(header_buf[0..header_len]);
        _ = try self.stream.write(payload);
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

    pub fn init(allocator: std.mem.Allocator, port: u16) Self {
        return .{
            .allocator = allocator,
            .ws_server = WebSocketServer.init(allocator, port),
            .modules = null,
            .update_thread = null,
            .is_running = false,
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

        self.update_thread = try std.Thread.spawn(.{}, updateLoop, .{self});
    }

    pub fn stop(self: *Self) void {
        self.is_running = false;
        self.ws_server.stop();
        if (self.update_thread) |t| {
            t.join();
            self.update_thread = null;
        }
    }

    fn updateLoop(self: *Self) void {
        while (self.is_running) {
            self.broadcastMetrics() catch |err| {
                std.log.err("[WebSocketMonitor] Broadcast error: {}", .{err});
            };
            std.Thread.sleep(5 * std.time.ns_per_s);
        }
    }

    fn broadcastMetrics(self: *Self) !void {
        const module_count = if (self.modules) |m| m.modules.count() else 0;

        var json_buf: [1024]u8 = undefined;
        const json = try std.fmt.bufPrint(&json_buf, "{{\"type\":\"metrics\",\"module_count\":{d},\"clients\":{d},\"timestamp\":{d}}}", .{ module_count, self.ws_server.clientCount(), std.time.timestamp() });

        self.ws_server.broadcast(json);
    }
};

// ========================================
// Tests
// ========================================

test "WebSocketServer initialization" {
    const allocator = std.testing.allocator;
    var server = WebSocketServer.init(allocator, 19001);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 19001), server.port);
    try std.testing.expectEqual(@as(usize, 0), server.clientCount());
}

test "WebSocketMonitor initialization" {
    const allocator = std.testing.allocator;
    var monitor = WebSocketMonitor.init(allocator, 19002);
    defer monitor.deinit();

    try std.testing.expectEqual(@as(u16, 19002), monitor.ws_server.port);
}
