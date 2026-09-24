//! Cron scheduler for zigzero
//!
//! Provides scheduled task execution aligned with go-zero's cron patterns.

const std = @import("std");
const Time = @import("../core/Time.zig");
const DistributedLock = @import("../core/DistributedLock.zig");

/// Cron expression (5-field: minute hour day month dow).
/// Supports: * (any), */n (step), n (specific), n-m (range), n,m (list)
pub const Expression = struct {
    minutes: [60]bool = @splat(false),
    hours: [24]bool = @splat(false),
    days: [32]bool = @splat(false),
    months: [13]bool = @splat(false),
    dows: [7]bool = @splat(false),

    /// Parse standard cron expression "m h d M w"
    pub fn parse(expr: []const u8) !Expression {
        var self = Expression{};
        var it = std.mem.splitScalar(u8, expr, ' ');
        var fi: usize = 0;
        while (it.next()) |part| : (fi += 1) {
            if (part.len == 0) continue;
            if (fi >= 5) return error.InvalidCronExpr;
            const target = switch (fi) {
                0 => &self.minutes,
                1 => &self.hours,
                2 => &self.days,
                3 => &self.months,
                4 => &self.dows,
                else => unreachable,
            };
            const max: u8 = switch (fi) {
                0 => 59,
                1 => 23,
                2 => 31,
                3 => 12,
                4 => 6,
                else => unreachable,
            };
            try parseField(part, target, max);
        }
        return self;
    }

    /// Check if current time matches expression
    pub fn matches(self: Expression, tm: i64) bool {
        const secs: u64 = @intCast(tm);
        const days = secs / 86400;
        const day_secs = secs % 86400;
        const min: usize = @intCast((day_secs / 60) % 60);
        const hr: usize = @intCast(day_secs / 3600);
        const d: usize = @intCast((days + 4) % 7); // 1970-01-01 was Thursday (dow=4)
        // Simple date calc for month/day
        var y: u64 = 1970;
        var remaining = days;
        while (true) {
            const yr_days: u64 = if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) 366 else 365;
            if (remaining < yr_days) break;
            remaining -= yr_days;
            y += 1;
        }
        const leap = y % 4 == 0 and (y % 100 != 0 or y % 400 == 0);
        const md = [_]u64{ 31, if (leap) @as(u64, 29) else @as(u64, 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var m: usize = 1;
        for (md) |dim| {
            if (remaining < dim) break;
            remaining -= dim;
            m += 1;
        }
        const dom: usize = @intCast(remaining + 1);
        return self.minutes[min] and self.hours[hr] and self.days[dom] and self.months[m] and self.dows[d];
    }
};

fn parseField(part: []const u8, target: []bool, max: u8) !void {
    if (std.mem.eql(u8, part, "*")) {
        for (0..@min(target.len, @as(usize, max) + 1)) |i| target[i] = true;
        return;
    }
    var sub = std.mem.splitScalar(u8, part, ',');
    while (sub.next()) |s| {
        if (std.mem.indexOfScalar(u8, s, '/')) |slash| {
            const base = s[0..slash];
            const step_str = s[slash + 1 ..];
            const step = std.fmt.parseInt(u8, step_str, 10) catch return error.InvalidCronExpr;
            if (std.mem.eql(u8, base, "*")) {
                var i: u8 = 0;
                while (i <= max) : (i += step) target[i] = true;
            } else {
                const start = std.fmt.parseInt(u8, base, 10) catch return error.InvalidCronExpr;
                var i = start;
                while (i <= max) : (i += step) target[i] = true;
            }
        } else if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
            const start_str = s[0..dash];
            const end_str = s[dash + 1 ..];
            const start = std.fmt.parseInt(u8, start_str, 10) catch return error.InvalidCronExpr;
            const end = std.fmt.parseInt(u8, end_str, 10) catch return error.InvalidCronExpr;
            var i = start;
            while (i <= end) : (i += 1) target[i] = true;
        } else {
            const v = std.fmt.parseInt(u8, s, 10) catch return error.InvalidCronExpr;
            if (v <= max) target[v] = true;
        }
    }
}

