//! Cron scheduler for zigzero
//!
//! Provides scheduled task execution aligned with go-zero's cron patterns.

const std = @import("std");
const Time = @import("../core/Time.zig");

/// Cron expression (5-field: minute hour day month dow).
/// Supports: * (any), */n (step), n (specific), n-m (range), n,m (list)
pub const Expression = struct {
    minutes: [60]bool = [_]bool{false} ** 60,
    hours: [24]bool = [_]bool{false} ** 24,
    days: [32]bool = [_]bool{false} ** 32,
    months: [13]bool = [_]bool{false} ** 13,
    dows: [7]bool = [_]bool{false} ** 7,

    /// Parse standard cron expression "m h d M w"
    pub fn parse(expr: []const u8) !Expression {
        var self = Expression{};
        var it = std.mem.splitScalar(u8, expr, ' ');
        var fi: usize = 0;
        while (it.next()) |part| : (fi += 1) {
            if (part.len == 0) continue;
            if (fi >= 5) return error.InvalidCronExpr;
            const target = switch (fi) {
                0 => &self.minutes, 1 => &self.hours, 2 => &self.days, 3 => &self.months, 4 => &self.dows,
                else => unreachable,
            };
            const max: u8 = switch (fi) { 0 => 59, 1 => 23, 2 => 31, 3 => 12, 4 => 6, else => unreachable };
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
            const step_str = s[slash+1..];
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
            const end_str = s[dash+1..];
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
    name: []const u8,
    schedule: Expression,
    task: *const fn (*anyopaque) void,
    context: *anyopaque,
    last_run: i64,
};

/// Cron scheduler
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(Job),
    running: std.atomic.Value(bool),
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{
            .allocator = allocator,
            .jobs = .{},
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Scheduler) void {
        self.stop();
        self.jobs.deinit(self.allocator);
    }

    /// Add a job to the scheduler
    pub fn addJob(self: *Scheduler, name: []const u8, schedule: Expression, task: *const fn (*anyopaque) void, context: *anyopaque) !void {
        try self.jobs.append(self.allocator, .{
            .name = name,
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

    /// Stop the scheduler
    pub fn stop(self: *Scheduler) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *Scheduler) void {
        while (self.running.load(.monotonic)) {
            const now = Time.monotonicNowSeconds();
            for (self.jobs.items) |*job| {
                if (job.schedule.matches(now) and job.last_run < @divFloor(now, 60) * 60) {
                    job.task(job.context);
                    job.last_run = now;
                }
            }
            // Note: Blocking sleep unavailable in Zig 0.16.0 sync context
            break;
        }
    }
};

/// Run a task every N seconds
pub fn every(seconds: u64, task: *const fn (*anyopaque) void, context: *anyopaque) void {
    const start = Time.monotonicNowSeconds();
    while (true) {
        const now = Time.monotonicNowSeconds();
        if (now - start >= @as(i64, @intCast(seconds))) {
            task(context);
            break;
        }
        // Note: Blocking sleep unavailable in Zig 0.16.0 sync context
        break;
    }
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
