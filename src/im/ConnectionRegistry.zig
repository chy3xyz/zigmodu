const std = @import("std");

/// Shard count — power of 2 for fast modulo (user_id & (SHARDS-1)).
const SHARDS = 64;

/// UserId-to-connection registry for IM routing.
/// Sharded by user_id: concurrent operations on different shards
/// don't contend. Each shard has its own mutex and tick counter.
pub const ConnectionRegistry = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    shards: [SHARDS]Shard,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
        return initCapacity(allocator, io, 1024);
    }

    /// Init with capacity hint (max connections per shard). Pre-allocates
    /// HashMap storage so runtime register() is infallible for map ops.
    pub fn initCapacity(allocator: std.mem.Allocator, io: std.Io, capacity_per_shard: usize) Self {
        var self = Self{
            .allocator = allocator,
            .io = io,
            .shards = undefined,
        };
        for (&self.shards, 0..) |*s, i| {
            s.* = Shard.initCapacity(allocator, io, @intCast(i), capacity_per_shard);
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (&self.shards) |*s| s.deinit();
        self.* = undefined;
    }

    fn shard(self: *Self, user_id: u64) *Shard {
        return &self.shards[user_id & (SHARDS - 1)];
    }

    /// Register a user connection. Replaces old connection.
    ///
    /// Returns the new connection id, or **0 for failure** (pool exhausted, or
    /// the shard lock could not be taken). A *successful* registration never
    /// returns 0 — `firstId` reserves it — which is what makes the check
    /// `if (conn_id == 0) { /* failed */ }` safe. It was not always: shard 0's id
    /// window starts at 0, so its first connection looked exactly like a failure,
    /// and a caller that freed the session on 0 left `by_user` pointing at freed
    /// memory (the next `sendToUser` was a use-after-free).
    pub fn register(self: *Self, user_id: u64, ctx: *anyopaque, send_fn: SendFn) u32 {
        return self.shard(user_id).register(self.allocator, user_id, ctx, send_fn);
    }

    /// Remove a user's connection.
    pub fn unregister(self: *Self, user_id: u64) void {
        self.shard(user_id).unregister(self.allocator, user_id);
    }

    /// Unregister by connection id.
    pub fn unregisterByConn(self: *Self, conn_id: u32) void {
        for (&self.shards) |*s| {
            if (s.unregisterByConn(self.allocator, conn_id)) return;
        }
    }

    /// Send a text message to a specific user. Returns true if delivered.
    pub fn sendToUser(self: *Self, user_id: u64, msg: []const u8) bool {
        return self.shard(user_id).sendToUser(user_id, msg);
    }

    /// Send a message to multiple users.
    pub fn sendToUsers(self: *Self, user_ids: []const u64, msg: []const u8) usize {
        var count: usize = 0;
        for (user_ids) |uid| {
            if (self.sendToUser(uid, msg)) count += 1;
        }
        return count;
    }

    /// Check if a user is online.
    pub fn isOnline(self: *Self, user_id: u64) bool {
        return self.shard(user_id).isOnline(user_id);
    }

    /// Update heartbeat for a connection.
    pub fn heartbeat(self: *Self, conn_id: u32) void {
        for (&self.shards) |*s| {
            s.heartbeat(conn_id);
        }
    }

    /// Advance tick on ALL shards and remove stale connections.
    pub fn tickAndCleanup(self: *Self, max_gap: u64) usize {
        var count: usize = 0;
        for (&self.shards) |*s| {
            count += s.tickAndCleanup(self.allocator, max_gap);
        }
        return count;
    }

    pub fn onlineCount(self: *Self) usize {
        var count: usize = 0;
        for (&self.shards) |*s| {
            count += s.onlineCount();
        }
        return count;
    }

    pub fn onlineUsers(self: *Self, buf: []u64) usize {
        var count: usize = 0;
        for (&self.shards) |*s| {
            count += s.onlineUsers(buf[count..]);
            if (count >= buf.len) break;
        }
        return count;
    }
};

pub const SendFn = *const fn (ctx: *anyopaque, msg: []const u8) anyerror!void;

