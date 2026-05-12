const std = @import("std");
const Time = @import("Time.zig");

/// 分布式事务管理器
/// 分布式事务管理器
/// 实现 Saga 模式用于分布式事务
pub const DistributedTransactionManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    transactions: std.StringHashMap(SagaTransaction),
    transaction_id_counter: u64 = 1,

    pub const SagaTransaction = struct {
        id: []const u8,
        status: TransactionStatus,
        arena: std.heap.ArenaAllocator,
        steps: std.ArrayList(SagaStep),
        compensations: std.ArrayList(CompensationAction),
        start_time: i64,
        end_time: i64 = 0,

        pub const TransactionStatus = enum(u8) {
            PENDING,
            RUNNING,
            COMPLETED,
            FAILED,
            COMPENSATING,
            COMPENSATED,
        };

        pub const SagaStep = struct {
            name: []const u8,
            action: *const fn () anyerror!void,
            compensation: *const fn () void,
            executed: bool = false,
        };

        pub const CompensationAction = struct {
            step_name: []const u8,
            action: *const fn () void,
            executed: bool = false,
        };
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .transactions = std.StringHashMap(SagaTransaction).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.transactions.iterator();
        while (iter.next()) |entry| {
            var tx = entry.value_ptr.*;
            tx.arena.deinit();
        }
        self.transactions.deinit();
    }

    /// 开始新的事务
    pub fn beginTransaction(self: *Self) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const aa = arena.allocator();

        const id = try std.fmt.allocPrint(aa, "tx-{d}", .{self.transaction_id_counter});
        self.transaction_id_counter += 1;

        const tx = SagaTransaction{
            .id = id,
            .status = .PENDING,
            .arena = arena,
            .steps = std.ArrayList(SagaTransaction.SagaStep).empty,
            .compensations = std.ArrayList(SagaTransaction.CompensationAction).empty,
            .start_time = Time.monotonicNowSeconds(),
        };

        try self.transactions.put(id, tx);
        return id;
    }

    /// 添加 Saga 步骤
    pub fn addStep(
        self: *Self,
        tx_id: []const u8,
        name: []const u8,
        action: *const fn () anyerror!void,
        compensation: *const fn () void,
    ) !void {
        const tx = self.transactions.getPtr(tx_id) orelse return error.TransactionNotFound;
        const aa = tx.arena.allocator();

        try tx.steps.append(aa, .{
            .name = try aa.dupe(u8, name),
            .action = action,
            .compensation = compensation,
        });

        try tx.compensations.append(aa, .{
            .step_name = try aa.dupe(u8, name),
            .action = compensation,
        });
    }

    /// 执行事务
    pub fn execute(self: *Self, tx_id: []const u8) !void {
        const tx = self.transactions.getPtr(tx_id) orelse return error.TransactionNotFound;

        tx.status = .RUNNING;
        std.log.info("Starting distributed transaction: {s}", .{tx_id});

        for (tx.steps.items, 0..) |step, i| {
            step.action() catch |err| {
                std.log.warn("Step '{s}' failed in transaction '{s}': {s}", .{ step.name, tx_id, @errorName(err) });

                // 标记失败的步骤
                tx.steps.items[i].executed = true;

                // 执行补偿
                try self.compensate(tx_id, i);
                return error.TransactionFailed;
            };

            tx.steps.items[i].executed = true;
            std.log.info("Step '{s}' completed in transaction '{s}'", .{ step.name, tx_id });
        }

        tx.status = .COMPLETED;
        tx.end_time = 0;
        std.log.info("Transaction '{s}' completed successfully", .{tx_id});
    }

    /// 补偿事务
    fn compensate(self: *Self, tx_id: []const u8, failed_step_index: usize) !void {
        const tx = self.transactions.getPtr(tx_id) orelse return error.TransactionNotFound;

        tx.status = .COMPENSATING;
        std.log.info("Starting compensation for transaction: {s}", .{tx_id});

        // 逆向执行已完成的步骤的补偿
        var i: usize = failed_step_index;
        while (i > 0) {
            i -= 1;
            const step = tx.steps.items[i];
            if (step.executed) {
                std.log.info("Executing compensation for step '{s}'", .{step.name});
                step.compensation();

                for (tx.compensations.items) |*comp| {
                    if (std.mem.eql(u8, comp.step_name, step.name)) {
                        comp.executed = true;
                        break;
                    }
                }
            }
        }

        tx.status = .COMPENSATED;
        tx.end_time = 0;
        std.log.info("Compensation completed for transaction: {s}", .{tx_id});
    }

    /// 获取事务状态
    pub fn getStatus(self: *Self, tx_id: []const u8) ?SagaTransaction.TransactionStatus {
        const tx = self.transactions.get(tx_id) orelse return null;
        return tx.status;
    }

    /// 获取事务统计
    pub fn getStatistics(self: *Self) TransactionStatistics {
        var stats = TransactionStatistics{};

        var iter = self.transactions.iterator();
        while (iter.next()) |entry| {
            const tx = entry.value_ptr.*;
            stats.total += 1;

            switch (tx.status) {
                .COMPLETED => stats.completed += 1,
                .FAILED, .COMPENSATED => stats.failed += 1,
                .RUNNING => stats.running += 1,
                else => {},
            }
        }

        return stats;
    }
};

