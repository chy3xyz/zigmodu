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
#   bash scripts/test-fast.sh --count                           # only the one count line
#   bash scripts/test-fast.sh -- --summary all                  # extra `zig build test` args
#
# `-Ddb` defaults to sqlite here (a light subset). The framework's own suite
# wants every driver: `bash scripts/test-fast.sh --db all [--filter X]`.
#
# ── The two counts, and which one is the reading ──────────────────────────────
#
# A test run in this repository has **two** legitimate numbers, and calling them
# by one name is how a baseline got recorded wrong: `zig build test`'s main suite
# alone, and the total over all five test binaries. So every run now prints both,
# each on its own line, each with the label that says which it is:
#
#   zm-test-count: aggregate ...    <- the reading. Quote this one.
#   zm-test-count: main-binary ...  <- the largest binary (the library suite).
#                                      Locates a failure; never a baseline.
#   zm-test-count: binary ...       <- every other artifact, for the same purpose.
#
# The aggregate line carries `source=`, because the count comes from one of two
# places and they are not the same mechanism: `source=build-summary` (zig's own
# runner, no filter) or `source=zm-test-runner` (the runtime filter in
# `scripts/test-runner.zig`, which skips the aggregate `test { … }` blocks). Both
# report the same denominator today — 1450 tests, 5 binaries, `-Ddb=all` — and the
# two sources are cross-checked against each other when both are present.
#
# `--count` prints that one aggregate line and nothing else on stdout (the zig
# output goes to the log), so a caller can capture it:
#   n="$(bash scripts/test-fast.sh --count --db all)"
#
# The convention — what to quote, what each label obliges you to do, and how this
# relates to the benchmark reading convention — is `docs/dev/READING_NUMBERS.md`.
#
# Exit codes: 0 ran and passed · 1 tests failed (zig build's code) ·
#             2 filter matched no test · 3 result could not be read · 64 usage error
# "Could not be read" (3) covers a warm cache that replayed a run instead of
# executing one: `zig build test` then prints `run test cached` and no counts at
# all, and this script does not call that success. `--force-run` is the way to get
# a run you can quote.
set -euo pipefail
cd "$(dirname "$0")/.."

FILTER=""
DB="sqlite"
FORCE_RUN=""
COUNT_ONLY=""
EXTRA=()

usage() {
  sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'
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
    --count) COUNT_ONLY=1; shift ;;
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

if [[ -n "$COUNT_ONLY" ]]; then
  # Everything but the count line goes to stderr, so `$(… --count)` is one line.
  echo "test-fast: zig ${ARGS[*]}" >&2
else
  echo "test-fast: zig ${ARGS[*]}"
fi
START=$SECONDS
set +e
if [[ -n "$COUNT_ONLY" ]]; then
  echo "test-fast: --count — zig output goes to the log; stdout carries only the count line" >&2
  zig "${ARGS[@]}" >"$LOG" 2>&1
  STATUS=$?
else
  zig "${ARGS[@]}" 2>&1 | tee "$LOG"
  STATUS=${PIPESTATUS[0]}
fi
set -e
ELAPSED=$((SECONDS - START))

if [[ $STATUS -ne 0 ]]; then
  echo "test-fast: FAILED — zig build test exited $STATUS (${ELAPSED}s)" >&2
  exit "$STATUS"
fi

# ── the counts ────────────────────────────────────────────────────────────────
# One source or the other, never both: under `-Dtest-filter=` the suite runs on
# `scripts/test-runner.zig`, which prints one `zm-test-runner:` line per test
# binary and makes the build summary count nothing; without a filter zig's own
# runner prints a `+- run test N pass (M total)` line per binary in the build
# summary tree, and the `Build Summary:` line carries the total. Both are parsed
# into the same shape, and the labels below say which one a number came from.
AGG_SOURCE=""
AGG_TOTAL=0
AGG_PASSED=0
AGG_SKIPPED=0
AGG_FAILED=0
AGG_LEAKED=0
AGG_SELECTED=0
BINARIES=0
BINARY_ROWS=()