/// Scheduled job
pub const Job = struct {
    name: []const u8, // owned by the scheduler (duped in addJob)
    schedule: Expression,
    task: *const fn (*anyopaque) void,
    context: *anyopaque,
    last_run: i64,
};

/// Cron scheduler — periodic execution on a background thread.
/// Thread-safe: `addJob` may be called from any thread while the loop runs.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    jobs: std.ArrayList(Job),
    mutex: std.Io.Mutex,
    running: std.atomic.Value(bool),
    thread: ?std.Thread = null,
    tick_interval_ms: u64,
    /// Cross-instance guard. When set, a job whose lock is held by another
    /// replica is skipped for this tick. Default null = every instance runs
    /// every job (single-process behavior).
    lock: ?DistributedLock.Lock = null,
    lock_ttl_ms: u64 = 60_000,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Scheduler {
        return .{
            .allocator = allocator,
            .io = io,
            .jobs = std.ArrayList(Job).empty,
            .mutex = std.Io.Mutex.init,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .tick_interval_ms = 1000,
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.stop();
        // Uncancelable: a destructor has to run to completion. `std.Io.Mutex.lock`
        // fails only with `error.Canceled`, and "skip the cleanup because the lock
        // could not be taken" leaves every job name and the list's own storage
        // allocated with nothing left that could free them — `self.*` is
        // `undefined` by the time the old branch returned, so no later call can
        // repair it either. Same rule as `cache/Lru.zig`'s, `pool/Pool.zig`'s and
        // `im/BufferPool.zig`'s `deinit`. Red:
        // `scheduler.Cron.test.canceled lock wait does not let the scheduler
        // deinit leak its jobs` leaks the list (352 bytes) and the job name
        // ("leaky", 5 bytes) on the old shape.
        self.mutex.lockUncancelable(self.io);

        for (self.jobs.items) |job| self.allocator.free(job.name);
        self.jobs.deinit(self.allocator);

        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// Add a job to the scheduler. The name is copied, so the caller may reuse
    /// or free its buffer afterwards. Safe from any thread (mutex-protected
    /// against the background loop).
    ///
    /// The lock wait is a cancelation point this signature can report:
    /// `std.Io.Mutex.lock` fails only with `error.Canceled`, so the old
    /// `catch return error.SchedulerLockFailed` told the caller the scheduler's
    /// lock machinery had failed when the truth was that the caller was being
    /// canceled. Nothing is at stake — the job is not registered either way, and
    /// the `errdefer` above frees the copied name. Red:
    /// `scheduler.Cron.test.addJob and listJobNames report a canceled lock wait
    /// as error.Canceled` reads `expected error.Canceled, found
    /// error.SchedulerLockFailed`.
    pub fn addJob(self: *Scheduler, name: []const u8, schedule: Expression, task: *const fn (*anyopaque) void, context: *anyopaque) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        try self.jobs.append(self.allocator, .{
            .name = name_copy,
            .schedule = schedule,
            .task = task,
            .context = context,
            .last_run = 0,
        });
    }

    /// Guard every job with a cross-instance lock (cron on N replicas).
    /// `ttl_ms` must exceed the worst-case job runtime: a holder that dies
    /// without releasing is reaped once the TTL passes. The backing lock
    /// object must outlive the scheduler.
    pub fn setLock(self: *Scheduler, lock: DistributedLock.Lock, ttl_ms: u64) void {
        self.lock = lock;
        self.lock_ttl_ms = ttl_ms;
    }

    /// Start the scheduler in a background thread
    pub fn start(self: *Scheduler) !void {
        if (self.running.load(.monotonic)) return;
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Number of registered jobs (thread-safe).
    pub fn jobCount(self: *Scheduler) usize {
        // Uncancelable: `0` is a published reading, not a placeholder — it says "no
        // jobs are scheduled" while jobs are registered and firing. There is no
        // error channel (the `usize` *is* the answer), and `listJobNames` next door
        // reports `error.Canceled` rather than inventing a short list.
        // Red: `scheduler.Cron.test.canceled lock wait does not fabricate an empty
        // job count` reads `expected 1, found 0`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.jobs.items.len;
    }

    /// Duplicated names of registered jobs (caller frees each entry and the
    /// slice). Thread-safe.
    ///
    /// Same cancelation contract as `addJob`: the lock wait is reported as
    /// `error.Canceled`, never as a lock-machinery name, because that is the only
    /// way `std.Io.Mutex.lock` fails. Nothing is allocated before the lock is
    /// held, so a canceled wait leaves nothing behind.
    ///
    /// A failed copy unwinds the whole call: the names already written into the
    /// slice are freed along with it, because a caller that only sees
    /// `error.OutOfMemory` cannot reach a prefix it was never handed. Red:
    /// `scheduler.Cron.test.listJobNames frees the names it already copied when a
    /// later copy fails` leaks the 5-byte name and reads `expected 37, found 32`
    /// on `allocated_bytes`.
    pub fn listJobNames(self: *Scheduler, allocator: std.mem.Allocator) ![][]const u8 {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        const out = try allocator.alloc([]const u8, self.jobs.items.len);
        var filled: usize = 0;
        errdefer {
            for (out[0..filled]) |name| allocator.free(name);
            allocator.free(out);
        }
        for (self.jobs.items, 0..) |job, i| {
            out[i] = try allocator.dupe(u8, job.name);
            filled = i + 1;
        }
        return out;
    }

    /// Remove a job by name. Returns true when removed. Thread-safe.
    pub fn cancelJob(self: *Scheduler, name: []const u8) bool {
        // Uncancelable: `false` answers "there is no such job", and it is also the
        // only channel this function has — so a canceled wait does not merely
        // skip a removal, it reports the job as gone while the job stays
        // registered and keeps firing on every matching tick. Red:
        // `scheduler.Cron.test.canceled lock wait does not report a live job as
        // missing`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items, 0..) |job, i| {
            if (std.mem.eql(u8, job.name, name)) {
                self.allocator.free(job.name);
                _ = self.jobs.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Stop the scheduler
    pub fn stop(self: *Scheduler) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Run one scheduling pass for the given instant. Public so callers and
    /// tests can drive scheduling deterministically (the background loop calls
    /// this once per tick).
    pub fn tick(self: *Scheduler, now: i64) void {
        // Uncancelable: the pass has no error channel, and abandoning the wait
        // drops every job whose minute this is without telling the caller a pass
        // was skipped (the loop retries a second later, but only while the caller
        // stays cancelable). The critical section is the jobs themselves — the
        // same reason `ThreadSafeEventBus.publish` holds its mutex across the
        // callbacks. Red: `scheduler.Cron.test.canceled lock wait does not skip a
        // due tick` reads `expected 1, found 0`.
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const minute_start = @divFloor(now, 60) * 60;
        for (self.jobs.items) |*job| {
            if (!job.schedule.matches(now) or job.last_run >= minute_start) continue;
            // Marked as due either way: if another replica owns this minute we
            // must not hammer the lock on every tick.
            job.last_run = now;
            const lock = self.lock orelse {
                job.task(job.context);
                continue;
            };
            const key = std.fmt.allocPrint(self.allocator, "cron:{s}", .{job.name}) catch {
                std.log.err("[cron] {s}: cannot build lock name; skipping this tick", .{job.name});
                continue;
            };
            defer self.allocator.free(key);
            const acquired = lock.tryAcquire(key, self.lock_ttl_ms) catch |err| {
                std.log.err("[cron] {s}: lock acquire failed ({s}); skipping this tick", .{ job.name, @errorName(err) });
                continue;
            };
            if (!acquired) continue; // another replica is running it
            defer lock.release(key);
            job.task(job.context);
        }
    }

    fn runLoop(self: *Scheduler) void {
        while (self.running.load(.monotonic)) {
            self.tick(Time.monotonicNowSeconds());
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(self.tick_interval_ms)), .real) catch |sleep_err| std.log.debug("[cron] tick sleep interrupted ({s})", .{@errorName(sleep_err)});
        }
    }
};

/// Block for `seconds`, then run `task` once (blocking helper).
/// Use `Scheduler` for recurring jobs.
pub fn every(io: std.Io, seconds: u64, task: *const fn (*anyopaque) void, context: *anyopaque) void {
    std.Io.sleep(io, std.Io.Duration.fromSeconds(@intCast(seconds)), .real) catch |err| std.log.debug("[cron] every(): sleep interrupted ({s})", .{@errorName(err)});
    task(context);
}

test "cron parse wildcard" {
    const expr = try Expression.parse("* * * * *");
    try std.testing.expect(expr.minutes[0]);
    try std.testing.expect(expr.minutes[59]);
    try std.testing.expect(expr.hours[0]);
    try std.testing.expect(expr.hours[23]);
}

test "cron parse specific" {
    const expr = try Expression.parse("30 9 * * *");
    try std.testing.expect(expr.minutes[30]);
    try std.testing.expect(!expr.minutes[0]);
    try std.testing.expect(expr.hours[9]);
    try std.testing.expect(!expr.hours[0]);
}

test "cron parse step" {
    const expr = try Expression.parse("*/5 * * * *");
    try std.testing.expect(expr.minutes[0]);
    try std.testing.expect(expr.minutes[5]);
    try std.testing.expect(expr.minutes[10]);
    try std.testing.expect(!expr.minutes[1]);
}

test "cron parse range" {
    const expr = try Expression.parse("0 9-17 * * *");
    try std.testing.expect(expr.minutes[0]);
    try std.testing.expect(expr.hours[9]);
    try std.testing.expect(expr.hours[17]);
    try std.testing.expect(!expr.hours[8]);
}

test "scheduler tick fires a matching job once per minute" {
    const allocator = std.testing.allocator;
    var count: usize = 0;
    const T = struct {
        fn run(ptr: *anyopaque) void {
            const c: *usize = @ptrCast(@alignCast(ptr));
            c.* += 1;
        }
    };

    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    const expr = try Expression.parse("* * * * *");
    try scheduler.addJob("every-minute", expr, T.run, &count);
    try std.testing.expectEqual(@as(usize, 1), scheduler.jobCount());

    const now = Time.monotonicNowSeconds();
    scheduler.tick(now);
    try std.testing.expectEqual(@as(usize, 1), count);
    scheduler.tick(now);
    try std.testing.expectEqual(@as(usize, 1), count); // same minute: no re-run
    scheduler.tick(now + 60);
    try std.testing.expectEqual(@as(usize, 2), count); // next minute: runs again
}

test "scheduler start and stop lifecycle" {
    var scheduler = Scheduler.init(std.testing.allocator, std.testing.io);
    defer scheduler.deinit();
    try scheduler.start();
    try std.testing.expect(scheduler.running.load(.monotonic));
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(50), .real) catch {};
    scheduler.stop();
    try std.testing.expect(!scheduler.running.load(.monotonic));
}

