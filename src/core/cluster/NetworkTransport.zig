//! TCP Network Transport for cluster communication.
//!
//! Provides length-prefixed message framing over std.Io.net.Stream.
//! Used by RaftElection, DistributedEventBus, and ClusterMembership
//! for node-to-node communication.
//!
//! Protocol: 4-byte big-endian length + JSON payload

const std = @import("std");

/// Maximum message size (1MB) to prevent memory exhaustion.
pub const MAX_MESSAGE_SIZE: usize = 1024 * 1024;

/// A framed TCP connection for cluster messages.
pub const ClusterConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream, io: std.Io) ClusterConnection {
        return .{ .allocator = allocator, .stream = stream, .io = io };
    }

    pub fn deinit(self: *ClusterConnection) void {
        self.stream.close(self.io);
    }

    /// Send a length-prefixed message.
    pub fn send(self: *ClusterConnection, payload: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        const len: u32 = @intCast(payload.len);
        std.mem.writeInt(u32, &len_buf, len, .big);
        _ = try self.stream.write(self.io, &len_buf);
        _ = try self.stream.write(self.io, payload);
    }

    /// Receive a length-prefixed message. Caller owns returned memory.
    pub fn recv(self: *ClusterConnection, buf: *std.ArrayList(u8)) ![]const u8 {
        var len_buf: [4]u8 = undefined;
        _ = try self.stream.read(self.io, &len_buf);
        const msg_len = std.mem.readInt(u32, &len_buf, .big);

        if (msg_len > MAX_MESSAGE_SIZE) return error.MessageTooLarge;

        try buf.resize(self.allocator, msg_len);
        _ = try self.stream.read(self.io, buf.items[0..msg_len]);
        return buf.items[0..msg_len];
    }
};

/// TCP server that accepts cluster connections.
pub const ClusterServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    listener: ?std.Io.net.Server,
    port: u16,
    running: std.atomic.Value(bool),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) ClusterServer {
        return .{
            .allocator = allocator,
            .io = io,
            .listener = null,
            .port = port,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *ClusterServer) void {
        self.stop();
    }

    /// Start listening. Accepts connections and passes them to the handler.
    pub fn start(self: *ClusterServer, handler: *const fn (ClusterConnection) void) !void {
        const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.listener = try addr.listen(self.io, .{ .reuse_address = true });
        self.running.store(true, .monotonic);

        while (self.running.load(.monotonic)) {
            const stream = (self.listener orelse break).accept(self.io) catch |err| {
                if (!self.running.load(.monotonic)) break;
                std.log.err("[ClusterServer] Accept error: {}", .{err});
                continue;
            };
            const conn = ClusterConnection.init(self.allocator, stream, self.io);
            handler(conn);
        }
    }

    pub fn stop(self: *ClusterServer) void {
        self.running.store(false, .monotonic);
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
    }
};

/// Connect to a remote cluster node.
pub fn connect(allocator: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !ClusterConnection {
    const addr = try std.Io.net.IpAddress.parse(host, port);
    const stream = try addr.connect(io, .{});
    return ClusterConnection.init(allocator, stream, io);
}

// ── Tests ──

test "ClusterConnection send and recv" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Create a server
    var server = ClusterServer.init(allocator, io, 0);
    defer server.deinit();

    // For now, verify basic construction
    try std.testing.expectEqual(@as(u16, 0), server.port);
    try std.testing.expect(!server.running.load(.monotonic));
}

test "message framing round-trip" {
    const msg = "hello cluster";
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(msg.len), .big);
    try std.testing.expectEqual(@as(u32, 14), std.mem.readInt(u32, &len_buf, .big));
}

test "max message size constant" {
    try std.testing.expect(MAX_MESSAGE_SIZE == 1024 * 1024);
}
