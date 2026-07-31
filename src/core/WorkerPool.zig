//! Bounded worker pool for async task execution.
//! Tasks are submitted to a queue and executed by a fixed number of workers.

const std = @import("std");
const Time = @import("Time.zig");

pub const max_worker_count = 128;

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
        total_workers: usize,
        active_workers: std.atomic.Value(usize),
        completed_tasks: std.atomic.Value(u64),
        rejected_tasks: std.atomic.Value(u64),
    };

    pub const WorkerPoolStats = struct {
        pending_count: usize,
        max_pending: usize,
        active_workers: usize,
        total_workers: usize,
        completed_tasks: u64,
        rejected_tasks: u64,
        utilization_pct: f32,

        /// Render as Prometheus text format with the given `pool` label.
        /// Caller owns the returned slice and must `allocator.free(it)`.
        pub fn toPrometheusFormat(
            self: WorkerPoolStats,
            allocator: std.mem.Allocator,
            pool_name: []const u8,
        ) ![]u8 {
            var buf = std.array_list.Managed(u8).init(allocator);
            errdefer buf.deinit();

            try buf.print("# HELP zigmodu_workerpool_pending_tasks Tasks waiting in the worker pool queue.\n", .{});
            try buf.print("# TYPE zigmodu_workerpool_pending_tasks gauge\n", .{});
            try buf.print("zigmodu_workerpool_pending_tasks{{pool=\"{s}\"}} {d}\n\n", .{ pool_name, self.pending_count });

            try buf.print("# HELP zigmodu_workerpool_max_pending Maximum queue capacity.\n", .{});
            try buf.print("# TYPE zigmodu_workerpool_max_pending gauge\n", .{});
            try buf.print("zigmodu_workerpool_max_pending{{pool=\"{s}\"}} {d}\n\n", .{ pool_name, self.max_pending });

            try buf.print("# HELP zigmodu_workerpool_active_workers Workers currently executing a task.\n", .{});
            try buf.print("# TYPE zigmodu_workerpool_active_workers gauge\n", .{});
            try buf.print("zigmodu_workerpool_active_workers{{pool=\"{s}\"}} {d}\n\n", .{ pool_name, self.active_workers });

            try buf.print("# HELP zigmodu_workerpool_total_workers Configured worker thread count.\n", .{});
            try buf.print("# TYPE zigmodu_workerpool_total_workers gauge\n", .{});
            try buf.print("zigmodu_workerpool_total_workers{{pool=\"{s}\"}} {d}\n\n", .{ pool_name, self.total_workers });

            try buf.print("# HELP zigmodu_workerpool_completed_tasks_total Tasks that ran to completion.\n", .{});
            try buf.print("# TYPE zigmodu_workerpool_completed_tasks_total counter\n", .{});
            try buf.print("zigmodu_workerpool_completed_tasks_total{{pool=\"{s}\"}} {d}\n\n", .{ pool_name, self.completed_tasks });

            try buf.print("# HELP zigmodu_workerpool_rejected_tasks_total Tasks rejected because queue was full or pool was shutting down.\n", .{});
            try buf.print("# TYPE zigmodu_workerpool_rejected_tasks_total counter\n", .{});
            try buf.print("zigmodu_workerpool_rejected_tasks_total{{pool=\"{s}\"}} {d}\n\n", .{ pool_name, self.rejected_tasks });

            try buf.print("# HELP zigmodu_workerpool_utilization Fraction of workers currently active (0.0 to 1.0).\n", .{});
            try buf.print("# TYPE zigmodu_workerpool_utilization gauge\n", .{});
            try buf.print("zigmodu_workerpool_utilization{{pool=\"{s}\"}} {d:.3}\n", .{ pool_name, self.utilization_pct });

            return buf.toOwnedSlice() catch unreachable;
        }
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
        if (worker_count == 0 or worker_count > max_worker_count) {
            return error.ConfigurationError;
        }

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
            .total_workers = worker_count,
            .active_workers = std.atomic.Value(usize).init(0),
            .completed_tasks = std.atomic.Value(u64).init(0),
            .rejected_tasks = std.atomic.Value(u64).init(0),
        };

        try shared.queue.ensureTotalCapacity(allocator, max_pending);
        errdefer shared.queue.deinit(allocator);

        var threads = std.ArrayList(std.Thread).empty;
        errdefer {
            // On failure after workers have been spawned: stop them, join them,
            // then free the thread list. `shared` is still valid because this
            // errdefer runs before we return the WorkerPool value.
            signalShutdown(shared);

            for (threads.items) |thread| {
                thread.join();
            }
            threads.deinit(allocator);
        }

        try threads.ensureTotalCapacity(allocator, worker_count);
        for (0..worker_count) |_| {
            const thread = try std.Thread.spawn(.{}, workerLoop, .{shared});
            threads.appendAssumeCapacity(thread);
        }

        return .{
            .allocator = allocator,
            .shared = shared,
            .threads = threads,
            .name = name_copy,
        };
    }

    /// Signal workers to shut down. New dispatches are rejected after this.
    /// `deinit` calls this automatically; call it explicitly if you need to
    /// stop accepting work before releasing the pool.
    pub fn shutdown(self: *Self) void {
        signalShutdown(self.shared);
    }

    pub fn deinit(self: *Self) void {
        self.shutdown();
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
        shared.mu.lock(shared.io) catch {
            _ = shared.rejected_tasks.fetchAdd(1, .monotonic);
            return false;
        };
        defer shared.mu.unlock(shared.io);

        if (shared.shutdown or shared.queue.items.len >= shared.max_pending) {
            _ = shared.rejected_tasks.fetchAdd(1, .monotonic);
            return false;
        }

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

    /// Retrieve runtime statistics of this worker pool
    pub fn stats(self: *Self) WorkerPoolStats {
        const shared = self.shared;
        const pending = self.pendingCount();
        const active = shared.active_workers.load(.monotonic);
        const total = shared.total_workers;
        const util = if (total > 0) @as(f32, @floatFromInt(active)) / @as(f32, @floatFromInt(total)) else 0.0;

        return .{
            .pending_count = pending,
            .max_pending = shared.max_pending,
            .active_workers = active,
            .total_workers = total,
            .completed_tasks = shared.completed_tasks.load(.monotonic),
            .rejected_tasks = shared.rejected_tasks.load(.monotonic),
            .utilization_pct = util,
        };
    }

    /// Backpressure check: returns true if queue or worker capacity is above threshold_pct (0.0 to 1.0)
    pub fn isOverloaded(self: *Self, threshold_pct: f32) bool {
        const st = self.stats();
        const pending_pct = if (st.max_pending > 0) @as(f32, @floatFromInt(st.pending_count)) / @as(f32, @floatFromInt(st.max_pending)) else 0.0;
        return (st.utilization_pct >= threshold_pct) or (pending_pct >= threshold_pct);
    }

    fn workerLoop(shared: *Shared) void {
        while (true) {
            shared.mu.lock(shared.io) catch return;

            while (shared.queue.items.len == 0 and !shared.shutdown) {
                shared.cond.wait(shared.io, &shared.mu) catch break;
            }

            if (shared.queue.items.len == 0) {
                shared.mu.unlock(shared.io);
                return;
            }

            const task = shared.queue.orderedRemove(0);
            _ = shared.active_workers.fetchAdd(1, .monotonic);
            shared.mu.unlock(shared.io);

            task.run(task.ctx, shared.io);
            _ = shared.active_workers.fetchSub(1, .monotonic);
            _ = shared.completed_tasks.fetchAdd(1, .monotonic);
        }
    }
};

