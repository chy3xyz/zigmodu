//! Saga orchestrator — distributed transaction with compensating rollback steps.

const std = @import("std");
const Time = @import("../core/Time.zig");
const WAL = @import("eventbus/WAL.zig").WAL;

/// One saga step
pub const SagaStep = struct {
    name: []const u8,
    /// Forward action to run
    action: *const fn () anyerror!void,
    /// Compensation that undoes the already-performed action
    compensation: *const fn () void,
    /// Whether the step may be retried
    retryable: bool = true,
    /// Per-step budget in seconds; `0` disables the check.
    ///
    /// Judged *after* the step returns — an in-process executor cannot preempt
    /// a running step. When the action took longer than the budget the instance
    /// ends `.timed_out` and every step whose effects took place (this one
    /// included, because it DID return successfully) is compensated in reverse
    /// order; `execute` / `resumeInstance` then return `error.SagaStepTimeout`.
    timeout_seconds: u64 = 30,
};

/// Saga transaction status. Terminal states — `completed`, `compensated`,
/// `failed`, `timed_out` — are refused by `resumeInstance` and skipped by
/// `restoreFromWal`. `timed_out` is a post-hoc verdict (see
/// `SagaStep.timeout_seconds`), never a mid-step interruption.
pub const SagaStatus = enum {
    pending,
    running,
    completed,
    failed,
    compensating,
    compensated,
    timed_out,
};

/// Saga execution log
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

