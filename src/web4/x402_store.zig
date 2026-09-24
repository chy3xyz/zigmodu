//! Persistent x402 invoice ledger: creates invoices and **records each
//! redemption exactly once** (idempotent anti-replay). It does **not** verify
//! payment proofs — validity is `X402Config.verifier`'s decision, and
//! `x402Middleware` consults it on every request whether a store is attached or
//! not. Attach to `X402Config.store` to give a payment gate exactly-once
//! semantics; a store alone is never a gate.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const sqlx = @import("../data.zig").sqlx;
const Time = @import("../core/Time.zig");
const x402_mod = @import("x402.zig");

pub const RedeemResult = enum { redeemed, not_found, already_used, expired };

pub const X402Store = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    backend: *SqlxBackend,
    /// Table name — an *identifier*, interpolated into every statement below.
    /// Values are bound with `?`, identifiers cannot be, so each entry point
    /// runs it through `sqlx.validateIdentifier` first. Payment paths get no
    /// exemption from that gate.
    table: []const u8 = "web4_invoice",

    pub fn init(allocator: std.mem.Allocator, backend: *SqlxBackend) Self {
        return .{ .allocator = allocator, .backend = backend };
    }

    /// The `Io` handle behind this store's client. Wall-clock reads and
    /// `randomSecure` both need one, and this is the handle the store already
    /// writes timestamps with — callers that reach the store without one of
    /// their own (see `middleware.requestIo`) borrow it here.
    pub fn io(self: *const Self) std.Io {
        return self.backend.client.io;
    }

    /// Create the invoice table (idempotent). Call once at startup.
    pub fn migrate(self: *Self) !void {
        try sqlx.validateIdentifier(self.table);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_id TEXT NOT NULL UNIQUE, payee_did TEXT NOT NULL, amount INTEGER NOT NULL, currency TEXT NOT NULL, chain_id INTEGER NOT NULL DEFAULT 1, deadline INTEGER NOT NULL, description TEXT NOT NULL DEFAULT '', status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, redeemed_at INTEGER, tx_hash TEXT)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{});
    }

    /// Insert a pending invoice. Returns `error.DuplicateInvoice` when the id
    /// already exists (client replay of an issued invoice).
    ///
    /// `created_at` and `deadline` are Unix wall-clock seconds, matching
    /// `x402.Invoice.deadline`: the row outlives the process, and uptime seconds
    /// ("we have been up for 4 hours") say nothing about when a payment is due.
    pub fn create(self: *Self, invoice: x402_mod.Invoice) !void {
        try sqlx.validateIdentifier(self.table);
        // Name the collision before it reaches the driver. Re-issuing an id is
        // an expected outcome of this protocol (an app that prices by its own
        // order id meets it on every retry), and the driver reports a rejected
        // INSERT as a generic `DatabaseError` plus an error-level log line —
        // neither of which belongs in the caller's payment flow.
        if (try self.exists(invoice.id)) return error.DuplicateInvoice;
        const now = Time.wallClockSeconds(self.io());
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s} (invoice_id, payee_did, amount, currency, chain_id, deadline, description, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = self.backend.exec(sql, &.{
            .{ .string = invoice.id },
            .{ .string = invoice.payee_did },
            .{ .int = @intCast(invoice.amount) },
            .{ .string = @tagName(invoice.currency) },
            .{ .int = @intCast(invoice.chain_id) },
            .{ .int = invoice.deadline },
            .{ .string = invoice.description },
            .{ .int = now },
        }) catch |err| {
            // The only UNIQUE key on this row is `invoice_id` (every other
            // column is NOT NULL and bound with a value), so a rejected INSERT
            // means the id was taken between the check above and here — or the
            // database is failing. Re-read to tell them apart: sqlite reports a
            // UNIQUE violation as extended code 2067, which never equals the
            // primary 19 that sqlx tests for, so the error class cannot.
            const duplicated = self.exists(invoice.id) catch |check_err| blk: {
                std.log.debug("web4 invoice duplicate check failed: {s}", .{@errorName(check_err)});
                break :blk false;
            };
            if (duplicated) return error.DuplicateInvoice;
            return err;
        };
    }

    /// Does an invoice with this id exist? Used to name a rejected INSERT's
    /// cause, so a read that fails is the caller's problem too.
    fn exists(self: *Self, invoice_id: []const u8) !bool {
        try sqlx.validateIdentifier(self.table);
        const select = try std.fmt.allocPrint(
            self.allocator,
            "SELECT 1 FROM {s} WHERE invoice_id = ?",
            .{self.table},
        );
        defer self.allocator.free(select);
        var cursor = try self.backend.client.queryCursorEx(select, &.{.{ .string = invoice_id }}, .{});
        defer cursor.deinit();
        return cursor.next() != null;
    }

    /// Redeem a proof's invoice id. Succeeds exactly once per invoice: a second
    /// attempt with the same id returns `already_used` (anti-replay), missing
    /// ids return `not_found`, past-deadline invoices return `expired`.
    ///
    /// The comparison is against the wall clock, the same clock `create` stamps
    /// `deadline` with — an uptime reading would let a process that restarted
    /// after the deadline (or before it) exempt or expire the wrong invoices.
    pub fn redeem(self: *Self, invoice_id: []const u8, tx_hash: []const u8) !RedeemResult {
        try sqlx.validateIdentifier(self.table);
        const now = Time.wallClockSeconds(self.io());
        const select = try std.fmt.allocPrint(
            self.allocator,
            "SELECT status, deadline FROM {s} WHERE invoice_id = ?",
            .{self.table},
        );
        defer self.allocator.free(select);
        var cursor = try self.backend.client.queryCursorEx(select, &.{.{ .string = invoice_id }}, .{});
        defer cursor.deinit();
        const row = cursor.next() orelse return .not_found;
        if (row.get("status").?.int != 0) return .already_used;
        if (row.get("deadline").?.int > 0 and row.get("deadline").?.int < now) return .expired;

        const update = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE {s} SET status = 1, redeemed_at = ?, tx_hash = ? WHERE invoice_id = ? AND status = 0",
            .{self.table},
        );
        defer self.allocator.free(update);
        const result = try self.backend.exec(update, &.{
            .{ .int = now },
            .{ .string = tx_hash },
            .{ .string = invoice_id },
        });
        return if (result.rows_affected > 0) .redeemed else .already_used;
    }
};

