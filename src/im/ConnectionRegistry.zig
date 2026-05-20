const std = @import("std");

/// Lightweight userId-to-connection registry for IM routing.
/// Uses std.Io.Mutex for fiber-safe synchronization.
///
/// Heartbeat tracking: each connection has a tick counter that gets reset
/// on heartbeat(). cleanupTimeout() removes connections whose tick is behind
/// the current tick by more than the allowed gap.
pub const ConnectionRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    /// userId → connection entry
    by_user: std.AutoHashMap(u64, *ConnectionEntry),
    /// connectionId → *ConnectionEntry
    by_conn: std.AutoHashMap(u32, *ConnectionEntry),
    mutex: std.Io.Mutex,
    next_id: u32,
    /// Monotonic tick, incremented on each heartbeat sweep
    tick: u64,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return .{
            .allocator = allocator,
            .io = io,
            .by_user = std.AutoHashMap(u64, *ConnectionEntry).init(allocator),
            .by_conn = std.AutoHashMap(u32, *ConnectionEntry).init(allocator),
            .mutex = std.Io.Mutex.init,
            .next_id = 1,
            .tick = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        {
            var it = self.by_user.iterator();
            while (it.next()) |kv| {
                self.allocator.destroy(kv.value_ptr.*);
            }
        }
        self.by_user.deinit();
        self.by_conn.deinit();
    }

    /// Register a user connection. Replaces old connection if user already connected.
    /// Returns the assigned connection id, or 0 on allocation failure.
    pub fn register(self: *Self, user_id: u64, ctx: *anyopaque, send_fn: SendFn) u32 {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        if (self.by_user.getPtr(user_id)) |existing| {
            _ = self.by_conn.remove(existing.*.conn_id);
            self.allocator.destroy(existing.*);
        }

        const conn_id = self.next_id;
        self.next_id += 1;

        const entry = self.allocator.create(ConnectionEntry) catch return 0;
        entry.* = .{
            .conn_id = conn_id,
            .user_id = user_id,
            .ctx = ctx,
            .send_fn = send_fn,
            .last_tick = self.tick,
            .is_connected = true,
        };

        self.by_user.put(user_id, entry) catch {
            self.allocator.destroy(entry);
            return 0;
        };
        self.by_conn.put(conn_id, entry) catch {};
        return conn_id;
    }

    /// Remove a user's connection.
    pub fn unregister(self: *Self, user_id: u64) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (self.by_user.fetchRemove(user_id)) |kv| {
            _ = self.by_conn.remove(kv.value.conn_id);
            kv.value.is_connected = false;
            self.allocator.destroy(kv.value);
        }
    }

    /// Unregister by connection id.
    pub fn unregisterByConn(self: *Self, conn_id: u32) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (self.by_conn.fetchRemove(conn_id)) |kv| {
            _ = self.by_user.remove(kv.value.user_id);
            kv.value.is_connected = false;
            self.allocator.destroy(kv.value);
        }
    }

    /// Send a text message to a specific user. Returns true if delivered.
    pub fn sendToUser(self: *Self, user_id: u64, msg: []const u8) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);

        const entry = self.by_user.getPtr(user_id) orelse return false;
        if (!entry.*.is_connected) return false;

        entry.*.send_fn(entry.*.ctx, msg) catch {
            entry.*.is_connected = false;
            return false;
        };
        return true;
    }

    /// Send a message to multiple users. Returns count of successful deliveries.
    pub fn sendToUsers(self: *Self, user_ids: []const u64, msg: []const u8) usize {
        var count: usize = 0;
        for (user_ids) |uid| {
            if (self.sendToUser(uid, msg)) count += 1;
        }
        return count;
    }

    /// Check if a user is online.
    pub fn isOnline(self: *Self, user_id: u64) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);

        const entry = self.by_user.getPtr(user_id) orelse return false;
        return entry.*.is_connected;
    }

    /// Update heartbeat for a connection. Call from ping/pong handler.
    pub fn heartbeat(self: *Self, conn_id: u32) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (self.by_conn.getPtr(conn_id)) |entry| {
            entry.*.last_tick = self.tick;
        }
    }

    /// Advance tick and remove connections that haven't kept up within `max_gap` ticks.
    /// Returns the number of connections cleaned up.
    pub fn tickAndCleanup(self: *Self, max_gap: u64) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        self.tick += 1;
        const current = self.tick;
        var dead: [64]u64 = undefined;
        var dead_len: usize = 0;
        var count: usize = 0;

        var it = self.by_user.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr.*;
            if (!entry.is_connected or (current - entry.last_tick) > max_gap) {
                if (dead_len < dead.len) {
                    dead[dead_len] = kv.key_ptr.*;
                    dead_len += 1;
                }
            }
        }

        for (dead[0..dead_len]) |user_id| {
            if (self.by_user.fetchRemove(user_id)) |kv| {
                _ = self.by_conn.remove(kv.value.conn_id);
                self.allocator.destroy(kv.value);
                count += 1;
            }
        }

        return count;
    }

    /// Return total online count.
    pub fn onlineCount(self: *Self) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.by_user.count();
    }

    /// Get list of online user IDs (up to max, returns total written).
    pub fn onlineUsers(self: *Self, buf: []u64) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        var count: usize = 0;
        var it = self.by_user.iterator();
        while (it.next()) |kv| {
            if (count >= buf.len) break;
            if (kv.value_ptr.*.is_connected) {
                buf[count] = kv.key_ptr.*;
                count += 1;
            }
        }
        return count;
    }
};

