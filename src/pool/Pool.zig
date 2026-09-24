//! Generic connection pool for zigzero
//!
//! Provides a reusable connection pool pattern aligned with go-zero.

const std = @import("std");
const errors = @import("../sqlx/errors.zig");

/// Connection factory interface
pub const Factory = struct {
    create: *const fn (*anyopaque, std.mem.Allocator) errors.ResultT(*anyopaque),
    destroy: *const fn (*anyopaque, *anyopaque) void,
    validate: *const fn (*anyopaque, *anyopaque) bool,
    context: *anyopaque,
};

/// Generic connection pool
pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        const Node = struct {
            conn: *T,
            last_used: i64,
        };

        pub const PoolStats = struct {
            active_count: u32,
            idle_count: usize,
            creation_count: u64,
            eviction_count: u64,
            total_wait_time_ms: u64,
            timeout_count: u64,
        };

        allocator: std.mem.Allocator,
        io: std.Io,
        createFn: *const fn () errors.ResultT(*T),
        destroyFn: *const fn (*T) void,
        validateFn: *const fn (*T) bool,
        min_idle: u32,
        max_active: u32,
        active_count: std.atomic.Value(u32),
        creation_count: std.atomic.Value(u64),
        eviction_count: std.atomic.Value(u64),
        total_wait_time_ms: std.atomic.Value(u64),
        timeout_count: std.atomic.Value(u64),
        idle_conns: std.ArrayList(Node),
        mutex: std.Io.Mutex,
        cond: std.Io.Condition,
        max_wait_ms: u32 = 5000,
        closed: std.atomic.Value(bool),

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            createFn: *const fn () errors.ResultT(*T),
            destroyFn: *const fn (*T) void,
            validateFn: *const fn (*T) bool,
            config: Config,
        ) !Self {
            var pool = Self{
                .allocator = allocator,
                .io = io,
                .createFn = createFn,
                .destroyFn = destroyFn,
                .validateFn = validateFn,
                .min_idle = config.min_idle,
                .max_active = config.max_active,
                .active_count = std.atomic.Value(u32).init(0),
                .creation_count = std.atomic.Value(u64).init(0),
                .eviction_count = std.atomic.Value(u64).init(0),
                .total_wait_time_ms = std.atomic.Value(u64).init(0),
                .timeout_count = std.atomic.Value(u64).init(0),
                .idle_conns = std.ArrayList(Node).empty,
                .mutex = std.Io.Mutex.init,
                .cond = std.Io.Condition.init,
                .max_wait_ms = config.max_wait_ms,
                .closed = std.atomic.Value(bool).init(false),
            };

            // Pre-create min idle connections
            var i: u32 = 0;
            while (i < config.min_idle) : (i += 1) {
                const conn = createFn() catch continue;
                try pool.idle_conns.append(allocator, .{
                    .conn = conn,
                    .last_used = 0,
                });
                _ = pool.active_count.fetchAdd(1, .monotonic);
                _ = pool.creation_count.fetchAdd(1, .monotonic);
            }

            return pool;
        }

        pub fn deinit(self: *Self) void {
            self.closed.store(true, .monotonic);
            self.cond.broadcast(self.io);

            // Uncancelable: this is the destructor. A cancelable `lock` returns
            // early on cancellation, which here would skip destroying the idle
            // connections and freeing the list — the pool would leak every idle
            // connection while reporting itself closed.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            for (self.idle_conns.items) |node| {
                self.destroyFn(node.conn);
            }
            self.idle_conns.deinit(self.allocator);
        }

        /// Get a connection from the pool
        pub fn acquire(self: *Self) !*T {
            if (self.closed.load(.monotonic)) return error.ServerError;

            self.mutex.lock(self.io) catch return error.ServerError;

            // Try to get an idle connection
            while (self.idle_conns.items.len > 0) {
                const node = self.idle_conns.pop();
                if (node) |n| {
                    if (self.validateFn(n.conn)) {
                        self.mutex.unlock(self.io);
                        return n.conn;
                    }
                    self.destroyFn(n.conn);
                    _ = self.active_count.fetchSub(1, .monotonic);
                    _ = self.eviction_count.fetchAdd(1, .monotonic);
                }
            }

            // Check if we can create a new connection
            const current_active = self.active_count.load(.monotonic);
            if (current_active < self.max_active) {
                self.mutex.unlock(self.io);
                const conn = try self.createFn();
                _ = self.active_count.fetchAdd(1, .monotonic);
                _ = self.creation_count.fetchAdd(1, .monotonic);
                return conn;
            }

            // Wait for a connection to be released
            var waited: u32 = 0;
            const step_ms: u32 = 10;
            while (self.idle_conns.items.len == 0 and waited < self.max_wait_ms) {
                self.cond.wait(self.io, &self.mutex) catch break;
                waited += step_ms;
            }

            _ = self.total_wait_time_ms.fetchAdd(waited, .monotonic);

            if (self.idle_conns.items.len > 0) {
                const node = self.idle_conns.pop();
                self.mutex.unlock(self.io);
                if (node) |n| return n.conn;
            }

            _ = self.timeout_count.fetchAdd(1, .monotonic);
            self.mutex.unlock(self.io);
            return error.Timeout;
        }

        /// Return a connection to the pool
        pub fn release(self: *Self, conn: *T) void {
            if (self.closed.load(.monotonic)) {
                self.destroyFn(conn);
                _ = self.active_count.fetchSub(1, .monotonic);
                return;
            }

            // Uncancelable: `release` is the caller handing its connection back,
            // and a canceled `lock` has no way to say "never mind" — the old
            // `catch return` dropped the connection on the floor (not destroyed,
            // not idle, `active_count` unchanged), so every canceled release
            // cost the pool one slot for good. Waiting is the honest answer: the
            // critical section is a single list append, and the alternative
            // (destroying a healthy connection) throws away the connection for
            // no reason. Same choice as `sqlx.ConnPool.release`, which also
            // takes this mutex with `lockUncancelable`.
            self.mutex.lockUncancelable(self.io);
            self.idle_conns.append(self.allocator, .{
                .conn = conn,
                .last_used = 0,
            }) catch {
                self.mutex.unlock(self.io);
                self.destroyFn(conn);
                _ = self.active_count.fetchSub(1, .monotonic);
                _ = self.eviction_count.fetchAdd(1, .monotonic);
                return;
            };
            self.mutex.unlock(self.io);
            self.cond.signal(self.io);
        }

        /// Current active connection count
        pub fn active(self: *Self) u32 {
            return self.active_count.load(.monotonic);
        }

        /// Current idle connection count
        pub fn idle(self: *Self) usize {
            // Uncancelable: `0` here claims the pool holds nothing while
            // connections sit in `idle_conns` — the reading `stats()` republishes
            // as `idle_count` and every capacity/health check is built on. Same
            // class as `im/BufferPool.zig`'s `available`, and the accessor has no
            // error channel to report a cancelation through. Red:
            // `pool.Pool.test.canceled lock wait does not fabricate an empty pool
            // reading` reads `expected 1, found 0`.
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.idle_conns.items.len;
        }

        /// Comprehensive pool status metrics
        pub fn stats(self: *Self) PoolStats {
            return .{
                .active_count = self.active_count.load(.monotonic),
                .idle_count = self.idle(),
                .creation_count = self.creation_count.load(.monotonic),
                .eviction_count = self.eviction_count.load(.monotonic),
                .total_wait_time_ms = self.total_wait_time_ms.load(.monotonic),
                .timeout_count = self.timeout_count.load(.monotonic),
            };
        }
    };
}

