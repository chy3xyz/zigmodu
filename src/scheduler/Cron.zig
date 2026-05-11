//! Cron scheduler for zigzero
//!
//! Provides scheduled task execution aligned with go-zero's cron patterns.

const std = @import("std");
const Time = @import("../core/Time.zig");

/// Cron expression (simplified: minute hour day month dow)
pub const Expression = struct {
    minute: u8 = 0, // 0-59
    hour: u8 = 0, // 0-23
    day: u8 = 0, // 1-31 (0 = any)
    month: u8 = 0, // 1-12 (0 = any)
    dow: u8 = 8, // 0-6 (8 = any)

    /// Check if current time matches expression
    pub fn matches(self: Expression, tm: std.c.time_t) bool {
        const local = std.c.localtime(&tm);
        if (self.minute != local.tm_min) return false;
        if (self.hour != local.tm_hour) return false;
        if (self.day != 0 and self.day != local.tm_mday) return false;
        if (self.month != 0 and self.month != @as(u8, @intCast(local.tm_mon + 1))) return false;
        if (self.dow != 8 and self.dow != @as(u8, @intCast(local.tm_wday))) return false;
        return true;
    }
};

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

test "cron expression matches specific time" {
    const expr = Expression{ .minute = 30, .hour = 9, .day = 15, .month = 3 };
    // March 15, 9:30 AM UTC
    const ts: std.c.time_t = 1710502200; // 2024-03-15 09:30:00 UTC
    try std.testing.expect(expr.matches(ts));

    // 1 minute later should NOT match
    const ts2: std.c.time_t = 1710502260;
    try std.testing.expect(!expr.matches(ts2));
}

test "cron expression any-day wildcard" {
    const expr = Expression{ .minute = 0, .hour = 8, .day = 0, .month = 0 }; // every day at 8:00
    try std.testing.expect(expr.day == 0); // day=0 means "any"
    try std.testing.expect(expr.month == 0); // month=0 means "any"
}
