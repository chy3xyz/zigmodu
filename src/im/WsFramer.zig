const std = @import("std");

/// Minimal WebSocket frame reader/writer.
pub const WsFramer = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    /// Optional pre-allocated write buffer for frame output.
    /// If null, writeFrame stack-allocates a 4KB buffer per call.
    write_buf: ?[]u8 = null,

    pub fn init(stream: std.Io.net.Stream, io: std.Io) WsFramer {
        return .{ .stream = stream, .io = io };
    }

    pub fn setWriteBuffer(self: *WsFramer, buf: []u8) void {
        self.write_buf = buf;
    }

    /// RFC 6455 handshake using a small stack buffer (one-shot).
    pub fn handshake(self: *WsFramer, ws_key: []const u8) !void {
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var hash_input: [128]u8 = undefined;
        const hash_len = ws_key.len + magic.len;
        @memcpy(hash_input[0..ws_key.len], ws_key);
        @memcpy(hash_input[ws_key.len..hash_len], magic);

        var sha1 = std.crypto.hash.Sha1.init(.{});
        sha1.update(hash_input[0..hash_len]);
        var digest: [20]u8 = undefined;
        sha1.final(&digest);

        var accept_key: [28]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&accept_key, &digest);

        var buf: [256]u8 = undefined;
        const response = try std.fmt.bufPrint(&buf,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n", .{accept_key});

        var write_buf: [512]u8 = undefined;
        var w = self.stream.writer(self.io, &write_buf);
        try w.interface.writeAll(response);
        try w.interface.flush();
    }

    pub const Frame = struct {
        opcode: u8,
        payload: []u8,
        payload_len: usize,
    };

    /// Read one WebSocket frame. `buf` must be at least 4KB (caller provided).
    pub fn readFrame(self: *WsFramer, buf: []u8) !Frame {
        var header: [2]u8 = undefined;
        try readFull(self.stream, self.io, &header);

        const opcode = header[0] & 0x0F;
        const masked = (header[1] & 0x80) != 0;
        var payload_len: usize = header[1] & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try readFull(self.stream, self.io, &ext);
            payload_len = @intCast(std.mem.readInt(u16, &ext, .big));
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try readFull(self.stream, self.io, &ext);
            payload_len = @intCast(std.mem.readInt(u64, &ext, .big));
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            try readFull(self.stream, self.io, &mask_key);
        }

        if (payload_len > buf.len) return error.PayloadTooLarge;
        try readFull(self.stream, self.io, buf[0..payload_len]);

        if (masked) {
            for (buf[0..payload_len], 0..) |*b, i| {
                b.* ^= mask_key[i % 4];
            }
        }

        return .{ .opcode = opcode, .payload = buf[0..payload_len], .payload_len = payload_len };
    }

    /// Write a text frame.
    pub fn writeText(self: *WsFramer, payload: []const u8) !void {
        try self.writeFrame(0x1, payload);
    }

    /// Write an arbitrary frame. Uses pre-allocated write_buf if set.
    pub fn writeFrame(self: *WsFramer, opcode: u8, payload: []const u8) !void {
        var header: [14]u8 = undefined;
        var header_len: usize = 2;
        header[0] = 0x80 | opcode;

        if (payload.len < 126) {
            header[1] = @intCast(payload.len);
        } else if (payload.len < 65536) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
            header_len = 10;
        }

        if (self.write_buf) |buf| {
            var w = self.stream.writer(self.io, buf);
            try w.interface.writeAll(header[0..header_len]);
            try w.interface.writeAll(payload);
            try w.interface.flush();
        } else {
            var write_buf: [4096]u8 = undefined;
            var w = self.stream.writer(self.io, &write_buf);
            try w.interface.writeAll(header[0..header_len]);
            try w.interface.writeAll(payload);
            try w.interface.flush();
        }
    }

    /// Write a pong frame.
    pub fn writePong(self: *WsFramer, payload: []const u8) !void {
        try self.writeFrame(0xA, payload);
    }

    /// Write a close frame.
    pub fn writeClose(self: *WsFramer) !void {
        try self.writeFrame(0x8, &.{});
    }
};

fn readFull(stream: std.Io.net.Stream, io: std.Io, buf: []u8) !void {
    var read_buf: [4096]u8 = undefined;
    var r = stream.reader(io, &read_buf);
    _ = try r.interface.readSliceAll(buf);
}

test "handshake" {
    _ = WsFramer.init(undefined, undefined);
}

test "write with and without buffer" {
    _ = WsFramer.init(undefined, undefined);
}
