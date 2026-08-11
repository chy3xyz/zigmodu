#!/usr/bin/env bash
# Fast test subset for overloaded machines / quick iteration.
# Usage: bash scripts/test-fast.sh [--filter "name"]
# Runs the sqlite-only driver build (much lighter than -Ddb=all) with an
# optional test filter. Full suite: ZIG_GLOBAL_CACHE_DIR=.zig-global-cache
# zig build test (needs idle CPU; on a loaded box use -j2/-j4).
set -euo pipefail
cd "$(dirname "$0")/.."
FILTER="${1:-}"
export ZIG_GLOBAL_CACHE_DIR=.zig-global-cache
if [ -n "$FILTER" ]; then
  exec zig build test -Ddb=sqlite -- --test-filter "$FILTER"
fi
exec zig build test -Ddb=sqlite
