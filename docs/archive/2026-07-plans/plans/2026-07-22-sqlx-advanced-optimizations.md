# SQLx Advanced Optimizations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden the database layer for production traffic by adding connection lifecycle management, fair pool acquisition, metrics, true streaming cursors, and efficient batch protocols.

**Architecture:** Keep changes inside `src/sqlx/sqlx.zig` and its test suite. Extend `ConnPool` with timestamps and a FIFO wait queue; add a lightweight `Metrics` struct; introduce `Cursor` with driver-native streaming for MySQL/PostgreSQL; add `Client.batchInsertEx` using MySQL prepared-statement batch and PostgreSQL `COPY` fallback.

**Tech Stack:** Zig 0.17.0-dev, libpq, libmysqlclient, sqlite3, `std.Io.Mutex/Condition`, `Time.monotonicNowMilliseconds()`.

## Global Constraints

- Target Zig 0.17.0-dev; use `std.ArrayList(T).empty` + allocator-per-method.
- All mutex operations need `self.io`.
- All time measurements use `Time.monotonicNowMilliseconds()` or `Time.monotonicNow()`.
- No new external dependencies.
- Every allocation must have matching `defer`/`errdefer`.
- Tests must pass with `ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test`.
- Keep public API additions additive; do not break existing `Client`/`Transaction` signatures.

---

## Task 1: Connection Pool Lifecycle + Fairness

**Files:**
- Modify: `src/sqlx/sqlx.zig:ConnPool` (around line 2791)
- Test: add tests at end of `src/sqlx/sqlx.zig`

**Interfaces:**
- Consumes: `Time.monotonicNowMilliseconds()`, `std.Io.Condition.waitTimeout`
- Produces:
  - `ConnPool.Options` extended with `max_lifetime_secs: u32 = 3600`, `max_idle_time_secs: u32 = 300`
  - `ConnPool.PooledEntry` with `created_at_ms: i64`, `idle_since_ms: ?i64`
  - `ConnPool.acquire()` uses FIFO fairness via wait-ticket queue
  - `ConnPool.release()` evicts by lifetime / idle time
  - `ConnPool.keepAlive()` evicts stale idle connections

- [ ] **Step 1: Add per-connection metadata**

Change `ConnPool.idle` from `std.ArrayList(Conn)` to `std.ArrayList(PooledEntry)`:

```zig
const PooledEntry = struct {
    conn: Conn,
    created_at_ms: i64,
    idle_since_ms: ?i64 = null,
};
```

Update `ConnPool.init` to initialize these fields and `deinit` to destroy entries.

- [ ] **Step 2: Add lifecycle eviction in release()**

On `release()`, compute `now = Time.monotonicNowMilliseconds()`. If `now - entry.created_at_ms > lifetime_ms` or `entry.idle_since_ms` already stale, close the connection instead of returning it to idle.

- [ ] **Step 3: Implement FIFO wait fairness**

Replace the simple `cond.waitTimeout` loop with a ticket queue:

```zig
waiters: std.ArrayList(*Waiter),

const Waiter = struct {
    ready: std.atomic.Value(bool),
    next: ?*Waiter,
};
```

`acquire()` pushes a waiter, waits on its own condition, and is woken by `release()` in FIFO order. Simpler acceptable alternative: maintain a `head` index and `signal()` the longest-waiting waiter.

- [ ] **Step 4: Update keepAlive to honor idle timeout**

Iterate idle entries; close any whose `idle_since_ms` is older than `max_idle_time_secs`.

- [ ] **Step 5: Add tests**

```zig
test "conn pool evicts idle connection after timeout" { ... }
test "conn pool acquire is fair under contention" { ... }
```