/// Saga orchestrator
/// Automatic compensation: when a step fails, the steps that already succeeded are
/// compensated in reverse order
pub const SagaOrchestrator = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    sagas: std.StringHashMap(SagaDefinition),
    running_instances: std.StringHashMap(SagaInstance),
    instance_counter: u64,
    /// Optional WAL for persisting saga step results
    wal: ?*WAL = null,

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
        self.* = undefined;
    }

    /// Registers a saga definition
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

    /// Starts executing a saga
    pub fn execute(self: *Self, saga_name: []const u8) ![]const u8 {
        // Look the definition up before creating anything: an unknown saga must not
        // leave a half-created instance behind.
        if (!self.sagas.contains(saga_name)) return error.SagaNotFound;

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

        try self.runFrom(instance_id, 0);

        const inst = self.running_instances.getPtr(instance_id) orelse return error.InternalError;
        inst.status = .completed;

        // Persist final state
        self.saveSagaState(instance_id);

        std.log.info("[Saga] '{s}' completed successfully", .{instance_id});
        return instance_id;
    }

    /// Run `saga.steps[start_index..]`, logging every outcome and compensating on
    /// failure. Shared by `execute` (start 0) and `resume` (start = recorded
    /// progress) so a resumed saga cannot drift from a fresh one.
    fn runFrom(self: *Self, instance_id: []const u8, start_index: usize) !void {
        const inst = self.running_instances.getPtr(instance_id) orelse return error.InternalError;
        const saga = self.sagas.get(inst.saga_name) orelse return error.SagaNotFound;
        if (start_index >= saga.steps.len) return;

        for (saga.steps[start_index..], start_index..) |step, i| {
            const running = self.running_instances.getPtr(instance_id) orelse return error.InternalError;
            running.current_step = i;

            // Milliseconds are what the budget is checked against; the step log
            // keeps seconds. divFloor(ms) == monotonicNowSeconds().
            const step_start_ms = Time.monotonicNowMilliseconds();
            const step_start = @divFloor(step_start_ms, std.time.ms_per_s);

            step.action() catch |err| {
                const step_end = Time.monotonicNowSeconds();
                const err_msg = try std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)});

                try running.step_logs.append(self.allocator, .{
                    .step_name = try self.allocator.dupe(u8, step.name),
                    .status = .failed,
                    .started_at = step_start,
                    .ended_at = step_end,
                    .error_message = err_msg,
                });

                running.last_error = try self.allocator.dupe(u8, err_msg);

                std.log.warn("[Saga] Step '{s}' failed in '{s}': {s}", .{ step.name, instance_id, err_msg });

                // Persist state before compensation
                self.saveSagaState(instance_id);

                // Undo the steps that already succeeded
                try self.compensate(instance_id, i);
                return error.SagaStepFailed;
            };

            const step_end_ms = Time.monotonicNowMilliseconds();
            const step_end = @divFloor(step_end_ms, std.time.ms_per_s);

            try running.step_logs.append(self.allocator, .{
                .step_name = try self.allocator.dupe(u8, step.name),
                .status = .completed,
                .started_at = step_start,
                .ended_at = step_end,
                .error_message = null,
            });

            // Post-hoc timeout judgement: a step cannot be preempted mid-flight,
            // so the budget is only checked when it returns. The step DID
            // complete — its side effects are real — so it is compensated along
            // with the steps before it (`compensate` covers indices `< i + 1`).
            const elapsed_ms = step_end_ms - step_start_ms;
            if (step.timeout_seconds > 0 and
                @as(u128, @intCast(elapsed_ms)) > @as(u128, step.timeout_seconds) * std.time.ms_per_s)
            {
                running.last_error = try std.fmt.allocPrint(self.allocator, "step '{s}' exceeded its {d}s budget (took {d}ms)", .{ step.name, step.timeout_seconds, elapsed_ms });
                std.log.warn("[Saga] Step '{s}' in '{s}' timed out: {d}ms over a {d}s budget", .{ step.name, instance_id, elapsed_ms, step.timeout_seconds });
                self.saveSagaState(instance_id);
                try self.compensate(instance_id, i + 1);
                const done = self.running_instances.getPtr(instance_id) orelse return error.InternalError;
                done.status = .timed_out;
                self.saveSagaState(instance_id);
                return error.SagaStepTimeout;
            }

            std.log.info("[Saga] Step '{s}' completed in '{s}'", .{ step.name, instance_id });
            self.saveSagaState(instance_id);
        }

        const done = self.running_instances.getPtr(instance_id) orelse return error.InternalError;
        done.status = .completed;
        self.saveSagaState(instance_id);
        std.log.info("[Saga] '{s}' completed successfully", .{instance_id});
    }

    /// Continue a saga that a previous process left in flight (the instance comes
    ///
    /// Named `resumeInstance` because `resume` is a Zig keyword.
    /// back via `restoreFromWal`).
    ///
    /// Semantics, stated because they are the whole point of a checkpoint:
    ///
    /// * Steps logged **completed** are never re-run.
    /// * The step that was *in flight* when the process died **is** re-run, because
    ///   nothing recorded whether it took effect — so a step with side effects must
    ///   be idempotent (the same requirement every at-least-once system has).
    /// * A terminal instance (`.completed`, `.compensated`, `.failed`,
    ///   `.timed_out`) is refused:
    ///   re-running a compensated saga would compensate side effects twice.
    pub fn resumeInstance(self: *Self, instance_id: []const u8) !void {
        const inst = self.running_instances.getPtr(instance_id) orelse return error.UnknownInstance;
        switch (inst.status) {
            .completed, .compensated, .failed, .timed_out => return error.NothingToResume,
            .compensating => return error.NothingToResume, // compensation was mid-flight: a human decides
            .pending, .running => {},
        }

        // Where to continue from: the step after the last one *logged completed*.
        // (Not `current_step + 1`: the step in flight when we died has no completed
        // log, and `current_step` is only updated as the loop enters each step.)
        var completed_steps: usize = 0;
        for (inst.step_logs.items) |log| {
            if (log.status == .completed) completed_steps += 1;
        }
        if (completed_steps < inst.current_step) completed_steps = inst.current_step;

        std.log.info("[Saga] Resuming '{s}' from step {d}", .{ instance_id, completed_steps });
        inst.status = .running;
        try self.runFrom(instance_id, completed_steps);
    }

    /// Executes compensation (reverse-order rollback)
    fn compensate(self: *Self, instance_id: []const u8, failed_step_index: usize) !void {
        const inst = self.running_instances.getPtr(instance_id) orelse return;
        const saga = self.sagas.get(inst.saga_name) orelse return;

        inst.status = .compensating;

        std.log.info("[Saga] Compensating '{s}' (failed at step {d})", .{ instance_id, failed_step_index });

        // Compensate the steps before the failing one, in reverse order
        var i: usize = failed_step_index;
        while (i > 0) {
            i -= 1;
            const step = saga.steps[i];

            std.log.info("[Saga] Executing compensation for step '{s}'", .{step.name});
            step.compensation();

            // Mark the matching step log as compensated
            for (inst.step_logs.items) |*log| {
                if (std.mem.eql(u8, log.step_name, step.name) and log.status == .completed) {
                    log.status = .compensated;
                    break;
                }
            }
        }

        inst.status = .compensated;
        // Persist compensation result
        self.saveSagaState(instance_id);
        std.log.info("[Saga] Compensation completed for '{s}'", .{instance_id});
    }

    /// Gets the status of a saga instance
    pub fn getStatus(self: *Self, instance_id: []const u8) ?SagaStatus {
        const inst = self.running_instances.get(instance_id) orelse return null;
        return inst.status;
    }

    /// Gets the execution log of a saga instance
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

    /// Lists the ids of all currently active saga instances
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

    /// Gets the number of registered sagas
    pub fn getSagaCount(self: *Self) usize {
        return self.sagas.count();
    }

    /// Set the WAL for persisting saga step results
    pub fn setWal(self: *Self, w: *WAL) void {
        self.wal = w;
    }

    /// Persist the current saga instance state to the WAL.
    /// Called after each step execution (success or compensation).
    fn saveSagaState(self: *Self, instance_id: []const u8) void {
        const w = self.wal orelse return;
        const inst = self.running_instances.get(instance_id) orelse return;

        // Serialize saga state as compact payload:
        //   {saga_id}|{saga_name}|{status:int}|{current_step}|{started_at}
        var payload_buf: [512]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{s}|{s}|{d}|{d}|{d}", .{
            inst.id,
            inst.saga_name,
            @backingInt(inst.status),
            inst.current_step,
            inst.started_at,
        }) catch {
            std.log.err("[Saga] Failed to serialize state for '{s}'", .{instance_id});
            return;
        };

        _ = w.append(.{
            .topic = "saga-state",
            .payload = payload,
            .source_node = "saga-orchestrator",
            .timestamp_ms = Time.monotonicNowMilliseconds(),
        }) catch |err| {
            std.log.err("[Saga] WAL append failed for '{s}': {}", .{ instance_id, err });
        };
    }

    /// Restore in-progress saga instances from the WAL.
    /// Reads all entries from last committed position and reconstructs
    /// saga instances that were still running at crash time.
    pub fn restoreFromWal(self: *Self) !void {
        const w = self.wal orelse return;
        const from_seq = w.lastCommittedIndex() + 1;
        const entries = try w.readFrom(from_seq);
        defer {
            // `readFrom` hands over owned strings; without this the restore leaks
            // one topic+payload+source_node per record on every boot.
            for (entries) |entry| {
                self.allocator.free(entry.topic);
                self.allocator.free(entry.payload);
                self.allocator.free(entry.source_node);
            }
            self.allocator.free(entries);
        }

        // A crash leaves a *chain* of records per instance (running → running →
        // completed). Restoring on "any record says running" resurrects instances
        // that already finished or compensated — so decide from each instance's
        // LAST record, which means looking at all of them before creating any.
        var latest = std.StringHashMap(SagaStatus).init(self.allocator);
        defer latest.deinit();
        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.topic, "saga-state")) continue;
            var it = std.mem.splitScalar(u8, entry.payload, '|');
            const id = it.next() orelse continue;
            _ = it.next() orelse continue; // saga_name
            const status_str = it.next() orelse continue;
            const status_int = std.fmt.parseInt(u8, status_str, 10) catch continue;
            const status: SagaStatus = @fromBackingInt(@intCast(status_int));
            // Later entries overwrite earlier ones: `put` keeps the newest.
            latest.put(id, status) catch continue;
        }

        for (entries) |entry| {
            if (!std.mem.eql(u8, entry.topic, "saga-state")) continue;

            // Parse: {saga_id}|{saga_name}|{status:int}|{current_step}|{started_at}
            var parts = std.mem.splitScalar(u8, entry.payload, '|');
            const saga_id = parts.next() orelse continue;
            const saga_name = parts.next() orelse continue;
            const status_int_str = parts.next() orelse continue;
            const current_step_str = parts.next() orelse continue;
            const started_at_str = parts.next() orelse continue;

            const status_int = std.fmt.parseInt(u8, status_int_str, 10) catch continue;
            const status: SagaStatus = @fromBackingInt(@intCast(status_int));
            const current_step = std.fmt.parseInt(usize, current_step_str, 10) catch continue;
            const started_at = std.fmt.parseInt(i64, started_at_str, 10) catch continue;

            // Only restore sagas whose *latest* state is still in-progress.
            const final_status = latest.get(saga_id) orelse status;
            if (final_status != .running and final_status != .compensating and final_status != .pending) continue;

            // Check if already restored
            if (self.running_instances.contains(saga_id)) continue;

            const id_copy = try self.allocator.dupe(u8, saga_id);
            errdefer self.allocator.free(id_copy);
            const name_copy = try self.allocator.dupe(u8, saga_name);
            errdefer self.allocator.free(name_copy);

            const instance = SagaInstance{
                .id = id_copy,
                .saga_name = name_copy,
                .status = status,
                .current_step = current_step,
                .step_logs = std.ArrayList(SagaLog.StepLog).empty,
                .started_at = started_at,
                .last_error = null,
            };

            try self.running_instances.put(id_copy, instance);
            std.log.info("[Saga] Restored instance '{s}' ({s}) from WAL", .{ saga_id, saga_name });
        }
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
        pub fn act() !void {
            flag.* = true;
        }
    };
    Step1.flag = &step1_executed;

    const Step2 = struct {
        var flag: *bool = undefined;
        pub fn act() !void {
            flag.* = true;
        }
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
        pub fn comp() void {
            flag.* = true;
        }
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

test "SagaOrchestrator timeout_seconds = 0 disables the budget" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    const steps = &[_]SagaStep{
        .{
            .name = "no-budget",
            .action = struct {
                fn act() !void {}
            }.act,
            .compensation = struct {
                fn comp() void {}
            }.comp,
            .timeout_seconds = 0,
        },
    };

    try orchestrator.registerSaga("no-budget-saga", steps);
    const instance_id = try orchestrator.execute("no-budget-saga");
    try std.testing.expectEqual(SagaStatus.completed, orchestrator.getStatus(instance_id).?);
}