test "every runs the task after the delay" {
    var count: usize = 0;
    const T = struct {
        fn run(ptr: *anyopaque) void {
            const c: *usize = @ptrCast(@alignCast(ptr));
            c.* += 1;
        }
    };
    every(std.testing.io, 0, T.run, &count);
    try std.testing.expectEqual(@as(usize, 1), count);
}

fn countTask(ctx: *anyopaque) void {
    const counter: *usize = @ptrCast(@alignCast(ctx));
    counter.* += 1;
}

test "cron: a job held by another replica is skipped, then runs once freed" {
    const allocator = std.testing.allocator;
    const SqlClient = @import("../sqlx/sqlx.zig").Client;
    var db = SqlClient.init(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 1,
        .max_idle_conns = 1,
    });
    defer db.deinit();

    var sched = Scheduler.init(allocator, std.testing.io);
    defer sched.deinit();
    var sched_lock = try DistributedLock.SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_cron_lock", .sqlite);
    defer sched_lock.deinit();
    sched.setLock(sched_lock.lock(), 60_000);

    // A second owner stands in for the replica that is currently running the
    // job (or that crashed and whose TTL has not elapsed yet).
    var other_replica = try DistributedLock.SqlLock(@TypeOf(db)).init(allocator, std.testing.io, &db, "zmodu_cron_lock", .sqlite);
    defer other_replica.deinit();
    try std.testing.expect(try other_replica.lock().tryAcquire("cron:nightly", 60_000));

    var runs: usize = 0;
    try sched.addJob("nightly", try Expression.parse("* * * * *"), countTask, &runs);

    const now: i64 = 1_700_000_040;
    sched.tick(now);
    // Locked elsewhere → this replica stays out of the way (the duplicate
    // side-effect this guard exists to prevent).
    try std.testing.expectEqual(@as(usize, 0), runs);

    other_replica.lock().release("cron:nightly");
    sched.tick(now + 60);
    try std.testing.expectEqual(@as(usize, 1), runs);

    // The winner released when its tick ended, so the slot is free again.
    try std.testing.expect(try other_replica.lock().tryAcquire("cron:nightly", 60_000));
}