fn signalShutdown(shared: *WorkerPool.Shared) void {
    shared.mu.lock(shared.io) catch return;
    defer shared.mu.unlock(shared.io);

    shared.shutdown = true;
    shared.cond.broadcast(shared.io);
}

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

    const deadline = Time.monotonicNowMilliseconds() + 5000;
    while (Ctx.counter.load(.monotonic) < 10) {
        if (Time.monotonicNowMilliseconds() >= deadline) return error.Timeout;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 10), Ctx.counter.load(.monotonic));
}

test "WorkerPool rejects when queue is full" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        flag: std.atomic.Value(bool) = .init(false),

        fn run(ctx: ?*anyopaque, io: std.Io) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            while (!self.flag.load(.acquire)) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
        }
    };

    // Keep the single worker busy until the test ends. With max_pending=1 the
    // queue+worker capacity is at most two tasks, so the third dispatch is
    // deterministically rejected.
    var ctx: Ctx = .{};
    var pool = try WorkerPool.init(allocator, std.testing.io, "full", 1, 1);
    defer {
        ctx.flag.store(true, .release);
        pool.deinit();
    }

    try std.testing.expect(pool.dispatch(.{ .run = Ctx.run, .ctx = &ctx }));
    _ = pool.dispatch(.{ .run = Ctx.run, .ctx = &ctx }); // may accept or reject
    try std.testing.expect(!pool.dispatch(.{ .run = Ctx.run, .ctx = &ctx }));
}

