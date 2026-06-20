#!/usr/bin/env bash
# CI smoke: compile, unit tests, API import gate.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

zig fmt --check src/
zig build
zig build test
zig build check-api
zig build check

echo "smoke: OK"