test "cron: no lock configured keeps single-process behavior" {
    const allocator = std.testing.allocator;
    var sched = Scheduler.init(allocator, std.testing.io);
    defer sched.deinit();

    var runs: usize = 0;
    try sched.addJob("plain", try Expression.parse("* * * * *"), countTask, &runs);
    sched.tick(1_700_000_040);
    try std.testing.expectEqual(@as(usize, 1), runs);
    // Same minute: not due again.
    sched.tick(1_700_000_045);
    try std.testing.expectEqual(@as(usize, 1), runs);
}

// A destructor has to run to completion. `deinit`'s old shape answered a
// contended lock by *skipping* the cleanup (`locked = false`), which leaves every
// job name and the list's own storage allocated with nothing left that could free
// them — the scheduler is `undefined` by the time that branch returns. Same rule
// as `cache/Lru.zig`'s, `pool/Pool.zig`'s and `im/BufferPool.zig`'s `deinit`:
// wait, do not skip.
//
// Red evidence: with the old shape this test fails on the leak the testing
// allocator reports (`FAIL (MemoryLeakDetected)`, one leaked job name plus the
// list). The lock wait is the cancelation point: the task is parked on the
// scheduler's mutex (held by the test thread) with a cancel request already
// placed on its thread.
test "canceled lock wait does not let the scheduler deinit leak its jobs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var runs: usize = 0;
    var scheduler = Scheduler.init(allocator, io);
    try scheduler.addJob("leaky", try Expression.parse("* * * * *"), countTask, &runs);

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var deinited = std.atomic.Value(bool).init(false);

        fn teardown(s: *Scheduler) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            s.deinit();
            deinited.store(true, .release);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.deinited.store(false, .monotonic);

    try scheduler.mutex.lock(io);

    var task_fut = try io.concurrent(Task.teardown, .{&scheduler});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (scheduler.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    scheduler.mutex.unlock(io);

    cancel_fut.await(io);
    task_fut.await(io);

    // `scheduler` is `undefined` after a `deinit` that ran, so nothing here may
    // touch it — and no `defer scheduler.deinit()`: a second deinit would either
    // double-free (if the first skipped) or be undefined behaviour (if it did not).
    try std.testing.expect(Task.deinited.load(.acquire));
}

