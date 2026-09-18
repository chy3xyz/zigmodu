#!/usr/bin/env bash
# Tenant-scope compile gate for `data.Repository(T)`.
#
# A model that declares `sql_tenant_column` gets its unscoped repository
# methods turned into compile errors, so "I forgot the tenant filter" fails the
# build instead of leaking another tenant's rows. That guard is invisible to
# `zig build test` (the fixtures that must fail on purpose cannot live in the
# test suite), so it is asserted here — three tiny compilations, red/green:
#
#   deny   model declares sql_tenant_column + calls findById        -> must FAIL
#   escape same model + calls findByIdUnscoped                      -> must PASS
#   plain  model without the decl + calls findById                  -> must PASS
#
# The fixtures are written at the repository root because a Zig module's root
# directory is the directory of its root source file: a fixture under a
# temporary *subdirectory* could not `@import("src/persistence/Orm.zig")`
# ("import of file outside module path"). They are removed on exit.
#
# The backend is a stub: these fixtures only have to be type-checked, and a
# stub keeps each compilation at ~0.15s instead of pulling sqlx's drivers in.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
FIXTURE_PREFIX="$ROOT/.tenant-scope-fixture"
STUB="$FIXTURE_PREFIX-stub.zig"
DENY="$FIXTURE_PREFIX-deny.zig"
ESCAPE="$FIXTURE_PREFIX-escape.zig"
PLAIN="$FIXTURE_PREFIX-plain.zig"
trap 'rm -f "$STUB" "$DENY" "$ESCAPE" "$PLAIN"' EXIT

cat > "$STUB" <<'ZIG'
//! Minimal backend stub: satisfies Orm.assertBackend; never executed.
const std = @import("std");
const orm = @import("src/persistence/Orm.zig");
const sqlx = @import("src/sqlx/sqlx.zig");

pub const Backend = struct {
    allocator: std.mem.Allocator,

    pub const Value = orm.OrmValue;
    pub const ExecResult = struct { rows_affected: u64 = 0, last_insert_id: ?i64 = null };
    pub const Tx = struct {};

    pub fn fromOrmValue(v: orm.OrmValue) Value {
        return v;
    }
    pub fn queryRow(self: @This(), comptime T: type, sql: []const u8, args: []const Value) anyerror!?T {
        _ = self;
        _ = sql;
        _ = args;
        return null;
    }
    pub fn queryRows(self: @This(), comptime T: type, sql: []const u8, args: []const Value) anyerror!sqlx.QueryResult(T) {
        _ = self;
        _ = sql;
        _ = args;
        return error.Unimplemented;
    }
    pub fn exec(self: @This(), sql: []const u8, args: []const Value) anyerror!ExecResult {
        _ = self;
        _ = sql;
        _ = args;
        return .{};
    }
    pub fn beginTx(self: @This()) anyerror!Tx {
        _ = self;
        return .{};
    }
    pub fn commitTx(self: @This(), tx: *Tx) anyerror!void {
        _ = self;
        _ = tx;
    }
    pub fn rollbackTx(self: @This(), tx: *Tx) anyerror!void {
        _ = self;
        _ = tx;
    }
    pub fn execTx(self: @This(), tx: *Tx, sql: []const u8, args: []const Value) anyerror!ExecResult {
        _ = self;
        _ = tx;
        _ = sql;
        _ = args;
        return .{};
    }
    pub fn queryRowTx(self: @This(), tx: *Tx, comptime T: type, sql: []const u8, args: []const Value) anyerror!?T {
        _ = self;
        _ = tx;
        _ = sql;
        _ = args;
        return null;
    }
    pub fn queryRowsTx(self: @This(), tx: *Tx, comptime T: type, sql: []const u8, args: []const Value) anyerror!sqlx.QueryResult(T) {
        _ = self;
        _ = tx;
        _ = sql;
        _ = args;
        return error.Unimplemented;
    }
};
ZIG

# --- red: opt-in model + an unscoped call must not compile ---------------
cat > "$DENY" <<'ZIG'
const orm = @import("src/persistence/Orm.zig");
const stub = @import(".tenant-scope-fixture-stub.zig");

