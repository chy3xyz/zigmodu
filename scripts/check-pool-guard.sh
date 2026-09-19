#!/usr/bin/env bash
# Compile gate for `.mode = .pooled` on a worker that cannot be pooled.
#
# docs/RUNTIME.md §12.5: a `run`-owned worker has a loop of its own, so a pool
# thread running it would be occupied for as long as it runs — the pool would
# have one worker. `spawnSupervised` turns that into a `@compileError`, which
# cannot be asserted from inside the test suite (the failure *is* the test file's
# compilation), so it is asserted here the same way `check-tenant-scope.sh`
# asserts its own compile-time guard: two tiny compilations, red/green.
#
#   deny   `.mode = .pooled` + a `run`-owned worker  -> must FAIL, and name both
#                                                       `.dedicated` and `handle`
#   green  the same worker left `.dedicated`          -> must PASS
#   green  a message-driven worker, pooled            -> must PASS
#
# The fixtures are written at the repository root because a Zig module's root
# directory is the directory of its root source file: a fixture in a temporary
# subdirectory could not `@import("src/runtime/runtime.zig")`. They are removed
# on exit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

ZIG="${ZIG:-zig}"
FIXTURE_PREFIX="$ROOT/.pool-guard-fixture"
DENY="$FIXTURE_PREFIX-deny.zig"
DEDICATED="$FIXTURE_PREFIX-dedicated.zig"
POOLED="$FIXTURE_PREFIX-pooled.zig"
trap 'rm -f "$DENY" "$DEDICATED" "$POOLED"' EXIT

cat > "$DENY" <<'ZIG'
//! Must not compile: a `run`-owned worker cannot be pooled (§12.5).
const rt = @import("src/runtime/runtime.zig");

const LoopWorker = struct {
    pub fn run(self: *@This(), ctx: anytype) anyerror!void {
        _ = self;
        _ = ctx;
    }
};

export fn probe(runtime: *rt.Runtime) void {
    _ = runtime.spawn(LoopWorker, .{}, .{ .capacity = 8, .mode = .pooled }) catch {};
}
ZIG

cat > "$DEDICATED" <<'ZIG'
//! Same worker, default mode: dedicated is the mode a `run` worker is for.
const rt = @import("src/runtime/runtime.zig");

const LoopWorker = struct {
    pub fn run(self: *@This(), ctx: anytype) anyerror!void {
        _ = self;
        _ = ctx;
    }
};

export fn probe(runtime: *rt.Runtime) void {
    _ = runtime.spawn(LoopWorker, .{}, 8) catch {};
}
ZIG

cat > "$POOLED" <<'ZIG'
//! A message-driven worker is exactly what the pool is for.
const rt = @import("src/runtime/runtime.zig");

const MsgWorker = struct {
    pub const Message = u32;
    pub fn handle(self: *@This(), msg: u32, ctx: anytype) anyerror!void {
        _ = self;
        _ = msg;
        _ = ctx;
    }
};

export fn probe(runtime: *rt.Runtime) void {
    _ = runtime.spawn(MsgWorker, .{}, .{ .capacity = 8, .mode = .pooled }) catch {};
}
ZIG

compile() {
  # Prints combined stdout+stderr; returns the compiler's exit code.
  # `-fno-emit-bin` type-checks without linking (the fixtures never run).
  local out code
  set +e
  out="$("$ZIG" build-obj -fno-emit-bin -lc "$1" 2>&1)"
  code=$?
  set -e
  printf '%s\n' "$out"
  return "$code"
}

fail=0
note() { echo "check-pool-guard: $*"; }
err() { echo "check-pool-guard: $*" >&2; }

# 1. deny: must fail, and the failure must be actionable.
if out="$(compile "$DENY")"; then
  err "FAIL(deny): `.pooled` + a `run`-owned worker COMPILED — the guard is not firing"
  fail=1
else
  missing=""
  for needle in "cannot be pooled" ".dedicated" "handle"; do
    grep -q -- "$needle" <<<"$out" || missing="$missing '$needle'"
  done
  if [[ -n "$missing" ]]; then
    err "FAIL(deny): compile error is missing actionable text:$missing"
    printf '%s\n' "$out" >&2
    fail=1
  else
    note 'OK(deny): a `run`-owned worker cannot be spawned `.pooled`, and the error says what to do'
  fi
fi

# 2. green: the same worker in its own mode.
if out="$(compile "$DEDICATED")"; then
  note 'OK(green): the same `run`-owned worker still spawns `.dedicated`'
else
  err "FAIL(green): a `.dedicated` `run`-owned worker no longer compiles:"
  printf '%s\n' "$out" >&2
  fail=1
fi

# 3. green: a message-driven worker, pooled.
if out="$(compile "$POOLED")"; then
  note 'OK(green): a message-driven worker compiles `.pooled`'
else
  err "FAIL(green): a message-driven `.pooled` worker does not compile:"
  printf '%s\n' "$out" >&2
  fail=1
fi

exit "$fail"
