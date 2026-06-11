const std = @import("std");
const builtin = @import("builtin");

const linux = if (builtin.os.tag == .linux) std.os.linux else struct {
    pub const fd_t = i32;
    pub const io_uring_cqe = extern struct { user_data: u64 = 0, res: i32 = 0, flags: u32 = 0 };
    pub const io_uring_sqe = extern struct {
        opcode: u8 = 0, flags: u8 = 0, ioprio: u16 = 0, fd: i32 = 0,
        off: u64 = 0, addr: u64 = 0, len: u32 = 0, user_data: u64 = 0,
    };
    pub const IORING_OP_READ: u8 = 22;
    pub const IORING_OP_WRITE: u8 = 23;
    pub fn close(_: i32) void {}
    pub fn write(_: i32, _: [*]const u8, _: usize) usize { return 0; }
};
const IoUring = if (builtin.os.tag == .linux) std.os.linux.IoUring else struct {
    pub fn init(_: u16, _: u32) !@This() { return error.SystemOutdated; }
    pub fn deinit(_: *@This()) void {}
    pub fn get_sqe(_: *@This()) !*linux.io_uring_sqe { return error.SubmissionQueueFull; }
    pub fn submit(_: *@This()) !u32 { return 0; }
    pub fn copy_cqes(_: *@This(), _: []linux.io_uring_cqe, _: u32) !u32 { return 0; }
};

/// Callback types matching WsRoute in Server.zig
pub const OnMessageFn = *const fn (session: ?*anyopaque, msg: []const u8) void;
pub const OnCloseFn = *const fn (session: ?*anyopaque) void;