pub const TransactionStatistics = struct {
    total: usize = 0,
    completed: usize = 0,
    failed: usize = 0,
    running: usize = 0,
};

/// 两阶段提交 (2PC) 实现
pub const TwoPhaseCommit = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    coordinators: std.StringHashMap(TransactionCoordinator),

    pub const TransactionCoordinator = struct {
        tx_id: []const u8,
        status: TwoPhaseStatus,
        participants: std.ArrayList(Participant),

        pub const TwoPhaseStatus = enum(u8) {
            PREPARING,
            PREPARED,
            COMMITTING,
            COMMITTED,
            ABORTING,
            ABORTED,
        };

        pub const Participant = struct {
            id: []const u8,
            prepare: *const fn () bool,
            commit: *const fn () void,
            rollback: *const fn () void,
            voted: bool = false,
            vote: bool = false,
        };
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .coordinators = std.StringHashMap(TransactionCoordinator).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.coordinators.iterator();
        while (iter.next()) |entry| {
            var coord = entry.value_ptr.*;
            for (coord.participants.items) |participant| {
                self.allocator.free(participant.id);
            }
            coord.participants.deinit(self.allocator);
            self.allocator.free(coord.tx_id);
        }
        self.coordinators.deinit();
    }

    /// 创建协调者
    pub fn createCoordinator(self: *Self, tx_id: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, tx_id);
        try self.coordinators.put(id_copy, .{
            .tx_id = id_copy,
            .status = .PREPARING,
            .participants = std.ArrayList(TransactionCoordinator.Participant).empty,
        });
    }

    /// 添加参与者
    pub fn addParticipant(
        self: *Self,
        tx_id: []const u8,
        participant_id: []const u8,
        prepare: *const fn () bool,
        commit: *const fn () void,
        rollback: *const fn () void,
    ) !void {
        const coord = self.coordinators.getPtr(tx_id) orelse return error.CoordinatorNotFound;

        try coord.participants.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, participant_id),
            .prepare = prepare,
            .commit = commit,
            .rollback = rollback,
        });
    }

    /// 执行两阶段提交
    pub fn execute(self: *Self, tx_id: []const u8) !void {
        const coord = self.coordinators.getPtr(tx_id) orelse return error.CoordinatorNotFound;

        // Phase 1: Prepare
        std.log.info("2PC Phase 1: Prepare for transaction {s}", .{tx_id});
        coord.status = .PREPARING;

        var all_prepared = true;
        for (coord.participants.items) |*participant| {
            const vote = participant.prepare();
            participant.voted = true;
            participant.vote = vote;

            if (!vote) {
                all_prepared = false;
                std.log.warn("Participant {s} voted NO", .{participant.id});
            } else {
                std.log.info("Participant {s} voted YES", .{participant.id});
            }
        }

        // Phase 2: Commit or Abort
        if (all_prepared) {
            std.log.info("2PC Phase 2: Commit for transaction {s}", .{tx_id});
            coord.status = .COMMITTING;

            for (coord.participants.items) |participant| {
                participant.commit();
            }

            coord.status = .COMMITTED;
            std.log.info("Transaction {s} committed successfully", .{tx_id});
        } else {
            std.log.info("2PC Phase 2: Abort for transaction {s}", .{tx_id});
            coord.status = .ABORTING;

            for (coord.participants.items) |participant| {
                participant.rollback();
            }

            coord.status = .ABORTED;
            std.log.info("Transaction {s} aborted", .{tx_id});
            return error.TransactionAborted;
        }
    }
};