const Shard = struct {
    const SelfShard = @This();

    by_user: std.AutoHashMap(u64, *ConnectionEntry),
    by_conn: std.AutoHashMap(u32, *ConnectionEntry),
    free_list: ?*ConnectionEntry = null,
    mutex: std.Io.Mutex,
    io: std.Io,
    /// The id `nextId` will hand out. Never 0 — see `firstId`.
    next_id: u32,
    tick: u64 = 0,
    id: u8,

    fn init(allocator: std.mem.Allocator, io: std.Io, id: u8) SelfShard {
        return initCapacity(allocator, io, id, 1024);
    }

    fn initCapacity(allocator: std.mem.Allocator, io: std.Io, id: u8, capacity: usize) SelfShard {
        var by_user = std.AutoHashMap(u64, *ConnectionEntry).init(allocator);
        by_user.ensureTotalCapacity(@intCast(capacity)) catch |err| {
            std.log.warn("[im.registry] by_user pre-allocate failed ({s}); registration may fail", .{@errorName(err)});
        };
        var by_conn = std.AutoHashMap(u32, *ConnectionEntry).init(allocator);
        by_conn.ensureTotalCapacity(@intCast(capacity)) catch |err| {
            std.log.warn("[im.registry] by_conn pre-allocate failed ({s}); registration may fail", .{@errorName(err)});
        };

        // Pre-allocate ConnectionEntry free list (object pool)
        var free_list: ?*ConnectionEntry = null;
        for (0..capacity) |_| {
            const entry = allocator.create(ConnectionEntry) catch break;
            entry.* = ConnectionEntry.empty();
            entry.next_free = free_list;
            free_list = entry;
        }

        return .{
            .by_user = by_user,
            .by_conn = by_conn,
            .free_list = free_list,
            .mutex = std.Io.Mutex.init,
            .io = io,
            .next_id = firstId(id),
            .id = id,
        };
    }

    fn deinit(self: *SelfShard) void {
        // Destroy active entries in maps
        var it = self.by_user.iterator();
        while (it.next()) |kv| self.by_user.allocator.destroy(kv.value_ptr.*);
        // Destroy free list entries
        var entry = self.free_list;
        while (entry) |e| {
            const next = e.next_free;
            self.by_user.allocator.destroy(e);
            entry = next;
        }
        self.by_user.deinit();
        self.by_conn.deinit();
        self.* = undefined;
    }

    /// Pop from free list. Returns null if pool exhausted.
    fn acquireEntry(self: *SelfShard) ?*ConnectionEntry {
        const entry = self.free_list orelse return null;
        self.free_list = entry.next_free;
        entry.next_free = null;
        return entry;
    }

    /// Push back to free list for reuse.
    fn releaseEntry(self: *SelfShard, entry: *ConnectionEntry) void {
        entry.* = ConnectionEntry.empty();
        entry.next_free = self.free_list;
        self.free_list = entry;
    }

    /// Hand out the next id, wrapping inside this shard's own 2^26 window rather
    /// than rolling into the neighbouring shard's ids. The last shard's window
    /// ends at `0xFFFF_FFFF`, so without the wrap its counter would step onto 0 —
    /// the one value `register` needs kept free (see `firstId`).
    fn nextId(self: *SelfShard) u32 {
        const id = self.next_id;
        const next = id +% 1;
        // `(next >> 26) == shard_id` is exactly "still inside this window".
        self.next_id = if ((next >> 26) == @as(u32, self.id)) next else firstId(self.id);
        return id;
    }

    /// First id this shard hands out: `(shard << 26) | 1`.
    ///
    /// The **low bit forced to 1 is the point**: ids are `(shard << 26) | counter`,
    /// so shard 0's window is `[0, 1 << 26)` and its very first counter value is 0
    /// — the same value `ConnectionRegistry.register` returns to mean
    /// "registration failed". The generated gateway reads it that way
    /// (`if (conn_id == 0) { destroy(session); }`), so the first connection for any
    /// `user_id & 63 == 0` was freed while `by_user` still referenced it and the
    /// next `sendToUser` was a use-after-free. Reserving 0 costs shard 0 exactly
    /// one id out of 2^26.
    fn firstId(shard_id: u8) u32 {
        return (@as(u32, shard_id) << 26) | 1;
    }

    fn register(self: *SelfShard, allocator: std.mem.Allocator, user_id: u64, ctx: *anyopaque, send_fn: SendFn) u32 {
        _ = allocator;
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        // Replace old connection, recycle entry to free list
        if (self.by_user.getPtr(user_id)) |existing| {
            _ = self.by_conn.remove(existing.*.conn_id);
            self.releaseEntry(existing.*);
        }

        // Acquire from object pool (infallible at capacity)
        const entry = self.acquireEntry() orelse return 0;
        const conn_id = self.nextId();
        entry.* = .{
            .conn_id = conn_id,
            .user_id = user_id,
            .ctx = ctx,
            .send_fn = send_fn,
            .last_tick = self.tick,
            .is_connected = true,
            .next_free = null,
        };

        // Infallible: capacity pre-allocated via ensureTotalCapacity in initCapacity
        self.by_user.putAssumeCapacity(user_id, entry);
        self.by_conn.putAssumeCapacity(conn_id, entry);
        return conn_id;
    }

    fn unregister(self: *SelfShard, allocator: std.mem.Allocator, user_id: u64) void {
        _ = allocator;
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (self.by_user.fetchRemove(user_id)) |kv| {
            _ = self.by_conn.remove(kv.value.conn_id);
            // Recycle entry to free list instead of destroying
            self.releaseEntry(kv.value);
        }
    }

    fn unregisterByConn(self: *SelfShard, allocator: std.mem.Allocator, conn_id: u32) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);

        if (self.by_conn.fetchRemove(conn_id)) |kv| {
            _ = self.by_user.remove(kv.value.user_id);
            kv.value.is_connected = false;
            allocator.destroy(kv.value);
            return true;
        }
        return false;
    }

    fn sendToUser(self: *SelfShard, user_id: u64, msg: []const u8) bool {
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

    fn isOnline(self: *SelfShard, user_id: u64) bool {
        self.mutex.lock(self.io) catch return false;
        defer self.mutex.unlock(self.io);

        const entry = self.by_user.getPtr(user_id) orelse return false;
        return entry.*.is_connected;
    }

    fn heartbeat(self: *SelfShard, conn_id: u32) void {
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);

        if (self.by_conn.getPtr(conn_id)) |entry| {
            entry.*.last_tick = self.tick;
        }
    }

    fn tickAndCleanup(self: *SelfShard, allocator: std.mem.Allocator, max_gap: u64) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);

        self.tick += 1;
        const current = self.tick;
        var dead: [32]u64 = undefined;
        var dead_len: usize = 0;
        var count: usize = 0;

        var it = self.by_user.iterator();
        while (it.next()) |kv| {
            if (!kv.value_ptr.*.is_connected or (current - kv.value_ptr.*.last_tick) > max_gap) {
                if (dead_len < dead.len) {
                    dead[dead_len] = kv.key_ptr.*;
                    dead_len += 1;
                }
            }
        }

        for (dead[0..dead_len]) |uid| {
            if (self.by_user.fetchRemove(uid)) |kv| {
                _ = self.by_conn.remove(kv.value.conn_id);
                allocator.destroy(kv.value);
                count += 1;
            }
        }
        return count;
    }

    fn onlineCount(self: *SelfShard) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.by_user.count();
    }

    fn onlineUsers(self: *SelfShard, buf: []u64) usize {
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

const ConnectionEntry = struct {
    conn_id: u32,
    user_id: u64,
    ctx: *anyopaque,
    send_fn: SendFn,
    last_tick: u64,
    is_connected: bool,
    next_free: ?*ConnectionEntry = null, // Free list link (object pool)

    fn empty() ConnectionEntry {
        return .{
            .conn_id = 0,
            .user_id = 0,
            .ctx = undefined,
            .send_fn = undefined,
            .last_tick = 0,
            .is_connected = false,
            .next_free = null,
        };
    }

    comptime {
        std.debug.assert(@sizeOf(ConnectionEntry) <= 128); // Must fit in two cache lines
    }
};

// ── Tests ──

test "sharded register unregister" {
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
}

test "sharded sendToUser offline" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();
    try std.testing.expect(!reg.sendToUser(999, "hello"));
}