- [ ] **Step 6: Run tests**

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
```

Expected: `478+ passed; 14 skipped; 0 failed`.

- [ ] **Step 7: Commit**

```bash
git add src/sqlx/sqlx.zig
git commit -m "feat(sqlx): connection pool lifecycle, idle eviction, and fair acquisition"
```

---

## Task 2: Pool Metrics and Observability

**Files:**
- Modify: `src/sqlx/sqlx.zig` (add `PoolMetrics` struct, wire into `ConnPool`)
- Test: add tests at end of `src/sqlx/sqlx.zig`

**Interfaces:**
- Produces:
  - `PoolMetrics` struct with `acquired_total`, `released_total`, `wait_ms_total`, `created_total`, `closed_total`, `stale_evicted_total`, `max_active`, `max_idle`
  - `ConnPool.metrics(self: *ConnPool) PoolMetrics`

- [ ] **Step 1: Define PoolMetrics**

```zig
pub const PoolMetrics = struct {
    acquired_total: u64 = 0,
    released_total: u64 = 0,
    wait_ms_total: u64 = 0,
    created_total: u64 = 0,
    closed_total: u64 = 0,
    stale_evicted_total: u64 = 0,
    max_active: u32 = 0,
    max_idle: u32 = 0,
};
```

- [ ] **Step 2: Wire metrics into ConnPool**

Add `metrics: PoolMetrics` to `ConnPool`. Update `acquire()`, `release()`, `reconnect()`, `warmup()`, `keepAlive()` to increment counters atomically (`@atomicRmw`).

- [ ] **Step 3: Add public getter**

```zig
pub fn getMetrics(self: *ConnPool) PoolMetrics {
    return @atomicLoad(PoolMetrics, &self.metrics, .acquire);
}
```

Note: `PoolMetrics` must be plain POD for atomic load to be valid; if not, return by copying under mutex.

- [ ] **Step 4: Test**

```zig
test "conn pool metrics track acquire and release" { ... }
```

- [ ] **Step 5: Run tests and commit**

---

## Task 3: True Streaming Cursor

**Files:**
- Modify: `src/sqlx/sqlx.zig` (extend `Cursor`, add driver hooks)
- Test: add tests at end of `src/sqlx/sqlx.zig`

**Interfaces:**
- Produces:
  - `CursorMode` enum: `buffered`, `streaming`
  - `Client.queryCursor(sql, args, .{ .mode = .streaming })`
  - MySQL: `mysql_use_result` path in `mysqlReadRowsStreaming`
  - PostgreSQL: `PQsendQuery` + `PQsingleRowMode` path

- [ ] **Step 1: Add CursorOptions**

```zig
pub const CursorOptions = struct {
    mode: CursorMode = .buffered,
};
pub const CursorMode = enum { buffered, streaming };
```

- [ ] **Step 2: Extend VTable with queryStreaming**

Add to `Conn.VTable`:

```zig
queryStreaming: ?*const fn (ptr: *anyopaque, allocator: Allocator, sql: []const u8, args: []const Value) errors.ResultT(Cursor) = null,
```

Optional for drivers; default falls back to buffered `Cursor`.

- [ ] **Step 3: Implement MySQL streaming cursor**

Create `mysqlReadRowsStreaming` using `mysql_use_result` and `mysql_fetch_row`. `Cursor.next()` advances the result set; `Cursor.deinit()` calls `mysql_free_result`.

- [ ] **Step 4: Implement PostgreSQL streaming cursor**

Use `PQsendQuery` + `PQsetSingleRowMode` + `PQgetResult`. Each `next()` fetches one `PGresult` row.

- [ ] **Step 5: Add public API**

```zig
pub fn queryCursor(self: *Client, sql_str: []const u8, args: []const Value, opts: CursorOptions) !Cursor
```

- [ ] **Step 6: Test**

```zig
test "mysql streaming cursor reads large result set lazily" { ... skip unless mysql ... }
test "postgres streaming cursor reads rows one by one" { ... skip unless postgres ... }
```

- [ ] **Step 7: Run tests and commit**

---

## Task 4: Batch Protocols (MySQL Prepared Multi-Execute, PG COPY)

**Files:**
- Modify: `src/sqlx/sqlx.zig` (MySQL batch prepared, PG COPY fallback)
- Test: add tests at end of `src/sqlx/sqlx.zig`

**Interfaces:**
- Produces:
  - `Client.batchInsertEx(self, table, columns, rows, .{ .mode = .protocol })`
  - `BatchMode` enum: `sql`, `protocol`
  - MySQL: `MySqlConn.batchInsertPrepared`
  - PostgreSQL: `PostgresConn.copyFrom`

- [ ] **Step 1: Define BatchMode and options**

```zig
pub const BatchMode = enum { sql, protocol };
pub const BatchInsertOptions = struct { mode: BatchMode = .sql };
```

- [ ] **Step 2: MySQL prepared-statement batch**

Prepare `INSERT INTO t (c1,c2) VALUES (?,?)`, then loop over rows, calling `mysql_stmt_bind_param` + `mysql_stmt_execute` for each. Accumulate `rows_affected` and `last_insert_id`.

- [ ] **Step 3: PostgreSQL COPY FROM STDIN**

Use `PQexec("COPY t (c1,c2) FROM STDIN WITH (FORMAT csv)")`, then `PQputCopyData` with CSV lines, then `PQputCopyEnd`.

- [ ] **Step 4: Add public API**

```zig
pub fn batchInsertEx(self: *Client, table: []const u8, columns: []const []const u8, rows: []const []const Value, opts: BatchInsertOptions) !ExecResult
```

Default `.sql` keeps current behavior; `.protocol` uses driver native batch.

- [ ] **Step 5: Test**

```zig
test "mysql batch insert protocol mode" { ... }
test "postgres copy from inserts multiple rows" { ... }
```

- [ ] **Step 6: Run tests and commit**

---

## Task 5: Final Integration Test and Tag

- [ ] **Step 1: Full test suite**

```bash
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test
```

Expected: all tests pass, 0 failed.

- [ ] **Step 2: Commit any remaining changes**

- [ ] **Step 3: Bump tag**

```bash
git tag -a v0.14.5 -m "v0.14.5: pool lifecycle, metrics, streaming cursor, batch protocols"
git push origin v0.14.5
```

---

## Self-Review

- **Spec coverage:** Each of the three recommended directions (pool, cursor, batch) has a dedicated task group.
- **Placeholder scan:** No TBD/TODO; each task has concrete code shapes and commands.
- **Type consistency:** `PoolMetrics`, `CursorOptions`, `BatchInsertOptions` names are consistent across tasks.