RUNNER_LINES="$(grep -E '^zm-test-runner: ' "$LOG" || true)"

if [[ -n "$RUNNER_LINES" ]]; then
  AGG_SOURCE="zm-test-runner"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pair="$(printf '%s' "$line" | sed -n 's/.*selected \([0-9][0-9]*\) of \([0-9][0-9]*\) tests.*/\1 \2/p')"
    [[ -n "$pair" ]] || continue
    selected="${pair%% *}"
    total="${pair##* }"
    quad="$(printf '%s' "$line" | sed -n 's/.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) skipped; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) leaked.*/\1 \2 \3 \4/p')"
    passed=0; skipped=0; failed=0; leaked=0
    if [[ -n "$quad" ]]; then
      read -r passed skipped failed leaked <<<"$quad"
    fi
    AGG_SELECTED=$((AGG_SELECTED + selected))
    AGG_TOTAL=$((AGG_TOTAL + total))
    AGG_PASSED=$((AGG_PASSED + passed))
    AGG_SKIPPED=$((AGG_SKIPPED + skipped))
    AGG_FAILED=$((AGG_FAILED + failed))
    AGG_LEAKED=$((AGG_LEAKED + leaked))
    BINARIES=$((BINARIES + 1))
    BINARY_ROWS+=("$total $selected $passed $skipped")
  done <<< "$RUNNER_LINES"
else
  # Zig's own runner. The aggregate is the build summary's own total; the sum of
  # the per-binary rows is recomputed next to it and has to agree — a
  # disagreement is the one case where this script cannot say which number is
  # the reading, and it exits 3 rather than picking one.
  AGG_SOURCE="build-summary"
  summary_line="$(grep -E 'Build Summary: .*tests passed' "$LOG" | tail -1 || true)"
  pair="$(printf '%s' "$summary_line" | sed -n 's/.* \([0-9][0-9]*\)\/\([0-9][0-9]*\) tests passed.*/\1 \2/p')"
  if [[ -n "$pair" ]]; then
    AGG_PASSED="${pair%% *}"
    AGG_TOTAL="${pair##* }"
  fi
  AGG_SKIPPED="$(printf '%s' "$summary_line" | sed -n 's/.*(\([0-9][0-9]*\) skipped).*/\1/p')"
  [[ -n "$AGG_SKIPPED" ]] || AGG_SKIPPED=0

  sum_total=0
  sum_passed=0
  sum_skipped=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    total="$(printf '%s' "$line" | sed -n 's/.*(\([0-9][0-9]*\) total).*/\1/p')"
    passed="$(printf '%s' "$line" | sed -n 's/.*run test \([0-9][0-9]*\) pass.*/\1/p')"
    [[ -n "$total" && -n "$passed" ]] || continue
    skipped="$(printf '%s' "$line" | sed -n 's/.* \([0-9][0-9]*\) skip.*/\1/p')"
    [[ -n "$skipped" ]] || skipped=0
    sum_total=$((sum_total + total))
    sum_passed=$((sum_passed + passed))
    sum_skipped=$((sum_skipped + skipped))
    BINARIES=$((BINARIES + 1))
    BINARY_ROWS+=("$total $passed $passed $skipped")
  done < <(grep -E 'run test [0-9][0-9]* pass' "$LOG" || true)

  if [[ -n "$pair" && $BINARIES -gt 0 ]] && { [ "$sum_total" -ne "$AGG_TOTAL" ] || [ "$sum_passed" -ne "$AGG_PASSED" ]; }; then
    echo "test-fast: the build summary and the per-binary lines disagree — cannot tell which count is the reading:" >&2
    echo "test-fast:   build summary:  $AGG_PASSED/$AGG_TOTAL passed, $AGG_SKIPPED skipped" >&2
    echo "test-fast:   sum of binaries: $sum_passed/$sum_total passed, $sum_skipped skipped ($BINARIES binaries)" >&2
    exit 3
  fi
  if [[ -z "$pair" ]]; then
    # No summary total: fall back to the sum, which is the same fact computed
    # from the tree, but only when every binary was readable.
    AGG_PASSED=$sum_passed
    AGG_TOTAL=$sum_total
    AGG_SKIPPED=$sum_skipped
  fi
