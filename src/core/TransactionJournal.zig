//! Durable coordinator journal for two-phase commit.
//!
//! The coordinator is the only actor that knows a 2PC outcome: once every
//! participant has voted YES, those participants are *in doubt* until they are
//! told to commit or to roll back. An in-memory coordinator loses that
//! knowledge when it dies, and the participants stay locked. This journal is
//! the fix — an append-only record of the coordinator's lifecycle
//! (`begun` → `prepared` → `committed` / `aborted`), written **before** the
//! decision is acted on, so a restarted process can ask `recover` which
//! transactions are in doubt.
//!
//! Storage goes through the `data` domain seam (`data.SqlxBackend`), never the
//! driver layer. With no backend the journal degrades to memory: same API, no
//! durability — the pre-journal behaviour.

const std = @import("std");
const Time = @import("Time.zig");
const data = @import("../data.zig");

/// Append-only coordinator journal. Attach it to a `TwoPhaseCommit` with
/// `setJournal` and the coordinator's decisions become durable.
pub const TransactionJournal = struct {
    const Self = @This();

    pub const SqlxBackend = data.SqlxBackend;
    pub const SqlValue = data.sqlx.Value;

    /// Coordinator state as journaled.
    pub const TxState = enum {
        /// Coordinator created / participant registered.
        begun,
        /// Every participant voted YES — the commit decision, durable before
        /// any participant is told to commit. A `prepared` record with no
        /// terminal record after it *is* an in-doubt transaction.
        prepared,
        /// Every participant acknowledged the commit.
        committed,
        /// The abort decision, written before the rollbacks are sent.
        aborted,

        pub fn asText(self: TxState) []const u8 {
            return @tagName(self);
        }

        pub fn fromText(text: []const u8) ?TxState {
            return std.meta.stringToEnum(TxState, text);
        }
    };

    /// One append-only journal record.
    pub const Record = struct {
        tx_id: []const u8,
        state: TxState,
        /// Comma-separated participant ids as of this write (participant ids
        /// must not contain a comma).
        participants: []const u8 = "",
        /// Monotonic seconds (`core/Time`); `0` = stamp on write.
        updated_at: i64 = 0,
    };

    /// A transaction the coordinator left in doubt: prepared, with no
    /// commit/abort decision on record. Reported by `recover`; what to do about
    /// it (re-drive the commit, roll back, page a human) is the caller's call.
    pub const InDoubt = struct {
        tx_id: []const u8,
        participants: [][]const u8,
        updated_at: i64,

        pub fn deinit(self: *InDoubt, allocator: std.mem.Allocator) void {
            allocator.free(self.tx_id);
            for (self.participants) |participant| allocator.free(participant);
            allocator.free(self.participants);
        }
    };

    /// Frees a slice returned by `recover`.
    pub fn freeInDoubt(allocator: std.mem.Allocator, items: []InDoubt) void {
        for (items) |*item| item.deinit(allocator);
        allocator.free(items);
    }

    /// Joins participant ids into the `participants` column.
    pub fn joinParticipants(allocator: std.mem.Allocator, ids: []const []const u8) ![]const u8 {
        return std.mem.join(allocator, ",", ids);
    }

    /// Splits a `participants` column into owned ids (empty fields dropped).
    pub fn splitParticipants(allocator: std.mem.Allocator, csv: []const u8) ![][]const u8 {
        var out = std.ArrayList([]const u8).empty;
        errdefer freeParticipants(allocator, out.items);
        var it = std.mem.splitScalar(u8, csv, ',');
        while (it.next()) |field| {
            if (field.len == 0) continue;
            const id = try allocator.dupe(u8, field);
            errdefer allocator.free(id);
            try out.append(allocator, id);
        }
        return out.toOwnedSlice(allocator);
    }

    allocator: std.mem.Allocator,
    /// `null` = memory-only: same API, nothing survives the process.
    backend: ?SqlxBackend = null,
    table_name: []const u8 = "zigmodu_tx_journal",
    /// Memory fallback: one *latest* record per transaction (memory mode has no
    /// crash to replay), keyed by the same allocation as `value.tx_id`.
    memory: std.StringHashMap(Record),

    /// Memory-only journal (the pre-journal behaviour).
    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .memory = std.StringHashMap(Record).init(allocator),
        };
    }

    /// Durable journal on a SQL backend; call `migrate` once before use.
    pub fn initWithBackend(allocator: std.mem.Allocator, backend: SqlxBackend) Self {
        var journal = init(allocator);
        journal.backend = backend;
        return journal;
    }

    pub fn deinit(self: *Self) void {
        var it = self.memory.iterator();
        while (it.next()) |entry| {
            // The key is `value.tx_id` (one allocation), so it is freed here.
            self.allocator.free(entry.value_ptr.tx_id);
            self.allocator.free(entry.value_ptr.participants);
        }
        self.memory.deinit();
        self.* = undefined;
    }

    pub fn isDurable(self: *const Self) bool {
        return self.backend != null;
    }

    /// Creates the journal table (idempotent). No-op without a backend.
    ///
    /// DDL is deliberately dialect-neutral — `VARCHAR(191)` fits MySQL's index
    /// limit, `BIGINT` is portable, and no index/PK is declared (a plain
    /// append-only heap works on sqlite, PostgreSQL and MySQL alike).
    pub fn migrate(self: *Self) !void {
        const backend = self.backend orelse return;
        const ddl = try std.fmt.allocPrint(
            self.allocator,
            "CREATE TABLE IF NOT EXISTS {s} (tx_id VARCHAR(191) NOT NULL, state VARCHAR(16) NOT NULL, participants TEXT NOT NULL, updated_at BIGINT NOT NULL)",
            .{self.table_name},
        );
        defer self.allocator.free(ddl);
        _ = try backend.exec(ddl, &.{});
    }

    /// Appends one lifecycle record. Records are never updated in place, so a
    /// crash can only ever lose a trailing record, never corrupt an earlier one.
    pub fn record(self: *Self, rec: Record) !void {
        const updated_at = if (rec.updated_at != 0) rec.updated_at else Time.monotonicNowSeconds();

        if (self.backend) |backend| {
            const sql = try std.fmt.allocPrint(
                self.allocator,
                "INSERT INTO {s} (tx_id, state, participants, updated_at) VALUES (?, ?, ?, ?)",
                .{self.table_name},
            );
            defer self.allocator.free(sql);
            _ = try backend.exec(sql, &.{
                .{ .string = rec.tx_id },
                .{ .string = rec.state.asText() },
                .{ .string = rec.participants },
                .{ .int = updated_at },
            });
            return;
        }

        const id_copy = try self.allocator.dupe(u8, rec.tx_id);
        errdefer self.allocator.free(id_copy);
        const participants_copy = try self.allocator.dupe(u8, rec.participants);
        errdefer self.allocator.free(participants_copy);

        if (self.memory.fetchRemove(rec.tx_id)) |old| {
            self.allocator.free(old.value.tx_id);
            self.allocator.free(old.value.participants);
        }
        try self.memory.put(id_copy, .{
            .tx_id = id_copy,
            .state = rec.state,
            .participants = participants_copy,
            .updated_at = updated_at,
        });
    }

    /// All in-doubt transactions: `prepared` with no `committed` / `aborted`
    /// decision on record. **Reports only** — no retry, no rollback, no timeout
    /// policy, and no attempt to find out what the participants actually did.
    /// Free the result with `freeInDoubt`.
    pub fn recover(self: *Self, allocator: std.mem.Allocator) ![]InDoubt {
        const backend = self.backend orelse return self.recoverFromMemory(allocator);

        const sql = try std.fmt.allocPrint(
            self.allocator,
            "SELECT tx_id, participants, updated_at FROM {s} WHERE state = ? AND tx_id NOT IN (SELECT tx_id FROM {s} WHERE state IN (?, ?)) ORDER BY updated_at DESC",
            .{ self.table_name, self.table_name },
        );
        defer self.allocator.free(sql);

        var cursor = try backend.client.queryCursorEx(sql, &.{
            .{ .string = TxState.prepared.asText() },
            .{ .string = TxState.committed.asText() },
            .{ .string = TxState.aborted.asText() },
        }, .{});
        defer cursor.deinit();

        var out = std.ArrayList(InDoubt).empty;
        errdefer {
            for (out.items) |*item| item.deinit(allocator);
            out.deinit(allocator);
        }
        // A transaction can be prepared more than once (a resumed coordinator);
        // report each one once.
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();

        while (cursor.next()) |row| {
            const tx_id_text = textOf(row.get("tx_id"));
            if (tx_id_text.len == 0 or seen.contains(tx_id_text)) continue;

            const tx_id = try allocator.dupe(u8, tx_id_text);
            errdefer allocator.free(tx_id);
            const participants = try splitParticipants(allocator, textOf(row.get("participants")));
            errdefer freeParticipants(allocator, participants);

            // `seen` before `out`: the append is the last fallible step, so an
            // error there cannot leave the item owned twice.
            try seen.put(tx_id, {});
            try out.append(allocator, .{
                .tx_id = tx_id,
                .participants = participants,
                .updated_at = intOf(row.get("updated_at")),
            });
        }
        return out.toOwnedSlice(allocator);
    }

    fn recoverFromMemory(self: *Self, allocator: std.mem.Allocator) ![]InDoubt {
        var out = std.ArrayList(InDoubt).empty;
        errdefer {
            for (out.items) |*item| item.deinit(allocator);
            out.deinit(allocator);
        }
        var it = self.memory.iterator();
        while (it.next()) |entry| {
            const rec = entry.value_ptr.*;
            if (rec.state != .prepared) continue;
            const tx_id = try allocator.dupe(u8, rec.tx_id);
            errdefer allocator.free(tx_id);
            const participants = try splitParticipants(allocator, rec.participants);
            errdefer freeParticipants(allocator, participants);
            try out.append(allocator, .{
                .tx_id = tx_id,
                .participants = participants,
                .updated_at = rec.updated_at,
            });
        }
        return out.toOwnedSlice(allocator);
    }
};

