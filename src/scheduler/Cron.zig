//! Cron scheduler for zigzero
//!
//! Provides scheduled task execution aligned with go-zero's cron patterns.

const std = @import("std");
const Time = @import("../core/Time.zig");

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
        self.mutex.lock(self.io) catch {};
        for (self.jobs.items) |job| self.allocator.free(job.name);
        self.jobs.deinit(self.allocator);
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    /// Add a job to the scheduler. The name is copied, so the caller may reuse
    /// or free its buffer afterwards. Safe from any thread (mutex-protected
    /// against the background loop).
    pub fn addJob(self: *Scheduler, name: []const u8, schedule: Expression, task: *const fn (*anyopaque) void, context: *anyopaque) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        self.mutex.lock(self.io) catch return error.SchedulerLockFailed;
        defer self.mutex.unlock(self.io);
        try self.jobs.append(self.allocator, .{
            .name = name_copy,
            .schedule = schedule,
            .task = task,
            .context = context,
            .last_run = 0,
        });
    }

    /// Start the scheduler in a background thread
    pub fn start(self: *Scheduler) !void {
        if (self.running.load(.monotonic)) return;
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    /// Number of registered jobs (thread-safe).
    pub fn jobCount(self: *Scheduler) usize {
        self.mutex.lock(self.io) catch return 0;
        defer self.mutex.unlock(self.io);
        return self.jobs.items.len;
    }

    /// Duplicated names of registered jobs (caller frees each entry and the
    /// slice). Thread-safe.
    pub fn listJobNames(self: *Scheduler, allocator: std.mem.Allocator) ![][]const u8 {
        self.mutex.lock(self.io) catch return error.SchedulerLockFailed;
        defer self.mutex.unlock(self.io);
        const out = try allocator.alloc([]const u8, self.jobs.items.len);
        errdefer allocator.free(out);
        for (self.jobs.items, 0..) |job, i| out[i] = try allocator.dupe(u8, job.name);
        return out;
    }

    /// Remove a job by name. Returns true when removed. Thread-safe.
    pub fn cancelJob(self: *Scheduler, name: []const u8) bool {
        self.mutex.lock(self.io) catch return false;
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
        self.mutex.lock(self.io) catch return;
        defer self.mutex.unlock(self.io);
        const minute_start = @divFloor(now, 60) * 60;
        for (self.jobs.items) |*job| {
            if (job.schedule.matches(now) and job.last_run < minute_start) {
                job.task(job.context);
                job.last_run = now;
            }
        }
    }

    fn runLoop(self: *Scheduler) void {
        while (self.running.load(.monotonic)) {
            self.tick(Time.monotonicNowSeconds());
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(self.tick_interval_ms)), .real) catch {};
        }
    }
};

/// Block for `seconds`, then run `task` once (blocking helper).
/// Use `Scheduler` for recurring jobs.
pub fn every(io: std.Io, seconds: u64, task: *const fn (*anyopaque) void, context: *anyopaque) void {
    std.Io.sleep(io, std.Io.Duration.fromSeconds(@intCast(seconds)), .real) catch {};
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
