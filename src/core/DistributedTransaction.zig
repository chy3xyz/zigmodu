const std = @import("std");
const Time = @import("Time.zig");
const TransactionJournal = @import("TransactionJournal.zig").TransactionJournal;

/// Distributed transaction manager based on the Saga pattern.
/// Runs a transaction's steps in order; the first step that fails triggers
/// reverse-order compensation of the steps already executed.
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
        self.* = undefined;
    }

    /// Begin a transaction and return its id; the id lives in the manager's arena.
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

    /// Append a Saga step together with the compensation callback that undoes it.
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

    /// Run the steps in order. A failure marks the step, compensates the
    /// executed steps in reverse and returns error.TransactionFailed.
    pub fn execute(self: *Self, tx_id: []const u8) !void {
        const tx = self.transactions.getPtr(tx_id) orelse return error.TransactionNotFound;

        tx.status = .RUNNING;
        std.log.info("Starting distributed transaction: {s}", .{tx_id});

        for (tx.steps.items, 0..) |step, i| {
            step.action() catch |err| {
                std.log.warn("Step '{s}' failed in transaction '{s}': {s}", .{ step.name, tx_id, @errorName(err) });

                // Mark failed steps
                tx.steps.items[i].executed = true;

                // Execute compensation
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

    /// Compensating transaction
    fn compensate(self: *Self, tx_id: []const u8, failed_step_index: usize) !void {
        const tx = self.transactions.getPtr(tx_id) orelse return error.TransactionNotFound;

        tx.status = .COMPENSATING;
        std.log.info("Starting compensation for transaction: {s}", .{tx_id});

        // Reverse-compensate completed steps
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

    /// Current status of a transaction, or null when the id is unknown.
    pub fn getStatus(self: *Self, tx_id: []const u8) ?SagaTransaction.TransactionStatus {
        const tx = self.transactions.get(tx_id) orelse return null;
        return tx.status;
    }

    /// Counts of transactions per status across the whole manager.
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

/// Two-phase commit (2PC): participants vote in Prepare, then all commit or roll back.
///
/// Attach a `TransactionJournal` with `setJournal` to make the coordinator's
/// decisions durable: the `prepared` record is written before any participant
/// is told to commit, so a coordinator that dies between the phases leaves an
/// in-doubt transaction that `recover` reports instead of a participant that is
/// locked forever. Without a journal the coordinator is memory-only — the
/// behaviour every existing caller already has.
pub const TwoPhaseCommit = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    coordinators: std.StringHashMap(TransactionCoordinator),
    /// Optional durable coordinator log. Unset = in-memory coordinator.
    journal: ?*TransactionJournal = null,

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
        self.* = undefined;
    }

    /// Create coordinator
    pub fn createCoordinator(self: *Self, tx_id: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, tx_id);
        self.coordinators.put(id_copy, .{
            .tx_id = id_copy,
            .status = .PREPARING,
            .participants = std.ArrayList(TransactionCoordinator.Participant).empty,
        }) catch |err| {
            self.allocator.free(id_copy);
            return err;
        };
        // The map owns `id_copy` from here: undo the registration if the
        // journal cannot record it, rather than leaving a coordinator the log
        // has never heard of.
        errdefer self.dropCoordinator(tx_id);
        try self.journalRecord(tx_id, .begun, &.{});
    }

    /// Add participant
    pub fn addParticipant(
        self: *Self,
        tx_id: []const u8,
        participant_id: []const u8,
        prepare: *const fn () bool,
        commit: *const fn () void,
        rollback: *const fn () void,
    ) !void {
        const coord = self.coordinators.getPtr(tx_id) orelse return error.CoordinatorNotFound;

        // Journal the grown participant list before it exists in memory: a
        // crash in between leaves a `begun` record that names the participant,
        // never the reverse.
        {
            var ids = std.ArrayList([]const u8).empty;
            defer ids.deinit(self.allocator);
            for (coord.participants.items) |participant| try ids.append(self.allocator, participant.id);
            try ids.append(self.allocator, participant_id);
            try self.journalRecord(tx_id, .begun, ids.items);
        }

        try coord.participants.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, participant_id),
            .prepare = prepare,
            .commit = commit,
            .rollback = rollback,
        });
    }

    /// Attach the durable coordinator log (`docs/DISTRIBUTED.md`).
    pub fn setJournal(self: *Self, journal: *TransactionJournal) void {
        self.journal = journal;
    }

    fn dropCoordinator(self: *Self, tx_id: []const u8) void {
        const coord = self.coordinators.getPtr(tx_id) orelse return;
        for (coord.participants.items) |participant| self.allocator.free(participant.id);
        coord.participants.deinit(self.allocator);
        if (self.coordinators.fetchRemove(tx_id)) |entry| {
            self.allocator.free(entry.key);
        }
    }

    /// Append one coordinator lifecycle record. Fail-closed: a coordinator with
    /// a journal refuses to advance when the record cannot be written (an
    /// unjournaled decision is exactly the in-doubt hole this closes).
    fn journalRecord(self: *Self, tx_id: []const u8, state: TransactionJournal.TxState, participant_ids: []const []const u8) !void {
        const journal = self.journal orelse return;
        const participants = try TransactionJournal.joinParticipants(self.allocator, participant_ids);
        defer self.allocator.free(participants);
        try journal.record(.{ .tx_id = tx_id, .state = state, .participants = participants });
    }

    /// Journal the state of a coordinator whose participants are already registered.
    fn journalCoordinator(self: *Self, coord: *const TransactionCoordinator, state: TransactionJournal.TxState) !void {
        if (self.journal == null) return;
        var ids = std.ArrayList([]const u8).empty;
        defer ids.deinit(self.allocator);
        for (coord.participants.items) |participant| try ids.append(self.allocator, participant.id);
        try self.journalRecord(coord.tx_id, state, ids.items);
    }

    /// In-doubt transactions from the journal: prepared with no commit/abort
    /// decision on record. **Reports only** — no retry, no rollback, no timeout
    /// policy; the caller decides what the participants should be told. Returns
    /// an empty list when no journal is attached. Free with
    /// `zigmodu.TransactionJournal.freeInDoubt`.
    pub fn recover(self: *Self, allocator: std.mem.Allocator) ![]TransactionJournal.InDoubt {
        const journal = self.journal orelse return allocator.alloc(TransactionJournal.InDoubt, 0);
        return journal.recover(allocator);
    }

    /// Phase 1: collect every vote. When they are all YES the commit decision is
    /// journaled (`prepared`) before this returns — the in-doubt record — and
    /// the coordinator stays `.PREPARED` until phase 2.
    ///
    /// Returns false when a participant voted NO; the caller then decides with
    /// `abortPhase` (which journals the abort decision before rolling back).
    pub fn preparePhase(self: *Self, tx_id: []const u8) !bool {
        const coord = self.coordinators.getPtr(tx_id) orelse return error.CoordinatorNotFound;

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

        if (all_prepared) {
            try self.journalCoordinator(coord, .prepared);
            coord.status = .PREPARED;
        }
        return all_prepared;
    }

    /// Phase 2, commit branch: tell every participant to commit, then journal
    /// `committed`. A failure to journal here leaves a false in-doubt record
    /// (the transaction *is* committed) — reported to a human rather than
    /// silently forgotten, which is the safe direction.
    pub fn commitPhase(self: *Self, tx_id: []const u8) !void {
        const coord = self.coordinators.getPtr(tx_id) orelse return error.CoordinatorNotFound;

        std.log.info("2PC Phase 2: Commit for transaction {s}", .{tx_id});
        coord.status = .COMMITTING;

        for (coord.participants.items) |participant| {
            participant.commit();
        }

        coord.status = .COMMITTED;
        try self.journalCoordinator(coord, .committed);
        std.log.info("Transaction {s} committed successfully", .{tx_id});
    }

    /// Phase 2, abort branch: journal the `aborted` decision, then roll every
    /// participant back.
    pub fn abortPhase(self: *Self, tx_id: []const u8) !void {
        const coord = self.coordinators.getPtr(tx_id) orelse return error.CoordinatorNotFound;

        std.log.info("2PC Phase 2: Abort for transaction {s}", .{tx_id});
        // Decision before action: a crash mid-rollback then replays an abort
        // nobody must re-decide.
        try self.journalCoordinator(coord, .aborted);
        coord.status = .ABORTING;

        for (coord.participants.items) |participant| {
            participant.rollback();
        }

        coord.status = .ABORTED;
        std.log.info("Transaction {s} aborted", .{tx_id});
    }

    /// Run both phases: prepare everyone, then commit if all voted yes,
    /// otherwise roll back every participant and return error.TransactionAborted.
    pub fn execute(self: *Self, tx_id: []const u8) !void {
        if (try self.preparePhase(tx_id)) {
            try self.commitPhase(tx_id);
            return;
        }
        try self.abortPhase(tx_id);
        return error.TransactionAborted;
    }
};

