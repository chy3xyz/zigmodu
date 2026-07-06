#!/usr/bin/env bash
# Fail CI if banned error-handling patterns appear in production hot paths
# (tests excluded by line cap):
#   - bare `catch {}`        — swallows errors silently
#   - `catch unreachable`    — turns runtime errors into panics
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

scan_range() {
  local file="$1"
  local max_line="$2"
  local hits
  hits="$(awk -v max="$max_line" 'NR <= max && (/catch \{\}/ || /catch unreachable/) {print FILENAME ":" NR ":" $0}' "$file" || true)"
  if [[ -n "$hits" ]]; then
    echo "check-production: banned catch pattern in ${file} (lines 1-${max_line}):" >&2
    echo "$hits" >&2
    fail=1
  fi
}

scan_range src/api/Server.zig 1700
scan_range src/sqlx/sqlx.zig 2739

for f in src/security/*.zig; do
  [[ -f "$f" ]] || continue
  first_test="$(grep -n '^test "' "$f" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_test" ]]; then
    scan_range "$f" $((first_test - 1))
  else
    scan_range "$f" 99999
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "check-production: replace catch {} / catch unreachable with logged catch |err| handling" >&2
  exit 1
fi

echo "check-production: OK"
