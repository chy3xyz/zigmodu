//! Hierarchical orchestration: a planner splits a goal into subtasks, which
//! run concurrently via std.Io.Group and aggregate into one result.
//!
//! Planner and executor are callbacks so the app can wire them to Agent or
//! Workflow (or pure logic). Subtask strings are borrowed for the duration of
//! run; executors should dupe what they need into SubTaskResult.

const std = @import("std");
const SkillContext = @import("skill.zig").SkillContext;

pub const SubTask = struct {
    name: []const u8,
    goal: []const u8,
    input: []const u8 = "",
};

pub const SubTaskResult = struct {
    name: []const u8,
    ok: bool,
    output: []const u8 = "",
};

pub const Status = enum { completed, partial_failed };

pub const PlannerFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    goal: []const u8,
    plan: *std.ArrayList(SubTask),
) anyerror!void;

pub const ExecutorFn = *const fn (
    allocator: std.mem.Allocator,
    ctx: *SkillContext,
    task: SubTask,
    out: *SubTaskResult,
) anyerror!void;

pub const HierarchyResult = struct {
    status: Status,
    tasks: std.ArrayList(SubTaskResult),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *HierarchyResult) void {
        for (self.tasks.items) |t| {
            self.allocator.free(t.name);
            if (t.output.len > 0) self.allocator.free(t.output);
        }
        self.tasks.deinit(self.allocator);
        self.* = undefined;
    }
};

const TaskState = struct {
    executor: ExecutorFn,
    ctx: SkillContext,
    task: SubTask,
    result: SubTaskResult,
    allocator: std.mem.Allocator,
};

fn taskFn(st: *TaskState) void {
    st.executor(st.allocator, &st.ctx, st.task, &st.result) catch {};
}

pub const Hierarchy = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    planner: PlannerFn,
    executor: ExecutorFn,
    max_parallel: usize = 4,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        planner: PlannerFn,
        executor: ExecutorFn,
    ) Hierarchy {
        return .{ .allocator = allocator, .io = io, .planner = planner, .executor = executor };
    }

    /// Plan the goal, run subtasks concurrently in waves of `max_parallel`,
    /// and aggregate. Partial failures surface as `.partial_failed`.
    pub fn run(self: *Hierarchy, allocator: std.mem.Allocator, ctx: *SkillContext, goal: []const u8) !HierarchyResult {
        var plan = std.ArrayList(SubTask).empty;
        defer plan.deinit(allocator);
        try self.planner(allocator, ctx, goal, &plan);

        var result = HierarchyResult{
            .status = .completed,
            .tasks = std.ArrayList(SubTaskResult).empty,
            .allocator = allocator,
        };
        errdefer result.deinit();

        var wave_start: usize = 0;
        while (wave_start < plan.items.len) : (wave_start += self.max_parallel) {
            const wave_end = @min(plan.items.len, wave_start + self.max_parallel);
            const wave_len = wave_end - wave_start;

            const states = try allocator.alloc(*TaskState, wave_len);
            defer allocator.free(states);
            var group = std.Io.Group.init;
            var spawned: usize = 0;
            errdefer {
                for (states[0..spawned]) |st| allocator.destroy(st);
            }

            for (plan.items[wave_start..wave_end], 0..) |task, i| {
                const st = try allocator.create(TaskState);
                st.* = .{
                    .executor = self.executor,
                    .ctx = ctx.*,
                    .task = task,
                    .result = .{ .name = "", .ok = false },
                    .allocator = allocator,
                };
                states[i] = st;
                spawned += 1;
                group.async(self.io, taskFn, .{st});
            }
            try group.await(self.io);

            for (states) |st| {
                try result.tasks.append(allocator, st.result);
                allocator.destroy(st);
            }
        }

        for (result.tasks.items) |t| {
            if (!t.ok) {
                result.status = .partial_failed;
                break;
            }
        }
        return result;
    }
};

test "hierarchy runs planner subtasks concurrently and aggregates" {
    const allocator = std.testing.allocator;
    var counter: std.atomic.Value(usize) = .init(0);

    const T = struct {
        fn plan(a: std.mem.Allocator, _: *SkillContext, goal: []const u8, out: *std.ArrayList(SubTask)) anyerror!void {
            _ = goal;
            try out.append(a, .{ .name = "a", .goal = "g1" });
            try out.append(a, .{ .name = "b", .goal = "g2" });
            try out.append(a, .{ .name = "c", .goal = "g3" });
        }
        fn exec(a: std.mem.Allocator, ctx: *SkillContext, task: SubTask, out: *SubTaskResult) anyerror!void {
            const c: *std.atomic.Value(usize) = @ptrCast(@alignCast(ctx.userdata.?));
            _ = c.fetchAdd(1, .monotonic);
            out.name = try a.dupe(u8, task.name);
            out.ok = true;
            out.output = try a.dupe(u8, "ok");
        }
    };

    var ctx = SkillContext{ .allocator = allocator, .userdata = @ptrCast(&counter) };
    var hierarchy = Hierarchy.init(allocator, std.testing.io, T.plan, T.exec);
    var result = try hierarchy.run(allocator, &ctx, "top-goal");
    defer result.deinit();

    try std.testing.expectEqual(Status.completed, result.status);
    try std.testing.expectEqual(@as(usize, 3), result.tasks.items.len);
    try std.testing.expectEqual(@as(usize, 3), counter.load(.monotonic));
    try std.testing.expect(result.tasks.items[0].ok);
    try std.testing.expectEqualStrings("a", result.tasks.items[0].name);
}

test "hierarchy surfaces partial failure" {
    const allocator = std.testing.allocator;

    const T = struct {
        fn plan(a: std.mem.Allocator, _: *SkillContext, goal: []const u8, out: *std.ArrayList(SubTask)) anyerror!void {
            _ = goal;
            try out.append(a, .{ .name = "good", .goal = "g1" });
            try out.append(a, .{ .name = "bad", .goal = "g2" });
        }
        fn exec(a: std.mem.Allocator, _: *SkillContext, task: SubTask, out: *SubTaskResult) anyerror!void {
            out.name = try a.dupe(u8, task.name);
            out.ok = !std.mem.eql(u8, task.name, "bad");
            out.output = try a.dupe(u8, if (out.ok) "ok" else "failed");
        }
    };

    var ctx = SkillContext{ .allocator = allocator };
    var hierarchy = Hierarchy.init(allocator, std.testing.io, T.plan, T.exec);
    var result = try hierarchy.run(allocator, &ctx, "top");
    defer result.deinit();

    try std.testing.expectEqual(Status.partial_failed, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.tasks.items.len);
    try std.testing.expect(!result.tasks.items[1].ok);
}