fn freeParticipants(allocator: std.mem.Allocator, participants: [][]const u8) void {
    for (participants) |participant| allocator.free(participant);
    allocator.free(participants);
}

fn textOf(value: ?TransactionJournal.SqlValue) []const u8 {
    const v = value orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn intOf(value: ?TransactionJournal.SqlValue) i64 {
    const v = value orelse return 0;
    return switch (v) {
        .int => |i| i,
        else => 0,
    };
}

// ========================================
// Tests
// ========================================

test "TransactionJournal without a backend records and recovers in memory" {
    const allocator = std.testing.allocator;
    var journal = TransactionJournal.init(allocator);
    defer journal.deinit();

    try std.testing.expect(!journal.isDurable());

    try journal.record(.{ .tx_id = "tx-1", .state = .begun, .participants = "orders" });
    try journal.record(.{ .tx_id = "tx-1", .state = .prepared, .participants = "orders,inventory" });
    try journal.record(.{ .tx_id = "tx-2", .state = .begun, .participants = "orders" });
    try journal.record(.{ .tx_id = "tx-2", .state = .prepared, .participants = "orders" });
    try journal.record(.{ .tx_id = "tx-2", .state = .committed, .participants = "orders" });

    const in_doubt = try journal.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, in_doubt);

    try std.testing.expectEqual(@as(usize, 1), in_doubt.len);
    try std.testing.expectEqualStrings("tx-1", in_doubt[0].tx_id);
    try std.testing.expectEqual(@as(usize, 2), in_doubt[0].participants.len);
    try std.testing.expectEqualStrings("orders", in_doubt[0].participants[0]);
    try std.testing.expectEqualStrings("inventory", in_doubt[0].participants[1]);
}

