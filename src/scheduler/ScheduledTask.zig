const std = @import("std");

/// 定时任务调度器
pub const TaskScheduler = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    tasks: std.ArrayList(Task),
    running: bool,

    pub const Task = struct {
        id: u64,
        name: []const u8,
        schedule: Schedule,
        action: *const fn () void,
        last_run: i64,
        next_run: i64,
        run_count: u64,
    };

    pub const Schedule = union(enum) {
        cron: CronExpression,
        interval: u64, // seconds
        once: i64, // timestamp
    };

    pub const CronExpression = struct {
        minute: []const u8, // 0-59 or *
        hour: []const u8, // 0-23 or *
        day_of_month: []const u8, // 1-31 or *
        month: []const u8, // 1-12 or *
        day_of_week: []const u8, // 0-6 or *
    };

    var task_id_counter: u64 = 1;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .tasks = std.ArrayList(Task).empty,
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tasks.items) |task| {
            self.allocator.free(task.name);
        }
        self.tasks.deinit(self.allocator);
    }

    /// 添加 Cron 任务
    pub fn addCronTask(
        self: *Self,
        name: []const u8,
        cron: CronExpression,
        action: *const fn () void,
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const next_run = try self.calculateNextCronRun(cron);

        try self.tasks.append(self.allocator, .{
            .id = task_id_counter,
            .name = name_copy,
            .schedule = .{ .cron = cron },
            .action = action,
            .last_run = 0,
            .next_run = next_run,
            .run_count = 0,
        });

        task_id_counter += 1;
        std.log.info("Scheduled cron task: {s}", .{name});
    }

    /// 添加间隔任务
    pub fn addIntervalTask(
        self: *Self,
        name: []const u8,
        interval_seconds: u64,
        action: *const fn () void,
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);

        try self.tasks.append(self.allocator, .{
            .id = task_id_counter,
            .name = name_copy,
            .schedule = .{ .interval = interval_seconds },
            .action = action,
            .last_run = 0,
            .next_run = 0 + @as(i64, @intCast(interval_seconds)),
            .run_count = 0,
        });

        task_id_counter += 1;
        std.log.info("Scheduled interval task: {s} (every {d}s)", .{ name, interval_seconds });
    }

    /// 添加一次性任务
    pub fn addOneTimeTask(
        self: *Self,
        name: []const u8,
        timestamp: i64,
        action: *const fn () void,
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);

        try self.tasks.append(self.allocator, .{
            .id = task_id_counter,
            .name = name_copy,
            .schedule = .{ .once = timestamp },
            .action = action,
            .last_run = 0,
            .next_run = timestamp,
            .run_count = 0,
        });

        task_id_counter += 1;
        std.log.info("Scheduled one-time task: {s} at {d}", .{ name, timestamp });
    }

    /// 启动调度器
    pub fn start(self: *Self) !void {
        self.running = true;
        std.log.info("Task scheduler started with {d} tasks", .{self.tasks.items.len});

        // 简化实现：在实际应用中应该使用线程
        while (self.running) {
            self.tick() catch |err| {
                std.log.err("Task scheduler tick failed: {s}", .{@errorName(err)});
            };
            // std.Thread.sleep(1 * std.time.ns_per_s);// TODO: 0.16.0 needs io
        }
    }

    /// 停止调度器
    pub fn stop(self: *Self) void {
        self.running = false;
        std.log.info("Task scheduler stopped", .{});
    }

    /// 执行调度检查
    pub fn tick(self: *Self) !void {
        const now = 0;

        for (self.tasks.items) |*task| {
            if (now >= task.next_run) {
                // 执行任务
                std.log.info("Executing task: {s}", .{task.name});
                task.action();
                task.last_run = now;
                task.run_count += 1;

                // 计算下次执行时间
                switch (task.schedule) {
                    .cron => |cron| {
                        task.next_run = try self.calculateNextCronRun(cron);
                    },
                    .interval => |interval| {
                        task.next_run = now + @as(i64, @intCast(interval));
                    },
                    .once => {
                        // 一次性任务，标记为已完成
                        task.next_run = std.math.maxInt(i64);
                    },
                }
            }
        }
    }

    /// 计算下次 Cron 执行时间（简化实现）
    fn calculateNextCronRun(_self: *Self, cron: CronExpression) !i64 {
        _ = _self;
        _ = cron;
        // 简化实现：每小时执行
        const now = 0;
        return now + 3600;
    }

    /// 获取任务列表
    pub fn getTasks(self: *Self) []Task {
        return self.tasks.items;
    }

    /// 获取即将执行的任务
    pub fn getNextTask(self: *Self) ?*Task {
        if (self.tasks.items.len == 0) return null;

        var next_task: ?*Task = null;
        var earliest_time: i64 = std.math.maxInt(i64);

        for (self.tasks.items) |*task| {
            if (task.next_run < earliest_time) {
                earliest_time = task.next_run;
                next_task = task;
            }
        }

        return next_task;
    }

    /// 生成调度报告
    pub fn generateReport(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).empty;

        try buf.appendSlice(allocator, "=== Task Scheduler Report ===\n\n");
        try buf.print(allocator, "Total tasks: {d}\n", .{self.tasks.items.len});
        try buf.print(allocator, "Running: {s}\n\n", .{if (self.running) "Yes" else "No"});

        for (self.tasks.items) |task| {
            try buf.print(allocator, "Task: {s}\n", .{task.name});
            try buf.print(allocator, "  ID: {d}\n", .{task.id});
            try buf.print(allocator, "  Run count: {d}\n", .{task.run_count});
            try buf.print(allocator, "  Last run: {d}\n", .{task.last_run});
            try buf.print(allocator, "  Next run: {d}\n\n", .{task.next_run});
        }

        return buf.toOwnedSlice(allocator);
    }
};

