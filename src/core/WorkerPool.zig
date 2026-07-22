//! Bounded worker pool for async task execution.
//! Tasks are submitted to a queue and executed by a fixed number of workers.

const std = @import("std");
const Time = @import("Time.zig");

pub const Task = struct {
    run: *const fn (ctx: ?*anyopaque, io: std.Io) void,
    ctx: ?*anyopaque,
};

pub const WorkerPool = struct {
    const Self = @This();

    /// Shared state is heap-allocated so worker threads have a stable pointer
    /// even after `WorkerPool.init` returns and the `WorkerPool` value is moved.
    const Shared = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        queue: std.ArrayList(Task),
        mu: std.Io.Mutex,
        cond: std.Io.Condition,
        shutdown: bool,
        max_pending: usize,
    };

    allocator: std.mem.Allocator,
    shared: *Shared,
    threads: std.ArrayList(std.Thread),
    name: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        name: []const u8,
        worker_count: u32,
        max_pending: usize,
    ) !Self {
        const name_copy = try allocator.dupe(u8, name);
        errdefer allocator.free(name_copy);

        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);

        shared.* = .{
            .allocator = allocator,
            .io = io,
            .queue = std.ArrayList(Task).empty,
            .mu = .init,
            .cond = .init,
            .shutdown = false,
            .max_pending = max_pending,
        };
        try shared.queue.ensureTotalCapacity(allocator, max_pending);
        errdefer shared.queue.deinit(allocator);

        var threads = std.ArrayList(std.Thread).empty;
        errdefer threads.deinit(allocator);

        for (0..worker_count) |_| {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{shared});
            try threads.append(allocator, thread);
        }

        return .{
            .allocator = allocator,
            .shared = shared,
            .threads = threads,
            .name = name_copy,
        };
    }

    pub fn deinit(self: *Self) void {
        self.shared.shutdown = true;
        self.shared.cond.broadcast(self.shared.io);
        for (self.threads.items) |thread| {
            thread.join();
        }
        self.threads.deinit(self.allocator);
        self.shared.queue.deinit(self.allocator);
        self.allocator.destroy(self.shared);
        self.allocator.free(self.name);
        self.* = undefined;
    }

    /// Submit a task. Returns false if the queue is full or shutting down.
    pub fn dispatch(self: *Self, task: Task) bool {
        const shared = self.shared;
        shared.mu.lock(shared.io) catch return false;
        defer shared.mu.unlock(shared.io);

        if (shared.shutdown) return false;
        if (shared.queue.items.len >= shared.max_pending) return false;

        shared.queue.appendAssumeCapacity(task);
        shared.cond.signal(shared.io);
        return true;
    }

    pub fn pendingCount(self: *Self) usize {
        const shared = self.shared;
        shared.mu.lock(shared.io) catch return 0;
        defer shared.mu.unlock(shared.io);
        return shared.queue.items.len;
    }

    fn workerLoop(shared: *Shared) void {
        while (true) {
            shared.mu.lock(shared.io) catch return;
            while (shared.queue.items.len == 0 and !shared.shutdown) {
                shared.cond.wait(shared.io, &shared.mu) catch break;
            }
            if (shared.queue.items.len == 0 and shared.shutdown) {
                shared.mu.unlock(shared.io);
                return;
            }
            const task = shared.queue.orderedRemove(0);
            shared.mu.unlock(shared.io);

            task.run(task.ctx, shared.io);
        }
    }
};

test "WorkerPool executes dispatched tasks" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        var counter: std.atomic.Value(u32) = .init(0);
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            _ = ctx;
            _ = io;
            _ = @This().counter.fetchAdd(1, .monotonic);
        }
    };

    var pool = try WorkerPool.init(allocator, std.testing.io, "test", 2, 16);
    defer pool.deinit();

    for (0..10) |_| {
        try std.testing.expect(pool.dispatch(.{ .run = Ctx.run, .ctx = null }));
    }

    while (Ctx.counter.load(.monotonic) < 10) {
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 10), Ctx.counter.load(.monotonic));
}

test "WorkerPool rejects when queue is full" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            _ = ctx;
            _ = io;
        }
    };

    var pool = try WorkerPool.init(allocator, std.testing.io, "full", 1, 1);
    defer pool.deinit();

    try std.testing.expect(pool.dispatch(.{ .run = Ctx.run, .ctx = null }));
    try std.testing.expect(!pool.dispatch(.{ .run = Ctx.run, .ctx = null }));
}