/// In-memory append-only transaction log (saga-style lifecycle events).
/// Process-local: `replay` can only recover state the process still holds — the
/// durable 2PC coordinator log is `TransactionJournal`.
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
        self.* = undefined;
    }

    pub fn append(self: *TransactionLog, tx_id: []const u8, event: Event, alloc: std.mem.Allocator) !void {
        const id_copy = try alloc.dupe(u8, tx_id);
        const event_copy = switch (event) {
            .begin => |id| Event{ .begin = try alloc.dupe(u8, id) },
            .step_added => |s| Event{ .step_added = .{
                .tx_id = try alloc.dupe(u8, s.tx_id),
                .step_name = try alloc.dupe(u8, s.step_name),
                .compensation_name = try alloc.dupe(u8, s.compensation_name),
            } },
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

fn voteYes() bool {
    return true;
}

fn voteNo() bool {
    return false;
}

fn commitNoop() void {}

fn rollbackNoop() void {}

test "TwoPhaseCommit without a journal reports no in-doubt transactions" {
    const allocator = std.testing.allocator;

    var tpc = TwoPhaseCommit.init(allocator);
    defer tpc.deinit();

    try tpc.createCoordinator("tx-1");
    try tpc.addParticipant("tx-1", "orders", voteYes, commitNoop, rollbackNoop);

    try tpc.execute("tx-1");
    try std.testing.expectEqual(TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.COMMITTED, tpc.coordinators.get("tx-1").?.status);

    const in_doubt = try tpc.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, in_doubt);
    try std.testing.expectEqual(@as(usize, 0), in_doubt.len);
}

test "TwoPhaseCommit journals the decision so commit and abort leave nothing in doubt" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");

    var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };

    var journal = TransactionJournal.initWithBackend(allocator, backend);
    defer journal.deinit();
    try journal.migrate();

    var tpc = TwoPhaseCommit.init(allocator);
    defer tpc.deinit();
    tpc.setJournal(&journal);

    // Committed transaction: no longer in doubt once phase 2 journals it.
    try tpc.createCoordinator("tx-commit");
    try tpc.addParticipant("tx-commit", "orders", voteYes, commitNoop, rollbackNoop);
    try tpc.addParticipant("tx-commit", "inventory", voteYes, commitNoop, rollbackNoop);
    try tpc.execute("tx-commit");
    try std.testing.expectEqual(TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.COMMITTED, tpc.coordinators.get("tx-commit").?.status);

    // Aborted transaction: the NO vote journals `aborted`, never `prepared`.
    try tpc.createCoordinator("tx-abort");
    try tpc.addParticipant("tx-abort", "orders", voteNo, commitNoop, rollbackNoop);
    try std.testing.expectError(error.TransactionAborted, tpc.execute("tx-abort"));
    try std.testing.expectEqual(TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.ABORTED, tpc.coordinators.get("tx-abort").?.status);

    const in_doubt = try tpc.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, in_doubt);
    try std.testing.expectEqual(@as(usize, 0), in_doubt.len);
}

