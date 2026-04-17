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

        allocator: std.mem.Allocator,
        io: std.Io,
        createFn: *const fn () errors.ResultT(*T),
        destroyFn: *const fn (*T) void,
        validateFn: *const fn (*T) bool,
        min_idle: u32,
        max_active: u32,
        active_count: std.atomic.Value(u32),
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
            }

            return pool;
        }

        pub fn deinit(self: *Self) void {
            self.closed.store(true, .monotonic);
            self.cond.broadcast(self.io);

            self.mutex.lock(self.io) catch return;
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
                }
            }

            // Check if we can create a new connection
            const current_active = self.active_count.load(.monotonic);
            if (current_active < self.max_active) {
                self.mutex.unlock(self.io);
                const conn = try self.createFn();
                _ = self.active_count.fetchAdd(1, .monotonic);
                return conn;
            }

            // Wait for a connection to be released
            // In Zig 0.16.0, Condition.timedWait API changed; using simple timeout loop
            var waited: u32 = 0;
            const step_ms: u32 = 10;
            while (self.idle_conns.items.len == 0 and waited < self.max_wait_ms) {
                self.cond.wait(self.io, &self.mutex) catch break;
                waited += step_ms;
            }

            if (self.idle_conns.items.len > 0) {
                const node = self.idle_conns.pop();
                self.mutex.unlock(self.io);
                if (node) |n| return n.conn;
            }

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

            self.mutex.lock(self.io) catch return;
            self.idle_conns.append(self.allocator, .{
                .conn = conn,
                .last_used = 0,
            }) catch {
                self.mutex.unlock(self.io);
                self.destroyFn(conn);
                _ = self.active_count.fetchSub(1, .monotonic);
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
            self.mutex.lock(self.io) catch return 0;
            defer self.mutex.unlock(self.io);
            return self.idle_conns.items.len;
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

    try std.testing.expect(create_count >= 2);
}