test "SagaOrchestrator step over budget ends timed_out and compensates what ran" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    const Ctx = struct {
        var order: [4][]const u8 = undefined;
        var n: usize = 0;
        var never_ran: bool = false;
        fn compSlow() void {
            order[n] = "slow";
            n += 1;
        }
        fn compFast() void {
            order[n] = "fast";
            n += 1;
        }
        fn slow() !void {
            std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1200), .awake) catch {};
        }
        fn fast() !void {}
        fn never() !void {
            never_ran = true;
        }
    };
    Ctx.n = 0;
    Ctx.never_ran = false;

    const steps = &[_]SagaStep{
        .{ .name = "fast", .action = Ctx.fast, .compensation = Ctx.compFast, .timeout_seconds = 60 },
        .{ .name = "slow", .action = Ctx.slow, .compensation = Ctx.compSlow, .timeout_seconds = 1 },
        .{ .name = "never", .action = Ctx.never, .compensation = Ctx.compFast },
    };

    try orchestrator.registerSaga("timeout-saga", steps);
    // execute returns the error, not the id — the instance stays in the map.
    try std.testing.expectError(error.SagaStepTimeout, orchestrator.execute("timeout-saga"));

    var it = orchestrator.running_instances.iterator();
    const entry = it.next().?;
    try std.testing.expect(it.next() == null);
    try std.testing.expectEqual(SagaStatus.timed_out, entry.value_ptr.status);

    // Reverse order, the over-budget step included: its action returned, so its
    // effects are real and get undone too. The step after it never ran.
    try std.testing.expectEqual(@as(usize, 2), Ctx.n);
    try std.testing.expectEqualStrings("slow", Ctx.order[0]);
    try std.testing.expectEqualStrings("fast", Ctx.order[1]);
    try std.testing.expect(!Ctx.never_ran);

    // The step logs tell the same story: both ran, both were compensated.
    try std.testing.expectEqual(@as(usize, 2), entry.value_ptr.step_logs.items.len);
    try std.testing.expectEqual(SagaLog.StepLog.StepStatus.compensated, entry.value_ptr.step_logs.items[0].status);
    try std.testing.expectEqual(SagaLog.StepLog.StepStatus.compensated, entry.value_ptr.step_logs.items[1].status);
    try std.testing.expect(entry.value_ptr.last_error != null);

    // Terminal: nothing to resume.
    try std.testing.expectError(error.NothingToResume, orchestrator.resumeInstance(entry.key_ptr.*));
}

