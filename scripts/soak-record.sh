#!/usr/bin/env bash
# soak-record.sh [history_dir]
#
# Runs both soak harnesses once and appends one schema-v1 JSON line each to
# `soak-history.jsonl` / `soak-cluster-history.jsonl` in `history_dir`
# (default: the repository root, both files gitignored). The harnesses do the
# appends themselves; this wrapper only sets the environment: the history
# paths, the commit (hex, validated by the harness) and the sandboxed global
# cache the repo uses.
#
# Read the series back with scripts/soak_trend.py. The nightly CI sets
# SOAK_HISTORY / SOAK_CLUSTER_HISTORY into $RUNNER_TEMP/nightly-logs/, which
# the nightly-soak-<sha> artifact archives — so the CI series exists without
# this script; this script is for local/release-time series.
#
# Optional sizing (same knobs as the build steps):
#   SOAK_CLIENTS=64 SOAK_ITERATIONS=200 ./scripts/soak-record.sh
set -euo pipefail
cd "$(dirname "$0")/.."

history_dir="${1:-.}"
mkdir -p "$history_dir"

clients="${SOAK_CLIENTS:-16}"
iterations="${SOAK_ITERATIONS:-50}"

export GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
: "${ZIG_GLOBAL_CACHE_DIR:=.zig-global-cache}"
export ZIG_GLOBAL_CACHE_DIR

SOAK_HISTORY="$history_dir/soak-history.jsonl" \
  zig build soak -Dsoak-clients="$clients" -Dsoak-iterations="$iterations"

SOAK_CLUSTER_HISTORY="$history_dir/soak-cluster-history.jsonl" \
  zig build soak-cluster

python3 scripts/soak_trend.py \
  "$history_dir/soak-history.jsonl" "$history_dir/soak-cluster-history.jsonl"