/// Function pointer type: send a text message to a specific connection context.
pub const SendFn = *const fn (ctx: *anyopaque, msg: []const u8) anyerror!void;

const ConnectionEntry = struct {
    conn_id: u32,
    user_id: u64,
    ctx: *anyopaque,
    send_fn: SendFn,
    last_tick: u64,
    is_connected: bool,
};

test "register unregister" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var dummy: u8 = 0;
    try std.testing.expectEqual(@as(usize, 0), reg.onlineCount());
    try std.testing.expect(!reg.isOnline(1));

    const id = reg.register(1, @ptrCast(&dummy), testSendFn);
    try std.testing.expect(id > 0);
    try std.testing.expect(reg.isOnline(1));
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());

    reg.unregister(1);
    try std.testing.expect(!reg.isOnline(1));
    try std.testing.expectEqual(@as(usize, 0), reg.onlineCount());
}

test "sendToUser offline returns false" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    try std.testing.expect(!reg.sendToUser(999, "hello"));
}

test "tickAndCleanup with heartbeat keeps connections alive" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var dummy: u8 = 0;
    const cid = reg.register(1, @ptrCast(&dummy), testSendFn);
    try std.testing.expect(cid > 0);
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());

    // Heartbeat to update last_tick to current tick (0)
    reg.heartbeat(cid);

    // Advance tick with gap=0 — should NOT clean (tick becomes 1, gap=0, 1-0=1 > 0 → cleaned!)
    // Hmm: tick=0, last_tick=0 after heartbeat.
    // tickAndCleanup(0): tick=1, check: 1-0=1 > 0 → true → cleaned
    // So with gap=0 only connections that are heartbeat'd AFTER the tick is advanced survive.
    // This is a known quirk: gap=0 means "must have heartbeat since last tick".

    // Use gap=2 to have some slack
    _ = reg.tickAndCleanup(2); // tick=1, gap check: 1-0=1 > 2? No → survive
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());

    // heartbeat again to reset
    reg.heartbeat(cid);
    _ = reg.tickAndCleanup(2); // tick=2, gap: 2-1=1 > 2? No
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());

    // Without heartbeat, after several ticks → cleaned
    _ = reg.tickAndCleanup(1); // tick=3, gap=1, 3-1=2 > 1? Yes → cleaned
    try std.testing.expectEqual(@as(usize, 0), reg.onlineCount());
}

fn testSendFn(ctx: *anyopaque, msg: []const u8) anyerror!void {
    _ = ctx;
    _ = msg;
}