// `cancelJob` answering a canceled lock wait with `false` reports "no job by that
// name" while the job stays registered and keeps running on every matching tick —
// the one reading a caller uses to decide the job is gone (and to stop waiting for
// its side effects). There is no error channel: the `bool` *is* the answer.
//
// Red evidence: with the old `self.mutex.lock(self.io) catch return false` both
// assertions below fail — `expected true, found false` and then
// `expected 0, found 1`: the job is still scheduled.
test "canceled lock wait does not report a live job as missing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var scheduler = Scheduler.init(allocator, io);
    defer scheduler.deinit();
    var runs: usize = 0;
    try scheduler.addJob("nightly", try Expression.parse("* * * * *"), countTask, &runs);

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var removed: bool = false;

        fn cancel_job(s: *Scheduler) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            removed = s.cancelJob("nightly");
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.removed = false;

    try scheduler.mutex.lock(io);

    var task_fut = try io.concurrent(Task.cancel_job, .{&scheduler});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (scheduler.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    scheduler.mutex.unlock(io);

    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expect(Task.removed);
    try std.testing.expectEqual(@as(usize, 0), scheduler.jobCount());
}

// `jobCount` answering a canceled lock wait with `0` reports "no jobs scheduled"
// while jobs are registered and firing on every matching tick — the reading an
// operator checks wiring with, and the one `listJobNames` next door contradicts
// (it *has* an error channel and reports `error.Canceled` instead of
// inventing a short list). The count is a `usize`, so there is nowhere to put the
// cancelation, and the critical section is a length read.
//
// Red evidence: with the old `self.mutex.lock(self.io) catch return 0` the
// assertion below fails with `expected 1, found 0`.
test "canceled lock wait does not fabricate an empty job count" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var scheduler = Scheduler.init(allocator, io);
    defer scheduler.deinit();
    var runs: usize = 0;
    try scheduler.addJob("counted", try Expression.parse("* * * * *"), countTask, &runs);
    try std.testing.expectEqual(@as(usize, 1), scheduler.jobCount());

    const Task = struct {
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);
        var count: usize = 0;

        fn read(s: *Scheduler) void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            count = s.jobCount();
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);
    Task.count = 0;

    try scheduler.mutex.lock(io);

    var read_fut = try io.concurrent(Task.read, .{&scheduler});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &read_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (scheduler.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    scheduler.mutex.unlock(io);

    cancel_fut.await(io);
    read_fut.await(io);

    try std.testing.expectEqual(@as(usize, 1), Task.count);
}

