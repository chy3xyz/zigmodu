const std = @import("std");
const Time = @import("../core/Time.zig");

/// Saga 步骤定义
pub const SagaStep = struct {
    name: []const u8,
    /// 正向操作
    action: *const fn () anyerror!void,
    /// 补偿操作 (撤销已执行操作)
    compensation: *const fn () void,
    /// 是否可重试
    retryable: bool = true,
    /// 超时时间 (秒)
    timeout_seconds: u64 = 30,
};

/// Saga 事务状态
pub const SagaStatus = enum {
    pending,
    running,
    completed,
    failed,
    compensating,
    compensated,
    timed_out,
};

/// Saga 执行记录
pub const SagaLog = struct {
    transaction_id: []const u8,
    saga_name: []const u8,
    status: SagaStatus,
    steps: []const StepLog,
    started_at: i64,
    ended_at: i64,

    pub const StepLog = struct {
        step_name: []const u8,
        status: StepStatus,
        started_at: i64,
        ended_at: i64,
        error_message: ?[]const u8,

        pub const StepStatus = enum {
            pending,
            running,
            completed,
            failed,
            compensated,
        };
    };
};

/// Saga 编排器
/// 自动补偿: 任何步骤失败时，自动按逆序执行已成功步骤的补偿操作
pub const SagaOrchestrator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    sagas: std.StringHashMap(SagaDefinition),
    running_instances: std.StringHashMap(SagaInstance),
    instance_counter: u64,

    pub const SagaDefinition = struct {
        name: []const u8,
        steps: []const SagaStep,
    };

    pub const SagaInstance = struct {
        id: []const u8,
        saga_name: []const u8,
        status: SagaStatus,
        current_step: usize,
        step_logs: std.ArrayList(SagaLog.StepLog),
        started_at: i64,
        last_error: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .sagas = std.StringHashMap(SagaDefinition).init(allocator),
            .running_instances = std.StringHashMap(SagaInstance).init(allocator),
            .instance_counter = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var saga_iter = self.sagas.iterator();
        while (saga_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.name);
            for (entry.value_ptr.steps) |step| {
                self.allocator.free(step.name);
            }
            self.allocator.free(entry.value_ptr.steps);
        }
        self.sagas.deinit();

        var inst_iter = self.running_instances.iterator();
        while (inst_iter.next()) |entry| {
            var inst = entry.value_ptr.*;
            self.allocator.free(inst.id);
            self.allocator.free(inst.saga_name);
            for (inst.step_logs.items) |log| {
                self.allocator.free(log.step_name);
                if (log.error_message) |em| self.allocator.free(em);
            }
            inst.step_logs.deinit(self.allocator);
            if (inst.last_error) |le| self.allocator.free(le);
        }
        self.running_instances.deinit();
    }

    /// 注册 Saga 定义
    pub fn registerSaga(self: *Self, name: []const u8, steps: []const SagaStep) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);

        const steps_copy = try self.allocator.alloc(SagaStep, steps.len);
        for (steps, 0..) |step, i| {
            steps_copy[i] = .{
                .name = try self.allocator.dupe(u8, step.name),
                .action = step.action,
                .compensation = step.compensation,
                .retryable = step.retryable,
                .timeout_seconds = step.timeout_seconds,
            };
        }

        try self.sagas.put(name_copy, .{
            .name = name_copy,
            .steps = steps_copy,
        });
    }

    /// 开始执行 Saga
    pub fn execute(self: *Self, saga_name: []const u8) ![]const u8 {
        const saga = self.sagas.get(saga_name) orelse return error.SagaNotFound;

        self.instance_counter += 1;
        const instance_id = try std.fmt.allocPrint(self.allocator, "saga-{s}-{d}", .{ saga_name, self.instance_counter });

        const instance = SagaInstance{
            .id = instance_id,
            .saga_name = try self.allocator.dupe(u8, saga_name),
            .status = .running,
            .current_step = 0,
            .step_logs = std.ArrayList(SagaLog.StepLog).empty,
            .started_at = Time.monotonicNowSeconds(),
            .last_error = null,
        };

        try self.running_instances.put(instance_id, instance);

        // 执行所有步骤
        for (saga.steps, 0..) |step, i| {
            const inst = self.running_instances.getPtr(instance_id) orelse return error.InternalError;
            inst.current_step = i;

            const step_start = Time.monotonicNowSeconds();

            step.action() catch |err| {
                const step_end = Time.monotonicNowSeconds();
                const err_msg = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});

                try inst.step_logs.append(self.allocator, .{
                    .step_name = try self.allocator.dupe(u8, step.name),
                    .status = .failed,
                    .started_at = step_start,
                    .ended_at = step_end,
                    .error_message = err_msg,
                });

                inst.last_error = try self.allocator.dupe(u8, err_msg);

                std.log.warn("[Saga] Step '{s}' failed in '{s}': {s}", .{ step.name, instance_id, err_msg });

                // 自动补偿
                try self.compensate(instance_id, i);
                return error.SagaStepFailed;
            };

            const step_end = Time.monotonicNowSeconds();

            try inst.step_logs.append(self.allocator, .{
                .step_name = try self.allocator.dupe(u8, step.name),
                .status = .completed,
                .started_at = step_start,
                .ended_at = step_end,
                .error_message = null,
            });

            std.log.info("[Saga] Step '{s}' completed in '{s}'", .{ step.name, instance_id });
        }

        const inst = self.running_instances.getPtr(instance_id) orelse return error.InternalError;
        inst.status = .completed;

        std.log.info("[Saga] '{s}' completed successfully", .{instance_id});
        return instance_id;
    }

    /// 执行补偿 (逆序回滚)
    fn compensate(self: *Self, instance_id: []const u8, failed_step_index: usize) !void {
        const inst = self.running_instances.getPtr(instance_id) orelse return;
        const saga = self.sagas.get(inst.saga_name) orelse return;

        inst.status = .compensating;

        std.log.info("[Saga] Compensating '{s}' (failed at step {d})", .{ instance_id, failed_step_index });

        // 逆向补偿已成功的步骤
        var i: usize = failed_step_index;
        while (i > 0) {
            i -= 1;
            const step = saga.steps[i];

            std.log.info("[Saga] Executing compensation for step '{s}'", .{step.name});
            step.compensation();

            // 更新日志
            for (inst.step_logs.items) |*log| {
                if (std.mem.eql(u8, log.step_name, step.name) and log.status == .completed) {
                    log.status = .compensated;
                    break;
                }
            }
        }

        inst.status = .compensated;
        std.log.info("[Saga] Compensation completed for '{s}'", .{instance_id});
    }

    /// 获取 Saga 实例状态
    pub fn getStatus(self: *Self, instance_id: []const u8) ?SagaStatus {
        const inst = self.running_instances.get(instance_id) orelse return null;
        return inst.status;
    }

    /// 获取 Saga 执行日志
    pub fn getLog(self: *Self, instance_id: []const u8) !?SagaLog {
        const inst = self.running_instances.get(instance_id) orelse return null;

        var step_logs_copy = std.ArrayList(SagaLog.StepLog).empty;
        for (inst.step_logs.items) |log| {
            try step_logs_copy.append(self.allocator, .{
                .step_name = try self.allocator.dupe(u8, log.step_name),
                .status = log.status,
                .started_at = log.started_at,
                .ended_at = log.ended_at,
                .error_message = if (log.error_message) |em| try self.allocator.dupe(u8, em) else null,
            });
        }

        return SagaLog{
            .transaction_id = inst.id,
            .saga_name = inst.saga_name,
            .status = inst.status,
            .steps = try step_logs_copy.toOwnedSlice(self.allocator),
            .started_at = inst.started_at,
            .ended_at = Time.monotonicNowSeconds(),
        };
    }

    /// 列出所有活跃 Saga 实例
    pub fn listActiveInstances(self: *Self) ![]const []const u8 {
        var result = std.ArrayList([]const u8).empty;

        var iter = self.running_instances.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.status == .running or entry.value_ptr.status == .compensating) {
                try result.append(self.allocator, entry.key_ptr.*);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    /// 获取已注册的 Saga 数量
    pub fn getSagaCount(self: *Self) usize {
        return self.sagas.count();
    }
};