/// io_uring-based WebSocket event loop — Linux 5.1+ only.
/// Eliminates per-connection fiber stacks: each connection is a 4KB buffer + 120B state.
pub const WsUring = struct {
    const Self = @This();

    ring: IoUring,
    allocator: std.mem.Allocator,
    connections: std.AutoHashMap(i32, *Conn),
    running: std.atomic.Value(bool),
    max_conn: u32,
    thread: ?std.Thread = null,

    pub const Config = struct {
        max_connections: u32 = 8192,
    };

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Self {
        if (builtin.os.tag != .linux) @compileError("io_uring requires Linux 5.1+");

        const ring_size: u16 = @intCast(std.math.ceilPowerOfTwo(u16, @intCast(@min(cfg.max_connections * 2, 32768))) catch 512);
        const ring = try IoUring.init(ring_size, 0);
        return .{
            .ring = ring,
            .allocator = allocator,
            .connections = std.AutoHashMap(i32, *Conn).init(allocator),
            .running = std.atomic.Value(bool).init(false),
            .max_conn = cfg.max_connections,
        };
    }

    pub fn deinit(self: *Self) void {
        self.ring.deinit();
        {
            var it = self.connections.iterator();
            while (it.next()) |kv| {
                self.allocator.destroy(kv.value_ptr.*);
            }
        }
        self.connections.deinit();
        self.* = undefined;
    }

    /// Start the event loop in a dedicated thread.
    pub fn start(self: *Self) !void {
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Signal shutdown and wait for the event loop to exit.
    pub fn stop(self: *Self) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| t.join();
    }

    /// Transfer a WS connection (after handshake) from fiber to io_uring.
    /// Takes ownership of the fd — caller must NOT close it.
    pub fn adopt(self: *Self, fd: i32, session: *anyopaque, on_message: OnMessageFn, on_close: OnCloseFn) !void {
        if (self.connections.count() >= self.max_conn) return error.MaxConnections;

        const conn = try self.allocator.create(Conn);
        conn.* = .{
            .fd = fd,
            .session = session,
            .on_message = on_message,
            .on_close = on_close,
            .data_offset = 0,
            .data_len = 0,
        };
        try self.connections.put(fd, conn);

        // Submit initial read
        try self.submitRead(conn);
    }

    fn runLoop(self: *Self) void {
        var cqes: [64]linux.io_uring_cqe = undefined;

        while (self.running.load(.monotonic)) {
            _ = self.ring.submit() catch {};

            const count = self.ring.copy_cqes(&cqes, 0) catch {
                std.time.sleep(std.time.ns_per_ms);
                continue;
            };

            if (count == 0) {
                std.time.sleep(std.time.ns_per_ms);
                continue;
            }

            for (cqes[0..count]) |*cqe| {
                if (cqe.user_data == 0) continue;
                const fd: i32 = @intCast(cqe.user_data);
                const conn = self.connections.getPtr(fd) orelse continue;

                if (cqe.res <= 0) {
                    self.closeConn(conn, fd);
                    continue;
                }

                self.processData(conn, fd, @intCast(cqe.res));
            }
        }

        // Cleanup
        var it = self.connections.iterator();
        while (it.next()) |kv| {
            _ = linux.close(kv.key_ptr.*);
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.connections.clearRetainingCapacity();
    }

    /// Submit a 4KB read at the current buffer tail.
    fn submitRead(self: *Self, conn: *Conn) !void {
        const sqe = try self.ring.get_sqe();
        const sqe_bytes: [*]u8 = @ptrCast(sqe);
        @memset(sqe_bytes[0..@sizeOf(linux.io_uring_sqe)], 0);
        sqe.opcode = linux.IORING_OP_READ;
        sqe.fd = conn.fd;
        sqe.addr = @intFromPtr(&conn.buf[conn.data_offset + conn.data_len]);
        sqe.len = @intCast(Conn.BufSize - conn.data_offset - conn.data_len);
        sqe.user_data = @as(u64, @intCast(conn.fd));
    }

    /// Process newly read data. Parse all complete frames, submit next read.
    fn processData(self: *Self, conn: *Conn, fd: i32, bytes_read: usize) void {
        conn.data_len += bytes_read;
        var parse_offset: usize = conn.data_offset;
        var buf = conn.buf[parse_offset..][0..conn.data_len];

        while (true) {
            if (buf.len < 2) break; // Need more data for header

            const opcode = buf[0] & 0x0F;
            const masked = (buf[1] & 0x80) != 0;
            var payload_len: usize = buf[1] & 0x7F;
            var header_len: usize = 2;

            if (payload_len == 126) {
                if (buf.len < 4) break;
                payload_len = std.mem.readInt(u16, buf[2..4], .big);
                header_len = 4;
            } else if (payload_len == 127) {
                if (buf.len < 10) break;
                payload_len = @intCast(std.mem.readInt(u64, buf[2..10], .big));
                header_len = 10;
            }

            var mask_offset: usize = 0;
            if (masked) {
                if (buf.len < header_len + 4) break;
                mask_offset = 4;
            }

            const frame_total = header_len + mask_offset + payload_len;
            if (buf.len < frame_total) break; // Incomplete frame

            // Parse mask
            var mask_key: [4]u8 = undefined;
            if (masked) {
                mask_key = buf[header_len..][0..4].*;
            }

            // Extract payload
            const payload = buf[header_len + mask_offset .. frame_total];
            if (masked) {
                for (payload, 0..) |*b, i| {
                    b.* ^= mask_key[i % 4];
                }
            }

            // Dispatch frame
            switch (opcode) {
                0x1 => if (conn.on_message != 0) conn.on_message(conn.session, payload),
                0x8 => { self.closeConn(conn, fd); return; },
                0x9 => { // Ping → Pong
                    self.sendPong(fd, payload) catch {};
                },
                else => {},
            }

            // Advance past this frame
            buf = buf[frame_total..];
            parse_offset += frame_total;
        }

        // Compact: move remaining partial data to start of buffer
        conn.data_offset = 0;
        conn.data_len = buf.len;
        if (buf.len > 0 and parse_offset > 0) {
            std.mem.copyForwards(u8, conn.buf[0..buf.len], buf);
        }

        // Submit next read
        self.submitRead(conn) catch self.closeConn(conn, fd);
    }

    /// Write a pong frame via direct syscall (small, infrequent).
    fn sendPong(self: *Self, fd: i32, payload: []const u8) !void {
        _ = self;
        var header: [6]u8 = undefined;
        header[0] = 0x80 | 0xA;
        header[1] = @intCast(payload.len);
        _ = linux.write(fd, &header, 2);
        if (payload.len > 0) _ = linux.write(fd, payload.ptr, payload.len);
    }

    fn closeConn(self: *Self, conn: *Conn, fd: i32) void {
        if (conn.on_close != 0) conn.on_close(conn.session);
        _ = self.connections.remove(fd);
        _ = linux.close(fd);
        self.allocator.destroy(conn);
    }
};

const Conn = struct {
    const BufSize = 4096;

    fd: i32,
    session: *anyopaque,
    on_message: OnMessageFn,
    on_close: OnCloseFn,
    buf: [BufSize]u8 = undefined,
    data_offset: usize = 0, // Start of valid data in buf
    data_len: usize = 0, // Amount of valid data starting at data_offset
};