// `addJob` and `listJobNames` answered a canceled lock with
// `error.SchedulerLockFailed`. Nothing is fabricated by that name — neither call
// did its work — but it is the wrong fact: `std.Io.Mutex.lock` fails only with
// `error.Canceled`, so a cancelation was reported as lock-machinery failure, and
// a caller cannot tell "unwind, you were canceled" from "this scheduler's lock is
// broken". Both error sets are inferred and nothing is allocated before the lock
// is held, so naming the truth costs no call site.
//
// Red evidence: with the old `catch return error.SchedulerLockFailed` both
// assertions below read `expected error.Canceled, found error.SchedulerLockFailed`.
test "addJob and listJobNames report a canceled lock wait as error.Canceled" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Task = struct {
        var sched: *Scheduler = undefined;
        var op: *const fn (*Scheduler) void = undefined;
        var schedule: Expression = undefined;
        var job_ctx: u8 = 0;
        var add_err: ?anyerror = null;
        var list_err: ?anyerror = null;
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn onAdd(s: *Scheduler) void {
            s.addJob("nightly", schedule, noop, &job_ctx) catch |e| {
                add_err = e;
            };
        }

        fn onList(s: *Scheduler) void {
            const names = s.listJobNames(std.testing.allocator) catch |e| {
                list_err = e;
                return;
            };
            for (names) |n| std.testing.allocator.free(n);
            std.testing.allocator.free(names);
        }

        fn noop(_: *anyopaque) void {}

        fn body() void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            op(sched);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }

        /// Park the task on the scheduler mutex this thread holds, place the
        /// cancelation request while it is parked, then release the lock: the
        /// call reports whatever it answers a canceled wait with.
        fn run(op_fn: *const fn (*Scheduler) void) !void {
            op = op_fn;
            entered.store(false, .monotonic);
            open.store(false, .monotonic);

            try sched.mutex.lock(io);
            var task_fut = try io.concurrent(body, .{});
            while (!entered.load(.acquire)) std.atomic.spinLoopHint();

            var cancel_fut = try io.concurrent(cancel, .{ io, &task_fut });
            try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

            open.store(true, .release);
            while (sched.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
            sched.mutex.unlock(io);
            cancel_fut.await(io);
            task_fut.await(io);
        }
    };

    var sched = Scheduler.init(allocator, io);
    defer sched.deinit();
    Task.sched = &sched;
    Task.schedule = try Expression.parse("* * * * *");

    Task.add_err = null;
    try Task.run(Task.onAdd);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Task.add_err);
    // The failure was real: no job was registered (and the copied name was freed).
    try std.testing.expectEqual(@as(usize, 0), sched.jobCount());

    Task.list_err = null;
    try Task.run(Task.onList);
    try std.testing.expectEqual(@as(?anyerror, error.Canceled), Task.list_err);
}

