//! Persistent x402 invoice ledger: creates invoices, **binds each one to the
//! payer it was issued to**, and **records each redemption exactly once**
//! (idempotent anti-replay). It does **not** verify payment proofs — validity is
//! `X402Config.verifier`'s decision, and `x402Middleware` consults it on every
//! request whether a store is attached or not. Attach to `X402Config.store` to
//! give a payment gate exactly-once semantics; a store alone is never a gate.
//!
//! Binding is the second half of anti-replay: "exactly once" answers *how many
//! times* a proof may be spent, and the payer column answers *by whom*. Without
//! it, anyone who knows (or guesses, or observes) an invoice id could redeem it
//! with a proof of their own and leave the payer it was issued to holding a
//! spent invoice — a denial of service for the legitimate payer, and a stolen
//! invoice wherever the verifier is lenient about who paid.

const std = @import("std");
const SqlxBackend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
const sqlx = @import("../data.zig").sqlx;
const Time = @import("../core/Time.zig");
const x402_mod = @import("x402.zig");

pub const RedeemResult = enum {
    redeemed,
    not_found,
    already_used,
    expired,
    /// The invoice is bound to a **different payer** than the one this proof
    /// arrived with. Kept out of `already_used` on purpose: the invoice is still
    /// open for its payer, and a 410 would report a *pending* invoice as spent —
    /// which is precisely the denial of service the payer column closes.
    payer_mismatch,
};

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
    ///
    /// `CREATE TABLE IF NOT EXISTS` leaves an existing table untouched, so an
    /// install older than `payer_did` would keep the pre-binding schema; the
    /// column is therefore added on demand (see `hasColumn`). Both steps are
    /// safe to repeat — `migrate` is a startup call an app may make on every
    /// boot.
    ///
    /// The DDL is SQLite's: `INTEGER PRIMARY KEY AUTOINCREMENT` is not accepted
    /// by PostgreSQL or MySQL, so `migrate` builds no table there (the same is
    /// true of the framework's other embedded stores). The `ALTER TABLE … ADD
    /// COLUMN` it pairs with is plain SQL, and the existence check under it is
    /// dialect-aware, but only the SQLite arm has been exercised.
    pub fn migrate(self: *Self) !void {
        try sqlx.validateIdentifier(self.table);
        const sql = try std.fmt.allocPrint(
            self.allocator,
            "CREATE TABLE IF NOT EXISTS {s} (id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_id TEXT NOT NULL UNIQUE, payee_did TEXT NOT NULL, payer_did TEXT, amount INTEGER NOT NULL, currency TEXT NOT NULL, chain_id INTEGER NOT NULL DEFAULT 1, deadline INTEGER NOT NULL, description TEXT NOT NULL DEFAULT '', status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, redeemed_at INTEGER, tx_hash TEXT)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = try self.backend.exec(sql, &.{});
        if (!try self.hasColumn("payer_did")) {
            const alter = try std.fmt.allocPrint(
                self.allocator,
                "ALTER TABLE {s} ADD COLUMN payer_did TEXT",
                .{self.table},
            );
            defer self.allocator.free(alter);
            _ = try self.backend.exec(alter, &.{});
        }
    }

    /// Is `column` on the ledger table?
    ///
    /// SQLite answers from the schema itself (`PRAGMA table_info`) — a list of
    /// the real names, so the answer cannot be confused with a failing
    /// connection. PG and MySQL have no `PRAGMA`; the catalogue view
    /// `information_schema.columns` is the portable equivalent (names compared
    /// case-insensitively: PG folds an unquoted identifier to lower case, MySQL
    /// stores `table_name` as the OS created it).
    ///
    /// Errors are returned, never read as "no such column": a probe that failed
    /// because the database is unreachable must not be answered by running DDL
    /// against it.
    fn hasColumn(self: *Self, column: []const u8) !bool {
        try sqlx.validateIdentifier(self.table);
        try sqlx.validateIdentifier(column);
        switch (self.backend.dialect()) {
            .sqlite => {
                const pragma = try std.fmt.allocPrint(
                    self.allocator,
                    "PRAGMA table_info({s})",
                    .{self.table},
                );
                defer self.allocator.free(pragma);
                var cursor = try self.backend.client.queryCursorEx(pragma, &.{}, .{});
                defer cursor.deinit();
                while (cursor.next()) |row| {
                    // The SQLite driver maps SQLITE_NULL to a null optional, so
                    // a `name` that came back at all is a string.
                    const name = row.get("name") orelse continue;
                    switch (name) {
                        .string => |text| if (std.mem.eql(u8, text, column)) return true,
                        else => {},
                    }
                }
                return false;
            },
            // `table` may be schema-qualified (`sqlx.validateIdentifier` allows
            // the dot); only the bare name is compared, and the catalogue is
            // searched by name rather than narrowed to the current schema. A
            // same-named table elsewhere could therefore make this answer
            // "present" too readily — which skips the ALTER, and the failure
            // then lands on the first statement that names `payer_did` (loudly),
            // never as a row that is silently left unbound.
            .postgres, .mysql => {
                const bare = if (std.mem.lastIndexOfScalar(u8, self.table, '.')) |dot|
                    self.table[dot + 1 ..]
                else
                    self.table;
                const probe = "SELECT 1 FROM information_schema.columns WHERE LOWER(table_name) = LOWER(?) AND LOWER(column_name) = LOWER(?)";
                var cursor = try self.backend.client.queryCursorEx(probe, &.{
                    .{ .string = bare },
                    .{ .string = column },
                }, .{});
                defer cursor.deinit();
                return cursor.next() != null;
            },
        }
    }

    /// Insert a pending invoice, bound to `payer_did` when the caller knows who
    /// is paying (the verified identity attr — see `middleware.payerDid`).
    /// Returns `error.DuplicateInvoice` when the id already exists (client
    /// replay of an issued invoice).
    ///
    /// `payer_did` is optional because a deployment may gate a route with no
    /// identity middleware at all. Such a row is **unbound**, and `redeem` lets
    /// any caller that `verifier` accepts spend it — the behaviour of every row
    /// written before this column existed. Pass the identity whenever the
    /// request has one: an unbound invoice cannot be defended against a
    /// stranger who knows its id.
    ///
    /// `created_at` and `deadline` are Unix wall-clock seconds, matching
    /// `x402.Invoice.deadline`: the row outlives the process, and uptime seconds
    /// ("we have been up for 4 hours") say nothing about when a payment is due.
    pub fn create(self: *Self, invoice: x402_mod.Invoice, payer_did: ?[]const u8) !void {
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
            "INSERT INTO {s} (invoice_id, payee_did, payer_did, amount, currency, chain_id, deadline, description, status, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?)",
            .{self.table},
        );
        defer self.allocator.free(sql);
        _ = self.backend.exec(sql, &.{
            .{ .string = invoice.id },
            .{ .string = invoice.payee_did },
            if (payer_did) |p| .{ .string = p } else .null,
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
    /// `payer_did` is who is presenting the proof now (the same verified
    /// identity `create` bound the invoice to), and the row's own `payer_did`
    /// decides whether the claim is theirs — see `RedeemResult.payer_mismatch`.
    /// An **unbound** row (payer `NULL`: written before this column existed, or
    /// by a route with no auth middleware) has nothing to compare and is
    /// redeemable by whoever `verifier` accepts, as it always was.
    ///
    /// The comparison is against the wall clock, the same clock `create` stamps
    /// `deadline` with — an uptime reading would let a process that restarted
    /// after the deadline (or before it) exempt or expire the wrong invoices.
    pub fn redeem(self: *Self, invoice_id: []const u8, tx_hash: []const u8, payer_did: ?[]const u8) !RedeemResult {
        try sqlx.validateIdentifier(self.table);
        const now = Time.wallClockSeconds(self.io());
        const select = try std.fmt.allocPrint(
            self.allocator,
            "SELECT status, deadline, payer_did FROM {s} WHERE invoice_id = ?",
            .{self.table},
        );
        defer self.allocator.free(select);
        var cursor = try self.backend.client.queryCursorEx(select, &.{.{ .string = invoice_id }}, .{});
        defer cursor.deinit();
        const row = cursor.next() orelse return .not_found;
        // Binding first, and before the write: a caller the invoice was not
        // issued to gets no redemption *and* no report of the row's state
        // (spent / expired / still open) — that state is the payer's business.
        // `get` cannot tell a NULL column from a missing one (the SQLite driver
        // maps SQLITE_NULL to a null optional), which is fine here: both mean
        // "no payer on file", and a *missing* column would have failed this
        // SELECT outright rather than reaching this line.
        if (row.get("payer_did")) |stored| switch (stored) {
            .string => |bound| if (bound.len > 0) {
                const claim = payer_did orelse return .payer_mismatch;
                if (!std.mem.eql(u8, bound, claim)) return .payer_mismatch;
            },
            else => {},
        };
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
    try store.create(invoice, null);

    try std.testing.expectEqual(RedeemResult.redeemed, try store.redeem("inv-001", "0xabc", null));
    // Replay is rejected — idempotent anti-replay.
    try std.testing.expectEqual(RedeemResult.already_used, try store.redeem("inv-001", "0xabc2", null));
    try std.testing.expectEqual(RedeemResult.not_found, try store.redeem("inv-999", "0x1", null));
}

test "X402Store refuses a redemption by a payer the invoice was not issued to" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();
    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    try store.migrate();

    // The payer is recorded when the invoice is issued (deadline 0 = no expiry,
    // so nothing below is answered by the clock).
    try store.create(.{
        .id = "inv-bound",
        .payee_did = "did:key:z6MkPayee",
        .amount = 1000000,
        .currency = .usdc,
        .deadline = 0,
        .description = "access",
    }, "did:key:z6MkAlice");

    // A stranger who knows this invoice id cannot spend it with a proof of their
    // own: without this check their redemption is the one that lands, and the
    // payer it was issued to is left trying to redeem a spent invoice.
    try std.testing.expectEqual(RedeemResult.payer_mismatch, try store.redeem("inv-bound", "0xmallory", "did:key:z6MkMallory"));
    // No identity at all is no better a claim to somebody else's invoice.
    try std.testing.expectEqual(RedeemResult.payer_mismatch, try store.redeem("inv-bound", "0xanon", null));

    // Neither attempt consumed anything — the row is still pending, so the
    // payer's own proof below is the *first* redemption, not a replay.
    const pending = try client.queryRow(
        struct { status: i64, redeemed_at: ?i64 },
        "SELECT status, redeemed_at FROM web4_invoice WHERE invoice_id = ?",
        &.{.{ .string = "inv-bound" }},
    );
    try std.testing.expectEqual(@as(i64, 0), pending.status);
    try std.testing.expect(pending.redeemed_at == null);

    try std.testing.expectEqual(RedeemResult.redeemed, try store.redeem("inv-bound", "0xalice", "did:key:z6MkAlice"));
    // Once spent, the payer sees the replay (already_used) while the stranger
    // still gets a mismatch: what the row now says is not a stranger's to read.
    try std.testing.expectEqual(RedeemResult.already_used, try store.redeem("inv-bound", "0xalice2", "did:key:z6MkAlice"));
    try std.testing.expectEqual(RedeemResult.payer_mismatch, try store.redeem("inv-bound", "0xmallory2", "did:key:z6MkMallory"));

    // The binding was stored with the invoice, not inferred at redemption.
    const bound = try client.queryScalar(
        i64,
        "SELECT COUNT(*) FROM web4_invoice WHERE invoice_id = ? AND payer_did = ?",
        &.{ .{ .string = "inv-bound" }, .{ .string = "did:key:z6MkAlice" } },
    );
    try std.testing.expectEqual(@as(?i64, 1), bound);
}

test "X402Store migrates an existing ledger to record payers" {
    const allocator = std.testing.allocator;
    var client = @import("../sqlx/sqlx.zig").Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    // The schema as an install that predates `payer_did` has it. `migrate`'s
    // CREATE TABLE IF NOT EXISTS will not touch it, so the column can only
    // arrive through the ALTER that follows.
    _ = try client.exec("CREATE TABLE web4_invoice (id INTEGER PRIMARY KEY AUTOINCREMENT, invoice_id TEXT NOT NULL UNIQUE, payee_did TEXT NOT NULL, amount INTEGER NOT NULL, currency TEXT NOT NULL, chain_id INTEGER NOT NULL DEFAULT 1, deadline INTEGER NOT NULL, description TEXT NOT NULL DEFAULT '', status INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, redeemed_at INTEGER, tx_hash TEXT)", &.{});
    _ = try client.exec("INSERT INTO web4_invoice (invoice_id, payee_did, amount, currency, deadline, description, status, created_at) VALUES ('inv-legacy', 'did:key:z6MkPayee', 1, 'usdc', 0, '', 0, 0)", &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    try store.migrate();
    // Booting again runs it a second time: the ALTER only happens if the column
    // is still missing, so this is the idempotency the startup call depends on.
    try store.migrate();

    // The column is there — this statement does not even parse without it.
    var probe = try client.queryCursorEx("SELECT payer_did FROM web4_invoice LIMIT 0", &.{}, .{});
    probe.deinit();

    // …and an invoice issued after the migration records its payer.
    try store.create(.{
        .id = "inv-post-migrate",
        .payee_did = "did:key:z6MkPayee",
        .amount = 1,
        .currency = .usdc,
        .deadline = 0,
        .description = "",
    }, "did:key:z6MkBob");
    const bound = try client.queryScalar(
        i64,
        "SELECT COUNT(*) FROM web4_invoice WHERE invoice_id = ? AND payer_did = ?",
        &.{ .{ .string = "inv-post-migrate" }, .{ .string = "did:key:z6MkBob" } },
    );
    try std.testing.expectEqual(@as(?i64, 1), bound);

    // The legacy row has no payer on file. It stays redeemable by whoever the
    // verifier accepts — refusing it would strand every invoice paid before the
    // column existed — and that leniency is exactly what a bound row never gets.
    try std.testing.expectEqual(RedeemResult.redeemed, try store.redeem("inv-legacy", "0xlegacy", "did:key:z6MkStranger"));
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
    }, "did:key:z6MkDemo"));
    try std.testing.expectError(error.InvalidSqlIdentifier, store.redeem("inv-x", "0x0", "did:key:z6MkDemo"));
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
    }, null);
    try std.testing.expectEqual(RedeemResult.expired, try store.redeem("inv-old", "0x1", null));
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
    }, null);

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
    }, null);
    try std.testing.expectEqual(RedeemResult.expired, try store.redeem("inv-past", "0xdead", null));

    try std.testing.expectEqual(RedeemResult.redeemed, try store.redeem("inv-clock", "0xabc", null));
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
    try store.create(invoice, null);
    // The id is already issued: callers (the x402 gate) answer this with a
    // payment-protocol status, so it must be named, not left as the driver's
    // generic `ConstraintViolation`.
    try std.testing.expectError(error.DuplicateInvoice, store.create(invoice, null));
}

