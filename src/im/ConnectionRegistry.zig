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

        // **Fallible on purpose.** The `putAssumeCapacity` this replaces rested on
        // "capacity pre-allocated in initCapacity", and that premise does not hold:
        // `initCapacity` only *logs* a failed `ensureTotalCapacity` (and its pool
        // loop `catch break`s), so a shard can come back with maps that never grew —
        // and `putAssumeCapacity` against such a map writes past its allocation.
        // `by_conn` first, because it is the insert that can grow a map: if it fails,
        // the incumbent connection is still intact. Doing it after the swap below
        // meant a failed registration also dropped the user's live connection.
        self.by_conn.put(conn_id, entry) catch {
            self.releaseEntry(entry);
            return 0;
        };

        // Now retire the incumbent. `fetchRemove` takes the key out of `by_user` as
        // well as handing back the entry, and that matters: releasing an entry while
        // leaving its key in place points `by_user` at a struct that is back on the
        // free list — one the next `acquireEntry` may hand to a **different** user,
        // after which `sendToUser` delivers to the wrong session.
        if (self.by_user.fetchRemove(user_id)) |old| {
            _ = self.by_conn.remove(old.value.conn_id);
            self.releaseEntry(old.value);
        }

        // Re-inserting a key that was just removed cannot need to grow (the map fit
        // it a moment ago), so this failing means the allocator is already gone —
        // roll back and leave nothing half-registered.
        self.by_user.put(user_id, entry) catch {
            _ = self.by_conn.remove(conn_id);
            self.releaseEntry(entry);
            return 0;
        };
        return conn_id;
    }

    fn unregister(self: *SelfShard, allocator: std.mem.Allocator, user_id: u64) void {
        _ = allocator;
        // Uncancelable: `std.Io.Mutex.lock` fails only with `error.Canceled`, and
        // this is the WS disconnect path — a task that is already being torn down
        // has that cancellation pending, so the old `catch return` dropped the
        // removal on *every* such call, not occasionally. The dropped removal is
        // not a missing cleanup: the entry stays in `by_user` with its `ctx`
        // still pointing at the session the caller is about to free, and the next
        // `sendToUser` calls `send_fn(entry.*.ctx, …)` on that freed session. The
        // critical section is two hash-map removals and there is no error channel
        // (`void`), so waiting is the honest answer — the same choice as
        // `pool/Pool.zig`'s `release`, `im/BufferPool.zig`'s `release` and
        // `sqlx.ConnPool.release`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.by_user.fetchRemove(user_id)) |kv| {
            _ = self.by_conn.remove(kv.value.conn_id);
            // Recycle entry to free list instead of destroying
            self.releaseEntry(kv.value);
        }
    }

    fn unregisterByConn(self: *SelfShard, allocator: std.mem.Allocator, conn_id: u32) bool {
        _ = allocator;
        // Uncancelable, for the same reason as `unregister`: `false` reads as "no
        // connection has this id", so a canceled wait does not just skip a
        // cleanup — the entry survives in `by_user` with a `ctx` the caller is
        // about to free (use-after-free on the next `sendToUser`), and
        // `ConnectionRegistry.unregisterByConn` walks every shard on `false`
        // without ever reporting that nothing was retired. Red:
        // `im.ConnectionRegistry.test.canceled lock wait does not lose a
        // disconnect`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.by_conn.fetchRemove(conn_id)) |kv| {
            _ = self.by_user.remove(kv.value.user_id);
            // Recycle, do **not** destroy. The pool is finite and has no refill
            // path (`free_list` is written only by `initCapacity` and
            // `releaseEntry`), so destroying here shrank it for good: after
            // `capacity` connect/disconnect cycles on one shard, `acquireEntry`
            // returns null, `register` returns 0, and every caller reads that as
            // "registration failed" — that shard could never take another
            // connection for the life of the process. This is the disconnect path
            // the generated gateway actually uses.
            self.releaseEntry(kv.value);
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
        // Uncancelable: `false` claims "this user has no connection" — the
        // gateway routes on it (a user it believes offline gets the message
        // stored instead of pushed) and cannot tell a fabricated answer from the
        // truth. The critical section is a single hash lookup. Red:
        // `im.ConnectionRegistry.test.canceled lock wait does not fabricate an
        // offline reading`.
        self.mutex.lockUncancelable(self.io);
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
        _ = allocator;
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
                // Recycle, not destroy — same pool as `unregisterByConn`, so the
                // same exhaustion applies to the stale-connection sweep.
                self.releaseEntry(kv.value);
                count += 1;
            }
        }
        return count;
    }

    fn onlineCount(self: *SelfShard) usize {
        // Uncancelable: `0` is a count a caller reports as fact (health checks,
        // metrics, `ConnectionRegistry.onlineCount` sums the shards) and cannot
        // be told apart from the truth — the same reading `im/BufferPool.zig`'s
        // `available`/`stats` were changed to stop fabricating.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.by_user.count();
    }

    fn onlineUsers(self: *SelfShard, buf: []u64) usize {
        // Uncancelable, for the same reason as `onlineCount`: `0` is published as
        // "no user is online" (the caller's `buf` is left untouched), which a
        // health check or a broadcast fan-out cannot tell apart from the truth.
        self.mutex.lockUncancelable(self.io);
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

// Verified red: reverting `unregisterByConn`'s `releaseEntry` to
// `allocator.destroy` makes this fail on the second round with
// `expected non-zero, found 0` — the shard's pool never refills, so after
// `capacity` disconnects `register` reports failure forever and every caller
// reads that as "this user could not connect". The `capacity = 4` here is what
// makes it observable in four cycles instead of 1024.
test "disconnects return their slot to the pool instead of shrinking it" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.initCapacity(allocator, std.testing.io, 4);
    defer reg.deinit();

    var dummy: u8 = 0;
    // All four hash to shard 0, i.e. the same per-shard pool of 4.
    const users = [_]u64{ 0, 64, 128, 192 };

    // Three full connect/disconnect rounds. The pre-fix code survives exactly one:
    // each `unregisterByConn` destroyed a slot, so round 2 had none left.
    for (0..3) |round| {
        var ids: [users.len]u32 = undefined;
        for (users, 0..) |uid, i| {
            ids[i] = reg.register(uid, @ptrCast(&dummy), testSendFn);
            if (ids[i] == 0) {
                std.debug.print("round {d}: shard 0 pool exhausted after {d} users\n", .{ round, i });
            }
            try std.testing.expect(ids[i] != 0);
        }
        try std.testing.expectEqual(users.len, reg.onlineCount());

        for (ids) |id| reg.unregisterByConn(id);
        try std.testing.expectEqual(@as(usize, 0), reg.onlineCount());
    }
}

