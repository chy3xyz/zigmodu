#!/usr/bin/env bash
# Compile-time budget reporter/gate.
#
# The enforced budget lives in code: `src/test/ComptimeBudget.zig` mounts 256
# routes at comptime, so a fixed quota (or an O(n²) fold) fails the build with
# no timing flakiness. This script adds the numbers — wall clock and peak RSS —
# and fails only on a catastrophic regression (`COMPTIME_BUDGET_SECS` /
# `COMPTIME_BUDGET_RSS_MB`), because shared CI runners are not a benchmark.
#
#   COMPTIME_BUDGET_SECS=300 COMPTIME_BUDGET_RSS_MB=4096 bash scripts/check-comptime-budget.sh
#
# Skip inside a release gate with SKIP_COMPTIME_BUDGET=1.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "${SKIP_COMPTIME_BUDGET:-0}" == "1" ]]; then
  echo "check-comptime-budget: skipped (SKIP_COMPTIME_BUDGET=1)"
  exit 0
fi
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"
secs_budget="${COMPTIME_BUDGET_SECS:-300}"
rss_budget_mb="${COMPTIME_BUDGET_RSS_MB:-4096}"

log="$(mktemp -t zm-comptime-budget.XXXXXX)"
trap 'rm -f "$log"' EXIT

start=$(date +%s)
# Force a fresh run of the budget test; the artifact itself is what we time.
bash scripts/zig-build-test-guarded.sh --timeout 900 build test \
  -Dtest-force-run=true "-Dtest-filter=comptime budget" --summary all >"$log" 2>&1
status=$?
elapsed=$(( $(date +%s) - start ))

rss_kb=0
if [[ -f "$log" ]]; then
  # Zig's --summary all prints MaxRSS per compile step ("MaxRSS:123M").
  rss="$(grep -oE 'MaxRSS:[0-9.]+[KMG]' "$log" | tail -1 | cut -d: -f2)"
  case "$rss" in
    *G) rss_kb=$(( ${rss%G} * 1024 * 1024 )) ;;
    *M) rss_kb=$(( ${rss%M} * 1024 )) ;;
    *K) rss_kb=${rss%K} ;;
  esac
fi
rss_mb=$(( rss_kb / 1024 ))

echo "check-comptime-budget: 256-route comptime build took ${elapsed}s, peak RSS ${rss_mb} MiB (budget ${secs_budget}s / ${rss_budget_mb} MiB)"

if [[ "$status" -ne 0 ]]; then
  echo "check-comptime-budget: the compile-time budget test failed:" >&2
  tail -20 "$log" >&2
  exit 1
fi
if (( elapsed > secs_budget )); then
  echo "check-comptime-budget: ${elapsed}s exceeds the ${secs_budget}s budget — check for a comptime regression (see docs/reference/COMPTIME.md)" >&2
  exit 1
fi
if (( rss_mb > rss_budget_mb )); then
  echo "check-comptime-budget: ${rss_mb} MiB exceeds the ${rss_budget_mb} MiB budget — check for a comptime regression (see docs/reference/COMPTIME.md)" >&2
  exit 1
fi
exit 0