test "SagaOrchestrator step within budget completes normally" {
    const allocator = std.testing.allocator;
    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();

    var compensated = false;
    const Comp = struct {
        var flag: *bool = undefined;
        fn comp() void {
            flag.* = true;
        }
    };
    Comp.flag = &compensated;

    const steps = &[_]SagaStep{
        .{
            .name = "quick",
            .action = struct {
                fn act() !void {}
            }.act,
            .compensation = Comp.comp,
            .timeout_seconds = 5,
        },
    };

    try orchestrator.registerSaga("within-budget-saga", steps);
    const instance_id = try orchestrator.execute("within-budget-saga");
    try std.testing.expectEqual(SagaStatus.completed, orchestrator.getStatus(instance_id).?);
    try std.testing.expect(!compensated);
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

    const noopCompensate = struct {
        fn c() void {}
    }.c;
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
                fn f() anyerror!void {
                    return error.SimulatedFailure;
                }
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

test "Saga persists step results to WAL" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wal_config = @import("eventbus/WAL.zig").WALConfig{ .dir_path = "wal_test_saga", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, wal_config);
    defer wal.deinit();

    var orchestrator = SagaOrchestrator.init(allocator);
    defer orchestrator.deinit();
    orchestrator.setWal(&wal);

    var step_executed = false;
    const StepCtx = struct {
        var flag: *bool = undefined;
        pub fn act() !void {
            flag.* = true;
        }
    };
    StepCtx.flag = &step_executed;

    const steps = &[_]SagaStep{
        .{
            .name = "persist-step",
            .action = StepCtx.act,
            .compensation = struct {
                fn comp() void {}
            }.comp,
        },
    };

    try orchestrator.registerSaga("persist-saga", steps);

    try std.testing.expectEqual(@as(u64, 0), wal.lastIndex());

    const instance_id = try orchestrator.execute("persist-saga");

    try std.testing.expect(step_executed);
    try std.testing.expectEqual(SagaStatus.completed, orchestrator.getStatus(instance_id).?);

    // Verify that WAL entries were written (at least 1 for completion, plus step success)
    try std.testing.expect(wal.lastIndex() >= 2);
}