/// In-memory append-only transaction log for crash recovery.
/// Records all transaction lifecycle events so state can be replayed.
pub const TransactionLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(LogEntry),

    pub const LogEntry = struct {
        tx_id: []const u8,
        event: Event,
        timestamp: i64,
    };

    pub const Event = union(enum) {
        begin: []const u8, // tx_id
        step_added: StepInfo,
        commit: []const u8,
        abort: []const u8,
        compensate: []const u8,

        pub const StepInfo = struct {
            tx_id: []const u8,
            step_name: []const u8,
            compensation_name: []const u8,
        };
    };

    pub fn init(allocator: std.mem.Allocator) TransactionLog {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(LogEntry).empty,
        };
    }

    pub fn deinit(self: *TransactionLog) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.tx_id);
            switch (e.event) {
                .begin => |id| self.allocator.free(id),
                .step_added => |s| {
                    self.allocator.free(s.tx_id);
                    self.allocator.free(s.step_name);
                    self.allocator.free(s.compensation_name);
                },
                .commit => |id| self.allocator.free(id),
                .abort => |id| self.allocator.free(id),
                .compensate => |id| self.allocator.free(id),
            }
        }
        self.entries.deinit(self.allocator);
    }

    pub fn append(self: *TransactionLog, tx_id: []const u8, event: Event, alloc: std.mem.Allocator) !void {
        const id_copy = try alloc.dupe(u8, tx_id);
        const event_copy = switch (event) {
            .begin => |id| Event{ .begin = try alloc.dupe(u8, id) },
            .step_added => |s| Event{ .step_added = .{
                .tx_id = try alloc.dupe(u8, s.tx_id),
                .step_name = try alloc.dupe(u8, s.step_name),
                .compensation_name = try alloc.dupe(u8, s.compensation_name),
            }},
            .commit => |id| Event{ .commit = try alloc.dupe(u8, id) },
            .abort => |id| Event{ .abort = try alloc.dupe(u8, id) },
            .compensate => |id| Event{ .compensate = try alloc.dupe(u8, id) },
        };
        try self.entries.append(alloc, .{
            .tx_id = id_copy,
            .event = event_copy,
            .timestamp = @import("Time.zig").monotonicNowSeconds(),
        });
    }

    /// Replay the log to recover transaction state after a crash.
    /// Returns the set of in-flight transaction IDs that were active at crash time.
    pub fn replay(self: *const TransactionLog, alloc: std.mem.Allocator) ![][]const u8 {
        var active = std.StringHashMap(void).init(alloc);
        defer active.deinit();
        for (self.entries.items) |e| {
            switch (e.event) {
                .begin => {
                    try active.put(e.tx_id, {});
                },
                .commit, .abort, .compensate => {
                    _ = active.remove(e.tx_id);
                },
                .step_added => {}, // no state change
            }
        }
        var result = std.ArrayList([]const u8).empty;
        var iter = active.iterator();
        while (iter.next()) |entry| {
            try result.append(alloc, entry.key_ptr.*);
        }
        return result.toOwnedSlice(alloc);
    }

    pub fn size(self: *const TransactionLog) usize {
        return self.entries.items.len;
    }
};

// ========================================
// Tests
// ========================================

