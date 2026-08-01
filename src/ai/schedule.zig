//! Thin AI ⇄ cron bridge.
//!
//! Lets an Agent schedule **pre-registered named tasks** on cron expressions
//! via tool calls. The LLM only supplies a task name + cron expression — it
//! never provides code. Tasks themselves are plain Zig functions the app
//! registers up front, so the bridge stays within the framework's "controlled
//! execution" posture (see docs/AI.md).

const std = @import("std");
const Scheduler = @import("../scheduler/Cron.zig").Scheduler;
const Expression = @import("../scheduler/Cron.zig").Expression;
const SkillRegistry = @import("skill.zig").SkillRegistry;
const SkillContext = @import("skill.zig").SkillContext;
const Time = @import("../core/Time.zig");

/// A named, schedulable task the LLM may attach to a cron expression.
pub const ScheduledTask = struct {
    name: []const u8,
    description: []const u8,
    task: *const fn (*anyopaque) void,
    context: *anyopaque,
};

/// Register `list_schedulable_tasks` and `schedule_job` skills backed by
/// `scheduler`. Tasks are looked up by name from `tasks` (borrowed — the
/// caller must keep them alive for the scheduler's lifetime).
pub fn registerScheduleSkills(
    registry: *SkillRegistry,
    scheduler: *Scheduler,
    tasks: []const ScheduledTask,
) !void {
    try registry.register(.{
        .name = "list_schedulable_tasks",
        .description = "List tasks that can be scheduled and their descriptions",
        .parameters = &.{},
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                _ = args;
                var out = std.json.ObjectMap{};
                var arr = std.json.Array.init(ctx.allocator);
                for (tasks) |t| {
                    var obj = std.json.ObjectMap{};
                    try obj.put(ctx.allocator, "name", .{ .string = t.name });
                    try obj.put(ctx.allocator, "description", .{ .string = t.description });
                    try arr.append(ctx.allocator, .{ .object = obj });
                }
                try out.put(ctx.allocator, "tasks", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "schedule_job",
        .description = "Schedule a named task on a 5-field cron expression (minute hour day-of-month month day-of-week; e.g. '0 9 * * *' for 09:00 daily)",
        .parameters = &.{
            .{ .name = "task", .type = .string, .description = "Task name from list_schedulable_tasks", .required = true },
            .{ .name = "expr", .type = .string, .description = "Cron expression", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const obj = args.object;
                const task_value = obj.get("task") orelse return error.InvalidArguments;
                const expr_value = obj.get("expr") orelse return error.InvalidArguments;
                if (task_value != .string or expr_value != .string) return error.InvalidArguments;

                var found: ?ScheduledTask = null;
                for (tasks) |t| {
                    if (std.mem.eql(u8, t.name, task_value.string)) {
                        found = t;
                        break;
                    }
                }
                const entry = found orelse return error.TaskNotFound;

                const expr = try Expression.parse(expr_value.string);
                try scheduler.addJob(task_value.string, expr, entry.task, entry.context);

                var out = std.json.ObjectMap{};
                try out.put(ctx.allocator, "ok", .{ .bool = true });
                try out.put(ctx.allocator, "job", .{ .string = task_value.string });
                try out.put(ctx.allocator, "expr", .{ .string = expr_value.string });
                return .{ .object = out };
            }
        }.h,
    });
}

test "schedule skills list tasks and schedule a job that fires on tick" {
    const allocator = std.testing.allocator;
    var count: usize = 0;
    const T = struct {
        fn run(ptr: *anyopaque) void {
            const c: *usize = @ptrCast(@alignCast(ptr));
            c.* += 1;
        }
    };
    const tasks = [_]ScheduledTask{
        .{ .name = "ping", .description = "increment a counter", .task = T.run, .context = &count },
    };

    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerScheduleSkills(&registry, &scheduler, &tasks);

    var ctx = SkillContext{ .allocator = allocator };

    // list_schedulable_tasks returns the registered task.
    const list = try registry.dispatch("list_schedulable_tasks", &ctx, .{ .object = .{} });
    try std.testing.expect(list == .object);
    try std.testing.expectEqual(@as(usize, 1), list.object.get("tasks").?.array.items.len);
    try std.testing.expectEqualStrings("ping", list.object.get("tasks").?.array.items[0].object.get("name").?.string);

    // schedule_job adds a job to the scheduler.
    var args_map = std.json.ObjectMap{};
    try args_map.put(allocator, "task", .{ .string = "ping" });
    try args_map.put(allocator, "expr", .{ .string = "* * * * *" });
    const res = try registry.dispatch("schedule_job", &ctx, .{ .object = args_map });
    try std.testing.expect(res.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(usize, 1), scheduler.jobCount());

    // The scheduled job fires on the next matching tick.
    const now = Time.monotonicNowSeconds();
    scheduler.tick(now);
    try std.testing.expectEqual(@as(usize, 1), count);
}