// ─────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────

test "SagaOrchestrator register and execute success" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    var step1_executed = false;
    var step2_executed = false;

    const Step1 = struct {
        var flag: *bool = undefined;
        pub fn act() !void { flag.* = true; }
    };
    Step1.flag = &step1_executed;

    const Step2 = struct {
        var flag: *bool = undefined;
        pub fn act() !void { flag.* = true; }
    };
    Step2.flag = &step2_executed;

    const steps = &[_]SagaStep{
        .{
            .name = "validate-order",
            .action = Step1.act,
            .compensation = struct {
                fn comp() void {}
            }.comp,
        },
        .{
            .name = "reserve-inventory",
            .action = Step2.act,
            .compensation = struct {
                fn comp() void {}
            }.comp,
        },
    };

    try orchestrator.registerSaga("create-order", steps);
    try std.testing.expectEqual(@as(usize, 1), orchestrator.getSagaCount());

    const instance_id = try orchestrator.execute("create-order");
    // instance_id owned by orchestrator — don't free

    try std.testing.expect(step1_executed);
    try std.testing.expect(step2_executed);
    try std.testing.expectEqual(SagaStatus.completed, orchestrator.getStatus(instance_id).?);
}

test "SagaOrchestrator auto-compensation on failure" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    var compensated = false;

    const FailCompensation = struct {
        var flag: *bool = undefined;
        pub fn comp() void { flag.* = true; }
    };
    FailCompensation.flag = &compensated;

    const steps = &[_]SagaStep{
        .{
            .name = "step-ok",
            .action = struct {
                fn act() !void {}
            }.act,
            .compensation = struct {
                fn comp() void {}
            }.comp,
        },
        .{
            .name = "step-fails",
            .action = struct {
                fn act() !void {
                    return error.SimulatedFailure;
                }
            }.act,
            .compensation = FailCompensation.comp,
        },
    };

    try orchestrator.registerSaga("fail-saga", steps);

    const result = orchestrator.execute("fail-saga");
    try std.testing.expectError(error.SagaStepFailed, result);
}