test "WorkerPool shutdown rejects new dispatches and drains queue" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        var counter: std.atomic.Value(u32) = .init(0);
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            _ = ctx;
            _ = io;
            _ = @This().counter.fetchAdd(1, .monotonic);
        }
    };

    var pool = try WorkerPool.init(allocator, std.testing.io, "shutdown", 2, 16);
    defer pool.deinit();

    try std.testing.expect(pool.dispatch(.{ .run = Ctx.run, .ctx = null }));
    pool.shutdown();
    try std.testing.expect(!pool.dispatch(.{ .run = Ctx.run, .ctx = null }));

    const deadline = Time.monotonicNowMilliseconds() + 5000;
    while (Ctx.counter.load(.monotonic) < 1) {
        if (Time.monotonicNowMilliseconds() >= deadline) return error.Timeout;
        std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(u32, 1), Ctx.counter.load(.monotonic));
}

test "WorkerPool rejects worker_count == 0" {
    const allocator = std.testing.allocator;
    const pool = WorkerPool.init(allocator, std.testing.io, "zero", 0, 1);
    try std.testing.expectError(error.ConfigurationError, pool);
}

test "WorkerPool rejects worker_count above max_worker_count" {
    const allocator = std.testing.allocator;
    const pool = WorkerPool.init(allocator, std.testing.io, "huge", max_worker_count + 1, 1);
    try std.testing.expectError(error.ConfigurationError, pool);
}

test "WorkerPool stats and isOverloaded backpressure" {
    const allocator = std.testing.allocator;

    const Ctx = struct {
        flag: std.atomic.Value(bool) = .init(false),
        fn run(ctx: ?*anyopaque, io: std.Io) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            while (!self.flag.load(.acquire)) {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(1), .awake) catch {};
            }
        }
    };

    var ctx: Ctx = .{};
    var pool = try WorkerPool.init(allocator, std.testing.io, "stats-test", 1, 1);

    try std.testing.expect(pool.dispatch(.{ .run = Ctx.run, .ctx = &ctx }));
    _ = pool.dispatch(.{ .run = Ctx.run, .ctx = &ctx });

    const st = pool.stats();
    try std.testing.expectEqual(@as(usize, 1), st.total_workers);
    try std.testing.expect(pool.isOverloaded(0.50));

    ctx.flag.store(true, .release);
    pool.deinit();
}

test "WorkerPool stats toPrometheusFormat includes expected labels" {
    const allocator = std.testing.allocator;
    const st: WorkerPool.WorkerPoolStats = .{
        .pending_count = 3,
        .max_pending = 16,
        .active_workers = 2,
        .total_workers = 4,
        .completed_tasks = 42,
        .rejected_tasks = 1,
        .utilization_pct = 0.500,
    };

    const out = try st.toPrometheusFormat(allocator, "demo");
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_workerpool_pending_tasks{pool=\"demo\"} 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_workerpool_total_workers{pool=\"demo\"} 4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_workerpool_completed_tasks_total{pool=\"demo\"} 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_workerpool_rejected_tasks_total{pool=\"demo\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "zigmodu_workerpool_utilization{pool=\"demo\"} 0.500") != null);
}