/// Cron 表达式解析器
pub const CronParser = struct {
    /// 解析 Cron 字符串 (e.g., "0 0 * * *")
    pub fn parse(allocator: std.mem.Allocator, expression: []const u8) !TaskScheduler.CronExpression {
        var parts = std.mem.splitSequence(u8, expression, " ");

        const minute = parts.next() orelse return error.InvalidCronExpression;
        const hour = parts.next() orelse return error.InvalidCronExpression;
        const day_of_month = parts.next() orelse return error.InvalidCronExpression;
        const month = parts.next() orelse return error.InvalidCronExpression;
        const day_of_week = parts.next() orelse return error.InvalidCronExpression;

        return .{
            .minute = try allocator.dupe(u8, minute),
            .hour = try allocator.dupe(u8, hour),
            .day_of_month = try allocator.dupe(u8, day_of_month),
            .month = try allocator.dupe(u8, month),
            .day_of_week = try allocator.dupe(u8, day_of_week),
        };
    }
};

var action_counter: u32 = 0;
fn testAction() void {
    action_counter += 1;
}

test "TaskScheduler add and retrieve tasks" {
    const allocator = std.testing.allocator;
    var scheduler = TaskScheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.addIntervalTask("task1", 60, testAction);
    try scheduler.addOneTimeTask("task2", 0 + 300, testAction);

    try std.testing.expectEqual(@as(usize, 2), scheduler.getTasks().len);

    const next = scheduler.getNextTask();
    try std.testing.expect(next != null);
    try std.testing.expectEqualStrings("task1", next.?.name);
}

test "TaskScheduler tick executes task" {
    const allocator = std.testing.allocator;
    var scheduler = TaskScheduler.init(allocator);
    defer scheduler.deinit();

    action_counter = 0;
    const now = 0;
    try scheduler.addOneTimeTask("immediate", now - 1, testAction);

    try scheduler.tick();
    try std.testing.expectEqual(@as(u32, 1), action_counter);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), scheduler.getTasks()[0].next_run);
}

test "TaskScheduler generate report" {
    const allocator = std.testing.allocator;
    var scheduler = TaskScheduler.init(allocator);
    defer scheduler.deinit();

    try scheduler.addIntervalTask("report-task", 60, testAction);

    const report = try scheduler.generateReport(allocator);
    defer allocator.free(report);

    try std.testing.expect(std.mem.startsWith(u8, report, "=== Task Scheduler Report ==="));
    try std.testing.expect(std.mem.indexOf(u8, report, "report-task") != null);
}

test "CronParser parse" {
    const allocator = std.testing.allocator;
    const cron = try CronParser.parse(allocator, "0 12 * * 1");
    defer {
        allocator.free(cron.minute);
        allocator.free(cron.hour);
        allocator.free(cron.day_of_month);
        allocator.free(cron.month);
        allocator.free(cron.day_of_week);
    }

    try std.testing.expectEqualStrings("0", cron.minute);
    try std.testing.expectEqualStrings("12", cron.hour);
    try std.testing.expectEqualStrings("1", cron.day_of_week);
}