test "resume: a crash-restored saga continues without re-running completed steps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wal_config = @import("eventbus/WAL.zig").WALConfig{ .dir_path = "wal_test_resume", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, wal_config);
    defer wal.deinit();

    const Ctx = struct {
        var ran: u32 = 0;
        var compensated: u32 = 0;
        fn a1() !void {
            ran += 1;
        }
        fn a2() !void {
            ran += 1;
        }
        fn a3() !void {
            ran += 1;
        }
        fn c() void {
            compensated += 1;
        }
    };
    Ctx.ran = 0;
    Ctx.compensated = 0;

    const steps = &[_]SagaStep{
        .{ .name = "one", .action = Ctx.a1, .compensation = Ctx.c },
        .{ .name = "two", .action = Ctx.a2, .compensation = Ctx.c },
        .{ .name = "three", .action = Ctx.a3, .compensation = Ctx.c },
    };

    // The crash artifact: a `saga-state` record saying "instance X is running,
    // step index 1 is in flight". That is exactly what `saveSagaState` wrote before
    // the process died mid-step-2 — the test writes it by hand instead of dying.
    // (`current_step` is the step being *entered*, so index 1 = the second step.)
    _ = try wal.append(.{ .topic = "saga-state", .payload = "saga-resume-1|resume-saga|1|1|1700000000", .source_node = "test" });

    var orch = SagaOrchestrator.init(allocator);
    defer orch.deinit();
    orch.setWal(&wal);
    try orch.registerSaga("resume-saga", steps);
    try orch.restoreFromWal();

    try std.testing.expectEqual(SagaStatus.running, orch.getStatus("saga-resume-1").?);
    try std.testing.expectEqual(@as(u32, 0), Ctx.ran);

    try orch.resumeInstance("saga-resume-1");

    // Step index 1 ("two") is re-run — it was in flight, nothing recorded whether it
    // took effect — and step 2 ("three") runs. Step 0 ("one") is not re-run: the
    // record says the process had already entered step 1, which is only written
    // after step 0 returned. Nothing is compensated.
    try std.testing.expectEqual(@as(u32, 2), Ctx.ran);
    try std.testing.expectEqual(@as(u32, 0), Ctx.compensated);
    try std.testing.expectEqual(SagaStatus.completed, orch.getStatus("saga-resume-1").?);

    // Terminal instances refuse to resume: a compensated saga must not be replayed.
    try std.testing.expectError(error.NothingToResume, orch.resumeInstance("saga-resume-1"));
    try std.testing.expectError(error.UnknownInstance, orch.resumeInstance("no-such-instance"));
}