test "sharded users in different shards" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var dummy: u8 = 0;
    // These user_ids hash to different shards
    _ = reg.register(1, @ptrCast(&dummy), testSendFn);
    _ = reg.register(65, @ptrCast(&dummy), testSendFn); // Different shard than user 1
    try std.testing.expectEqual(@as(usize, 2), reg.onlineCount());

    reg.unregister(1);
    try std.testing.expect(!reg.isOnline(1));
    try std.testing.expect(reg.isOnline(65));
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());
}

test "sharded tickAndCleanup" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var dummy: u8 = 0;
    const cid = reg.register(1, @ptrCast(&dummy), testSendFn);
    try std.testing.expect(cid > 0);

    _ = reg.tickAndCleanup(5);
    try std.testing.expect(reg.isOnline(1));

    reg.heartbeat(cid);
    _ = reg.tickAndCleanup(5);
    try std.testing.expect(reg.isOnline(1));
}

test "sharded unregisterByConn" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var dummy: u8 = 0;
    const cid = reg.register(42, @ptrCast(&dummy), testSendFn);
    try std.testing.expect(cid > 0);

    reg.unregisterByConn(cid);
    try std.testing.expect(!reg.isOnline(42));
    try std.testing.expectEqual(@as(usize, 0), reg.onlineCount());
}