// `tick` answered a canceled lock wait with `return`: the pass was abandoned
// silently, so every job whose minute it was never ran and nothing told the
// caller a pass had been skipped. The pass has no error channel, and its critical
// section is the jobs themselves — the same reason
// `ThreadSafeEventBus.publish` holds its mutex across the callbacks — so it
// waits.
//
// Red evidence: with the old `catch return` the assertion below reads
// `expected 1, found 0`.
test "canceled lock wait does not skip a due tick" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Task = struct {
        var sched: *Scheduler = undefined;
        var runs = std.atomic.Value(usize).init(0);
        var entered = std.atomic.Value(bool).init(false);
        var open = std.atomic.Value(bool).init(false);

        fn count(_: *anyopaque) void {
            _ = runs.fetchAdd(1, .monotonic);
        }

        fn body() void {
            entered.store(true, .release);
            while (!open.load(.acquire)) std.atomic.spinLoopHint();
            // 2023-11-14T22:15:40Z — a second "* * * * *" matches.
            sched.tick(1_700_000_140);
        }

        fn cancel(thread_io: std.Io, fut: *std.Io.Future(void)) void {
            fut.cancel(thread_io);
        }
    };

    var sched = Scheduler.init(allocator, io);
    defer sched.deinit();
    var job_ctx: u8 = 0;
    try sched.addJob("nightly", try Expression.parse("* * * * *"), Task.count, &job_ctx);
    Task.sched = &sched;

    Task.runs.store(0, .monotonic);
    Task.entered.store(false, .monotonic);
    Task.open.store(false, .monotonic);

    try sched.mutex.lock(io);
    var task_fut = try io.concurrent(Task.body, .{});
    while (!Task.entered.load(.acquire)) std.atomic.spinLoopHint();

    var cancel_fut = try io.concurrent(Task.cancel, .{ io, &task_fut });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    Task.open.store(true, .release);
    while (sched.mutex.state.load(.monotonic) != .contended) std.atomic.spinLoopHint();
    sched.mutex.unlock(io);
    cancel_fut.await(io);
    task_fut.await(io);

    try std.testing.expectEqual(@as(usize, 1), Task.runs.load(.monotonic));
}

// `listJobNames` freed the result slice when a name copy failed but not the
// names already copied into it. With two jobs, a failure on the second copy left
// "alpha" allocated in a slice the caller never received: `error.OutOfMemory` is
// all it got back, so it had nothing to free and no way to reach the name — a
// leak on every failable call.
//
// Allocation #0 is the result slice and #1..#N the name copies, so failing #2 is
// exactly "one name was already in the list". Red evidence: without the loop
// `errdefer` this test fails twice over: `[SafeAllocator] (err): leaked [addr:
// …, len: 5 (0x5) align: 1]` points at the copy in this function, and the byte
// check below reads `expected 37, found 32`.
test "listJobNames frees the names it already copied when a later copy fails" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const Noop = struct {
        fn run(_: *anyopaque) void {}
    };

    var sched = Scheduler.init(allocator, io);
    defer sched.deinit();
    var ctx_a: u8 = 0;
    var ctx_b: u8 = 0;
    const schedule = try Expression.parse("* * * * *");
    try sched.addJob("alpha", schedule, Noop.run, &ctx_a);
    try sched.addJob("bravo", schedule, Noop.run, &ctx_b);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, sched.listJobNames(failing.allocator()));
    try std.testing.expect(failing.has_induced_failure);
    // The name copied before the failure and the slice holding it are both back,
    // so the caller owes nothing and the harness finds nothing.
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);

    // The failed read left the scheduler alone: both jobs still list.
    const names = try sched.listJobNames(allocator);
    defer allocator.free(names);
    defer for (names) |n| allocator.free(n);
    try std.testing.expectEqual(@as(usize, 2), names.len);
}
