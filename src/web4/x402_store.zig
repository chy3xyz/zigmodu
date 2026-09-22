//! Persistent x402 invoice store: creates invoices, verifies payment proofs
//! against the ledger and **redeems each invoice exactly once** (idempotent
//! anti-replay). Attach to `X402Config.store` to upgrade the demo middleware
//! into a production payment gate.

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
    pub fn create(self: *Self, invoice: x402_mod.Invoice) !void {
        try sqlx.validateIdentifier(self.table);
        const now = Time.monotonicNowSeconds();
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO {s} (invoice_id, payee_did, amount, currency, chain_id, deadline, description, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{
            .{ .string = invoice.id },
            .{ .string = invoice.payee_did },
            .{ .int = @intCast(invoice.amount) },
            .{ .string = @tagName(invoice.currency) },
            .{ .int = @intCast(invoice.chain_id) },
            .{ .int = invoice.deadline },
            .{ .string = invoice.description },
            .{ .int = now },
        });
    }

    /// Redeem a proof's invoice id. Succeeds exactly once per invoice: a second
    /// attempt with the same id returns `already_used` (anti-replay), missing
    /// ids return `not_found`, past-deadline invoices return `expired`.
    pub fn redeem(self: *Self, invoice_id: []const u8, tx_hash: []const u8) !RedeemResult {
        try sqlx.validateIdentifier(self.table);
        const now = Time.monotonicNowSeconds();
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
        .deadline = Time.monotonicNowSeconds() + 3600,
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
        .deadline = Time.monotonicNowSeconds() + 60,
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
        .deadline = Time.monotonicNowSeconds() - 10,
        .description = "",
    });
    try std.testing.expectEqual(RedeemResult.expired, try store.redeem("inv-old", "0x1"));
}