fi

if [[ $AGG_TOTAL -eq 0 || $BINARIES -eq 0 ]]; then
  echo "test-fast: no test counts in the output — cannot tell what ran." >&2
  echo "test-fast: a warm cache makes zig replay the previous run without executing it," >&2
  echo "test-fast: printing 'run test cached' and no counts;" >&2
  echo "test-fast: re-run with --force-run when you need a run you can quote." >&2
  exit 3
fi

if [[ -n "$FILTER" && $AGG_SELECTED -eq 0 && $AGG_SOURCE = "zm-test-runner" ]]; then
  echo "test-fast: FAILED — filter '$FILTER' matched 0 of $AGG_TOTAL tests: nothing was verified (${ELAPSED}s)" >&2
  echo "test-fast: the filter is a plain substring of a test's fully qualified name, e.g." >&2
  echo "test-fast:   core.cluster.RaftElection.test.RaftElection: a tick and an inbound RPC …" >&2
  echo "test-fast: check the spelling, or run --force-run without --filter to list the suite." >&2
  exit 2
fi

# The one line a caller captures: it is the aggregate, and it says so, with the
# mode and the db it was measured in. Nothing else goes to stdout under --count.
aggregate_line="zm-test-count: aggregate"
if [[ "$AGG_SOURCE" = "zm-test-runner" ]]; then
  aggregate_line+=" $AGG_SELECTED/$AGG_TOTAL selected passed=$AGG_PASSED skipped=$AGG_SKIPPED failed=$AGG_FAILED leaked=$AGG_LEAKED"
else
  aggregate_line+=" $AGG_PASSED/$AGG_TOTAL passed skipped=$AGG_SKIPPED"
fi
aggregate_line+=" binaries=$BINARIES db=$DB filter=${FILTER:-none} source=$AGG_SOURCE"
if [[ "$AGG_SOURCE" = "zm-test-runner" && $AGG_SELECTED -ne $AGG_TOTAL ]]; then
  aggregate_line+=" unnamed_blocks_not_selected=$((AGG_TOTAL - AGG_SELECTED))"
fi

if [[ -n "$COUNT_ONLY" ]]; then
  echo "$aggregate_line"
  exit 0
fi

if [[ -n "$FILTER" ]]; then
  echo "test-fast: OK — $AGG_SELECTED of $AGG_TOTAL tests matched '$FILTER' in ${ELAPSED}s ($AGG_PASSED passed, $AGG_SKIPPED skipped)"
else
  echo "test-fast: OK — $AGG_PASSED/$AGG_TOTAL tests passed ($AGG_SKIPPED skipped) in ${ELAPSED}s (-Ddb=$DB)"
fi

echo "$aggregate_line"
# The largest binary is the library suite. It is printed because it is the number
# a failure is located by, and labelled so it can never be quoted as the total.
first=1
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  read -r total selected passed skipped <<<"$row"
  detail="$passed/$total passed"
  # In the filter mode `total` counts the unnamed aggregate blocks too, which the
  # runner does not select — so a per-binary row says both numbers when they
  # differ, and neither can be read as the other.
  if [[ "$AGG_SOURCE" = "zm-test-runner" && "$selected" != "$total" ]]; then
    detail="$detail (selected=$selected of $total)"
  fi
  detail="$detail skipped=$skipped"
  if [[ $first -eq 1 ]]; then
    echo "zm-test-count: main-binary $detail (largest of $BINARIES — locates a failure, NOT the number to quote)"
    first=0
  else
    echo "zm-test-count: binary $detail"
  fi
done < <(printf '%s\n' ${BINARY_ROWS[@]+"${BINARY_ROWS[@]}"} | sort -rn -k1,1)
echo "test-fast: quote the aggregate line; the convention is docs/dev/READING_NUMBERS.md"
if [[ -n "$RUNNER_LINES" ]]; then
  printf '%s\n' "$RUNNER_LINES" | sed 's/^zm-test-runner: /test-fast:   /'
fi