test "TwoPhaseCommit: in-doubt transaction survives a coordinator crash" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");
    const db_path = "/tmp/zigmodu_2pc_in_doubt.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};

    // Coordinator #1 reaches `prepared` for both participants and then dies —
    // neither `commitPhase` nor `abortPhase` ever runs.
    {
        var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
        defer client.deinit();
        try client.connect();
        const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
        var journal = TransactionJournal.initWithBackend(allocator, backend);
        defer journal.deinit();
        try journal.migrate();

        var tpc = TwoPhaseCommit.init(allocator);
        defer tpc.deinit();
        tpc.setJournal(&journal);

        try tpc.createCoordinator("tx-in-doubt");
        try tpc.addParticipant("tx-in-doubt", "orders", voteYes, commitNoop, rollbackNoop);
        try tpc.addParticipant("tx-in-doubt", "inventory", voteYes, commitNoop, rollbackNoop);

        try std.testing.expect(try tpc.preparePhase("tx-in-doubt"));
        try std.testing.expectEqual(TwoPhaseCommit.TransactionCoordinator.TwoPhaseStatus.PREPARED, tpc.coordinators.get("tx-in-doubt").?.status);
    }

    // Coordinator #2: new process, same database. The in-doubt transaction is
    // reported so someone can decide what the participants should be told.
    var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
    defer client.deinit();
    try client.connect();
    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var journal = TransactionJournal.initWithBackend(allocator, backend);
    defer journal.deinit();
    try journal.migrate();

    var tpc = TwoPhaseCommit.init(allocator);
    defer tpc.deinit();
    tpc.setJournal(&journal);

    const in_doubt = try tpc.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, in_doubt);
    try std.testing.expectEqual(@as(usize, 1), in_doubt.len);
    try std.testing.expectEqualStrings("tx-in-doubt", in_doubt[0].tx_id);
    try std.testing.expectEqual(@as(usize, 2), in_doubt[0].participants.len);
    try std.testing.expectEqualStrings("orders", in_doubt[0].participants[0]);
    try std.testing.expectEqualStrings("inventory", in_doubt[0].participants[1]);
}