test "TransactionJournal SQL: round-trips records and drops decided ones" {
    const allocator = std.testing.allocator;
    var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    const backend = TransactionJournal.SqlxBackend{ .allocator = allocator, .client = &client };

    var journal = TransactionJournal.initWithBackend(allocator, backend);
    defer journal.deinit();
    try journal.migrate();
    try std.testing.expect(journal.isDurable());

    // Two transactions prepare; one of them then reaches a terminal state.
    try journal.record(.{ .tx_id = "tx-a", .state = .begun, .participants = "orders" });
    try journal.record(.{ .tx_id = "tx-a", .state = .prepared, .participants = "orders,inventory" });
    try journal.record(.{ .tx_id = "tx-b", .state = .begun, .participants = "billing" });
    try journal.record(.{ .tx_id = "tx-b", .state = .prepared, .participants = "billing" });
    try journal.record(.{ .tx_id = "tx-b", .state = .committed, .participants = "billing" });

    const in_doubt = try journal.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, in_doubt);
    try std.testing.expectEqual(@as(usize, 1), in_doubt.len);
    try std.testing.expectEqualStrings("tx-a", in_doubt[0].tx_id);
    try std.testing.expectEqual(@as(usize, 2), in_doubt[0].participants.len);

    // The abort decision also takes a transaction out of the in-doubt set.
    try journal.record(.{ .tx_id = "tx-a", .state = .aborted, .participants = "orders,inventory" });
    const none = try journal.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "TransactionJournal SQL: a prepared transaction survives losing the coordinator" {
    const allocator = std.testing.allocator;
    const db_path = "/tmp/zigmodu_tx_journal_crash.db";
    std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};

    // First coordinator: prepares, then "dies" (no terminal record, no handle).
    {
        var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
        defer client.deinit();
        try client.connect();
        const backend = TransactionJournal.SqlxBackend{ .allocator = allocator, .client = &client };
        var journal = TransactionJournal.initWithBackend(allocator, backend);
        defer journal.deinit();
        try journal.migrate();
        try journal.record(.{ .tx_id = "tx-crashed", .state = .begun, .participants = "orders" });
        try journal.record(.{ .tx_id = "tx-crashed", .state = .prepared, .participants = "orders,inventory" });
    }

    // Second coordinator, same database: the in-doubt transaction is visible.
    var client = data.sqlx.Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
    defer client.deinit();
    try client.connect();
    const backend = TransactionJournal.SqlxBackend{ .allocator = allocator, .client = &client };
    var journal = TransactionJournal.initWithBackend(allocator, backend);
    defer journal.deinit();
    try journal.migrate();

    const in_doubt = try journal.recover(allocator);
    defer TransactionJournal.freeInDoubt(allocator, in_doubt);
    try std.testing.expectEqual(@as(usize, 1), in_doubt.len);
    try std.testing.expectEqualStrings("tx-crashed", in_doubt[0].tx_id);
    try std.testing.expectEqual(@as(usize, 2), in_doubt[0].participants.len);
    try std.testing.expectEqualStrings("orders", in_doubt[0].participants[0]);
    try std.testing.expectEqualStrings("inventory", in_doubt[0].participants[1]);
}

test "joinParticipants and splitParticipants round-trip" {
    const allocator = std.testing.allocator;
    const ids = [_][]const u8{ "orders", "inventory", "billing" };

    const csv = try TransactionJournal.joinParticipants(allocator, &ids);
    defer allocator.free(csv);
    try std.testing.expectEqualStrings("orders,inventory,billing", csv);

    const back = try TransactionJournal.splitParticipants(allocator, csv);
    defer freeParticipants(allocator, back);
    try std.testing.expectEqual(@as(usize, 3), back.len);
    try std.testing.expectEqualStrings("inventory", back[1]);

    const empty = try TransactionJournal.splitParticipants(allocator, "");
    defer freeParticipants(allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