/// The catalogue arm of `hasColumn` against a **real** server.
///
/// The `CREATE TABLE` in `migrate` is SQLite's, so on PG/MySQL the ledger table
/// is the application's to create — exactly the situation this probe exists for,
/// and the only way to know that `information_schema` answers it there. Gating
/// and connection variables follow the repo's real-server tests: `ZIGMODU_TEST_PG=1`
/// for PostgreSQL (`core.DistributedLock`), `DB=mysql` for MySQL (`sqlx`), with
/// the usual `PG*` / `MYSQL_*` overrides.
fn probeCatalogColumn(comptime driver: sqlx.Driver) !void {
    const allocator = std.testing.allocator;
    if (!sqlx.DriverFeatures.isEnabled(driver)) return error.SkipZigTest;
    const gate = switch (driver) {
        .postgres => std.c.getenv("ZIGMODU_TEST_PG"),
        .mysql => std.c.getenv("DB"),
        .sqlite => null,
    } orelse return error.SkipZigTest;
    if (!std.mem.eql(u8, std.mem.span(gate), if (driver == .mysql) "mysql" else "1")) return error.SkipZigTest;

    const env = struct {
        fn get(name: [:0]const u8, default: []const u8) []const u8 {
            const raw = std.c.getenv(name) orelse return default;
            return std.mem.span(raw);
        }
        fn port(name: [:0]const u8, default: u16) u16 {
            const raw = std.c.getenv(name) orelse return default;
            return std.fmt.parseInt(u16, std.mem.span(raw), 10) catch default;
        }
    };
    const SqlClient = @import("../sqlx/sqlx.zig").Client;
    const cfg: sqlx.Config = switch (driver) {
        .postgres => .{
            .driver = .postgres,
            .host = env.get("PGHOST", "127.0.0.1"),
            .port = env.port("PGPORT", 5432),
            .username = env.get("PGUSER", "postgres"),
            .password = env.get("PGPASSWORD", ""),
            .database = env.get("PGDATABASE", "postgres"),
            .max_open_conns = 2,
            .max_idle_conns = 1,
        },
        .mysql => .{
            .driver = .mysql,
            .host = env.get("MYSQL_HOST", "127.0.0.1"),
            .port = env.port("MYSQL_PORT", 3306),
            .username = env.get("MYSQL_USER", "root"),
            .password = env.get("MYSQL_PASSWORD", ""),
            .database = env.get("MYSQL_DATABASE", "zigzero_test"),
        },
        // This test is about the dialects without a `PRAGMA`; SQLite is covered
        // by the migration test above, on the path production actually takes.
        .sqlite => return error.SkipZigTest,
    };
    var client = SqlClient.init(allocator, std.testing.io, cfg);
    defer client.deinit();
    try client.connect();

    // A table of its own per run, so repeated and parallel runs never collide.
    var table_buf: [64]u8 = undefined;
    var seed: [8]u8 = undefined;
    try std.Io.randomSecure(std.testing.io, &seed);
    const table = try std.fmt.bufPrint(&table_buf, "zmodu_x402_probe_{s}", .{std.fmt.bytesToHex(seed, .lower)});
    defer {
        var drop_buf: [96]u8 = undefined;
        const drop = std.fmt.bufPrint(&drop_buf, "DROP TABLE IF EXISTS {s}", .{table}) catch "";
        if (drop.len > 0) _ = client.exec(drop, &.{}) catch |err| {
            std.log.debug("web4 catalog probe cleanup failed: {s}", .{@errorName(err)});
        };
    }
    var ddl_buf: [512]u8 = undefined;
    // The same row shape in each server's dialect, *without* `payer_did`: the
    // schema an install older than this column has. (`migrate`'s own CREATE
    // TABLE is SQLite's — `AUTOINCREMENT` — so on these servers the DDL is the
    // application's, which is what this probe exists to handle.)
    const create = try switch (driver) {
        .postgres => std.fmt.bufPrint(&ddl_buf, "CREATE TABLE {s} (id SERIAL PRIMARY KEY, invoice_id TEXT NOT NULL UNIQUE, payee_did TEXT NOT NULL, amount BIGINT NOT NULL, currency TEXT NOT NULL, chain_id BIGINT NOT NULL DEFAULT 1, deadline BIGINT NOT NULL, description TEXT NOT NULL DEFAULT '', status INTEGER NOT NULL DEFAULT 0, created_at BIGINT NOT NULL, redeemed_at BIGINT, tx_hash TEXT)", .{table}),
        .mysql => std.fmt.bufPrint(&ddl_buf, "CREATE TABLE {s} (id INT AUTO_INCREMENT PRIMARY KEY, invoice_id VARCHAR(255) NOT NULL UNIQUE, payee_did VARCHAR(255) NOT NULL, amount BIGINT NOT NULL, currency VARCHAR(32) NOT NULL, chain_id BIGINT NOT NULL DEFAULT 1, deadline BIGINT NOT NULL, description VARCHAR(255) NOT NULL DEFAULT '', status INT NOT NULL DEFAULT 0, created_at BIGINT NOT NULL, redeemed_at BIGINT, tx_hash VARCHAR(255))", .{table}),
        .sqlite => return error.SkipZigTest,
    };
    _ = try client.exec(create, &.{});

    var backend = SqlxBackend{ .allocator = allocator, .client = &client };
    var store = X402Store.init(allocator, &backend);
    store.table = table;

    // The column is not there yet: the answer has to come from the catalogue,
    // not from a statement that happened to fail.
    try std.testing.expect(!try store.hasColumn("payer_did"));

    // The same ALTER `migrate` issues once the probe says "missing".
    var alter_buf: [128]u8 = undefined;
    const alter = try std.fmt.bufPrint(&alter_buf, "ALTER TABLE {s} ADD COLUMN payer_did TEXT", .{table});
    _ = try client.exec(alter, &.{});

    try std.testing.expect(try store.hasColumn("payer_did"));
    // PG folds an unquoted identifier to lower case and MySQL stores whatever
    // the OS created; neither may make the probe deny a column that is there.
    try std.testing.expect(try store.hasColumn("PAYER_DID"));
    // …and one that really is absent still reads as absent (`row shape minus
    // payer_did`, so `payee_did` is there and a column that never existed is not).
    try std.testing.expect(!try store.hasColumn("redeemed_by"));

    // With the column in place the ledger runs here too: these are the same
    // INSERT / SELECT / UPDATE statements SQLite gets, and the binding is what
    // the INSERT writes and the SELECT compares.
    try store.create(.{
        .id = "inv-catalog-probe",
        .payee_did = "did:key:z6MkPayee",
        .amount = 1000000,
        .currency = .usdc,
        .deadline = 0,
        .description = "access",
    }, "did:key:z6MkAlice");
    try std.testing.expectEqual(RedeemResult.payer_mismatch, try store.redeem("inv-catalog-probe", "0xmallory", "did:key:z6MkMallory"));
    try std.testing.expectEqual(RedeemResult.redeemed, try store.redeem("inv-catalog-probe", "0xalice", "did:key:z6MkAlice"));
    try std.testing.expectEqual(RedeemResult.already_used, try store.redeem("inv-catalog-probe", "0xalice2", "did:key:z6MkAlice"));
}

test "X402Store finds the payer column in information_schema on PostgreSQL" {
    try probeCatalogColumn(.postgres);
}

test "X402Store finds the payer column in information_schema on MySQL" {
    try probeCatalogColumn(.mysql);
}