test "TwoPhaseCommit: a reported in-doubt transaction can be decided after recovery" {
    const allocator = std.testing.allocator;
    const data = @import("../data.zig");
    const db_path = "/tmp/zigmodu_2pc_resume.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};

    {
        var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
        defer client.deinit();
        try client.connect();
        const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
        var journal = TransactionJournal.initWithBackend(allocator, backend);
        defer journal.deinit();
        try journal.migrate();

        var tpc = TwoPhaseCommit.init(allocator);
        defer tpc.deinit();
        tpc.setJournal(&journal);

        try tpc.createCoordinator("tx-resume");
        try tpc.addParticipant("tx-resume", "orders", voteYes, commitNoop, rollbackNoop);
        try std.testing.expect(try tpc.preparePhase("tx-resume"));
    }

    // New coordinator: report, then re-drive the commit (the caller's policy —
    // the coordinator supplies no retry/rollback decision of its own).
    var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
    defer client.deinit();
    try client.connect();
    const backend = data.SqlxBackend{ .allocator = allocator, .client = &client };
    var journal = TransactionJournal.initWithBackend(allocator, backend);
    defer journal.deinit();

    var tpc = TwoPhaseCommit.init(allocator);
    defer tpc.deinit();
    tpc.setJournal(&journal);

    const in_doubt = try tpc.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, in_doubt);
    try std.testing.expectEqual(@as(usize, 1), in_doubt.len);
    try std.testing.expectEqualStrings("tx-resume", in_doubt[0].tx_id);

    try tpc.createCoordinator("tx-resume");
    try tpc.addParticipant("tx-resume", "orders", voteYes, commitNoop, rollbackNoop);
    try tpc.commitPhase("tx-resume");

    const after = try tpc.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}
