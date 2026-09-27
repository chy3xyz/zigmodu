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
const freeValue = @import("skill.zig").freeValue;
const skill = @import("skill.zig");

/// ObjectMap does not copy keys and deinit does not free them; results must
/// own every key so `freeValue` can release them.
fn putOwned(obj: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    // The key copy needs its own guard: built as the `put` argument it was
    // stranded whenever the map refused the field. The disarmed-by-`return`
    // guard leaves the value's contract alone — a `.string` here is still
    // owned by the caller.
    const k = try allocator.dupe(u8, key);
    errdefer allocator.free(k);
    try obj.put(allocator, k, value);
}
const Time = @import("../core/Time.zig");

/// A named, schedulable task the LLM may attach to a cron expression.
pub const ScheduledTask = struct {
    name: []const u8,
    description: []const u8,
    task: *const fn (*anyopaque) void,
    context: *anyopaque,
};

/// Capability bundle for the schedule skills: the cron `Scheduler` plus the
/// whitelist of named tasks the LLM may schedule. The caller owns this value
/// (keep it alive for the registry's lifetime) and sets
/// `SkillContext.userdata = &schedule_ctx` before dispatch.
pub const ScheduleCtx = struct {
    scheduler: *Scheduler,
    tasks: []const ScheduledTask,
};

