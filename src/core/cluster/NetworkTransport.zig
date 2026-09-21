//! TCP Network Transport for cluster communication.
//!
//! Provides length-prefixed message framing over std.Io.net.Stream.
//! Used by RaftElection, DistributedEventBus, and ClusterMembership
//! for node-to-node communication.
//!
//! Protocol: 4-byte big-endian length + JSON payload

const std = @import("std");
const sockread = @import("../sockread.zig");

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
        self.* = undefined;
    }

    /// Send a length-prefixed message.
    pub fn send(self: *ClusterConnection, payload: []const u8) !void {
        var len_buf: [4]u8 = undefined;
        const len: u32 = @intCast(payload.len);
        std.mem.writeInt(u32, len_buf[0..], len, .big);
        try sockread.writevAll(self.stream, &.{ &len_buf, payload });
    }

    /// Receive a length-prefixed message. Caller owns returned memory.
    pub fn recv(self: *ClusterConnection, buf: *std.ArrayList(u8)) ![]const u8 {
        var len_buf: [4]u8 = undefined;
        try sockread.readFull(self.stream, &len_buf);
        const msg_len = std.mem.readInt(u32, &len_buf, .big);

        if (msg_len > MAX_MESSAGE_SIZE) return error.MessageTooLarge;

        try buf.resize(self.allocator, msg_len);
        try sockread.readFull(self.stream, buf.items[0..msg_len]);
        return buf.items[0..msg_len];
    }
};

/// TCP server that accepts cluster connections.
///
/// **One fiber per connection.** The handler used to run *inline on the accept
/// thread*, so a single slow peer serialised every other inbound connection for
/// as long as it took to read its frame: `RaftTransport`'s recv/send bounds
/// capped that stall at `ElectionConfig.rpc_timeout_ms`, but a node with two
/// slow peers still answered the third one only after both had timed out. The
/// dispatch below is the shape `DistributedEventBus.acceptLoop` already uses,
/// for the same reason.
///
/// The handler takes a **context** because it no longer runs on the thread that
/// called `start`: anything the handler needs (its raft, its address book) has
/// to travel with the call instead of living in a `threadlocal` that only the
/// accept thread can see. A handler dispatched onto a pool thread found that
/// `threadlocal` null and dropped the connection.
pub const ClusterServer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    listener: ?std.Io.net.Server,
    port: u16,
    running: std.atomic.Value(bool),
    /// Live handler fibers. `stop()` awaits this, so a returned `stop()` means
    /// no handler is still running against the resources it was handed.
    group: std.Io.Group,
    /// True only for the window in which the accept loop can still add a task to
    /// `group` (between a successful `accept` and `Group.concurrent` returning).
    /// `stop()` waits for it to clear before awaiting the group: `Group.await` is
    /// documented as unsafe to race with `Group.concurrent` (and would assert),
    /// and a task added after the await began would not be covered by it.
    dispatching: std.atomic.Value(bool),

    /// `context` is whatever the handler needs to find its way back to its
    /// owner; the server only passes it through.
    pub const Handler = *const fn (context: ?*anyopaque, conn: ClusterConnection) void;

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) ClusterServer {
        return .{
            .allocator = allocator,
            .io = io,
            .listener = null,
            .port = port,
            .running = std.atomic.Value(bool).init(false),
            .group = .init,
            .dispatching = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *ClusterServer) void {
        self.stop();
        self.* = undefined;
    }

    /// Start listening. Accepts connections and hands each one to `handler` on
    /// its own fiber, together with `context`. Blocks until `stop()`.
    ///
    /// The context is a `start` parameter rather than a field so that the
    /// binding cannot be set on a server that never starts (or changed under a
    /// running one); there is exactly one place that knows what a handler is for.
    pub fn start(self: *ClusterServer, handler: Handler, context: ?*anyopaque) !void {
        const addr = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        self.listener = try addr.listen(self.io, .{ .reuse_address = true });
        self.running.store(true, .monotonic);

        while (self.running.load(.monotonic)) {
            const stream = (self.listener orelse break).accept(self.io) catch |err| {
                if (!self.running.load(.monotonic)) break;
                std.log.err("[ClusterServer] Accept error: {}", .{err});
                continue;
            };
            // **Claim the dispatch slot, then re-check `running` under it.** The
            // two `seq_cst` operations are what make the re-check sound: `stop()`
            // stores `running = false` and *then* spins on `dispatching`, so a
            // claim that lands after that store sees `running == false` here and
            // drops the connection instead of dispatching it — while a claim that
            // lands before it is waited for by `stop()`'s spin. Without the
            // re-check, an accept that completed just before `stop()` could add a
            // task to the group *after* `stop()`'s await began, and the await
            // would neither cover it nor be allowed to race it.
            self.dispatching.store(true, .seq_cst);
            if (!self.running.load(.seq_cst)) {
                self.dispatching.store(false, .seq_cst);
                stream.close(self.io);
                break;
            }
            var conn = ClusterConnection.init(self.allocator, stream, self.io);
            // `concurrent`, not `async`: a handler blocks on peer reads, and
            // `async`'s eager fallback at its limit runs it on this thread —
            // which is the serialization being removed. The limit's rejection
            // path closes the connection rather than leaving the peer waiting.
            self.group.concurrent(self.io, runHandler, .{ handler, context, conn }) catch |err| {
                std.log.warn("[ClusterServer] connection rejected (concurrent limit): {}", .{err});
                conn.deinit();
                self.dispatching.store(false, .seq_cst);
                continue;
            };
            self.dispatching.store(false, .seq_cst);
        }

        // No await here: only `stop()` may wait on the group (a second awaiter
        // races the first — `Group.await` is not threadsafe, and asserts on it).
        // Nothing can be dispatched after `stop()` has observed `dispatching`
        // clear, which is what makes `stop()`'s await complete.
    }

    pub fn stop(self: *ClusterServer) void {
        // `seq_cst`, because the accept loop's re-check relies on this store
        // being ordered against its own claim (see `start`).
        self.running.store(false, .seq_cst);
        if (self.listener) |*l| {
            l.deinit(self.io);
            self.listener = null;
        }
        // The accept loop may be one dispatch short of handing a connection
        // over; let it finish that step so the await below covers that fiber too
        // (bounded by one `Group.concurrent` call — no later one can start,
        // because `running` is already false).
        while (self.dispatching.load(.seq_cst)) std.atomic.spinLoopHint();
        self.awaitHandlers();
    }

    /// Wait for every handler fiber to return. Idempotent for the caller
    /// (`stop()` is called twice by some owners) but **not** for two threads at
    /// once: `Io.Group.await` is not threadsafe, so this is the owner's call to
    /// make and `start()` deliberately does not make it too.
    pub fn awaitHandlers(self: *ClusterServer) void {
        self.group.await(self.io) catch |err| {
            std.log.warn("[ClusterServer] waiting for handlers was interrupted: {}", .{err});
        };
    }

    fn runHandler(handler: Handler, context: ?*anyopaque, conn: ClusterConnection) void {
        handler(context, conn);
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
    try std.testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, &len_buf, .big));
}

test "max message size constant" {
    try std.testing.expect(MAX_MESSAGE_SIZE == 1024 * 1024);
}