test "DistributedTransactionManager saga success" {
    const allocator = std.testing.allocator;

    var dtm = DistributedTransactionManager.init(allocator);
    defer dtm.deinit();

    const tx_id = try dtm.beginTransaction();
    // tx_id is owned by DistributedTransactionManager, do not free here

    try dtm.addStep(tx_id, "step1", struct {
        fn action() !void {}
    }.action, struct {
        fn comp() void {}
    }.comp);

    try dtm.addStep(tx_id, "step2", struct {
        fn action() !void {}
    }.action, struct {
        fn comp() void {}
    }.comp);

    try dtm.execute(tx_id);
    try std.testing.expectEqual(DistributedTransactionManager.SagaTransaction.TransactionStatus.COMPLETED, dtm.getStatus(tx_id).?);
}

test "DistributedTransactionManager saga compensation" {
    const allocator = std.testing.allocator;

    var dtm = DistributedTransactionManager.init(allocator);
    defer dtm.deinit();

    const tx_id = try dtm.beginTransaction();
    // tx_id is owned by DistributedTransactionManager, do not free here

    try dtm.addStep(tx_id, "step1", struct {
        fn action() !void {}
    }.action, struct {
        fn comp() void {}
    }.comp);

    try dtm.addStep(tx_id, "step2", struct {
        fn action() !void {
            return error.TestFailure;
        }
    }.action, struct {
        fn comp() void {}
    }.comp);

    const result = dtm.execute(tx_id);
    try std.testing.expectError(error.TransactionFailed, result);
}

test "TwoPhaseCommit success" {
    const allocator = std.testing.allocator;

    var tpc = TwoPhaseCommit.init(allocator);
    defer tpc.deinit();

    try tpc.createCoordinator("tx-1");

    try tpc.addParticipant("tx-1", "p1", struct {
        fn prep() bool {
            return true;
        }
    }.prep, struct {
        fn cmt() void {}
    }.cmt, struct {
        fn roll() void {}
    }.roll);

    try tpc.execute("tx-1");
    try std.testing.expectEqual(TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.COMMITTED, tpc.coordinators.get("tx-1").?.status);
}

test "TwoPhaseCommit abort" {
    const allocator = std.testing.allocator;

    var tpc = TwoPhaseCommit.init(allocator);
    defer tpc.deinit();

    try tpc.createCoordinator("tx-1");

    try tpc.addParticipant("tx-1", "p1", struct {
        fn prep() bool {
            return false;
        }
    }.prep, struct {
        fn cmt() void {}
    }.cmt, struct {
        fn roll() void {}
    }.roll);

    const result = tpc.execute("tx-1");
    try std.testing.expectError(error.TransactionAborted, result);
    try std.testing.expectEqual(TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.ABORTED, tpc.coordinators.get("tx-1").?.status);
}

test "TransactionLog append and replay" {
    const allocator = std.testing.allocator;
    var log = TransactionLog.init(allocator);
    defer log.deinit();

    // Append events
    try log.append("tx-1", TransactionLog.Event{ .begin = "tx-1" }, allocator);
    try log.append("tx-2", TransactionLog.Event{ .begin = "tx-2" }, allocator);
    try log.append("tx-1", TransactionLog.Event{ .commit = "tx-1" }, allocator);
    try log.append("tx-3", TransactionLog.Event{ .begin = "tx-3" }, allocator);

    try std.testing.expectEqual(@as(usize, 4), log.size());

    // Replay: only tx-2 and tx-3 are in-flight (tx-1 committed)
    const active = try log.replay(allocator);
    defer allocator.free(active);

    try std.testing.expectEqual(@as(usize, 2), active.len);
}

test "TransactionLog abort and compensate" {
    const allocator = std.testing.allocator;
    var log = TransactionLog.init(allocator);
    defer log.deinit();

    try log.append("tx-1", TransactionLog.Event{ .begin = "tx-1" }, allocator);
    try log.append("tx-1", TransactionLog.Event{ .step_added = .{ .tx_id = "tx-1", .step_name = "reserve", .compensation_name = "release" } }, allocator);
    try log.append("tx-1", TransactionLog.Event{ .abort = "tx-1" }, allocator);

    // After abort, tx-1 should not be active
    const active = try log.replay(allocator);
    defer allocator.free(active);
    try std.testing.expectEqual(@as(usize, 0), active.len);
}
