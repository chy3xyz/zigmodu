#!/usr/bin/env bash
# Fail CI if banned error-handling patterns appear in production hot paths
# (test blocks excluded by truncating at the first `test "` line):
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
  # Comment lines are skipped: prose that mentions the pattern (e.g. explaining
  # why it is banned) is not a violation.
  hits="$(awk -v max="$max_line" 'NR <= max && $0 !~ /^[[:space:]]*\/\// && (/catch \{\}/ || /catch unreachable/) {print FILENAME ":" NR ":" $0}' "$file" || true)"
  if [[ -n "$hits" ]]; then
    echo "check-production: banned catch pattern in ${file} (lines 1-${max_line}):" >&2
    echo "$hits" >&2
    fail=1
  fi
}

# Server/sqlx are scanned with the same dynamic rule as every other hot path:
# production code up to the first `test "` block. Hard-coded line caps used to
# silently exempt 49%/62% of these files — do not reintroduce them.
HOT_PATHS=(
  src/api/Server.zig
  src/sqlx/sqlx.zig
  src/redis/redis.zig
  src/messaging/Nats.zig
  src/core/ClusterMembership.zig
  src/core/DistributedEventBus.zig
  src/core/cluster/RaftElection.zig
  src/core/eventbus/WAL.zig
  src/persistence/Orm.zig
)

for f in "${HOT_PATHS[@]}"; do
  [[ -f "$f" ]] || continue
  first_test="$(grep -n '^test "' "$f" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_test" ]]; then
    scan_range "$f" $((first_test - 1))
  else
    scan_range "$f" 99999
  fi
done

# Everything else, same rule — but the rest of the tree is still being ratcheted
# (extensions/ai/im/log carry older best-effort swallows), so those report a
# warning instead of failing the build. Promoting a path into ENFORCED_PATHS is
# the todo list: fix its hits, then add it here.
ENFORCED_PREFIXES=(src/api/ src/core/ src/http/ src/metrics/ src/messaging/ src/scheduler/ src/security/)
is_enforced() {
  local f="$1"
  for pfx in "${ENFORCED_PREFIXES[@]}"; do
    [[ "$f" == ${pfx}* ]] && return 0
  done
  return 1
}

warned=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  is_enforced "$f" && continue
  first_test="$(grep -n '^test "' "$f" | head -1 | cut -d: -f1 || true)"
  max=$(( ${first_test:-99999} - 1 ))
  [[ "$first_test" == "" ]] && max=99999
  hits="$(awk -v max="$max" 'NR <= max && $0 !~ /^[[:space:]]*\/\// && (/catch \{\}/ || /catch unreachable/) {print FILENAME ":" NR}' "$f" || true)"
  if [[ -n "$hits" ]]; then
    warned=$(( warned + $(printf '%s\n' "$hits" | wc -l) ))
    echo "check-production: WARN (not yet enforced) banned catch pattern:" >&2
    echo "$hits" >&2
  fi
done < <(find src -name '*.zig' | sort)

# Enforced tree: HOT_PATHS above plus everything under the enforced prefixes.
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  is_enforced "$f" || continue
  case " ${HOT_PATHS[*]} " in *" $f "*) continue;; esac
  first_test="$(grep -n '^test "' "$f" | head -1 | cut -d: -f1 || true)"
  if [[ -n "$first_test" ]]; then
    scan_range "$f" $((first_test - 1))
  else
    scan_range "$f" 99999
  fi
done < <(find src -name '*.zig' | sort)

if [[ "$fail" -ne 0 ]]; then
  echo "check-production: replace catch {} / catch unreachable with logged catch |err| handling" >&2
  exit 1
fi

echo "check-production: OK"