/// Register schedule skills (`list_schedulable_tasks`, `schedule_job`,
/// `list_jobs`, `cancel_job`) backed by `ScheduleCtx` (see above).
pub fn registerScheduleSkills(
    registry: *SkillRegistry,
) !void {
    try registry.register(.{
        .name = "list_schedulable_tasks",
        .action = .read,
        .description = "List tasks that can be scheduled and their descriptions",
        .parameters = &.{},
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                _ = args;
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                var out = std.json.ObjectMap{};
                // Each level is guarded until its hand-over: the `return`
                // hands the tree to the caller, the final put hands `arr` to
                // `out`, and the loop's append hands each task object to
                // `arr`. The string fields are copied by `putJsonField`
                // (self-guarding) — a dupe built as the `putOwned` argument
                // had no owner when the put failed.
                errdefer freeValue(ctx.allocator, .{ .object = out });
                var arr = std.json.Array.init(ctx.allocator);
                errdefer freeValue(ctx.allocator, .{ .array = arr });
                for (sc.tasks) |t| {
                    var obj = std.json.ObjectMap{};
                    errdefer freeValue(ctx.allocator, .{ .object = obj });
                    try skill.putJsonField(ctx.allocator, &obj, "name", .{ .string = t.name });
                    try skill.putJsonField(ctx.allocator, &obj, "description", .{ .string = t.description });
                    try arr.append(.{ .object = obj });
                }
                try putOwned(&out, ctx.allocator, "tasks", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "schedule_job",
        .action = .execute,
        .description = "Schedule a named task on a 5-field cron expression (minute hour day-of-month month day-of-week; e.g. '0 9 * * *' for 09:00 daily)",
        .parameters = &.{
            .{ .name = "task", .type = .string, .description = "Task name from list_schedulable_tasks", .required = true },
            .{ .name = "expr", .type = .string, .description = "Cron expression", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                const obj = args.object;
                const task_value = obj.get("task") orelse return error.InvalidArguments;
                const expr_value = obj.get("expr") orelse return error.InvalidArguments;
                if (task_value != .string or expr_value != .string) return error.InvalidArguments;

                var found: ?ScheduledTask = null;
                for (sc.tasks) |t| {
                    if (std.mem.eql(u8, t.name, task_value.string)) {
                        found = t;
                        break;
                    }
                }
                const entry = found orelse return error.TaskNotFound;

                const expr = try Expression.parse(expr_value.string);
                try sc.scheduler.addJob(task_value.string, expr, entry.task, entry.context);

                var out = std.json.ObjectMap{};
                // Same contract as the other handlers: the tree is the
                // caller's on success, freed here on failure, and the string
                // fields are `putJsonField` copies (self-guarding).
                errdefer freeValue(ctx.allocator, .{ .object = out });
                try putOwned(&out, ctx.allocator, "ok", .{ .bool = true });
                try skill.putJsonField(ctx.allocator, &out, "job", .{ .string = task_value.string });
                try skill.putJsonField(ctx.allocator, &out, "expr", .{ .string = expr_value.string });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "list_jobs",
        .action = .read,
        .description = "List jobs currently scheduled on the cron scheduler",
        .parameters = &.{},
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                _ = args;
                const names = try sc.scheduler.listJobNames(ctx.allocator);
                var arr = std.json.Array.init(ctx.allocator);
                // On the error path `arr` owns the names already appended and
                // `names[moved..]` the rest; the slice itself is released
                // either way. Both guards end at the final put's hand-over —
                // on success the `defer` frees only the slice, and the strings
                // are the result's.
                errdefer freeValue(ctx.allocator, .{ .array = arr });
                var moved: usize = 0;
                defer {
                    for (names[moved..]) |n| ctx.allocator.free(n);
                    ctx.allocator.free(names);
                }
                for (names) |n| {
                    try arr.append(.{ .string = n });
                    moved += 1;
                }
                var out = std.json.ObjectMap{};
                errdefer freeValue(ctx.allocator, .{ .object = out });
                try putOwned(&out, ctx.allocator, "jobs", .{ .array = arr });
                return .{ .object = out };
            }
        }.h,
    });

    try registry.register(.{
        .name = "cancel_job",
        .action = .execute,
        .description = "Cancel a scheduled job by name",
        .parameters = &.{
            .{ .name = "job", .type = .string, .description = "Job name from list_jobs", .required = true },
        },
        .handler = struct {
            fn h(ctx: *SkillContext, args: std.json.Value) anyerror!std.json.Value {
                try ctx.checkDeadline();
                const sc: *ScheduleCtx = @ptrCast(@alignCast(ctx.userdata orelse return error.SchedulerNotConfigured));
                const obj = args.object;
                const job_v = obj.get("job") orelse return error.InvalidArguments;
                if (job_v != .string) return error.InvalidArguments;
                const removed = sc.scheduler.cancelJob(job_v.string);
                var out = std.json.ObjectMap{};
                // Same contract: the tree is the caller's on success, freed
                // here on failure — a second field's failure used to strand
                // the first field's key.
                errdefer freeValue(ctx.allocator, .{ .object = out });
                try putOwned(&out, ctx.allocator, "ok", .{ .bool = true });
                try putOwned(&out, ctx.allocator, "removed", .{ .bool = removed });
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

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    var sched_ctx = ScheduleCtx{ .scheduler = &scheduler, .tasks = &tasks };
    var registry = SkillRegistry.init(allocator, std.testing.io);
    defer registry.deinit();
    try registerScheduleSkills(&registry);

    var ctx = SkillContext{ .allocator = a, .userdata = @ptrCast(&sched_ctx) };

    // list_schedulable_tasks returns the registered task.
    const list = try registry.dispatch("list_schedulable_tasks", &ctx, .{ .object = .{} });
    try std.testing.expect(list == .object);
    try std.testing.expectEqual(@as(usize, 1), list.object.get("tasks").?.array.items.len);
    try std.testing.expectEqualStrings("ping", list.object.get("tasks").?.array.items[0].object.get("name").?.string);

    // schedule_job adds a job to the scheduler.
    var args_map = std.json.ObjectMap{};
    try args_map.put(a, "task", .{ .string = "ping" });
    try args_map.put(a, "expr", .{ .string = "* * * * *" });
    const res = try registry.dispatch("schedule_job", &ctx, .{ .object = args_map });
    try std.testing.expect(res.object.get("ok").?.bool);
    try std.testing.expectEqual(@as(usize, 1), scheduler.jobCount());

    // The scheduled job fires on the next matching tick.
    const now = Time.monotonicNowSeconds();
    scheduler.tick(now);
    try std.testing.expectEqual(@as(usize, 1), count);

    // list_jobs / cancel_job round-trip.
    const jobs = try registry.dispatch("list_jobs", &ctx, .{ .object = .{} });
    try std.testing.expectEqual(@as(usize, 1), jobs.object.get("jobs").?.array.items.len);
    var cancel_map = std.json.ObjectMap{};
    try cancel_map.put(a, "job", .{ .string = "ping" });
    const cancelled = try registry.dispatch("cancel_job", &ctx, .{ .object = cancel_map });
    try std.testing.expect(cancelled.object.get("removed").?.bool);
    try std.testing.expectEqual(@as(usize, 0), scheduler.jobCount());
}

// ── OOM scans ────────────────────────────────────────────────────────────────
// One scan per handler: each builds its result tree under a failing allocator.
// The scheduler and registry ride the test allocator (built before the scan);
// the failing one is swapped into the `SkillContext`, so the walk covers the
// handlers' copies and maps, not the scheduler's own storage. The production
// context allocator is the agent worker's, not an arena — these paths must own
// their failure exits.

const ScanTaskState = struct {
    fn noop(_: *anyopaque) void {}
};

fn setupScanRegistry(
    allocator: std.mem.Allocator,
    registry: *SkillRegistry,
    scheduler: *Scheduler,
    sched_ctx: *ScheduleCtx,
    tasks: []const ScheduledTask,
) !void {
    sched_ctx.* = .{ .scheduler = scheduler, .tasks = tasks };
    registry.* = SkillRegistry.init(allocator, std.testing.io);
    try registerScheduleSkills(registry);
}

test "list_schedulable_tasks hands back its task tree at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    const tasks = [_]ScheduledTask{
        .{ .name = "ping", .description = "increment a counter", .task = ScanTaskState.noop, .context = &dummy },
        .{ .name = "sweep", .description = "sweep the queue", .task = ScanTaskState.noop, .context = &dummy },
    };
    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    var sched_ctx: ScheduleCtx = undefined;
    var registry: SkillRegistry = undefined;
    try setupScanRegistry(allocator, &registry, &scheduler, &sched_ctx, &tasks);
    defer registry.deinit();
    var base_ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&sched_ctx) };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var ctx = base.*;
            ctx.allocator = a;
            const res = try reg.dispatch("list_schedulable_tasks", &ctx, .{ .object = .{} });
            defer freeValue(a, res);
            try std.testing.expectEqual(@as(usize, 2), res.object.get("tasks").?.array.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}

test "schedule_job hands back its response at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    const tasks = [_]ScheduledTask{
        .{ .name = "ping", .description = "increment a counter", .task = ScanTaskState.noop, .context = &dummy },
    };
    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    var sched_ctx: ScheduleCtx = undefined;
    var registry: SkillRegistry = undefined;
    try setupScanRegistry(allocator, &registry, &scheduler, &sched_ctx, &tasks);
    defer registry.deinit();
    var base_ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&sched_ctx) };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var ctx = base.*;
            ctx.allocator = a;
            var args = std.json.ObjectMap{};
            defer freeValue(a, .{ .object = args });
            try skill.putJsonField(a, &args, "task", .{ .string = "ping" });
            try skill.putJsonField(a, &args, "expr", .{ .string = "* * * * *" });
            const res = try reg.dispatch("schedule_job", &ctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expect(res.object.get("ok").?.bool);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}