// The stale-connection sweep takes the same path, so it has to recycle too.
// Verified red the same way (restore `allocator.destroy` in `tickAndCleanup`).
test "the stale sweep also returns slots to the pool" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.initCapacity(allocator, std.testing.io, 4);
    defer reg.deinit();

    var dummy: u8 = 0;
    const users = [_]u64{ 0, 64, 128, 192 };

    for (0..3) |round| {
        for (users) |uid| {
            const id = reg.register(uid, @ptrCast(&dummy), testSendFn);
            if (id == 0) std.debug.print("round {d}: shard 0 pool exhausted\n", .{round});
            try std.testing.expect(id != 0);
        }
        // No heartbeat: every entry is past `max_gap`, so the sweep reaps them all.
        try std.testing.expectEqual(users.len, reg.tickAndCleanup(0));
        try std.testing.expectEqual(@as(usize, 0), reg.onlineCount());
    }
}

// No mutation red for this one: the pre-fix code also passed it (as analysed in the
// `register` comment, the old `getPtr` + `releaseEntry` pair happened to work only
// because `acquireEntry` was guaranteed to hand back the entry that had just been
// released). It is a pin on the replace path, not a reproduction. The `by_conn`
// ordering, however, does have teeth — see the exhaustion tests above.
test "re-registering a user replaces the connection and delivers to the new one" {
    const allocator = std.testing.allocator;
    var reg = ConnectionRegistry.init(allocator, std.testing.io);
    defer reg.deinit();

    var first_delivered: usize = 0;
    var second_delivered: usize = 0;

    const first = reg.register(0, @ptrCast(&first_delivered), countingSendFn);
    try std.testing.expect(first != 0);
    const second = reg.register(0, @ptrCast(&second_delivered), countingSendFn);
    try std.testing.expect(second != 0);
    try std.testing.expect(first != second);

    // One user, one entry — the replaced one went back to the pool rather than
    // lingering in `by_user`.
    try std.testing.expectEqual(@as(usize, 1), reg.onlineCount());

    // And delivery follows the *new* session, not the replaced one.
    try std.testing.expect(reg.sendToUser(0, "hi"));
    try std.testing.expectEqual(@as(usize, 0), first_delivered);
    try std.testing.expectEqual(@as(usize, 1), second_delivered);
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

// `unregisterByConn`'s `catch return false` is not a harmless "no such
// connection": the caller (`ConnectionRegistry.unregisterByConn` walks the shards
// with it) reads it as "this id was never registered" and the entry stays in
// `by_user` with its `ctx` pointing at the session the caller is tearing down —
// the next `sendToUser` calls `send_fn(entry.*.ctx, …)` on that freed session.
//
// The disconnect path is where a cancellation lands: the generated gateway runs
// `unregisterByConn` from the close handler of a task that may already be
// canceled, and `std.Io.Mutex.lock` is a cancelation point that then fails
// immediately (`error.Canceled` is the only error it has).
//
// Red evidence: with the old `self.mutex.lock(self.io) catch return false` the
// assertion below fails — `expected false, found true` — the user is still online
// after a disconnect that reported success. The lock wait is the cancelation
// point here: the task is parked on shard 0's mutex (held by the test thread)
// with a cancel request already placed on its thread, and the gate between the
// two is pure spinning.
test "canceled lock wait does not lose a disconnect" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reg = ConnectionRegistry.init(allocator, io);
    defer reg.deinit();

    var dummy: u8 = 0;
    const conn_id = reg.register(0, @ptrCast(&dummy), testSendFn);
    try std.testing.expect(conn_id != 0);

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn unregister(r: *ConnectionRegistry, id: u32) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            r.unregisterByConn(id);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    // The test thread holds shard 0's mutex, so the task cannot get past the lock
    // wait until told to. user_id 0 is shard 0.
    try reg.shards[0].mutex.lock(io);

    var task_fut = try io.concurrent(Task.unregister, .{ &reg, conn_id });
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    // The task is now inside `unregisterByConn`: parked on the mutex (it swaps the
    // state to `contended` on its way to the wait), or already gone.
    while (reg.shards[0].mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    reg.shards[0].mutex.unlock(io);

    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expect(!reg.isOnline(0));
}

// The same defect class in the read-only accessors: `isOnline` answering a
// canceled lock wait with `false` fabricates "this user has no connection" — a
// reading the gateway routes on (offline → store the message instead of pushing
// it). The user is online here, so the reading has to say so.
//
// Red evidence: with the old `self.mutex.lock(self.io) catch return false` this
// fails with `expected true, found false`.
test "canceled lock wait does not fabricate an offline reading" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var reg = ConnectionRegistry.init(allocator, io);
    defer reg.deinit();

    var dummy: u8 = 0;
    try std.testing.expect(reg.register(0, @ptrCast(&dummy), testSendFn) != 0);

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var seen: bool = false;

        fn read(r: *ConnectionRegistry) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            seen = r.isOnline(0);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.seen = false;

    try reg.shards[0].mutex.lock(io);

    var read_fut = try io.concurrent(Task.read, .{&reg});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (reg.shards[0].mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    reg.shards[0].mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);

    try std.testing.expect(Task.seen);
}