test "X402Store creates and redeems an invoice exactly once" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    try store.migrate();

    const invoice = x402_mod.Invoice{
        .id = "inv-001",
        .payee_did = "did:key:z6MkDemo",
        .amount = 1000000,
        .currency = .usdc,
        .deadline = Time.wallClockSeconds(std.testing.io) + 3600,
        .description = "access",
    };
    try store.create(invoice);

    try std.testing.expectEqual(RedeemResult.redeemed, try store.redeem("inv-001", "0xabc"));
    // Replay is rejected — idempotent anti-replay.
    try std.testing.expectEqual(RedeemResult.already_used, try store.redeem("inv-001", "0xabc2"));
    try std.testing.expectEqual(RedeemResult.not_found, try store.redeem("inv-999", "0x1"));
}

test "X402Store rejects a table name that is not a plain identifier" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    // This is a payment path: the table name is the one part of each statement
    // that is not bound with `?`, so a bad one must fail before any SQL runs —
    // redeem least of all, since it is the idempotent anti-replay write.
    store.table = "invoice; DROP TABLE ledger";
    try std.testing.expectError(error.InvalidSqlIdentifier, store.migrate());
    try std.testing.expectError(error.InvalidSqlIdentifier, store.create(.{
        .id = "inv-x",
        .payee_did = "did:key:z6MkDemo",
        .amount = 1,
        .currency = .usdc,
        .deadline = Time.wallClockSeconds(std.testing.io) + 60,
        .description = "",
    }));
    try std.testing.expectError(error.InvalidSqlIdentifier, store.redeem("inv-x", "0x0"));
}

test "X402Store rejects expired invoices" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    try store.migrate();
    try store.create(.{
        .id = "inv-old",
        .payee_did = "did:key:z6MkDemo",
        .amount = 1,
        .currency = .eth,
        .deadline = Time.wallClockSeconds(std.testing.io) - 10,
        .description = "",
    });
    try std.testing.expectEqual(RedeemResult.expired, try store.redeem("inv-old", "0x1"));
}

test "X402Store stamps and expires invoices on the wall clock" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    try store.migrate();

    // `deadline` is also what the client is told to pay against (`x402.zig`
    // documents it as a Unix timestamp), and `created_at` is the ledger's own
    // record. Uptime seconds start near zero on every boot, so an hour of slack
    // still separates the two clocks by orders of magnitude.
    const before = Time.wallClockSeconds(std.testing.io);
    try store.create(.{
        .id = "inv-clock",
        .payee_did = "did:key:z6MkDemo",
        .amount = 1,
        .currency = .usdc,
        .deadline = before + 3600,
        .description = "",
    });

    const Stamp = struct { created_at: i64, redeemed_at: ?i64 };
    const row = try client.queryRow(
        Stamp,
        "SELECT created_at, redeemed_at FROM web4_invoice WHERE invoice_id = ?",
        &.{.{ .string = "inv-clock" }},
    );
    try std.testing.expect(@abs(row.created_at - before) <= 60);

    // An invoice whose wall-clock deadline has passed is expired — the check
    // compares against the same clock the deadline came from.
    try store.create(.{
        .id = "inv-past",
        .payee_did = "did:key:z6MkDemo",
        .amount = 1,
        .currency = .usdc,
        .deadline = Time.wallClockSeconds(std.testing.io) - 60,
        .description = "",
    });
    try std.testing.expectEqual(RedeemResult.expired, try store.redeem("inv-past", "0xdead"));

    try std.testing.expectEqual(RedeemResult.redeemed, try store.redeem("inv-clock", "0xabc"));
    const redeemed = try client.queryRow(
        struct { redeemed_at: ?i64 },
        "SELECT redeemed_at FROM web4_invoice WHERE invoice_id = ?",
        &.{.{ .string = "inv-clock" }},
    );
    try std.testing.expect(@abs(redeemed.redeemed_at.? - Time.wallClockSeconds(std.testing.io)) <= 60);
}

test "X402Store reports a duplicate invoice id instead of a driver error" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    try store.migrate();

    const invoice = x402_mod.Invoice{
        .id = "inv-dup",
        .payee_did = "did:key:z6MkDemo",
        .amount = 1,
        .currency = .usdc,
        .deadline = Time.wallClockSeconds(std.testing.io) + 60,
        .description = "",
    };
    try store.create(invoice);
    // The id is already issued: callers (the x402 gate) answer this with a
    // payment-protocol status, so it must be named, not left as the driver's
    // generic `ConstraintViolation`.
    try std.testing.expectError(error.DuplicateInvoice, store.create(invoice));
}