pub const Config = struct {
    min_idle: u32 = 2,
    max_active: u32 = 20,
    max_wait_ms: u32 = 5000,
    max_idle_time_ms: u32 = 300000, // 5 minutes
};

test "connection pool" {
    const CreateCtx = struct {
        var count: *u32 = undefined;
    };
    const DestroyCtx = struct {
        var count: *u32 = undefined;
    };

    var create_count: u32 = 0;
    var destroy_count: u32 = 0;
    CreateCtx.count = &create_count;
    DestroyCtx.count = &destroy_count;

    const createFn = struct {
        fn create() errors.ResultT(*u32) {
            CreateCtx.count.* += 1;
            const ptr = std.heap.page_allocator.create(u32) catch return error.ServerError;
            ptr.* = 42;
            return ptr;
        }
    }.create;

    const destroyFn = struct {
        fn destroy(ptr: *u32) void {
            DestroyCtx.count.* += 1;
            std.heap.page_allocator.destroy(ptr);
        }
    }.destroy;

    const validateFn = struct {
        fn validate(ptr: *u32) bool {
            _ = ptr;
            return true;
        }
    }.validate;

    var pool = try Pool(u32).init(
        std.testing.allocator,
        std.testing.io,
        createFn,
        destroyFn,
        validateFn,
        .{ .min_idle = 2, .max_active = 5 },
    );
    defer pool.deinit();

    try std.testing.expect(pool.idle() >= 2);

    const conn = try pool.acquire();
    try std.testing.expectEqual(@as(u32, 42), conn.*);
    pool.release(conn);

    const st = pool.stats();
    try std.testing.expect(st.creation_count >= 2);
    try std.testing.expectEqual(@as(u64, 0), st.eviction_count);

    try std.testing.expect(create_count >= 2);
}