test "list_jobs hands back its job names at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    const tasks = [_]ScheduledTask{
        .{ .name = "ping", .description = "increment a counter", .task = ScanTaskState.noop, .context = &dummy },
    };
    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    try scheduler.addJob("ping", try Expression.parse("* * * * *"), ScanTaskState.noop, &dummy);
    var sched_ctx: ScheduleCtx = undefined;
    var registry: SkillRegistry = undefined;
    try setupScanRegistry(allocator, &registry, &scheduler, &sched_ctx, &tasks);
    defer registry.deinit();
    var base_ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&sched_ctx) };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var ctx = base.*;
            ctx.allocator = a;
            const res = try reg.dispatch("list_jobs", &ctx, .{ .object = .{} });
            defer freeValue(a, res);
            try std.testing.expectEqual(@as(usize, 1), res.object.get("jobs").?.array.items.len);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}

test "cancel_job hands back its response at every allocation point (OOM scan)" {
    const allocator = std.testing.allocator;
    var dummy: u8 = 0;
    const tasks = [_]ScheduledTask{
        .{ .name = "ping", .description = "increment a counter", .task = ScanTaskState.noop, .context = &dummy },
    };
    var scheduler = Scheduler.init(allocator, std.testing.io);
    defer scheduler.deinit();
    var sched_ctx: ScheduleCtx = undefined;
    var registry: SkillRegistry = undefined;
    try setupScanRegistry(allocator, &registry, &scheduler, &sched_ctx, &tasks);
    defer registry.deinit();
    var base_ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&sched_ctx) };

    const Scan = struct {
        fn run(a: std.mem.Allocator, reg: *SkillRegistry, base: *SkillContext) !void {
            var ctx = base.*;
            ctx.allocator = a;
            var args = std.json.ObjectMap{};
            defer freeValue(a, .{ .object = args });
            try skill.putJsonField(a, &args, "job", .{ .string = "ping" });
            const res = try reg.dispatch("cancel_job", &ctx, .{ .object = args });
            defer freeValue(a, res);
            try std.testing.expect(res.object.get("ok").?.bool);
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &registry, &base_ctx });
}
