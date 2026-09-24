//! SQL client abstraction — aligned with go-zero's core/stores/sqlx.
//! Supports SQLite, PostgreSQL, and MySQL via C bindings.
//!
//! SECURITY: Always use parameterized queries with `?` placeholders.
//! Never concatenate user input directly into SQL strings.
//!
//!   // SAFE — parameterized:
//!   client.query("SELECT * FROM users WHERE name = ?", &.{Value.string(name)});
//!
//!   // UNSAFE — SQL injection risk:
//!   const sql = try std.fmt.allocPrint(alloc, "SELECT * FROM users WHERE name = '{s}'", .{name});
//!   client.query(sql, &.{}); // ← name may contain '; DROP TABLE users; --
//!
//! STRUCTURE (monolith — intentionally NOT split; see docs/PRODUCTION_ROADMAP.md):
//!   §1  Types & helpers     —— Value, Row, Rows, ExecResult, Driver, Conn, Stmt + SQL-fragment guards
//!   §2  Struct scanning      —— buildColumnIndices, scanStruct, valueToType, freeScanned, QueryResult
//!   §3  SQLite driver        —— SQLiteConn + VTable, bind/read helpers, LRU statement cache
//!   §4  PostgreSQL driver    —— PostgresConn + VTable, binary/date/numeric/inet decoders
//!   §5  MySQL driver         —— MySqlConn + VTable, query formatting, row materialisation
//!   §6  Prepared statements  —— Stmt vtable + SQLiteStmt / PostgresStmt / MySqlStmt
//!   §7  Connection pool      —— ConnPool with circuit breaker, health checks, waiters
//!   §8  Unified client       —— Config, Client (init/query/exec/tx), Transaction, misc helpers
//!   §9  Tests                —— offline tests + `DB=`-gated per-driver tests
//!
//! Every section below carries a matching `// ==== §N ... ====` anchor — `grep "§8"` jumps there.
//!
//! MAINTENANCE (do NOT grow this file without reading the roadmap):
//!   - One PR should touch at most ONE § section.
//!   - New DB driver → new file under sqlx/ (e.g. sqlx/foo_conn.zig), register here only.
//!   - New ORM features → sqlx/orm.zig (or data layer), not ad-hoc helpers in §8.
//!   - ConnPool / Row arena / stmt cache changes → full `zig build test` required.

const std = @import("std");
const builtin = @import("builtin");
const Time = @import("../core/Time.zig");
const errors = @import("errors.zig");
const breaker = @import("breaker.zig");

const enable_sqlite = blk: {
    const bo = @import("build_options");
    break :blk if (@hasDecl(bo, "enable_sqlite")) bo.enable_sqlite else true;
};
const enable_postgres = blk: {
    const bo = @import("build_options");
    break :blk if (@hasDecl(bo, "enable_postgres")) bo.enable_postgres else true;
};
const enable_mysql = blk: {
    const bo = @import("build_options");
    break :blk if (@hasDecl(bo, "enable_mysql")) bo.enable_mysql else true;
};

const sqlite3_c = if (enable_sqlite) @import("sqlite3_c.zig") else @import("sqlite3_c_stub.zig");
const libpq_c = if (enable_postgres) @import("libpq_c.zig") else @import("libpq_c_stub.zig");
const libmysql_c = if (enable_mysql) @import("libmysql_c.zig") else @import("libmysql_c_stub.zig");

// ==== §1  Types & helpers ====

/// Compile-time driver feature flags (from `-Ddb=` / `build_options`).
pub const DriverFeatures = struct {
    pub const sqlite = enable_sqlite;
    pub const postgres = enable_postgres;
    pub const mysql = enable_mysql;

    pub fn isEnabled(d: Driver) bool {
        return switch (d) {
            .sqlite => sqlite,
            .postgres => postgres,
            .mysql => mysql,
        };
    }
};
/// Allocate null-terminated copy (replaces removed allocator.dupeZ in Zig 0.17).
fn allocZ(allocator: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const result = try allocator.allocSentinel(u8, s.len, 0);
    @memcpy(result, s);
    return result;
}

/// Format into buffer with null terminator (replaces removed bufPrintZ in Zig 0.17).
/// Reserves the last byte for `\0` so a full format never writes past `buf.len`.
fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    if (buf.len == 0) return error.NoSpaceLeft;
    const written = try std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args);
    buf[written.len] = 0;
    return buf[0..written.len :0];
}

/// Allocate a formatted null-terminated string.
fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    return try allocZ(allocator, s);
}

/// Validates a SQL identifier (table/column name): `[A-Za-z_][A-Za-z0-9_.]*`.
/// The dot allows schema-qualified names (`public.users`).
pub fn validateIdentifier(name: []const u8) error{InvalidSqlIdentifier}!void {
    if (name.len == 0 or name.len > 128) return error.InvalidSqlIdentifier;
    for (name, 0..) |c, i| {
        const ok = switch (c) {
            'a'...'z', 'A'...'Z', '_' => true,
            '0'...'9', '.' => i > 0,
            else => false,
        };
        if (!ok) return error.InvalidSqlIdentifier;
    }
}

/// Statement keywords rejected as whole tokens (case-insensitive) inside SQL
/// fragments. Fragments are WHERE-style predicates; a statement keyword means
/// the caller is smuggling a second statement or subquery, not a predicate.
const banned_fragment_keywords = [_][]const u8{
    "union",   "select",   "insert", "update", "delete",  "drop",
    "alter",   "create",   "attach", "detach", "pragma",  "exec",
    "execute", "truncate", "grant",  "revoke", "replace",
};

/// Character-level bans shared by fragment and statement validation:
/// string literals, statement separators, comments and identifier quoting.
fn validateSqlChars(sql: []const u8) error{UnsafeSqlFragment}!void {
    var i: usize = 0;
    while (i < sql.len) : (i += 1) {
        switch (sql[i]) {
            '\'', '"', '`', ';', '#', 0 => return error.UnsafeSqlFragment,
            '-' => if (i + 1 < sql.len and sql[i + 1] == '-') return error.UnsafeSqlFragment,
            '/' => if (i + 1 < sql.len and (sql[i + 1] == '*' or sql[i + 1] == '/')) return error.UnsafeSqlFragment,
            '*' => if (i + 1 < sql.len and sql[i + 1] == '/') return error.UnsafeSqlFragment,
            else => {},
        }
    }
}

/// Defense-in-depth check for SQL fragments interpolated into query strings
/// (e.g. `where_clause` in findOne/findAll). Values MUST be passed via `?`
/// placeholders + args — string literals, statement separators, comments,
/// identifier quoting (backticks) and statement keywords (`UNION`, `SELECT`,
/// ...) are rejected to block injection through the fragment itself.
pub fn validateSqlFragment(fragment: []const u8) error{UnsafeSqlFragment}!void {
    if (fragment.len > 4096) return error.UnsafeSqlFragment;
    try validateSqlChars(fragment);
    var i: usize = 0;
    while (i < fragment.len) : (i += 1) {
        switch (fragment[i]) {
            'a'...'z', 'A'...'Z', '_' => {
                const start = i;
                while (i + 1 < fragment.len) : (i += 1) {
                    const n = fragment[i + 1];
                    if (!((n >= 'a' and n <= 'z') or (n >= 'A' and n <= 'Z') or (n >= '0' and n <= '9') or n == '_')) break;
                }
                const tok = fragment[start .. i + 1];
                for (banned_fragment_keywords) |kw| {
                    if (std.ascii.eqlIgnoreCase(tok, kw)) return error.UnsafeSqlFragment;
                }
            },
            else => {},
        }
    }
}

/// Statement-context variant for full read-only statements (e.g. the AI
/// `db.query` skill, which additionally requires a leading `SELECT`):
/// applies the character-level bans (literals / comments / separators /
/// backticks) but no keyword ban — a full statement legitimately starts
/// with `SELECT` and may contain subqueries. Callers must enforce the
/// read-only verb themselves before/after calling this.
pub fn validateSqlStatement(sql: []const u8) error{UnsafeSqlFragment}!void {
    if (sql.len > 4096) return error.UnsafeSqlFragment;
    try validateSqlChars(sql);
}

/// SQL value types for parameterized queries
pub const Value = union(enum) {
    null,
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
};

/// Row of query results
pub const Row = struct {
    /// Pointer to the Rows arena. Stable across arena relocation (move from
    /// stack to Rows struct). Use .allocator() to get a working Allocator.
    arena: *std.heap.ArenaAllocator,
    columns: []const []const u8,
    values: []const ?Value,
    /// Single-entry lazy column-name → index cache for hot repeated lookups.
    cached_col: ?[]const u8 = null,
    cached_idx: usize = 0,

    pub fn rowAllocator(self: Row) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn get(self: *Row, column: []const u8) ?Value {
        if (self.cached_col) |c| {
            if (std.mem.eql(u8, c, column)) return self.values[self.cached_idx];
        }
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col, column)) {
                self.cached_col = column;
                self.cached_idx = i;
                return self.values[i];
            }
        }
        return null;
    }

    pub fn scan(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, false, null, false);
    }

    pub fn scanPartial(self: Row, allocator: std.mem.Allocator, comptime T: type) !T {
        return scanStruct(allocator, T, self, true, null, false);
    }
};

/// Query results
pub const Rows = struct {
    arena: std.heap.ArenaAllocator,
    /// Mutable — queryRows/queryRow update row.arena to point to this Rows.arena.
    /// Using `[]Row` (not `[]const Row`) avoids @constCast which Zig 0.17-dev
    /// may optimize away in certain monomorphized instances.
    rows: []Row,

    pub fn deinit(self: *Rows) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// RAII managed wrapper for query results to guarantee memory release in current scope.
pub const ManagedRows = struct {
    rows: Rows,

    pub fn init(rows: Rows) ManagedRows {
        return .{ .rows = rows };
    }

    pub fn deinit(self: *ManagedRows) void {
        self.rows.deinit();
    }

    pub fn get(self: *const ManagedRows) []const Row {
        return self.rows.rows;
    }

    pub fn first(self: *const ManagedRows) ?*Row {
        if (self.rows.rows.len == 0) return null;
        return &self.rows.rows[0];
    }
};

/// RAII wrapper for a single scanned row whose `[]const u8` fields borrow an
/// arena owned by this wrapper (no per-field dupe, no `freeScanned` needed).
/// The value is valid until `deinit()`; `get()` returns a shallow copy (string
/// pointers still point into the arena). Prefer `queryRowBorrowed` /
/// `queryRowPartialBorrowed` when the row is consumed within a scope.
///
/// **Lifetime contract: a `BorrowedRow` must not escape its function scope**
/// — strings point into the wrapper-owned arena, so returning it (or storing
/// it beyond `deinit()`) leaves the caller with dangling pointers. For
/// cross-scope returns use the owned `queryRow`/`queryRowOwned` + `freeScanned`.
pub fn BorrowedRow(comptime T: type) type {
    return struct {
        value: T,
        arena: std.heap.ArenaAllocator,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }

        /// Shallow copy of the scanned row. String fields remain valid until
        /// `deinit()`.
        pub fn get(self: *const @This()) T {
            return self.value;
        }
    };
}

/// Cursor fetch mode.
pub const CursorMode = enum {
    /// Materialize all rows upfront. Rows remain valid until `cursor.deinit()`.
    /// The connection is handed back to the pool immediately.
    buffered,
    /// Fetch rows lazily from the driver. The row returned by `next()` is only
    /// valid until the next call to `next()` or `deinit()`. The cursor holds a
    /// pooled connection until `deinit` (which drains the unconsumed tail of
    /// the stream first) — so `deinit` before using the client for anything
    /// else, and well before `Client.deinit`.
    streaming,
};

/// Options for `Client.queryCursorEx`.
pub const CursorOptions = struct {
    mode: CursorMode = .buffered,
};

/// Batch insert strategy.
pub const BatchMode = enum {
    /// Build a single multi-row `INSERT ... VALUES (...), (...)` statement.
    sql,
    /// Use driver-native batch protocols (MySQL prepared-statement multi-execute
    /// or PostgreSQL `COPY FROM STDIN`).
    protocol,
};

/// Options for `Client.batchInsertEx`.
pub const BatchInsertOptions = struct {
    mode: BatchMode = .sql,
};

/// Streaming cursor over a query result set.
///
/// Ownership: a `.streaming` cursor reads from a live driver connection, so it
/// holds onto it (`checkout`) until `deinit`, which drains whatever part of the
/// result stream was not consumed and only then returns the connection to the
/// pool. A cursor must therefore be `deinit`'d before its `Client` (`Client.deinit`
/// tears the pool down — releasing into it afterwards writes to undefined
/// memory), and no other statement may run on that client until it is: on the
/// single-connection path (no pool) there is exactly one connection to
/// interleave with.
///
/// Observability: acquiring a cursor is reported like any other read (metrics
/// callback + circuit breaker, see `Client.queryCursorEx`). Reading one is
/// reported to the circuit breaker — but not to the meter: a driver failure
/// while fetching is counted once against the owning client's breaker (as is a
/// pooled stream that broke while draining), while the metrics callback stays
/// with acquisition because it is keyed by the statement text. `sql_str`
/// belongs to the caller and has no promised lifetime (`src/ai/business.zig`
/// passes a scratch buffer's `items`), so the cursor can neither borrow it nor
/// keep an index into it; copying it once per cursor was rejected as a
/// permanent allocation on every acquisition, paid for a failure most cursors
/// never hit — see `bookFailure`. The failure itself is not lost: `next`
/// returns it to the caller.
pub const Cursor = struct {
    state: State,
    pos: usize = 0,
    /// Pooled connection this cursor owns until `deinit`; null for buffered
    /// cursors (rows already materialized) and for the single-connection path
    /// (that connection belongs to the `Client`, not to a pool).
    checkout: ?Checkout = null,
    /// The client whose breaker this cursor's failures are counted against —
    /// set by `Client.doQueryCursor`, the only place that knows it. Null only
    /// for cursors a test built by hand. Same stability requirement as the
    /// pool's `client` back-pointer: the address must stay valid until the
    /// cursor is `deinit`'d, which is already the documented contract.
    owner: ?*Client = null,
    /// Whether this cursor already counted a failure, so `deinit` does not
    /// count the same break a second time.
    booked_failure: bool = false,

    const State = union(enum) {
        buffered: Rows,
        streaming_mysql: MySqlCursor,
        streaming_pg: PgCursor,
    };

    /// A pool slot the cursor has to give back.
    pub const Checkout = struct {
        pool: *ConnPool,
        conn: Conn,
    };

    pub fn init(rows: Rows) Cursor {
        return .{ .state = .{ .buffered = rows } };
    }

    pub fn deinit(self: *Cursor) void {
        switch (self.state) {
            .buffered => |*rows| rows.deinit(),
            .streaming_mysql => |*c| c.deinit(),
            .streaming_pg => |*c| c.deinit(),
        }
        // The driver deinit above drained the rest of the result stream, so the
        // connection is idle on the wire again — but only hand back one that is
        // still usable. A stream that broke while draining (`ping` fails) is
        // retired instead: re-pooling it would hand the next borrower a
        // connection whose protocol state is unknown.
        if (self.checkout) |co| {
            if (co.conn.ping()) |_| {
                co.pool.release(co.conn);
            } else |err| {
                // The half of "the stream broke" that `next` cannot see: a
                // cursor drained or abandoned over a connection that died, where
                // no `next` call ever returned an error to book. The end state
                // of the connection is visible here as a failed `ping`, and it
                // is the same filter and the same once-per-cursor rule the fetch
                // side uses (`bookFailure`), so a break `next` already counted
                // is not counted twice.
                self.bookFailure(err);
                co.pool.discard(co.conn);
            }
        }
        self.* = undefined;
    }

    /// Count `err` as a failed read attempt against the owning client's breaker,
    /// at most once per cursor.
    ///
    /// Called from both ends of a cursor's life: `next` on a driver failure in
    /// the middle of a result, and `deinit` when the connection turns out to be
    /// dead after the drain. Both are read attempts that failed, and the
    /// acquisition path (`Client.queryCursorExPrimary`) counts exactly that
    /// class — a client whose streamed statements keep dying at row N has to be
    /// able to trip its breaker, or replica routing keeps sending reads to a
    /// backend that cannot serve them.
    ///
    /// Nothing is allocated here and no statement text is needed: the breaker is
    /// per client, not per statement. That is what makes booking the use phase
    /// affordable, and it is also the whole reason the metrics callback is not
    /// fed here — the meter is keyed by `sql_str`, which the cursor does not own
    /// (see the `Cursor` doc comment).
    fn bookFailure(self: *Cursor, err: anyerror) void {
        if (self.booked_failure) return;
        const client = self.owner orelse return;
        // Same filter as acquisition, so the acceptable-error rule stays "never
        // counted, on either path".
        if (client.isAcceptable(err)) return;
        client.cb.recordFailure(client.io);
        self.booked_failure = true;
    }

    /// True when rows are pulled from the driver on demand, i.e. this cursor
    /// owns a live wire stream that only `deinit` may end. Drivers without
    /// incremental fetch (sqlite) serve a `.streaming` request buffered.
    pub fn isStreaming(self: *const Cursor) bool {
        return switch (self.state) {
            .buffered => false,
            .streaming_mysql, .streaming_pg => true,
        };
    }

    /// Pull the next row, or `null` once the result set is exhausted (or the
    /// cursor was already drained).
    ///
    /// A driver failure **in the middle** of a stream comes back as an error,
    /// never as `null`: "the row source broke" and "the rows ran out" are
    /// different events, and a caller that cannot tell them apart reports a
    /// truncated result as a complete one. `try` on the result is therefore not
    /// optional bookkeeping — it is what makes the short read visible. The same
    /// failure is counted against the owning client's breaker on its way out
    /// (`bookFailure`), because the caller that sees it may be the only other
    /// party that ever will.
    pub fn next(self: *Cursor) errors.ResultT(?*Row) {
        return self.fetchNext() catch |err| {
            self.bookFailure(err);
            return err;
        };
    }

    /// The fetching half of `next`, with none of the failure bookkeeping.
    fn fetchNext(self: *Cursor) errors.ResultT(?*Row) {
        switch (self.state) {
            .buffered => |*rows| {
                if (self.pos >= rows.rows.len) return null;
                const row = &rows.rows[self.pos];
                // The buffered path hands back rows whose `arena` still points
                // wherever the driver left it (a stack frame, or `undefined`) —
                // `Row.rowAllocator()` / `scan()` on those is UB. The other
                // buffered entry points patch it the same way.
                row.arena = &rows.arena;
                self.pos += 1;
                return row;
            },
            .streaming_mysql => |*c| return c.next(),
            .streaming_pg => |*c| return c.next(),
        }
    }

    pub fn reset(self: *Cursor) void {
        switch (self.state) {
            .buffered => self.pos = 0,
            .streaming_mysql, .streaming_pg => {}, // forward-only
        }
    }
};

/// Driver-native streaming cursor for MySQL/MariaDB. Uses `mysql_use_result` so
/// rows are pulled over the wire on demand. The active `Row` is invalidated by
/// the next `next()` call.
const MySqlCursor = struct {
    mysql: ?*libmysql_c.MYSQL,
    res: ?*libmysql_c.MYSQL_RES,
    /// Row values only. `next` resets this arena on every call, so nothing that
    /// has to outlive a row may be allocated here — that is why the column
    /// names live in `columns_arena` instead (they used to be allocated here
    /// and were freed by the first `reset`, leaving every row's `columns` slice
    /// dangling).
    arena: std.heap.ArenaAllocator,
    /// Column names, copied at acquisition: one set per result set, shared by
    /// every row, freed by `deinit`.
    columns_arena: std.heap.ArenaAllocator,
    columns: []const []const u8,
    row: Row,
    eof: bool,

    fn deinit(self: *MySqlCursor) void {
        // `mysql_free_result` on a `mysql_use_result` handle reads and discards
        // the rows still on the wire — that is what returns the connection to
        // an idle protocol state. Dropping it (or `mysql_store_result`-ing it
        // first) would leave the next `mysql_real_query` reading this result
        // set's frames.
        if (self.res) |r| libmysql_c.mysql_free_result(r);
        self.arena.deinit();
        self.columns_arena.deinit();
        self.* = undefined;
    }

    fn next(self: *MySqlCursor) errors.ResultT(?*Row) {
        if (self.eof or self.res == null) return null;
        _ = self.arena.reset(.free_all);
        const row_data = libmysql_c.mysql_fetch_row(self.res);
        if (row_data == null) {
            // `NULL` means either "no more rows" or a read failure, and only
            // the error slot tells them apart. Folding the two together is what
            // let a broken stream reach the caller as a short result set.
            const err_no = libmysql_c.mysql_errno(self.mysql);
            if (err_no != 0) {
                const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
                std.log.warn("[sqlx] MySQL stream failed mid-result: errno={d} msg={s}", .{ err_no, err_msg });
                self.eof = true;
                return mysqlErrnoToError(err_no);
            }
            self.eof = true;
            return null;
        }
        const row_ptr = row_data.?;
        const lengths = libmysql_c.mysql_fetch_lengths(self.res);
        // One length per column, every time — a `NULL` here is a driver
        // failure, not an empty row, and indexing it was a null deref. The
        // branch is a guard rather than a covered path: the C API documents
        // `mysql_fetch_lengths` as NULL only when the *preceding* fetch
        // returned NULL, and no live statement was found that makes it NULL
        // after the successful fetch above (see the MySQL streaming tests).
        if (lengths == null) {
            std.log.warn("[sqlx] MySQL stream failed mid-result: mysql_fetch_lengths returned NULL", .{});
            self.eof = true;
            return error.DatabaseError;
        }
        const n_cols = self.columns.len;
        const values = try self.arena.allocator().alloc(?Value, n_cols);
        for (0..n_cols) |c| {
            if (row_ptr[c] == null) {
                values[c] = null;
            } else {
                const len = lengths[c];
                const val = row_ptr[c].?[0..len];
                values[c] = .{ .string = try self.arena.allocator().dupe(u8, val) };
            }
        }
        self.row = .{
            .arena = &self.arena,
            .columns = self.columns,
            .values = values,
        };
        return &self.row;
    }
};

/// Driver-native streaming cursor for PostgreSQL. Uses `PQsendQueryParams` +
/// `PQsetSingleRowMode` so the server emits one row per result. The active `Row`
/// is invalidated by the next `next()` call.
const PgCursor = struct {
    conn: ?*libpq_c.PGconn,
    /// Row values only. `next` resets this arena on every call, so nothing that
    /// has to outlive a row may be allocated here — that is why the column
    /// names live in `columns_arena` instead (they used to be allocated here
    /// and were freed by the first `reset`, leaving every row's `columns` slice
    /// dangling).
    arena: std.heap.ArenaAllocator,
    /// Column names, copied at acquisition: one set per result set, shared by
    /// every row, freed by `deinit`.
    columns_arena: std.heap.ArenaAllocator,
    columns: []const []const u8,
    row: Row,
    current: ?*libpq_c.PGresult,
    eof: bool,

    fn deinit(self: *PgCursor) void {
        // Abandoning the cursor early must not leave the connection mid-stream:
        // libpq returns to an idle protocol state only once every result of the
        // in-flight query has been fetched, which is why clearing `current`
        // alone (the previous behavior) left the next borrower — `ping` only
        // looks at `PQstatus`, which stays CONNECTION_OK — reading this query's
        // leftover frames.
        //
        // The drain below is what restores that state. The cancel in front of it
        // is what keeps the drain from having to *read* the whole remaining
        // result set: without it, dropping a cursor over a large scan costs
        // every remaining row on the wire. Cancel is an optimization, never a
        // requirement — when it cannot be dispatched (dead connection,
        // unreachable postmaster) the drain still ends the stream, which is
        // exactly the old behavior and the old cost.
        if (self.conn) |conn| {
            if (self.current) |res| libpq_c.PQclear(res);
            self.current = null;
            // `eof` set means the driver already saw the end of the stream
            // (`PQgetResult` returned null, or an error status ended it): there
            // is nothing in flight to cancel, and a cancel nobody needs is a
            // wasted postmaster connection.
            if (!self.eof) cancelInFlight(conn);
            while (libpq_c.PQgetResult(conn)) |res| libpq_c.PQclear(res);
        } else if (self.current) |res| {
            libpq_c.PQclear(res);
            self.current = null;
        }
        self.arena.deinit();
        self.columns_arena.deinit();
        self.* = undefined;
    }

    fn next(self: *PgCursor) errors.ResultT(?*Row) {
        if (self.eof) return null;
        _ = self.arena.reset(.free_all);
        const res = self.current orelse {
            self.eof = true;
            // No further result. On a healthy connection that is the end of the
            // query; if libpq lost the connection, saying so is the whole point
            // of the error channel — the rows that did arrive are a prefix, not
            // the result set.
            if (self.conn) |conn| {
                if (libpq_c.PQstatus(conn) != .CONNECTION_OK) {
                    std.log.warn("[sqlx] PG stream lost its connection: {s}", .{cStrSpan(libpq_c.PQerrorMessage(conn))});
                    return error.DatabaseConnectionFailed;
                }
            }
            return null;
        };
        const status = libpq_c.PQresultStatus(res);
        if (status == libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
            libpq_c.PQclear(res);
            self.current = null;
            self.eof = true;
            return null;
        }
        if (status != libpq_c.ExecStatusType.PGRES_TUPLES_OK and status != libpq_c.ExecStatusType.PGRES_SINGLE_TUPLE) {
            // A failure result in the middle of a stream — the server says why,
            // and that reason is what the caller gets: same SQLSTATE mapping the
            // acquisition path uses, so a statement that dies at row 10^6 is
            // classified like one that dies at parse time.
            const db_err = pgResultToError(res);
            std.log.warn("[sqlx] PG stream failed mid-result ({s}): {s}", .{ @tagName(status), cStrSpan(libpq_c.PQresultErrorMessage(res)) });
            libpq_c.PQclear(res);
            self.current = null;
            self.eof = true;
            return db_err;
        }
        // A zero-row `PGRES_TUPLES_OK` is the end of the stream, not a row. In
        // single-row mode libpq delivers the query's *row-description* result —
        // zero rows, the original `PQresult` restored by `pqPrepareAsyncResult`
        // once the last tuple is handed out — as the terminal result, and an
        // empty result set is delivered as exactly that result too (it is then
        // the only result the query ever produces). Reading row 0 out of it is
        // out of range, and libpq answers "is null" for every column, so this
        // used to come back as one phantom all-NULL row — which for an empty
        // result set was the only row the caller ever saw, and which panics the
        // usual `row.get("col").?.int` decoding.
        if (libpq_c.PQntuples(res) == 0) {
            libpq_c.PQclear(res);
            self.current = libpq_c.PQgetResult(self.conn);
            // If nothing else is pending the stream has ended, so record it:
            // `deinit` then has nothing to cancel and nothing to drain.
            if (self.current == null) self.eof = true;
            return null;
        }
        const n_cols = libpq_c.PQnfields(res);
        const values = try self.arena.allocator().alloc(?Value, @intCast(n_cols));
        for (0..@intCast(n_cols)) |c| {
            values[c] = try pgReadCell(self.arena.allocator(), res, 0, @intCast(c));
        }
        self.row = .{
            .arena = &self.arena,
            .columns = self.columns,
            .values = values,
        };
        libpq_c.PQclear(res);
        self.current = libpq_c.PQgetResult(self.conn);
        return &self.row;
    }
};

/// Classify a `PGresult` that is not usable data: the SQLSTATE decides, exactly
/// as it does on the acquisition path (`queryFn` / `execFn`), so a failure that
/// arrives mid-stream is named like the same failure arriving up front.
/// Nothing is logged here — each caller's log line names the statement, which
/// the result itself does not carry.
fn pgResultToError(res: *libpq_c.PGresult) errors.Error {
    const db_err = errors.sqlStateToError(cStrSpan(libpq_c.PQresultErrorField(res, PG_DIAG_SQLSTATE)));
    return switch (db_err) {
        error.ConstraintViolation => error.ConstraintViolation,
        error.NotFound => error.NotFound,
        error.ConnectionFailed => error.DatabaseConnectionFailed,
        error.SerializationFailure => error.SerializationFailure,
        error.ReadOnlyViolation => error.ReadOnlyViolation,
        else => error.DatabaseError,
    };
}

/// The detail a `ConstraintViolation` deserves and the generic error name does
/// not carry: which constraint, on which table and column.
fn logPgConstraintViolation(res: *libpq_c.PGresult) void {
    const diag = diagnosePostgres(res);
    std.log.err("PG constraint violation: table={s} column={s}", .{ diag.table orelse "?", diag.column orelse "?" });
}

/// `PQcancel` writes its failure text into a caller-supplied buffer; libpq's
/// own comment calls 256 the recommended size (fe-cancel.c: "must be of size
/// errbufsize (recommended size is 256 bytes)").
const PG_CANCEL_ERRBUF_SIZE = 256;

/// Ask the server to abort `conn`'s in-flight command — best effort, no return
/// value: the caller drains the result stream either way, so a cancel that does
/// not dispatch is a cost, not an error.
///
/// Assumptions this relies on:
///   * the connection is not being used concurrently. `PgCursor.deinit` is the
///     only caller and a streaming cursor holds its pool checkout, so no other
///     statement can be in flight on `conn`; the cancel is issued *between*
///     `PQgetResult` calls, never during one (the old cancel protocol is
///     signal-safe but not reentrant);
///   * cancel only affects a command already running on the server. When the
///     command has already finished, the request is a no-op the backend
///     discards while idle (tcop/postgres.c: "Query cancel is supposed to be a
///     no-op when there is no query in progress"), which is why this is gated on
///     `!eof` rather than being issued unconditionally.
fn cancelInFlight(conn: *libpq_c.PGconn) void {
    const cancel = libpq_c.PQgetCancel(conn) orelse return;
    defer libpq_c.PQfreeCancel(cancel);
    // Zeroed, not `undefined`: a failed dispatch is *documented* to leave the
    // message here, but only a terminated buffer makes reading it safe if that
    // ever stops being true.
    var errbuf: [PG_CANCEL_ERRBUF_SIZE]u8 = @splat(0);
    if (libpq_c.PQcancel(cancel, &errbuf, PG_CANCEL_ERRBUF_SIZE) == 0) {
        std.log.debug("[sqlx] PG cancel request not dispatched: {s}", .{cStrSpan(&errbuf)});
    }
}

/// Execution result
pub const ExecResult = struct {
    last_insert_id: ?i64 = null,
    rows_affected: u64 = 0,
};

/// Database driver type
pub const Driver = enum {
    sqlite,
    postgres,
    mysql,
};

/// Structured diagnostic for SQL errors — table and column are extracted from
/// driver error messages when available (e.g. "UNIQUE constraint failed: users.email").
pub const SqlDiagnostic = struct {
    code: i32,
    message: []const u8, // driver error message (borrowed, not owned)
    constraint: ?[]const u8 = null, // e.g. "users.email" (SQLite), "users_email_key" (PG)
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
};

/// SQLite extended result codes share their low 8 bits with the primary code
/// (`sqlite3_errcode`). The call sites here pass the *extended* code so the log
/// names the specific failure (2067 = SQLITE_CONSTRAINT_UNIQUE, 1299 = NOTNULL),
/// which means every comparison against a primary code has to mask first — the
/// unmasked `ext_code == 19` comparisons this used to be made the constraint
/// paths (diagnosis, `error.ConstraintViolation`) dead on arrival.
fn sqlitePrimaryCode(extended: i32) i32 {
    return extended & 0xff;
}

/// Parse SQLite error message to extract table/column from constraint failures.
pub fn diagnoseSqlite(err_code: i32, err_msg: []const u8) SqlDiagnostic {
    var diag = SqlDiagnostic{ .code = err_code, .message = err_msg };

    if (sqlitePrimaryCode(err_code) == 19) { // SQLITE_CONSTRAINT
        // "UNIQUE constraint failed: table.column" — the prefix lengths are
        // taken from the literals: the hand-counted 24/26 here were one short
        // (the trailing colon belongs to the prefix), so every diagnosed name
        // carried a leading ':'.
        const unique_prefix = "UNIQUE constraint failed:";
        if (std.mem.indexOf(u8, err_msg, unique_prefix)) |pos| {
            const rest = std.mem.trim(u8, err_msg[pos + unique_prefix.len ..], " \t\r\n");
            if (rest.len > 0) {
                diag.constraint = rest;
                if (std.mem.indexOf(u8, rest, ".")) |dot| {
                    diag.table = rest[0..dot];
                    diag.column = rest[dot + 1 ..];
                } else {
                    diag.table = rest;
                }
            }
        }
        // "NOT NULL constraint failed: table.column"
        const notnull_prefix = "NOT NULL constraint failed:";
        if (std.mem.indexOf(u8, err_msg, notnull_prefix)) |pos| {
            const rest = std.mem.trim(u8, err_msg[pos + notnull_prefix.len ..], " \t\r\n");
            if (rest.len > 0) {
                diag.constraint = rest;
                if (std.mem.indexOf(u8, rest, ".")) |dot| {
                    diag.table = rest[0..dot];
                    diag.column = rest[dot + 1 ..];
                } else {
                    diag.table = rest;
                }
            }
        }
    } else if (sqlitePrimaryCode(err_code) == 1) { // SQLITE_ERROR
        // "no such table: xxx"
        const missing_prefix = "no such table:";
        if (std.mem.indexOf(u8, err_msg, missing_prefix)) |pos| {
            const rest = std.mem.trim(u8, err_msg[pos + missing_prefix.len ..], " \t\r\n");
            if (rest.len > 0) {
                diag.table = rest;
            }
        }
    }
    return diag;
}

/// PG_DIAG_* field codes (from postgres_ext.h)
const PG_DIAG_SQLSTATE: c_int = 'C';
const PG_DIAG_CONSTRAINT_NAME: c_int = 'n';
const PG_DIAG_TABLE_NAME: c_int = 't';
const PG_DIAG_COLUMN_NAME: c_int = 'c';

/// Safely convert a C string pointer to a Zig slice without triggering std.mem.span(null) debug panic.
pub inline fn cStrSpan(c_ptr: [*c]const u8) []const u8 {
    if (c_ptr == null) return "";
    return std.mem.span(c_ptr);
}

/// Extract diagnostic info from a PostgreSQL PGresult after a failure.
pub fn diagnosePostgres(result: ?*const libpq_c.PGresult) SqlDiagnostic {
    var diag = SqlDiagnostic{ .code = 0, .message = "" };

    const sqlstate = if (result) |r| cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_SQLSTATE)) else "";
    if (sqlstate.len > 0) {
        diag.code = std.fmt.parseInt(i32, sqlstate, 10) catch 0;
    }

    diag.message = if (result) |r| cStrSpan(libpq_c.PQresultErrorMessage(r)) else "";

    if (result) |r| {
        const constraint = cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_CONSTRAINT_NAME));
        if (constraint.len > 0) diag.constraint = constraint;

        const table = cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_TABLE_NAME));
        if (table.len > 0) diag.table = table;

        const column = cStrSpan(libpq_c.PQresultErrorField(r, PG_DIAG_COLUMN_NAME));
        if (column.len > 0) diag.column = column;
    }

    return diag;
}

/// Parse MySQL error message to extract table/column from constraint failures.
pub fn diagnoseMysql(err_no: c_uint, err_msg: []const u8) SqlDiagnostic {
    var diag = SqlDiagnostic{ .code = @intCast(err_no), .message = err_msg };

    // "Duplicate entry 'value' for key 'table.column'"
    if (std.mem.indexOf(u8, err_msg, "Duplicate entry")) |pos| {
        const rest = err_msg[pos..];
        if (std.mem.indexOf(u8, rest, "for key '")) |key_pos| {
            const key = rest[key_pos + 9 ..];
            if (std.mem.indexOf(u8, key, "'")) |end_pos| {
                const key_name = key[0..end_pos];
                diag.constraint = key_name;
                if (std.mem.indexOf(u8, key_name, ".")) |dot| {
                    diag.table = key_name[0..dot];
                    diag.column = key_name[dot + 1 ..];
                } else {
                    diag.table = key_name;
                }
            }
        }
    }
    // "Column 'col' cannot be null"
    if (std.mem.indexOf(u8, err_msg, "Column '")) |pos| {
        const rest = err_msg[pos + 8 ..];
        if (std.mem.indexOf(u8, rest, "'")) |end_pos| {
            diag.column = rest[0..end_pos];
        }
    }
    // "Table 'db.table' doesn't exist"
    if (std.mem.indexOf(u8, err_msg, "Table '")) |pos| {
        const rest = err_msg[pos + 7 ..];
        if (std.mem.indexOf(u8, rest, "'")) |end_pos| {
            const table_name = rest[0..end_pos];
            if (std.mem.indexOf(u8, table_name, ".")) |dot| {
                diag.table = table_name[dot + 1 ..];
            } else {
                diag.table = table_name;
            }
        }
    }

    // Log diagnostic details in error paths
    if (diag.table != null or diag.column != null or diag.constraint != null) {
        std.log.err("MySQL diagnostic: errno={d} table={?s} column={?s} constraint={?s}", .{ err_no, diag.table, diag.column, diag.constraint });
    }

    return diag;
}

/// The dialects that answer "does this column exist?" from the catalogue view
/// `information_schema.columns`. SQLite has no such view — it answers from
/// `PRAGMA table_info`, which is already local to the database file.
pub const CatalogDialect = enum { postgres, mysql };

/// A column-existence probe: the statement, plus the arguments it binds.
///
/// `information_schema.columns` is **server-wide** — every schema of the
/// current database on PostgreSQL, every database on the server on MySQL — so a
/// lookup that names only `table_name` lets a same-named table somewhere else
/// answer for this one. The callers of such a lookup are startup migrations
/// deciding whether to run `ALTER TABLE … ADD COLUMN`, where a wrong "yes" skips
/// the DDL the real table needs and nothing says so until a later statement
/// names the missing column.
pub const CatalogColumnProbe = struct {
    /// The statement, with `?` placeholders in `bindArgs()` order.
    sql: []const u8,
    /// The schema (only when `table` named one), the bare table name, the
    /// column. The unused tail is `.null` and is never bound.
    args: [3]Value,
    arg_count: usize,

    pub fn bindArgs(self: *const CatalogColumnProbe) []const Value {
        return self.args[0..self.arg_count];
    }
};

const catalog_column_probe_named_schema = "SELECT 1 FROM information_schema.columns WHERE LOWER(table_schema) = LOWER(?) AND LOWER(table_name) = LOWER(?) AND LOWER(column_name) = LOWER(?)";
const catalog_column_probe_postgres = "SELECT 1 FROM information_schema.columns WHERE table_schema = current_schema() AND LOWER(table_name) = LOWER(?) AND LOWER(column_name) = LOWER(?)";
const catalog_column_probe_mysql = "SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE() AND LOWER(table_name) = LOWER(?) AND LOWER(column_name) = LOWER(?)";

/// Build the probe for `table` / `column` on `dialect`.
///
/// The schema predicate is the point. It is the schema `table` names when it is
/// qualified (`billing.orders`), otherwise the schema the connection is on —
/// `current_schema()` on PostgreSQL, `DATABASE()` on MySQL, both of which are
/// what an unqualified `ALTER TABLE` resolves against. Names are compared
/// case-insensitively: PG folds an unquoted identifier to lower case, MySQL
/// stores `table_name` as the OS created it.
pub fn catalogColumnProbe(dialect: CatalogDialect, table: []const u8, column: []const u8) CatalogColumnProbe {
    const schema: ?[]const u8 = if (std.mem.lastIndexOfScalar(u8, table, '.')) |dot| table[0..dot] else null;
    const bare = if (schema) |s| table[s.len + 1 ..] else table;

    const sql = if (schema != null) catalog_column_probe_named_schema else switch (dialect) {
        .postgres => catalog_column_probe_postgres,
        .mysql => catalog_column_probe_mysql,
    };
    const args: [3]Value = if (schema) |s|
        .{ .{ .string = s }, .{ .string = bare }, .{ .string = column } }
    else
        .{ .{ .string = bare }, .{ .string = column }, .null };

    return .{ .sql = sql, .args = args, .arg_count = if (schema != null) 3 else 2 };
}

/// SQL connection interface
pub const Conn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Monotonic creation time, tracked by the connection pool for lifetime eviction.
    created_at_ms: ?i64 = null,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) errors.Result,
        begin: *const fn (ptr: *anyopaque) errors.Result,
        commit: *const fn (ptr: *anyopaque) errors.Result,
        rollback: *const fn (ptr: *anyopaque) errors.Result,
        prepare: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt),
        /// Optional driver-native streaming cursor. Null drivers fall back to
        /// buffering all rows in `queryCursor`.
        queryCursor: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) = null,
        /// Optional driver-native batch insert. SQLite returns null to fall back
        /// to the SQL mode; MySQL and PostgreSQL implement protocol-level batching.
        batchInsert: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) = null,
    };

    pub fn query(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        var rows = try self.vtable.query(self.ptr, allocator, sql_str, args);
        for (rows.rows) |*row| row.arena = &rows.arena;
        return rows;
    }

    pub fn exec(self: Conn, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        return self.vtable.exec(self.ptr, sql_str, args);
    }

    pub fn close(self: Conn) void {
        self.vtable.close(self.ptr);
    }

    pub fn ping(self: Conn) errors.Result {
        return self.vtable.ping(self.ptr);
    }

    pub fn begin(self: Conn) errors.Result {
        return self.vtable.begin(self.ptr);
    }

    pub fn commit(self: Conn) errors.Result {
        return self.vtable.commit(self.ptr);
    }

    pub fn rollback(self: Conn) errors.Result {
        return self.vtable.rollback(self.ptr);
    }

    pub fn prepare(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        return self.vtable.prepare(self.ptr, allocator, sql_str);
    }

    pub fn queryCursor(self: Conn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        if (self.vtable.queryCursor) |qf| {
            return qf(self.ptr, allocator, sql_str, args, opts);
        }
        const rows = try self.query(allocator, sql_str, args);
        return Cursor.init(rows);
    }

    pub fn batchInsert(self: Conn, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        if (self.vtable.batchInsert) |bi| {
            return bi(self.ptr, allocator, table, columns, rows);
        }
        return error.DatabaseError;
    }
};

// ==== §2  Struct scanning ====

/// Precompute struct-field → column-index mapping once per query.
/// Eliminates O(F*C) string comparisons per row — each row scan
/// becomes O(F) direct array indexing instead of O(F*C) linear probes.
fn buildColumnIndices(allocator: std.mem.Allocator, comptime T: type, columns: []const []const u8) ![]?usize {
    const names = std.meta.fieldNames(T);
    const indices = try allocator.alloc(?usize, names.len);
    for (indices) |*idx| idx.* = null;
    for (names, 0..) |name, fi| {
        for (columns, 0..) |col, ci| {
            if (std.mem.eql(u8, col, name)) {
                indices[fi] = ci;
                break;
            }
        }
    }
    return indices;
}

/// Scan all rows into []T using a one-shot column→field index map (O(F+C) setup, O(F) per row).
/// String fields are duplicated into `allocator` (caller owns them via freeScanned).
fn scanRowsToSlice(allocator: std.mem.Allocator, comptime T: type, rows: *Rows, partial: bool) ![]T {
    for (rows.rows) |*row| row.arena = &rows.arena;

    const indices: ?[]?usize = if (rows.rows.len > 0)
        try buildColumnIndices(allocator, T, rows.rows[0].columns)
    else
        null;
    defer if (indices) |idx| allocator.free(idx);

    const result = try allocator.alloc(T, rows.rows.len);
    var scanned_count: usize = 0;
    errdefer {
        for (result[0..scanned_count]) |item| freeScanned(allocator, T, item);
        allocator.free(result);
    }
    for (rows.rows, 0..) |row, i| {
        result[i] = try scanStruct(allocator, T, row, partial, indices, false);
        scanned_count += 1;
    }
    return result;
}

/// Scan into QueryResult owning the Rows arena — string fields borrow arena memory (no second dupe).
/// On success, steals `rows.arena`; caller must NOT call `rows.deinit()`.
pub fn scanRowsToOwned(comptime T: type, rows: *Rows, partial: bool) !QueryResult(T) {
    for (rows.rows) |*row| row.arena = &rows.arena;
    const arena_alloc = rows.arena.allocator();

    const indices: ?[]?usize = if (rows.rows.len > 0)
        try buildColumnIndices(arena_alloc, T, rows.rows[0].columns)
    else
        null;

    const result = try arena_alloc.alloc(T, rows.rows.len);
    for (rows.rows, 0..) |row, i| {
        result[i] = try scanStruct(arena_alloc, T, row, partial, indices, true);
    }

    const stolen = rows.arena;
    rows.* = undefined;
    return .{ .items = result, .arena = stolen };
}

/// Scan a struct Row, optionally using precomputed column indices for O(1) field lookup.
/// When `borrow_strings` is true, []const u8 fields point into the row arena (no dupe).
fn scanStruct(allocator: std.mem.Allocator, comptime T: type, row: Row, partial: bool, indices: ?[]?usize, borrow_strings: bool) !T {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("scanStruct / queryRow* expect a struct row type whose fields mirror the SELECT list; got " ++
        @typeName(T) ++ ". Pass a struct (optionals for nullable columns, `[]const u8` for text) or scan a single column with queryScalar.");

    var result: T = undefined;
    const fn_names = info.@"struct".field_names;
    const fn_types = info.@"struct".field_types;
    const fn_attrs = info.@"struct".field_attrs;
    inline for (fn_names, fn_types, fn_attrs, 0..) |fname, ft, _, fi| {
        const FieldType = ft;
        const is_optional = @typeInfo(FieldType) == .optional;
        const BaseType = if (is_optional) @typeInfo(FieldType).optional.child else FieldType;
        const is_string = BaseType == []const u8;
        const ci: ?usize = if (indices) |idx| idx[fi] else null;

        if (is_string) {
            // The copies below are this process's memory: a failed `dupe` is
            // `error.OutOfMemory` — the name `Error.zig` documents for "dupe
            // failures while scanning rows" — while a missing column stays
            // `error.NotFound` and the driver's own failures stay
            // `error.DatabaseError`.
            // String fields: use index if available, otherwise linear scan.
            if (ci) |c| {
                const raw_val = row.values[c];
                if (raw_val == null or raw_val.? == .null) {
                    if (is_optional) {
                        @field(result, fname) = null;
                    } else if (partial) {
                        @field(result, fname) = &[_]u8{};
                    } else {
                        return error.NotFound;
                    }
                } else {
                    const str = raw_val.?.string;
                    @field(result, fname) = if (borrow_strings)
                        str
                    else
                        try allocator.dupe(u8, str);
                }
            } else {
                // Fallback: linear scan (no column index provided)
                found: {
                    for (row.columns, 0..) |col, ci2| {
                        if (std.mem.eql(u8, col, fname)) {
                            const raw_val = row.values[ci2];
                            if (raw_val == null or raw_val.? == .null) {
                                if (is_optional) {
                                    @field(result, fname) = null;
                                } else if (partial) {
                                    @field(result, fname) = &[_]u8{};
                                } else {
                                    return error.NotFound;
                                }
                            } else {
                                const str = raw_val.?.string;
                                @field(result, fname) = if (borrow_strings)
                                    str
                                else
                                    try allocator.dupe(u8, str);
                            }
                            break :found;
                        }
                    }
                    if (is_optional) {
                        @field(result, fname) = null;
                    } else if (partial) {
                        @field(result, fname) = &[_]u8{};
                    } else {
                        return error.NotFound;
                    }
                }
            }
            continue;
        }

        // Non-string fields: borrow Value as-is (parseInt uses the arena string transiently).
        const val: ?Value = if (ci) |c| blk: {
            if (row.values[c]) |v| break :blk v;
            break :blk null;
        } else val: {
            var row_mut = row;
            break :val row_mut.get(fname);
        };

        if (is_optional) {
            const ChildType = BaseType;
            if (val == null or val.? == .null) {
                @field(result, fname) = null;
            } else {
                @field(result, fname) = try valueToType(allocator, ChildType, val.?);
            }
        } else {
            if (val == null or val.? == .null) {
                if (partial) {
                    @field(result, fname) = std.mem.zeroes(FieldType);
                } else {
                    return error.NotFound;
                }
            } else {
                @field(result, fname) = try valueToType(allocator, FieldType, val.?);
            }
        }
    }
    return result;
}

fn valueToType(allocator: std.mem.Allocator, comptime T: type, val: Value) !T {
    return switch (T) {
        i64 => switch (val) {
            .int => |v| v,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        i32 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(i32, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        i16 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(i16, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        i8 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(i8, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u64 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u64, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u32 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u32, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u16 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u16, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        u8 => switch (val) {
            .int => |v| @intCast(v),
            .string => |s| std.fmt.parseInt(u8, s, 10) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        f64 => switch (val) {
            .float => |v| v,
            .int => |v| @floatFromInt(v),
            .string => |s| std.fmt.parseFloat(f64, s) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        f32 => switch (val) {
            .float => |v| @floatCast(v),
            .int => |v| @floatFromInt(v),
            .string => |s| std.fmt.parseFloat(f32, s) catch return error.DatabaseError,
            else => error.DatabaseError,
        },
        bool => switch (val) {
            .bool => |v| v,
            .int => |v| v != 0,
            .string => |s| std.mem.eql(u8, s, "t") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1"),
            else => error.DatabaseError,
        },
        // The one allocation in this function: a failed `dupe` is
        // `error.OutOfMemory`, not a value the database refused to hand over.
        []const u8 => if (val == .string) (try allocator.dupe(u8, val.string)) else error.DatabaseError,
        else => @compileError("Unsupported scan type: " ++ @typeName(T)),
    };
}

/// Compile-time: does `T` have any `[]const u8` / `?[]const u8` field?
/// Used by `queryScalar` (string-free requirement) and exposed as
/// `QueryResult(T).has_strings` for callers that want to branch on whether a
/// row owns string data.
pub fn typeHasStrings(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    inline for (info.@"struct".field_types) |ft| {
        if (ft == []const u8) return true;
        if (@typeInfo(ft) == .optional and @typeInfo(ft).optional.child == []const u8) return true;
    }
    return false;
}

pub fn freeScanned(allocator: std.mem.Allocator, comptime T: type, val: T) void {
    const info = @typeInfo(T);
    if (info != .@"struct") return;
    inline for (info.@"struct".field_names, info.@"struct".field_types) |fn2, fft2| {
        const FieldType = fft2;
        if (FieldType == []const u8) {
            allocator.free(@field(val, fn2));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(val, fn2)) |s| allocator.free(s);
        }
    }
}

/// Owned query result — prefers arena ownership (strings borrowed, single free on deinit).
/// Legacy path (arena=null) frees per-string via freeScanned.
///
/// ```zig
/// var result = try client.queryRowsOwned(User, "SELECT * FROM users", &.{});
/// defer result.deinit(allocator);
/// for (result.items) |user| { ... }
/// ```
pub fn QueryResult(comptime T: type) type {
    return struct {
        items: []T,
        /// When set, owns all string data (and the items slice). deinit frees the arena only.
        arena: ?std.heap.ArenaAllocator = null,
        /// Whether `T` contains `[]const u8` fields (compile-time; callers can
        /// skip per-row freeing when false).
        pub const has_strings = typeHasStrings(T);

        pub const TakeResult = struct { items: []T, arena: ?std.heap.ArenaAllocator };

        /// Free owned memory. Accepts `*const @This()` so callers can keep the
        /// idiomatic `const rows = try ...; defer rows.deinit(...);` pattern
        /// under Zig 0.17's stricter const checking. The cast is safe because
        /// QueryResult always owns its backing memory on the heap/stack and
        /// the caller holds the only reference at this point.
        ///
        /// Contract: call **either** `deinit` **or** per-row `freeScanned` +
        /// `allocator.free(items)` — never both. When `arena != null`, `deinit`
        /// frees the arena once; when `arena == null`, it `freeScanned`s every
        /// row then frees the items slice. Doing `freeScanned` then `deinit`
        /// is a double-free (heysen SIGABRT / SafeAllocator `len: 7` pattern).
        ///
        /// On the arena path the `allocator` argument is **ignored** — the arena
        /// was created with its own backing allocator (the connection / client's
        /// allocator) and `ArenaAllocator.deinit` uses that one internally.
        /// Passing a different allocator here is a misuse: the caller has mixed
        /// allocator identities and the SafeAllocator-backed backing allocator
        /// will reject memory freed through the wrong path. For arena-backed
        /// results prefer `deinitArena()`, which makes the intent explicit.
        pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
            const self_mut: *@This() = @constCast(self);
            if (self_mut.arena) |*a| {
                a.deinit();
                self_mut.arena = null;
                self_mut.items = &.{};
                return;
            }
            for (self.items) |item| freeScanned(allocator, T, item);
            allocator.free(self.items);
            self_mut.items = &.{};
        }

        /// Free an arena-backed QueryResult without taking an allocator.
        /// Preferred over `deinit(any_allocator)` when the result owns an arena
        /// (the common path returned by `queryRowsOwned` / `scanRowsToOwned`).
        /// The arena's backing allocator — captured at scan time — releases the
        /// arena's internal buffer, so the caller cannot influence or confuse
        /// the free path by passing a different allocator.
        ///
        /// Calling this on a slice-backed result (arena == null) is a bug:
        /// per-row strings would leak. We debug-panic to surface it loudly
        /// rather than silently leak.
        pub fn deinitArena(self: *const @This()) void {
            const self_mut: *@This() = @constCast(self);
            if (self_mut.arena) |*a| {
                a.deinit();
                self_mut.arena = null;
                self_mut.items = &.{};
                return;
            }
            @panic("deinitArena called on a slice-backed QueryResult (arena == null); " ++ "use deinit(allocator) for the slice path");
        }

        /// Transfer items + arena ownership out (e.g. into PageResult). Leaves self empty.
        pub fn take(self: *const @This()) TakeResult {
            const self_mut: *@This() = @constCast(self);
            const out: TakeResult = .{ .items = self.items, .arena = self.arena };
            self_mut.items = &.{};
            self_mut.arena = null;
            return out;
        }
    };
}

// ==== §3  SQLite driver ====

/// Bounded prepared-statement cache (per connection, LRU eviction).
const MAX_CACHED_STMTS = 64;

fn CachedStmt(comptime V: type) type {
    return struct {
        value: V,
        last_used: u64,
    };
}

fn findLruStmtKey(comptime V: type, cache: std.StringHashMap(CachedStmt(V))) ?[]const u8 {
    var it = cache.iterator();
    var lru_key: ?[]const u8 = null;
    var lru_used: u64 = std.math.maxInt(u64);
    while (it.next()) |entry| {
        if (entry.value_ptr.last_used < lru_used) {
            lru_used = entry.value_ptr.last_used;
            lru_key = entry.key_ptr.*;
        }
    }
    return lru_key;
}

pub const SQLiteConn = struct {
    db: ?*sqlite3_c.sqlite3,
    allocator: std.mem.Allocator,
    /// LRU cache of prepared statements keyed by SQL string.
    stmt_cache: std.StringHashMap(CachedStmt(*sqlite3_c.sqlite3_stmt)),
    stmt_counter: u64 = 0,
    magic: u32 = 0xDBDBDBDB,

    fn guard(self: *const @This()) void {
        if (self.magic != 0xDBDBDBDB) @panic("DB heap corruption detected (SQLite magic mismatch)");
    }

    fn poison(self: *@This()) void {
        self.magic = 0xDEADDEAD;
    }

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SQLiteConn {
        var db: ?*sqlite3_c.sqlite3 = null;
        const c_path = try allocZ(allocator, path);
        defer allocator.free(c_path);
        const rc = sqlite3_c.sqlite3_open(c_path.ptr, &db);
        if (rc != sqlite3_c.SQLITE_OK or db == null) {
            if (db) |d| {
                _ = sqlite3_c.sqlite3_errmsg(d);
                _ = sqlite3_c.sqlite3_close(d);
                return error.DatabaseError;
            }
            return error.DatabaseError;
        }
        errdefer _ = sqlite3_c.sqlite3_close(db.?);
        try applySqlitePragmas(db.?);
        return .{ .db = db, .allocator = allocator, .stmt_cache = std.StringHashMap(CachedStmt(*sqlite3_c.sqlite3_stmt)).init(allocator) };
    }

    fn applySqlitePragmas(db: *sqlite3_c.sqlite3) !void {
        const pragmas = [_][:0]const u8{
            "PRAGMA journal_mode=WAL",
            "PRAGMA busy_timeout=5000",
            "PRAGMA foreign_keys=ON",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA cache_size=-8000",
        };
        for (pragmas) |sql| {
            const rc = sqlite3_c.sqlite3_exec(db, sql.ptr, null, null, null);
            if (rc != sqlite3_c.SQLITE_OK) {
                const msg = cStrSpan(sqlite3_c.sqlite3_errmsg(db));
                std.log.warn("SQLite PRAGMA failed: sql={s} msg={s}", .{ sql, msg });
                return error.DatabaseError;
            }
        }
    }

    /// Get or prepare a cached statement. Returns reset + clear_bindings stmt ready for binding.
    fn getCachedStmt(self: *SQLiteConn, sql_str: []const u8) !*sqlite3_c.sqlite3_stmt {
        self.guard();
        if (self.stmt_cache.getPtr(sql_str)) |entry| {
            self.stmt_counter += 1;
            entry.last_used = self.stmt_counter;
            _ = sqlite3_c.sqlite3_reset(entry.value);
            _ = sqlite3_c.sqlite3_clear_bindings(entry.value);
            return entry.value;
        }
        // Evict LRU entry when at capacity.
        if (self.stmt_cache.count() >= MAX_CACHED_STMTS) {
            if (findLruStmtKey(*sqlite3_c.sqlite3_stmt, self.stmt_cache)) |lru_key| {
                if (self.stmt_cache.fetchRemove(lru_key)) |kv| {
                    _ = sqlite3_c.sqlite3_finalize(kv.value.value);
                    self.allocator.free(kv.key);
                }
            }
        }
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(self.db, @ptrCast(sql_str.ptr), @intCast(sql_str.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) {
            const err_msg = std.mem.span(sqlite3_c.sqlite3_errmsg(self.db));
            const ext_code = sqlite3_c.sqlite3_extended_errcode(self.db);
            const diag = diagnoseSqlite(ext_code, err_msg);
            if (sqlitePrimaryCode(ext_code) == 1 and std.mem.indexOf(u8, err_msg, "no such table") != null) { // SQLITE_ERROR + no such table
                std.log.err("SQLite not found: table={s}", .{diag.table orelse "?"});
                return error.NotFound;
            }
            std.log.err("SQLite prepare error: code={d} msg={s}", .{ ext_code, err_msg });
            return error.DatabaseError;
        }
        // Cache the statement under a copy of the SQL. A failed `dupe` is the
        // process running out of memory — the statement was prepared fine — so
        // it keeps `error.OutOfMemory` rather than becoming `DatabaseError`.
        const key = self.allocator.dupe(u8, sql_str) catch |err| {
            _ = sqlite3_c.sqlite3_finalize(stmt);
            return err;
        };
        self.stmt_counter += 1;
        // A failed `put` is the cache's own allocation failing. The statement and
        // the key are already this process's, so they have to go back with it —
        // otherwise the failure leaves a leaked key *and* a leaked prepared
        // statement behind, which is what the row-scan allocation sweep catches.
        self.stmt_cache.put(key, .{ .value = stmt.?, .last_used = self.stmt_counter }) catch |err| {
            self.allocator.free(key);
            _ = sqlite3_c.sqlite3_finalize(stmt);
            return err;
        };
        return stmt.?;
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        _ = allocator;
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const stmt = try self.getCachedStmt(sql_str);

        try bindSQLite(stmt, args);

        // The row buffer below is built in `arena`, so an allocation failure is
        // the process running out of memory, not the server rejecting the
        // statement — it propagates as `error.OutOfMemory` (the name `Error.zig`
        // documents this file as producing for "arena/dupe failures while
        // scanning rows") instead of being folded into `error.DatabaseError`.
        const col_count = sqlite3_c.sqlite3_column_count(stmt);
        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        // Column names are identical for every row — allocate once and share.
        const shared_columns = try arena_alloc.alloc([]const u8, @intCast(col_count));
        var names_ready = false;

        var step_rc = sqlite3_c.sqlite3_step(stmt);
        while (step_rc == sqlite3_c.SQLITE_ROW) {
            if (!names_ready) {
                for (0..@intCast(col_count)) |i| {
                    const raw_name = sqlite3_c.sqlite3_column_name(stmt, @intCast(i));
                    const name_len = std.mem.len(raw_name);
                    shared_columns[i] = try arena_alloc.dupe(u8, raw_name[0..name_len]);
                }
                names_ready = true;
            }
            const values = try arena_alloc.alloc(?Value, @intCast(col_count));
            for (0..@intCast(col_count)) |i| {
                values[i] = try readSQLiteValue(arena_alloc, stmt, @intCast(i));
            }
            try rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values });
            step_rc = sqlite3_c.sqlite3_step(stmt);
        }
        // Check if step ended with an error (not DONE)
        if (step_rc != sqlite3_c.SQLITE_DONE) {
            const err_msg = cStrSpan(sqlite3_c.sqlite3_errmsg(self.db));
            const ext_code = sqlite3_c.sqlite3_extended_errcode(self.db);
            std.log.err("SQLite query error: code={d} msg={s}", .{ ext_code, err_msg });
            return error.DatabaseError;
        }

        const rows_slice = try arena_alloc.alloc(Row, rows_list.items.len);
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const stmt = try self.getCachedStmt(sql_str);

        try bindSQLite(stmt, args);

        const step_rc = sqlite3_c.sqlite3_step(stmt);
        if (step_rc != sqlite3_c.SQLITE_DONE and step_rc != sqlite3_c.SQLITE_ROW) {
            const err_msg = std.mem.span(sqlite3_c.sqlite3_errmsg(self.db));
            const ext_code = sqlite3_c.sqlite3_extended_errcode(self.db);
            const diag = diagnoseSqlite(ext_code, err_msg);
            if (sqlitePrimaryCode(ext_code) == 19) { // SQLITE_CONSTRAINT
                std.log.err("SQLite constraint violation: table={s} column={s} msg={s}", .{ diag.table orelse "?", diag.column orelse "?", err_msg });
                return error.ConstraintViolation;
            }
            std.log.err("SQLite exec error: code={d} msg={s}", .{ ext_code, err_msg });
            return error.DatabaseError;
        }

        return ExecResult{
            .last_insert_id = sqlite3_c.sqlite3_last_insert_rowid(self.db),
            .rows_affected = @intCast(sqlite3_c.sqlite3_changes(self.db)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        // Finalize all cached statements
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            _ = sqlite3_c.sqlite3_finalize(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.deinit();
        if (self.db) |db| {
            _ = sqlite3_c.sqlite3_close(db);
            self.db = null;
        }
        self.poison();
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (self.db == null) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rc = sqlite3_c.sqlite3_exec(self.db, "BEGIN", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rc = sqlite3_c.sqlite3_exec(self.db, "COMMIT", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rc = sqlite3_c.sqlite3_exec(self.db, "ROLLBACK", null, null, null);
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        // The stub itself is this process's memory; only the prepare that
        // follows can be the database refusing the statement.
        const stmt = try allocator.create(SQLiteStmt);
        errdefer allocator.destroy(stmt);
        stmt.* = SQLiteStmt.prepare(self.db, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
    }

    fn queryCursorFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        _ = opts;
        const self = @as(*SQLiteConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const rows = try queryFn(ptr, allocator, sql_str, args);
        return Cursor.init(rows);
    }

    fn batchInsertFn(ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        _ = ptr;
        _ = allocator;
        _ = table;
        _ = columns;
        _ = rows;
        return error.DatabaseError; // Caller falls back to SQL mode.
    }

    pub fn toConn(self: *SQLiteConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
                .prepare = prepareFn,
                .queryCursor = queryCursorFn,
                .batchInsert = batchInsertFn,
            },
        };
    }
};

const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

fn bindSQLite(stmt: ?*sqlite3_c.sqlite3_stmt, args: []const Value) !void {
    for (args, 0..) |arg, i| {
        const idx: c_int = @intCast(i + 1);
        const rc = switch (arg) {
            .null => sqlite3_c.sqlite3_bind_null(stmt, idx),
            .int => |v| sqlite3_c.sqlite3_bind_int64(stmt, idx, v),
            .float => |v| sqlite3_c.sqlite3_bind_double(stmt, idx, v),
            .string => |v| sqlite3_c.sqlite3_bind_text(stmt, idx, @ptrCast(v.ptr), @intCast(v.len), @ptrCast(SQLITE_TRANSIENT)),
            .bool => |v| sqlite3_c.sqlite3_bind_int64(stmt, idx, if (v) 1 else 0),
        };
        if (rc != sqlite3_c.SQLITE_OK) return error.DatabaseError;
    }
}

/// Column types this process has already reported as undecoded, one bit per
/// `sqlite3_column_type` value (see `markUndecodedSqliteType`).
///
/// Process-global on purpose: the gap is a fact about the driver, not about one
/// row, and a scan of a BLOB column would otherwise log it once per cell.
var undecoded_sqlite_type_warn_mask: std.atomic.Value(u32) = .init(0);

/// Record that column type `t` is not decoded. Returns `true` for the call that
/// is the first to see it — the one that has to warn.
fn markUndecodedSqliteType(t: c_int) bool {
    const flag = @as(u32, 1) << @as(u5, @intCast(@as(u32, @intCast(t)) & 31));
    return (undecoded_sqlite_type_warn_mask.fetchOr(flag, .monotonic) & flag) == 0;
}

/// Decode one SQLite cell.
///
/// `null` means the column holds SQL NULL — or a type this driver does not
/// decode — and never a failed allocation. Copying a TEXT cell out of the
/// driver is this process's memory, so it leaves through the error channel as
/// `error.OutOfMemory`, the way `pgReadCell` does; reporting it as `null` gave
/// the caller a wrong value with no error at all.
///
/// The other `null` cannot leave through the error channel either: a row's
/// columns are all decoded before any of them is scanned, so erroring here would
/// fail a query that merely *lists* such a column — `SELECT *` on a table with a
/// BLOB, including for the callers that never read it. BLOB is the only SQLite
/// type this does not decode, and the other two drivers carry one as a `.string`
/// (`pgDecodeBinary`'s bytea, `mysqlStmtReadRows`' `MYSQL_TYPE_BLOB`); doing the
/// same here needs `sqlite3_column_blob` / `sqlite3_column_bytes`, which are
/// declared in `sqlite3_c.zig`, not in this file. So the value channel keeps
/// reporting `null` until that lands, and what this arm changes is that the type
/// is *said* instead of silent: the first cell of a given type logs a warning
/// once per process, which is what tells a caller's truncated-looking NULL apart
/// from a column that really is SQL NULL.
fn readSQLiteValue(allocator: std.mem.Allocator, stmt: ?*sqlite3_c.sqlite3_stmt, col: c_int) !?Value {
    const t = sqlite3_c.sqlite3_column_type(stmt, col);
    return switch (t) {
        sqlite3_c.SQLITE_INTEGER => Value{ .int = sqlite3_c.sqlite3_column_int64(stmt, col) },
        sqlite3_c.SQLITE_FLOAT => Value{ .float = sqlite3_c.sqlite3_column_double(stmt, col) },
        sqlite3_c.SQLITE_TEXT => blk: {
            const raw_text = sqlite3_c.sqlite3_column_text(stmt, col);
            const text_len = std.mem.len(raw_text);
            const text = raw_text[0..text_len];
            break :blk Value{ .string = try allocator.dupe(u8, text) };
        },
        sqlite3_c.SQLITE_NULL => null,
        else => blk: {
            if (markUndecodedSqliteType(t)) {
                std.log.warn("[sqlx] SQLite column type {d} is not decoded by this driver; its cells read as SQL NULL", .{t});
            }
            break :blk null;
        },
    };
}

// ==== §4  PostgreSQL driver ====

/// Maximum cached prepared statements per PG connection.
const PG_MAX_CACHED_STMTS = 64;

/// `resultFormat` for PQexecParams / PQexecPrepared — binary wire format.
const PG_RESULT_BINARY: c_int = 1;

/// Common PostgreSQL type OIDs (pg_type).
const PgOid = struct {
    const bool_t: libpq_c.Oid = 16;
    const bytea: libpq_c.Oid = 17;
    const char_t: libpq_c.Oid = 18;
    const name: libpq_c.Oid = 19;
    const int8: libpq_c.Oid = 20;
    const int2: libpq_c.Oid = 21;
    const int4: libpq_c.Oid = 23;
    const text: libpq_c.Oid = 25;
    const json: libpq_c.Oid = 114;
    const xml: libpq_c.Oid = 142;
    const float4: libpq_c.Oid = 700;
    const float8: libpq_c.Oid = 701;
    const bpchar: libpq_c.Oid = 1042;
    const varchar: libpq_c.Oid = 1043;
    const date: libpq_c.Oid = 1082;
    const time: libpq_c.Oid = 1083;
    const timestamp: libpq_c.Oid = 1114;
    const timestamptz: libpq_c.Oid = 1184;
    const interval: libpq_c.Oid = 1186;
    const timetz: libpq_c.Oid = 1266;
    const numeric: libpq_c.Oid = 1700;
    const uuid: libpq_c.Oid = 2950;
    const jsonb: libpq_c.Oid = 3802;
    const inet: libpq_c.Oid = 869;
    const cidr: libpq_c.Oid = 650;
};

/// Decode one PG cell. Handles text (`PQexec`) and binary (`resultFormat=1`) results.
fn pgReadCell(allocator: std.mem.Allocator, res: *libpq_c.PGresult, row: c_int, col: c_int) !?Value {
    if (libpq_c.PQgetisnull(res, row, col) == 1) return null;

    const raw = libpq_c.PQgetvalue(res, row, col);
    const len: usize = @intCast(libpq_c.PQgetlength(res, row, col));
    const bytes = raw[0..len];

    // Text format (simple query / resultFormat=0): keep as string for scanStruct parsing.
    if (libpq_c.PQfformat(res, col) == 0) {
        return .{ .string = try allocator.dupe(u8, bytes) };
    }

    return @as(?Value, try pgDecodeBinary(allocator, libpq_c.PQftype(res, col), bytes));
}

/// Decode PostgreSQL binary column bytes into a Value.
fn pgDecodeBinary(allocator: std.mem.Allocator, oid: libpq_c.Oid, bytes: []const u8) !Value {
    switch (oid) {
        PgOid.bool_t => {
            if (bytes.len < 1) return error.DatabaseError;
            return .{ .bool = bytes[0] != 0 };
        },
        PgOid.int2 => {
            if (bytes.len < 2) return error.DatabaseError;
            return .{ .int = std.mem.readInt(i16, bytes[0..2], .big) };
        },
        PgOid.int4 => {
            if (bytes.len < 4) return error.DatabaseError;
            return .{ .int = std.mem.readInt(i32, bytes[0..4], .big) };
        },
        PgOid.int8 => {
            if (bytes.len < 8) return error.DatabaseError;
            return .{ .int = std.mem.readInt(i64, bytes[0..8], .big) };
        },
        PgOid.float4 => {
            if (bytes.len < 4) return error.DatabaseError;
            const bits = std.mem.readInt(u32, bytes[0..4], .big);
            return .{ .float = @as(f32, @bitCast(bits)) };
        },
        PgOid.float8 => {
            if (bytes.len < 8) return error.DatabaseError;
            const bits = std.mem.readInt(u64, bytes[0..8], .big);
            return .{ .float = @as(f64, @bitCast(bits)) };
        },
        PgOid.numeric => {
            return pgDecodeNumeric(allocator, bytes);
        },
        PgOid.text, PgOid.varchar, PgOid.bpchar, PgOid.name, PgOid.xml, PgOid.json, PgOid.char_t, PgOid.bytea => {
            return .{ .string = try allocator.dupe(u8, bytes) };
        },
        PgOid.jsonb => {
            // jsonb binary: 1-byte version (1) + utf8 json
            if (bytes.len >= 1 and bytes[0] == 1) {
                return .{ .string = try allocator.dupe(u8, bytes[1..]) };
            }
            return .{ .string = try allocator.dupe(u8, bytes) };
        },
        PgOid.uuid => {
            if (bytes.len != 16) return error.DatabaseError;
            const s = try std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
                bytes[0],  bytes[1],  bytes[2],  bytes[3],
                bytes[4],  bytes[5],  bytes[6],  bytes[7],
                bytes[8],  bytes[9],  bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15],
            });
            return .{ .string = s };
        },
        PgOid.date => {
            // days since 2000-01-01
            if (bytes.len < 4) return error.DatabaseError;
            const days = std.mem.readInt(i32, bytes[0..4], .big);
            const s = try pgFormatDate(allocator, days);
            return .{ .string = s };
        },
        PgOid.timestamp, PgOid.timestamptz => {
            // microseconds since 2000-01-01 00:00:00
            if (bytes.len < 8) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const is_tz = oid == PgOid.timestamptz;
            const s = try pgFormatTimestamp(allocator, us, is_tz);
            return .{ .string = s };
        },
        PgOid.interval => {
            // Binary: int64 us (microseconds), int32 days, int32 months
            if (bytes.len < 16) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const days = std.mem.readInt(i32, bytes[8..12], .big);
            const months = std.mem.readInt(i32, bytes[12..16], .big);
            const s = try pgFormatInterval(allocator, months, days, us);
            return .{ .string = s };
        },
        PgOid.time => {
            // int64 microseconds since midnight
            if (bytes.len < 8) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const s = try pgFormatTime(allocator, us, 0);
            return .{ .string = s };
        },
        PgOid.timetz => {
            // int64 us + int32 tz_offset_seconds
            if (bytes.len < 12) return error.DatabaseError;
            const us = std.mem.readInt(i64, bytes[0..8], .big);
            const tz_offset = std.mem.readInt(i32, bytes[8..12], .big);
            const s = try pgFormatTime(allocator, us, tz_offset);
            return .{ .string = s };
        },
        PgOid.inet, PgOid.cidr => {
            // Binary: u8 family, u8 prefix_len, u8 is_cidr, u8 nbytes, u8 addr[nbytes]
            if (bytes.len < 4) return error.DatabaseError;
            const family = bytes[0];
            const prefix_len = bytes[1];
            const is_cidr = bytes[2] == 1;
            const nbytes = bytes[3];
            if (bytes.len < 4 + nbytes) return error.DatabaseError;
            const addr = bytes[4 .. 4 + nbytes];
            const s = try pgFormatInet(allocator, family, prefix_len, is_cidr, addr);
            return .{ .string = s };
        },
        else => {
            // Unknown binary OID: keep raw bytes as string when UTF-8, else hex.
            if (std.unicode.utf8ValidateSlice(bytes)) {
                return .{ .string = try allocator.dupe(u8, bytes) };
            }
            const hex = try allocator.alloc(u8, 2 + bytes.len * 2);
            hex[0] = '\\';
            hex[1] = 'x';
            const digits = "0123456789abcdef";
            for (bytes, 0..) |b, i| {
                hex[2 + i * 2] = digits[b >> 4];
                hex[2 + i * 2 + 1] = digits[b & 0xf];
            }
            return .{ .string = hex };
        },
    }
}

/// Decode PostgreSQL numeric binary format (OID 1700).
///
/// Binary layout: int16 ndigits, int16 weight, uint16 sign, uint16 dscale, uint16 digits[ndigits].
/// Each digit is base-10000. sign: 0x0000=positive, 0x4000=negative, 0xC000=NaN.
fn pgDecodeNumeric(allocator: std.mem.Allocator, bytes: []const u8) !Value {
    if (bytes.len < 8) return error.DatabaseError;
    const ndigits = std.mem.readInt(i16, bytes[0..2], .big);
    const weight = std.mem.readInt(i16, bytes[2..4], .big);
    const sign = std.mem.readInt(u16, bytes[4..6], .big);
    const dscale = std.mem.readInt(u16, bytes[6..8], .big);

    if (sign == 0xC000) return .{ .string = try allocator.dupe(u8, "NaN") };
    if (ndigits <= 0) return .{ .string = try allocator.dupe(u8, "0") };

    const n: usize = @intCast(ndigits);
    if (bytes.len < 8 + n * 2) return error.DatabaseError;

    const digits_before_dot: usize = if (weight >= 0) @intCast((@as(isize, @intCast(weight)) + 1) * 4) else 0;
    const is_neg = sign == 0x4000;

    // Phase 1: expand digits to flat decimal array.
    // Track first_decimal_pos: the decimal position of dec[0] (0 = 10^0, 1 = 10^-1, etc).
    var dec = std.ArrayList(u8).empty;
    try dec.ensureTotalCapacity(allocator, n * 4);
    errdefer dec.deinit(allocator);

    var first_decimal_pos: usize = 0;
    var first_group: ?usize = null;
    for (0..n) |di| {
        var d = std.mem.readInt(u16, bytes[8 + di * 2 ..][0..2], .big);
        if (d == 0 and first_group == null) {
            first_decimal_pos += 4;
            continue;
        }
        if (first_group == null) {
            first_group = di;
            if (d >= 1000) {} // 4 chars, no leading zeros
            else if (d >= 100) {
                first_decimal_pos += 1;
            } else if (d >= 10) {
                first_decimal_pos += 2;
            } else {
                first_decimal_pos += 3;
            }
        }
        if (di == first_group.?) {
            if (d >= 1000) {
                dec.appendAssumeCapacity(@intCast(d / 1000 + '0'));
                d %= 1000;
            }
            if (d >= 100 or dec.items.len > 0) {
                dec.appendAssumeCapacity(@intCast(d / 100 + '0'));
                d %= 100;
            }
            if (d >= 10 or dec.items.len > 0) {
                dec.appendAssumeCapacity(@intCast(d / 10 + '0'));
                d %= 10;
            }
            dec.appendAssumeCapacity(@intCast(d + '0'));
        } else {
            dec.appendAssumeCapacity(@intCast(d / 1000 + '0'));
            d %= 1000;
            dec.appendAssumeCapacity(@intCast(d / 100 + '0'));
            d %= 100;
            dec.appendAssumeCapacity(@intCast(d / 10 + '0'));
            d %= 10;
            dec.appendAssumeCapacity(@intCast(d + '0'));
        }
    }

    const total = dec.items.len;
    if (total == 0) {
        dec.deinit(allocator);
        return .{ .string = try allocator.dupe(u8, "0") };
    }

    // Find first non-zero within raw digits
    var fnz: usize = 0;
    while (fnz < total and dec.items[fnz] == '0') : (fnz += 1) {}
    if (fnz >= total) {
        dec.deinit(allocator);
        return .{ .string = try allocator.dupe(u8, "0") };
    }
    // Adjust: raw fnz is within dec; actual decimal position is first_decimal_pos + fnz
    const true_fnz = first_decimal_pos + fnz;
    const dscale_usz: usize = @intCast(dscale);

    // Phase 2: heap buffer (was fixed [256]u8 — overflowed on large numeric / high dscale).
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    // Upper bound: sign + int digits + '.' + dscale padding.
    const cap_hint = 1 + total + dscale_usz + 2;
    try out.ensureTotalCapacity(allocator, cap_hint);

    if (is_neg) try out.append(allocator, '-');

    if (true_fnz >= digits_before_dot) {
        // Pure fraction: "0.00...xxx"
        try out.append(allocator, '0');
        try out.append(allocator, '.');
        const lead_zeros = true_fnz - digits_before_dot;
        try out.appendNTimes(allocator, '0', lead_zeros);
        const frac_room = if (lead_zeros < dscale_usz) dscale_usz - lead_zeros else 0;
        const frac_chars = @min(total - fnz, frac_room);
        try out.appendSlice(allocator, dec.items[fnz .. fnz + frac_chars]);
        const padded = lead_zeros + frac_chars;
        if (dscale_usz > padded) try out.appendNTimes(allocator, '0', dscale_usz - padded);
    } else {
        // Integer + optional fraction
        const int_chars = digits_before_dot - true_fnz;
        const int_out = @min(int_chars, total - fnz);
        try out.appendSlice(allocator, dec.items[fnz .. fnz + int_out]);
        // PG may strip trailing zero base-10000 groups from numeric values, so
        // `ndigits` can be less than `weight + 1`. When that happens, the integer
        // part needs left-padding zeros to fill the higher base-10000 groups.
        // Example: digits=[10], weight=1 → 10 * 10000^1 = 100000 needs 4 zeros
        // padded after the "10" to produce "100000". Without this, 100000 → "10".
        if (int_out < int_chars) {
            try out.appendNTimes(allocator, '0', int_chars - int_out);
        }
        if (dscale_usz > 0) {
            try out.append(allocator, '.');
            const frac_avail = if (total > fnz + int_out) total - fnz - int_out else 0;
            const frac_out = @min(frac_avail, dscale_usz);
            try out.appendSlice(allocator, dec.items[fnz + int_out .. fnz + int_out + frac_out]);
            if (frac_out < dscale_usz) try out.appendNTimes(allocator, '0', dscale_usz - frac_out);
        }
    }

    dec.deinit(allocator);
    const owned = try out.toOwnedSlice(allocator);
    return .{ .string = owned };
}

/// Format PG date (days since 2000-01-01) as `YYYY-MM-DD`.
fn pgFormatDate(allocator: std.mem.Allocator, days_since_2000: i32) ![]u8 {
    // 2000-01-01 = Unix epoch day 10957 (days since 1970-01-01).
    const unix_days: i64 = @as(i64, days_since_2000) + 10957;
    // Civil from days (Howard Hinnant algorithm).
    const z = unix_days + 719468;
    const era: i64 = @divFloor(z, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe: u64 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    var y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy: u64 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u64 = (5 * doy + 2) / 153;
    const d: u64 = doy - (153 * mp + 2) / 5 + 1;
    const m: u64 = if (mp < 10) mp + 3 else mp - 9;
    y += if (m <= 2) @as(i64, 1) else 0;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, @intCast(y)),
        @as(u32, @intCast(m)),
        @as(u32, @intCast(d)),
    });
}

/// Format PG timestamp (µs since 2000-01-01) as ISO-8601 UTC `YYYY-MM-DDTHH:MM:SS.ffffff`.
/// When `is_tz` is true (timestamptz, OID 1184), appends `+00` suffix (PG stores timestamptz in UTC).
fn pgFormatTimestamp(allocator: std.mem.Allocator, us_since_2000: i64, is_tz: bool) ![]u8 {
    const us_per_day: i64 = 86_400_000_000;
    const days: i32 = @intCast(@divFloor(us_since_2000, us_per_day));
    var us_rem = @mod(us_since_2000, us_per_day);
    if (us_rem < 0) us_rem += us_per_day;
    const date = try pgFormatDate(allocator, days);
    defer allocator.free(date);
    const secs = @divFloor(us_rem, 1_000_000);
    const frac = @mod(us_rem, 1_000_000);
    const h = @divFloor(secs, 3600);
    const mi = @divFloor(@mod(secs, 3600), 60);
    const s = @mod(secs, 60);
    if (is_tz) {
        return std.fmt.allocPrint(allocator, "{s}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}+00", .{
            date,
            @as(u32, @intCast(h)),
            @as(u32, @intCast(mi)),
            @as(u32, @intCast(s)),
            @as(u32, @intCast(frac)),
        });
    }
    return std.fmt.allocPrint(allocator, "{s}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
        date,
        @as(u32, @intCast(h)),
        @as(u32, @intCast(mi)),
        @as(u32, @intCast(s)),
        @as(u32, @intCast(frac)),
    });
}

/// Format PG interval (int32 months, int32 days, int64 microseconds) as ISO-8601 duration.
/// When months/days > 0: `P[nY][nM][nD]T[nH][nM][nS]`; else: `HH:MM:SS.ffffff`.
fn pgFormatInterval(allocator: std.mem.Allocator, months: i32, days: i32, us_total: i64) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.ensureTotalCapacity(allocator, 256);
    errdefer buf.deinit(allocator);

    if (months != 0 or days != 0) {
        try buf.append(allocator, 'P');
        if (months != 0) {
            const s = try std.fmt.allocPrint(allocator, "{d}M", .{@abs(months)});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        }
        if (days != 0) {
            const s = try std.fmt.allocPrint(allocator, "{d}D", .{@abs(days)});
            defer allocator.free(s);
            try buf.appendSlice(allocator, s);
        }
        if (us_total != 0) {
            try buf.append(allocator, 'T');
            try pgAppendTimePart(allocator, &buf, us_total);
        }
    } else {
        try pgAppendTimePart(allocator, &buf, us_total);
    }
    return buf.toOwnedSlice(allocator);
}

/// Append time part (HH:MM:SS.ffffff or -HH:MM:SS.ffffff) to an ArrayList.
fn pgAppendTimePart(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), us_total: i64) !void {
    var us = @abs(us_total);
    if (us_total < 0) try buf.append(allocator, '-');

    const h = @divFloor(@as(i64, @intCast(us)), 3_600_000_000);
    us -= @as(u64, @intCast(h)) * 3_600_000_000;
    const mi = @divFloor(@as(i64, @intCast(us)), 60_000_000);
    us -= @as(u64, @intCast(mi)) * 60_000_000;
    const s = @divFloor(@as(i64, @intCast(us)), 1_000_000);
    const frac = us - @as(u64, @intCast(s)) * 1_000_000;
    const time_str = try std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{
        @as(u32, @intCast(@abs(h))),
        @as(u32, @intCast(@abs(mi))),
        @as(u32, @intCast(@abs(s))),
        @as(u32, @intCast(frac)),
    });
    defer allocator.free(time_str);
    try buf.appendSlice(allocator, time_str);
}

/// Format PG time (µs since midnight) as `HH:MM:SS.ffffff` or `HH:MM:SS.ffffff±HH:MM`.
fn pgFormatTime(allocator: std.mem.Allocator, us_since_midnight: i64, tz_offset_secs: i32) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.ensureTotalCapacity(allocator, 64);
    errdefer buf.deinit(allocator);
    try pgAppendTimePart(allocator, &buf, us_since_midnight);
    if (tz_offset_secs != 0) {
        const abs_offset = @abs(tz_offset_secs);
        const tz_h = @divFloor(abs_offset, 3600);
        const tz_m = @divFloor(@mod(abs_offset, 3600), 60);
        const sign: u8 = if (tz_offset_secs >= 0) '+' else '-';
        const tz_str = try std.fmt.allocPrint(allocator, "{c}{d:0>2}:{d:0>2}", .{ sign, tz_h, tz_m });
        defer allocator.free(tz_str);
        try buf.appendSlice(allocator, tz_str);
    }
    return buf.toOwnedSlice(allocator);
}

/// Format PG inet/cidr binary as text representation.
fn pgFormatInet(allocator: std.mem.Allocator, family: u8, prefix_len: u8, is_cidr: bool, addr: []const u8) ![]u8 {
    if (family == 2) {
        // AF_INET: 4 bytes
        if (addr.len != 4) return error.DatabaseError;
        // Mask network bits for CIDR
        var masked = [_]u8{ 0, 0, 0, 0 };
        @memcpy(&masked, addr);
        if (is_cidr and prefix_len < 32) {
            if (prefix_len == 0) {
                @memset(&masked, 0);
            } else {
                const mask: u32 = @truncate(@as(u64, 0xFFFFFFFF) << @intCast(32 - prefix_len));
                const host_bits = std.mem.readInt(u32, &masked, .big);
                std.mem.writeInt(u32, &masked, host_bits & mask, .big);
            }
        }
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}/{d}", .{
            masked[0], masked[1], masked[2], masked[3], prefix_len,
        });
    } else if (family == 3) {
        // AF_INET6: 16 bytes
        if (addr.len != 16) return error.DatabaseError;
        var masked: [16]u8 = undefined;
        @memcpy(&masked, addr);
        if (is_cidr and prefix_len < 128) {
            const byte_idx: usize = @intCast(prefix_len / 8);
            const bit_in_byte: u8 = prefix_len % 8;
            // Zero bytes at and after byte_idx, then restore partial byte prefix
            for (byte_idx..16) |i| masked[i] = 0;
            if (bit_in_byte > 0 and byte_idx < 16) {
                // mask: keep top bit_in_byte bits, zero lower (8 - bit_in_byte) bits
                const shift = @as(u3, @intCast(8 - bit_in_byte));
                const m: u8 = @truncate(@as(u16, 0xFF) << shift);
                masked[byte_idx] &= m;
            }
        }
        return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}/{d}", .{
            masked[0],  masked[1],  masked[2],  masked[3],
            masked[4],  masked[5],  masked[6],  masked[7],
            masked[8],  masked[9],  masked[10], masked[11],
            masked[12], masked[13], masked[14], masked[15],
            prefix_len,
        });
    }
    return error.DatabaseError;
}

/// Escape a single value for PostgreSQL `COPY ... FROM STDIN WITH (FORMAT csv)`.
fn appendCsvCell(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len == 0) {
        return try buf.appendSlice(allocator, "\"\"");
    }
    var needs_quote = false;
    for (value) |ch| {
        if (ch == ',' or ch == '"' or ch == '\n' or ch == '\r') {
            needs_quote = true;
            break;
        }
    }
    if (!needs_quote) {
        return try buf.appendSlice(allocator, value);
    }
    try buf.append(allocator, '"');
    for (value) |ch| {
        if (ch == '"') try buf.append(allocator, '"');
        try buf.append(allocator, ch);
    }
    try buf.append(allocator, '"');
}

pub const PostgresConn = struct {
    conn: ?*libpq_c.PGconn,
    allocator: std.mem.Allocator,
    /// Socket read timeout (ms); 0 = disabled. Applied via SO_RCVTIMEO so
    /// synchronous PQexec*/PQgetResult reads cannot hang forever. NOTE: this
    /// is a per-read idle timeout (kernel), not a whole-query deadline — a
    /// slow-but-progressing query is not cut off.
    query_timeout_ms: u32 = 0,
    /// LRU-style prepared statement cache: SQL text → null-terminated statement name.
    /// Values MUST stay `[:0]u8` (from `allocZ`): coercing to `[]const u8` then `free`
    /// drops the sentinel and panics SafeAllocator with alloc=N+1 / free=N.
    stmt_cache: std.StringHashMap(CachedStmt([:0]u8)),
    stmt_counter: u64 = 0,
    magic: u32 = 0xDBDBDBDB,

    fn guard(self: *const @This()) void {
        if (self.magic != 0xDBDBDBDB) @panic("DB heap corruption detected (PG magic mismatch)");
    }

    fn poison(self: *@This()) void {
        self.magic = 0xDEADDEAD;
    }

    /// Connect using explicit parameters via dlsym (bypasses Zig C ABI issues)
    pub fn connectParams(allocator: std.mem.Allocator, host: []const u8, port: u16, user: []const u8, pass: []const u8, db: []const u8, query_timeout_ms: u32) !PostgresConn {
        // Use PQconnectdb with conninfo string so we can set sslmode
        const sslmode = if (std.c.getenv("PGSSLMODE")) |v| std.mem.span(v) else "require";
        const conninfo = try std.fmt.allocPrint(allocator, "host={s} port={d} dbname={s} user={s} password={s} sslmode={s} connect_timeout=10", .{ host, port, db, user, pass, sslmode });
        defer allocator.free(conninfo);
        return connect(allocator, conninfo, query_timeout_ms);
    }

    /// Null-terminated string connect
    pub fn connect(allocator: std.mem.Allocator, conninfo: []const u8, query_timeout_ms: u32) !PostgresConn {
        const null_terminated = try allocZ(allocator, conninfo);
        defer allocator.free(null_terminated);
        const conn = libpq_c.PQconnectdb(null_terminated);
        if (conn == null) return error.DatabaseError;
        const status = libpq_c.PQstatus(conn);
        if (status != .CONNECTION_OK) {
            const err_msg = libpq_c.PQerrorMessage(conn);
            std.log.err("PG connect failed (status={s}): {s}", .{ @tagName(status), std.mem.span(err_msg) });
            libpq_c.PQfinish(conn);
            return error.DatabaseError;
        }
        applySocketTimeout(conn.?, query_timeout_ms);
        return .{ .conn = conn, .allocator = allocator, .query_timeout_ms = query_timeout_ms, .stmt_cache = std.StringHashMap(CachedStmt([:0]u8)).init(allocator) };
    }

    /// Apply SO_RCVTIMEO to the libpq socket so synchronous PQexec* reads
    /// cannot block a worker thread forever (Threaded Io M:N fibers). A
    /// timed-out read leaves the connection in an indeterminate state — the
    /// pool's ping / single-conn reconnect paths recover it on next use.
    fn applySocketTimeout(conn: *libpq_c.PGconn, timeout_ms: u32) void {
        if (timeout_ms == 0) return;
        const fd = libpq_c.PQsocket(conn);
        if (fd < 0) return;
        var tv = std.posix.timeval{
            .sec = @intCast(@divTrunc(@as(i64, @intCast(timeout_ms)), 1000)),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(@intCast(fd), std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |err| {
            std.log.warn("[sqlx] PG SO_RCVTIMEO apply failed: {s}", .{@errorName(err)});
        };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        // Only a driver that declines to hand back a result is `null` here —
        // this process's allocation failures inside `execPrepared` (and the two
        // helpers under it) come back as `error.OutOfMemory` through the error
        // channel and are not relabelled as the server's doing.
        const res = try execPrepared(self, sql_str, args);
        if (res == null) {
            std.log.err("PG queryFn: execPrepared returned null sql={s}", .{sql_str});
            return error.DatabaseError;
        }
        defer libpq_c.PQclear(res.?);

        const status = libpq_c.PQresultStatus(res.?);
        if (status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) {
            const err_msg = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.err("PG queryFn: status={d} sql={s} err={s}", .{ @backingInt(status), sql_str, err_msg });
            if (status == libpq_c.ExecStatusType.PGRES_FATAL_ERROR) {
                const db_err = pgResultToError(res.?);
                if (db_err == error.ConstraintViolation) logPgConstraintViolation(res.?);
                return db_err;
            }
            return error.DatabaseError;
        }

        const n_rows = libpq_c.PQntuples(res.?);
        const n_cols = libpq_c.PQnfields(res.?);

        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        // The row buffer is built in the caller's arena, so an allocation
        // failure here is the process running out of memory — `error.OutOfMemory`,
        // the name `Error.zig` documents for "arena/dupe failures while scanning
        // rows" — while a failure of the driver to hand over a field or a cell
        // stays `error.DatabaseError` (it comes from `pgReadCell`).
        const shared_columns = try arena_alloc.alloc([]const u8, @intCast(n_cols));
        for (0..@intCast(n_cols)) |c| {
            const name = cStrSpan(libpq_c.PQfname(res.?, @intCast(c)));
            shared_columns[c] = try arena_alloc.dupe(u8, name);
        }

        for (0..@intCast(n_rows)) |r| {
            const values = try arena_alloc.alloc(?Value, @intCast(n_cols));
            for (0..@intCast(n_cols)) |c| {
                values[c] = try pgReadCell(arena_alloc, res.?, @intCast(r), @intCast(c));
            }
            try rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values });
        }

        const rows_slice = try arena_alloc.alloc(Row, rows_list.items.len);
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = try execPrepared(self, sql_str, args);
        if (res == null) {
            std.log.err("PG execFn: execPrepared returned null sql={s}", .{sql_str});
            return error.DatabaseError;
        }
        defer libpq_c.PQclear(res.?);

        const status = libpq_c.PQresultStatus(res.?);
        if (status != libpq_c.ExecStatusType.PGRES_COMMAND_OK and status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) {
            const err_msg = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.err("PG execFn: status={d} sql={s} err={s}", .{ @backingInt(status), sql_str, err_msg });
            if (status == libpq_c.ExecStatusType.PGRES_FATAL_ERROR) {
                const db_err = pgResultToError(res.?);
                if (db_err == error.ConstraintViolation) logPgConstraintViolation(res.?);
                return db_err;
            }
            return error.DatabaseError;
        }

        const cmd = std.mem.span(libpq_c.PQcmdTuples(res));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    /// Execute with prepared statement caching. First call prepares and caches;
    /// subsequent calls reuse via PQexecPrepared (server-side).
    /// Falls back to `execParamsDirect` on prepare failure or zero-arg queries.
    ///
    /// `null` in the result is the driver declining to hand back a `PGresult`
    /// (each caller logs which statement); this process's own allocation
    /// failures leave through the error channel as `error.OutOfMemory`, so the
    /// two no longer share one answer.
    fn execPrepared(self: *PostgresConn, sql_str: []const u8, args: []const Value) errors.ResultT(?*libpq_c.PGresult) {
        // No bind params → PQexec is enough (and avoids polluting the stmt cache).
        if (args.len == 0) {
            return execParamsDirect(self, sql_str, args);
        }

        // Cache key = original Zig SQL (`?` placeholders). Hit → PQexecPrepared.
        if (self.stmt_cache.getPtr(sql_str)) |entry| {
            self.stmt_counter += 1;
            entry.last_used = self.stmt_counter;
            if (try self.execPreparedStmt(entry.value, args)) |res| return res;
            // Cached name may be stale after reconnect; drop and re-prepare below.
            if (self.stmt_cache.fetchRemove(sql_str)) |kv| {
                self.allocator.free(kv.key);
                self.allocator.free(kv.value.value);
            }
        }

        // `null` = the SQL carries no `?` to rewrite, so the cache key and the
        // statement are the SQL as written.
        const pg_sql = (try convertPlaceholders(self.allocator, sql_str)) orelse return execParamsDirect(self, sql_str, args);
        defer self.allocator.free(pg_sql);

        // Evict LRU entry when at capacity.
        if (self.stmt_cache.count() >= PG_MAX_CACHED_STMTS) {
            if (findLruStmtKey([:0]u8, self.stmt_cache)) |lru_key| {
                if (self.stmt_cache.fetchRemove(lru_key)) |kv| {
                    var dealloc_buf: [80]u8 = undefined;
                    if (bufPrintZ(&dealloc_buf, "DEALLOCATE {s}", .{kv.value.value})) |dealloc_sql| {
                        if (self.conn) |c| {
                            if (libpq_c.PQexec(c, @ptrCast(dealloc_sql.ptr))) |dr| libpq_c.PQclear(dr);
                        }
                    } else |_| {}
                    self.allocator.free(kv.key);
                    self.allocator.free(kv.value.value);
                }
            }
        }

        self.stmt_counter += 1;
        var stmt_buf: [32]u8 = undefined;
        const stmt_name_z = bufPrintZ(&stmt_buf, "zs_{d}", .{self.stmt_counter}) catch {
            return execParamsDirect(self, sql_str, args);
        };

        const prep_res = libpq_c.PQprepare(self.conn, @ptrCast(stmt_name_z.ptr), @ptrCast(pg_sql.ptr), @intCast(args.len), null);
        if (prep_res == null) return execParamsDirect(self, sql_str, args);
        defer libpq_c.PQclear(prep_res.?);
        if (libpq_c.PQresultStatus(prep_res.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
            const err = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.warn("PG PQprepare failed, falling back to PQexecParams: {s}", .{err});
            return execParamsDirect(self, sql_str, args);
        }

        // The statement is prepared, so the only failures left are this
        // process's own allocations — the two cache copies and whatever the run
        // needs. They surface as `error.OutOfMemory`; retrying through the
        // uncached path on a failed allocation is what used to turn an
        // out-of-memory into the server's `error.DatabaseError`. Once `put`
        // returns, the cache owns both strings and nothing here frees them.
        const sql_dup = try self.allocator.dupe(u8, sql_str);
        const stmt_name_dup = allocZ(self.allocator, stmt_name_z) catch |err| {
            self.allocator.free(sql_dup);
            return err;
        };
        self.stmt_counter += 1;
        self.stmt_cache.put(sql_dup, .{ .value = stmt_name_dup, .last_used = self.stmt_counter }) catch |err| {
            self.allocator.free(sql_dup);
            self.allocator.free(stmt_name_dup);
            return err;
        };

        return self.execPreparedStmt(stmt_name_dup, args);
    }

    /// Direct PQexecParams (no prepared statement cache).
    /// Direct PQexecParams (no prepared statement cache).
    ///
    /// `null` is the driver handing back nothing — `PQexec` / `PQexecParams`
    /// returned null, or the status was neither `TUPLES_OK` nor `COMMAND_OK` —
    /// while every allocation failure below is `error.OutOfMemory`.
    fn execParamsDirect(self: *PostgresConn, sql_str: []const u8, args: []const Value) errors.ResultT(?*libpq_c.PGresult) {
        // Use PQexec (simple query, no params) for queries without args
        // Must null-terminate the SQL string for libpq
        if (args.len == 0) {
            const pg_sql_simple = try allocZ(self.allocator, sql_str);
            defer self.allocator.free(pg_sql_simple);
            const res = libpq_c.PQexec(self.conn, @ptrCast(pg_sql_simple.ptr));
            if (res == null) {
                std.log.err("PG PQexec returned null", .{});
                return null;
            }
            const status = libpq_c.PQresultStatus(res.?);
            if (status != libpq_c.ExecStatusType.PGRES_TUPLES_OK and status != libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
                const err = std.mem.span(libpq_c.PQerrorMessage(self.conn));
                std.log.err("PG PQexec failed: sql={s} err={s}", .{ sql_str, err });
                libpq_c.PQclear(res.?);
                return null;
            }
            return res.?;
        }

        // Convert ? → $1,$2,...; `null` is "no `?` to convert", not a failure —
        // the SQL goes to the driver exactly as the caller wrote it.
        const pg_sql_conv = try convertPlaceholders(self.allocator, sql_str);
        const pg_sql = pg_sql_conv orelse (try allocZ(self.allocator, sql_str));
        defer self.allocator.free(pg_sql);

        const param_count = args.len;
        // Each `defer` is registered next to its own allocation, so a failure
        // here — this process's memory, and `error.OutOfMemory` — frees the
        // half-built parameter arrays on the way out.
        const paramValues = try self.allocator.alloc(?[*]const u8, param_count);
        defer self.allocator.free(paramValues);
        const paramLengths = try self.allocator.alloc(c_int, param_count);
        defer self.allocator.free(paramLengths);
        const paramAllocs = try self.allocator.alloc(?[:0]const u8, param_count);
        defer {
            for (paramAllocs) |maybe_alloc| {
                if (maybe_alloc) |a| self.allocator.free(a);
            }
            self.allocator.free(paramAllocs);
        }
        @memset(paramAllocs, null);

        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => blk: {
                    paramLengths[i] = 0;
                    break :blk null;
                },
                .int => |v| blk: {
                    const s = try allocPrintZ(self.allocator, "{d}", .{v});
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = try allocPrintZ(self.allocator, "{d}", .{v});
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| blk: {
                    const s = try allocZ(self.allocator, v);
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .bool => |v| blk: {
                    paramLengths[i] = 1;
                    break :blk if (v) @ptrCast("t") else @ptrCast("f");
                },
            };
        }

        const res = libpq_c.PQexecParams(self.conn, @ptrCast(pg_sql.ptr), @intCast(param_count), null, @ptrCast(paramValues.ptr), @ptrCast(paramLengths.ptr), null, PG_RESULT_BINARY);
        if (res == null) {
            const err = std.mem.span(libpq_c.PQerrorMessage(self.conn));
            std.log.err("PG PQexecParams returned null: err={s}", .{err});
        }
        return res;
    }

    /// Execute already-prepared statement.
    /// Param strings live in a local arena until `PQexecPrepared` returns (heysen §1.1/§1.2).
    /// `stmt_name` must be null-terminated (`[:0]const u8` or a `bufPrintZ` stack name).
    ///
    /// `null` is `PQexecPrepared` handing back no result; a failure of the arena
    /// below is this process's memory and leaves as `error.OutOfMemory` instead
    /// of sharing that answer.
    fn execPreparedStmt(self: *PostgresConn, stmt_name: [:0]const u8, args: []const Value) errors.ResultT(?*libpq_c.PGresult) {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const paramValues = try aa.alloc(?[*:0]const u8, args.len);
        const paramLengths = try aa.alloc(c_int, args.len);

        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => blk: {
                    paramLengths[i] = 0;
                    break :blk null;
                },
                .int => |v| blk: {
                    const s = try allocPrintZ(aa, "{d}", .{v});
                    paramLengths[i] = @intCast(s.len);
                    break :blk s.ptr;
                },
                .float => |v| blk: {
                    const s = try allocPrintZ(aa, "{d}", .{v});
                    paramLengths[i] = @intCast(s.len);
                    break :blk s.ptr;
                },
                .string => |v| blk: {
                    const s = try allocZ(aa, v);
                    paramLengths[i] = @intCast(s.len);
                    break :blk s.ptr;
                },
                .bool => |v| blk: {
                    paramLengths[i] = 1;
                    break :blk if (v) @as(?[*:0]const u8, @ptrCast("t")) else @ptrCast("f");
                },
            };
        }

        // Cached names are allocZ'd; stack names from bufPrintZ are also sentinel-terminated.
        return libpq_c.PQexecPrepared(
            self.conn,
            @ptrCast(stmt_name.ptr),
            @intCast(args.len),
            @ptrCast(paramValues.ptr),
            @ptrCast(paramLengths.ptr),
            null,
            PG_RESULT_BINARY,
        );
    }

    /// Bytes consumed when `sql[i]` opens a string literal (`'...'` with `''`
    /// escapes), quoted identifier (`"..."`), `--` line comment, or `/* ... */`
    /// block comment; 0 when `sql[i]` is plain SQL text.
    fn skipQuotedOrComment(sql: []const u8, i: usize) usize {
        const c = sql[i];
        if (c == '\'') {
            var j = i + 1;
            while (j < sql.len) {
                if (sql[j] == '\'') {
                    j += 1;
                    if (j < sql.len and sql[j] == '\'') {
                        j += 1; // escaped ''
                        continue;
                    }
                    return j - i;
                }
                j += 1;
            }
            return sql.len - i; // unterminated — consume the rest
        }
        if (c == '"') {
            var j = i + 1;
            while (j < sql.len and sql[j] != '"') : (j += 1) {}
            return if (j < sql.len) j + 1 - i else sql.len - i;
        }
        if (c == '-' and i + 1 < sql.len and sql[i + 1] == '-') {
            var j = i;
            while (j < sql.len and sql[j] != '\n') : (j += 1) {}
            return j - i;
        }
        if (c == '/' and i + 1 < sql.len and sql[i + 1] == '*') {
            var j = i + 2;
            while (j + 1 < sql.len and !(sql[j] == '*' and sql[j + 1] == '/')) : (j += 1) {}
            return if (j + 1 < sql.len) j + 2 - i else sql.len - i;
        }
        return 0;
    }

    /// Number of digits following a `?` placeholder at `sql[i]` (sqlite-style
    /// `?N` numbering). The digits must be consumed so `?1` becomes `$1`, not
    /// `$11`.
    fn placeholderDigits(sql: []const u8, i: usize) usize {
        var j = i + 1;
        while (j < sql.len and std.ascii.isDigit(sql[j])) : (j += 1) {}
        return j - i - 1;
    }

    /// Enough for `$` plus the 20 decimal digits of a 64-bit `usize`.
    const dollar_buf_len = 21;

    /// Write `$N` for a placeholder number into `buf` and return the slice. It
    /// is total by construction — a `usize` never needs the 21st byte — so the
    /// only failure left in `convertPlaceholders` is its allocator, which is
    /// what separates "could not allocate" from "nothing to rewrite".
    fn dollarPlaceholder(buf: *[dollar_buf_len]u8, n: usize) []const u8 {
        var digits: [20]u8 = undefined;
        var first: usize = digits.len;
        var v = n;
        while (true) {
            first -= 1;
            digits[first] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
            if (v == 0) break;
        }
        const len = digits.len - first;
        buf[0] = '$';
        @memcpy(buf[1 .. 1 + len], digits[first..]);
        return buf[0 .. 1 + len];
    }

    /// Converts sqlite-style `?` / `?N` placeholders to PostgreSQL `$N`.
    ///
    /// Every placeholder is numbered sequentially in order of appearance and
    /// trailing digits are consumed, so `?`, `?2`, `?` become `$1`, `$2`, `$3`.
    /// Quoted strings, quoted identifiers, `--` comments and `/* */` comments
    /// are skipped so `?` inside literals is never rewritten.
    ///
    /// `null` means there was nothing to rewrite — the callers send the SQL as
    /// it stands — and the buffer's allocation is the only thing that can fail,
    /// as `error.OutOfMemory` rather than that same `null`.
    fn convertPlaceholders(allocator: std.mem.Allocator, sql: []const u8) errors.ResultT(?[:0]u8) {
        // Pass 1: count placeholders and compute the exact output size.
        var count: usize = 0;
        var removed: usize = 0;
        var added: usize = 0;
        var i: usize = 0;
        while (i < sql.len) {
            const skipped = skipQuotedOrComment(sql, i);
            if (skipped > 0) {
                i += skipped;
                continue;
            }
            if (sql[i] == '?') {
                count += 1;
                const digits = placeholderDigits(sql, i);
                removed += 1 + digits;
                var tmp: [dollar_buf_len]u8 = undefined;
                added += dollarPlaceholder(&tmp, count).len;
                i += 1 + digits;
            } else {
                i += 1;
            }
        }
        if (count == 0) return null;

        // Pass 2: emit `$N`, consuming `?N` digits verbatim-skipped elsewhere.
        const buf = try allocator.allocSentinel(u8, sql.len - removed + added, 0);
        var pos: usize = 0;
        var n: usize = 0;
        i = 0;
        while (i < sql.len) {
            const skipped = skipQuotedOrComment(sql, i);
            if (skipped > 0) {
                @memcpy(buf[pos .. pos + skipped], sql[i .. i + skipped]);
                pos += skipped;
                i += skipped;
                continue;
            }
            if (sql[i] == '?') {
                n += 1;
                var tmp: [dollar_buf_len]u8 = undefined;
                const s = dollarPlaceholder(&tmp, n);
                @memcpy(buf[pos .. pos + s.len], s);
                pos += s.len;
                i += 1 + placeholderDigits(sql, i);
            } else {
                buf[pos] = sql[i];
                pos += 1;
                i += 1;
            }
        }
        return buf[0..pos :0];
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        // Deallocate all cached prepared statements
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            var dealloc_buf: [64]u8 = undefined;
            const sql = bufPrintZ(&dealloc_buf, "DEALLOCATE {s}", .{entry.value_ptr.value}) catch "";
            if (self.conn != null) _ = libpq_c.PQexec(self.conn, @ptrCast(sql.ptr));
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }
        self.stmt_cache.deinit();
        if (self.conn) |conn| {
            libpq_c.PQfinish(conn);
            self.conn = null;
        }
        self.poison();
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (self.conn == null or libpq_c.PQstatus(self.conn) != libpq_c.ConnStatusType.CONNECTION_OK) return error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = libpq_c.PQexec(self.conn, "BEGIN");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = libpq_c.PQexec(self.conn, "COMMIT");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        const res = libpq_c.PQexec(self.conn, "ROLLBACK");
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        // Two kinds of failure, two names: the cell and the statement name are
        // this process's memory (`error.OutOfMemory`), while a statement the
        // server refused is `error.DatabaseError`. `PostgresStmt.prepare`'s
        // inferred set also carries `error.NoSpaceLeft` from its own 32-byte
        // name buffer — unreachable for `"stmt_{x}"` of a pointer, and not a
        // member of `ZigModuError`, so it lands on the database arm.
        const stmt = try allocator.create(PostgresStmt);
        errdefer allocator.destroy(stmt);
        stmt.* = PostgresStmt.prepare(self.conn, allocator, sql_str) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.DatabaseError,
        };
        return stmt.toStmt();
    }

    fn queryCursorFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (opts.mode == .buffered) {
            const rows = try queryFn(ptr, allocator, sql_str, args);
            return Cursor.init(rows);
        }

        // Convert ? → $1,$2,... then null-terminate for libpq.
        // Keep branches separate: `if (a) []u8 else [:0]u8` coerces to []u8 and
        // `free` then drops the sentinel (alloc=N+1 / free=N SafeAllocator panic).
        // Every buffer below is this process's memory, so a failure to get one —
        // the rewrite included — is `error.OutOfMemory`, while
        // `PQsendQueryParams` returning 0 stays `error.DatabaseError` (that is
        // the driver path). `null` from `convertPlaceholders` is not a failure:
        // it means the SQL has no `?` to rewrite and goes out as written.
        const sql_z: [:0]u8 = blk: {
            if (args.len == 0) {
                break :blk try allocZ(allocator, sql_str);
            }
            const maybe_pg_sql = try convertPlaceholders(self.allocator, sql_str);
            defer {
                if (maybe_pg_sql) |pg_sql| self.allocator.free(pg_sql);
            }
            break :blk try allocZ(allocator, maybe_pg_sql orelse sql_str);
        };
        defer allocator.free(sql_z);

        // Build text parameter arrays. Owned by `allocator` and freed before return.
        const paramValues = try allocator.alloc(?[*]const u8, args.len);
        defer allocator.free(paramValues);
        const paramLengths = try allocator.alloc(c_int, args.len);
        defer allocator.free(paramLengths);
        const paramAllocs = try allocator.alloc(?[]u8, args.len);
        defer {
            for (paramAllocs) |maybe| {
                if (maybe) |a| allocator.free(a);
            }
            allocator.free(paramAllocs);
        }
        @memset(paramAllocs, null);

        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => blk: {
                    paramLengths[i] = 0;
                    break :blk null;
                },
                .int => |v| blk: {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .float => |v| blk: {
                    const s = try std.fmt.allocPrint(allocator, "{d}", .{v});
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .string => |v| blk: {
                    const s = try allocator.dupe(u8, v);
                    paramAllocs[i] = s;
                    paramLengths[i] = @intCast(s.len);
                    break :blk @ptrCast(s.ptr);
                },
                .bool => |v| blk: {
                    paramLengths[i] = 1;
                    break :blk if (v) @ptrCast("t") else @ptrCast("f");
                },
            };
        }

        if (libpq_c.PQsendQueryParams(self.conn, @ptrCast(sql_z.ptr), @intCast(args.len), null, @ptrCast(paramValues.ptr), @ptrCast(paramLengths.ptr), null, 0) == 0) {
            return error.DatabaseError;
        }
        _ = libpq_c.PQsetSingleRowMode(self.conn);
        _ = libpq_c.PQconsumeInput(self.conn);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        // The column names must survive `PgCursor.next`, which resets `arena` on
        // every row — a second arena is what gives them the result set's
        // lifetime instead of a row's.
        var columns_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer columns_arena.deinit();
        var first = libpq_c.PQgetResult(self.conn);
        var columns: [][]u8 = &[_][]u8{};
        var eof = false;
        if (first) |r| {
            const status = libpq_c.PQresultStatus(r);
            if (status == libpq_c.ExecStatusType.PGRES_COMMAND_OK) {
                libpq_c.PQclear(r);
                first = null;
                eof = true;
            } else if (status == libpq_c.ExecStatusType.PGRES_TUPLES_OK or status == libpq_c.ExecStatusType.PGRES_SINGLE_TUPLE) {
                const n_cols = libpq_c.PQnfields(r);
                if (n_cols > 0) {
                    columns = try columns_arena.allocator().alloc([]u8, @intCast(n_cols));
                    for (0..@intCast(n_cols)) |c| {
                        const name = std.mem.span(libpq_c.PQfname(r, @intCast(c)));
                        columns[c] = try columns_arena.allocator().dupe(u8, name);
                    }
                }
            } else {
                libpq_c.PQclear(r);
                return error.DatabaseError;
            }
        } else {
            eof = true;
        }

        return Cursor{ .state = .{ .streaming_pg = .{
            .conn = self.conn,
            .arena = arena,
            .columns_arena = columns_arena,
            .columns = columns,
            .row = undefined,
            .current = first,
            .eof = eof,
        } } };
    }

    /// Batch insert using PostgreSQL `COPY ... FROM STDIN WITH (FORMAT csv)`.
    fn copyFrom(self: *PostgresConn, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        validateIdentifier(table) catch return error.DatabaseError;
        if (rows.len == 0) return ExecResult{};
        if (columns.len == 0) return error.DatabaseError;
        for (columns) |c| validateIdentifier(c) catch return error.DatabaseError;

        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);
        try sql.appendSlice(self.allocator, "COPY ");
        try sql.appendSlice(self.allocator, table);
        try sql.appendSlice(self.allocator, " (");
        for (columns, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, col);
        }
        try sql.appendSlice(self.allocator, ") FROM STDIN WITH (FORMAT csv)");

        const sql_z = try allocZ(self.allocator, sql.items);
        defer self.allocator.free(sql_z);

        const begin = libpq_c.PQexec(self.conn, "BEGIN");
        defer if (begin) |b| libpq_c.PQclear(b);
        if (begin == null or libpq_c.PQresultStatus(begin.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;

        const res = libpq_c.PQexec(self.conn, @ptrCast(sql_z.ptr));
        defer if (res) |r| libpq_c.PQclear(r);
        if (res == null or libpq_c.PQresultStatus(res.?) != libpq_c.ExecStatusType.PGRES_COPY_IN) return error.DatabaseError;

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        for (rows) |row| {
            if (row.len != columns.len) return error.DatabaseError;
            buf.items.len = 0;
            for (row, 0..) |val, c| {
                if (c > 0) try buf.append(self.allocator, ',');
                switch (val) {
                    .null => try buf.appendSlice(self.allocator, "\\N"),
                    .int => |v| try buf.appendSlice(self.allocator, try std.fmt.allocPrint(scratch.allocator(), "{d}", .{v})),
                    .float => |v| try buf.appendSlice(self.allocator, try std.fmt.allocPrint(scratch.allocator(), "{d}", .{v})),
                    .string => |v| try appendCsvCell(self.allocator, &buf, v),
                    .bool => |v| try buf.appendSlice(self.allocator, if (v) "t" else "f"),
                }
            }
            try buf.appendSlice(self.allocator, "\n");
            if (libpq_c.PQputCopyData(self.conn, @ptrCast(buf.items.ptr), @intCast(buf.items.len)) != 1) {
                _ = libpq_c.PQputCopyEnd(self.conn, "copy data failed");
                return error.DatabaseError;
            }
        }

        if (libpq_c.PQputCopyEnd(self.conn, null) != 1) return error.DatabaseError;
        const final = libpq_c.PQgetResult(self.conn);
        defer if (final) |f| libpq_c.PQclear(f);
        if (final == null or libpq_c.PQresultStatus(final.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;

        const commit = libpq_c.PQexec(self.conn, "COMMIT");
        defer if (commit) |c| libpq_c.PQclear(c);
        if (commit == null or libpq_c.PQresultStatus(commit.?) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;

        const cmd = std.mem.span(libpq_c.PQcmdTuples(final.?));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    fn batchInsertFn(ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        _ = allocator;
        const self = @as(*PostgresConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        return self.copyFrom(table, columns, rows);
    }

    pub fn toConn(self: *PostgresConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
                .prepare = prepareFn,
                .queryCursor = queryCursorFn,
                .batchInsert = batchInsertFn,
            },
        };
    }
};

// ==== §5  MySQL driver ====

fn formatQuery(allocator: std.mem.Allocator, sql: []const u8, args: []const Value) ![]u8 {
    var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var arg_idx: usize = 0;
    for (sql) |c| {
        if (c == '?') {
            if (arg_idx >= args.len) return error.DatabaseError;
            const arg = args[arg_idx];
            arg_idx += 1;
            switch (arg) {
                .null => try buf.appendSlice(allocator, "NULL"),
                .int => |v| try buf.print(allocator, "{d}", .{v}),
                .float => |v| try buf.print(allocator, "{d}", .{v}),
                .string => |v| {
                    try buf.append(allocator, '\'');
                    // Escape backslash and single quotes for MySQL sql_mode (NO_BACKSLASH_ESCAPES off by default)
                    for (v) |char| {
                        switch (char) {
                            '\\' => try buf.appendSlice(allocator, "\\\\"),
                            '\'' => try buf.appendSlice(allocator, "''"),
                            0x00 => try buf.appendSlice(allocator, "\\0"),
                            '\n' => try buf.appendSlice(allocator, "\\n"),
                            '\r' => try buf.appendSlice(allocator, "\\r"),
                            0x1a => try buf.appendSlice(allocator, "\\Z"),
                            else => try buf.append(allocator, char),
                        }
                    }
                    try buf.append(allocator, '\'');
                },
                .bool => |v| try buf.appendSlice(allocator, if (v) "1" else "0"),
            }
        } else {
            try buf.append(allocator, c);
        }
    }
    return allocator.dupe(u8, buf.items);
}

/// After a successful `mysql_real_query` for a statement that may return rows, build `Rows`.
/// `mysql_store_result` returns NULL in three cases: read failure (errno != 0), statements
/// with no result set (field_count == 0, e.g. INSERT), or an **empty SELECT** (errno == 0,
/// field_count > 0). The last case must yield zero rows, not `DatabaseError`.
/// Caller owns `arena` and should `errdefer arena.deinit()` until `Rows` is returned.
///
/// The two kinds of failure are kept apart: a failure of the arena allocations
/// below is the caller's allocator failing and comes back as `error.OutOfMemory`
/// — the name `Error.zig` documents this file as producing for "arena/dupe
/// failures while scanning rows" — while a failed fetch or field lookup is the
/// driver failing and stays `error.DatabaseError`. Folding the first kind into
/// the second made running out of memory indistinguishable from a statement the
/// server rejected, in the metrics callback's error name, in logs, and in
/// `toErrorContext`.
///
/// The fetch guards are guards, not covered branches: `res` is always a
/// `mysql_store_result` handle, so every row is already in client memory (that
/// is what `mysql_store_result` means) and `mysql_num_rows` is the buffered row
/// count. `mysql_fetch_lengths` is NULL exactly when there is no current row —
/// measured on MySQL 9.3.0: NULL before the first fetch and one fetch past the
/// end, non-NULL after each successful fetch — and no live statement was found
/// that makes either call fail inside this loop (see the MySQL buffered-read
/// tests). They are here so a driver version that ever breaks that contract
/// returns an error instead of dereferencing `lengths[c]` or inventing an
/// all-NULL row.
fn mysqlReadRowsAfterQuery(mysql: ?*libmysql_c.MYSQL, arena: std.heap.ArenaAllocator) errors.ResultT(Rows) {
    var arena_mut = arena;
    const arena_alloc = arena_mut.allocator();
    const res = libmysql_c.mysql_store_result(mysql);
    if (res) |r| {
        defer libmysql_c.mysql_free_result(r);

        const n_cols = libmysql_c.mysql_num_fields(r);
        const n_rows = libmysql_c.mysql_num_rows(r);

        const field_names = try arena_alloc.alloc([]const u8, n_cols);
        for (0..n_cols) |c| {
            const field = libmysql_c.mysql_fetch_field(r) orelse return error.DatabaseError;
            const name = std.mem.span(field.name);
            field_names[c] = try arena_alloc.dupe(u8, name);
        }

        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        for (0..n_rows) |_| {
            const row_data = libmysql_c.mysql_fetch_row(r) orelse {
                std.log.warn("[sqlx] MySQL buffered read ran out of rows after {d} of {d}", .{
                    rows_list.items.len, n_rows,
                });
                return error.DatabaseError;
            };
            const lengths = libmysql_c.mysql_fetch_lengths(r) orelse {
                std.log.warn("[sqlx] MySQL buffered read got no column lengths for a fetched row", .{});
                return error.DatabaseError;
            };
            const values = try arena_alloc.alloc(?Value, n_cols);
            for (0..n_cols) |c| {
                if (row_data[c] == null) {
                    values[c] = null;
                } else {
                    const len = lengths[c];
                    const val = row_data[c].?[0..len];
                    values[c] = .{ .string = try arena_alloc.dupe(u8, val) };
                }
            }
            // Share field_names across rows (same arena lifetime).
            try rows_list.append(arena_alloc, .{ .arena = undefined, .columns = field_names, .values = values });
        }

        const rows_slice = try arena_alloc.alloc(Row, rows_list.items.len);
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena_mut, .rows = rows_slice };
    }

    if (libmysql_c.mysql_errno(mysql) != 0) return error.DatabaseError;
    if (libmysql_c.mysql_field_count(mysql) == 0) return error.DatabaseError;
    const rows_slice = try arena_alloc.alloc(Row, 0);
    const rows = Rows{ .arena = arena_mut, .rows = rows_slice };
    return rows;
}

/// Map MySQL/MariaDB errno to ZigModu errors.
fn mysqlErrnoToError(err_no: c_uint) errors.Error {
    return switch (err_no) {
        // Constraint violations
        1062, 1586 => error.ConstraintViolation, // ER_DUP_ENTRY, ER_DUP_ENTRY_WITH_KEY_NAME
        1451, 1452, 1216, 1217 => error.ConstraintViolation, // FK violations
        1048 => error.ConstraintViolation, // ER_BAD_NULL_ERROR
        // Not found
        1146 => error.NotFound, // ER_NO_SUCH_TABLE
        1054 => error.NotFound, // ER_BAD_FIELD_ERROR
        // Connection failures
        2006, 2013, 2003 => error.DatabaseConnectionFailed, // ER_SERVER_GONE, ER_QUERY_INTERRUPTED, ER_CONN_HOST_ERROR
        // Query failures
        1064 => error.QueryFailed, // ER_PARSE_ERROR
        // Default
        else => error.DatabaseError,
    };
}

/// Per-column bind buffer for binary result-set reading.
const MysqlBindBuffer = union(enum) {
    tiny: u8,
    short: i16,
    long: i32,
    longlong: i64,
    float: f32,
    double: f64,
    string: struct { buf: [4096]u8, len: usize = 0 },
};

/// Bind `args` onto a prepared statement. Scratch storage lives in `arena`.
fn mysqlBindParams(stmt: *libmysql_c.MYSQL_STMT, arena: std.mem.Allocator, args: []const Value) !void {
    if (args.len == 0) return;
    const binds = try arena.alloc(libmysql_c.MYSQL_BIND, args.len);
    @memset(binds, .{});
    const null_flags = try arena.alloc(libmysql_c.my_bool, args.len);
    const lengths = try arena.alloc(c_ulong, args.len);
    const int_bufs = try arena.alloc(i64, args.len);
    const float_bufs = try arena.alloc(f64, args.len);
    const bool_bufs = try arena.alloc(u8, args.len);

    for (args, 0..) |arg, i| {
        switch (arg) {
            .null => {
                null_flags[i] = 1;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_NULL;
                binds[i].is_null = &null_flags[i];
            },
            .int => |v| {
                null_flags[i] = 0;
                int_bufs[i] = v;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_LONGLONG;
                binds[i].buffer = @ptrCast(&int_bufs[i]);
                binds[i].is_null = &null_flags[i];
                binds[i].is_unsigned = 0;
            },
            .float => |v| {
                null_flags[i] = 0;
                float_bufs[i] = v;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_DOUBLE;
                binds[i].buffer = @ptrCast(&float_bufs[i]);
                binds[i].is_null = &null_flags[i];
            },
            .string => |s| {
                null_flags[i] = 0;
                lengths[i] = @intCast(s.len);
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_STRING;
                binds[i].buffer = @ptrCast(@constCast(s.ptr));
                binds[i].buffer_length = @intCast(s.len);
                binds[i].length = &lengths[i];
                binds[i].is_null = &null_flags[i];
            },
            .bool => |v| {
                null_flags[i] = 0;
                bool_bufs[i] = if (v) 1 else 0;
                binds[i].buffer_type = libmysql_c.MYSQL_TYPE_TINY;
                binds[i].buffer = @ptrCast(&bool_bufs[i]);
                binds[i].is_null = &null_flags[i];
                binds[i].is_unsigned = 1;
            },
        }
    }
    if (libmysql_c.mysql_stmt_bind_param(stmt, binds.ptr) != 0) {
        const err_no = libmysql_c.mysql_stmt_errno(stmt);
        const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
        std.log.err("MySQL stmt_bind_param error: errno={d} msg={s}", .{ err_no, err_msg });
        return mysqlErrnoToError(err_no);
    }
}

/// Fetch a single oversized/binary column after `mysql_stmt_fetch` returned
/// `MYSQL_DATA_TRUNCATED`. `field_type` is the original bound type (or field type)
/// so binary BLOB columns are refetched without string coercion.
/// The returned slice is allocated in `arena_alloc`.
fn mysqlFetchStringColumn(arena_alloc: std.mem.Allocator, stmt: *libmysql_c.MYSQL_STMT, col: usize, actual_len: usize, field_type: c_int) errors.ResultT([]u8) {
    // The refetch buffer is this process's memory, so running out of it is
    // `error.OutOfMemory`; the `mysql_stmt_fetch_column` failure below stays
    // `error.DatabaseError` (the server/library refused to hand the column over).
    const temp = try arena_alloc.alloc(u8, actual_len);
    var fetch_len: c_ulong = 0;
    const buffer_type: c_int = if (field_type == 0) libmysql_c.MYSQL_TYPE_STRING else field_type;
    var fetch_bind: libmysql_c.MYSQL_BIND = .{
        .buffer_type = buffer_type,
        .buffer = @ptrCast(temp.ptr),
        .buffer_length = @intCast(actual_len),
        .length = &fetch_len,
    };
    if (libmysql_c.mysql_stmt_fetch_column(stmt, &fetch_bind, @intCast(col), 0) != 0) {
        return error.DatabaseError;
    }
    const returned_len: usize = @intCast(fetch_len);
    if (returned_len > actual_len) return error.DatabaseError;
    return temp[0..returned_len];
}

/// Return a `Value.string` for a column, refetching oversized values on truncation.
fn mysqlFetchStringValue(arena_alloc: std.mem.Allocator, stmt: *libmysql_c.MYSQL_STMT, col: usize, len: usize, rc: c_int, buf: []const u8, field_type: c_int) errors.ResultT(Value) {
    if (len > buf.len) {
        if (rc == libmysql_c.MYSQL_DATA_TRUNCATED) {
            const full = try mysqlFetchStringColumn(arena_alloc, stmt, col, len, field_type);
            return Value{ .string = full };
        }
        return error.DatabaseError;
    }
    return Value{ .string = try arena_alloc.dupe(u8, buf[0..len]) };
}

/// Validate a MySQL DECIMAL/NEWDECIMAL string. Returns the input unchanged on success.
fn mysqlParseDecimal(s: []const u8) errors.Error![]const u8 {
    if (s.len == 0) return error.InvalidFormat;
    var i: usize = 0;
    if (s[0] == '-' or s[0] == '+') i += 1;
    if (i >= s.len) return error.InvalidFormat;
    var has_digit = false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) has_digit = true;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) has_digit = true;
    }
    if (!has_digit or i != s.len) return error.InvalidFormat;
    return s;
}

fn isValidFractionalSeconds(s: []const u8, prefix_len: usize) bool {
    if (s.len == prefix_len) return true;
    if (s.len < prefix_len + 2) return false;
    if (s[prefix_len] != '.') return false;
    const frac = s[prefix_len + 1 ..];
    if (frac.len == 0 or frac.len > 6) return false;
    for (frac) |ch| if (ch < '0' or ch > '9') return false;
    return true;
}

/// Validate a MySQL DATETIME/TIMESTAMP/DATE/TIME string. Returns the input unchanged on success.
fn mysqlParseDateTime(s: []const u8) errors.Error![]const u8 {
    if (s.len < 8) return error.InvalidFormat;

    // DATETIME / TIMESTAMP
    if (std.mem.indexOfScalar(u8, s, ' ') != null) {
        if (s.len < 19) return error.InvalidFormat;
        if (s[4] != '-' or s[7] != '-' or s[10] != ' ' or s[13] != ':' or s[16] != ':') return error.InvalidFormat;
        if (!isValidFractionalSeconds(s, 19)) return error.InvalidFormat;
        return s;
    }

    // DATE
    if (s.len >= 10 and s[4] == '-' and s[7] == '-') {
        if (!isValidFractionalSeconds(s, 10)) return error.InvalidFormat;
        return s;
    }

    // TIME (optional leading '-')
    const time_start: usize = if (s[0] == '-') 1 else 0;
    const prefix_len = time_start + 8;
    if (s.len < prefix_len) return error.InvalidFormat;
    if (s[time_start + 2] != ':' or s[time_start + 5] != ':') return error.InvalidFormat;
    if (!isValidFractionalSeconds(s, prefix_len)) return error.InvalidFormat;
    return s;
}

/// Validate a MySQL JSON string. Returns the input unchanged on success.
fn mysqlParseJson(s: []const u8) errors.Error![]const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidFormat;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch return error.InvalidFormat;
    parsed.deinit();
    return s;
}

/// After successful `mysql_stmt_execute` for a result-producing statement, fetch rows with binary decoding.
fn mysqlStmtReadRows(stmt: *libmysql_c.MYSQL_STMT, arena: *std.heap.ArenaAllocator) errors.ResultT(Rows) {
    // `arena` is a pointer on purpose: the row buffer is built inside this call,
    // and an arena taken by value would record those nodes in the *copy* — so the
    // caller's `errdefer arena.deinit()` would free an empty list and leak the
    // partially built rows on the very allocation failures this path reports.
    const arena_alloc = arena.allocator();

    // Metadata **before** `store_result`. Both orders are documented, but only
    // this one holds on MariaDB Connector/C 11: `mysql_stmt_store_result` leaves
    // the statement's field array such that `mysql_stmt_result_metadata` then
    // hands back a descriptor whose first column is intact and whose remaining
    // columns have `name == NULL` / `name_length == 0` — which is what
    // `field.name[0..field.name_length]` below then panics on
    // (`attempt to use null value`). Measured against mariadb:11 with Debian's
    // libmariadb, the configuration CI runs.
    const meta = libmysql_c.mysql_stmt_result_metadata(stmt) orelse {
        // No metadata → treat as empty result set (should be rare after field_count > 0).
        const empty = try arena_alloc.alloc(Row, 0);
        return Rows{ .arena = arena.*, .rows = empty };
    };
    defer libmysql_c.mysql_free_result(meta);

    if (libmysql_c.mysql_stmt_store_result(stmt) != 0) {
        const err_no = libmysql_c.mysql_stmt_errno(stmt);
        const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
        std.log.err("MySQL stmt_store_result error: errno={d} msg={s}", .{ err_no, err_msg });
        return mysqlErrnoToError(err_no);
    }

    const n_cols = libmysql_c.mysql_num_fields(meta);

    // Everything the bind/decode machinery needs is built in the caller's
    // arena — this process's memory. An allocation failure here is
    // `error.OutOfMemory` (the name `Error.zig` documents for "arena/dupe
    // failures while scanning rows"); a failure of the *library* to describe a
    // column stays `error.DatabaseError` (see the two checks in the loop below).
    const shared_columns = try arena_alloc.alloc([]const u8, n_cols);
    const binds = try arena_alloc.alloc(libmysql_c.MYSQL_BIND, n_cols);
    @memset(binds, .{});
    const null_flags = try arena_alloc.alloc(libmysql_c.my_bool, n_cols);
    const lengths = try arena_alloc.alloc(c_ulong, n_cols);
    const err_flags = try arena_alloc.alloc(libmysql_c.my_bool, n_cols);
    const bind_bufs = try arena_alloc.alloc(MysqlBindBuffer, n_cols);
    const is_unsigned_flags = try arena_alloc.alloc(libmysql_c.my_bool, n_cols);
    // What the decode loop below switches on. Collected while walking the
    // library's field cursor, so neither loop has to index a `MYSQL_FIELD`
    // array (see the comment in the loop).
    const col_types = try arena_alloc.alloc(c_int, n_cols);

    for (0..n_cols) |c| {
        // `mysql_fetch_field(meta)` walks the library's own cursor, and that is
        // why it is used instead of `mysql_fetch_fields(meta)[c]`: an array
        // index assumes this file's `MYSQL_FIELD` has the *linked* library's
        // stride, and it does not for MariaDB. Measured on the configuration CI
        // runs (mariadb:11, Debian libmariadb):
        //
        //     sizeof(MYSQL_FIELD) = 128   offsetof(extension) = 120   offsetof(type) = 112
        //
        // while this file's declaration ends after `type` — 116 bytes, padded to
        // 120. Indexing with that stride reads column 1 from eight bytes before
        // where it starts, i.e. out of the tail of column 0: `name == NULL`,
        // `name_length == 0`, `type == 0`. Column 0 reads correctly, which is
        // exactly the shape the crash had — `attempt to use null value` at
        // `field.name[0..field.name_length]` on the second column.
        const field = libmysql_c.mysql_fetch_field(meta) orelse return error.DatabaseError;
        if (field.name == null) {
            std.log.warn("[sqlx] MySQL metadata gave column {d}/{d} no name; refusing to parse it as a string", .{ c, n_cols });
            return error.DatabaseError;
        }
        col_types[c] = field.type;
        const name = field.name[0..field.name_length];
        shared_columns[c] = try arena_alloc.dupe(u8, name);

        const unsigned = (field.flags & libmysql_c.UNSIGNED_FLAG) != 0;
        is_unsigned_flags[c] = if (unsigned) 1 else 0;

        // Initialize bind buffer based on column type
        bind_bufs[c] = switch (field.type) {
            libmysql_c.MYSQL_TYPE_TINY => .{ .tiny = 0 },
            libmysql_c.MYSQL_TYPE_SHORT => .{ .short = 0 },
            libmysql_c.MYSQL_TYPE_LONG => .{ .long = 0 },
            libmysql_c.MYSQL_TYPE_LONGLONG => .{ .longlong = 0 },
            libmysql_c.MYSQL_TYPE_FLOAT => .{ .float = 0 },
            libmysql_c.MYSQL_TYPE_DOUBLE => .{ .double = 0 },
            else => blk: {
                var buf: [4096]u8 = undefined;
                @memset(&buf, 0);
                break :blk .{ .string = .{ .buf = buf } };
            },
        };

        // Set up bind descriptors per column type
        switch (field.type) {
            libmysql_c.MYSQL_TYPE_TINY => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_TINY;
                binds[c].buffer = @ptrCast(&bind_bufs[c].tiny);
                binds[c].buffer_length = @sizeOf(u8);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_SHORT => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_SHORT;
                binds[c].buffer = @ptrCast(&bind_bufs[c].short);
                binds[c].buffer_length = @sizeOf(i16);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_LONG => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_LONG;
                binds[c].buffer = @ptrCast(&bind_bufs[c].long);
                binds[c].buffer_length = @sizeOf(i32);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_LONGLONG => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_LONGLONG;
                binds[c].buffer = @ptrCast(&bind_bufs[c].longlong);
                binds[c].buffer_length = @sizeOf(i64);
                binds[c].is_unsigned = is_unsigned_flags[c];
            },
            libmysql_c.MYSQL_TYPE_FLOAT => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_FLOAT;
                binds[c].buffer = @ptrCast(&bind_bufs[c].float);
                binds[c].buffer_length = @sizeOf(f32);
                binds[c].is_unsigned = 0;
            },
            libmysql_c.MYSQL_TYPE_DOUBLE => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_DOUBLE;
                binds[c].buffer = @ptrCast(&bind_bufs[c].double);
                binds[c].buffer_length = @sizeOf(f64);
                binds[c].is_unsigned = 0;
            },
            // BLOB types (249-252) and VARCHAR/VAR_STRING: bind as BLOB with length+ptr
            libmysql_c.MYSQL_TYPE_BLOB,
            libmysql_c.MYSQL_TYPE_TINY_BLOB,
            libmysql_c.MYSQL_TYPE_MEDIUM_BLOB,
            libmysql_c.MYSQL_TYPE_LONG_BLOB,
            libmysql_c.MYSQL_TYPE_VAR_STRING,
            libmysql_c.MYSQL_TYPE_VARCHAR,
            => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_BLOB;
                binds[c].buffer = @ptrCast(&bind_bufs[c].string.buf);
                binds[c].buffer_length = bind_bufs[c].string.buf.len;
                binds[c].length = &lengths[c];
                binds[c].is_unsigned = 0;
            },
            // DECIMAL, NEWDECIMAL, DATE, TIME, DATETIME, TIMESTAMP, and default: keep as STRING
            else => {
                binds[c].buffer_type = libmysql_c.MYSQL_TYPE_STRING;
                binds[c].buffer = @ptrCast(&bind_bufs[c].string.buf);
                binds[c].buffer_length = bind_bufs[c].string.buf.len;
                binds[c].length = &lengths[c];
                binds[c].is_unsigned = 0;
            },
        }
        binds[c].is_null = &null_flags[c];
        binds[c].@"error" = &err_flags[c];
    }

    if (libmysql_c.mysql_stmt_bind_result(stmt, binds.ptr) != 0) {
        const err_no = libmysql_c.mysql_stmt_errno(stmt);
        const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
        std.log.err("MySQL stmt_bind_result error: errno={d} msg={s}", .{ err_no, err_msg });
        return mysqlErrnoToError(err_no);
    }

    var rows_list: std.ArrayList(Row) = .empty;
    while (true) {
        const rc = libmysql_c.mysql_stmt_fetch(stmt);
        if (rc == 1) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_fetch error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (rc == libmysql_c.MYSQL_NO_DATA) break;
        // 0 = OK, MYSQL_DATA_TRUNCATED = truncated but still usable
        if (rc != 0 and rc != libmysql_c.MYSQL_DATA_TRUNCATED) {
            return error.DatabaseError;
        }

        const values = try arena_alloc.alloc(?Value, n_cols);
        for (0..n_cols) |c| {
            if (null_flags[c] != 0) {
                values[c] = null;
            } else {
                values[c] = switch (col_types[c]) {
                    libmysql_c.MYSQL_TYPE_TINY => blk: {
                        if (is_unsigned_flags[c] != 0) {
                            break :blk Value{ .int = @as(i64, bind_bufs[c].tiny) };
                        } else {
                            break :blk Value{ .int = @as(i64, @as(i8, @bitCast(bind_bufs[c].tiny))) };
                        }
                    },
                    libmysql_c.MYSQL_TYPE_SHORT => blk: {
                        if (is_unsigned_flags[c] != 0) {
                            break :blk Value{ .int = @as(i64, @as(u16, @bitCast(bind_bufs[c].short))) };
                        } else {
                            break :blk Value{ .int = @as(i64, bind_bufs[c].short) };
                        }
                    },
                    libmysql_c.MYSQL_TYPE_LONG => blk: {
                        if (is_unsigned_flags[c] != 0) {
                            break :blk Value{ .int = @as(i64, @as(u32, @bitCast(bind_bufs[c].long))) };
                        } else {
                            break :blk Value{ .int = @as(i64, bind_bufs[c].long) };
                        }
                    },
                    libmysql_c.MYSQL_TYPE_LONGLONG => blk: {
                        break :blk Value{ .int = bind_bufs[c].longlong };
                    },
                    libmysql_c.MYSQL_TYPE_FLOAT => Value{ .float = @as(f64, bind_bufs[c].float) },
                    libmysql_c.MYSQL_TYPE_DOUBLE => Value{ .float = bind_bufs[c].double },
                    // BLOB types: store as string (like bytea)
                    libmysql_c.MYSQL_TYPE_BLOB,
                    libmysql_c.MYSQL_TYPE_TINY_BLOB,
                    libmysql_c.MYSQL_TYPE_MEDIUM_BLOB,
                    libmysql_c.MYSQL_TYPE_LONG_BLOB,
                    => try mysqlFetchStringValue(arena_alloc, stmt, c, @intCast(lengths[c]), rc, bind_bufs[c].string.buf[0..], binds[c].buffer_type),
                    // DECIMAL, JSON, temporal, ENUM/SET, and explicit STRING fallback
                    libmysql_c.MYSQL_TYPE_NEWDECIMAL,
                    libmysql_c.MYSQL_TYPE_DECIMAL,
                    libmysql_c.MYSQL_TYPE_JSON,
                    libmysql_c.MYSQL_TYPE_DATETIME,
                    libmysql_c.MYSQL_TYPE_TIMESTAMP,
                    libmysql_c.MYSQL_TYPE_DATE,
                    libmysql_c.MYSQL_TYPE_TIME,
                    libmysql_c.MYSQL_TYPE_ENUM,
                    libmysql_c.MYSQL_TYPE_SET,
                    libmysql_c.MYSQL_TYPE_STRING,
                    => try mysqlFetchStringValue(arena_alloc, stmt, c, @intCast(lengths[c]), rc, bind_bufs[c].string.buf[0..], binds[c].buffer_type),
                    // Remaining string-like fallback
                    else => try mysqlFetchStringValue(arena_alloc, stmt, c, @intCast(lengths[c]), rc, bind_bufs[c].string.buf[0..], binds[c].buffer_type),
                };
            }
        }
        try rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values });
    }

    const rows_slice = try arena_alloc.alloc(Row, rows_list.items.len);
    @memcpy(rows_slice, rows_list.items);
    _ = libmysql_c.mysql_stmt_free_result(stmt);
    return Rows{ .arena = arena.*, .rows = rows_slice };
}

pub const MySqlConn = struct {
    mysql: ?*libmysql_c.MYSQL,
    allocator: std.mem.Allocator,
    /// LRU-ish prepared-statement cache keyed by original SQL (`?` placeholders).
    stmt_cache: std.StringHashMap(CachedStmt(*libmysql_c.MYSQL_STMT)),
    stmt_counter: u64 = 0,
    magic: u32 = 0xDBDBDBDB,

    fn guard(self: *const @This()) void {
        if (self.magic != 0xDBDBDBDB) @panic("DB heap corruption detected (MySQL magic mismatch)");
    }

    fn poison(self: *@This()) void {
        self.magic = 0xDEADDEAD;
    }

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, user: []const u8, password: []const u8, db: []const u8, port: u32) !MySqlConn {
        const mysql = libmysql_c.mysql_init(null);
        if (mysql == null) return error.DatabaseError;

        // Connection timeouts (P1-5)
        _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_CONNECT_TIMEOUT, @ptrCast(@constCast(&@as(c_uint, 10))));
        _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_READ_TIMEOUT, @ptrCast(@constCast(&@as(c_uint, 30))));

        // SSL/TLS support (P0-3)
        const ssl_mode = if (std.c.getenv("MYSQL_SSL_MODE")) |v| std.mem.span(v) else "preferred";
        if (std.mem.eql(u8, ssl_mode, "disabled")) {
            // Don't set SSL
        } else if (std.mem.eql(u8, ssl_mode, "required")) {
            _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_SSL_MODE, @ptrCast(@constCast(&libmysql_c.SSL_MODE_REQUIRED)));
        } else {
            _ = libmysql_c.mysql_options(mysql, libmysql_c.MYSQL_OPT_SSL_MODE, @ptrCast(@constCast(&libmysql_c.SSL_MODE_PREFERRED)));
        }

        // "" has ptr=null; mysql_real_connect interprets null as "no password".
        // Use "\x00" (null terminator only) as a null-terminated empty string instead.
        const password_cstr: [*c]const u8 = if (password.len > 0) @ptrCast(password.ptr) else @ptrCast("\x00");
        // Use Unix socket for localhost connections (avoids TCP auth issues with
        // caching_sha2_password which MariaDB Connector/C doesn't support with MySQL 8).
        const use_socket = std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1");
        // Socket path from MYSQL_UNIX_PORT env var, or default (P2-9)
        const socket_path: [*c]const u8 = if (use_socket)
            if (std.c.getenv("MYSQL_UNIX_PORT")) |sp| @ptrCast(sp) else @ptrCast("/tmp/mysql.sock")
        else
            @ptrCast("\x00");
        const conn = libmysql_c.mysql_real_connect(mysql, @ptrCast(host.ptr), @ptrCast(user.ptr), password_cstr, @ptrCast(db.ptr), @intCast(port), socket_path, 0);
        if (conn == null) {
            const err_no = libmysql_c.mysql_errno(mysql);
            const err_msg = cStrSpan(libmysql_c.mysql_error(mysql));
            std.log.err("MySQL connect error: errno={d} msg={s}", .{ err_no, err_msg });
            libmysql_c.mysql_close(mysql);
            return error.DatabaseError;
        }

        // Set charset to utf8mb4 (P1-6)
        _ = libmysql_c.mysql_set_character_set(mysql, "utf8mb4");

        return .{
            .mysql = mysql,
            .allocator = allocator,
            .stmt_cache = std.StringHashMap(CachedStmt(*libmysql_c.MYSQL_STMT)).init(allocator),
        };
    }

    /// Get or prepare a cached statement. Returns reset stmt ready for binding.
    fn getCachedStmt(self: *MySqlConn, sql_str: []const u8) !*libmysql_c.MYSQL_STMT {
        self.guard();
        if (self.stmt_cache.getPtr(sql_str)) |entry| {
            self.stmt_counter += 1;
            entry.last_used = self.stmt_counter;
            _ = libmysql_c.mysql_stmt_reset(entry.value);
            _ = libmysql_c.mysql_stmt_free_result(entry.value);
            return entry.value;
        }
        // Evict LRU entry when at capacity.
        if (self.stmt_cache.count() >= MAX_CACHED_STMTS) {
            if (findLruStmtKey(*libmysql_c.MYSQL_STMT, self.stmt_cache)) |lru_key| {
                if (self.stmt_cache.fetchRemove(lru_key)) |kv| {
                    _ = libmysql_c.mysql_stmt_close(kv.value.value);
                    self.allocator.free(kv.key);
                }
            }
        }
        // `mysql_stmt_init` returning NULL is the library's *own* out of memory,
        // and there is no statement handle yet to read an errno from: it stays
        // `error.DatabaseError` with the other "could not prepare" verdicts,
        // which the callers below answer with the text-protocol fallback.
        const stmt = libmysql_c.mysql_stmt_init(self.mysql) orelse return error.DatabaseError;
        if (libmysql_c.mysql_stmt_prepare(stmt, @ptrCast(sql_str.ptr), @intCast(sql_str.len)) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_prepare error: errno={d} msg={s}", .{ err_no, err_msg });
            _ = libmysql_c.mysql_stmt_close(stmt);
            return mysqlErrnoToError(err_no);
        }
        // Both allocations are this process's memory, so their failure keeps the
        // allocator's own name (`error.OutOfMemory`) rather than becoming the
        // driver's `error.DatabaseError`. The `catch |err|` blocks still close the
        // statement handle the callers rely on before they decline the prepared
        // path — and the callers re-raise `error.OutOfMemory` instead of reading
        // it as that decline.
        const key = self.allocator.dupe(u8, sql_str) catch |err| {
            _ = libmysql_c.mysql_stmt_close(stmt);
            return err;
        };
        self.stmt_counter += 1;
        self.stmt_cache.put(key, .{ .value = stmt, .last_used = self.stmt_counter }) catch |err| {
            self.allocator.free(key);
            _ = libmysql_c.mysql_stmt_close(stmt);
            return err;
        };
        return stmt;
    }

    /// Execute via binary prepared statement. Returns `null` to signal the
    /// `formatQuery` fallback.
    ///
    /// `null` is for a *driver* verdict on the statement — the server would not
    /// take this one prepared — which is what `getCachedStmt` and
    /// `mysqlBindParams` report for every failure except this process's own
    /// memory. `error.OutOfMemory` is re-raised instead of folded into the
    /// fallback: that fallback allocates from the same allocator, so folding it
    /// hides exactly the failures that are not permanent — the one where the
    /// fallback's own buffer happens to fit and the statement then runs for real.
    fn execViaStmt(self: *MySqlConn, sql_str: []const u8, args: []const Value) !?ExecResult {
        const stmt = self.getCachedStmt(sql_str) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        mysqlBindParams(stmt, scratch.allocator(), args) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_execute error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) > 0) {
            _ = libmysql_c.mysql_stmt_store_result(stmt);
            _ = libmysql_c.mysql_stmt_free_result(stmt);
        }
        return ExecResult{
            .rows_affected = libmysql_c.mysql_stmt_affected_rows(stmt),
            .last_insert_id = @intCast(libmysql_c.mysql_stmt_insert_id(stmt)),
        };
    }

    /// Query via binary prepared statement. Returns `null` to signal the
    /// `formatQuery` fallback — for a driver verdict on the statement only, never
    /// for this process's memory: see `execViaStmt`.
    fn queryViaStmt(self: *MySqlConn, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) !?Rows {
        const stmt = self.getCachedStmt(sql_str) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        mysqlBindParams(stmt, scratch.allocator(), args) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return null,
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt_execute error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) == 0) {
            const empty = try arena.allocator().alloc(Row, 0);
            return Rows{ .arena = arena, .rows = empty };
        }
        return try mysqlStmtReadRows(stmt, &arena);
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        // Zero-arg: skip prepare overhead.
        if (args.len == 0) {
            if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(sql_str.ptr), @intCast(sql_str.len)) != 0) {
                const err_no = libmysql_c.mysql_errno(self.mysql);
                const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
                std.log.err("MySQL query error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
            return mysqlReadRowsAfterQuery(self.mysql, arena);
        }

        if (self.queryViaStmt(allocator, sql_str, args)) |maybe_rows| {
            if (maybe_rows) |rows| return rows;
        } else |err| return err;

        // `formatQuery` interpolates into a fresh buffer: a failure of
        // `self.allocator` there is this process running out of memory, while
        // `formatQuery`'s own `error.DatabaseError` (too few arguments for the
        // placeholders) is a caller bug. Both keep their own name — folding the
        // first into the second made running out of memory look like the server
        // rejecting the statement, in the metrics callback's `@errorName`, in
        // the logs, and in `toErrorContext`.
        const query = try formatQuery(self.allocator, sql_str, args);
        defer self.allocator.free(query);

        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) {
            const err_no = libmysql_c.mysql_errno(self.mysql);
            const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
            std.log.err("MySQL query error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }

        return mysqlReadRowsAfterQuery(self.mysql, arena);
    }

    fn execFn(ptr: *anyopaque, sql_str: []const u8, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();

        if (args.len == 0) {
            if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(sql_str.ptr), @intCast(sql_str.len)) != 0) {
                const err_no = libmysql_c.mysql_errno(self.mysql);
                const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
                std.log.err("MySQL exec error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
        } else {
            if (self.execViaStmt(sql_str, args)) |maybe_res| {
                if (maybe_res) |res| return res;
            } else |err| return err;

            // See the `queryFn` fallback above: an allocation failure here is
            // `error.OutOfMemory`, not the driver failing.
            const query = try formatQuery(self.allocator, sql_str, args);
            defer self.allocator.free(query);

            if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) {
                const err_no = libmysql_c.mysql_errno(self.mysql);
                const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
                std.log.err("MySQL exec error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
        }
        // mysql_store_result returns NULL for DDL/DML (no result set). Only free if non-null.
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);

        return ExecResult{
            .rows_affected = libmysql_c.mysql_affected_rows(self.mysql),
            .last_insert_id = @intCast(libmysql_c.mysql_insert_id(self.mysql)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        var it = self.stmt_cache.iterator();
        while (it.next()) |entry| {
            _ = libmysql_c.mysql_stmt_close(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
        }
        self.stmt_cache.deinit();
        if (self.mysql) |mysql| {
            libmysql_c.mysql_close(mysql);
            self.mysql = null;
        }
        self.poison();
        self.allocator.destroy(self);
    }

    fn pingFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (self.mysql == null) return error.DatabaseError;
        return if (libmysql_c.mysql_ping(self.mysql) == 0) {} else error.DatabaseError;
    }

    fn beginFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (libmysql_c.mysql_real_query(self.mysql, "START TRANSACTION", 17) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn commitFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (libmysql_c.mysql_real_query(self.mysql, "COMMIT", 6) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn rollbackFn(ptr: *anyopaque) errors.Result {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (libmysql_c.mysql_real_query(self.mysql, "ROLLBACK", 8) != 0) return error.DatabaseError;
        const res = libmysql_c.mysql_store_result(self.mysql);
        if (res != null) libmysql_c.mysql_free_result(res);
    }

    fn prepareFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8) errors.ResultT(Stmt) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        // The statement cell is this process's memory; `MySqlStmt.prepare`'s own
        // failure is the driver refusing to prepare, and stays `DatabaseError`.
        const stmt = try allocator.create(MySqlStmt);
        errdefer allocator.destroy(stmt);
        stmt.* = MySqlStmt.prepare(self.mysql, allocator, sql_str) catch return error.DatabaseError;
        return stmt.toStmt();
    }

    fn queryCursorFn(ptr: *anyopaque, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value, opts: CursorOptions) errors.ResultT(Cursor) {
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        if (opts.mode == .buffered) {
            const rows = try queryFn(ptr, allocator, sql_str, args);
            return Cursor.init(rows);
        }

        // The interpolated buffer is `self.allocator`'s, so its failure is
        // `error.OutOfMemory` (see `queryFn`), not a database failure.
        const query = if (args.len == 0) sql_str else try formatQuery(self.allocator, sql_str, args);
        defer if (args.len != 0) self.allocator.free(query);
        if (libmysql_c.mysql_real_query(self.mysql, @ptrCast(query.ptr), @intCast(query.len)) != 0) {
            const err_no = libmysql_c.mysql_errno(self.mysql);
            const err_msg = std.mem.span(libmysql_c.mysql_error(self.mysql));
            std.log.err("MySQL streaming query error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        // The column names must survive `MySqlCursor.next`, which resets `arena`
        // on every row — a second arena is what gives them the result set's
        // lifetime instead of a row's.
        var columns_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer columns_arena.deinit();
        const res = libmysql_c.mysql_use_result(self.mysql);
        var columns: [][]u8 = &[_][]u8{};
        var eof = false;
        if (res) |r| {
            const n_cols = libmysql_c.mysql_num_fields(r);
            if (n_cols > 0) {
                columns = try columns_arena.allocator().alloc([]u8, n_cols);
                for (0..n_cols) |c| {
                    const field = libmysql_c.mysql_fetch_field(r) orelse return error.DatabaseError;
                    columns[c] = try columns_arena.allocator().dupe(u8, std.mem.span(field.name));
                }
            }
        } else {
            if (libmysql_c.mysql_errno(self.mysql) != 0) return error.DatabaseError;
            eof = true; // DML or empty result set
        }

        return Cursor{ .state = .{ .streaming_mysql = .{
            .mysql = self.mysql,
            .res = res,
            .arena = arena,
            .columns_arena = columns_arena,
            .columns = columns,
            .row = undefined,
            .eof = eof,
        } } };
    }

    /// Batch insert using a prepared statement executed once per row. This avoids
    /// sending the SQL text repeatedly and keeps the binary wire format.
    fn batchInsertPrepared(self: *MySqlConn, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        validateIdentifier(table) catch return error.DatabaseError;
        if (rows.len == 0) return ExecResult{};
        if (columns.len == 0) return error.DatabaseError;
        for (columns) |c| validateIdentifier(c) catch return error.DatabaseError;

        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);
        try sql.appendSlice(self.allocator, "INSERT INTO ");
        try sql.appendSlice(self.allocator, table);
        try sql.appendSlice(self.allocator, " (");
        for (columns, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, col);
        }
        try sql.appendSlice(self.allocator, ") VALUES (");
        for (0..columns.len) |c| {
            if (c > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, "?");
        }
        try sql.appendSlice(self.allocator, ")");

        const stmt = libmysql_c.mysql_stmt_init(self.mysql) orelse return error.DatabaseError;
        // Sole owner of `stmt` for the whole function: exactly one close on
        // every exit path. An overlapping `errdefer` here (also closing `stmt`)
        // used to fire *together* with this `defer` whenever a later step
        // returned an error — row/column count mismatch below, or
        // `mysql_stmt_execute` failing (e.g. duplicate key) — closing the same
        // MYSQL_STMT twice.
        defer _ = libmysql_c.mysql_stmt_close(stmt);
        if (libmysql_c.mysql_stmt_prepare(stmt, @ptrCast(sql.items.ptr), @intCast(sql.items.len)) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL batch prepare error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        var total_affected: u64 = 0;
        var last_insert_id: i64 = 0;
        for (rows) |row| {
            if (row.len != columns.len) return error.DatabaseError;
            // `mysqlBindParams` builds its bind arrays in `scratch` (this
            // process's memory), so its failure keeps its own name — an
            // allocation failure must not read as the server rejecting the row.
            try mysqlBindParams(stmt, scratch.allocator(), row);
            if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
                const err_no = libmysql_c.mysql_stmt_errno(stmt);
                const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
                std.log.err("MySQL batch execute error: errno={d} msg={s}", .{ err_no, err_msg });
                return mysqlErrnoToError(err_no);
            }
            total_affected += libmysql_c.mysql_stmt_affected_rows(stmt);
            if (last_insert_id == 0) last_insert_id = @intCast(libmysql_c.mysql_stmt_insert_id(stmt));
            _ = libmysql_c.mysql_stmt_free_result(stmt);
            _ = scratch.reset(.free_all);
        }
        return ExecResult{ .rows_affected = total_affected, .last_insert_id = if (last_insert_id == 0) null else last_insert_id };
    }

    fn batchInsertFn(ptr: *anyopaque, allocator: std.mem.Allocator, table: []const u8, columns: []const []const u8, rows: []const []const Value) errors.ResultT(ExecResult) {
        _ = allocator;
        const self = @as(*MySqlConn, @ptrCast(@alignCast(ptr)));
        self.guard();
        return self.batchInsertPrepared(table, columns, rows);
    }

    pub fn toConn(self: *MySqlConn) Conn {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
                .ping = pingFn,
                .begin = beginFn,
                .commit = commitFn,
                .rollback = rollbackFn,
                .prepare = prepareFn,
                .queryCursor = queryCursorFn,
                .batchInsert = batchInsertFn,
            },
        };
    }
};

// ==== §6  Prepared statements ====

pub const Stmt = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    conn: ?Conn = null,

    pub const VTable = struct {
        query: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows),
        exec: *const fn (ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult),
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn query(self: Stmt, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        var rows = try self.vtable.query(self.ptr, allocator, args);
        for (rows.rows) |*row| row.arena = &rows.arena;
        return rows;
    }

    pub fn exec(self: Stmt, args: []const Value) errors.ResultT(ExecResult) {
        return self.vtable.exec(self.ptr, args);
    }

    pub fn close(self: Stmt) void {
        self.vtable.close(self.ptr);
        if (self.conn) |c| c.close();
    }
};

pub const SQLiteStmt = struct {
    db: ?*sqlite3_c.sqlite3,
    stmt: ?*sqlite3_c.sqlite3_stmt,
    allocator: std.mem.Allocator,

    pub fn prepare(db: ?*sqlite3_c.sqlite3, allocator: std.mem.Allocator, sql: []const u8) !SQLiteStmt {
        var stmt: ?*sqlite3_c.sqlite3_stmt = null;
        const rc = sqlite3_c.sqlite3_prepare_v2(db, @ptrCast(sql.ptr), @intCast(sql.len), &stmt, null);
        if (rc != sqlite3_c.SQLITE_OK or stmt == null) return error.DatabaseError;
        return .{ .db = db, .stmt = stmt, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        _ = sqlite3_c.sqlite3_reset(self.stmt);
        try bindSQLite(self.stmt.?, args);

        // As in `SQLiteConn.queryFn`: this arena is the caller's, and a failure
        // to allocate the row buffer in it is `error.OutOfMemory`, not a
        // database failure.
        const col_count = sqlite3_c.sqlite3_column_count(self.stmt);
        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        while (sqlite3_c.sqlite3_step(self.stmt) == sqlite3_c.SQLITE_ROW) {
            const columns = try arena_alloc.alloc([]const u8, @intCast(col_count));
            const values = try arena_alloc.alloc(?Value, @intCast(col_count));
            for (0..@intCast(col_count)) |i| {
                const raw_name = sqlite3_c.sqlite3_column_name(self.stmt, @intCast(i));
                const name_len = std.mem.len(raw_name);
                const name = raw_name[0..name_len];
                columns[i] = try arena_alloc.dupe(u8, name);
                values[i] = try readSQLiteValue(arena_alloc, self.stmt, @intCast(i));
            }
            try rows_list.append(arena_alloc, .{ .arena = undefined, .columns = columns, .values = values });
        }

        const rows_slice = try arena_alloc.alloc(Row, rows_list.items.len);
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        _ = sqlite3_c.sqlite3_reset(self.stmt);
        try bindSQLite(self.stmt.?, args);
        const step_rc = sqlite3_c.sqlite3_step(self.stmt);
        if (step_rc != sqlite3_c.SQLITE_DONE and step_rc != sqlite3_c.SQLITE_ROW) return error.DatabaseError;
        return ExecResult{
            .last_insert_id = sqlite3_c.sqlite3_last_insert_rowid(self.db),
            .rows_affected = @intCast(sqlite3_c.sqlite3_changes(self.db)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*SQLiteStmt, @ptrCast(@alignCast(ptr)));
        if (self.stmt) |s| {
            _ = sqlite3_c.sqlite3_finalize(s);
            self.stmt = null;
        }
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *SQLiteStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

pub const PostgresStmt = struct {
    conn: ?*libpq_c.PGconn,
    /// The statement name, kept **with its sentinel**: `prepare` allocates it
    /// with `allocZ`, and `closeFn` frees the same slice. Storing it as
    /// `[]const u8` dropped the sentinel, so the allocator was handed a length
    /// one byte short of what it handed out — a sizing allocator (`std.testing`,
    /// `GeneralPurposeAllocator` in Debug) panics on that, and `PQexecPrepared`
    /// is given the name through `@ptrCast(self.name.ptr)`, which wants the
    /// sentinel anyway.
    name: [:0]const u8,
    allocator: std.mem.Allocator,

    pub fn prepare(conn: ?*libpq_c.PGconn, allocator: std.mem.Allocator, sql: []const u8) !PostgresStmt {
        var name_buf: [32]u8 = undefined;
        const stmt_name = try bufPrintZ(&name_buf, "stmt_{x}", .{@intFromPtr(sql.ptr)});
        const name_copy = try allocZ(allocator, stmt_name);
        const sql_z = try allocZ(allocator, sql);
        defer allocator.free(sql_z);
        const res = libpq_c.PQprepare(conn, @ptrCast(name_copy.ptr), @ptrCast(sql_z.ptr), 0, null);
        if (res == null) return error.DatabaseError;
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_COMMAND_OK) return error.DatabaseError;
        return .{ .conn = conn, .name = name_copy, .allocator = allocator };
    }

    /// Bind and run the prepared statement. The parameter arrays and the text
    /// copies live in a local arena until `PQexecPrepared` returns, so `null`
    /// here is only the driver's answer — a missing connection (or no result)
    /// — while a failure of that arena is this process's memory and leaves as
    /// `error.OutOfMemory`. Both callers below used to read the two as one.
    fn execParamsPrepared(self: *PostgresStmt, args: []const Value) errors.ResultT(?*libpq_c.PGresult) {
        if (self.conn == null) return null;

        // Arena holds all null-terminated string copies alive until PQexecPrepared completes
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const paramValues = try aa.alloc(?[*:0]const u8, args.len);
        for (args, 0..) |arg, i| {
            paramValues[i] = switch (arg) {
                .null => null,
                .int => |v| try allocPrintZ(aa, "{d}", .{v}),
                .float => |v| try allocPrintZ(aa, "{d}", .{v}),
                .string => |v| try allocZ(aa, v),
                .bool => |v| if (v) @as(?[*:0]const u8, @ptrCast("t")) else @ptrCast("f"),
            };
        }
        const res = libpq_c.PQexecPrepared(self.conn, @ptrCast(self.name.ptr), @intCast(args.len), @ptrCast(paramValues.ptr), null, null, PG_RESULT_BINARY);
        return res;
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const res = (try execParamsPrepared(self, args)) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);
        if (libpq_c.PQresultStatus(res) != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;

        const n_rows = libpq_c.PQntuples(res);
        const n_cols = libpq_c.PQnfields(res);
        var rows_list: std.ArrayList(Row) = std.ArrayList(Row).empty;

        // Same split as `PostgresConn.queryFn`: the caller's arena failing is
        // `error.OutOfMemory`; anything the driver cannot hand over stays
        // `error.DatabaseError` (that is what `pgReadCell` returns for it).
        const shared_columns = try arena_alloc.alloc([]const u8, @intCast(n_cols));
        for (0..@intCast(n_cols)) |c| {
            const name = std.mem.span(libpq_c.PQfname(res, @intCast(c)));
            shared_columns[c] = try arena_alloc.dupe(u8, name);
        }

        for (0..@intCast(n_rows)) |r| {
            const values = try arena_alloc.alloc(?Value, @intCast(n_cols));
            for (0..@intCast(n_cols)) |c| {
                values[c] = try pgReadCell(arena_alloc, res, @intCast(r), @intCast(c));
            }
            try rows_list.append(arena_alloc, .{ .arena = undefined, .columns = shared_columns, .values = values });
        }
        const rows_slice = try arena_alloc.alloc(Row, rows_list.items.len);
        @memcpy(rows_slice, rows_list.items);
        return Rows{ .arena = arena, .rows = rows_slice };
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        const res = (try execParamsPrepared(self, args)) orelse return error.DatabaseError;
        defer libpq_c.PQclear(res);
        const status = libpq_c.PQresultStatus(res);
        if (status != libpq_c.ExecStatusType.PGRES_COMMAND_OK and status != libpq_c.ExecStatusType.PGRES_TUPLES_OK) return error.DatabaseError;
        const cmd = std.mem.span(libpq_c.PQcmdTuples(res));
        const affected = std.fmt.parseInt(u64, cmd, 10) catch 0;
        return ExecResult{ .rows_affected = affected };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*PostgresStmt, @ptrCast(@alignCast(ptr)));
        const dealloc_sql = blk: {
            var buf: [128]u8 = undefined;
            const s = bufPrintZ(&buf, "DEALLOCATE {s}", .{self.name}) catch {
                self.allocator.free(self.name);
                self.allocator.destroy(self);
                return;
            };
            break :blk allocZ(self.allocator, s) catch {
                self.allocator.free(self.name);
                self.allocator.destroy(self);
                return;
            };
        };
        const res = libpq_c.PQexec(self.conn, @ptrCast(dealloc_sql.ptr));
        if (res) |r| libpq_c.PQclear(r);
        self.allocator.free(dealloc_sql);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *PostgresStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

pub const MySqlStmt = struct {
    stmt: ?*libmysql_c.MYSQL_STMT,
    allocator: std.mem.Allocator,

    pub fn prepare(mysql: ?*libmysql_c.MYSQL, allocator: std.mem.Allocator, sql: []const u8) !MySqlStmt {
        const stmt = libmysql_c.mysql_stmt_init(mysql) orelse return error.DatabaseError;
        if (libmysql_c.mysql_stmt_prepare(stmt, @ptrCast(sql.ptr), @intCast(sql.len)) != 0) {
            _ = libmysql_c.mysql_stmt_close(stmt);
            return error.DatabaseError;
        }
        return .{ .stmt = stmt, .allocator = allocator };
    }

    fn queryFn(ptr: *anyopaque, allocator: std.mem.Allocator, args: []const Value) errors.ResultT(Rows) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        const stmt = self.stmt orelse return error.DatabaseError;
        _ = libmysql_c.mysql_stmt_reset(stmt);
        _ = libmysql_c.mysql_stmt_free_result(stmt);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try mysqlBindParams(stmt, scratch.allocator(), args);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt query error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) == 0) {
            const empty = try arena.allocator().alloc(Row, 0);
            return Rows{ .arena = arena, .rows = empty };
        }
        return mysqlStmtReadRows(stmt, &arena);
    }

    fn execFn(ptr: *anyopaque, args: []const Value) errors.ResultT(ExecResult) {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        const stmt = self.stmt orelse return error.DatabaseError;
        _ = libmysql_c.mysql_stmt_reset(stmt);
        _ = libmysql_c.mysql_stmt_free_result(stmt);

        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        try mysqlBindParams(stmt, scratch.allocator(), args);

        if (libmysql_c.mysql_stmt_execute(stmt) != 0) {
            const err_no = libmysql_c.mysql_stmt_errno(stmt);
            const err_msg = std.mem.span(libmysql_c.mysql_stmt_error(stmt));
            std.log.err("MySQL stmt exec error: errno={d} msg={s}", .{ err_no, err_msg });
            return mysqlErrnoToError(err_no);
        }
        if (libmysql_c.mysql_stmt_field_count(stmt) > 0) {
            _ = libmysql_c.mysql_stmt_store_result(stmt);
            _ = libmysql_c.mysql_stmt_free_result(stmt);
        }
        return ExecResult{
            .rows_affected = libmysql_c.mysql_stmt_affected_rows(stmt),
            .last_insert_id = @intCast(libmysql_c.mysql_stmt_insert_id(stmt)),
        };
    }

    fn closeFn(ptr: *anyopaque) void {
        const self = @as(*MySqlStmt, @ptrCast(@alignCast(ptr)));
        if (self.stmt) |s| {
            _ = libmysql_c.mysql_stmt_close(s);
            self.stmt = null;
        }
        self.allocator.destroy(self);
    }

    pub fn toStmt(self: *MySqlStmt) Stmt {
        return .{
            .ptr = self,
            .vtable = &.{
                .query = queryFn,
                .exec = execFn,
                .close = closeFn,
            },
        };
    }
};

// ==== §7  Connection pool ====

const ConnPool = struct {
    pub const PooledEntry = struct {
        conn: Conn,
        created_at_ms: i64,
        idle_since_ms: ?i64 = null,
    };

    pub const Waiter = struct {
        cond: std.Io.Condition,
        ready: bool,
        conn: Conn,
    };

    pub const PoolMetrics = struct {
        total_acquired: u64,
        total_released: u64,
        total_evicted_lifetime: u64,
        total_evicted_idle: u64,
        current_active: u32,
        current_idle: u32,
        current_waiters: u32,
    };

    allocator: std.mem.Allocator,
    client: *Client,
    max_open: u32,
    max_idle: u32,
    max_wait_ms: u32,
    max_lifetime_ms: u64,
    max_idle_time_ms: u64,
    active: std.atomic.Value(u32),
    idle: std.ArrayList(PooledEntry),
    waiters: std.ArrayList(*Waiter),
    mutex: std.Io.Mutex,
    cond: std.Io.Condition,
    closed: std.atomic.Value(bool),
    io: std.Io,
    acquire_count: std.atomic.Value(u64),
    release_count: std.atomic.Value(u64),
    evict_lifetime_count: std.atomic.Value(u64),
    evict_idle_count: std.atomic.Value(u64),

    pub fn init(allocator: std.mem.Allocator, client: *Client, max_open: u32, max_idle: u32, io: std.Io) ConnPool {
        return .{
            .allocator = allocator,
            .client = client,
            .max_open = max_open,
            .max_idle = max_idle,
            .max_wait_ms = client.config.max_wait_ms,
            .max_lifetime_ms = @as(u64, client.config.max_lifetime_secs) * 1000,
            .max_idle_time_ms = @as(u64, client.config.max_idle_time_secs) * 1000,
            .active = std.atomic.Value(u32).init(0),
            .idle = std.ArrayList(PooledEntry).empty,
            .waiters = std.ArrayList(*Waiter).empty,
            .mutex = std.Io.Mutex.init,
            .cond = .init,
            .closed = std.atomic.Value(bool).init(false),
            .io = io,
            .acquire_count = std.atomic.Value(u64).init(0),
            .release_count = std.atomic.Value(u64).init(0),
            .evict_lifetime_count = std.atomic.Value(u64).init(0),
            .evict_idle_count = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *ConnPool) void {
        self.closed.store(true, .monotonic);
        // Wake any waiters waiting on a per-waiter condition.
        self.mutex.lockUncancelable(self.io);
        for (self.waiters.items) |waiter| {
            waiter.ready = false;
            waiter.cond.signal(self.io);
        }
        self.mutex.unlock(self.io);
        self.cond.broadcast(self.io);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.idle.items) |*entry| {
            entry.conn.close();
        }
        self.idle.deinit(self.allocator);
        self.waiters.deinit(self.allocator);
    }

    pub fn acquire(self: *ConnPool) !Conn {
        if (self.closed.load(.monotonic)) return error.ConnectionFailed;

        self.mutex.lockUncancelable(self.io);
        while (true) {
            if (self.closed.load(.monotonic)) {
                self.mutex.unlock(self.io);
                return error.ConnectionFailed;
            }

            // Prefer idle connections — always ping before checkout.
            while (self.idle.items.len > 0) {
                const entry = self.idle.pop().?;
                const conn = entry.conn;
                const created_at = entry.created_at_ms;
                self.mutex.unlock(self.io);
                conn.ping() catch {
                    conn.close();
                    _ = self.active.fetchSub(1, .monotonic);
                    self.mutex.lockUncancelable(self.io);
                    continue;
                };
                const now = Time.monotonicNowMilliseconds();
                if (self.max_lifetime_ms > 0 and now - created_at >= self.max_lifetime_ms) {
                    conn.close();
                    _ = self.active.fetchSub(1, .monotonic);
                    _ = self.evict_lifetime_count.fetchAdd(1, .monotonic);
                    self.mutex.lockUncancelable(self.io);
                    continue;
                }
                _ = self.acquire_count.fetchAdd(1, .monotonic);
                return conn;
            }

            // Create new connection if under limit.
            const current_active = self.active.load(.monotonic);
            if (current_active < self.max_open) {
                _ = self.active.fetchAdd(1, .monotonic);
                self.mutex.unlock(self.io);
                var conn = self.client.newConn() catch {
                    _ = self.active.fetchSub(1, .monotonic);
                    return error.ConnectionFailed;
                };
                conn.created_at_ms = Time.monotonicNowMilliseconds();
                _ = self.acquire_count.fetchAdd(1, .monotonic);
                return conn;
            }

            // Wait until a connection is released (honour max_wait_ms).
            // Waits are sliced (50ms) so the fiber responds to cancellation
            // (io.checkCancel) and pool close between slices — a single long
            // futex wait on Threaded Io would be uninterruptible. The FIFO
            // waiter handoff in `release` still wakes the waiter immediately
            // via its condition variable.
            if (self.max_wait_ms == 0) {
                self.mutex.unlock(self.io);
                return error.Timeout;
            }
            const slice_ns: i96 = 50_000_000; // 50ms per futex slice

            var waiter: Waiter = .{
                .cond = .init,
                .ready = false,
                .conn = undefined,
            };
            self.waiters.append(self.allocator, &waiter) catch {
                self.mutex.unlock(self.io);
                return error.ConnectionFailed;
            };
            var waited_ms: u64 = 0;
            while (waited_ms < self.max_wait_ms) {
                const slice_woken = waiter.cond.waitTimeout(self.io, &self.mutex, .{
                    .duration = .{ .raw = .{ .nanoseconds = slice_ns }, .clock = .awake },
                });
                if (slice_woken) |_| {} else |err| switch (err) {
                    // A slice timeout is NOT an overall failure — keep
                    // waiting until max_wait_ms. Cancellation aborts now
                    // (waitTimeout re-acquires the mutex before returning).
                    error.Timeout => {},
                    error.Canceled => {
                        // Cancellation can land *after* `release` already handed
                        // this waiter a connection (`ready` is set, `conn` is
                        // written, and the signal may or may not have been
                        // observed). Dropping such a hand-off loses the
                        // connection outright — neither closed nor re-pooled,
                        // with `active` never decremented — so every canceled
                        // wait would cost the pool one permanent slot.
                        if (self.cancelWaiter(&waiter)) |conn| return conn;
                        self.mutex.unlock(self.io);
                        return error.Timeout;
                    },
                }
                // Woken with mutex held: released conn handoff, slice timeout,
                // or spurious wakeup.
                if (waiter.ready) {
                    self.removeWaiter(&waiter);
                    _ = self.acquire_count.fetchAdd(1, .monotonic);
                    return waiter.conn;
                }
                if (self.closed.load(.monotonic)) {
                    self.removeWaiter(&waiter);
                    self.mutex.unlock(self.io);
                    return error.ConnectionFailed;
                }
                waited_ms += 50;
            }
            self.removeWaiter(&waiter);
            self.mutex.unlock(self.io);
            return error.Timeout;
        }
    }

    fn removeWaiter(self: *ConnPool, waiter: *Waiter) void {
        for (self.waiters.items, 0..) |w, i| {
            if (w == waiter) {
                _ = self.waiters.orderedRemove(i);
                return;
            }
        }
    }

    /// Canceled-wait cleanup: drop `waiter` from the queue and report the
    /// connection `release` already handed it (`ready`/`conn` are written before
    /// the signal, so a cancellation can arrive in between). Caller holds the
    /// pool mutex; a non-null result transfers that connection to the caller,
    /// null means the waiter owned nothing.
    fn cancelWaiter(self: *ConnPool, waiter: *Waiter) ?Conn {
        self.removeWaiter(waiter);
        if (!waiter.ready) return null;
        _ = self.acquire_count.fetchAdd(1, .monotonic);
        return waiter.conn;
    }

    pub fn release(self: *ConnPool, conn: Conn) void {
        _ = self.release_count.fetchAdd(1, .monotonic);
        if (self.closed.load(.monotonic)) {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
            return;
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // FIFO handoff to the oldest waiting acquire().
        if (self.waiters.items.len > 0) {
            const waiter = self.waiters.orderedRemove(0);
            waiter.ready = true;
            waiter.conn = conn;
            waiter.cond.signal(self.io);
            return;
        }

        // No waiters: evict if the connection exceeded its lifetime.
        const now = Time.monotonicNowMilliseconds();
        const created_at = conn.created_at_ms orelse now;
        if (self.max_lifetime_ms > 0 and now - created_at >= self.max_lifetime_ms) {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
            _ = self.evict_lifetime_count.fetchAdd(1, .monotonic);
            return;
        }

        // Return to idle pool if not full, otherwise close.
        if (self.idle.items.len < self.max_idle) {
            self.idle.append(self.allocator, .{
                .conn = conn,
                .created_at_ms = created_at,
                .idle_since_ms = now,
            }) catch {
                conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                return;
            };
            self.cond.signal(self.io);
        } else {
            conn.close();
            _ = self.active.fetchSub(1, .monotonic);
        }
    }

    /// Retire a connection that must not be reused: ROLLBACK/COMMIT itself
    /// failed, so the server-side transaction state is unknown (PostgreSQL, for
    /// example, keeps the session in "current transaction is aborted" until a
    /// successful ROLLBACK). Failure-path counterpart of `release` — closes the
    /// connection and drops it from the active count instead of handing it to
    /// the next borrower.
    pub fn discard(self: *ConnPool, conn: Conn) void {
        _ = self.release_count.fetchAdd(1, .monotonic);
        conn.close();
        _ = self.active.fetchSub(1, .monotonic);
    }

    /// Pre-create `count` idle connections (capped at `max_idle`).
    pub fn warmup(self: *ConnPool, count: u32) !void {
        if (self.closed.load(.monotonic)) return error.ConnectionFailed;
        const target = @min(count, self.max_idle);
        if (target == 0) return;
        var conns = std.ArrayList(Conn).empty;
        defer {
            for (conns.items) |*c| c.close();
            conns.deinit(self.allocator);
        }
        const now = Time.monotonicNowMilliseconds();
        for (0..target) |_| {
            var conn = self.client.newConn() catch return error.ConnectionFailed;
            conn.created_at_ms = now;
            conns.append(self.allocator, conn) catch {
                conn.close();
                return error.ConnectionFailed;
            };
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (conns.items) |conn| {
            self.idle.append(self.allocator, .{
                .conn = conn,
                .created_at_ms = conn.created_at_ms orelse now,
                .idle_since_ms = now,
            }) catch {
                conn.close();
                continue;
            };
            _ = self.active.fetchAdd(1, .monotonic);
        }
        conns.items.len = 0;
    }

    /// Ping all idle connections — returns false if any are dead.
    pub fn ping(self: *ConnPool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var all_healthy = true;
        var i: usize = 0;
        while (i < self.idle.items.len) {
            self.idle.items[i].conn.ping() catch {
                // Connection is dead — close it and remove from idle pool.
                self.idle.items[i].conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                _ = self.idle.swapRemove(i);
                all_healthy = false;
                continue;
            };
            i += 1;
        }
        return all_healthy;
    }

    /// Run keepAlive — ping all idle connections, then evict any that have been idle too long.
    pub fn keepAlive(self: *ConnPool) void {
        if (!self.ping()) {
            std.log.warn("[ConnPool] keepAlive: some idle connections were dead and removed", .{});
        }
        self.evictIdle();
    }

    fn evictIdle(self: *ConnPool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now = Time.monotonicNowMilliseconds();
        var i: usize = 0;
        while (i < self.idle.items.len) {
            const idle_since = self.idle.items[i].idle_since_ms orelse continue;
            if (self.max_idle_time_ms > 0 and now - idle_since >= self.max_idle_time_ms) {
                self.idle.items[i].conn.close();
                _ = self.active.fetchSub(1, .monotonic);
                _ = self.idle.swapRemove(i);
                _ = self.evict_idle_count.fetchAdd(1, .monotonic);
                continue;
            }
            i += 1;
        }
    }

    /// Current metrics snapshot (values are consistent with respect to the pool mutex).
    pub fn metrics(self: *ConnPool) PoolMetrics {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .total_acquired = self.acquire_count.load(.monotonic),
            .total_released = self.release_count.load(.monotonic),
            .total_evicted_lifetime = self.evict_lifetime_count.load(.monotonic),
            .total_evicted_idle = self.evict_idle_count.load(.monotonic),
            .current_active = self.active.load(.monotonic),
            .current_idle = @intCast(self.idle.items.len),
            .current_waiters = @intCast(self.waiters.items.len),
        };
    }

    /// Execute a function within a transaction, acquiring a connection from the pool.
    /// The connection is automatically released after commit or rollback — or
    /// discarded when ending the transaction failed (its state is unknown then).
    pub fn transaction(self: *ConnPool, comptime func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).@"fn".return_type {
        const conn = try self.acquire();
        var poisoned = false;
        defer {
            if (poisoned) self.discard(conn) else self.release(conn);
        }
        try conn.begin();
        errdefer conn.rollback() catch |e| {
            std.log.err("[ConnPool] tx rollback failed: {}", .{e});
            poisoned = true;
        };
        const result = try @call(.auto, func, .{conn} ++ args);
        conn.commit() catch |e| {
            poisoned = true;
            return e;
        };
        return result;
    }
};

// ==== §8  Unified client ====

/// SQL configuration
pub const Config = struct {
    driver: Driver,
    host: []const u8 = "localhost",
    port: u16 = 3306,
    database: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    sqlite_path: []const u8 = ":memory:",
    postgres_conninfo: []const u8 = "",
    max_open_conns: u32 = 8,
    max_idle_conns: u32 = 4,
    max_wait_ms: u32 = 5000,
    max_lifetime_secs: u32 = 3600,
    max_idle_time_secs: u32 = 300,
    /// libpq socket read timeout (ms). 0 = disabled. Guards against a hung
    /// synchronous PQexec* permanently wedging a fiber/worker thread — the
    /// query fails with error.Timeout and the connection is re-established.
    query_timeout_ms: u32 = 30000,
};

/// Transaction options aligned with Go's sql.TxOptions.
pub const TxOptions = struct {
    read_only: bool = false,
    deferred: bool = false,
};

fn beginSql(driver: Driver, opts: TxOptions) []const u8 {
    if (driver == .mysql) {
        if (opts.read_only) return "START TRANSACTION READ ONLY";
        return "START TRANSACTION";
    }
    if (opts.deferred and opts.read_only) return "BEGIN DEFERRED READ ONLY";
    if (opts.deferred) return "BEGIN DEFERRED";
    if (opts.read_only) return "BEGIN READ ONLY";
    return "BEGIN";
}

/// SQL option function type aligned with go-zero's SqlOption
pub const SqlOption = *const fn (*Client) void;

/// Default acceptable error filter: NotFound is acceptable
pub fn defaultAcceptable(err: anyerror) bool {
    return err == error.NotFound;
}

/// SQL context aligned with go-zero's context.Context usage for sqlx
pub const SqlContext = struct {
    /// Absolute deadline in monotonic milliseconds (see Time.monotonicNowMilliseconds).
    deadline_ms: ?i64 = null,

    pub fn isDone(self: SqlContext) bool {
        if (self.deadline_ms) |d| {
            return Time.monotonicNowMilliseconds() > d;
        }
        return false;
    }

    pub fn withDeadline(deadline_ms: i64) SqlContext {
        return .{ .deadline_ms = deadline_ms };
    }

    pub fn withTimeout(timeout_ms: i64) SqlContext {
        return .{ .deadline_ms = Time.monotonicNowMilliseconds() + timeout_ms };
    }
};

/// Metrics callback type: called after each query/exec with timing info
pub const MetricsCallback = *const fn (duration_ns: u64, query: []const u8, ok: bool, err_msg: ?[]const u8) void;

/// Tracer interface: minimal OpenTelemetry-compatible span
pub const Tracer = struct {
    start_span: *const fn (name: []const u8) Span,
    end_span: *const fn (span: *Span) void,
};

pub const Span = struct {
    name: []const u8,
    start_ns: i128,
    end_ns: ?i128 = null,
    attributes: std.StringHashMap([]const u8),

    pub fn init(name: []const u8) Span {
        return .{
            .name = name,
            .start_ns = Time.monotonicNow(),
            .end_ns = null,
            .attributes = std.StringHashMap([]const u8).init(std.heap.page_allocator),
        };
    }

    /// Span duration in nanoseconds; null until `end()` is called.
    pub fn durationNs(self: *const Span) ?i128 {
        const e = self.end_ns orelse return null;
        return e - self.start_ns;
    }

    pub fn setAttribute(self: *Span, key: []const u8, value: []const u8) void {
        const alloc = std.heap.page_allocator;
        const k = alloc.dupe(u8, key) catch return;
        errdefer alloc.free(k);
        const v = alloc.dupe(u8, value) catch {
            alloc.free(k);
            return;
        };
        self.attributes.put(k, v) catch {
            alloc.free(k);
            alloc.free(v);
        };
    }

    pub fn deinit(self: *Span) void {
        const alloc = std.heap.page_allocator;
        var it = self.attributes.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        self.attributes.deinit();
    }

    pub fn end(self: *Span) void {
        if (self.end_ns == null) {
            self.end_ns = Time.monotonicNow();
        }
        self.deinit();
    }
};

/// SQLx client - unified SQL client
pub const Client = struct {
    allocator: std.mem.Allocator,
    config: Config,
    conn: ?Conn = null,
    pool: ?ConnPool = null,
    /// Eagerly initialized in `init` — never lazy. Does not store `Io`; call sites
    /// pass `self.io` into allow/record* so futex waits use the live handle.
    cb: breaker.CircuitBreaker,
    acceptable: ?*const fn (anyerror) bool = null,
    /// Optional metrics callback (zero-cost when null)
    metrics_callback: ?MetricsCallback = null,
    /// Optional tracer for OpenTelemetry-compatible spans (zero-cost when null)
    tracer: ?*const Tracer = null,
    /// Read-replica client (read/write splitting). `query`-family methods
    /// route here when set; `exec`/`beginTx`/batch writes always hit the
    /// primary. Replica failures transparently fall back to the primary.
    replica: ?*Client = null,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: Config) Client {
        return .{
            .allocator = allocator,
            .config = cfg,
            .conn = null,
            .pool = null,
            .cb = breaker.CircuitBreaker.new(),
            .acceptable = null,
            .metrics_callback = null,
            .tracer = null,
            .io = io,
        };
    }

    /// One-step init + connect. Use instead of init() + connect().
    ///
    /// Pool creation is deferred to the first query via `ensurePool` so
    /// `ConnPool.client` is bound to the caller's stable `*Client` address.
    /// Creating the pool here then `return client` by value would leave
    /// `pool.client` dangling at the temporary's old address (SIGSEGV in
    /// `ensurePool` / `acquire` under `max_open_conns > 1`).
    /// Call `warmPool()` on the assigned client if idle warmup is needed.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !Client {
        var client = Client.init(allocator, io, cfg);
        try client.connect();
        return client;
    }

    /// Create the connection pool (if configured) and optionally warm idle
    /// connections. Must be called on the final `*Client` location (after
    /// `open`/`init` has been stored into its long-lived variable).
    pub fn warmPool(self: *Client) void {
        self.ensurePool();
        if (self.pool) |*p| {
            p.warmup(self.config.max_idle_conns) catch |err| {
                std.log.warn("[sqlx] connection warmup failed: {}", .{err});
            };
        }
    }

    pub fn withOptions(self: *Client, opts: []const SqlOption) void {
        for (opts) |opt| {
            opt(self);
        }
    }

    pub fn withMetrics(self: *Client, cb: MetricsCallback) void {
        self.metrics_callback = cb;
    }

    pub fn withTracer(self: *Client, t: *const Tracer) void {
        self.tracer = t;
    }

    /// Register a read-replica client: `query`/`queryRow`/`queryRows` and the
    /// cursor family route to it, while writes and transactions stay on this
    /// (primary) client. The replica is an ordinary `Client` — build it with
    /// its own `Config` (usually a read-only user + replica host) and treat
    /// it as long-lived as the primary. On any replica failure the read is
    /// retried once against the primary, so stale-or-down replicas degrade
    /// to single-primary behavior instead of failing requests.
    ///
    /// Every failed replica attempt counts against the *replica's* breaker —
    /// including the errors `isAcceptable` swallows (`error.NotFound` is a
    /// replica that is structurally behind, i.e. missing the table). Without
    /// that count the breaker never trips and routing keeps picking a replica
    /// that cannot serve the read.
    pub fn withReplica(self: *Client, replica: *Client) void {
        self.replica = replica;
    }

    /// Read-routing inner gate: returns the replica when one is registered
    /// and its circuit breaker allows traffic; null means "use primary".
    fn readTarget(self: *Client) ?*Client {
        const r = self.replica orelse return null;
        if (!r.cb.allow(r.io)) return null;
        return r;
    }

    fn isAcceptable(self: *Client, err: anyerror) bool {
        if (self.acceptable) |f| {
            return f(err);
        }
        return defaultAcceptable(err);
    }

    /// Count a failed replica attempt against the replica's own breaker.
    ///
    /// The replica's `query`/`queryCursorEx` already records every error
    /// `isAcceptable` rejects; this covers the other half — an *acceptable*
    /// error (`error.NotFound` from a table the replica does not have) still
    /// means the replica could not serve the read. Mirroring the acceptance
    /// filter keeps the bookkeeping "exactly once per failed attempt".
    fn noteReplicaFailure(replica: *Client, err: anyerror) void {
        if (!replica.isAcceptable(err)) return;
        replica.cb.recordFailure(replica.io);
    }

    /// Pool saturation snapshot — `null` when pooling is disabled (e.g. the
    /// `:memory:` single-connection path). Expose these as gauges (see
    /// `PrometheusMetrics.setScrapeHook`) so pool exhaustion is visible before
    /// requests start timing out.
    pub fn poolMetrics(self: *Client) ?ConnPool.PoolMetrics {
        if (self.pool) |*p| return p.metrics();
        return null;
    }

    pub fn deinit(self: *Client) void {
        if (self.pool) |*p| {
            p.deinit();
            self.pool = null;
        }
        if (self.conn) |*c| c.close();
        self.* = undefined;
    }

    fn ensurePool(self: *Client) void {
        if (self.pool) |*p| {
            // Client may have been moved by value after the pool was created
            // (e.g. historical open() path). Always rebind the back-pointer.
            p.client = self;
            return;
        }
        if (self.config.max_open_conns > 1) {
            self.pool = ConnPool.init(self.allocator, self, self.config.max_open_conns, self.config.max_idle_conns, self.io);
        }
    }

    fn newConn(self: *Client) !Conn {
        if (!DriverFeatures.isEnabled(self.config.driver)) return error.DriverNotEnabled;
        switch (self.config.driver) {
            .sqlite => {
                const sqlite = try self.allocator.create(SQLiteConn);
                errdefer self.allocator.destroy(sqlite);
                sqlite.* = try SQLiteConn.open(self.allocator, self.config.sqlite_path);
                return sqlite.toConn();
            },
            .postgres => {
                const pg: *PostgresConn = try self.allocator.create(PostgresConn);
                errdefer self.allocator.destroy(pg);
                if (self.config.postgres_conninfo.len > 0) {
                    pg.* = try PostgresConn.connect(self.allocator, self.config.postgres_conninfo, self.config.query_timeout_ms);
                } else {
                    pg.* = try PostgresConn.connectParams(
                        self.allocator,
                        self.config.host,
                        self.config.port,
                        self.config.username,
                        self.config.password,
                        self.config.database,
                        self.config.query_timeout_ms,
                    );
                }
                return pg.toConn();
            },
            .mysql => {
                const mysql = try self.allocator.create(MySqlConn);
                errdefer self.allocator.destroy(mysql);
                mysql.* = try MySqlConn.connect(self.allocator, self.config.host, self.config.username, self.config.password, self.config.database, self.config.port);
                return mysql.toConn();
            },
        }
    }

    pub fn connect(self: *Client) !void {
        if (self.conn != null) return;
        self.conn = try self.newConn();
    }

    pub fn prepare(self: *Client, sql_str: []const u8) !Stmt {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;
        const conn = try self.newConn();
        errdefer conn.close();
        var stmt = self.newStmt(conn, sql_str) catch |err| {
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        stmt.conn = conn;
        self.cb.recordSuccess(self.io);
        return stmt;
    }

    pub fn prepareCtx(self: *Client, ctx: SqlContext, sql_str: []const u8) !Stmt {
        if (ctx.isDone()) return error.Timeout;
        return self.prepare(sql_str);
    }

    /// `comptime`: the option is a bare `fn (*Client) void`, so the captured
    /// filter has to be a compile-time parameter — as a runtime one, the inner
    /// `apply` cannot reach it and *every* caller fails to compile
    /// (`error: 'f' not accessible from inner function`).
    pub fn withAcceptable(comptime f: *const fn (anyerror) bool) SqlOption {
        return struct {
            fn apply(client: *Client) void {
                client.acceptable = f;
            }
        }.apply;
    }

    fn newStmt(self: *Client, conn: Conn, sql_str: []const u8) !Stmt {
        return conn.prepare(self.allocator, sql_str);
    }

    fn doQuery(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.query(self.allocator, sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.query(self.allocator, sql_str, args) catch {
            // Single-connection reconnect on failure
            self.conn.?.close();
            self.conn = null;
            try self.connect();
            return self.conn.?.query(self.allocator, sql_str, args);
        };
    }

    pub fn query(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        // Read/write splitting: route pure reads to the replica when one is
        // registered. A replica failure falls back to the primary read so a
        // stale replica degrades instead of erroring. The fallback goes to
        // `queryPrimary` directly — re-entering `query` would run `readTarget()`
        // again and, with the replica's breaker still closed (see
        // `noteReplicaFailure`), recurse without bound.
        if (self.readTarget()) |r| {
            return r.query(sql_str, args) catch |err| {
                std.log.warn("[sqlx] replica read failed ({s}), falling back to primary", .{@errorName(err)});
                r.noteReplicaFailure(err);
                return self.queryPrimary(sql_str, args);
            };
        }
        return self.queryPrimary(sql_str, args);
    }

    /// The primary-side read path: `query` with replica routing removed.
    fn queryPrimary(self: *Client, sql_str: []const u8, args: []const Value) !Rows {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;

        const t0 = Time.monotonicNow();
        var rows = self.doQuery(sql_str, args) catch |err| {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
            if (self.metrics_callback) |cb| cb(elapsed, sql_str, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        for (rows.rows) |*row| row.arena = &rows.arena;
        const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
        if (self.metrics_callback) |cb| cb(elapsed, sql_str, true, null);
        self.cb.recordSuccess(self.io);
        return rows;
    }

    pub fn queryCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !Rows {
        if (ctx.isDone()) return error.Timeout;
        return self.query(sql_str, args);
    }

    /// Query and return a buffered Cursor for row-by-row iteration. Caller must `defer cursor.deinit()`.
    pub fn queryCursor(self: *Client, sql_str: []const u8, args: []const Value) !Cursor {
        return self.queryCursorEx(sql_str, args, .{});
    }

    pub fn queryCursorCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !Cursor {
        if (ctx.isDone()) return error.Timeout;
        return self.queryCursor(sql_str, args);
    }

    /// Query and return a Cursor with explicit fetch mode. `.buffered` (default)
    /// materializes all rows; `.streaming` fetches rows lazily and the row returned
    /// by `next()` is only valid until the next `next()`/`deinit()`.
    ///
    /// The cursor is the sole owner of the connection it reads from: a
    /// `.streaming` cursor keeps a pooled connection checked out until
    /// `deinit`, which drains the unconsumed tail of the result stream and only
    /// then releases the connection (retiring it if the stream broke). Its
    /// lifecycle therefore nests inside the client's — `deinit` the cursor
    /// before `Client.deinit`.
    pub fn queryCursorEx(self: *Client, sql_str: []const u8, args: []const Value, opts: CursorOptions) !Cursor {
        // Read/write splitting (same fallback semantics as `query`, including
        // the primary-only fallback so the replica is not re-entered).
        if (self.readTarget()) |r| {
            return r.queryCursorEx(sql_str, args, opts) catch |err| {
                std.log.warn("[sqlx] replica cursor failed ({s}), falling back to primary", .{@errorName(err)});
                r.noteReplicaFailure(err);
                return self.queryCursorExPrimary(sql_str, args, opts);
            };
        }
        return self.queryCursorExPrimary(sql_str, args, opts);
    }

    /// The primary-side cursor path: `queryCursorEx` with replica routing removed.
    ///
    /// Metrics and breaker bookkeeping mirror `queryPrimary` field by field —
    /// same callback arguments, same `isAcceptable` filter, same "one event per
    /// attempt" — so a read served by a cursor is as visible as one served by
    /// `query` (a replica whose cursors fail must be able to trip its breaker
    /// too, or routing keeps picking it).
    ///
    /// Both cover *acquiring* the cursor only. Row fetching happens later, in
    /// `Cursor.next`, which reports a mid-stream failure to its caller instead
    /// of folding it into "no more rows" — and books that same failure against
    /// the cursor's owning client, so the use phase is not a blind spot for the
    /// breaker either (the acquisition above already handed the cursor the
    /// client, and `Cursor.bookFailure` applies the same `isAcceptable` filter
    /// and the same once-per-attempt rule). The meter stays with acquisition:
    /// it is keyed by the statement text, which the cursor does not own.
    fn queryCursorExPrimary(self: *Client, sql_str: []const u8, args: []const Value, opts: CursorOptions) !Cursor {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;

        const t0 = Time.monotonicNow();
        const cursor = self.doQueryCursor(sql_str, args, opts) catch |err| {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
            if (self.metrics_callback) |cb| cb(elapsed, sql_str, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
        if (self.metrics_callback) |cb| cb(elapsed, sql_str, true, null);
        self.cb.recordSuccess(self.io);
        return cursor;
    }

    /// Cursor acquisition over the pool / single connection — the `queryCursorEx`
    /// analogue of `doQuery` (same shape, `CursorOptions` forwarded). Both
    /// branches hand the cursor its owning client: failures that happen *after*
    /// acquisition (mid-stream driver errors) are booked against that client's
    /// breaker, and this is the only place that knows which client that is.
    fn doQueryCursor(self: *Client, sql_str: []const u8, args: []const Value, opts: CursorOptions) !Cursor {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            // A streaming cursor keeps reading from this connection after the
            // function returns, so the checkout has to survive until
            // `Cursor.deinit` (which drains the stream and then releases it).
            // Releasing here — the previous behavior — put the connection back
            // on the idle list (or straight into another fiber's hands) while
            // this query was still on the wire.
            var cursor = conn.queryCursor(self.allocator, sql_str, args, opts) catch |err| {
                p.release(conn);
                return err;
            };
            cursor.owner = self;
            if (cursor.isStreaming()) {
                cursor.checkout = .{ .pool = p, .conn = conn };
            } else {
                // Buffered: every row is in memory, nothing keeps the
                // connection busy.
                p.release(conn);
            }
            return cursor;
        }
        if (self.conn == null) try self.connect();
        var cursor = self.conn.?.queryCursor(self.allocator, sql_str, args, opts) catch |err| blk: {
            std.log.err("queryCursorEx failed, reconnecting: {s}", .{@errorName(err)});
            self.conn.?.close();
            self.conn = null;
            try self.connect();
            break :blk try self.conn.?.queryCursor(self.allocator, sql_str, args, opts);
        };
        cursor.owner = self;
        return cursor;
    }

    fn doExec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.exec(sql_str, args);
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.exec(sql_str, args) catch {
            // Single-connection reconnect on failure
            self.conn.?.close();
            self.conn = null;
            try self.connect();
            return self.conn.?.exec(sql_str, args);
        };
    }

    pub fn exec(self: *Client, sql_str: []const u8, args: []const Value) !ExecResult {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;

        const t0 = Time.monotonicNow();
        const result = self.doExec(sql_str, args) catch |err| {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
            if (self.metrics_callback) |cb| cb(elapsed, sql_str, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
        if (self.metrics_callback) |cb| cb(elapsed, sql_str, true, null);
        self.cb.recordSuccess(self.io);
        return result;
    }

    pub fn execCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.exec(sql_str, args);
    }

    /// Execute the same statement multiple times with different argument sets.
    /// Caller owns the returned slice and must free it with `allocator.free(results)`.
    pub fn batchExec(self: *Client, sql_str: []const u8, rows: []const []const Value) ![]ExecResult {
        const results = try self.allocator.alloc(ExecResult, rows.len);
        errdefer self.allocator.free(results);
        for (rows, 0..) |args, i| {
            results[i] = try self.exec(sql_str, args);
        }
        return results;
    }

    pub fn batchExecCtx(self: *Client, ctx: SqlContext, sql_str: []const u8, rows: []const []const Value) ![]ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.batchExec(sql_str, rows);
    }

    /// Build and execute a single multi-row INSERT for the given table/columns.
    /// All drivers share the `?` placeholder; the caller must ensure `rows[i].len == columns.len`.
    pub fn batchInsert(self: *Client, table: []const u8, columns: []const []const u8, rows: []const []const Value) !ExecResult {
        try validateIdentifier(table);
        if (rows.len == 0) return ExecResult{};
        if (columns.len == 0) return error.DatabaseError;
        for (columns) |c| try validateIdentifier(c);

        // Flatten parameters: [row0col0, row0col1, ..., rowNcolM].
        const total_args = rows.len * columns.len;
        const flat_args = try self.allocator.alloc(Value, total_args);
        defer self.allocator.free(flat_args);
        var pos: usize = 0;
        for (rows) |row| {
            if (row.len != columns.len) return error.DatabaseError;
            @memcpy(flat_args[pos .. pos + row.len], row);
            pos += row.len;
        }

        // Build "INSERT INTO t (c1,c2) VALUES (?,?),(?,?),...".
        var sql = std.ArrayList(u8).empty;
        defer sql.deinit(self.allocator);
        try sql.appendSlice(self.allocator, "INSERT INTO ");
        try sql.appendSlice(self.allocator, table);
        try sql.appendSlice(self.allocator, " (");
        for (columns, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(self.allocator, ",");
            try sql.appendSlice(self.allocator, col);
        }
        try sql.appendSlice(self.allocator, ") VALUES ");
        for (0..rows.len) |r| {
            if (r > 0) try sql.appendSlice(self.allocator, ",");
            try sql.append(self.allocator, '(');
            for (0..columns.len) |c| {
                if (c > 0) try sql.appendSlice(self.allocator, ",");
                try sql.appendSlice(self.allocator, "?");
            }
            try sql.append(self.allocator, ')');
        }
        return self.exec(sql.items, flat_args);
    }

    pub fn batchInsertCtx(self: *Client, ctx: SqlContext, table: []const u8, columns: []const []const u8, rows: []const []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.batchInsert(table, columns, rows);
    }

    /// Batch insert with explicit strategy. `.sql` (default) builds a single
    /// multi-row INSERT; `.protocol` uses MySQL prepared-statement multi-execute
    /// or PostgreSQL `COPY FROM STDIN`. SQLite always falls back to SQL mode.
    pub fn batchInsertEx(self: *Client, table: []const u8, columns: []const []const u8, rows: []const []const Value, opts: BatchInsertOptions) !ExecResult {
        // SQLite has no protocol-level batch insert; use the optimized SQL path.
        // MySQL/PostgreSQL will attempt native batching and fall back on failure.
        if (opts.mode == .sql or rows.len == 0 or self.config.driver == .sqlite) return self.batchInsert(table, columns, rows);
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;
        self.ensurePool();

        const t0 = Time.monotonicNow();
        const result = self.doBatchInsert(table, columns, rows) catch |err| {
            const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
            if (self.metrics_callback) |cb| cb(elapsed, table, false, @errorName(err));
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        const elapsed: u64 = @intCast(@max(@as(i64, 0), Time.monotonicNow() - t0));
        if (self.metrics_callback) |cb| cb(elapsed, table, true, null);
        self.cb.recordSuccess(self.io);
        return result;
    }

    fn doBatchInsert(self: *Client, table: []const u8, columns: []const []const u8, rows: []const []const Value) !ExecResult {
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.batchInsert(self.allocator, table, columns, rows) catch |err| {
                std.log.warn("[sqlx] protocol batch insert failed, falling back to SQL mode: {s}", .{@errorName(err)});
                return self.batchInsert(table, columns, rows);
            };
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.batchInsert(self.allocator, table, columns, rows) catch |err| {
            std.log.warn("[sqlx] protocol batch insert failed, falling back to SQL mode: {s}", .{@errorName(err)});
            return self.batchInsert(table, columns, rows);
        };
    }

    fn doPing(self: *Client) !void {
        self.ensurePool();
        if (self.pool) |*p| {
            const conn = try p.acquire();
            defer p.release(conn);
            return conn.ping();
        }
        if (self.conn == null) try self.connect();
        return self.conn.?.ping();
    }

    pub fn ping(self: *Client) !void {
        if (!self.cb.allow(self.io)) return error.CircuitBreakerOpen;
        self.doPing() catch |err| {
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return err;
        };
        self.cb.recordSuccess(self.io);
    }

    pub fn pingCtx(self: *Client, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.ping();
    }

    pub fn beginTx(self: *Client) errors.Error!Transaction {
        return self.beginTxOpts(.{});
    }

    pub fn beginTxOpts(self: *Client, opts: TxOptions) errors.Error!Transaction {
        if (!self.cb.allow(self.io)) return errors.Error.CircuitBreakerOpen;
        self.ensurePool();
        const sql = beginSql(self.config.driver, opts);
        if (self.pool) |*p| {
            const conn = p.acquire() catch |err| {
                if (err == error.ConnectionFailed) return errors.Error.DatabaseError;
                if (err == error.Timeout) return errors.Error.Timeout;
                if (err == error.PoolUnhealthy) return errors.Error.PoolUnhealthy;
                return errors.Error.DatabaseError;
            };
            errdefer p.release(conn);
            _ = conn.exec(sql, &.{}) catch |err| {
                if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
                return errors.Error.DatabaseError;
            };
            return Transaction{ .conn = conn, .pool = p, .allocator = self.allocator };
        }
        if (self.conn == null) {
            self.connect() catch |err| {
                if (err == error.OutOfMemory) return errors.Error.OutOfMemory;
                return errors.Error.DatabaseError;
            };
        }
        _ = self.conn.?.exec(sql, &.{}) catch |err| {
            if (!self.isAcceptable(err)) self.cb.recordFailure(self.io);
            return errors.Error.DatabaseError;
        };
        return Transaction{ .conn = self.conn.?, .allocator = self.allocator };
    }

    pub fn transact(self: *Client, comptime T: type, fn_tx: *const fn (*Transaction) errors.ResultT(T)) errors.ResultT(T) {
        var tx = try self.beginTx();
        errdefer {
            // `Transaction.rollback` retires the connection either way —
            // released after a clean ROLLBACK, discarded when ROLLBACK itself
            // failed. Releasing here as well would hand a connection with an
            // unknown transaction state to the next borrower.
            tx.rollback() catch |err| std.log.err("[sqlx] Transaction rollback failed: {}", .{err});
        }
        const result = try fn_tx(&tx);
        try tx.commit();
        return result;
    }

    /// transact with a runtime context passed to the callback — the
    /// single-parameter form can't capture business values (order id,
    /// tenant, timestamps), so multi-write business methods use this.
    pub fn transactWith(self: *Client, comptime T: type, comptime Ctx: type, ctx: Ctx, fn_tx: *const fn (*Transaction, Ctx) errors.ResultT(T)) errors.ResultT(T) {
        var tx = try self.beginTx();
        errdefer {
            tx.rollback() catch |err| std.log.err("[sqlx] Transaction rollback failed: {}", .{err});
        }
        const result = try fn_tx(&tx, ctx);
        try tx.commit();
        return result;
    }

    pub fn transactCtx(self: *Client, ctx: SqlContext, comptime T: type, fn_tx: *const fn (*Transaction) errors.ResultT(T)) errors.ResultT(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.transact(T, fn_tx);
    }

    /// Scan the first row into `T`. `[]const u8` / `?[]const u8` fields are
    /// **owned copies** allocated from the client's allocator — the row arena
    /// is released before returning, so strings are never borrowed from it.
    /// The caller owns the returned string fields and must free them once done
    /// (e.g. `defer freeScanned(allocator, T, row)`), otherwise they leak.
    /// Scalar fields are copied by value and need no freeing.
    pub fn queryRow(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        return try scanStruct(self.allocator, T, rows.rows[0], false, indices, false);
    }

    /// Same implementation as `queryRow` — the explicit name makes the
    /// ownership contract self-evident: string fields are owned copies from
    /// the client's allocator and must be freed by the caller
    /// (`freeScanned`). For scope-local use prefer `queryRowBorrowed`, which
    /// returns an arena-backed RAII row with nothing to free.
    pub const queryRowOwned = queryRow;

    /// Arena-borrowed RAII variant of `queryRow`: returns a `BorrowedRow(T)`
    /// that owns the scan arena; `[]const u8` fields point **into** that arena
    /// (no dupe). Strings stay valid until `BorrowedRow.deinit()`, which
    /// releases everything — no `freeScanned` needed. Use when the row is
    /// consumed within a scope.
    pub fn queryRowBorrowed(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        var rows = try self.query(sql_str, args);
        errdefer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        const arena_alloc = rows.arena.allocator();
        const value = try scanStruct(arena_alloc, T, rows.rows[0], false, indices, true);
        const stolen = rows.arena;
        return .{ .value = value, .arena = stolen };
    }

    pub fn queryRowCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRow(T, sql_str, args);
    }

    /// Partial-scan variant of `queryRow`: columns missing from the result set
    /// are zeroed (non-optional string fields become `""`, optionals `null`)
    /// instead of failing. Same ownership contract as `queryRow` — string
    /// fields are owned copies from the client's allocator; the caller must
    /// free them (e.g. `defer freeScanned(allocator, T, row)`).
    pub fn queryRowPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        return try scanStruct(self.allocator, T, rows.rows[0], true, indices, false);
    }

    /// Same implementation as `queryRowPartial` — the explicit name makes the
    /// ownership contract self-evident: string fields are owned copies from
    /// the client's allocator and must be freed by the caller
    /// (`freeScanned`). For scope-local use prefer `queryRowPartialBorrowed`.
    pub const queryRowPartialOwned = queryRowPartial;

    /// Arena-borrowed RAII variant of `queryRowPartial`: returns a
    /// `BorrowedRow(T)` that owns the scan arena; `[]const u8` fields point
    /// **into** that arena (no dupe). Missing columns are zeroed as in
    /// `queryRowPartial`. Strings stay valid until `BorrowedRow.deinit()`.
    pub fn queryRowPartialBorrowed(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        var rows = try self.query(sql_str, args);
        errdefer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(self.allocator, T, rows.rows[0].columns);
        defer self.allocator.free(indices);
        const arena_alloc = rows.arena.allocator();
        const value = try scanStruct(arena_alloc, T, rows.rows[0], true, indices, true);
        const stolen = rows.arena;
        return .{ .value = value, .arena = stolen };
    }

    /// One-shot scalar query: scans the first row and frees the owned strings
    /// internally, returning a plain value copy — no `freeScanned` needed by
    /// the caller. Requires a **string-free** `T` (scalars / numeric structs);
    /// models with `[]const u8` fields hit a compile error (use `queryRow` /
    /// `queryRowOwned` / `queryRowBorrowed` instead). `NotFound` → `null`.
    /// Read one row. Two shapes are accepted:
    ///   * a **struct** — scanned by column name, exactly like `queryRow` (the
    ///     shape this always supported, e.g. a one-field `Count`);
    ///   * a **string-free scalar** (`i64`, `f64`, …) — the *first column* of
    ///     the first row, which is what the `scanStruct` diagnostic points
    ///     callers here for.
    ///
    /// The scalar shape used to forward to `queryRow(T, …)`, which requires a
    /// struct, so it could not compile for any scalar `T` — a dead end that the
    /// error message recommending it led straight into.
    pub fn queryScalar(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        comptime if (typeHasStrings(T)) {
            @compileError("queryScalar requires a string-free type — use queryRow / queryRowOwned / queryRowBorrowed for models with []const u8 fields");
        };
        if (comptime isStruct(T)) {
            const row = self.queryRow(T, sql_str, args) catch |err| switch (err) {
                error.NotFound => return null,
                else => return err,
            };
            return row; // freeScanned is a no-op for string-free T
        }
        var cursor = try self.queryCursorEx(sql_str, args, .{});
        defer cursor.deinit();
        const row = (try cursor.next()) orelse return null;
        if (row.values.len == 0) return error.NotFound;
        const raw = row.values[0] orelse return null;
        if (raw == .null) return null;
        return try valueToType(self.allocator, T, raw);
    }

    fn isStruct(comptime T: type) bool {
        return switch (@typeInfo(T)) {
            .@"struct" => true,
            else => false,
        };
    }

    /// Deadline-aware `queryScalar`: refuses to start once the request budget is
    /// spent. Same string-free `T` requirement.
    pub fn queryScalarCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryScalar(T, sql_str, args);
    }

    /// Deadline-aware `queryRowBorrowed`.
    pub fn queryRowBorrowedCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowBorrowed(T, sql_str, args);
    }

    /// Deadline-aware `queryRowPartialBorrowed`.
    pub fn queryRowPartialBorrowedCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartialBorrowed(T, sql_str, args);
    }

    pub fn queryRowPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartial(T, sql_str, args);
    }

    pub fn queryRows(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        var rows = try self.query(sql_str, args);
        return scanRowsToOwned(T, &rows, false) catch |err| {
            rows.deinit();
            return err;
        };
    }

    pub fn queryRowsCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRows(T, sql_str, args);
    }

    pub fn queryRowsPartial(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        var rows = try self.query(sql_str, args);
        return scanRowsToOwned(T, &rows, true) catch |err| {
            rows.deinit();
            return err;
        };
    }

    pub fn queryRowsPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowsPartial(T, sql_str, args);
    }

    /// Like queryRows but returns an owned QueryResult(T). Caller MUST `defer result.deinit(allocator)`.
    /// Strings borrow the result arena (no per-field second copy).
    pub fn queryRowsOwned(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.queryRows(T, sql_str, args);
    }

    /// Scan all rows into an owned slice using `allocator`: strings are
    /// duplicated and the column→field index is built **once** per query
    /// (O(F+C) setup, O(F) per row) — faster than per-row `Row.scan` for
    /// large result sets while keeping column-name mapping safety.
    ///
    /// Ownership: the returned slice and each item's string fields live in
    /// `allocator`. Caller frees with `freeScanned` per item plus
    /// `allocator.free(slice)` — or transfer items into a collection and free
    /// only the slice buffer (strings then belong to the collection).
    pub fn queryRowsSlice(self: *Client, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) ![]T {
        var rows = try self.query(sql_str, args);
        defer rows.deinit();
        return scanRowsToSlice(allocator, T, &rows, false);
    }

    /// Like queryRowsPartial but returns an owned QueryResult(T). Caller MUST `defer result.deinit(allocator)`.
    pub fn queryRowsPartialOwned(self: *Client, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.queryRowsPartial(T, sql_str, args);
    }

    pub fn findOne(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, sql, args);
    }

    pub fn findOneCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOne(T, table, where_clause, args);
    }

    pub fn findOnePartial(self: *Client, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRowPartial(T, sql, args);
    }

    pub fn findOnePartialCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOnePartial(T, table, where_clause, args);
    }

    pub fn findAll(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, sql, args);
    }

    /// Like findAll but returns an owned QueryResult(T). Caller MUST `defer result.deinit(allocator)`.
    pub fn findAllOwned(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        return self.findAll(T, table, where_clause, args);
    }

    pub fn findAllCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAll(T, table, where_clause, args);
    }

    pub fn findAllPartial(self: *Client, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsPartial(T, sql, args);
    }

    pub fn findAllPartialCtx(self: *Client, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAllPartial(T, table, where_clause, args);
    }
};

/// SQL transaction
pub const Transaction = struct {
    conn: Conn,
    pool: ?*ConnPool = null,
    allocator: std.mem.Allocator,

    pub fn query(self: *Transaction, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) !Rows {
        return self.conn.query(allocator, sql_str, args);
    }

    pub fn queryCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, sql_str: []const u8, args: []const Value) !Rows {
        if (ctx.isDone()) return error.Timeout;
        return self.conn.query(allocator, sql_str, args);
    }

    pub fn exec(self: *Transaction, sql_str: []const u8, args: []const Value) !ExecResult {
        return self.conn.exec(sql_str, args);
    }

    pub fn execCtx(self: *Transaction, ctx: SqlContext, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.conn.exec(sql_str, args);
    }

    /// Return the pooled connection after a clean COMMIT/ROLLBACK.
    fn releaseConn(self: *Transaction) void {
        if (self.pool) |p| {
            p.release(self.conn);
            self.pool = null;
        }
    }

    /// Failure-path counterpart of `releaseConn`: ending the transaction failed,
    /// so the connection's state is unknown and it must not be pooled.
    fn discardConn(self: *Transaction) void {
        if (self.pool) |p| {
            p.discard(self.conn);
            self.pool = null;
        }
    }

    pub fn commit(self: *Transaction) !void {
        self.conn.commit() catch |err| {
            self.discardConn();
            return err;
        };
        self.releaseConn();
    }

    pub fn commitCtx(self: *Transaction, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.commit();
    }

    pub fn rollback(self: *Transaction) !void {
        self.conn.rollback() catch |err| {
            self.discardConn();
            return err;
        };
        self.releaseConn();
    }

    pub fn rollbackCtx(self: *Transaction, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.rollback();
    }

    /// Create a savepoint with the given name.
    pub fn savepoint(self: *Transaction, name: []const u8) !void {
        validateIdentifier(name) catch return error.DatabaseError;
        const sql = try std.fmt.allocPrint(self.allocator, "SAVEPOINT {s}", .{name});
        defer self.allocator.free(sql);
        _ = try self.exec(sql, &.{});
    }

    /// Rollback to a previously created savepoint.
    pub fn rollbackTo(self: *Transaction, name: []const u8) !void {
        validateIdentifier(name) catch return error.DatabaseError;
        const sql = try std.fmt.allocPrint(self.allocator, "ROLLBACK TO {s}", .{name});
        defer self.allocator.free(sql);
        _ = try self.exec(sql, &.{});
    }

    /// Release a savepoint.
    pub fn releaseSavepoint(self: *Transaction, name: []const u8) !void {
        validateIdentifier(name) catch return error.DatabaseError;
        const sql = try std.fmt.allocPrint(self.allocator, "RELEASE SAVEPOINT {s}", .{name});
        defer self.allocator.free(sql);
        _ = try self.exec(sql, &.{});
    }

    /// Scan a single row into struct T (like `Client.queryRow`, but on a tx)
    /// and return owned copies of its `[]const u8` fields — the caller frees
    /// them with `defer freeScanned(allocator, T, row)`.
    ///
    /// **Why does a `Transaction` take an explicit `allocator` here when
    /// `Client.queryRow` does not?** A row scanned inside a transaction must
    /// outlive the transaction's own scan scope: `Transaction.query` hands back
    /// `Rows` that this helper frees right away (`defer rows.deinit()`), so every
    /// string field has to be copied into an allocator whose lifetime the caller
    /// controls. The caller therefore names that allocator (and frees with it);
    /// `Client` has no such parameter because it does exactly this on your
    /// behalf with the pool/client allocator.
    pub fn queryRow(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(allocator, sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scan(allocator, T);
    }

    /// Deadline-aware `queryRow`. Same explicit-`allocator` contract as
    /// `queryRow` above (owned strings outlive the tx scan scope).
    pub fn queryRowCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRow(allocator, T, sql_str, args);
    }

    /// Partial-scan variant of `queryRow` on a transaction: missing columns
    /// are zeroed instead of failing (like `Client.queryRowPartial`). Same
    /// explicit-`allocator` contract as `queryRow` above.
    pub fn queryRowPartial(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        var rows = try self.query(allocator, sql_str, args);
        defer rows.deinit();
        if (rows.rows.len == 0) return error.NotFound;
        return try rows.rows[0].scanPartial(allocator, T);
    }

    /// Deadline-aware `queryRowPartial`.
    pub fn queryRowPartialCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartial(allocator, T, sql_str, args);
    }

    /// Arena-borrowed RAII variant of `queryRow` on a tx (mirrors
    /// `Client.queryRowBorrowed`): returns a `BorrowedRow(T)` that owns the scan
    /// arena, so `[]const u8` fields point **into** that arena instead of being
    /// duplicated — nothing to `freeScanned`; release with `defer row.deinit()`.
    /// `allocator` backs the returned arena and the transient column-index map.
    pub fn queryRowBorrowed(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        var rows = try self.query(allocator, sql_str, args);
        errdefer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(allocator, T, rows.rows[0].columns);
        defer allocator.free(indices);
        const arena_alloc = rows.arena.allocator();
        const value = try scanStruct(arena_alloc, T, rows.rows[0], false, indices, true);
        const stolen = rows.arena;
        return .{ .value = value, .arena = stolen };
    }

    /// Deadline-aware `queryRowBorrowed`.
    pub fn queryRowBorrowedCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowBorrowed(allocator, T, sql_str, args);
    }

    /// Arena-borrowed RAII variant of `queryRowPartial` on a tx (mirrors
    /// `Client.queryRowPartialBorrowed`): missing columns are zeroed like
    /// `queryRowPartial`, strings borrow the arena owned by the returned
    /// `BorrowedRow`. Release with `defer row.deinit()`.
    pub fn queryRowPartialBorrowed(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        var rows = try self.query(allocator, sql_str, args);
        errdefer rows.deinit();
        for (rows.rows) |*row| row.arena = &rows.arena;
        if (rows.rows.len == 0) return error.NotFound;
        const indices = try buildColumnIndices(allocator, T, rows.rows[0].columns);
        defer allocator.free(indices);
        const arena_alloc = rows.arena.allocator();
        const value = try scanStruct(arena_alloc, T, rows.rows[0], true, indices, true);
        const stolen = rows.arena;
        return .{ .value = value, .arena = stolen };
    }

    /// Deadline-aware `queryRowPartialBorrowed`.
    pub fn queryRowPartialBorrowedCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartialBorrowed(allocator, T, sql_str, args);
    }

    /// One-shot scalar query on a tx (mirrors `Client.queryScalar`): scans the
    /// first row, returns a plain value copy, and never hands the caller owned
    /// strings — so nothing needs freeing. `NotFound` → `null`. Requires a
    /// **string-free** `T` (compile error otherwise; use `queryRow` /
    /// `queryRowBorrowed` for models with `[]const u8` fields). `allocator`
    /// covers the transient scan state (no strings means nothing is retained).
    pub fn queryScalar(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        comptime if (typeHasStrings(T)) {
            @compileError("queryScalar requires a string-free type — use queryRow / queryRowOwned / queryRowBorrowed for models with []const u8 fields");
        };
        const row = self.queryRow(allocator, T, sql_str, args) catch |err| switch (err) {
            error.NotFound => return null,
            else => return err,
        };
        return row; // freeScanned is a no-op for string-free T
    }

    /// Deadline-aware `queryScalar`.
    pub fn queryScalarCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !?T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryScalar(allocator, T, sql_str, args);
    }

    /// queryRows scans all rows into an owned QueryResult(T) (like Client.queryRows but on tx).
    /// Caller MUST `defer result.deinit(allocator)`. Same explicit-`allocator`
    /// contract as `queryRow` above: the result's strings outlive the tx scan
    /// scope, so the caller names the allocator that ultimately frees them.
    pub fn queryRows(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        var rows = try self.query(allocator, sql_str, args);
        return scanRowsToOwned(T, &rows, false) catch |err| {
            rows.deinit();
            return err;
        };
    }

    /// Deadline-aware `queryRows`.
    pub fn queryRowsCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRows(allocator, T, sql_str, args);
    }

    /// Partial-scan variant of `queryRows` on a tx (mirrors
    /// `Client.queryRowsPartial`): columns missing from the result set are
    /// zeroed instead of failing. Caller MUST `defer result.deinit(allocator)`
    /// (or `deinitArena()` when the result is arena-backed).
    pub fn queryRowsPartial(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        var rows = try self.query(allocator, sql_str, args);
        return scanRowsToOwned(T, &rows, true) catch |err| {
            rows.deinit();
            return err;
        };
    }

    /// Deadline-aware `queryRowsPartial`.
    pub fn queryRowsPartialCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowsPartial(allocator, T, sql_str, args);
    }

    /// `Client.findOne` on a tx: builds `SELECT * FROM {table} WHERE
    /// {where_clause} LIMIT 1`. The identifier / fragment gates
    /// (`validateIdentifier` + `validateSqlFragment`) are the injection
    /// barriers and are applied exactly as on `Client` — values still belong in
    /// `args` via `?` placeholders. Generated SQL comes from `allocator`.
    pub fn findOne(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer allocator.free(sql);
        return self.queryRow(allocator, T, sql, args);
    }

    /// Deadline-aware `findOne`.
    pub fn findOneCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOne(allocator, T, table, where_clause, args);
    }

    /// Partial-scan `findOne` (mirrors `Client.findOnePartial`): missing columns
    /// are zeroed. Same identifier / fragment validation as `findOne`.
    pub fn findOnePartial(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer allocator.free(sql);
        return self.queryRowPartial(allocator, T, sql, args);
    }

    /// Deadline-aware `findOnePartial`.
    pub fn findOnePartialCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOnePartial(allocator, T, table, where_clause, args);
    }

    /// `Client.findAll` on a tx: `SELECT * FROM {table}` with an optional
    /// validated `WHERE` fragment. Same identifier / fragment gates as
    /// `Client.findAll` (no literals, separators, comments, backticks or
    /// statement keywords — bind values through `args`).
    pub fn findAll(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(allocator, "SELECT * FROM {s}", .{table});
        defer allocator.free(sql);
        return self.queryRows(allocator, T, sql, args);
    }

    /// Deadline-aware `findAll`.
    pub fn findAllCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAll(allocator, T, table, where_clause, args);
    }

    /// Partial-scan `findAll` (mirrors `Client.findAllPartial`): missing columns
    /// are zeroed. Same identifier / fragment validation as `findAll`.
    pub fn findAllPartial(self: *Transaction, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(allocator, "SELECT * FROM {s}", .{table});
        defer allocator.free(sql);
        return self.queryRowsPartial(allocator, T, sql, args);
    }

    /// Deadline-aware `findAllPartial`.
    pub fn findAllPartialCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAllPartial(allocator, T, table, where_clause, args);
    }

    /// Execute the same statement multiple times with different argument sets
    /// inside the transaction (mirrors `Client.batchExec`). Caller owns the
    /// returned slice and must free it with `allocator.free(results)`.
    pub fn batchExec(self: *Transaction, allocator: std.mem.Allocator, sql_str: []const u8, rows: []const []const Value) ![]ExecResult {
        const results = try allocator.alloc(ExecResult, rows.len);
        errdefer allocator.free(results);
        for (rows, 0..) |args, i| {
            results[i] = try self.exec(sql_str, args);
        }
        return results;
    }

    /// Deadline-aware `batchExec`.
    pub fn batchExecCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, sql_str: []const u8, rows: []const []const Value) ![]ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.batchExec(allocator, sql_str, rows);
    }

    /// Liveness probe on the transaction's own connection (mirrors
    /// `Client.ping`, minus the client-level circuit breaker that a tx does not
    /// own).
    pub fn ping(self: *Transaction) !void {
        return self.conn.ping();
    }

    /// Deadline-aware `ping`.
    pub fn pingCtx(self: *Transaction, ctx: SqlContext) !void {
        if (ctx.isDone()) return error.Timeout;
        return self.ping();
    }

    pub fn prepare(self: *Transaction, allocator: std.mem.Allocator, sql_str: []const u8) !Stmt {
        return self.conn.prepare(allocator, sql_str);
    }

    pub fn prepareCtx(self: *Transaction, ctx: SqlContext, allocator: std.mem.Allocator, sql_str: []const u8) !Stmt {
        if (ctx.isDone()) return error.Timeout;
        return self.prepare(allocator, sql_str);
    }
};

fn deepCopyStruct(allocator: std.mem.Allocator, comptime T: type, src: T) !T {
    var dst = src;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |dcn2, dct2| {
        const FieldType = dct2;
        if (FieldType == []const u8) {
            @field(dst, dcn2) = try allocator.dupe(u8, @field(src, dcn2));
        } else if (@typeInfo(FieldType) == .optional and @typeInfo(FieldType).optional.child == []const u8) {
            if (@field(src, dcn2)) |s| {
                @field(dst, dcn2) = try allocator.dupe(u8, s);
            }
        }
    }
    return dst;
}

/// Simple string cache for testing CachedConn
pub const StringCache = struct {
    const Entry = struct {
        value: []const u8,
        expires_at_ms: i64,
    };

    allocator: std.mem.Allocator,
    map: std.StringHashMap(Entry),

    pub fn init(allocator: std.mem.Allocator) StringCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap(Entry).init(allocator),
        };
    }

    pub fn deinit(self: *StringCache) void {
        var iter = self.map.valueIterator();
        while (iter.next()) |v| self.allocator.free(v.value);
        var key_iter = self.map.keyIterator();
        while (key_iter.next()) |k| self.allocator.free(k.*);
        self.map.deinit();
        self.* = undefined;
    }

    pub fn get(self: *StringCache, key: []const u8) ?[]const u8 {
        const entry = self.map.getEntry(key) orelse return null;
        if (Time.monotonicNowMilliseconds() > entry.value_ptr.expires_at_ms) {
            self.allocator.free(entry.value_ptr.value);
            self.allocator.free(entry.key_ptr.*);
            _ = self.map.removeByPtr(entry.key_ptr);
            return null;
        }
        return self.allocator.dupe(u8, entry.value_ptr.value) catch null;
    }

    pub fn set(self: *StringCache, key: []const u8, value: []const u8, ttl_sec: u32) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        const entry = self.map.getEntry(k);
        const expires_at_ms = if (ttl_sec == 0)
            std.math.maxInt(i64)
        else
            Time.monotonicNowMilliseconds() + @as(i64, ttl_sec) * 1000;
        if (entry) |e| {
            self.allocator.free(e.value_ptr.value);
            e.value_ptr.* = .{ .value = v, .expires_at_ms = expires_at_ms };
            self.allocator.free(k);
        } else {
            try self.map.put(k, .{ .value = v, .expires_at_ms = expires_at_ms });
        }
    }

    pub fn del(self: *StringCache, key: []const u8) void {
        if (self.map.fetchRemove(key)) |entry| {
            self.allocator.free(entry.value.value);
            self.allocator.free(entry.key);
        }
    }
};

/// Cached SQL connection aligned with go-zero's CachedConn
pub const CachedConn = struct {
    allocator: std.mem.Allocator,
    client: *Client,

    local_cache: ?*StringCache = null,
    ttl_sec: u32 = 60,

    pub fn queryRow(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            if (try self.decodeCached(T, cache_key, cached)) |hit| {
                var parsed = hit;
                defer parsed.deinit();
                return try deepCopyStruct(self.allocator, T, parsed.value);
            }
        }
        const result = try self.client.queryRow(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRow(T, sql_str, args);
    }

    /// Arena-borrowed variant — deliberately bypasses the JSON cache: the
    /// returned strings point into an arena owned by `BorrowedRow`, which is
    /// incompatible with caching. See `Client.queryRowBorrowed`.
    pub fn queryRowBorrowed(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !BorrowedRow(T) {
        return self.client.queryRowBorrowed(T, sql_str, args);
    }

    pub fn queryRowCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRow(T, cache_key, sql_str, args);
    }

    pub fn queryRowPartial(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            if (try self.decodeCached(T, cache_key, cached)) |hit| {
                var parsed = hit;
                defer parsed.deinit();
                return try deepCopyStruct(self.allocator, T, parsed.value);
            }
        }
        const result = try self.client.queryRowPartial(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !T {
        return self.client.queryRowPartial(T, sql_str, args);
    }

    pub fn queryRowPartialCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowPartial(T, cache_key, sql_str, args);
    }

    pub fn queryRows(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            if (try self.decodeCached([]T, cache_key, cached)) |hit| {
                var parsed = hit;
                defer parsed.deinit();
                const items = try self.allocator.alloc(T, parsed.value.len);
                errdefer {
                    for (items) |item| freeScanned(self.allocator, T, item);
                    self.allocator.free(items);
                }
                for (parsed.value, 0..) |item, i| {
                    items[i] = try deepCopyStruct(self.allocator, T, item);
                }
                return .{ .items = items, .arena = null };
            }
        }
        const result = try self.client.queryRows(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result.items, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowsNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.client.queryRows(T, sql_str, args);
    }

    pub fn queryRowsCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRows(T, cache_key, sql_str, args);
    }

    pub fn queryRowsPartial(self: *CachedConn, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (self.getCache(cache_key)) |cached| {
            defer self.allocator.free(cached);
            if (try self.decodeCached([]T, cache_key, cached)) |hit| {
                var parsed = hit;
                defer parsed.deinit();
                const items = try self.allocator.alloc(T, parsed.value.len);
                errdefer {
                    for (items) |item| freeScanned(self.allocator, T, item);
                    self.allocator.free(items);
                }
                for (parsed.value, 0..) |item, i| {
                    items[i] = try deepCopyStruct(self.allocator, T, item);
                }
                return .{ .items = items, .arena = null };
            }
        }
        const result = try self.client.queryRowsPartial(T, sql_str, args);
        const json = std.json.Stringify.valueAlloc(self.allocator, result.items, .{}) catch {
            return result;
        };
        defer self.allocator.free(json);
        self.setCache(cache_key, json, self.ttl_sec) catch |err| std.log.warn("[CachedConn] setCache failed: {}", .{err});
        return result;
    }

    pub fn queryRowsPartialNoCache(self: *CachedConn, comptime T: type, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        return self.client.queryRowsPartial(T, sql_str, args);
    }

    pub fn queryRowsPartialCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, sql_str: []const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.queryRowsPartial(T, cache_key, sql_str, args);
    }

    pub fn exec(self: *CachedConn, cache_keys: []const []const u8, sql_str: []const u8, args: []const Value) !ExecResult {
        const result = try self.client.exec(sql_str, args);
        for (cache_keys) |key| {
            self.delCache(key) catch |err| std.log.warn("[CachedConn] delCache failed: {}", .{err});
        }
        return result;
    }

    pub fn execNoCache(self: *CachedConn, sql_str: []const u8, args: []const Value) !ExecResult {
        return self.client.exec(sql_str, args);
    }

    pub fn execCtx(self: *CachedConn, ctx: SqlContext, cache_keys: []const []const u8, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.exec(cache_keys, sql_str, args);
    }

    pub fn execNoCacheCtx(self: *CachedConn, ctx: SqlContext, sql_str: []const u8, args: []const Value) !ExecResult {
        if (ctx.isDone()) return error.Timeout;
        return self.execNoCache(sql_str, args);
    }

    pub fn findOne(self: *CachedConn, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRow(T, cache_key, sql, args);
    }

    pub fn findOneNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        try validateIdentifier(table);
        try validateSqlFragment(where_clause);
        const sql = try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s} LIMIT 1", .{ table, where_clause });
        defer self.allocator.free(sql);
        return self.queryRowNoCache(T, sql, args);
    }

    pub fn findOneCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOne(T, cache_key, table, where_clause, args);
    }

    pub fn findOneNoCacheCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: []const u8, args: []const Value) !T {
        if (ctx.isDone()) return error.Timeout;
        return self.findOneNoCache(T, table, where_clause, args);
    }

    pub fn findAll(self: *CachedConn, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRows(T, cache_key, sql, args);
    }

    pub fn findAllNoCache(self: *CachedConn, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        try validateIdentifier(table);
        if (where_clause) |w| try validateSqlFragment(w);
        const sql = if (where_clause) |w|
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s} WHERE {s}", .{ table, w })
        else
            try std.fmt.allocPrint(self.allocator, "SELECT * FROM {s}", .{table});
        defer self.allocator.free(sql);
        return self.queryRowsNoCache(T, sql, args);
    }

    pub fn findAllCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, cache_key: []const u8, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAll(T, cache_key, table, where_clause, args);
    }

    pub fn findAllNoCacheCtx(self: *CachedConn, ctx: SqlContext, comptime T: type, table: []const u8, where_clause: ?[]const u8, args: []const Value) !QueryResult(T) {
        if (ctx.isDone()) return error.Timeout;
        return self.findAllNoCache(T, table, where_clause, args);
    }

    /// Decode a cached JSON blob.
    ///
    /// `null` means the bytes are not a decodable `T` — an entry written for an
    /// older row shape, or corruption. That is a cache **miss**, not a query
    /// failure: this is a read-through cache, so the caller runs the query and
    /// the same call overwrites the entry. That mirrors the fail-open stance the
    /// serialize side of these methods already takes (`catch { return result; }`,
    /// "serve the value, skip the cache").
    ///
    /// An allocation failure inside the parser is a different event: it is this
    /// process running out of memory, so it propagates as `error.OutOfMemory`
    /// rather than being folded into `error.DatabaseError` — a name that means
    /// the database and nothing else (see `Error.zig`).
    fn decodeCached(self: *CachedConn, comptime T: type, cache_key: []const u8, cached: []const u8) error{OutOfMemory}!?std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.allocator, cached, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                std.log.warn("[CachedConn] cached entry for '{s}' is not a decodable {s} ({s}); querying and overwriting it", .{ cache_key, @typeName(T), @errorName(err) });
                return null;
            },
        };
    }

    fn getCache(self: *CachedConn, key: []const u8) ?[]const u8 {
        if (self.local_cache) |lc| {
            return lc.get(key);
        }
        return null;
    }

    fn setCache(self: *CachedConn, key: []const u8, value: []const u8, ttl: u32) !void {
        if (self.local_cache) |lc| {
            try lc.set(key, value, ttl);
            return;
        }
    }

    fn delCache(self: *CachedConn, key: []const u8) !void {
        if (self.local_cache) |lc| {
            lc.del(key);
            return;
        }
    }
};

/// SQL builder for common operations.
///
/// Every method that emits SQL gates its inputs first: pieces that land in the
/// text as *names* (`table`, column lists) go through `validateIdentifier`;
/// pieces that land as developer *expressions* (`join`/`where`/`groupBy`/
/// `having`/`orderBy` clauses, `count`'s predicate) go through
/// `validateSqlFragment`. Without that, the builder was the one same-layer path
/// interpolating unguarded while `Client`/`Transaction`/`CachedConn` validated
/// the identical inputs. Consequence: `selectColumns` takes plain columns — an
/// expression such as `COUNT(*) AS n` is rejected rather than interpolated.
///
/// The chain methods (`selectColumns`, `join`, `where`, `groupBy`, `having`,
/// `orderBy`) stay infallible *at the call site* and keep returning `*Builder`,
/// so the fluent chain is unchanged, but each one stores an owned copy of its
/// argument and a copy that fails is no longer dropped on the floor: the failure
/// is **latched** on the builder and `toSql` returns it. Emitting the statement
/// *without* the clause is what made this a correctness bug rather than a
/// cosmetic loss — a dropped `WHERE` is a silently widened query, so the
/// allocation failure has to reach the caller, and `toSql` (already `![]u8`) is
/// the one point every caller must pass through. `limit` and `offset` cannot
/// fail and have nothing to latch.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    table: []const u8,
    select_columns: ?[][]const u8 = null,
    join_clauses: ?[][]const u8 = null,
    where_clauses: ?[][]const u8 = null,
    group_by_clause: ?[]const u8 = null,
    having_clause: ?[]const u8 = null,
    order_by_clause: ?[]const u8 = null,
    limit_val: ?usize = null,
    offset_val: ?usize = null,
    /// First allocation failure seen by a chain method. Latched rather than
    /// dropped; `toSql` returns it. Once set it stays set — the statement this
    /// builder would emit is already wrong, so later successful calls cannot
    /// make it right again.
    pending_error: ?std.mem.Allocator.Error = null,

    pub fn init(allocator: std.mem.Allocator, table: []const u8) Builder {
        return .{
            .allocator = allocator,
            .table = table,
        };
    }

    /// Gate for the pieces a method emits as names: the table plus the column
    /// list it was handed. Same check `Client.findAll` / `Client.batchInsert`
    /// apply to their `table` / `columns` arguments.
    fn checkNames(self: *const Builder, columns: []const []const u8) error{InvalidSqlIdentifier}!void {
        try self.checkTable();
        for (columns) |c| try validateIdentifier(c);
    }

    /// Gate for a method that emits the table without a column list.
    fn checkTable(self: *const Builder) error{InvalidSqlIdentifier}!void {
        try validateIdentifier(self.table);
    }

    /// Gate for the pieces a method emits as expressions. These are predicates
    /// and ordering terms, not identifiers (`id DESC`, `COUNT(orders.id) > ?2`,
    /// `INNER JOIN ...`), so they get the fragment gate — the same rule
    /// `Client.findAll` applies to its `where_clause`: literals, statement
    /// separators, comments and statement keywords are rejected, ordinary
    /// expressions are not.
    fn checkClauses(self: *const Builder) error{UnsafeSqlFragment}!void {
        if (self.join_clauses) |joins| {
            for (joins) |c| try validateSqlFragment(c);
        }
        if (self.where_clauses) |wheres| {
            for (wheres) |c| try validateSqlFragment(c);
        }
        if (self.group_by_clause) |g| try validateSqlFragment(g);
        if (self.having_clause) |h| try validateSqlFragment(h);
        if (self.order_by_clause) |o| try validateSqlFragment(o);
    }

    pub fn deinit(self: *Builder) void {
        if (self.select_columns) |cols| self.allocator.free(cols);
        if (self.join_clauses) |joins| {
            for (joins) |clause| self.allocator.free(clause);
            self.allocator.free(joins);
        }
        if (self.where_clauses) |wheres| {
            for (wheres) |clause| self.allocator.free(clause);
            self.allocator.free(wheres);
        }
        if (self.group_by_clause) |g| self.allocator.free(g);
        if (self.having_clause) |h| self.allocator.free(h);
        if (self.order_by_clause) |o| self.allocator.free(o);
        self.* = undefined;
    }

    /// Latch an allocation failure instead of dropping the clause. See
    /// `pending_error`: `toSql` is what turns this back into an error.
    fn latch(self: *Builder, err: std.mem.Allocator.Error) void {
        if (self.pending_error == null) self.pending_error = err;
    }

    pub fn selectColumns(self: *Builder, columns: []const []const u8) *Builder {
        const owned = self.allocator.dupe([]const u8, columns) catch |err| {
            self.latch(err);
            return self;
        };
        if (self.select_columns) |cols| self.allocator.free(cols);
        self.select_columns = owned;
        return self;
    }

    /// Append an owned copy of `clause` to a clause list. The copy is made
    /// before the list is touched, so a failed call leaves the builder exactly
    /// as the caller left it.
    fn appendClause(self: *Builder, list: *?[][]const u8, clause: []const u8) std.mem.Allocator.Error!void {
        const owned = try self.allocator.dupe(u8, clause);
        errdefer self.allocator.free(owned);
        if (list.*) |clauses| {
            const grown = try self.allocator.realloc(clauses, clauses.len + 1);
            grown[grown.len - 1] = owned;
            list.* = grown;
        } else {
            const fresh = try self.allocator.alloc([]const u8, 1);
            fresh[0] = owned;
            list.* = fresh;
        }
    }

    /// `appendClause` for the slots that hold one clause: a later call replaces
    /// the earlier one rather than adding to it.
    fn replaceClause(self: *Builder, slot: *?[]const u8, clause: []const u8) std.mem.Allocator.Error!void {
        const owned = try self.allocator.dupe(u8, clause);
        if (slot.*) |previous| self.allocator.free(previous);
        slot.* = owned;
    }

    pub fn join(self: *Builder, clause: []const u8) *Builder {
        self.appendClause(&self.join_clauses, clause) catch |err| self.latch(err);
        return self;
    }

    pub fn where(self: *Builder, clause: []const u8) *Builder {
        self.appendClause(&self.where_clauses, clause) catch |err| self.latch(err);
        return self;
    }

    pub fn groupBy(self: *Builder, clause: []const u8) *Builder {
        self.replaceClause(&self.group_by_clause, clause) catch |err| self.latch(err);
        return self;
    }

    pub fn having(self: *Builder, clause: []const u8) *Builder {
        self.replaceClause(&self.having_clause, clause) catch |err| self.latch(err);
        return self;
    }

    pub fn orderBy(self: *Builder, clause: []const u8) *Builder {
        self.replaceClause(&self.order_by_clause, clause) catch |err| self.latch(err);
        return self;
    }

    pub fn limit(self: *Builder, n: usize) *Builder {
        self.limit_val = n;
        return self;
    }

    pub fn offset(self: *Builder, n: usize) *Builder {
        self.offset_val = n;
        return self;
    }

    pub fn toSql(self: *const Builder) ![]u8 {
        // A latched chain failure means a clause is missing from the statement
        // this would emit, so the caller gets the error instead of the SQL.
        if (self.pending_error) |err| return err;
        try self.checkNames(self.select_columns orelse &.{});
        try self.checkClauses();
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        if (self.select_columns) |cols| {
            try buf.appendSlice(self.allocator, "SELECT ");
            for (cols, 0..) |col, i| {
                if (i > 0) try buf.appendSlice(self.allocator, ", ");
                try buf.appendSlice(self.allocator, col);
            }
            try buf.print(self.allocator, " FROM {s}", .{self.table});
        } else {
            try buf.print(self.allocator, "SELECT * FROM {s}", .{self.table});
        }

        if (self.join_clauses) |joins| {
            for (joins) |clause| {
                try buf.print(self.allocator, " {s}", .{clause});
            }
        }

        if (self.where_clauses) |wheres| {
            try buf.appendSlice(self.allocator, " WHERE ");
            for (wheres, 0..) |clause, i| {
                if (i > 0) try buf.appendSlice(self.allocator, " AND ");
                try buf.appendSlice(self.allocator, clause);
            }
        }

        if (self.group_by_clause) |g| {
            try buf.print(self.allocator, " GROUP BY {s}", .{g});
        }

        if (self.having_clause) |h| {
            try buf.print(self.allocator, " HAVING {s}", .{h});
        }

        if (self.order_by_clause) |o| {
            try buf.print(self.allocator, " ORDER BY {s}", .{o});
        }

        if (self.limit_val) |n| {
            try buf.print(self.allocator, " LIMIT {d}", .{n});
        }

        if (self.offset_val) |n| {
            try buf.print(self.allocator, " OFFSET {d}", .{n});
        }

        return self.allocator.dupe(u8, buf.items);
    }

    pub fn select(self: *const Builder, columns: []const []const u8) ![]u8 {
        var b = Builder.init(self.allocator, self.table);
        // `dupe`'s failure is an allocation failure, not a database one — and
        // labelling it `error.DatabaseError` also hid it from the OOM scans.
        b.select_columns = try self.allocator.dupe([]const u8, columns);
        defer b.deinit();
        return b.toSql();
    }

    pub fn insert(self: *const Builder, columns: []const []const u8) ![]u8 {
        try self.checkNames(columns);
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.print(self.allocator, "INSERT INTO {s} (", .{self.table});
        for (columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, col);
        }
        try buf.appendSlice(self.allocator, ") VALUES (");
        for (0..columns.len) |i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.print(self.allocator, "?{d}", .{i + 1});
        }
        try buf.appendSlice(self.allocator, ")");

        return self.allocator.dupe(u8, buf.items);
    }

    pub fn batchInsert(self: *const Builder, columns: []const []const u8, row_count: usize) ![]u8 {
        try self.checkNames(columns);
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);

        try buf.print(self.allocator, "INSERT INTO {s} (", .{self.table});
        for (columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, col);
        }
        try buf.appendSlice(self.allocator, ") VALUES ");
        var param_idx: usize = 1;
        for (0..row_count) |r| {
            if (r > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.appendSlice(self.allocator, "(");
            for (0..columns.len) |c| {
                if (c > 0) try buf.appendSlice(self.allocator, ", ");
                try buf.print(self.allocator, "?{d}", .{param_idx});
                param_idx += 1;
            }
            try buf.appendSlice(self.allocator, ")");
        }

        return self.allocator.dupe(u8, buf.items);
    }

    pub fn update(self: *const Builder, columns: []const []const u8) ![]u8 {
        try self.checkNames(columns);
        var buf: std.ArrayList(u8) = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.print(self.allocator, "UPDATE {s} SET ", .{self.table});
        for (columns, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(self.allocator, ", ");
            try buf.print(self.allocator, "{s} = ?{d}", .{ col, i + 1 });
        }
        return self.allocator.dupe(u8, buf.items);
    }

    pub fn delete(self: *const Builder) ![]u8 {
        try self.checkTable();
        return std.fmt.allocPrint(self.allocator, "DELETE FROM {s}", .{self.table});
    }

    pub fn count(self: *const Builder, where_clause: ?[]const u8) ![]u8 {
        try self.checkTable();
        if (where_clause) |w| {
            try validateSqlFragment(w);
            return std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s} WHERE {s}", .{ self.table, w });
        }
        return std.fmt.allocPrint(self.allocator, "SELECT COUNT(*) FROM {s}", .{self.table});
    }
};

// ==== §9  Tests ====

/// Skip this test unless the DB env var matches.
/// Postgres tests (named "postgres"): skip if DB=mysql or DB=sqlite
/// MySQL tests (named "mysql"): skip if DB=postgres or DB=sqlite
/// All other tests: always run (DB env doesn't affect them)
/// In CI: postgres job sets DB=postgres, mysql job sets DB=mysql,
/// sqlite job leaves DB unset so all tests run.
fn skipUnlessDb(comptime db: []const u8) !void {
    if (comptime std.mem.eql(u8, db, "postgres")) {
        if (!DriverFeatures.postgres) return error.SkipZigTest;
    } else if (comptime std.mem.eql(u8, db, "mysql")) {
        if (!DriverFeatures.mysql) return error.SkipZigTest;
    } else if (comptime std.mem.eql(u8, db, "sqlite")) {
        if (!DriverFeatures.sqlite) return error.SkipZigTest;
    }
    const db_env = if (builtin.os.tag == .windows) "" else if (std.c.getenv("DB")) |ptr| std.mem.span(ptr) else return error.SkipZigTest;
    if (db_env.len == 0 or !std.mem.eql(u8, db_env, db)) {
        return error.SkipZigTest;
    }
}

test "DriverFeatures and DriverNotEnabled" {
    try std.testing.expect(DriverFeatures.isEnabled(.sqlite) == DriverFeatures.sqlite);
    try std.testing.expect(DriverFeatures.isEnabled(.postgres) == DriverFeatures.postgres);
    try std.testing.expect(DriverFeatures.isEnabled(.mysql) == DriverFeatures.mysql);
    if (DriverFeatures.postgres) return;
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .postgres, .host = "127.0.0.1" });
    defer client.deinit();
    try std.testing.expectError(error.DriverNotEnabled, client.connect());
}

test "read replica routes reads and keeps writes on primary" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // Primary holds the real table; the "replica" is a second in-memory DB
    // seeded with different data so we can observe which side served a read.
    var primary = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer primary.deinit();
    var replica = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer replica.deinit();

    for ([_]*Client{ &primary, &replica }) |c| {
        _ = try c.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    }
    _ = try primary.exec("INSERT INTO users (name) VALUES ('primary-row')", &.{});
    _ = try replica.exec("INSERT INTO users (name) VALUES ('replica-row')", &.{});

    // Without a replica registered: reads hit primary.
    const before = try primary.queryRow(struct { name: []const u8 }, "SELECT name FROM users", &.{});
    defer freeScanned(allocator, @TypeOf(before), before);
    try std.testing.expectEqualStrings("primary-row", before.name);

    primary.withReplica(&replica);

    // Reads now route to the replica.
    const r1 = try primary.queryRow(struct { name: []const u8 }, "SELECT name FROM users", &.{});
    defer freeScanned(allocator, @TypeOf(r1), r1);
    try std.testing.expectEqualStrings("replica-row", r1.name);

    var rows = try primary.query("SELECT name FROM users", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqualStrings("replica-row", rows.rows[0].get("name").?.string);

    // Writes always go to the primary — replica never sees them.
    _ = try primary.exec("INSERT INTO users (name) VALUES ('written-via-primary')", &.{});
    const prim_names = try replica.queryRow(struct { n: i64 }, "SELECT COUNT(*) AS n FROM users WHERE name = 'written-via-primary'", &.{});
    defer freeScanned(allocator, @TypeOf(prim_names), prim_names);
    try std.testing.expectEqual(@as(i64, 0), prim_names.n);

    // Transactions bypass the replica (same primary connection).
    var tx = try primary.beginTx();
    errdefer tx.rollback() catch {};
    _ = try tx.exec("INSERT INTO users (name) VALUES ('tx-row')", &.{});
    try tx.commit();
}

test "read replica failure falls back to primary" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var primary = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer primary.deinit();
    var dead_replica = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = "/nonexistent-dir-must-fail/replica.db" });
    defer dead_replica.deinit();

    _ = try primary.exec("CREATE TABLE t (v TEXT)", &.{});
    _ = try primary.exec("INSERT INTO t (v) VALUES ('from-primary')", &.{});

    primary.withReplica(&dead_replica);
    // Replica open would fail → query falls back to the primary transparently.
    const row = try primary.queryRow(struct { v: []const u8 }, "SELECT v FROM t", &.{});
    defer freeScanned(allocator, @TypeOf(row), row);
    try std.testing.expectEqualStrings("from-primary", row.v);
}

test "read replica failure that is 'acceptable' still falls back to primary" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var primary = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer primary.deinit();
    var dead_replica = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = "/nonexistent-dir-must-fail/replica.db" });
    defer dead_replica.deinit();

    // `acceptable` is the knob that decides whether a replica failure trips the
    // replica's own breaker, and it is the whole reason the fallback used to
    // recurse: an error the filter accepts is not recorded, so `readTarget()`
    // kept picking the same replica and `self.query(...)` re-entered itself.
    // `error.NotFound` is the real-world instance (`defaultAcceptable` accepts
    // it; SQLite raises it for a table the replica does not have, i.e. a
    // structurally-behind replica). It is modeled with a connection failure
    // here because the SQLite driver logs an *error* for the missing-table
    // path, and Zig's test runner fails the run when anything logged at error
    // level — the mechanism under test does not depend on which error it is.
    const Accept = struct {
        fn f(err: anyerror) bool {
            return err == error.ConnectionFailed;
        }
    };
    dead_replica.acceptable = Accept.f;

    _ = try primary.exec("CREATE TABLE t (v TEXT)", &.{});
    _ = try primary.exec("INSERT INTO t (v) VALUES ('from-primary')", &.{});

    primary.withReplica(&dead_replica);

    // One failed replica attempt, then the primary — not one recursion per
    // attempt.
    const row = try primary.queryRow(struct { v: []const u8 }, "SELECT v FROM t", &.{});
    defer freeScanned(allocator, @TypeOf(row), row);
    try std.testing.expectEqualStrings("from-primary", row.v);

    // The unusable attempt counts against the replica's breaker even though its
    // error is "acceptable": after `failure_threshold` of them the replica is
    // skipped outright instead of probed on every read.
    try std.testing.expectEqual(@as(u32, 1), dead_replica.cb.failure_count);
    var i: u32 = 1;
    while (i < dead_replica.cb.failure_threshold) : (i += 1) {
        const r = try primary.queryRow(struct { v: []const u8 }, "SELECT v FROM t", &.{});
        freeScanned(allocator, @TypeOf(r), r);
    }
    try std.testing.expect(!dead_replica.cb.allow(std.testing.io));

    // ...and reads keep serving from the primary.
    const after = try primary.queryRow(struct { v: []const u8 }, "SELECT v FROM t", &.{});
    defer freeScanned(allocator, @TypeOf(after), after);
    try std.testing.expectEqualStrings("from-primary", after.v);
}

test "cached conn queryRow and exec" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    var cached = CachedConn{
        .allocator = allocator,
        .client = &client,
        .local_cache = &cache,
        .ttl_sec = 60,
    };

    // First query should hit DB and populate cache
    const user1 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, user1);
    try std.testing.expectEqual(@as(i64, 1), user1.id);
    try std.testing.expectEqualStrings("Alice", user1.name);

    // Second query should hit cache
    const user2 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 999 }});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);

    // Exec with cache invalidation
    _ = try cached.exec(&.{"user:1"}, "UPDATE users SET name = ?1 WHERE id = ?2", &.{ .{ .string = "Bob" }, .{ .int = 1 } });

    // After invalidation, query should hit DB again
    const user3 = try cached.queryRow(User, "user:1", "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, user3);
    try std.testing.expectEqualStrings("Bob", user3.name);
}

test "sqlite context deadline" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    const User = struct { id: i64, name: []const u8 };

    // Normal context should work
    const ctx_ok = SqlContext.withTimeout(5000);
    const user_ok = try client.queryRowCtx(ctx_ok, User, "SELECT 1 AS id, 'Alice' AS name", &.{});
    defer freeScanned(allocator, User, user_ok);
    try std.testing.expectEqual(@as(i64, 1), user_ok.id);

    // Expired context should return Timeout
    const ctx_expired = SqlContext.withDeadline(0 - 1);
    const err = client.queryRowCtx(ctx_expired, User, "SELECT 1 AS id, 'Alice' AS name", &.{}) catch |e| e;
    try std.testing.expectEqual(errors.Error.Timeout, err);
}

test "sqlite acceptable error does not trip breaker" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    // queryRow on empty table should return NotFound
    const User = struct { id: i64, name: []const u8 };
    const err = client.queryRow(User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 999 }}) catch |e| e;
    try std.testing.expectEqual(errors.Error.NotFound, err);

    // NotFound is acceptable, so breaker should still allow requests
    try client.ping();
}

test "sqlite builder count" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");
    const count_sql = try b.count("id > ?1");
    defer allocator.free(count_sql);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM users WHERE id > ?1", count_sql);

    const count_all = try b.count(null);
    defer allocator.free(count_all);
    try std.testing.expectEqualStrings("SELECT COUNT(*) FROM users", count_all);
}

test "client findOne and findAll" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.findOne(User, "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);

    const users = try client.findAll(User, "users", null, &.{});
    defer users.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), users.items.len);

    // Injection attempts through table / where_clause are rejected.
    try std.testing.expectError(error.InvalidSqlIdentifier, client.findAll(User, "users; DROP TABLE users", null, &.{}));
    try std.testing.expectError(error.UnsafeSqlFragment, client.findOne(User, "users", "name = 'Alice' OR 1=1 --", &.{}));
    try std.testing.expectError(error.UnsafeSqlFragment, client.findAll(User, "users", "1=1; DELETE FROM users", &.{}));
}

test "validateIdentifier and validateSqlFragment" {
    // Valid identifiers
    try validateIdentifier("users");
    try validateIdentifier("public.users");
    try validateIdentifier("_tmp_table1");

    // Invalid identifiers
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier(""));
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier("1users"));
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier("users; DROP"));
    try std.testing.expectError(error.InvalidSqlIdentifier, validateIdentifier("users--"));

    // Valid fragments (parameterized)
    try validateSqlFragment("name = ?1");
    try validateSqlFragment("age > ? AND status = ?");
    try validateSqlFragment("WHERE tenant_id = ? ORDER BY id");
    try validateSqlFragment("id IN (?, ?, ?)");
    try validateSqlFragment("selection = ? AND updated_at > ?"); // banned substrings inside identifiers are fine

    // Unsafe fragments
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("name = 'Alice'"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1; DROP TABLE users"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 -- comment"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 /* comment */"));
    // Identifier quoting / MySQL comment / closing block comment
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("name = `admin`"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 # comment"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 */"));
    // Statement keywords (case-insensitive, whole-token)
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 UNION SELECT password FROM users"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1 union all select 1"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("id = (SELECT id FROM users)"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlFragment("1=1; drop table users"));
}

test "validateSqlStatement allows full SELECT but bans literals/comments" {
    try validateSqlStatement("SELECT id, name FROM users WHERE tenant_id = ?1");
    try validateSqlStatement("SELECT id FROM (SELECT id FROM users) AS t WHERE t.id = ?");
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlStatement("SELECT * FROM users WHERE name = 'x'"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlStatement("SELECT 1; DROP TABLE users"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlStatement("SELECT 1 -- tail"));
    try std.testing.expectError(error.UnsafeSqlFragment, validateSqlStatement("SELECT `pw` FROM users"));
}

// `information_schema.columns` spans every schema (PG) / every database (MySQL)
// the server can see, so the `table_schema` predicate is what keeps a
// same-named table elsewhere from answering for this one. **No server is
// reachable from this test**: what is asserted is the generated statement and
// its arguments — that each shape carries a schema predicate, and that the
// binds line up with the placeholders. The end-to-end behaviour against PG and
// MySQL is covered by the real-server tests behind `ZIGMODU_TEST_PG` / `DB=mysql`
// (`web4.X402Store`), which do not run here.
test "catalogColumnProbe scopes the lookup to a schema" {
    const pg = catalogColumnProbe(.postgres, "orders", "payer_did");
    try std.testing.expect(std.mem.indexOf(u8, pg.sql, "information_schema.columns") != null);
    try std.testing.expect(std.mem.indexOf(u8, pg.sql, "table_schema = current_schema()") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, pg.sql, "?"));
    try std.testing.expectEqual(@as(usize, 2), pg.bindArgs().len);
    try std.testing.expectEqualStrings("orders", pg.bindArgs()[0].string);
    try std.testing.expectEqualStrings("payer_did", pg.bindArgs()[1].string);

    const my = catalogColumnProbe(.mysql, "orders", "payer_did");
    try std.testing.expect(std.mem.indexOf(u8, my.sql, "table_schema = DATABASE()") != null);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, my.sql, "?"));
    try std.testing.expectEqual(@as(usize, 2), my.bindArgs().len);
    try std.testing.expectEqualStrings("orders", my.bindArgs()[0].string);
    try std.testing.expectEqualStrings("payer_did", my.bindArgs()[1].string);

    // A qualified table names its own schema; the connection's schema is not
    // consulted, and the schema travels as a bind rather than as SQL text.
    for ([_]CatalogDialect{ .postgres, .mysql }) |dialect| {
        const qualified = catalogColumnProbe(dialect, "billing.orders", "payer_did");
        try std.testing.expect(std.mem.indexOf(u8, qualified.sql, "LOWER(table_schema) = LOWER(?)") != null);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, qualified.sql, "?"));
        try std.testing.expectEqual(@as(usize, 3), qualified.bindArgs().len);
        try std.testing.expectEqualStrings("billing", qualified.bindArgs()[0].string);
        try std.testing.expectEqualStrings("orders", qualified.bindArgs()[1].string);
        try std.testing.expectEqualStrings("payer_did", qualified.bindArgs()[2].string);
    }
}

test "cached conn findOne" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    var cached = CachedConn{
        .allocator = allocator,
        .client = &client,
        .local_cache = &cache,
        .ttl_sec = 60,
    };

    const user1 = try cached.findOne(User, "user:1", "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user1);

    const user2 = try cached.findOne(User, "user:1", "users", "name = ?1", &.{.{ .string = "WRONG" }});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);
}

test "sqlite parameterized query treats injection payload as literal" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    const malicious = "'; DROP TABLE users; --";
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = malicious }});

    var rows = try client.query("SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = malicious }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);

    var count_rows = try client.query("SELECT COUNT(*) AS cnt FROM users", &.{});
    defer count_rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), (&count_rows.rows[0]).get("cnt").?.int);
}

test "sqlite in-memory query and exec" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();

    const create = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    try std.testing.expectEqual(@as(u64, 0), create.rows_affected);

    const insert = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(i64, 1), insert.last_insert_id.?);

    var rows = try client.query("SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqual(@as(i64, 1), (&rows.rows[0]).get("id").?.int);
    if ((&rows.rows[0]).get("name")) |name_val| {
        try std.testing.expectEqualStrings("Alice", name_val.string);
    } else return error.TestUnexpectedResult;
}

test "sqlx builder" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");

    const select_sql = try b.select(&.{ "id", "name", "email" });
    defer allocator.free(select_sql);
    try std.testing.expectEqualStrings("SELECT id, name, email FROM users", select_sql);

    const insert_sql = try b.insert(&.{ "name", "email" });
    defer allocator.free(insert_sql);
    try std.testing.expectEqualStrings("INSERT INTO users (name, email) VALUES (?1, ?2)", insert_sql);
}

test "sqlx builder chainable" {
    const allocator = std.testing.allocator;
    var b = Builder.init(allocator, "users");
    defer b.deinit();

    // The clause links are fallible, so they are handled one by one; the
    // infallible tail (`limit` / `offset`) still chains.
    _ = b.selectColumns(&.{ "id", "name" });
    _ = b.where("id = ?1");
    _ = b.where("name = ?2");
    _ = b.orderBy("id DESC");
    _ = b.limit(10).offset(20);

    const sql = try b.toSql();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings("SELECT id, name FROM users WHERE id = ?1 AND name = ?2 ORDER BY id DESC LIMIT 10 OFFSET 20", sql);
}

test "sqlx builder join group by having" {
    const allocator = std.testing.allocator;
    var b = Builder.init(allocator, "users");
    defer b.deinit();

    _ = b.selectColumns(&.{ "users.id", "users.name" });
    _ = b.join("INNER JOIN orders ON orders.user_id = users.id");
    _ = b.where("users.id = ?1");
    _ = b.groupBy("users.id");
    _ = b.having("COUNT(orders.id) > ?2");
    _ = b.orderBy("users.id DESC");
    _ = b.limit(10);

    const sql = try b.toSql();
    defer allocator.free(sql);

    try std.testing.expectEqualStrings(
        "SELECT users.id, users.name FROM users INNER JOIN orders ON orders.user_id = users.id WHERE users.id = ?1 GROUP BY users.id HAVING COUNT(orders.id) > ?2 ORDER BY users.id DESC LIMIT 10",
        sql,
    );
}

test "sqlx builder batch insert" {
    const allocator = std.testing.allocator;
    const b = Builder.init(allocator, "users");

    const sql = try b.batchInsert(&.{ "name", "email" }, 3);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings("INSERT INTO users (name, email) VALUES (?1, ?2), (?3, ?4), (?5, ?6)", sql);
}

// The builder's emitters are one long string-append loop, so they have an
// allocation point per column, per row and per clause — and one place to lose
// the buffer. `checkAllAllocationFailures` walks every one of them: the
// statement must come back as `error.OutOfMemory` and the accumulator must be
// released, leaving the caller nothing to free.
test "sqlx builder batchInsert survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, cols: []const []const u8, rows: usize) !void {
            const b = Builder.init(alloc, "orders");
            const sql = try b.batchInsert(cols, rows);
            defer alloc.free(sql);
            // 4 columns × 3 rows: the last placeholder is ?12.
            try std.testing.expect(std.mem.endsWith(u8, sql, "(?9, ?10, ?11, ?12)"));
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{ &.{ "id", "user_id", "amount", "created_at" }, 3 });
}

// `toSql` is the same shape with more branches. The builder is filled in the
// scanned function (so the allocations behind it are injected into too) in the
// forms `selectColumns` / `join` / `where` / `groupBy` / `orderBy` produce:
// the column list is a single allocation with borrowed elements, the clause
// lists own their strings.
test "sqlx builder toSql survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(alloc: std.mem.Allocator, cols: []const []const u8, exprs: []const []const u8) !void {
            var b = Builder.init(alloc, "users");
            defer b.deinit();

            b.select_columns = try alloc.dupe([]const u8, cols);
            b.join_clauses = try dupeSqlClauses(alloc, exprs[0..1]);
            b.where_clauses = try dupeSqlClauses(alloc, exprs[1..3]);
            b.group_by_clause = try alloc.dupe(u8, exprs[3]);
            b.having_clause = try alloc.dupe(u8, exprs[4]);
            b.order_by_clause = try alloc.dupe(u8, exprs[5]);
            b.limit_val = 10;
            b.offset_val = 20;

            const sql = try b.toSql();
            defer alloc.free(sql);
            try std.testing.expectEqualStrings(
                "SELECT users.id, users.name FROM users INNER JOIN orders ON orders.user_id = users.id WHERE users.id = ?1 AND users.name = ?2 GROUP BY users.id HAVING COUNT(orders.id) > ?3 ORDER BY users.id DESC LIMIT 10 OFFSET 20",
                sql,
            );
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{
        &.{ "users.id", "users.name" },
        &.{
            "INNER JOIN orders ON orders.user_id = users.id",
            "users.id = ?1",
            "users.name = ?2",
            "users.id",
            "COUNT(orders.id) > ?3",
            "users.id DESC",
        },
    });
}

// The same statement, built through the public chain instead of by writing the
// fields: a failure at any link must surface (the scan fails with
// `SwallowedOutOfMemoryError` if one is ignored) and every clause already
// stored must still be released by `deinit` (`MemoryLeakDetected` if it is not).
test "sqlx builder chain survives every allocation point failing (OOM scan)" {
    const allocator = std.testing.allocator;

    const Scan = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var b = Builder.init(alloc, "users");
            defer b.deinit();

            _ = b.selectColumns(&.{ "users.id", "users.name" });
            _ = b.join("INNER JOIN orders ON orders.user_id = users.id");
            _ = b.where("users.id = ?1");
            _ = b.where("users.name = ?2");
            _ = b.groupBy("users.id");
            _ = b.having("COUNT(orders.id) > ?3");
            _ = b.orderBy("users.id DESC");
            _ = b.limit(10).offset(20);

            const sql = try b.toSql();
            defer alloc.free(sql);
            try std.testing.expectEqualStrings(
                "SELECT users.id, users.name FROM users INNER JOIN orders ON orders.user_id = users.id WHERE users.id = ?1 AND users.name = ?2 GROUP BY users.id HAVING COUNT(orders.id) > ?3 ORDER BY users.id DESC LIMIT 10 OFFSET 20",
                sql,
            );
        }
    };
    try std.testing.checkAllAllocationFailures(allocator, Scan.run, .{});
}

/// `Builder.deinit` frees the clause list's strings as well as the list, so a
/// half-filled list cannot be handed to the builder: every slot holds a valid
/// (empty) slice before the first copy can fail. Zero-length frees are no-ops,
/// which is what makes the unfilled slots safe to release.
fn dupeSqlClauses(alloc: std.mem.Allocator, exprs: []const []const u8) ![][]const u8 {
    const list = try alloc.alloc([]const u8, exprs.len);
    for (list) |*slot| slot.* = &.{};
    errdefer {
        for (list) |s| alloc.free(s);
        alloc.free(list);
    }
    for (list, exprs) |*slot, e| slot.* = try alloc.dupe(u8, e);
    return list;
}

/// `raw` must be rejected rather than built: a builder that emitted injected
/// SQL would leak the returned slice, so the test path frees it and fails.
fn expectSqlRejected(result: anyerror![]u8, expected_name: []const u8) !void {
    if (result) |sql| {
        std.testing.allocator.free(sql);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expectEqualStrings(expected_name, @errorName(err));
    }
}

test "sqlx builder gates identifiers and clauses" {
    const allocator = std.testing.allocator;

    var bad_table = Builder.init(allocator, "users; DROP TABLE users");
    defer bad_table.deinit();
    try expectSqlRejected(bad_table.toSql(), "InvalidSqlIdentifier");
    try expectSqlRejected(bad_table.count(null), "InvalidSqlIdentifier");
    try expectSqlRejected(bad_table.delete(), "InvalidSqlIdentifier");
    try expectSqlRejected(bad_table.select(&.{"name"}), "InvalidSqlIdentifier");
    try expectSqlRejected(bad_table.insert(&.{"name"}), "InvalidSqlIdentifier");

    var b = Builder.init(allocator, "users");
    defer b.deinit();
    try expectSqlRejected(b.insert(&.{"name) VALUES (1); --"}), "InvalidSqlIdentifier");
    try expectSqlRejected(b.batchInsert(&.{"a\"=1"}, 2), "InvalidSqlIdentifier");
    try expectSqlRejected(b.update(&.{"a\"=1"}), "InvalidSqlIdentifier");
    try expectSqlRejected((b.selectColumns(&.{"a\"=1"})).toSql(), "InvalidSqlIdentifier");

    // Clauses go through the fragment gate rather than the identifier one: a
    // statement separator is caught, while `id DESC` / `COUNT(x) > ?1` keep
    // building. A fresh builder per case — clauses accumulate.
    var bad_where = Builder.init(allocator, "users");
    defer bad_where.deinit();
    try expectSqlRejected((bad_where.where("id = 1; DROP TABLE users")).toSql(), "UnsafeSqlFragment");

    var bad_order = Builder.init(allocator, "users");
    defer bad_order.deinit();
    try expectSqlRejected((bad_order.orderBy("id; DROP TABLE users")).toSql(), "UnsafeSqlFragment");

    var ok = Builder.init(allocator, "users");
    defer ok.deinit();
    _ = ok.selectColumns(&.{"users.id"});
    _ = ok.where("users.id = ?1");
    _ = ok.groupBy("users.id");
    _ = ok.having("COUNT(orders.id) > ?2");
    _ = ok.orderBy("users.id DESC");

    const sql = try ok.toSql();
    defer allocator.free(sql);
    try std.testing.expectEqualStrings(
        "SELECT users.id FROM users WHERE users.id = ?1 GROUP BY users.id HAVING COUNT(orders.id) > ?2 ORDER BY users.id DESC",
        sql,
    );
}

/// Fails exactly one allocation — the `fail_at`-th `alloc`, then nothing else —
/// and lets every later call through.
///
/// `std.testing.FailingAllocator` cannot show the bug this looks for: once it
/// induces a failure, *every* later allocation fails too, so a chain that
/// swallowed its own `error.OutOfMemory` looks innocent — the builder's own
/// statement buffer then fails to allocate and the run ends in OOM anyway.
/// Failing one point and carrying on is what makes "the clause is missing"
/// distinguishable from "the failure was reported".
const FailOnceAllocator = struct {
    inner: std.mem.Allocator,
    fail_at: usize,
    calls: usize = 0,

    fn init(inner: std.mem.Allocator, fail_at: usize) FailOnceAllocator {
        return .{ .inner = inner, .fail_at = fail_at };
    }

    fn allocator(self: *FailOnceAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        const call = self.calls;
        self.calls += 1;
        if (call == self.fail_at) return null;
        return self.inner.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailOnceAllocator = @ptrCast(@alignCast(ctx));
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

// A chained clause is a *copy* of the caller's string, so recording it can
// fail — and a builder that drops the copy on the floor still emits a
// statement: one without the predicate. `tenant_id = ?1` missing from a
// `WHERE` is not a cosmetic difference, it is every tenant's rows.
//
// Every allocation index the chain plus `toSql` performs is failed in turn;
// either the statement comes back whole, or the failure is reported.
test "sqlx builder never drops a chained clause when an allocation fails" {
    const allocator = std.testing.allocator;

    const Chain = struct {
        const expected = "SELECT * FROM users WHERE tenant_id = ?1 ORDER BY id DESC";

        fn run(alloc: std.mem.Allocator, fail_at: usize) ![]u8 {
            var probe = FailOnceAllocator.init(alloc, fail_at);
            var b = Builder.init(probe.allocator(), "users");
            defer b.deinit();
            _ = b.where("tenant_id = ?1");
            _ = b.orderBy("id DESC");
            return b.toSql();
        }

        fn allocationCount(alloc: std.mem.Allocator) !usize {
            var probe = FailOnceAllocator.init(alloc, std.math.maxInt(usize));
            var b = Builder.init(probe.allocator(), "users");
            defer b.deinit();
            _ = b.where("tenant_id = ?1");
            _ = b.orderBy("id DESC");
            const sql = try b.toSql();
            alloc.free(sql);
            return probe.calls;
        }
    };

    const allocations = try Chain.allocationCount(allocator);
    // The clause copy, the clause list, the order-by copy, the statement buffer.
    try std.testing.expect(allocations >= 4);

    for (0..allocations) |fail_at| {
        if (Chain.run(allocator, fail_at)) |sql| {
            defer allocator.free(sql);
            try std.testing.expectEqualStrings(Chain.expected, sql);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }

    // Past the last allocation nothing is failed, so the whole statement — the
    // clause included — is the answer again.
    const whole = try Chain.run(allocator, allocations);
    defer allocator.free(whole);
    try std.testing.expectEqualStrings(Chain.expected, whole);
}

test "sqlite transaction commit" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var tx = try client.beginTx();
    const insert = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);
    try tx.commit();

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "Bob" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
}

test "sqlite transaction rollback" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var tx = try client.beginTx();
    _ = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Charlie" }});
    try tx.rollback();

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "Charlie" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), rows.rows.len);
}

test "failed transaction is re-pooled when ROLLBACK succeeds" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
        .max_wait_ms = 1000,
    });
    defer db.deinit();

    // The pool is created lazily by the first statement; take it afterwards.
    _ = try db.exec("CREATE TABLE t (v INTEGER)", &.{});
    const pool = &db.pool.?;
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_active);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_idle);

    const Fail = struct {
        fn run(tx: *Transaction) errors.ResultT(void) {
            // Business failure: the transaction is still healthy, so
            // `transact`'s error path rolls it back successfully.
            _ = try tx.exec("INSERT INTO t (v) VALUES (1)", &.{});
            return error.DatabaseError;
        }
    };
    try std.testing.expectError(error.DatabaseError, db.transact(void, Fail.run));

    // ROLLBACK succeeded, so the connection comes back to the pool as usual —
    // `transact` must not retire a connection that was cleaned up.
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_idle);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_active);
}

test "failed rollback retires the pooled connection instead of re-pooling it" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
        .max_wait_ms = 1000,
    });
    defer db.deinit();

    // The pool is created lazily by the first statement; take it afterwards.
    _ = try db.exec("CREATE TABLE t (v INTEGER)", &.{});
    const pool = &db.pool.?;
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_active);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_idle);

    var tx = try db.beginTx();
    // End the transaction out from under it: the ROLLBACK now fails ("cannot
    // rollback - no transaction is active"), leaving the connection's
    // transaction state unknown.
    _ = try tx.exec("COMMIT", &.{});
    try std.testing.expectError(error.DatabaseError, tx.rollback());

    // It must be closed, not put back into the idle pool for the next borrower.
    try std.testing.expectEqual(@as(u32, 0), pool.metrics().current_idle);
    try std.testing.expectEqual(@as(u32, 0), pool.metrics().current_active);

    // The pool recovers on the next checkout.
    const n = try db.queryRow(struct { n: i64 }, "SELECT 1 AS n", &.{});
    try std.testing.expectEqual(@as(i64, 1), n.n);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_active);
}

test "failed commit retires the pooled connection instead of re-pooling it" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
        .max_wait_ms = 1000,
    });
    defer db.deinit();

    _ = try db.exec("CREATE TABLE t (v INTEGER)", &.{});
    const pool = &db.pool.?;

    var tx = try db.beginTx();
    _ = try tx.exec("ROLLBACK", &.{});
    try std.testing.expectError(error.DatabaseError, tx.commit());

    try std.testing.expectEqual(@as(u32, 0), pool.metrics().current_idle);
    try std.testing.expectEqual(@as(u32, 0), pool.metrics().current_active);

    const n = try db.queryRow(struct { n: i64 }, "SELECT 1 AS n", &.{});
    try std.testing.expectEqual(@as(i64, 1), n.n);
}

test "sqlite queryRowPartial struct scan" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name, email) VALUES (?1, ?2)", &.{ .{ .string = "Alice" }, .{ .string = "alice@example.com" } });

    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // missing in DB, should be zeroed
    };

    const user = try client.queryRowPartial(PartialUser, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, PartialUser, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(usize, 0), user.bio.len);
}

test "sqlite queryRowBorrowed RAII arena borrow" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    // Borrowed variant: strings point into the wrapper-owned arena, freed
    // together by deinit — no freeScanned needed.
    var row = try client.queryRowBorrowed(User, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer row.deinit();
    const user = row.get();
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
}

test "sqlite queryRowPartialBorrowed zeroes missing columns" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // missing in DB, should be zeroed
    };

    var row = try client.queryRowPartialBorrowed(PartialUser, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer row.deinit();
    const user = row.get();
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(usize, 0), user.bio.len);
}

test "sqlite queryRowOwned alias has owned-string contract" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.queryRowOwned(User, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user); // owned → caller frees
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
}

test "typeHasStrings detects []const u8 fields" {
    const S = struct { a: i64, b: []const u8 };
    const N = struct { a: i64, b: i64 };
    const O = struct { a: ?[]const u8 };
    try std.testing.expect(typeHasStrings(S));
    try std.testing.expect(!typeHasStrings(N));
    try std.testing.expect(typeHasStrings(O));
    try std.testing.expect(!typeHasStrings(i64));
}

test "sqlite queryScalar returns value copy for string-free T" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE items (id INTEGER PRIMARY KEY, price INTEGER NOT NULL)", &.{});
    _ = try client.exec("INSERT INTO items (id, price) VALUES (?1, ?2)", &.{ .{ .int = 1 }, .{ .int = 100 } });

    const ItemRow = struct { id: i64, price: i64 };
    const val = try client.queryScalar(ItemRow, "SELECT id, price FROM items WHERE id = ?1", &.{.{ .int = 1 }});
    try std.testing.expect(val != null);
    try std.testing.expectEqual(@as(i64, 100), val.?.price);

    // NotFound → null, no freeing needed.
    try std.testing.expect((try client.queryScalar(ItemRow, "SELECT id, price FROM items WHERE id = ?1", &.{.{ .int = 999 }})) == null);
}

test "sqlite queryRow and queryRows struct scan" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const user = try client.queryRow(User, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);

    const users = try client.queryRows(User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer users.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), users.items.len);
    try std.testing.expectEqualStrings("Alice", users.items[0].name);
    try std.testing.expectEqualStrings("Bob", users.items[1].name);
}

test "sqlite transact helper" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    const affected = try client.transact(u64, struct {
        fn doTx(tx: *Transaction) errors.ResultT(u64) {
            const r = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "TxUser" }});
            return r.rows_affected;
        }
    }.doTx);
    try std.testing.expectEqual(@as(u64, 1), affected);

    var rows = try client.query("SELECT name FROM users WHERE name = ?1", &.{.{ .string = "TxUser" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
}

test "sqlite circuit breaker" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = "/nonexistent/path/bad.db" });
    defer client.deinit();

    var failures: u32 = 0;
    for (0..15) |_| {
        _ = client.query("SELECT 1", &.{}) catch {
            failures += 1;
        };
    }
    try std.testing.expectEqual(@as(u32, 15), failures);

    // After enough failures, circuit breaker should be open
    const err = client.query("SELECT 1", &.{}) catch |e| e;
    try std.testing.expectEqual(errors.Error.CircuitBreakerOpen, err);
}

test "sqlite connection pool" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 3, .max_idle_conns = 2 });
    defer client.deinit();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Bob" }});

    const User = struct {
        id: i64,
        name: []const u8,
    };

    const users = try client.queryRows(User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer users.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), users.items.len);

    // Transaction through pool
    const affected = try client.transact(u64, struct {
        fn doTx(tx: *Transaction) errors.ResultT(u64) {
            const r = try tx.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Charlie" }});
            return r.rows_affected;
        }
    }.doTx);
    try std.testing.expectEqual(@as(u64, 1), affected);
}

test "sqlite prepared statement" {
    const allocator = std.testing.allocator;
    // Unique per process — see the sibling note in DistributedTransaction.zig:
    // a fixed /tmp name lets two concurrent suite runs delete each other's db.
    var path_buf: [64]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&path_buf, "/tmp/zigzero_sqlx_stmt_test_{d}.db", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = db_path });
    defer {
        client.deinit();
        std.Io.Dir.cwd().deleteFile(std.testing.io, db_path) catch {};
    }

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    var stmt = try client.prepare("INSERT INTO users (name) VALUES (?1)");
    defer stmt.close();

    const r1 = try stmt.exec(&.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), r1.rows_affected);
    try std.testing.expectEqual(@as(i64, 1), r1.last_insert_id.?);

    const r2 = try stmt.exec(&.{.{ .string = "Bob" }});
    try std.testing.expectEqual(@as(u64, 1), r2.rows_affected);
    try std.testing.expectEqual(@as(i64, 2), r2.last_insert_id.?);

    var select_stmt = try client.prepare("SELECT id, name FROM users WHERE name = ?1");
    defer select_stmt.close();

    const User = struct {
        id: i64,
        name: []const u8,
    };

    var rows = try select_stmt.query(allocator, &.{.{ .string = "Alice" }});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const user = try rows.rows[0].scan(allocator, User);
    defer freeScanned(allocator, User, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
}

test "sqlx value" {
    const v = Value{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), v.int);
}

test "pgDecodeBinary scalars and uuid" {
    const allocator = std.testing.allocator;

    const b_true = try pgDecodeBinary(allocator, PgOid.bool_t, &[_]u8{1});
    try std.testing.expect(b_true.bool);

    var i2_buf: [2]u8 = undefined;
    std.mem.writeInt(i16, &i2_buf, -7, .big);
    const v_i2 = try pgDecodeBinary(allocator, PgOid.int2, &i2_buf);
    try std.testing.expectEqual(@as(i64, -7), v_i2.int);

    var i4_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &i4_buf, 123456, .big);
    const v_i4 = try pgDecodeBinary(allocator, PgOid.int4, &i4_buf);
    try std.testing.expectEqual(@as(i64, 123456), v_i4.int);

    var i8_buf: [8]u8 = undefined;
    std.mem.writeInt(i64, &i8_buf, 9_007_199_254_740_991, .big);
    const v_i8 = try pgDecodeBinary(allocator, PgOid.int8, &i8_buf);
    try std.testing.expectEqual(@as(i64, 9_007_199_254_740_991), v_i8.int);

    var f8_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &f8_buf, @as(u64, @bitCast(@as(f64, 3.5))), .big);
    const v_f8 = try pgDecodeBinary(allocator, PgOid.float8, &f8_buf);
    try std.testing.expectEqual(@as(f64, 3.5), v_f8.float);

    const text = try pgDecodeBinary(allocator, PgOid.text, "hello");
    defer allocator.free(text.string);
    try std.testing.expectEqualStrings("hello", text.string);

    const jsonb = try pgDecodeBinary(allocator, PgOid.jsonb, &[_]u8{ 1, '{', '}' });
    defer allocator.free(jsonb.string);
    try std.testing.expectEqualStrings("{}", jsonb.string);

    const uuid_bytes = [_]u8{ 0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4, 0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00 };
    const uuid = try pgDecodeBinary(allocator, PgOid.uuid, &uuid_bytes);
    defer allocator.free(uuid.string);
    try std.testing.expectEqualStrings("550e8400-e29b-41d4-a716-446655440000", uuid.string);

    // 2000-01-01 → days 0
    var date_buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &date_buf, 0, .big);
    const date = try pgDecodeBinary(allocator, PgOid.date, &date_buf);
    defer allocator.free(date.string);
    try std.testing.expectEqualStrings("2000-01-01", date.string);
}

test "pgDecodeNumeric integers" {
    const allocator = std.testing.allocator;

    // 123.45: ndigits=2, weight=0, sign=0, dscale=2
    // digit[0]=123 (10000^0), digit[1]=4500 (10000^-1)
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], 0, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0, .big); // sign (positive)
    std.mem.writeInt(u16, buf[6..8], 2, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 123, .big); // digit 0
    std.mem.writeInt(u16, buf[10..12], 4500, .big); // digit 1
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("123.45", v.string);
}

test "pgDecodeNumeric negative" {
    const allocator = std.testing.allocator;
    // -789: ndigits=1, weight=0, sign=0x4000, dscale=0
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], 0, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0x4000, .big); // sign (negative)
    std.mem.writeInt(u16, buf[6..8], 0, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 789, .big); // digit
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("-789", v.string);
}

test "pgDecodeNumeric large integer" {
    const allocator = std.testing.allocator;
    // 10000: ndigits=2, weight=1, sign=0, dscale=0
    // digits: 1, 0
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], 1, .big); // weight (=1 means 8 int digits before dot)
    std.mem.writeInt(u16, buf[4..6], 0, .big); // sign
    std.mem.writeInt(u16, buf[6..8], 0, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 1, .big); // digit 0
    std.mem.writeInt(u16, buf[10..12], 0, .big); // digit 1
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("10000", v.string);
}

test "pgDecodeNumeric pure fraction" {
    const allocator = std.testing.allocator;
    // 0.005: 0.005 = 50 * 10000^-1, so ndigits=1, weight=-1, sign=0, dscale=3
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big); // ndigits
    std.mem.writeInt(i16, buf[2..4], -1, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0, .big); // sign
    std.mem.writeInt(u16, buf[6..8], 3, .big); // dscale
    std.mem.writeInt(u16, buf[8..10], 50, .big); // digit = 50 (= 0.005 * 10000^1)
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("0.005", v.string);
}

test "pgDecodeNumeric NaN" {
    const allocator = std.testing.allocator;
    var buf: [8]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 0, .big); // ndigits = 0
    std.mem.writeInt(i16, buf[2..4], 0, .big); // weight
    std.mem.writeInt(u16, buf[4..6], 0xC000, .big); // sign = NaN
    std.mem.writeInt(u16, buf[6..8], 0, .big); // dscale
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("NaN", v.string);
}

test "pgDecodeNumeric 100000 base-10000 boundary" {
    const allocator = std.testing.allocator;
    // 100000: ndigits=2, weight=1, sign=0, dscale=0, digits=[10, 0]
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 10, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("100000", v.string);
}

test "pgDecodeNumeric 800000 base-10000 boundary" {
    const allocator = std.testing.allocator;
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 80, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("800000", v.string);
}

test "pgDecodeNumeric 1000000 base-10000 boundary" {
    const allocator = std.testing.allocator;
    // 1000000: ndigits=2, weight=1, digits=[100, 0]
    var buf: [12]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 2, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 100, .big);
    std.mem.writeInt(u16, buf[10..12], 0, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("1000000", v.string);
}

test "pgDecodeNumeric 100000 stripped (PG may drop trailing zero groups)" {
    // PG stores numeric in a compressed form that strips trailing zero base-10000
    // groups. 100000 = 10 * 10000^1 can be sent as ndigits=1, weight=1, digits=[10].
    // The decoder must pad "10" with 4 zeros to reach "100000".
    const allocator = std.testing.allocator;
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 10, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("100000", v.string);
}

test "pgDecodeNumeric 800000 stripped" {
    const allocator = std.testing.allocator;
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 80, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("800000", v.string);
}

test "pgDecodeNumeric 10000 stripped single digit" {
    const allocator = std.testing.allocator;
    var buf: [10]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], 1, .big);
    std.mem.writeInt(i16, buf[2..4], 1, .big);
    std.mem.writeInt(u16, buf[4..6], 0, .big);
    std.mem.writeInt(u16, buf[6..8], 0, .big);
    std.mem.writeInt(u16, buf[8..10], 1, .big);
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("10000", v.string);
}

test "pgDecodeNumeric exceeds former 256-byte stack buffer" {
    const allocator = std.testing.allocator;
    // 80 digit groups × 4 chars + sign + '.' + high dscale padding ≫ 256.
    const ndigits: i16 = 80;
    var buf: [8 + 80 * 2]u8 = undefined;
    std.mem.writeInt(i16, buf[0..2], ndigits, .big);
    std.mem.writeInt(i16, buf[2..4], ndigits - 1, .big); // weight → long integer part
    std.mem.writeInt(u16, buf[4..6], 0x4000, .big); // negative
    std.mem.writeInt(u16, buf[6..8], 40, .big); // dscale padding
    for (0..@as(usize, @intCast(ndigits))) |i| {
        std.mem.writeInt(u16, buf[8 + i * 2 ..][0..2], 1234, .big);
    }
    const v = try pgDecodeNumeric(allocator, &buf);
    defer allocator.free(v.string);
    try std.testing.expect(v.string.len > 256);
    try std.testing.expect(v.string[0] == '-');
}

test "bufPrintZ reserves byte for null terminator" {
    var buf: [4]u8 = undefined;
    // Fits in 3 payload bytes + 1 sentinel.
    const ok = try bufPrintZ(&buf, "{s}", .{"ab"});
    try std.testing.expectEqualStrings("ab", ok);
    try std.testing.expectEqual(@as(u8, 0), buf[2]);
    // Would need 4 payload bytes — must fail instead of writing past buf.
    try std.testing.expectError(error.NoSpaceLeft, bufPrintZ(&buf, "{s}", .{"abcd"}));
}

test "QueryResult.deinit frees strings once (arena=null path)" {
    const allocator = std.testing.allocator;
    const Tiny = struct { name: []const u8 };
    const name = try allocator.dupe(u8, "HS8529!"); // len 7 — matches production double-free size
    const items = try allocator.alloc(Tiny, 1);
    items[0] = .{ .name = name };
    var qr = QueryResult(Tiny){ .items = items, .arena = null };
    // Correct: deinit alone. Incorrect would be freeScanned then deinit (SIGABRT).
    qr.deinit(allocator);
}

test "Client circuit breaker is eager (no lazy ensureBreaker)" {
    var client = Client.init(std.testing.allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    // Must allow immediately — cb is fully initialized in init(), not on first query.
    try std.testing.expect(client.cb.allow(client.io));
    client.cb.recordFailure(client.io);
    try std.testing.expectEqual(@as(u32, 1), client.cb.failure_count);
}

test "Client.pool offset is before cb (SqlxBackend ABI claim)" {
    // pool precedes cb in source order; changing cb optionality cannot move pool.
    try std.testing.expect(@offsetOf(Client, "pool") < @offsetOf(Client, "cb"));
    // SqlxBackend is { allocator, *Client } — not an overlay on Client bytes.
    const Backend = @import("../persistence/backends/SqlxBackend.zig").SqlxBackend;
    try std.testing.expect(@sizeOf(Backend) < @sizeOf(Client));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Backend, "allocator"));
    try std.testing.expect(@offsetOf(Backend, "client") > 0);
}

test "pgDecodeInterval basic" {
    const allocator = std.testing.allocator;
    // 1 month, 2 days, 3:04:05.000006
    var buf: [16]u8 = undefined;
    const total_us: i64 = (3 * 3600 + 4 * 60 + 5) * 1_000_000 + 6;
    std.mem.writeInt(i64, buf[0..8], total_us, .big); // microseconds
    std.mem.writeInt(i32, buf[8..12], 2, .big); // days
    std.mem.writeInt(i32, buf[12..16], 1, .big); // months
    const v = try pgDecodeBinary(allocator, PgOid.interval, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("P1M2DT03:04:05.000006", v.string);
}

test "pgDecodeInterval time only" {
    const allocator = std.testing.allocator;
    // 0 months, 0 days, 12:30:45.0
    var buf: [16]u8 = undefined;
    const total_us: i64 = (12 * 3600 + 30 * 60 + 45) * 1_000_000;
    std.mem.writeInt(i64, buf[0..8], total_us, .big);
    std.mem.writeInt(i32, buf[8..12], 0, .big);
    std.mem.writeInt(i32, buf[12..16], 0, .big);
    const v = try pgDecodeBinary(allocator, PgOid.interval, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("12:30:45.000000", v.string);
}

test "pgDecodeTime basic" {
    const allocator = std.testing.allocator;
    // 23:59:59.123456
    var buf: [8]u8 = undefined;
    const us: i64 = (23 * 3600 + 59 * 60 + 59) * 1_000_000 + 123456;
    std.mem.writeInt(i64, buf[0..8], us, .big);
    const v = try pgDecodeBinary(allocator, PgOid.time, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("23:59:59.123456", v.string);
}

test "pgDecodeInet basic" {
    const allocator = std.testing.allocator;
    // 192.168.1.1/24
    var buf: [8]u8 = undefined;
    buf[0] = 2; // AF_INET
    buf[1] = 24; // prefix_len
    buf[2] = 0; // is_cidr = 0
    buf[3] = 4; // nbytes
    buf[4] = 192;
    buf[5] = 168;
    buf[6] = 1;
    buf[7] = 1;
    const v = try pgDecodeBinary(allocator, PgOid.inet, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("192.168.1.1/24", v.string);
}

test "pgDecodeCidr masking" {
    const allocator = std.testing.allocator;
    // 10.0.0.42/8 as CIDR → 10.0.0.0/8
    var buf: [8]u8 = undefined;
    buf[0] = 2; // AF_INET
    buf[1] = 8; // prefix_len
    buf[2] = 1; // is_cidr = 1
    buf[3] = 4; // nbytes
    buf[4] = 10;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 42;
    const v = try pgDecodeBinary(allocator, PgOid.cidr, &buf);
    defer allocator.free(v.string);
    try std.testing.expectEqualStrings("10.0.0.0/8", v.string);
}

test "postgres config init" {
    const cfg = Config{
        .driver = .postgres,
        .host = "localhost",
        .port = 5432,
        .database = "test",
        .username = "user",
        .password = "pass",
    };
    try std.testing.expectEqual(Driver.postgres, cfg.driver);
    try std.testing.expectEqual(@as(u16, 5432), cfg.port);
}

test "mysql config init" {
    const cfg = Config{
        .driver = .mysql,
        .host = "localhost",
        .port = 3306,
        .database = "test",
        .username = "user",
        .password = "pass",
    };
    try std.testing.expectEqual(Driver.mysql, cfg.driver);
    try std.testing.expectEqual(@as(u16, 3306), cfg.port);
}

test "postgres live connection" {
    try skipUnlessDb("postgres");
    const allocator = std.testing.allocator;

    // Support env overrides for CI and local dev
    const conninfo_default = "host=localhost port=5432 dbname=postgres user=cborli";
    const conninfo = if (builtin.os.tag == .windows) conninfo_default else if (std.c.getenv("PGconninfo")) |ptr| std.mem.span(ptr) else conninfo_default;

    var client = Client.init(allocator, std.testing.io, .{
        .driver = .postgres,
        .postgres_conninfo = conninfo,
    });
    defer client.deinit();

    try client.connect();
    try client.ping();

    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_users (id SERIAL PRIMARY KEY, name TEXT)", &.{});

    const insert = try client.exec("INSERT INTO zigzero_test_users (name) VALUES ($1)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);

    var rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = $1", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    if ((&rows.rows[0]).get("name")) |name_val| {
        const name_str = name_val.string;
        try std.testing.expectEqualStrings("Alice", name_str);
    } else return error.TestUnexpectedResult;

    var empty_rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = $1", &.{.{ .string = "NobodyHere" }});
    defer empty_rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_rows.rows.len);

    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{});
}

test "mysqlParseDecimal accepts valid MySQL decimal strings" {
    try std.testing.expectEqualStrings("1234567890123.4567", try mysqlParseDecimal("1234567890123.4567"));
    try std.testing.expectEqualStrings("-0.0001", try mysqlParseDecimal("-0.0001"));
    try std.testing.expectEqualStrings("+42.50", try mysqlParseDecimal("+42.50"));
    try std.testing.expectEqualStrings(".75", try mysqlParseDecimal(".75"));
    try std.testing.expectEqualStrings("100.", try mysqlParseDecimal("100."));
}

test "mysqlParseDecimal rejects invalid decimal strings" {
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal(""));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal("."));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal("abc"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDecimal("12a.34"));
}

test "mysqlParseDateTime accepts valid MySQL temporal strings" {
    try std.testing.expectEqualStrings("2024-03-15 14:30:00", try mysqlParseDateTime("2024-03-15 14:30:00"));
    try std.testing.expectEqualStrings("2024-03-15 14:30:00.123456", try mysqlParseDateTime("2024-03-15 14:30:00.123456"));
    try std.testing.expectEqualStrings("2024-03-15", try mysqlParseDateTime("2024-03-15"));
    try std.testing.expectEqualStrings("14:30:00", try mysqlParseDateTime("14:30:00"));
    try std.testing.expectEqualStrings("-14:30:00", try mysqlParseDateTime("-14:30:00"));
    try std.testing.expectEqualStrings("14:30:00.123", try mysqlParseDateTime("14:30:00.123"));
    try std.testing.expectEqualStrings("-14:30:00.123456", try mysqlParseDateTime("-14:30:00.123456"));
}

test "mysqlParseDateTime rejects invalid temporal strings" {
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime(""));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024/03/15"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("14-30-00"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("-2024-03-15"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024-03-15 14:30:00."));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024-03-15 14:30:00.1234567"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("2024-03-15 14:30:00x"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseDateTime("14:30:00."));
}

test "mysqlParseJson accepts valid MySQL JSON strings" {
    try std.testing.expectEqualStrings("{\"key\":\"value\"}", try mysqlParseJson("{\"key\":\"value\"}"));
    try std.testing.expectEqualStrings("[1,2,3]", try mysqlParseJson("[1,2,3]"));
    try std.testing.expectEqualStrings("null", try mysqlParseJson("null"));
    try std.testing.expectEqualStrings("true", try mysqlParseJson("true"));
    try std.testing.expectEqualStrings("42", try mysqlParseJson("42"));
    try std.testing.expectEqualStrings("  {\"a\":1}  ", try mysqlParseJson("  {\"a\":1}  "));
    try std.testing.expectEqualStrings("\"hello\"", try mysqlParseJson("\"hello\""));
    try std.testing.expectEqualStrings("-3.14", try mysqlParseJson("-3.14"));
}

test "mysqlParseJson rejects invalid JSON strings" {
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson(""));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("not json"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("{\"a\":1"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("42e"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("1.2.3"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("++1"));
    try std.testing.expectError(error.InvalidFormat, mysqlParseJson("--1"));
}

test "mysql live connection" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;

    const host_default = "127.0.0.1";
    const host = if (builtin.os.tag == .windows) host_default else if (std.c.getenv("MYSQL_HOST")) |ptr| std.mem.span(ptr) else host_default;
    const user_default = "root";
    const user = if (builtin.os.tag == .windows) user_default else if (std.c.getenv("MYSQL_USER")) |ptr| std.mem.span(ptr) else user_default;
    const pass_default = "";
    const pass = if (builtin.os.tag == .windows) pass_default else if (std.c.getenv("MYSQL_PASSWORD")) |ptr| std.mem.span(ptr) else pass_default;
    const db_default = "zigzero_test";
    const db = if (builtin.os.tag == .windows) db_default else if (std.c.getenv("MYSQL_DATABASE")) |ptr| std.mem.span(ptr) else db_default;
    // The port is read for the same reason the other four are: a service reached
    // through a container's published port (or a second server next to a local
    // one) is the normal case, and a hardcoded 3306 makes the live suite
    // unrunnable there.
    const port_default: u16 = 3306;
    const port: u16 = blk: {
        if (builtin.os.tag == .windows) break :blk port_default;
        const raw = std.c.getenv("MYSQL_PORT") orelse break :blk port_default;
        break :blk std.fmt.parseInt(u16, std.mem.span(raw), 10) catch port_default;
    };

    var client = Client.init(allocator, std.testing.io, .{
        .driver = .mysql,
        .host = host,
        .port = port,
        .database = db,
        .username = user,
        .password = pass,
    });
    defer client.deinit();

    try client.connect();
    try client.ping();

    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))", &.{});

    const insert = try client.exec("INSERT INTO zigzero_test_users (name) VALUES (?)", &.{.{ .string = "Alice" }});
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);

    var rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = ?", &.{.{ .string = "Alice" }});
    defer rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    if ((&rows.rows[0]).get("name")) |name_val| {
        // Deliberately not freed: the string belongs to `rows`' arena (the
        // driver duplicates scanned values into it), and `rows.deinit()` is its
        // release. `allocator.free` here is a mismatched free — it used to panic
        // with `free of invalid memory ... len: 5` ("Alice"), which went
        // unnoticed only because the statement-metadata crash above it aborted
        // the test before this line ever ran.
        try std.testing.expectEqualStrings("Alice", name_val.string);
    } else return error.TestUnexpectedResult;

    // Empty SELECT: libmysql may return NULL from mysql_store_result with errno==0; must not be DatabaseError.
    var empty_rows = try client.query("SELECT id, name FROM zigzero_test_users WHERE name = ?", &.{.{ .string = "NobodyHere" }});
    defer empty_rows.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_rows.rows.len);

    var empty_stmt = try client.prepare("SELECT id, name FROM zigzero_test_users WHERE name = ?");
    defer empty_stmt.close();
    var empty_prepared = try empty_stmt.query(allocator, &.{.{ .string = "NobodyHere" }});
    defer empty_prepared.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_prepared.rows.len);

    // DECIMAL / DATETIME / JSON round-trip via prepared statement binary protocol.
    _ = client.exec("DROP TABLE IF EXISTS zigzero_test_types", &.{}) catch {};
    _ = try client.exec("CREATE TABLE zigzero_test_types (id INT AUTO_INCREMENT PRIMARY KEY, amount DECIMAL(19,4), created_at DATETIME, payload JSON)", &.{});

    const insert_types = try client.exec("INSERT INTO zigzero_test_types (amount, created_at, payload) VALUES (?, ?, ?)", &.{
        .{ .string = "1234567890123.4567" },
        .{ .string = "2024-03-15 14:30:00" },
        .{ .string = "{\"key\":\"value\",\"num\":42}" },
    });
    try std.testing.expectEqual(@as(u64, 1), insert_types.rows_affected);

    var type_rows = try client.query("SELECT amount, created_at, payload FROM zigzero_test_types WHERE id = ?", &.{.{ .int = insert_types.last_insert_id.? }});
    defer type_rows.deinit();

    try std.testing.expectEqual(@as(usize, 1), type_rows.rows.len);
    const type_row = &type_rows.rows[0];

    const amount_val = type_row.get("amount") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("1234567890123.4567", try mysqlParseDecimal(amount_val.string));

    const created_val = type_row.get("created_at") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("2024-03-15 14:30:00", try mysqlParseDateTime(created_val.string));

    const payload_val = type_row.get("payload") orelse return error.TestUnexpectedResult;
    const payload_str = try mysqlParseJson(payload_val.string);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "\"key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "\"num\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload_str, "42") != null);

    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_types", &.{});
    _ = try client.exec("DROP TABLE IF EXISTS zigzero_test_users", &.{});
}

test "sqlite conn interface lifecycle" {
    const allocator = std.testing.allocator;

    // Conn.close() expects heap-allocated SQLiteConn, so allocate on heap
    const sqlite = try allocator.create(SQLiteConn);
    sqlite.* = try SQLiteConn.open(allocator, ":memory:");
    var conn = sqlite.toConn();

    // Ping should succeed
    try conn.ping();

    // Create table through Conn interface
    const create = try conn.exec("CREATE TABLE lifecycle_test (id INTEGER PRIMARY KEY)", &.{});
    try std.testing.expectEqual(@as(u64, 0), create.rows_affected);

    // Transaction commit through Conn interface
    try conn.begin();
    const insert = try conn.exec("INSERT INTO lifecycle_test (id) VALUES (1)", &.{});
    try std.testing.expectEqual(@as(i64, 1), insert.last_insert_id.?);
    try conn.commit();

    // Transaction rollback through Conn interface
    try conn.begin();
    _ = try conn.exec("INSERT INTO lifecycle_test (id) VALUES (2)", &.{});
    try conn.rollback();

    // Verify only committed row exists
    var rows = try conn.query(allocator, "SELECT id FROM lifecycle_test", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    try std.testing.expectEqual(@as(i64, 1), (&rows.rows[0]).get("id").?.int);

    // Close connection (this frees the heap-allocated SQLiteConn)
    conn.close();
}

test "sqlite batchExec and batchInsert helpers" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});

    const batch = [_][]const Value{
        &.{ .{ .int = 1 }, .{ .string = "Alice" } },
        &.{ .{ .int = 2 }, .{ .string = "Bob" } },
        &.{ .{ .int = 3 }, .{ .string = "Carol" } },
    };
    const results = try client.batchExec("INSERT INTO users (id, name) VALUES (?1, ?2)", &batch);
    defer allocator.free(results);
    try std.testing.expectEqual(@as(usize, 3), results.len);

    const batch2 = [_][]const Value{
        &.{ .{ .int = 4 }, .{ .string = "Dave" } },
        &.{ .{ .int = 5 }, .{ .string = "Eve" } },
    };
    const insert = try client.batchInsert("users", &.{ "id", "name" }, &batch2);
    try std.testing.expectEqual(@as(u64, 2), insert.rows_affected);

    var rows = try client.queryCursor("SELECT id, name FROM users ORDER BY id", &.{});
    defer rows.deinit();
    var count: usize = 0;
    while (try rows.next()) |row| {
        _ = (&row.*).get("id").?.int;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), count);
}

test "sqlite Row.get caches repeated lookups" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (a INTEGER, b TEXT)", &.{});
    _ = try client.exec("INSERT INTO t (a, b) VALUES (1, 'x')", &.{});

    var rows = try client.query("SELECT a, b FROM t", &.{});
    defer rows.deinit();
    var row = rows.rows[0];
    try std.testing.expectEqual(@as(i64, 1), row.get("a").?.int);
    try std.testing.expectEqual(@as(i64, 1), row.get("a").?.int);
    try std.testing.expectEqualStrings("x", row.get("b").?.string);
}

test "sqlite deferred transaction option" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (id INTEGER)", &.{});
    _ = try client.exec("INSERT INTO t (id) VALUES (1)", &.{});

    var tx = try client.beginTxOpts(.{ .deferred = true });
    defer tx.rollback() catch {};
    const n = try tx.queryRow(allocator, struct { id: i64 }, "SELECT id FROM t", &.{});
    try std.testing.expectEqual(@as(i64, 1), n.id);
}

test "sqlite CachedConn respects TTL expiration" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO t (id, name) VALUES (1, 'Alice')", &.{});

    var cache = StringCache.init(allocator);
    defer cache.deinit();

    const User = struct { id: i64, name: []const u8 };
    var cached = CachedConn{ .allocator = allocator, .client = &client, .local_cache = &cache, .ttl_sec = 0 };

    const user1 = try cached.queryRow(User, "u:1", "SELECT id, name FROM t WHERE id = 1", &.{});
    defer freeScanned(allocator, User, user1);
    try std.testing.expectEqualStrings("Alice", user1.name);

    _ = try client.exec("UPDATE t SET name = 'Bob' WHERE id = 1", &.{});
    const user2 = try cached.queryRow(User, "u:1", "SELECT id, name FROM t WHERE id = 1", &.{});
    defer freeScanned(allocator, User, user2);
    try std.testing.expectEqualStrings("Alice", user2.name);
}

test "cached conn treats an undecodable cache entry as a miss, not a query failure" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO t (id, name) VALUES (1, 'Alice')", &.{});

    var cache = StringCache.init(allocator);
    defer cache.deinit();
    var cached = CachedConn{ .allocator = allocator, .client = &client, .local_cache = &cache, .ttl_sec = 60 };

    // An entry the current row shape cannot decode — bytes written for an older
    // `User`, or corruption. It is not expired, so `StringCache` hands it back
    // verbatim and the read path has to decide what that means.
    try cache.set("u:1", "{\"id\":1,\"nickname\":\"Al", 60);

    const User = struct { id: i64, name: []const u8 };
    const row = try cached.queryRow(User, "u:1", "SELECT id, name FROM t WHERE id = 1", &.{});
    defer freeScanned(allocator, User, row);
    try std.testing.expectEqualStrings("Alice", row.name);

    // The read also repaired the entry: the arguments below match no row, so
    // `Alice` can only come back from the cache — the same hit evidence the
    // cache tests above use.
    const again = try cached.queryRow(User, "u:1", "SELECT id, name FROM t WHERE id = ?1", &.{.{ .int = 999 }});
    defer freeScanned(allocator, User, again);
    try std.testing.expectEqualStrings("Alice", again.name);
}

test "cached conn reports a cache decode allocation failure as OutOfMemory" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO t (id, name) VALUES (1, 'Alice')", &.{});

    var cache = StringCache.init(allocator);
    defer cache.deinit();
    const User = struct { id: i64, name: []const u8 };
    const sql = "SELECT id, name FROM t WHERE id = 1";

    // Valid JSON for `User`, so anything that fails below failed in the
    // allocator and not on the blob's shape. The `StringCache` itself is built
    // on the real allocator (`get`/`set` use their own), so the walk lands on
    // the two allocations `CachedConn` owns here: the decode and the copy-out.
    try cache.set("u:1", "{\"id\":1,\"name\":\"Alice\"}", 60);

    var idx: usize = 0;
    var oom_failures: usize = 0;
    var succeeded = false;
    while (idx < 16) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = idx, .resize_fail_index = 0 });
        var cached = CachedConn{ .allocator = failing.allocator(), .client = &client, .local_cache = &cache, .ttl_sec = 60 };
        const row = cached.queryRow(User, "u:1", sql, &.{}) catch |err| {
            // A decode that could not allocate is this process running out of
            // memory, not a failed query: reporting it as `error.DatabaseError`
            // hides the resource failure from the error mapping and sends the
            // caller looking at the database.
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
            oom_failures += 1;
            continue;
        };
        freeScanned(allocator, User, row);
        succeeded = true;
    }
    try std.testing.expect(oom_failures > 0);
    try std.testing.expect(succeeded);
}

test "sqlite connection pool warmup" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 4,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.warmPool();

    // Warmup should have created up to max_idle idle connections.
    try std.testing.expect(db.pool != null);
    try std.testing.expect(db.pool.?.idle.items.len > 0);
    // Back-pointer must address the final Client, not a moved temporary.
    try std.testing.expectEqual(@intFromPtr(&db), @intFromPtr(db.pool.?.client));
}

test "conn pool rebinds client pointer after value move" {
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 3,
        .max_idle_conns = 1,
    });
    defer db.deinit();
    db.warmPool();
    try std.testing.expect(db.pool != null);

    // Simulate open()-by-value leave-behind: pool.client points at a dead address.
    db.pool.?.client = @ptrFromInt(0x70);
    db.ensurePool();
    try std.testing.expectEqual(@intFromPtr(&db), @intFromPtr(db.pool.?.client));
}

// `active` counts the connections the pool *owns* — checked out and idle alike —
// because that is what `acquire` compares against `max_open` before opening
// another one. A release-to-idle therefore keeps the slot counted and a
// reacquire off the idle list does not increment it: the number is stable
// across a borrow/return cycle, and `current_active` reads the pool's
// high-water mark of open connections rather than the in-flight count. The
// in-flight reading is the difference to `current_idle`. Changing this to a
// borrowing counter would move the cap check off `active` (it would then admit
// up to `max_open` *checked-out* connections plus whatever sits idle).
test "conn pool active counts open connections, not only checked-out ones" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 4,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.warmPool();
    const pool = &db.pool.?;

    // Warmed but unused: two open connections, both idle, none in flight.
    const warmed = pool.metrics();
    try std.testing.expectEqual(@as(u32, 2), warmed.current_active);
    try std.testing.expectEqual(@as(u32, 2), warmed.current_idle);

    // Check one out — the slot was already counted, so `active` does not move.
    const conn = try pool.acquire();
    const checked_out = pool.metrics();
    try std.testing.expectEqual(@as(u32, 2), checked_out.current_active);
    try std.testing.expectEqual(@as(u32, 1), checked_out.current_idle);

    // Give it back: same number, one idle connection more.
    pool.release(conn);
    const released = pool.metrics();
    try std.testing.expectEqual(@as(u32, 2), released.current_active);
    try std.testing.expectEqual(@as(u32, 2), released.current_idle);
}

test "conn pool evicts idle connection after timeout" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.warmPool();

    try std.testing.expect(db.pool != null);
    const before = db.pool.?.metrics();
    try std.testing.expectEqual(@as(u32, 2), before.current_idle);
    try std.testing.expectEqual(@as(u64, 0), before.total_evicted_idle);

    // Use a 1 ms idle threshold and wait long enough for the warmed-up
    // connections to exceed it before invoking keepAlive().
    db.pool.?.max_idle_time_ms = 1;
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};

    db.pool.?.keepAlive();

    const after = db.pool.?.metrics();
    try std.testing.expectEqual(@as(u32, 0), after.current_idle);
    try std.testing.expectEqual(@as(u64, 2), after.total_evicted_idle);
}

test "conn pool thread smoke" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 4,
        .max_idle_conns = 0,
        .max_wait_ms = 5000,
    });
    defer db.deinit();
    db.warmPool();

    const pool = &db.pool.?;

    const Worker = struct {
        fn run(p: *ConnPool) void {
            const c = p.acquire() catch return;
            p.release(c);
        }
    };

    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{pool});
    }
    for (&threads) |*t| {
        t.join();
    }
}

test "conn pool release hands off to waiters in FIFO order" {
    const allocator = std.testing.allocator;

    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 0,
        .max_wait_ms = 5000,
    });
    defer db.deinit();
    db.warmPool();

    const pool = &db.pool.?;
    const conn_a = try pool.acquire();
    const conn_b = try pool.acquire();

    // Simulate a FIFO wait queue directly. Each release() must hand the
    // connection to the oldest waiter and set its ready flag.
    var waiters: [3]ConnPool.Waiter = undefined;
    for (&waiters) |*w| {
        w.* = .{ .cond = .init, .ready = false, .conn = undefined };
        try pool.waiters.append(allocator, w);
    }
    defer {
        // Remove the dummy waiters so pool deinit sees an empty queue.
        pool.waiters.items.len = 0;
    }

    try std.testing.expectEqual(@as(usize, 3), pool.waiters.items.len);

    pool.release(conn_a);
    try std.testing.expect(waiters[0].ready);
    try std.testing.expect(!waiters[1].ready);
    try std.testing.expect(!waiters[2].ready);

    pool.release(conn_b);
    try std.testing.expect(waiters[1].ready);
    try std.testing.expect(!waiters[2].ready);

    // Close the connections that were handed to the dummy waiters so the
    // pool's active count and the test allocator stay consistent.
    waiters[0].conn.close();
    waiters[1].conn.close();
}

test "canceled pool waiter keeps a connection already handed to it" {
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 0,
        .max_wait_ms = 1000,
    });
    defer db.deinit();
    db.warmPool();
    const pool = &db.pool.?;

    const conn = try pool.acquire();
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_active);

    // `release` writes the hand-off into the waiter (`ready` + `conn`) *before*
    // signalling, so a cancelation can arrive with `ready` set. That connection
    // is the waiter's at that point: dropping it on cancel would neither close
    // it nor re-pool it, and `active` would never come down — one pool slot
    // lost per canceled wait.
    var waiter: ConnPool.Waiter = .{ .cond = .init, .ready = false, .conn = undefined };
    try pool.waiters.append(allocator, &waiter);
    pool.release(conn);
    try std.testing.expect(waiter.ready);

    const handed = pool.cancelWaiter(&waiter);
    try std.testing.expect(handed != null);
    try std.testing.expectEqual(@as(usize, 0), pool.waiters.items.len);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_active);

    // The other half: a waiter that was never handed anything owns nothing.
    var empty: ConnPool.Waiter = .{ .cond = .init, .ready = false, .conn = undefined };
    try pool.waiters.append(allocator, &empty);
    try std.testing.expect(pool.cancelWaiter(&empty) == null);
    try std.testing.expectEqual(@as(usize, 0), pool.waiters.items.len);

    // Give it back: the connection goes through normal pool accounting
    // (max_idle_conns = 0 → closed, active back to zero).
    pool.release(handed.?);
    const after = pool.metrics();
    try std.testing.expectEqual(@as(u32, 0), after.current_active);
    try std.testing.expectEqual(@as(u32, 0), after.current_idle);
}

test "sqlite buffered cursor iterates rows" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE cur (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try db.exec("INSERT INTO cur (name) VALUES (?), (?), (?)", &.{ Value{ .string = "a" }, Value{ .string = "b" }, Value{ .string = "c" } });

    var cursor = try db.queryCursor("SELECT id, name FROM cur ORDER BY id", &.{});
    defer cursor.deinit();

    var count: usize = 0;
    while (try cursor.next()) |row| {
        count += 1;
        const id = row.get("id").?.int;
        const name = row.get("name").?.string;
        try std.testing.expectEqual(@as(i64, @intCast(count)), id);
        try std.testing.expect(name.len == 1);
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "sqlite streaming cursor falls back to buffered" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE cur2 (id INTEGER PRIMARY KEY)", &.{});
    _ = try db.exec("INSERT INTO cur2 VALUES (1), (2)", &.{});
    var cursor = try db.queryCursorEx("SELECT id FROM cur2 ORDER BY id", &.{}, .{ .mode = .streaming });
    defer cursor.deinit();
    try std.testing.expect((try cursor.next()).?.get("id").?.int == 1);
    try std.testing.expect((try cursor.next()).?.get("id").?.int == 2);
    try std.testing.expect(try cursor.next() == null);
}

// Real-server coverage for the two things a streaming cursor can get wrong
// that no sqlite test can reach: sqlite is served buffered, so `PgCursor` /
// `MySqlCursor` rows and their failures only exist against a live server.
//
// Gating follows both conventions already in this tree: `DB=postgres` (the CI
// `test-postgres` job, same as this file's other live-PG tests) or
// `ZIGMODU_TEST_PG=1` (the opt-in the other real-database tests use — and the
// only one that survives `scripts/test-fast.sh`, which owns `DB`).
//
// The queries are shaped so the server streams rows and *then* fails:
// `100 / (3 - i)` is computable for i = 1, 2 and raises SQLSTATE 22012
// (division by zero) at i = 3, so the failure genuinely arrives mid-result.
// Red evidence, taken on the pre-fix code with a probe that could compile
// against `next() ?*Row`:
//
//     [red] row 1: values.len=1
//     [red] row 2: values.len=1
//     [red] loop ended with no error after 2 row(s); the query has 5 and the server raises at row 3
//     expected 5, found 2
//
// i.e. the documented `while (cursor.next()) |row|` loop reported a truncated
// result set as a complete one.
test "streaming PG cursor reports a mid-stream server error instead of ending the result" {
    const opt_in = if (std.c.getenv("ZIGMODU_TEST_PG")) |v| !std.mem.eql(u8, std.mem.span(v), "0") else false;
    if (!opt_in) try skipUnlessDb("postgres");
    if (!DriverFeatures.postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const conninfo_default = "host=127.0.0.1 port=5432 dbname=postgres user=postgres";
    const conninfo = if (builtin.os.tag == .windows) conninfo_default else if (std.c.getenv("PGconninfo")) |ptr| std.mem.span(ptr) else conninfo_default;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .postgres, .postgres_conninfo = conninfo });
    defer db.deinit();
    try db.connect();

    {
        // A streaming row that reads at all: `values` and the column names come
        // from two different lifetimes inside the cursor, and the names used to
        // be freed by the arena reset at the top of `next` — every row then
        // carried a dangling `columns` slice, which is what `row.get("col")`
        // walks. (Red on the pre-fix code: reading `columns[0]` below aborted
        // with `FAULT` on freed memory, in this query, with no error involved.)
        var ok_cursor = try db.queryCursorEx(
            "SELECT i * 10 AS q FROM generate_series(1, 3) AS i",
            &.{},
            .{ .mode = .streaming },
        );
        defer ok_cursor.deinit();
        const ok_row = (try ok_cursor.next()).?;
        try std.testing.expectEqual(@as(usize, 1), ok_row.values.len);
        try std.testing.expectEqualStrings("q", ok_row.columns[0]);
        // PG streams in text format, where every cell is a string (`pgReadCell`
        // keeps it that way on purpose, for `scanStruct`); the point here is
        // that the cell *decodes*, not which union member it lands in.
        try std.testing.expectEqualStrings("10", ok_row.get("q").?.string);
        try std.testing.expectEqualStrings("20", (try ok_cursor.next()).?.get("q").?.string);
        try std.testing.expectEqualStrings("30", (try ok_cursor.next()).?.get("q").?.string);
        try std.testing.expectEqual(@as(?*Row, null), try ok_cursor.next());
    }

    var cursor = try db.queryCursorEx(
        "SELECT 100 / (3 - i) AS q FROM generate_series(1, 5) AS i",
        &.{},
        .{ .mode = .streaming },
    );
    defer cursor.deinit();
    try std.testing.expect(cursor.isStreaming());

    // The rows the server can produce are real rows: the failure arrives after
    // them, not instead of them.
    try std.testing.expectEqualStrings("50", (try cursor.next()).?.get("q").?.string);
    try std.testing.expectEqualStrings("100", (try cursor.next()).?.get("q").?.string);
    // And here the server raises. `22012` has no dedicated member in the
    // SQLSTATE table, so it maps to the generic driver failure — the same
    // mapping the acquisition path would apply to the same statement.
    try std.testing.expectError(error.DatabaseError, cursor.next());
    // `Cursor.next` does not only return the error: the cursor books it against
    // the client that handed it out, on the same filter and the same
    // once-per-attempt rule the acquisition path uses (`Cursor.bookFailure`).
    // The statement never ran, so nothing else has counted it.
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);
}

// The other half of the same contract: a stream that broke mid-result must not
// leave the client unusable. `deinit` drains whatever is left and either
// re-pools the connection or retires it, and the very next statement on the
// same client has to work.
test "pooled client stays usable after a streaming cursor fails mid-result" {
    const opt_in = if (std.c.getenv("ZIGMODU_TEST_PG")) |v| !std.mem.eql(u8, std.mem.span(v), "0") else false;
    if (!opt_in) try skipUnlessDb("postgres");
    if (!DriverFeatures.postgres) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const conninfo_default = "host=127.0.0.1 port=5432 dbname=postgres user=postgres";
    const conninfo = if (builtin.os.tag == .windows) conninfo_default else if (std.c.getenv("PGconninfo")) |ptr| std.mem.span(ptr) else conninfo_default;
    var db = Client.init(allocator, std.testing.io, .{
        .driver = .postgres,
        .postgres_conninfo = conninfo,
        .max_open_conns = 2,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.ensurePool();
    try db.connect();
    const pool = &db.pool.?;

    var cursor = try db.queryCursorEx(
        "SELECT 100 / (3 - i) AS q FROM generate_series(1, 5) AS i",
        &.{},
        .{ .mode = .streaming },
    );
    try std.testing.expectEqualStrings("50", (try cursor.next()).?.get("q").?.string);
    // Same statement as the test above: two rows, then the server raises on
    // the third (`100 / (3 - 3)`).
    try std.testing.expectEqualStrings("100", (try cursor.next()).?.get("q").?.string);
    try std.testing.expectError(error.DatabaseError, cursor.next());
    cursor.deinit();

    // The checkout came back exactly once, so the next borrower gets a usable
    // connection rather than this query's leftover frames.
    const m = pool.metrics();
    try std.testing.expectEqual(m.total_acquired, m.total_released);
    const after = try db.queryRow(struct { n: i64 }, "SELECT ?1 AS n", &.{.{ .int = 42 }});
    defer freeScanned(allocator, @TypeOf(after), after);
    try std.testing.expectEqual(@as(i64, 42), after.n);
}

// The MySQL half of the same two contracts. It is a separate server and a
// separate driver, so the PG tests above prove nothing about it: `MySqlCursor`
// reads its error slot with `mysql_errno` (libpq reports through the result
// status), and its rows are built from `mysql_fetch_row` +
// `mysql_fetch_lengths` (libpq hands the cells over pre-parsed).
//
// Not covered below: the `mysql_fetch_lengths` NULL guard in the same function.
// The C API documents that call as returning NULL only when the fetch before it
// failed, and every path into the guard sits behind a fetch that succeeded — no
// live statement was found that reaches it, so it is a guard, not a tested
// branch. Saying so is the point: the null deref it replaced is fixed either
// way, but the branch itself has no red evidence behind it.
//
// The mid-result failure is a scalar subquery that returns two rows, reached
// only from the third row of the series: the projection raises
// ER_SUBQUERY_NO_1_ROW (1242) *while the result is streaming*, after the first
// two rows are already on the wire. Divisor-based shapes do not work here —
// `ERROR_FOR_DIVISION_BY_ZERO` is set on this server and `SELECT 100/(3-i)`
// still yields `NULL` for i = 3 with no error, so the division-by-zero shape
// the PG test uses is not a mid-stream failure on MySQL at all.
//
// `--quick` is `mysql_use_result`, the same incremental protocol `MySqlCursor`
// uses, which is what makes "two rows, then the error" a property of this
// statement rather than of the client library's buffering:
//
//     $ mysql --quick -h 127.0.0.1 -P 3306 -u root -e "<the SELECT below>"
//     i   q
//     1   1
//     2   2
//     ERROR 1242 (21000) at line 1: Subquery returns more than 1 row
//
// Red evidence, taken against the pre-fix `next` with only its error slot
// removed (the branch folded back into `return null`, signature unchanged).
// Line numbers in the transcripts below are from the file as it stood during
// the probe, before the comment you are reading existed:
//
//     $ DB=mysql zig build test -Ddb=all -Dtest-filter="mysql streaming" -Dtest-force-run=true
//     185/1661 sqlx.sqlx.test.mysql streaming cursor reports a mid-stream server error instead of ending the result...expected error.DatabaseError, found null
//     FAIL (TestExpectedError)
//     src/sqlx/sqlx.zig:8788:9: in test.mysql streaming cursor reports a mid-stream server error...
//         try std.testing.expectError(error.DatabaseError, cursor.next());
//
// i.e. the truncated result set ended the loop after two rows and no error.

/// Connection settings for the live MySQL streaming tests below — the same five
/// environment variables, and the same defaults, as `test "mysql live
/// connection"`. A function because four tests share the block, and four hand
/// copies of it is how the host/port/defaults drift apart.
fn mysqlLiveConfig() Config {
    const Env = struct {
        fn get(comptime name: [:0]const u8) ?[]const u8 {
            if (builtin.os.tag == .windows) return null;
            const raw = std.c.getenv(name.ptr) orelse return null;
            return std.mem.span(raw);
        }
    };
    const port: u16 = blk: {
        const raw = Env.get("MYSQL_PORT") orelse break :blk 3306;
        break :blk std.fmt.parseInt(u16, raw, 10) catch 3306;
    };
    return .{
        .driver = .mysql,
        .host = Env.get("MYSQL_HOST") orelse "127.0.0.1",
        .port = port,
        .username = Env.get("MYSQL_USER") orelse "root",
        .password = Env.get("MYSQL_PASSWORD") orelse "",
        .database = Env.get("MYSQL_DATABASE") orelse "zigzero_test",
    };
}

const mysql_midstream_sql =
    "SELECT i, CASE WHEN i = 3 THEN (SELECT 1 UNION ALL SELECT 2) ELSE i END AS q" ++
    " FROM (SELECT 1 AS i UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4) t";

test "mysql streaming cursor reports a mid-stream server error instead of ending the result" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, mysqlLiveConfig());
    defer client.deinit();
    try client.connect();

    {
        var cursor = try client.queryCursorEx(mysql_midstream_sql, &.{}, .{ .mode = .streaming });
        defer cursor.deinit();
        try std.testing.expect(cursor.isStreaming());

        // The rows the server could produce before the failure are real rows ...
        const first = (try cursor.next()).?;
        try std.testing.expectEqualStrings("1", first.get("q").?.string);
        const second = (try cursor.next()).?;
        try std.testing.expectEqualStrings("2", second.get("q").?.string);
        // ... and here the server raises, one row short of the series' fourth
        // row. 1242 has no dedicated member in `mysqlErrnoToError`, so it lands
        // on the generic driver failure — the same mapping the acquisition path
        // applies to the same statement. Before this change the two rows above
        // were the whole result: the `while (cursor.next()) |row|` loop ended
        // quietly and reported a truncated result set as a complete one.
        try std.testing.expectError(error.DatabaseError, cursor.next());
    }

    // Scoped so the cursor gave its connection back before the next statement:
    // this is the pool-less path, where the connection is the client's own and
    // a broken stream leaves its mark on `self.conn` rather than on a pool
    // slot. The driver's error slot is per-command, so the next statement on
    // the same connection has to succeed rather than inherit the failure.
    const after = try client.queryRow(struct { n: i64 }, "SELECT 42 AS n", &.{});
    try std.testing.expectEqual(@as(i64, 42), after.n);
}

test "mysql streaming cursor keeps column names alive across rows" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, mysqlLiveConfig());
    defer client.deinit();
    try client.connect();

    var cursor = try client.queryCursorEx(
        "SELECT i AS alpha, i * 10 AS beta FROM (SELECT 1 AS i UNION ALL SELECT 2 UNION ALL SELECT 3) t",
        &.{},
        .{ .mode = .streaming },
    );
    defer cursor.deinit();

    // A streaming row that reads at all: `values` and the column names come
    // from two different lifetimes inside the cursor. The names used to be
    // allocated in the row arena — the one `next` resets at its top — and that
    // reset runs *before* the fetch, so by the time the first row was handed
    // out its `columns` slice already pointed at freed memory. `row.get("col")`
    // walks that slice on the way to the values, which is why this test reads
    // the names off every row rather than just the first: it pins the new
    // lifetime ("one set per result set") rather than a single offset that
    // happens to survive. Red evidence, taken with the reset restored to the
    // top of `next` (the pre-fix lifetime); line numbers are from the file as
    // it stood during the probe:
    //
    //     $ DB=mysql zig build test -Ddb=all \
    //         -Dtest-filter="mysql streaming cursor keeps column names alive" -Dtest-force-run=true
    //     ...mysql streaming cursor keeps column names alive across rows...Segmentation fault at address 0x5555555555555555
    //       std/mem.zig:909:40 in findDiff
    //       std/testing.zig:669:25 in expectEqualStrings
    //       src/sqlx/sqlx.zig:8833:39 in test.mysql streaming cursor keeps column names alive across rows
    //         try std.testing.expectEqualStrings("alpha", first.columns[0]);
    const first = (try cursor.next()).?;
    try std.testing.expectEqual(@as(usize, 2), first.columns.len);
    try std.testing.expectEqualStrings("alpha", first.columns[0]);
    try std.testing.expectEqualStrings("beta", first.columns[1]);
    try std.testing.expectEqualStrings("1", first.get("alpha").?.string);
    try std.testing.expectEqualStrings("10", first.get("beta").?.string);

    const second = (try cursor.next()).?;
    try std.testing.expectEqualStrings("alpha", second.columns[0]);
    try std.testing.expectEqualStrings("beta", second.columns[1]);
    try std.testing.expectEqualStrings("2", second.get("alpha").?.string);
    try std.testing.expectEqualStrings("20", second.get("beta").?.string);

    const third = (try cursor.next()).?;
    try std.testing.expectEqualStrings("alpha", third.columns[0]);
    try std.testing.expectEqualStrings("3", third.get("alpha").?.string);
    try std.testing.expectEqualStrings("30", third.get("beta").?.string);

    try std.testing.expectEqual(@as(?*Row, null), try cursor.next());
}

test "mysql pooled client stays usable after a streaming cursor fails mid-result" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    var cfg = mysqlLiveConfig();
    cfg.max_open_conns = 2;
    cfg.max_idle_conns = 2;
    var db = Client.init(allocator, std.testing.io, cfg);
    defer db.deinit();
    db.ensurePool();
    try db.connect();
    const pool = &db.pool.?;

    var cursor = try db.queryCursorEx(mysql_midstream_sql, &.{}, .{ .mode = .streaming });
    try std.testing.expectEqualStrings("1", (try cursor.next()).?.get("q").?.string);
    try std.testing.expectEqualStrings("2", (try cursor.next()).?.get("q").?.string);
    // Same statement as the test above: two rows, then the server raises.
    try std.testing.expectError(error.DatabaseError, cursor.next());
    cursor.deinit();

    // 1242 is a *server* error on an otherwise healthy socket, so `deinit`'s
    // `ping` succeeds and the connection goes back to the pool rather than
    // being retired — acquired and released must still balance.
    const m = pool.metrics();
    try std.testing.expectEqual(m.total_acquired, m.total_released);
    const after = try db.queryRow(struct { n: i64 }, "SELECT 42 AS n", &.{});
    try std.testing.expectEqual(@as(i64, 42), after.n);
}

// A mid-result failure is a failed *read attempt*, and the cursor is the only
// party that sees it — the caller gets the error and nothing else happens. The
// acquisition path books exactly this class of event (`queryCursorExPrimary`
// counts every failure `isAcceptable` rejects), so the same statement dying at
// row 3 was invisible: metrics untouched, and the breaker never learned that
// this client cannot serve the read. Replica routing reads that breaker.
//
// The pooled client is the case `deinit`'s ping cannot cover: 1242 is a
// server-side error, so the socket stays healthy and the drain books nothing.
test "mysql streaming cursor books a mid-stream failure against its client's breaker" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, mysqlLiveConfig());
    defer db.deinit();
    try db.connect();
    try std.testing.expectEqual(@as(u32, 0), db.cb.failure_count);

    var cursor = try db.queryCursorEx(mysql_midstream_sql, &.{}, .{ .mode = .streaming });
    try std.testing.expectEqualStrings("1", (try cursor.next()).?.get("q").?.string);
    try std.testing.expectEqualStrings("2", (try cursor.next()).?.get("q").?.string);
    try std.testing.expectError(error.DatabaseError, cursor.next());
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);

    // One failed attempt, one count: `deinit` drains and pings the same
    // connection, and that drain must not book the break a second time.
    cursor.deinit();
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);
}

// The same contract on the path that has no pool at all: `max_open_conns = 1`
// keeps the connection on the `Client`, so `Cursor.deinit` has no checkout to
// inspect and `next` is the only place this failure can ever be counted.
test "mysql single-connection cursor books a mid-stream failure too" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    var cfg = mysqlLiveConfig();
    cfg.max_open_conns = 1;
    var client = Client.init(allocator, std.testing.io, cfg);
    defer client.deinit();
    try client.connect();
    try std.testing.expect(client.pool == null);

    var cursor = try client.queryCursorEx(mysql_midstream_sql, &.{}, .{ .mode = .streaming });
    try std.testing.expectEqualStrings("1", (try cursor.next()).?.get("q").?.string);
    try std.testing.expectEqualStrings("2", (try cursor.next()).?.get("q").?.string);
    try std.testing.expectError(error.DatabaseError, cursor.next());
    try std.testing.expectEqual(@as(u32, 1), client.cb.failure_count);
    cursor.deinit();

    // The connection outlives the broken stream: the next statement on it still
    // works, and its success resets the count as any successful read would.
    const after = try client.queryRow(struct { n: i64 }, "SELECT 42 AS n", &.{});
    try std.testing.expectEqual(@as(i64, 42), after.n);
    try std.testing.expectEqual(@as(u32, 0), client.cb.failure_count);
}

// The buffered MySQL read path is where every non-cursor MySQL query lands
// (`MySqlConn.queryFn` builds its `Rows` in a caller-owned arena and does
// `errdefer arena.deinit()`), and its *allocation* failures used to be folded
// into `error.DatabaseError` — the name the driver also uses for a statement
// the server rejected. The row buffer is built in that arena, so an allocation
// failure there is a process problem, not a database one, and `Error.zig`'s
// taxonomy says so explicitly ("OutOfMemory … Produced by `toErrorContext` and
// by `src/sqlx/sqlx.zig` (arena/dupe failures while scanning rows)").
//
// Driving the function directly is what makes the failure injectable: the
// arena is the caller's, so a `FailingAllocator` under it fails the *first*
// row-buffer allocation while the statement and its result handle are real
// (`MySqlConn.connect` + `mysql_real_query`, the same two calls `queryFn`
// makes). Through `Client.query` there is no seam — the client owns the
// allocator — and a failure at *connect* time would be the only reachable one.
test "mysql buffered read reports an allocation failure as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const cfg = mysqlLiveConfig();
    var raw = try MySqlConn.connect(allocator, cfg.host, cfg.username, cfg.password, cfg.database, cfg.port);
    defer {
        raw.stmt_cache.deinit();
        libmysql_c.mysql_close(raw.mysql);
    }

    const sql = "SELECT 1 AS a, 2 AS b";
    try std.testing.expectEqual(@as(c_int, 0), libmysql_c.mysql_real_query(raw.mysql, @ptrCast(sql.ptr), @intCast(sql.len)));

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var arena = std.heap.ArenaAllocator.init(failing.allocator());
    defer arena.deinit();
    try std.testing.expectError(error.OutOfMemory, mysqlReadRowsAfterQuery(raw.mysql, arena));
    try std.testing.expect(failing.has_induced_failure);

    // The error unwinds through the `defer mysql_free_result` in that function,
    // so the connection is idle on the wire again rather than holding a
    // half-consumed result — the next statement on it must work.
    try std.testing.expectEqual(@as(c_int, 0), libmysql_c.mysql_real_query(raw.mysql, @ptrCast(sql.ptr), @intCast(sql.len)));
    const res = libmysql_c.mysql_store_result(raw.mysql) orelse return error.DatabaseError;
    defer libmysql_c.mysql_free_result(res);
    try std.testing.expectEqual(@as(c_ulonglong, 1), libmysql_c.mysql_num_rows(res));
}

/// Minimal `Conn` whose `ping`/`close` are observable — enough to drive
/// `Cursor.deinit`'s checkout handling without a live driver.
const CursorTestConn = struct {
    closed: bool = false,
    healthy: bool = true,
    pings: usize = 0,
};

fn cursorTestQuery(_: *anyopaque, _: std.mem.Allocator, _: []const u8, _: []const Value) errors.ResultT(Rows) {
    return error.DatabaseError;
}

fn cursorTestExec(_: *anyopaque, _: []const u8, _: []const Value) errors.ResultT(ExecResult) {
    return error.DatabaseError;
}

fn cursorTestUnit(_: *anyopaque) errors.Result {
    return error.DatabaseError;
}

fn cursorTestPrepare(_: *anyopaque, _: std.mem.Allocator, _: []const u8) errors.ResultT(Stmt) {
    return error.DatabaseError;
}

fn cursorTestPing(ptr: *anyopaque) errors.Result {
    const state: *CursorTestConn = @ptrCast(@alignCast(ptr));
    state.pings += 1;
    if (!state.healthy) return error.DatabaseError;
}

fn cursorTestClose(ptr: *anyopaque) void {
    const state: *CursorTestConn = @ptrCast(@alignCast(ptr));
    state.closed = true;
}

const cursor_test_vtable = Conn.VTable{
    .query = cursorTestQuery,
    .exec = cursorTestExec,
    .close = cursorTestClose,
    .ping = cursorTestPing,
    .begin = cursorTestUnit,
    .commit = cursorTestUnit,
    .rollback = cursorTestUnit,
    .prepare = cursorTestPrepare,
};

/// A `.streaming` cursor as the drivers build it, except the driver half is
/// inert (`conn = null`) so the checkout half can be exercised on its own.
/// `owner` is what `Client.doQueryCursor` would have set: the client whose
/// breaker a use-phase failure is counted against.
fn testStreamingCursor(state: *CursorTestConn, pool: *ConnPool, allocator: std.mem.Allocator, owner: ?*Client) Cursor {
    return .{
        .state = .{ .streaming_pg = .{
            .conn = null,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .columns_arena = std.heap.ArenaAllocator.init(allocator),
            .columns = &.{},
            .row = undefined,
            .current = null,
            .eof = true,
        } },
        .checkout = .{ .pool = pool, .conn = .{ .ptr = state, .vtable = &cursor_test_vtable } },
        .owner = owner,
    };
}

test "cursor deinit returns its pooled connection or retires a broken one" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.ensurePool();
    const pool = &db.pool.?;

    // While a streaming cursor is alive its connection is *its own*: nobody
    // else may be handed the same socket with rows still on it.
    var state = CursorTestConn{};
    var cursor = testStreamingCursor(&state, pool, allocator, &db);
    try std.testing.expect(cursor.isStreaming());
    try std.testing.expectEqual(@as(u64, 0), pool.metrics().total_released);
    try std.testing.expectEqual(@as(u32, 0), pool.metrics().current_idle);

    // `deinit` drains the stream (driver half), then hands the connection back
    // exactly once.
    cursor.deinit();
    try std.testing.expectEqual(@as(u64, 1), pool.metrics().total_released);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_idle);
    try std.testing.expectEqual(@as(usize, 1), state.pings);
    try std.testing.expect(!state.closed);

    // A stream that broke while draining must be retired, not re-pooled: its
    // protocol state is unknown, so the next borrower would read this query's
    // leftover frames.
    var dead = CursorTestConn{ .healthy = false };
    var dead_cursor = testStreamingCursor(&dead, pool, allocator, &db);
    dead_cursor.deinit();
    try std.testing.expect(dead.closed);
    try std.testing.expectEqual(@as(u32, 1), pool.metrics().current_idle);
}

test "sqlite pooled client stays usable after a cursor is abandoned early" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.ensurePool();
    const pool = &db.pool.?;

    // sqlite has no incremental step here, so a `.streaming` request is served
    // buffered — the cursor owns no wire stream and says so.
    var cur = try db.queryCursorEx("SELECT ?1 AS n", &.{.{ .int = 7 }}, .{ .mode = .streaming });
    try std.testing.expect(!cur.isStreaming());
    try std.testing.expectEqual(@as(i64, 7), (try cur.next()).?.get("n").?.int);
    cur.deinit();

    // Abandon a cursor mid-iteration, then keep using the same client.
    var abandoned = try db.queryCursor("SELECT ?1 AS n", &.{.{ .int = 1 }});
    try std.testing.expect((try abandoned.next()) != null);
    abandoned.deinit();

    const after = try db.queryRow(struct { n: i64 }, "SELECT ?1 AS n", &.{.{ .int = 42 }});
    defer freeScanned(allocator, @TypeOf(after), after);
    try std.testing.expectEqual(@as(i64, 42), after.n);

    // Every checkout came back exactly once — no leaked pool slot.
    const m = pool.metrics();
    try std.testing.expectEqual(m.total_acquired, m.total_released);
}

/// Counts `MetricsCallback` invocations. A read path that never calls the
/// callback is invisible to HTTP/SQL metrics no matter how healthy it is, so
/// the tests below pin the *observability* of the cursor path, not just its
/// return values.
const MetricsRecorder = struct {
    var ok_calls: usize = 0;
    var fail_calls: usize = 0;
    var last_err: ?[]const u8 = null;

    fn reset() void {
        ok_calls = 0;
        fail_calls = 0;
        last_err = null;
    }

    fn record(_: u64, _: []const u8, ok: bool, err_msg: ?[]const u8) void {
        if (ok) {
            ok_calls += 1;
        } else {
            fail_calls += 1;
            last_err = err_msg;
        }
    }
};

test "cursor path reports metrics and breaker state like the query path" {
    const allocator = std.testing.allocator;
    MetricsRecorder.reset();

    // (1) A cursor handed out successfully is a successful read.
    {
        var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
        defer db.deinit();
        db.withMetrics(MetricsRecorder.record);
        var cursor = try db.queryCursor("SELECT ?1 AS n", &.{.{ .int = 1 }});
        defer cursor.deinit();
        try std.testing.expectEqual(@as(i64, 1), (try cursor.next()).?.get("n").?.int);
        try std.testing.expectEqual(@as(usize, 1), MetricsRecorder.ok_calls);
        try std.testing.expectEqual(@as(usize, 0), MetricsRecorder.fail_calls);
        try std.testing.expectEqual(@as(u32, 0), db.cb.failure_count);
    }

    // (2) An acquisition that fails is a failed read — the same event shape
    // `query` books, in metrics *and* in the breaker.
    //
    // The failure used is pool exhaustion (`max_wait_ms = 0`), not a bad
    // statement: a driver error would be logged at `err` level, and this
    // suite's runner treats any logged error as a failed run. Both slots are
    // taken before the first cursor call, so the pool cannot serve the checkout
    // from idle — nothing may be released in between, since a released
    // connection would satisfy the next acquire.
    var db = Client.init(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
        .max_wait_ms = 0,
    });
    defer db.deinit();
    db.ensurePool();
    const pool = &db.pool.?;
    db.withMetrics(MetricsRecorder.record);
    const held_a = try pool.acquire();
    defer pool.release(held_a);
    const held_b = try pool.acquire();
    defer pool.release(held_b);

    try std.testing.expectError(error.Timeout, db.queryCursor("SELECT ?1 AS n", &.{.{ .int = 2 }}));
    try std.testing.expectEqual(@as(usize, 1), MetricsRecorder.fail_calls);
    try std.testing.expectEqualStrings("Timeout", MetricsRecorder.last_err.?);
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);

    try std.testing.expectError(error.Timeout, db.query("SELECT ?1 AS n", &.{.{ .int = 2 }}));
    try std.testing.expectEqual(@as(usize, 2), MetricsRecorder.fail_calls);
    try std.testing.expectEqual(@as(u32, 2), db.cb.failure_count);

    // (3) The acceptance filter is honoured on both paths: an error it allows
    // is reported to metrics but not counted by the breaker. Assigned directly
    // rather than through `Client.withAcceptable`, whose `SqlOption` closure
    // cannot read the filter out of its enclosing frame (see the replica
    // fallback test above).
    const AcceptTimeout = struct {
        fn f(err: anyerror) bool {
            return err == error.Timeout;
        }
    };
    db.acceptable = AcceptTimeout.f;
    try std.testing.expectError(error.Timeout, db.queryCursor("SELECT ?1 AS n", &.{.{ .int = 3 }}));
    try std.testing.expectEqual(@as(usize, 3), MetricsRecorder.fail_calls);
    try std.testing.expectEqualStrings("Timeout", MetricsRecorder.last_err.?);
    try std.testing.expectEqual(@as(u32, 2), db.cb.failure_count);

    try std.testing.expectError(error.Timeout, db.query("SELECT ?1 AS n", &.{.{ .int = 3 }}));
    try std.testing.expectEqual(@as(usize, 4), MetricsRecorder.fail_calls);
    try std.testing.expectEqual(@as(u32, 2), db.cb.failure_count);

    // (4) The `allow()` gate still comes first, as it does for `query`: an open
    // breaker rejects without emitting a metrics event.
    for (0..5) |_| db.cb.recordFailure(db.io);
    const before = MetricsRecorder.fail_calls;
    try std.testing.expectError(error.CircuitBreakerOpen, db.queryCursor("SELECT ?1 AS n", &.{.{ .int = 4 }}));
    try std.testing.expectEqual(before, MetricsRecorder.fail_calls);
}

test "cursor deinit books a broken stream against the owning client's breaker" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.ensurePool();
    const pool = &db.pool.?;

    // A cursor that ends cleanly leaves the breaker alone.
    var state = CursorTestConn{};
    var cursor = testStreamingCursor(&state, pool, allocator, &db);
    cursor.deinit();
    try std.testing.expectEqual(@as(u32, 0), db.cb.failure_count);

    // A stream that broke while draining is a read failure: the connection is
    // retired (see the checkout test) *and* the attempt is counted, so a client
    // whose cursors keep breaking trips its breaker instead of looping.
    var dead = CursorTestConn{ .healthy = false };
    var dead_cursor = testStreamingCursor(&dead, pool, allocator, &db);
    dead_cursor.deinit();
    try std.testing.expect(dead.closed);
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);
}

test "cursor counts one failed attempt per broken stream, not one per sighting" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{
        .driver = .sqlite,
        .sqlite_path = ":memory:",
        .max_open_conns = 2,
        .max_idle_conns = 2,
    });
    defer db.deinit();
    db.ensurePool();
    const pool = &db.pool.?;

    // Both ends of the cursor can see the same break: `next` reports it from the
    // driver (`bookFailure` is what it calls on the way out) and the drain's
    // `ping` then fails as well, because the break that killed the fetch is what
    // took the connection with it. That is one failed read attempt, not two —
    // the no-double-count rule the acquisition path states as "exactly once per
    // failed attempt".
    //
    // Driven through `bookFailure` rather than through a live server because the
    // two halves have to be staged together: the live MySQL tests cover the
    // wiring (`next` returning a driver error against a *healthy* socket, where
    // no ping ever fails), and this covers the composition the wire cannot
    // produce on demand.
    var dead = CursorTestConn{ .healthy = false };
    var cursor = testStreamingCursor(&dead, pool, allocator, &db);
    cursor.bookFailure(error.DatabaseError);
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);
    cursor.deinit();
    try std.testing.expect(dead.closed);
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);

    // The acceptance filter applies here exactly as it does at acquisition: an
    // error the filter allows is not a failure, so neither the fetch half nor
    // the drain half may count it.
    const AcceptAll = struct {
        fn f(_: anyerror) bool {
            return true;
        }
    };
    db.acceptable = AcceptAll.f;
    var allowed_state = CursorTestConn{};
    var allowed = testStreamingCursor(&allowed_state, pool, allocator, &db);
    allowed.bookFailure(error.DatabaseError);
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);
    allowed.deinit();
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);

    // A cursor nobody handed out (`owner = null`, e.g. one a caller assembled
    // from `Cursor.init`) has no breaker to count against, and says so instead
    // of guessing one from the checkout.
    var orphan = Cursor.init(.{ .arena = std.heap.ArenaAllocator.init(allocator), .rows = &.{} });
    orphan.bookFailure(error.DatabaseError);
    try std.testing.expectEqual(@as(u32, 1), db.cb.failure_count);
    orphan.deinit();
}

test "libpq cancel bindings link and answer without a server" {
    if (!DriverFeatures.postgres) return error.SkipZigTest;
    // The cancel path itself needs a live server, but the bindings can be
    // exercised — and their symbols resolved out of the linked libpq — with no
    // server at all: `PQgetCancel(NULL)` returns NULL by contract, `PQfreeCancel`
    // is a bare `free` (NULL-safe), and `PQcancel(NULL, …)` takes libpq's "no
    // cancel object supplied" branch, writing the message into `errbuf` and
    // returning 0 without touching the network (fe-cancel.c).
    try std.testing.expect(libpq_c.PQgetCancel(null) == null);
    libpq_c.PQfreeCancel(null);

    var errbuf: [PG_CANCEL_ERRBUF_SIZE]u8 = @splat(0);
    try std.testing.expect(libpq_c.PQcancel(null, &errbuf, PG_CANCEL_ERRBUF_SIZE) == 0);
    // The stub (postgres disabled) would leave the buffer untouched, so a
    // written byte is what shows the call reached real libpq. The text itself
    // is libpq's and may change; only "it wrote something" is asserted.
    try std.testing.expect(errbuf[0] != 0);
}

test "mysql streaming cursor api compiles" {
    // Requires a live MySQL server; kept as a compile-time/API smoke test.
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .mysql, .host = "127.0.0.1", .user = "root", .password = "", .database = "test" });
    defer db.deinit();
    var cursor = try db.queryCursorEx("SELECT 1 AS n", &.{});
    defer cursor.deinit();
    _ = try cursor.next();
}

test "postgres streaming cursor api compiles" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .postgres, .host = "127.0.0.1", .user = "postgres", .password = "", .database = "test" });
    defer db.deinit();
    var cursor = try db.queryCursorEx("SELECT 1 AS n", &.{}, .{ .mode = .streaming });
    defer cursor.deinit();
    _ = try cursor.next();
}

test "sqlite batchInsertEx sql mode matches batchInsert" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE batch (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    const res = try db.batchInsertEx("batch", &.{ "id", "name" }, &.{
        &.{ Value{ .int = 1 }, Value{ .string = "a" } },
        &.{ Value{ .int = 2 }, Value{ .string = "b" } },
    }, .{ .mode = .sql });
    try std.testing.expectEqual(@as(u64, 2), res.rows_affected);
}

test "sqlite batchInsertEx protocol mode routes to sql" {
    const allocator = std.testing.allocator;
    var db = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer db.deinit();
    try db.connect();
    _ = try db.exec("CREATE TABLE batch2 (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    const res = try db.batchInsertEx("batch2", &.{ "id", "name" }, &.{
        &.{ Value{ .int = 1 }, Value{ .string = "a" } },
        &.{ Value{ .int = 2 }, Value{ .string = "b" } },
    }, .{ .mode = .protocol });
    try std.testing.expectEqual(@as(u64, 2), res.rows_affected);
}

test "mysql batchInsertEx protocol mode api compiles" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .mysql, .host = "127.0.0.1", .user = "root", .password = "", .database = "test" });
    defer db.deinit();
    _ = try db.batchInsertEx("t", &.{"c"}, &.{
        &.{Value{ .int = 1 }},
    }, .{ .mode = .protocol });
}

test "postgres batchInsertEx protocol mode api compiles" {
    if (true) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var db = try Client.open(allocator, std.testing.io, .{ .driver = .postgres, .host = "127.0.0.1", .user = "postgres", .password = "", .database = "test" });
    defer db.deinit();
    _ = try db.batchInsertEx("t", &.{"c"}, &.{
        &.{Value{ .int = 1 }},
    }, .{ .mode = .protocol });
}

test "mysql batch insert failure closes the prepared statement exactly once" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;

    const Env = struct {
        fn get(comptime name: [:0]const u8) ?[]const u8 {
            if (builtin.os.tag == .windows) return null;
            const raw = std.c.getenv(name.ptr) orelse return null;
            return std.mem.span(raw);
        }
    };
    const port: u16 = blk: {
        const raw = Env.get("MYSQL_PORT") orelse break :blk 3306;
        break :blk std.fmt.parseInt(u16, raw, 10) catch 3306;
    };

    var client = Client.init(allocator, std.testing.io, .{
        .driver = .mysql,
        .host = Env.get("MYSQL_HOST") orelse "127.0.0.1",
        .port = port,
        .username = Env.get("MYSQL_USER") orelse "root",
        .password = Env.get("MYSQL_PASSWORD") orelse "",
        .database = Env.get("MYSQL_DATABASE") orelse "zigzero_test",
    });
    defer client.deinit();
    try client.connect();

    _ = client.exec("DROP TABLE IF EXISTS zm_stmt_close_probe", &.{}) catch |e| std.log.debug("[test] drop probe table: {}", .{e});
    defer _ = client.exec("DROP TABLE IF EXISTS zm_stmt_close_probe", &.{}) catch |e| std.log.debug("[test] drop probe table: {}", .{e});
    _ = try client.exec("CREATE TABLE zm_stmt_close_probe (id INT PRIMARY KEY, v VARCHAR(32))", &.{});
    _ = try client.exec("INSERT INTO zm_stmt_close_probe (id, v) VALUES (1, 'first')", &.{});

    const rows = [_][]const Value{
        &.{ Value{ .int = 2 }, Value{ .string = "ok" } },
        &.{Value{ .int = 3 }}, // one value for two columns
    };
    // The second row's arity is wrong, so `batchInsertPrepared` returns an error
    // after the statement was prepared and the first row was executed — the
    // error return where the statement must still be closed exactly once. The
    // old code had an `errdefer` *and* a `defer` live for the same MYSQL_STMT
    // here, and closed it twice (double free on the driver's heap).
    try std.testing.expectError(error.DatabaseError, client.batchInsertEx("zm_stmt_close_probe", &.{ "id", "v" }, &rows, .{ .mode = .protocol }));

    // The connection is still usable, and only the first (well-formed) row of
    // the failed protocol batch landed.
    const n = try client.queryRow(struct { n: i64 }, "SELECT COUNT(*) AS n FROM zm_stmt_close_probe", &.{});
    try std.testing.expectEqual(@as(i64, 2), n.n);
}

test "diagnosePostgres handles null result and missing error fields safely" {
    const diag_null = diagnosePostgres(null);
    try std.testing.expectEqual(@as(i32, 0), diag_null.code);
    try std.testing.expectEqualStrings("", diag_null.message);
    try std.testing.expect(diag_null.constraint == null);
    try std.testing.expect(diag_null.table == null);
    try std.testing.expect(diag_null.column == null);
}

test "convertPlaceholders maps ? and ?N to sequential $N" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "SELECT * FROM users WHERE username = ?1", .want = "SELECT * FROM users WHERE username = $1" },
        .{ .in = "INSERT INTO t (a, b) VALUES (?1, ?2)", .want = "INSERT INTO t (a, b) VALUES ($1, $2)" },
        .{ .in = "SELECT * FROM t WHERE a = ? AND b = ?2 AND c = ?", .want = "SELECT * FROM t WHERE a = $1 AND b = $2 AND c = $3" },
        .{ .in = "UPDATE t SET a = ?12 WHERE id = ?", .want = "UPDATE t SET a = $1 WHERE id = $2" },
        .{ .in = "SELECT * FROM t WHERE x = ?", .want = "SELECT * FROM t WHERE x = $1" },
        .{ .in = "SELECT * FROM t", .want = "SELECT * FROM t" },
    };
    for (cases) |case| {
        // `null` = nothing to rewrite, and then the input is what the driver
        // gets; only an allocation failure leaves through the error channel.
        const maybe_got = try PostgresConn.convertPlaceholders(allocator, case.in);
        defer {
            if (maybe_got) |got| allocator.free(got);
        }
        try std.testing.expectEqualStrings(case.want, maybe_got orelse case.in);
    }
}

test "convertPlaceholders skips ? inside literals and comments" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "SELECT 'it''s ? fine' AS s, ? AS p", .want = "SELECT 'it''s ? fine' AS s, $1 AS p" },
        .{ .in = "SELECT \"col?\" FROM t WHERE x = ?", .want = "SELECT \"col?\" FROM t WHERE x = $1" },
        .{ .in = "SELECT 1 -- ? comment\nWHERE x = ?", .want = "SELECT 1 -- ? comment\nWHERE x = $1" },
        .{ .in = "SELECT 1 /* ? block */ WHERE x = ?", .want = "SELECT 1 /* ? block */ WHERE x = $1" },
        .{ .in = "SELECT '?', 'a''b?c' WHERE x = ?1", .want = "SELECT '?', 'a''b?c' WHERE x = $1" },
    };
    for (cases) |case| {
        const maybe_got = try PostgresConn.convertPlaceholders(allocator, case.in);
        defer {
            if (maybe_got) |got| allocator.free(got);
        }
        try std.testing.expectEqualStrings(case.want, maybe_got orelse case.in);
    }
}

test "sqlite transaction queryRowPartial zeroes missing columns" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();

    try client.connect();
    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name) VALUES (?1)", &.{.{ .string = "Alice" }});

    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // missing in DB, should be zeroed
    };

    var tx = try client.beginTx();
    defer tx.rollback() catch {};
    const user = try tx.queryRowPartial(allocator, PartialUser, "SELECT id, name FROM users WHERE name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, PartialUser, user);
    try std.testing.expectEqual(@as(i64, 1), user.id);
    try std.testing.expectEqualStrings("Alice", user.name);
    try std.testing.expectEqual(@as(usize, 0), user.bio.len);
}

// Compile-time checklist for Client ⇄ Transaction parity. `Client` had a
// large scan/find surface while `Transaction` had a handful of methods, so
// users only found out at the call site (`no field or member function named
// 'queryRowsPartial'`). This pins the names: removing or renaming one on the
// tx breaks the build here instead of in a consumer project.
test "Transaction exposes the Client scan/find surface" {
    const required = [_][]const u8{
        // tier 1 — scan helpers (with Ctx forms)
        "queryRowsPartial",        "queryRowsPartialCtx",
        "queryScalar",             "queryScalarCtx",
        "queryRowBorrowed",        "queryRowBorrowedCtx",
        "queryRowPartialBorrowed", "queryRowPartialBorrowedCtx",
        // tier 2 — table helpers, same validateIdentifier/validateSqlFragment gates
        "findOne",                 "findOneCtx",
        "findOnePartial",          "findOnePartialCtx",
        "findAll",                 "findAllCtx",
        "findAllPartial",          "findAllPartialCtx",
        // tier 3 — batch + liveness
        "batchExec",               "batchExecCtx",
        "ping",                    "pingCtx",
        // Ctx forms of the pre-existing trio (Client has them, tx did not)
        "queryRowCtx",             "queryRowPartialCtx",
        "queryRowsCtx",
    };
    inline for (required) |name| {
        if (!@hasDecl(Transaction, name)) {
            @compileError("Transaction is missing Client-parity method: " ++ name);
        }
    }
}

// Client/Transaction parity test: the same query written once against each
// API must yield identical results — field values, row counts and error
// semantics. The write-path helpers are compared on their affected-row counts.
test "transaction scan helpers match client for the same query" {
    const allocator = std.testing.allocator;
    // Single connection on purpose: under the default pool (max_open_conns = 8)
    // the tx would hold one `:memory:` connection while the client-side reads
    // acquire a second one — and every pooled `:memory:` connection is its own
    // empty database, so the "client side" of the comparison would be querying
    // nothing. `max_open_conns = 1` disables the pool and keeps both surfaces on
    // the same connection (see Client.ensurePool).
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:", .max_open_conns = 1 });
    defer client.deinit();
    try client.connect();

    _ = try client.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)", &.{});
    _ = try client.exec("INSERT INTO users (name, email) VALUES (?1, ?2)", &.{ .{ .string = "Alice" }, .{ .string = "alice@example.com" } });
    _ = try client.exec("INSERT INTO users (name, email) VALUES (?1, ?2)", &.{ .{ .string = "Bob" }, .{ .string = "bob@example.com" } });

    const User = struct { id: i64, name: []const u8 };
    const PartialUser = struct {
        id: i64,
        name: []const u8,
        bio: []const u8, // never selected → zeroed by the partial variants
    };
    const Count = struct { n: i64 };

    var tx = try client.beginTx();
    defer tx.rollback() catch {};

    // --- queryRowsPartial ------------------------------------------------
    const c_partial = try client.queryRowsPartial(PartialUser, "SELECT id, name FROM users ORDER BY id", &.{});
    defer c_partial.deinit(allocator);
    const t_partial = try tx.queryRowsPartial(allocator, PartialUser, "SELECT id, name FROM users ORDER BY id", &.{});
    defer t_partial.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), c_partial.items.len);
    try std.testing.expectEqual(c_partial.items.len, t_partial.items.len);
    for (c_partial.items, t_partial.items) |c, t| {
        try std.testing.expectEqual(c.id, t.id);
        try std.testing.expectEqualStrings(c.name, t.name);
        try std.testing.expectEqual(c.bio.len, t.bio.len);
    }

    // --- queryRow / queryRowPartial (owned copies, tx names the allocator) --
    const c_user = try client.queryRow(User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, c_user);
    const t_user = try tx.queryRow(allocator, User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
    defer freeScanned(allocator, User, t_user);
    try std.testing.expectEqual(c_user.id, t_user.id);
    try std.testing.expectEqualStrings(c_user.name, t_user.name);
    try std.testing.expectEqualStrings("Alice", t_user.name);

    const c_partial_row = try client.queryRowPartial(PartialUser, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 2 }});
    defer freeScanned(allocator, PartialUser, c_partial_row);
    const t_partial_row = try tx.queryRowPartial(allocator, PartialUser, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 2 }});
    defer freeScanned(allocator, PartialUser, t_partial_row);
    try std.testing.expectEqual(c_partial_row.id, t_partial_row.id);
    try std.testing.expectEqualStrings(c_partial_row.name, t_partial_row.name);
    try std.testing.expectEqual(c_partial_row.bio.len, t_partial_row.bio.len);

    // NotFound semantics are identical on both surfaces.
    try std.testing.expectError(error.NotFound, client.queryRow(User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 777 }}));
    try std.testing.expectError(error.NotFound, tx.queryRow(allocator, User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 777 }}));

    // --- queryRows --------------------------------------------------------
    const c_rows = try client.queryRows(User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer c_rows.deinit(allocator);
    const t_rows = try tx.queryRows(allocator, User, "SELECT id, name FROM users ORDER BY id", &.{});
    defer t_rows.deinit(allocator);
    try std.testing.expectEqual(c_rows.items.len, t_rows.items.len);
    for (c_rows.items, t_rows.items) |c, t| try std.testing.expectEqualStrings(c.name, t.name);

    // --- queryRowBorrowed / queryRowPartialBorrowed ------------------------
    {
        var c_row = try client.queryRowBorrowed(User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
        defer c_row.deinit();
        var t_row = try tx.queryRowBorrowed(allocator, User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
        defer t_row.deinit();
        try std.testing.expectEqual(c_row.get().id, t_row.get().id);
        try std.testing.expectEqualStrings(c_row.get().name, t_row.get().name);
    }
    {
        var c_row = try client.queryRowPartialBorrowed(PartialUser, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 2 }});
        defer c_row.deinit();
        var t_row = try tx.queryRowPartialBorrowed(allocator, PartialUser, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 2 }});
        defer t_row.deinit();
        try std.testing.expectEqual(c_row.get().id, t_row.get().id);
        try std.testing.expectEqualStrings(c_row.get().name, t_row.get().name);
        try std.testing.expectEqual(c_row.get().bio.len, t_row.get().bio.len);
        try std.testing.expectEqual(@as(usize, 0), t_row.get().bio.len);
    }

    // --- queryScalar (value copy; no freeScanned; NotFound → null) ---------
    const c_count = try client.queryScalar(Count, "SELECT COUNT(*) AS n FROM users", &.{});
    const t_count = try tx.queryScalar(allocator, Count, "SELECT COUNT(*) AS n FROM users", &.{});
    try std.testing.expectEqual(c_count.?.n, t_count.?.n);
    try std.testing.expectEqual(@as(i64, 2), t_count.?.n);
    const c_missing = try client.queryScalar(Count, "SELECT id AS n FROM users WHERE id = ?1", &.{.{ .int = 999 }});
    const t_missing = try tx.queryScalar(allocator, Count, "SELECT id AS n FROM users WHERE id = ?1", &.{.{ .int = 999 }});
    try std.testing.expect(c_missing == null);
    try std.testing.expect(t_missing == null);

    // --- findOne / findOnePartial / findAll / findAllPartial ---------------
    const c_found = try client.findOne(User, "users", "id = ?1", &.{.{ .int = 2 }});
    defer freeScanned(allocator, User, c_found);
    const t_found = try tx.findOne(allocator, User, "users", "id = ?1", &.{.{ .int = 2 }});
    defer freeScanned(allocator, User, t_found);
    try std.testing.expectEqual(c_found.id, t_found.id);
    try std.testing.expectEqualStrings(c_found.name, t_found.name);

    const c_found_partial = try client.findOnePartial(PartialUser, "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, PartialUser, c_found_partial);
    const t_found_partial = try tx.findOnePartial(allocator, PartialUser, "users", "name = ?1", &.{.{ .string = "Alice" }});
    defer freeScanned(allocator, PartialUser, t_found_partial);
    try std.testing.expectEqual(c_found_partial.id, t_found_partial.id);
    try std.testing.expectEqual(c_found_partial.bio.len, t_found_partial.bio.len);

    const c_all = try client.findAll(User, "users", null, &.{});
    defer c_all.deinit(allocator);
    const t_all = try tx.findAll(allocator, User, "users", null, &.{});
    defer t_all.deinit(allocator);
    try std.testing.expectEqual(c_all.items.len, t_all.items.len);

    const c_all_partial = try client.findAllPartial(PartialUser, "users", "name = ?1", &.{.{ .string = "Bob" }});
    defer c_all_partial.deinit(allocator);
    const t_all_partial = try tx.findAllPartial(allocator, PartialUser, "users", "name = ?1", &.{.{ .string = "Bob" }});
    defer t_all_partial.deinit(allocator);
    try std.testing.expectEqual(c_all_partial.items.len, t_all_partial.items.len);
    try std.testing.expectEqualStrings(c_all_partial.items[0].name, t_all_partial.items[0].name);
    try std.testing.expectEqual(c_all_partial.items[0].bio.len, t_all_partial.items[0].bio.len);

    // The injection gates fire identically on both surfaces.
    try std.testing.expectError(error.InvalidSqlIdentifier, client.findOne(User, "users; DROP TABLE users", "id = 1", &.{}));
    try std.testing.expectError(error.InvalidSqlIdentifier, tx.findOne(allocator, User, "users; DROP TABLE users", "id = 1", &.{}));
    try std.testing.expectError(error.UnsafeSqlFragment, client.findOne(User, "users", "id = 1; DROP TABLE users", &.{}));
    try std.testing.expectError(error.UnsafeSqlFragment, tx.findOne(allocator, User, "users", "id = 1; DROP TABLE users", &.{}));
    try std.testing.expectError(error.UnsafeSqlFragment, tx.findAll(allocator, User, "users", "name = 'Alice'", &.{}));

    // --- Ctx variants: every new method is instantiated, not just declared --
    const ctx = SqlContext.withTimeout(5_000);
    try client.ping();
    try tx.ping();
    try tx.pingCtx(ctx);
    {
        const rows = try tx.queryRowsCtx(ctx, allocator, User, "SELECT id, name FROM users ORDER BY id", &.{});
        defer rows.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    }
    {
        const rows = try tx.queryRowsPartialCtx(ctx, allocator, PartialUser, "SELECT id, name FROM users ORDER BY id", &.{});
        defer rows.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), rows.items.len);
        try std.testing.expectEqual(@as(usize, 0), rows.items[0].bio.len);
    }
    {
        const row = try tx.queryRowCtx(ctx, allocator, User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
        defer freeScanned(allocator, User, row);
        try std.testing.expectEqualStrings("Alice", row.name);
    }
    {
        const row = try tx.queryRowPartialCtx(ctx, allocator, PartialUser, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
        defer freeScanned(allocator, PartialUser, row);
        try std.testing.expectEqual(@as(usize, 0), row.bio.len);
    }
    {
        var row = try tx.queryRowBorrowedCtx(ctx, allocator, User, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
        defer row.deinit();
        try std.testing.expectEqualStrings("Alice", row.get().name);
    }
    {
        var row = try tx.queryRowPartialBorrowedCtx(ctx, allocator, PartialUser, "SELECT id, name FROM users WHERE id = ?1", &.{.{ .int = 1 }});
        defer row.deinit();
        try std.testing.expectEqual(@as(usize, 0), row.get().bio.len);
    }
    {
        const n = try tx.queryScalarCtx(ctx, allocator, Count, "SELECT COUNT(*) AS n FROM users", &.{});
        try std.testing.expectEqual(@as(i64, 2), n.?.n);
    }
    {
        const row = try tx.findOneCtx(ctx, allocator, User, "users", "id = ?1", &.{.{ .int = 1 }});
        defer freeScanned(allocator, User, row);
        try std.testing.expectEqualStrings("Alice", row.name);
    }
    {
        const row = try tx.findOnePartialCtx(ctx, allocator, PartialUser, "users", "id = ?1", &.{.{ .int = 1 }});
        defer freeScanned(allocator, PartialUser, row);
        try std.testing.expectEqual(@as(usize, 0), row.bio.len);
    }
    {
        const rows = try tx.findAllCtx(ctx, allocator, User, "users", null, &.{});
        defer rows.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    }
    {
        const rows = try tx.findAllPartialCtx(ctx, allocator, PartialUser, "users", "name = ?1", &.{.{ .string = "Alice" }});
        defer rows.deinit(allocator);
        try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    }
    // A spent budget is refused before any work happens, on every Ctx variant.
    {
        const expired = SqlContext.withDeadline(Time.monotonicNowMilliseconds() - 1);
        try std.testing.expectError(error.Timeout, tx.pingCtx(expired));
        try std.testing.expectError(error.Timeout, tx.queryScalarCtx(expired, allocator, Count, "SELECT COUNT(*) AS n FROM users", &.{}));
        try std.testing.expectError(error.Timeout, tx.queryRowsPartialCtx(expired, allocator, PartialUser, "SELECT id FROM users", &.{}));
        try std.testing.expectError(error.Timeout, tx.findOneCtx(expired, allocator, User, "users", "id = ?1", &.{.{ .int = 1 }}));
    }

    // --- batchExec (write path; compared on affected rows) -----------------
    const client_batch = [_][]const Value{
        &.{ .{ .string = "ClientBatch1" }, .{ .string = "cb1@example.com" } },
        &.{ .{ .string = "ClientBatch2" }, .{ .string = "cb2@example.com" } },
    };
    const c_batch = try client.batchExec("INSERT INTO users (name, email) VALUES (?1, ?2)", &client_batch);
    defer allocator.free(c_batch);

    const ctx_batch = [_][]const Value{
        &.{ .{ .string = "TxBatch1" }, .{ .string = "tb1@example.com" } },
        &.{ .{ .string = "TxBatch2" }, .{ .string = "tb2@example.com" } },
    };
    const t_batch = try tx.batchExecCtx(ctx, allocator, "INSERT INTO users (name, email) VALUES (?1, ?2)", &ctx_batch);
    defer allocator.free(t_batch);

    try std.testing.expectEqual(c_batch.len, t_batch.len);
    for (c_batch, t_batch) |c, t| try std.testing.expectEqual(c.rows_affected, t.rows_affected);
    try std.testing.expectEqual(@as(u64, 1), t_batch[0].rows_affected);
}

test "sqlite extended codes are masked before comparing to primary codes" {
    // 2067 = SQLITE_CONSTRAINT_UNIQUE, 1299 = SQLITE_CONSTRAINT_NOTNULL,
    // 787 = SQLITE_CONSTRAINT_FOREIGNKEY. The call sites pass the extended code
    // (so logs name the specific failure) and compare against primary codes, so
    // the mask is what makes `error.ConstraintViolation` and the table/column
    // diagnosis reachable at all.
    try std.testing.expectEqual(@as(i32, 19), sqlitePrimaryCode(2067));
    try std.testing.expectEqual(@as(i32, 19), sqlitePrimaryCode(1299));
    try std.testing.expectEqual(@as(i32, 19), sqlitePrimaryCode(787));
    try std.testing.expectEqual(@as(i32, 1), sqlitePrimaryCode(1));
    try std.testing.expectEqual(@as(i32, 5), sqlitePrimaryCode(5));

    const unique = diagnoseSqlite(2067, "UNIQUE constraint failed: users.email");
    try std.testing.expectEqual(@as(i32, 2067), unique.code);
    try std.testing.expectEqualStrings("users", unique.table.?);
    try std.testing.expectEqualStrings("email", unique.column.?);

    const notnull = diagnoseSqlite(1299, "NOT NULL constraint failed: orders.total");
    try std.testing.expectEqualStrings("orders", notnull.table.?);
    try std.testing.expectEqualStrings("total", notnull.column.?);

    // A plain error (no extended constraint class) must not be diagnosed as one.
    const plain = diagnoseSqlite(1, "near \"slect\": syntax error");
    try std.testing.expect(plain.table == null and plain.column == null);
}

test "queryScalar reads the first column" {
    const allocator = std.testing.allocator;
    var client = Client.init(allocator, std.testing.io, .{ .driver = .sqlite, .sqlite_path = ":memory:" });
    defer client.deinit();
    try client.connect();

    try std.testing.expectEqual(@as(?i64, 7), try client.queryScalar(i64, "SELECT 7", &.{}));
    try std.testing.expectEqual(@as(?i64, null), try client.queryScalar(i64, "SELECT NULL", &.{}));
    try std.testing.expectEqual(@as(?i64, null), try client.queryScalar(i64, "SELECT 1 WHERE 0", &.{}));
    // Two columns: the first is the one read (documented behaviour).
    try std.testing.expectEqual(@as(?i64, 11), try client.queryScalar(i64, "SELECT 11, 22", &.{}));
    try std.testing.expectEqual(@as(?f64, 1.5), try client.queryScalar(f64, "SELECT 1.5", &.{}));
    // Bound arguments reach the driver on this path too.
    try std.testing.expectEqual(@as(?i64, 5), try client.queryScalar(i64, "SELECT ?1 + 2", &.{.{ .int = 3 }}));
}

// ==== Allocation failures in the row-scanning and query-building paths ====
//
// `Error.zig` documents this file as producing `error.OutOfMemory` for
// "arena/dupe failures while scanning rows", and `toErrorContext` gives that
// name a code of its own while an unmapped error degrades to `UnknownError`.
// These tests pin the split at the sites where a row buffer, a column name, or
// an interpolated query is built in memory this process owns: a failed
// allocation must not be reported as the database refusing the statement.
//
// The seam is `std.testing.FailingAllocator` under the allocator that site
// uses. Two properties make it usable here: it counts only *successful*
// allocations, so pinning `fail_index` at the current count fails exactly the
// next one, and its `free` never fails, so teardown still works afterwards.
// (`resize_fail_index` is pinned alongside so a `remap` cannot quietly satisfy
// a grow that `alloc` would have refused.) Nothing below needs a schema or a
// load — only a live server for the two drivers whose paths exist solely
// against one.

/// Skip unless the live-PG tests may run: `ZIGMODU_TEST_PG=1` (the opt-in that
/// survives `scripts/test-fast.sh`, which owns `DB`) or `DB=postgres`.
fn skipUnlessLivePg() !void {
    const opt_in = if (std.c.getenv("ZIGMODU_TEST_PG")) |v| !std.mem.eql(u8, std.mem.span(v), "0") else false;
    if (!opt_in) try skipUnlessDb("postgres");
    if (!DriverFeatures.postgres) return error.SkipZigTest;
}

/// Connection string for the live-PG tests below — the same variable and the
/// same default as the streaming-cursor tests above.
fn pgTestConninfo() []const u8 {
    const default = "host=127.0.0.1 port=5432 dbname=postgres user=postgres";
    if (builtin.os.tag == .windows) return default;
    if (std.c.getenv("PGconninfo")) |ptr| return std.mem.span(ptr);
    return default;
}

/// A live MySQL connection whose *own* allocator is the caller's
/// `FailingAllocator`. `connect` makes no Zig-side allocations of its own, so
/// the handshake succeeds and the failure can be pinned afterwards.
fn mysqlFailingConn(failing: *std.testing.FailingAllocator) !MySqlConn {
    const cfg = mysqlLiveConfig();
    return MySqlConn.connect(failing.allocator(), cfg.host, cfg.username, cfg.password, cfg.database, cfg.port);
}

/// Pin a `FailingAllocator` so that its next allocation fails.
fn pinAllocatorLimit(failing: *std.testing.FailingAllocator) void {
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
}

// The tests below drive the driver functions directly, on connections that live
// on the stack. `Conn.close` / `Stmt.close` go through `closeFn`, which
// destroys the connection cell — right for the heap cells the framework makes,
// wrong for a local — so these mirror `closeFn` without the destroy.

fn closeStackSQLiteConn(conn: *SQLiteConn) void {
    var it = conn.stmt_cache.iterator();
    while (it.next()) |entry| {
        _ = sqlite3_c.sqlite3_finalize(entry.value_ptr.value);
        conn.allocator.free(entry.key_ptr.*);
    }
    conn.stmt_cache.deinit();
    if (conn.db) |db| _ = sqlite3_c.sqlite3_close(db);
}

fn closeStackPostgresConn(conn: *PostgresConn) void {
    var it = conn.stmt_cache.iterator();
    while (it.next()) |entry| {
        conn.allocator.free(entry.key_ptr.*);
        conn.allocator.free(entry.value_ptr.value);
    }
    conn.stmt_cache.deinit();
    if (conn.conn) |c| libpq_c.PQfinish(c);
}

fn closeStackMySqlConn(conn: *MySqlConn) void {
    var it = conn.stmt_cache.iterator();
    while (it.next()) |entry| {
        _ = libmysql_c.mysql_stmt_close(entry.value_ptr.value);
        conn.allocator.free(entry.key_ptr.*);
    }
    conn.stmt_cache.deinit();
    if (conn.mysql) |m| libmysql_c.mysql_close(m);
}

test "sqlite row scan reports an allocation failure as OutOfMemory" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // `SQLiteConn.queryFn` builds its result set on `self.allocator` — it
    // ignores the allocator its caller passes — so the failure is injected
    // there, after the connection, its statements and one query have run.
    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var conn = try SQLiteConn.open(failing.allocator(), ":memory:");
    defer closeStackSQLiteConn(&conn);

    _ = try SQLiteConn.execFn(&conn, "CREATE TABLE t (a INTEGER, b TEXT)", &.{});
    _ = try SQLiteConn.execFn(&conn, "INSERT INTO t VALUES (1, 'x')", &.{});

    const sql = "SELECT a, b FROM t";
    {
        // Also warms the statement cache, so `getCachedStmt`'s copy of the SQL
        // text is not what the pinned limit trips over.
        var warm = try SQLiteConn.queryFn(&conn, allocator, sql, &.{});
        defer warm.deinit();
        try std.testing.expectEqual(@as(usize, 1), warm.rows.len);
        try std.testing.expectEqualStrings("x", warm.rows[0].get("b").?.string);
    }

    pinAllocatorLimit(&failing);
    try std.testing.expectError(error.OutOfMemory, SQLiteConn.queryFn(&conn, allocator, sql, &.{}));
    try std.testing.expect(failing.has_induced_failure);
}

test "sqlite prepared-statement row scan reports an allocation failure as OutOfMemory" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var conn = try SQLiteConn.open(allocator, ":memory:");
    defer closeStackSQLiteConn(&conn);
    _ = try SQLiteConn.execFn(&conn, "CREATE TABLE t (a INTEGER)", &.{});
    _ = try SQLiteConn.execFn(&conn, "INSERT INTO t VALUES (1)", &.{});

    // Unlike `SQLiteConn.queryFn`, the prepared-statement path builds its rows
    // in the allocator its caller passes — which is what the interface says.
    var stmt = try SQLiteConn.prepareFn(&conn, allocator, "SELECT a FROM t");
    defer stmt.close();
    {
        var warm = try stmt.query(allocator, &.{});
        defer warm.deinit();
        try std.testing.expectEqual(@as(usize, 1), warm.rows.len);
    }

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, stmt.query(failing.allocator(), &.{}));
    try std.testing.expect(failing.has_induced_failure);
}

test "sqlite statement stub allocation failure is OutOfMemory" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var conn = try SQLiteConn.open(allocator, ":memory:");
    defer closeStackSQLiteConn(&conn);

    // `prepareFn` allocates the statement cell itself and only then asks the
    // driver to prepare: the first failure is this process's memory, not the
    // database's.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, SQLiteConn.prepareFn(&conn, failing.allocator(), "SELECT 1"));
    try std.testing.expect(failing.has_induced_failure);
}

test "sqlite statement-cache key allocation failure is OutOfMemory" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var conn = try SQLiteConn.open(failing.allocator(), ":memory:");
    defer closeStackSQLiteConn(&conn);

    // `getCachedStmt` prepares with the driver and only then copies the SQL text
    // into the cache, so the copy is the first allocation on this path.
    pinAllocatorLimit(&failing);
    try std.testing.expectError(error.OutOfMemory, SQLiteConn.getCachedStmt(&conn, "SELECT 1"));
    try std.testing.expect(failing.has_induced_failure);
}

// `readSQLiteValue` used to fold both of these into one `null`: the SQL NULL a
// column legitimately holds, and a failed `dupe` of the TEXT cell it had to copy
// out of the driver. A caller cannot tell them apart, so an out-of-memory became
// a wrong value (a NULL cell in an otherwise complete row) with no error at all.
// The copy now leaves through the error channel, as `pgReadCell`'s does.
test "sqlite text cell: allocation failure is OutOfMemory, SQL NULL stays null" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var conn = try SQLiteConn.open(allocator, ":memory:");
    defer closeStackSQLiteConn(&conn);

    const stmt = try SQLiteConn.getCachedStmt(&conn, "SELECT 'x' AS s, NULL AS n");
    try std.testing.expectEqual(@as(c_int, sqlite3_c.SQLITE_ROW), sqlite3_c.sqlite3_step(stmt));

    // Column 1 is a genuine SQL NULL…
    try std.testing.expect((try readSQLiteValue(allocator, stmt, 1)) == null);
    // …and column 0 is the text, present whenever its copy can be made.
    const cell = (try readSQLiteValue(allocator, stmt, 0)).?;
    defer allocator.free(cell.string);
    try std.testing.expectEqualStrings("x", cell.string);

    // The copy is this process's memory, so failing it must not masquerade as the
    // NULL above.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, readSQLiteValue(failing.allocator(), stmt, 0));
    try std.testing.expect(failing.has_induced_failure);
}

// `readSQLiteValue`'s `else` arm answers `null` for a column type it does not
// decode — SQLite has exactly one left, BLOB — and `null` is also what it
// answers for a `SQLITE_NULL` cell. No consumer of the *value* can tell the two
// apart: `Row.get` hands back `?Value`, an optional `[]const u8` field scans to
// `null`, `valueToType` is never reached for either.
//
// The value channel keeps that shape — a row's columns are all decoded before any
// of them is scanned, so erroring here would fail a query that merely lists such
// a column (`SELECT *`) — but the arm no longer drops the driver's information on
// the floor: the type is logged once per process, which is what tells a
// truncated-looking NULL from a column that really is SQL NULL.
test "sqlite blob cell reads as SQL NULL, but the type is reported" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // The once-per-type guard is process-global; clear it for this run and put it
    // back, so the assertions hold whatever test ran before.
    undecoded_sqlite_type_warn_mask.store(0, .monotonic);
    defer undecoded_sqlite_type_warn_mask.store(0, .monotonic);
    const blob_bit = @as(u32, 1) << @as(u5, @intCast(@as(u32, sqlite3_c.SQLITE_BLOB) & 31));

    var conn = try SQLiteConn.open(allocator, ":memory:");
    defer closeStackSQLiteConn(&conn);
    _ = try SQLiteConn.execFn(&conn, "CREATE TABLE t (b BLOB, n INTEGER)", &.{});
    // Bytes that are not text: not UTF-8, and the first one is a NUL.
    _ = try SQLiteConn.execFn(&conn, "INSERT INTO t VALUES (x'00ff10', NULL)", &.{});

    const stmt = try SQLiteConn.getCachedStmt(&conn, "SELECT b, n FROM t");
    try std.testing.expectEqual(@as(c_int, sqlite3_c.SQLITE_ROW), sqlite3_c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, sqlite3_c.SQLITE_BLOB), sqlite3_c.sqlite3_column_type(stmt, 0));

    // A real SQL NULL is a value, not a report: it leaves the guard untouched.
    try std.testing.expect((try readSQLiteValue(allocator, stmt, 1)) == null);
    try std.testing.expectEqual(@as(u32, 0), undecoded_sqlite_type_warn_mask.load(.monotonic));

    // The BLOB is still `null` in the value channel …
    try std.testing.expect((try readSQLiteValue(allocator, stmt, 0)) == null);
    // … and the type it could not decode is reported — once, not per cell.
    try std.testing.expectEqual(blob_bit, undecoded_sqlite_type_warn_mask.load(.monotonic));
    try std.testing.expect(!markUndecodedSqliteType(sqlite3_c.SQLITE_BLOB));
    try std.testing.expectEqual(blob_bit, undecoded_sqlite_type_warn_mask.load(.monotonic));

    // And that is what a scan sees: the optional field is simply absent.
    const BlobRow = struct { b: ?[]const u8 };
    var rows = try SQLiteConn.queryFn(&conn, allocator, "SELECT b FROM t", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(usize, 1), rows.rows.len);
    const scanned = try rows.rows[0].scan(allocator, BlobRow);
    try std.testing.expect(scanned.b == null);
}

/// One scan on a connection of its own — `SQLiteConn.queryFn` builds its result
/// set on the connection's allocator, so the connection has to be rebuilt on the
/// allocator under test for a run to replay the same allocation sequence.
fn sqliteScanOnce(allocator: std.mem.Allocator, big: []const u8) !void {
    var conn = try SQLiteConn.open(allocator, ":memory:");
    defer closeStackSQLiteConn(&conn);

    _ = try SQLiteConn.execFn(&conn, "CREATE TABLE t (a INTEGER, b TEXT)", &.{});
    _ = try SQLiteConn.execFn(&conn, "INSERT INTO t VALUES (1, ?1)", &.{.{ .string = big }});

    // First the statement is prepared and cached, then the scan that is swept.
    // The text is checked without `expectEqualStrings`, so a scan that hands back
    // a NULL cell fails the test instead of dereferencing it.
    var warm = try SQLiteConn.queryFn(&conn, allocator, "SELECT a, b FROM t", &.{});
    defer warm.deinit();
    if (warm.rows[0].values[1]) |cell| {
        if (!std.mem.eql(u8, big, cell.string)) return error.ScanReturnedWrongText;
    } else return error.ScanReturnedNullText;

    var rows = try SQLiteConn.queryFn(&conn, allocator, "SELECT a, b FROM t", &.{});
    defer rows.deinit();
    if (rows.rows[0].values[1]) |cell| {
        if (!std.mem.eql(u8, big, cell.string)) return error.ScanReturnedWrongText;
    } else return error.ScanReturnedNullText;
}

test "sqlite row scan: no allocation failure in the scan is reported as a value" {
    if (!DriverFeatures.sqlite) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // The cell has to be big enough that its copy cannot be served out of the
    // arena node the row buffer already holds: the copy then asks the injected
    // allocator for a new node, which is what makes it reachable here at all.
    var big_buf: [4096]u8 = undefined;
    @memset(&big_buf, 'x');
    const big: []const u8 = &big_buf;

    // Run once with nothing failing to learn how many allocations a scan makes —
    // the same shape `std.testing.checkAllAllocationFailures` uses. The count
    // covers everything the helper allocates, statement prepare and caching
    // included, so those are swept too, not just the row buffer.
    const total = blk: {
        var counting = std.testing.FailingAllocator.init(allocator, .{});
        try sqliteScanOnce(counting.allocator(), big);
        break :blk counting.alloc_index;
    };
    try std.testing.expect(total > 0);

    // Then fail each of them in turn. Every iteration gets a fresh allocator, so
    // its counter starts at zero and `fail_index = k` lands on the k-th
    // allocation of that run; a shared counter would drift, because a failed
    // allocation is never counted and each run stops where it failed.
    var k: usize = 0;
    while (k < total) : (k += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = k });
        if (sqliteScanOnce(failing.allocator(), big)) |_| {
            if (!failing.has_induced_failure) return error.NondeterministicAllocationCount;
            std.debug.print("\nallocation #{d} of the scan failed but the scan returned a result\n", .{k});
            return error.AllocationFailureReportedAsValue;
        } else |err| {
            if (err != error.OutOfMemory) {
                std.debug.print("\nallocation #{d} of the scan came back as {s}\n", .{ k, @errorName(err) });
                return err;
            }
        }
    }
}

test "scanStruct indexed string-dupe allocation failure is OutOfMemory" {
    const allocator = std.testing.allocator;
    const columns = [_][]const u8{"name"};
    const values = [_]?Value{.{ .string = "ada" }};
    const row = Row{ .arena = undefined, .columns = &columns, .values = &values };
    const Named = struct { name: []const u8 };

    // The column-indexed path, the one `buildColumnIndices` feeds.
    var indices = [_]?usize{0};
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, scanStruct(failing.allocator(), Named, row, false, &indices, false));
    try std.testing.expect(failing.has_induced_failure);
}

test "scanStruct linear-scan string-dupe allocation failure is OutOfMemory" {
    const allocator = std.testing.allocator;
    const columns = [_][]const u8{"name"};
    const values = [_]?Value{.{ .string = "ada" }};
    const row = Row{ .arena = undefined, .columns = &columns, .values = &values };
    const Named = struct { name: []const u8 };

    // The fallback that matches the field name against the row's column names.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, scanStruct(failing.allocator(), Named, row, false, null, false));
    try std.testing.expect(failing.has_induced_failure);
}

test "valueToType reports a string-dupe allocation failure as OutOfMemory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, valueToType(failing.allocator(), []const u8, .{ .string = "ada" }));
    try std.testing.expect(failing.has_induced_failure);
}

test "postgres buffered read reports an allocation failure as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    var conn = try PostgresConn.connect(allocator, pgTestConninfo(), 0);
    defer closeStackPostgresConn(&conn);

    // `queryFn`'s row buffer lives in the arena its caller passes; the query
    // itself runs on the connection's own allocator. So the first failure here
    // is the buffer — the same name the streaming path reports for the same
    // condition.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        PostgresConn.queryFn(&conn, failing.allocator(), "SELECT i * 10 AS q FROM generate_series(1, 3) AS i", &.{}),
    );
    try std.testing.expect(failing.has_induced_failure);

    // The failed read must not have consumed or corrupted the connection: the
    // next statement on it still returns its row. (The cell's union member
    // depends on the result format libpq was asked for, so both are accepted.)
    var after = try PostgresConn.queryFn(&conn, allocator, "SELECT 42 AS n", &.{});
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.rows.len);
    const n = after.rows[0].get("n").?;
    try std.testing.expectEqual(@as(i64, 42), switch (n) {
        .int => |v| v,
        .string => |s| try std.fmt.parseInt(i64, s, 10),
        else => return error.TestUnexpectedResult,
    });
}

test "postgres prepared-statement row scan reports an allocation failure as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    var conn = try PostgresConn.connect(allocator, pgTestConninfo(), 0);
    defer closeStackPostgresConn(&conn);

    var stmt = try PostgresConn.prepareFn(&conn, allocator, "SELECT 1 AS a");
    defer stmt.close();
    {
        var warm = try stmt.query(allocator, &.{});
        defer warm.deinit();
        try std.testing.expectEqual(@as(usize, 1), warm.rows.len);
        try std.testing.expectEqualStrings("a", warm.rows[0].columns[0]);
    }

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, stmt.query(failing.allocator(), &.{}));
    try std.testing.expect(failing.has_induced_failure);
}

test "mysql query prepared path reports an allocation failure as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var conn = try mysqlFailingConn(&failing);
    defer closeStackMySqlConn(&conn);

    // Pinned at the next allocation, the first one the prepared path makes is
    // its copy of the SQL text into the statement cache — and that failure is
    // the whole call's: `error.OutOfMemory`, not the fallback.
    pinAllocatorLimit(&failing);
    try std.testing.expectError(error.OutOfMemory, MySqlConn.queryFn(&conn, allocator, "SELECT ? AS a", &.{.{ .int = 1 }}));
    try std.testing.expect(failing.has_induced_failure);
}

test "mysql exec prepared path reports an allocation failure as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var conn = try mysqlFailingConn(&failing);
    defer closeStackMySqlConn(&conn);

    pinAllocatorLimit(&failing);
    try std.testing.expectError(error.OutOfMemory, MySqlConn.execFn(&conn, "SELECT ? AS a", &.{.{ .int = 1 }}));
    try std.testing.expect(failing.has_induced_failure);
}

// The pinned tests above fail *every* allocation from their limit on, so the
// fallback fails too and the error would resurface even if the prepared path
// swallowed it. The case that shows the swallowing is a failure that does not
// persist: the fallback allocates from the same allocator, and when its own
// buffer happens to fit, the statement runs for real and the caller never learns
// that the allocation it needed had failed.
//
// `FailOnceAllocator` (below) fails one allocation and lets every later one
// through, which is exactly what `std.testing.FailingAllocator` cannot express.
test "mysql exec prepared path does not swallow an allocation failure" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const cfg = mysqlLiveConfig();

    // 0 is the copy of the SQL text into the statement cache, 1 the cache insert
    // right after it. Both sit inside the prepared path, ahead of the fallback.
    var fail_at: usize = 0;
    while (fail_at < 2) : (fail_at += 1) {
        var once = FailOnceAllocator.init(allocator, fail_at);
        var conn = try MySqlConn.connect(once.allocator(), cfg.host, cfg.username, cfg.password, cfg.database, cfg.port);
        defer closeStackMySqlConn(&conn);

        try std.testing.expectError(error.OutOfMemory, MySqlConn.execFn(&conn, "SELECT ? AS a", &.{.{ .int = 1 }}));
    }
}

test "mysql query prepared path does not swallow an allocation failure" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const cfg = mysqlLiveConfig();

    var fail_at: usize = 0;
    while (fail_at < 2) : (fail_at += 1) {
        var once = FailOnceAllocator.init(allocator, fail_at);
        var conn = try MySqlConn.connect(once.allocator(), cfg.host, cfg.username, cfg.password, cfg.database, cfg.port);
        defer closeStackMySqlConn(&conn);

        try std.testing.expectError(error.OutOfMemory, MySqlConn.queryFn(&conn, allocator, "SELECT ? AS a", &.{.{ .int = 1 }}));
    }
}

test "mysql streaming cursor reports an allocation failure as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var conn = try mysqlFailingConn(&failing);
    defer closeStackMySqlConn(&conn);

    // The streaming cursor interpolates before it touches the wire, so this is
    // the first — and only — allocation on its path.
    pinAllocatorLimit(&failing);
    try std.testing.expectError(
        error.OutOfMemory,
        MySqlConn.queryCursorFn(&conn, allocator, "SELECT ? AS a", &.{.{ .int = 1 }}, .{ .mode = .streaming }),
    );
    try std.testing.expect(failing.has_induced_failure);
}

test "postgres statement stub allocation failure is OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    var conn = try PostgresConn.connect(allocator, pgTestConninfo(), 0);
    defer closeStackPostgresConn(&conn);

    // As in the sqlite driver: `prepareFn` allocates the statement cell itself
    // and only then asks the server to prepare, so the first failure is this
    // process's memory rather than a statement the server rejected.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, PostgresConn.prepareFn(&conn, failing.allocator(), "SELECT 1"));
    try std.testing.expect(failing.has_induced_failure);
}

test "postgres statement name allocation failure is OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    var conn = try PostgresConn.connect(allocator, pgTestConninfo(), 0);
    defer closeStackPostgresConn(&conn);

    // One allocation is allowed — the statement cell — so what fails is the
    // `allocZ` of the statement name inside `PostgresStmt.prepare`, the other
    // allocation on that path.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, PostgresConn.prepareFn(&conn, failing.allocator(), "SELECT 1"));
    try std.testing.expect(failing.has_induced_failure);
}

// The tests below cover the two drivers whose row-scanning paths are only
// reachable against a live server, at the sites the tests above leave out: the
// prepared-statement row reader, the statement cache, the streaming cursors and
// the bulk-insert paths. They are written as *walks*: `fail_index = idx` fails
// the (idx+1)-th allocation the site asks its allocator for, and `idx` advances
// by one per attempt, so one loop passes through every allocation on the path in
// the order the code makes them. Reaching the success case is what says the walk
// covered all of them — an attempt can only succeed once the index is past the
// last allocation. `resize_fail_index = 0` keeps an arena from growing its node
// in place: without it a `rawResize` the counter never sees could satisfy the
// request and the walk would step over sites it claims to have visited.

test "mysql statement row scan reports allocation failures as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const cfg = mysqlLiveConfig();
    var conn = try MySqlConn.connect(allocator, cfg.host, cfg.username, cfg.password, cfg.database, cfg.port);
    defer closeStackMySqlConn(&conn);

    // Two rows on purpose: the short one is copied out of the fixed 4096-byte
    // bind buffer, the long one overflows it and is refetched — the two string
    // paths that each allocate.
    const sql = "SELECT 1 AS a, 'x' AS b UNION ALL SELECT 2, REPEAT('x', 5000)";
    {
        // Warm the statement cache with a working allocator, so every walk below
        // trips over the row buffer and never over the cache key.
        const stmt = try conn.getCachedStmt(sql);
        try std.testing.expectEqual(@as(c_int, 0), libmysql_c.mysql_stmt_execute(stmt));
        var warm_arena = std.heap.ArenaAllocator.init(allocator);
        var warm = try mysqlStmtReadRows(stmt, &warm_arena);
        defer warm.deinit();
        try std.testing.expectEqual(@as(usize, 2), warm.rows.len);
        try std.testing.expectEqualStrings("x", warm.rows[0].get("b").?.string);
        try std.testing.expectEqual(@as(usize, 5000), warm.rows[1].get("b").?.string.len);
    }

    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 24) : (idx += 1) {
        const stmt = try conn.getCachedStmt(sql); // cache hit: allocates nothing
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        try mysqlBindParams(stmt, scratch.allocator(), &.{});
        try std.testing.expectEqual(@as(c_int, 0), libmysql_c.mysql_stmt_execute(stmt));

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = idx, .resize_fail_index = 0 });
        var arena = std.heap.ArenaAllocator.init(failing.allocator());
        const res = mysqlStmtReadRows(stmt, &arena);
        if (res) |rows| {
            var got = rows;
            got.deinit();
            succeeded = true;
            break;
        } else |err| {
            // The failed read handed nothing back, so the row buffer it had
            // already built is still this test's to release.
            arena.deinit();
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

test "mysql prepared-statement cell allocation failure is OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const cfg = mysqlLiveConfig();
    var conn = try MySqlConn.connect(allocator, cfg.host, cfg.username, cfg.password, cfg.database, cfg.port);
    defer closeStackMySqlConn(&conn);

    // `prepareFn` allocates the statement cell before it asks the library to
    // prepare, so the first failure on this path is this process's memory rather
    // than a statement the server rejected.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, MySqlConn.prepareFn(&conn, failing.allocator(), "SELECT 1"));
    try std.testing.expect(failing.has_induced_failure);
}

test "mysql statement cache reports allocation failures as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const sql = "SELECT 1 AS a";

    // `getCachedStmt` on a cold cache: the SQL text is copied into the key and
    // the map behind it grows. Both are this process's memory; the statement
    // itself is already prepared by then.
    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 6) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = idx, .resize_fail_index = 0 });
        var conn = try mysqlFailingConn(&failing);
        defer closeStackMySqlConn(&conn);

        if (conn.getCachedStmt(sql)) |_| {
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), @as(errors.Error, err));
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

test "mysql streaming cursor reports column allocation failures as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const cfg = mysqlLiveConfig();
    const sql = "SELECT 1 AS a, 2 AS b";

    // Zero arguments, so the only allocations before the wire are the column
    // array and one `dupe` per column name — all on the allocator the *caller*
    // passes, which is why the connection can stay on a working one.
    var idx: usize = 0;
    var succeeded = false;
    while (idx < 6) : (idx += 1) {
        // A fresh connection per attempt: a failure after `mysql_use_result`
        // leaves the result set on the wire, and this cursor never got to drain
        // it.
        var conn = try MySqlConn.connect(allocator, cfg.host, cfg.username, cfg.password, cfg.database, cfg.port);
        defer closeStackMySqlConn(&conn);

        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = idx, .resize_fail_index = 0 });
        const res = MySqlConn.queryCursorFn(&conn, failing.allocator(), sql, &.{}, .{ .mode = .streaming });
        if (res) |cursor| {
            var c = cursor;
            c.deinit();
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
        }
    }
    try std.testing.expect(succeeded);
}

test "mysql batch insert reports allocation failures as OutOfMemory" {
    try skipUnlessDb("mysql");
    const allocator = std.testing.allocator;
    const columns = [_][]const u8{ "a", "b" };
    const row = [_]Value{ .{ .int = 1 }, .{ .string = "x" } };
    const rows = [_][]const Value{&row};

    // The insert text is built on the connection's own allocator and the bind
    // arrays on a scratch arena over it, so one walk covers both. The bind step
    // is the one that used to answer `error.DatabaseError`.
    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 24) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = idx, .resize_fail_index = 0 });
        var conn = try mysqlFailingConn(&failing);
        defer closeStackMySqlConn(&conn);

        const ddl = "CREATE TEMPORARY TABLE oom_batch (a INT, b VARCHAR(8))";
        if (libmysql_c.mysql_real_query(conn.mysql, @ptrCast(ddl.ptr), @intCast(ddl.len)) != 0) return error.DatabaseError;

        const res = MySqlConn.batchInsertPrepared(&conn, "oom_batch", &columns, &rows);
        if (res) |r| {
            try std.testing.expectEqual(@as(u64, 1), r.rows_affected);
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

test "mysql bind-param allocation failure is OutOfMemory" {
    // The bind arrays are allocated before the library is called, so this needs
    // no server and no statement: what it pins is that the failure keeps its own
    // name, which is what the batch path above depends on.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, mysqlBindParams(@as(*libmysql_c.MYSQL_STMT, undefined), failing.allocator(), &.{.{ .int = 1 }}));
    try std.testing.expect(failing.has_induced_failure);
}

test "postgres streaming cursor reports allocation failures as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;
    // The `?` placeholder is required: `PQsendQueryParams` is handed one
    // parameter, and a query with none comes back `PGRES_FATAL_ERROR` — a driver
    // error, which would end the walk before it reached the column names. The
    // cast is required too: a bare `$1` in a select list has no type to infer.
    const sql = "SELECT ?::text AS a, 2 AS b";

    // The caller's allocator owns every buffer this path builds: the
    // null-terminated SQL, the parameter arrays, the text of each bound value
    // (`allocPrint` for the numeric tags, `dupe` for the string) and the column
    // names. One walk per parameter shape, because the text is built per tag.
    for ([_]Value{ .{ .int = 1 }, .{ .float = 1.5 }, .{ .string = "x" } }) |arg| {
        const args = [_]Value{arg};
        var idx: usize = 0;
        var succeeded = false;
        while (idx < 24) : (idx += 1) {
            // A fresh connection per attempt: a failure after
            // `PQsendQueryParams` leaves the result on the wire, and this cursor
            // has no path that drains it.
            var conn = try PostgresConn.connect(allocator, pgTestConninfo(), 0);
            defer closeStackPostgresConn(&conn);

            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = idx, .resize_fail_index = 0 });
            const res = PostgresConn.queryCursorFn(&conn, failing.allocator(), sql, &args, .{ .mode = .streaming });
            if (res) |cursor| {
                var c = cursor;
                c.deinit();
                succeeded = true;
                break;
            } else |err| {
                try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
                try std.testing.expect(failing.has_induced_failure);
            }
        }
        try std.testing.expect(succeeded);
    }
}

test "postgres copy-from reports allocation failures as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;
    const columns = [_][]const u8{ "a", "b" };
    const row = [_]Value{ .{ .int = 1 }, .{ .string = "x" } };
    const rows = [_][]const Value{&row};

    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 24) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var conn = try PostgresConn.connect(failing.allocator(), pgTestConninfo(), 0);
        defer closeStackPostgresConn(&conn);

        // `connect` spent one allocation of its own (the null-terminated
        // conninfo), so the failure is placed `idx` allocations into the copy.
        failing.fail_index = failing.alloc_index + idx;
        failing.resize_fail_index = 0;

        const ddl = "CREATE TEMPORARY TABLE oom_copy (a int, b text)";
        const ddl_res = libpq_c.PQexec(conn.conn, ddl);
        if (ddl_res) |r| libpq_c.PQclear(r) else return error.DatabaseError;

        const res = PostgresConn.copyFrom(&conn, "oom_copy", &columns, &rows);
        if (res) |r| {
            try std.testing.expectEqual(@as(u64, 1), r.rows_affected);
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

// ==== Allocation failures on the PG parameter-binding path ====
//
// `execPrepared` / `execParamsDirect` / `execPreparedStmt` answered `null` for
// two unrelated things — "this process could not allocate" and "the driver did
// not hand back a `PGresult`" — and every caller read `null` as the second, so
// an out-of-memory inside them was reported as `error.DatabaseError` (which
// `toErrorContext` degrades to `UnknownError`, and the metrics callback records
// by name). They now take the split the row-scanning paths above already use:
// the answer is an error union, `null` is only the driver declining, and this
// process's memory is `error.OutOfMemory`.
//
// The seam is the connection's *own* allocator — these functions ignore the
// allocator their caller passes — so the `FailingAllocator` goes under
// `PostgresConn.connect` and the walks follow the same shape as the streaming
// cursor and copy-from tests.

test "postgres query walk reports connection-side allocation failures as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    // Every tag is bound, so the walk also passes the per-parameter copies
    // (`allocPrintZ` for the numeric tags, `allocZ` for the string).
    const args = [_]Value{ .{ .int = 7 }, .{ .float = 1.5 }, .{ .string = "x" }, .{ .bool = true }, .null };
    const sql = "SELECT ?::int AS a, ?::float AS b, ?::text AS c, ?::bool AS d, ?::int AS e";

    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 32) : (idx += 1) {
        // A fresh connection per attempt: an attempt that dies after
        // `PQprepare` leaves a statement on the server with nobody here to
        // deallocate it, and the session is thrown away with it.
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var conn = try PostgresConn.connect(failing.allocator(), pgTestConninfo(), 0);
        defer closeStackPostgresConn(&conn);
        failing.fail_index = failing.alloc_index + idx;
        failing.resize_fail_index = 0;

        const res = PostgresConn.queryFn(&conn, allocator, sql, &args);
        if (res) |rows| {
            var r = rows;
            r.deinit();
            succeeded = true;
            break;
        } else |err| {
            // Before the split this was `error.DatabaseError` for every index
            // that failed an allocation in one of the three functions.
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

test "postgres exec walk reports connection-side allocation failures as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;
    const args = [_]Value{.{ .int = 7 }};
    const sql = "SELECT ?::int AS a";

    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 24) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var conn = try PostgresConn.connect(failing.allocator(), pgTestConninfo(), 0);
        defer closeStackPostgresConn(&conn);
        failing.fail_index = failing.alloc_index + idx;
        failing.resize_fail_index = 0;

        const res = PostgresConn.execFn(&conn, sql, &args);
        if (res) |_| {
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

test "postgres no-argument query reports a connection-side allocation failure as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    // No arguments: `execPrepared` hands the statement straight to
    // `execParamsDirect`, whose only allocation before `PQexec` is the
    // null-terminated copy of the SQL.
    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 8) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var conn = try PostgresConn.connect(failing.allocator(), pgTestConninfo(), 0);
        defer closeStackPostgresConn(&conn);
        failing.fail_index = failing.alloc_index + idx;
        failing.resize_fail_index = 0;

        const res = PostgresConn.queryFn(&conn, allocator, "SELECT 42 AS n", &.{});
        if (res) |rows| {
            var r = rows;
            r.deinit();
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

test "postgres cached-statement re-execution reports an allocation failure as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var conn = try PostgresConn.connect(failing.allocator(), pgTestConninfo(), 0);
    defer closeStackPostgresConn(&conn);

    const sql = "SELECT ?::int AS q";
    const args = [_]Value{.{ .int = 7 }};

    // Warm the statement cache while the connection's allocator still works.
    {
        var warm = try PostgresConn.queryFn(&conn, allocator, sql, &args);
        warm.deinit();
        try std.testing.expectEqual(@as(usize, 1), conn.stmt_cache.count());
    }

    // The cached name is valid, so this run is `execPreparedStmt`'s parameter
    // arena — not a re-prepare — and every allocation on it now fails.
    pinAllocatorLimit(&failing);
    try std.testing.expectError(error.OutOfMemory, PostgresConn.queryFn(&conn, allocator, sql, &args));
    try std.testing.expect(failing.has_induced_failure);

    // What failed was the allocator, not the connection: the cache entry
    // survived and the next statement runs on it.
    failing.fail_index = std.math.maxInt(usize);
    var after = try PostgresConn.queryFn(&conn, allocator, sql, &args);
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.rows.len);
}

test "postgres driver failure is a returned result, not an allocation failure" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;

    var conn = try PostgresConn.connect(allocator, pgTestConninfo(), 0);
    defer closeStackPostgresConn(&conn);

    // The other direction of the same split, which the shared `null` used to
    // make unrepresentable: a statement name the server does not know is the
    // *driver* answering, and it comes back as a `PGresult` carrying the
    // failure — not as `error.OutOfMemory`, and not as a bare `null`.
    const maybe_pg = try PostgresConn.execPreparedStmt(&conn, "zm_no_such_statement_oom_probe", &.{});
    try std.testing.expect(maybe_pg != null);
    const pg = maybe_pg.?;
    defer libpq_c.PQclear(pg);
    try std.testing.expectEqual(libpq_c.ExecStatusType.PGRES_FATAL_ERROR, libpq_c.PQresultStatus(pg));

    // A driver failure that does come back as `null` is still `null` on the
    // statement path: `conn == null` is an answer, not this process's memory
    // (and it costs no allocation to say it).
    var orphan = PostgresStmt{ .conn = null, .name = "zm_orphan", .allocator = allocator };
    try std.testing.expect((try orphan.execParamsPrepared(&.{.{ .int = 1 }})) == null);

    // The connection is still usable: the driver's refusal was not a state
    // change on this side.
    var after = try PostgresConn.queryFn(&conn, allocator, "SELECT 1 AS n", &.{});
    defer after.deinit();
    try std.testing.expectEqual(@as(usize, 1), after.rows.len);
}

test "postgres execParamsDirect reports bound-parameter allocation failures as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;
    const args = [_]Value{ .{ .int = 1 }, .{ .string = "x" } };

    // Called directly with two parameters against SQL that uses none: the walk
    // steps through this function's own parameter arrays and the per-parameter
    // copies, and the driver is reached only past every one of them.
    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 16) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var conn = try PostgresConn.connect(failing.allocator(), pgTestConninfo(), 0);
        defer closeStackPostgresConn(&conn);
        failing.fail_index = failing.alloc_index + idx;
        failing.resize_fail_index = 0;

        const res = PostgresConn.execParamsDirect(&conn, "SELECT 1 AS n", &args);
        if (res) |maybe_pg| {
            // The driver does answer — with a `FATAL_ERROR` result, the bind
            // count not matching the statement — and that is only reachable
            // once every allocation below succeeded.
            if (maybe_pg) |pg| libpq_c.PQclear(pg);
            succeeded = true;
            break;
        } else |err| {
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    // How many allocations the path makes is an implementation detail of the
    // helpers it uses (`allocPrintZ` alone asks for two buffers); what the walk
    // proves is that the driver is reached only past the last of them, so every
    // allocation site on the path was visited — the SQL copy, the three
    // parameter arrays and the two parameter copies among them.
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}

test "convertPlaceholders reports an allocation failure as OutOfMemory" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, PostgresConn.convertPlaceholders(failing.allocator(), "SELECT ? AS a"));
    try std.testing.expect(failing.has_induced_failure);

    // "Nothing to rewrite" is not a failure and asks for no allocation at all —
    // not for SQL without a `?`, and not for a `?` that only sits inside a
    // literal. Callers send the SQL as it stands.
    const allocator = std.testing.allocator;
    try std.testing.expect((try PostgresConn.convertPlaceholders(allocator, "SELECT 1")) == null);
    try std.testing.expect((try PostgresConn.convertPlaceholders(allocator, "SELECT '?' AS q")) == null);
}

test "postgres prepared-statement bind walk reports allocation failures as OutOfMemory" {
    try skipUnlessLivePg();
    const allocator = std.testing.allocator;
    const args = [_]Value{ .{ .int = 1 }, .{ .float = 1.5 }, .{ .string = "x" } };
    // `PostgresStmt.prepare` hands the SQL to `PQprepare` as written, so the
    // placeholders here are PostgreSQL's own `$N` (it does not rewrite `?`).
    const sql = "SELECT $1::int AS a, $2::float AS b, $3::text AS c";

    var idx: usize = 0;
    var failures: usize = 0;
    var succeeded = false;
    while (idx < 24) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{});
        var conn = try PostgresConn.connect(allocator, pgTestConninfo(), 0);
        defer closeStackPostgresConn(&conn);

        // The statement carries the allocator its bind arena is built from, so
        // the failure is pinned after `prepare` — itself an allocation site on
        // that same allocator.
        var stmt = try PostgresConn.prepareFn(&conn, failing.allocator(), sql);
        defer stmt.close();

        failing.fail_index = failing.alloc_index + idx;
        failing.resize_fail_index = 0;

        const res = stmt.query(allocator, &args);
        if (res) |rows| {
            var r = rows;
            r.deinit();
            succeeded = true;
            break;
        } else |err| {
            // Before the split this was `error.DatabaseError` at every index
            // that failed the bind arena's allocation.
            try std.testing.expectEqual(@as(errors.Error, error.OutOfMemory), err);
            try std.testing.expect(failing.has_induced_failure);
            failures += 1;
        }
    }
    try std.testing.expect(succeeded);
    try std.testing.expect(failures > 0);
}