const Row = struct {
    pub const sql_table_name: []const u8 = "row";
    pub const sql_tenant_column: ?[]const u8 = "tenant_id";
    id: i64 = 0,
    tenant_id: i64 = 0,
};

export fn probe(repo: *orm.Orm(stub.Backend).Repository(Row)) void {
    _ = repo.*.findById(@as(i64, 1)) catch {};
}
ZIG

# --- green: the same model, via the named escape hatch -------------------
cat > "$ESCAPE" <<'ZIG'
const orm = @import("src/persistence/Orm.zig");
const stub = @import(".tenant-scope-fixture-stub.zig");

const Row = struct {
    pub const sql_table_name: []const u8 = "row";
    pub const sql_tenant_column: ?[]const u8 = "tenant_id";
    id: i64 = 0,
    tenant_id: i64 = 0,
};

export fn probe(repo: *orm.Orm(stub.Backend).Repository(Row)) void {
    _ = repo.*.findByIdUnscoped(@as(i64, 1)) catch {};
    _ = repo.*.findPageUnscoped(1, 10) catch {};
    repo.*.deleteUnscoped(@as(i64, 1)) catch {};
}
ZIG

# --- green: a model that never opted in keeps every unscoped name --------
cat > "$PLAIN" <<'ZIG'
const orm = @import("src/persistence/Orm.zig");
const stub = @import(".tenant-scope-fixture-stub.zig");

const Row = struct {
    pub const sql_table_name: []const u8 = "row";
    id: i64 = 0,
    tenant_id: i64 = 0,
};

export fn probe(repo: *orm.Orm(stub.Backend).Repository(Row)) void {
    _ = repo.*.findById(@as(i64, 1)) catch {};
    _ = repo.*.findAll() catch {};
    _ = repo.*.count() catch {};
    _ = repo.*.findPage(1, 10) catch {};
    _ = repo.*.insert(.{ .id = 1, .tenant_id = 1 }) catch {};
    _ = repo.*.update(.{ .id = 1, .tenant_id = 1 }) catch {};
    repo.*.delete(@as(i64, 1)) catch {};
}
ZIG

compile() {
  # Prints combined stdout+stderr; returns the compiler's exit code.
  local out code
  set +e
  out="$("$ZIG" build-obj -fno-emit-bin "$1" 2>&1)"
  code=$?
  set -e
  printf '%s\n' "$out"
  return "$code"
}

fail=0
note() { echo "check-tenant-scope: $*"; }
err() { echo "check-tenant-scope: $*" >&2; }

# 1. deny: must fail, and the failure must be actionable.
if out="$(compile "$DENY")"; then
  err "FAIL(deny): an unscoped findById on a sql_tenant_column model COMPILED — the guard is not firing"
  fail=1
else
  missing=""
  for needle in findByIdUnscoped belonging\ to\ every\ tenant findByIdForTenant sql_tenant_column; do
    grep -q "$needle" <<<"$out" || missing="$missing '$needle'"
  done
  if [[ -n "$missing" ]]; then
    err "FAIL(deny): compile error is missing actionable text:$missing"
    printf '%s\n' "$out" >&2
    fail=1
  else
    note "OK(deny): findById on a tenant-scoped model fails to compile, and names findByIdUnscoped"
  fi
fi

# 2. escape hatch: must compile.
if out="$(compile "$ESCAPE")"; then
  note "OK(escape): findByIdUnscoped / findPageUnscoped / deleteUnscoped compile"
else
  err "FAIL(escape): the *Unscoped escape hatch does not compile:"
  printf '%s\n' "$out" >&2
  fail=1
fi

# 3. plain: models that never opted in must be untouched.
if out="$(compile "$PLAIN")"; then
  note "OK(plain): an unscoped model keeps findById/findAll/count/findPage/insert/update/delete"
else
  err "FAIL(plain): a model without sql_tenant_column no longer compiles:"
  printf '%s\n' "$out" >&2
  fail=1
fi

if [[ "$fail" -ne 0 ]]; then
  err "tenant-scope guard is not in the expected state (see above)"
  exit 1
fi
note "OK (3/3 fixtures: guard fires, escape hatch works, opt-out unaffected)"
