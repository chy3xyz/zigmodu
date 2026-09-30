#!/usr/bin/env bash
# runtime-stress-record.sh [duration_ms] [history_path]
#
# Runs the runtime stress harness once and appends one schema-v1 JSON line to
# the history file. The harness itself does the append (it owns the counters);
# this wrapper only sets the environment: the history path, the commit (hex,
# validated by the harness), and the sandboxed global cache the repo uses.
#
# Read the series back with scripts/runtime_stress_trend.py. The nightly CI
# step sets RUNTIME_STRESS_HISTORY into $RUNNER_TEMP/nightly-logs/, which the
# nightly-soak-<sha> artifact archives — so the CI series exists without this
# script; this script is for local/release-time series.
set -euo pipefail
cd "$(dirname "$0")/.."

duration="${1:-60000}"
history="${2:-runtime-stress-history.jsonl}"

export RUNTIME_STRESS_HISTORY="$history"
export GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
: "${ZIG_GLOBAL_CACHE_DIR:=.zig-global-cache}"
export ZIG_GLOBAL_CACHE_DIR

zig build runtime-stress -Druntime-stress-duration-ms="$duration"