// Regression: `release` used to return early when its (cancelable) mutex lock
// came back `error.Canceled`. The connection was then neither destroyed nor put
// back on the idle list, and `active_count` stayed up — one permanent slot lost
// per canceled release, until the pool could not hand anything out at all.
//
// The release task here is parked on the pool mutex (held by the test thread)
// with a cancel request already placed on its thread, so it reaches the lock
// wait at a cancelation point. Whatever `release` decides to do about that
// request, the connection must not fall out of the pool's books.
test "Pool release keeps the connection when its lock wait is canceled" {
    const Counters = struct {
        var created = std.atomic.Value(u32).init(0);
        var destroyed = std.atomic.Value(u32).init(0);

        fn create() errors.ResultT(*u32) {
            _ = created.fetchAdd(1, .monotonic);
            const conn = std.testing.allocator.create(u32) catch return error.ServerError;
            conn.* = 7;
            return conn;
        }
        fn destroy(conn: *u32) void {
            _ = destroyed.fetchAdd(1, .monotonic);
            std.testing.allocator.destroy(conn);
        }
        fn validate(conn: *u32) bool {
            return conn.* == 7;
        }
    };
    Counters.created.store(0, .monotonic);
    Counters.destroyed.store(0, .monotonic);

    const io = std.testing.io;
    var pool = try Pool(u32).init(std.testing.allocator, io, Counters.create, Counters.destroy, Counters.validate, .{
        .min_idle = 0,
        .max_active = 4,
        .max_wait_ms = 1000,
    });
    defer pool.deinit();

    const conn = try pool.acquire();
    try std.testing.expectEqual(@as(u32, 1), pool.active());
    try std.testing.expectEqual(@as(usize, 0), pool.idle());

    const Gate = struct {
        var ready = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var released = std.atomic.Value(bool).init(false);

        fn releaseTask(p: *Pool(u32), c: *u32) void {
            ready.store(true, .release);
            // Pure spinning: no cancelation point, so a request placed while the
            // task is still gated cannot be consumed before `release` takes the
            // lock — it is still pending when the lock wait begins.
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            p.release(c);
            released.store(true, .release);
        }

        fn cancelTask(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Gate.ready.store(false, .monotonic);
    Gate.open.store(false, .monotonic);
    Gate.released.store(false, .monotonic);

    // The test thread holds the pool mutex, so the release task cannot get past
    // the lock wait until told to.
    try pool.mutex.lock(io);

    var release_fut = try io.concurrent(Gate.releaseTask, .{ &pool, conn });
    while (!Gate.ready.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Gate.cancelTask, .{ io, &release_fut });
    // Give the request time to land on the release task's thread while it is
    // still gated. This is what makes the cancelation point the lock wait, not
    // some earlier operation of the task.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Gate.open.store(true, .release);
    // The release task is now inside `release`: either it left through the
    // `error.Canceled` path (the bug), or it is parked on the mutex.
    while (pool.mutex.state.load(.monotonic) != .contended and !Gate.released.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    pool.mutex.unlock(io);

    cancel_fut.await(io);
    release_fut.await(io);

    try std.testing.expect(Gate.released.load(.acquire));
    // Every connection the pool created is accounted for: idle, or destroyed and
    // dropped from `active_count`. Canceling the release must not produce a third
    // state — that is the slot the pool used to leak, and `active` alone cannot
    // see it.
    try std.testing.expectEqual(
        Counters.created.load(.monotonic),
        @as(u32, @intCast(pool.idle())) + Counters.destroyed.load(.monotonic),
    );
    // What `release` does with a canceled lock wait here is take the connection
    // back (see the comment on `release`): it is idle, still counted, not
    // destroyed. The other defensible answer — treat the cancelation as "this
    // connection is gone", destroy it and decrement `active` — would satisfy the
    // invariant above with `idle == 0`, `destroyed == 1`, `active == 0`. Both are
    // fine; the leak (`idle + destroyed == 0` with `active == 1`) is not.
    try std.testing.expectEqual(@as(usize, 1), pool.idle());
    try std.testing.expectEqual(@as(u32, 0), Counters.destroyed.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), pool.active());

    // The slot is not merely counted, it is usable: the pool hands back out the
    // very connection the canceled release returned.
    const reacquired = try pool.acquire();
    try std.testing.expect(reacquired == conn);
    pool.release(reacquired);
}

// `idle` answering a canceled lock wait with `0` claims the pool holds nothing
// while connections sit in `idle_conns` — the reading `stats()` republishes as
// `idle_count` and every capacity/health check is built on. Same class as
// `im/BufferPool.zig`'s `available`, and the same rule as `release` just above:
// this accessor has no error channel (it returns `usize`), and the critical
// section is a length read.
//
// Red evidence: with the old `self.mutex.lock(self.io) catch return 0` the
// assertion below fails with `expected 1, found 0`.
test "canceled lock wait does not fabricate an empty pool reading" {
    const Counters = struct {
        var created = std.atomic.Value(u32).init(0);
        var destroyed = std.atomic.Value(u32).init(0);

        fn create() errors.ResultT(*u32) {
            _ = created.fetchAdd(1, .monotonic);
            const conn = std.testing.allocator.create(u32) catch return error.ServerError;
            conn.* = 7;
            return conn;
        }
        fn destroy(conn: *u32) void {
            _ = destroyed.fetchAdd(1, .monotonic);
            std.testing.allocator.destroy(conn);
        }
        fn validate(conn: *u32) bool {
            return conn.* == 7;
        }
    };
    Counters.created.store(0, .monotonic);
    Counters.destroyed.store(0, .monotonic);

    const io = std.testing.io;
    var pool = try Pool(u32).init(std.testing.allocator, io, Counters.create, Counters.destroy, Counters.validate, .{
        .min_idle = 0,
        .max_active = 4,
        .max_wait_ms = 1000,
    });
    defer pool.deinit();

    // One connection, handed back: idle is 1, not 0, so the fabricated reading is
    // distinguishable from the true one.
    const conn = try pool.acquire();
    pool.release(conn);
    try std.testing.expectEqual(@as(usize, 1), pool.idle());

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var idle_count: usize = 0;

        fn read(p: *Pool(u32)) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            idle_count = p.idle();
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.idle_count = 0;

    try pool.mutex.lock(io);

    var read_fut = try io.concurrent(Task.read, .{&pool});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (pool.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    pool.mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);

    try std.testing.expectEqual(@as(usize, 1), Task.idle_count);
}