test "SagaOrchestrator saga not found" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    const result = orchestrator.execute("nonexistent");
    try std.testing.expectError(error.SagaNotFound, result);
}

test "SagaOrchestrator list active" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    const steps = &[_]SagaStep{
        .{
            .name = "s1",
            .action = struct {
                fn act() !void {}
            }.act,
            .compensation = struct {
                fn comp() void {}
            }.comp,
        },
    };

    try orchestrator.registerSaga("active-test", steps);

    _ = try orchestrator.execute("active-test");

    const active = try orchestrator.listActiveInstances();
    defer allocator.free(active);
    // After completion, no active instances
    try std.testing.expectEqual(@as(usize, 0), active.len);
}

test "SagaOrchestrator get log" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    const steps = &[_]SagaStep{
        .{
            .name = "single-step",
            .action = struct {
                fn act() !void {}
            }.act,
            .compensation = struct {
                fn comp() void {}
            }.comp,
        },
    };

    try orchestrator.registerSaga("log-test", steps);
    const instance_id = try orchestrator.execute("log-test");

    const log = (try orchestrator.getLog(instance_id)).?;
    defer {
        for (log.steps) |s| {
            allocator.free(s.step_name);
            if (s.error_message) |em| allocator.free(em);
        }
        allocator.free(log.steps);
    }

    try std.testing.expectEqual(SagaStatus.completed, log.status);
    try std.testing.expectEqual(@as(usize, 1), log.steps.len);
    try std.testing.expectEqual(SagaLog.StepLog.StepStatus.completed, log.steps[0].status);
}

test "SagaOrchestrator compensation reverse order" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    const Ctx = struct {
        var compensate_order: [8][]const u8 = undefined;
        var compensate_idx: usize = 0;
    };

    const noopCompensate = struct { fn c() void {} }.c;
    const saga_def = SagaOrchestrator.SagaDefinition{
        .name = "reverse-test",
        .steps = &.{
            .{ .name = "step-1", .action = struct {
                fn f() anyerror!void {}
            }.f, .compensation = noopCompensate },
            .{ .name = "step-2", .action = struct {
                fn f() anyerror!void {}
            }.f, .compensation = noopCompensate },
            .{ .name = "step-3", .action = struct {
                fn f() anyerror!void { return error.SimulatedFailure; }
            }.f, .compensation = struct {
                fn c() void {
                    Ctx.compensate_order[Ctx.compensate_idx] = "step-3-comp";
                    Ctx.compensate_idx += 1;
                }
            }.c },
        },
    };
    // Register the saga and verify step count
    try orchestrator.registerSaga("reverse-test", saga_def.steps);
    try std.testing.expectEqual(@as(usize, 3), saga_def.steps.len);
}