fn testSendFn(ctx: *anyopaque, msg: []const u8) anyerror!void {
    _ = ctx;
    _ = msg;
}

/// Counts delivered messages through `ctx`, which points at a `usize`.
fn countingSendFn(ctx: *anyopaque, msg: []const u8) anyerror!void {
    _ = msg;
    const counter: *usize = @ptrCast(@alignCast(ctx));
    counter.* += 1;
}

// Verified red: dropping the `| 1` from `firstId` makes this fail on the *first*
// iteration with `expected ..., found 0` — shard 0's first id. That 0 is the
// value `ConnectionRegistry.register` documents as "registration failed", so any
// caller that branches on it frees a live session (see the test below). The
// existing tests all use user_ids 1 / 42 / 65 / 999, which land on shards 1 / 42 /
// 1 / 39 — shard 0 is never touched, which is how this survived.
test "the first id of every shard is non-zero, because 0 means registration failed" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var dummy: u8 = 0;
    // `user_id == i` lands on shard `i & 63`, so this visits all 64 shards once
    // each — i.e. every shard's *first* id, which is the value in question.
    for (0..SHARDS) |i| {
        const id = reg.register(i, @ptrCast(&dummy), testSendFn);
        try std.testing.expect(id != 0);
    }
}

// Verified red: same mutation (`| 1` removed) — `register(0, …)` returns 0, so
// the `id != 0` assertion fails. The rest of the test is what the caller does
// with that 0: it destroys the session, and `by_user` still points at it.
test "a shard-0 connection reaches its live session rather than looking like a failure" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var delivered: usize = 0;
    // user_id 0 is shard 0 — the shard whose id window starts at 0.
    const id = reg.register(0, @ptrCast(&delivered), countingSendFn);
    try std.testing.expect(id != 0); // a caller's `if (id == 0)` is-failure branch
    try std.testing.expect(reg.isOnline(0));
    try std.testing.expect(reg.sendToUser(0, "hi"));
    try std.testing.expectEqual(@as(usize, 1), delivered);
}

// Verified red: changing the wrap target from `firstId(self.id)` to a bare
// `0` makes the last assertion fail — shard 63's counter has stepped onto the
// failure sentinel, and every registration after it looks like a failure.
test "a shard id counter wraps inside its own window, never onto the sentinel" {
    const allocator = std.testing.allocator;
    // Shard 63 owns the top window, `[0xFC00_0000, 0xFFFF_FFFF]` — the only one
    // whose counter can reach 0 by incrementing.
    var shard = Shard.initCapacity(allocator, std.testing.io, 63, 4);
    defer shard.deinit();

    const window_base: u32 = @as(u32, 63) << 26;

    // Start from the last id in the window.
    shard.next_id = 0xFFFF_FFFF;
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), shard.nextId());
    try std.testing.expect(shard.next_id != 0);
    try std.testing.expectEqual(window_base | 1, shard.next_id);

    // And it keeps counting from there rather than sitting on the boundary.
    try std.testing.expectEqual(window_base | 1, shard.nextId());
    try std.testing.expectEqual(window_base | 2, shard.next_id);
}
