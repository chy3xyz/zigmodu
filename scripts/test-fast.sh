#!/usr/bin/env bash
# Focused test runs — the checked entry point for "run only the tests I care about".
#
# Why a wrapper exists at all: the obvious forms lie.
#
#   * `zig build test -- --test-filter X` — `zig build` drops everything after
#     `--` on the floor. Measured on 0.17.0-dev.2151: the filter is ignored, the
#     full suite runs (~47s), exit code 0. (Verified again with a filter that
#     cannot match anything — same 47s, same success.)
#   * `zig build test -Dtest-filter` used to be Zig's own compile-time filter.
#     That cannot reach this repo's tests: an excluded test is not analyzed, so
#     its `@import`s never run and the imported files' tests are never seen. The
#     suite hangs off one aggregate test (`src/tests.zig`), so a name filter
#     compiled a binary with a single, unmatchable unnamed test and exited 0.
#   * `zig test src/root.zig --test-filter X` — a bare `zig test` cannot resolve
#     this package's `build_options` module or the SQL driver links; the binary it
#     produces also *rejects* `--test-filter` at runtime (the filter is
#     compile-time, so the flag is not a runtime option). Do not use that form.
#
# So the filter is applied at runtime by `scripts/test-runner.zig`, wired in by
# `-Dtest-filter=` in build.zig. This script is the checked caller: it reports how
# many tests were selected, and refuses to call a run green when the filter
# selected nothing.
#
# Usage:
#   bash scripts/test-fast.sh                                   # whole sqlite subset
#   bash scripts/test-fast.sh --filter RaftElection             # only matching tests
#   bash scripts/test-fast.sh -f "RaftElection: a tick" --db all
#   bash scripts/test-fast.sh --force-run                       # full run, no cached replay
#   bash scripts/test-fast.sh -- --summary all                  # extra `zig build test` args
#
# `-Ddb` defaults to sqlite here (a light subset). The framework's own suite
# wants every driver: `bash scripts/test-fast.sh --db all [--filter X]`.
#
# Exit codes: 0 ran and passed · 1 tests failed (zig build's code) ·
#             2 filter matched no test · 3 result could not be read · 64 usage error
set -euo pipefail
cd "$(dirname "$0")/.."

FILTER=""
DB="sqlite"
FORCE_RUN=""
EXTRA=()

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--filter)
      [[ $# -ge 2 ]] || { echo "test-fast: --filter needs a value" >&2; exit 64; }
      FILTER="$2"; shift 2 ;;
    --filter=*) FILTER="${1#--filter=}"; shift ;;
    --db)
      [[ $# -ge 2 ]] || { echo "test-fast: --db needs a value" >&2; exit 64; }
      DB="$2"; shift 2 ;;
    --db=*) DB="${1#--db=}"; shift ;;
    -Ddb=*) DB="${1#-Ddb=}"; shift ;;
    --force-run) FORCE_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; EXTRA=("$@"); break ;;
    -*) echo "test-fast: unknown option '$1'" >&2; usage >&2; exit 64 ;;
    *) # Back-compat: the previous version took the filter as a bare argument
       # (while its own header documented `--filter`), so accept both.
      [[ -z "$FILTER" ]] || { echo "test-fast: unexpected argument '$1'" >&2; exit 64; }
      FILTER="$1"; shift ;;
  esac
done

ZIG_CACHE="${ZIG_GLOBAL_CACHE_DIR:-.zig-global-cache}"
export ZIG_GLOBAL_CACHE_DIR="$ZIG_CACHE"

LOG="$(mktemp -t zm-test-fast.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

ARGS=(build test "-Ddb=$DB" --summary all)
[[ -n "$FILTER" ]] && ARGS+=("-Dtest-filter=$FILTER")
[[ -n "$FORCE_RUN" ]] && ARGS+=("-Dtest-force-run=true")
[[ ${#EXTRA[@]} -gt 0 ]] && ARGS+=("${EXTRA[@]}")

echo "test-fast: zig ${ARGS[*]}"
START=$SECONDS
set +e
zig "${ARGS[@]}" 2>&1 | tee "$LOG"
STATUS=${PIPESTATUS[0]}
set -e
ELAPSED=$((SECONDS - START))

if [[ $STATUS -ne 0 ]]; then
  echo "test-fast: FAILED — zig build test exited $STATUS (${ELAPSED}s)" >&2
  exit "$STATUS"
fi

RUNNER_LINES="$(grep -E '^zm-test-runner: ' "$LOG" || true)"

if [[ -z "$RUNNER_LINES" ]]; then
  # No filtered runner in play: either `--force-run` (Zig's own runner, counts
  # land in the build summary) or a warm cache that replayed a previous run.
  if grep -qE '[0-9]+/[0-9]+ tests passed' "$LOG"; then
    echo "test-fast: OK — $(grep -oE '[0-9]+/[0-9]+ tests passed[^;]*' "$LOG" | tail -1) in ${ELAPSED}s (-Ddb=$DB)"
    exit 0
  fi
  echo "test-fast: no test counts in the output — cannot tell what ran." >&2
  echo "test-fast: a warm cache makes zig replay the previous run without executing it;" >&2
  echo "test-fast: re-run with --force-run when you need a run you can quote." >&2
  if [[ -n "$FILTER" ]]; then exit 3; fi
  exit 0
fi

SELECTED=0
TOTAL=0
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  counts="$(printf '%s' "$line" | sed -n 's/^zm-test-runner: selected \([0-9][0-9]*\) of \([0-9][0-9]*\) tests.*/\1 \2/p')"
  [[ -n "$counts" ]] || continue
  SELECTED=$((SELECTED + ${counts%% *}))
  TOTAL=$((TOTAL + ${counts##* }))
done <<< "$RUNNER_LINES"

if [[ -n "$FILTER" && $SELECTED -eq 0 ]]; then
  echo "test-fast: FAILED — filter '$FILTER' matched 0 of $TOTAL tests: nothing was verified (${ELAPSED}s)" >&2
  echo "test-fast: the filter is a plain substring of a test's fully qualified name, e.g." >&2
  echo "test-fast:   core.cluster.RaftElection.test.RaftElection: a tick and an inbound RPC …" >&2
  echo "test-fast: check the spelling, or run --force-run without --filter to list the suite." >&2
  exit 2
fi

if [[ -n "$FILTER" ]]; then
  echo "test-fast: OK — $SELECTED of $TOTAL tests matched '$FILTER' in ${ELAPSED}s"
else
  echo "test-fast: OK — $SELECTED of $TOTAL tests ran in ${ELAPSED}s (-Ddb=$DB)"
fi
printf '%s\n' "$RUNNER_LINES" | sed 's/^zm-test-runner: /test-fast:   /'