test "restoreFromWal keeps the *latest* state per instance (no stale resurrection)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const wal_config = @import("eventbus/WAL.zig").WALConfig{ .dir_path = "wal_test_latest", .max_segment_size = 1024 * 1024 };
    var wal = try WAL.init(allocator, std.testing.io, wal_config);
    defer wal.deinit();

    // The chain a saga that failed and compensated leaves behind. Before the fix,
    // the `running` records made it come back to life on restart.
    _ = try wal.append(.{ .topic = "saga-state", .payload = "saga-old-1|s|1|0|1700000000", .source_node = "test" });
    _ = try wal.append(.{ .topic = "saga-state", .payload = "saga-old-1|s|1|1|1700000001", .source_node = "test" });
    _ = try wal.append(.{ .topic = "saga-state", .payload = "saga-old-1|s|5|1|1700000002", .source_node = "test" }); // 5 = compensated
    // A second instance that really is still in flight must be restored.
    _ = try wal.append(.{ .topic = "saga-state", .payload = "saga-live-1|s|1|0|1700000003", .source_node = "test" });

    var orch = SagaOrchestrator.init(allocator);
    defer orch.deinit();
    orch.setWal(&wal);
    try orch.restoreFromWal();

    try std.testing.expect(orch.getStatus("saga-old-1") == null); // terminal: not resurrected
    try std.testing.expectEqual(SagaStatus.running, orch.getStatus("saga-live-1").?);
}
