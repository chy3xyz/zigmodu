#!/usr/bin/env bash
# Fail CI if banned error-handling patterns appear in production hot paths:
#   - bare `catch {}`        — swallows errors silently
#   - `catch unreachable`    — turns runtime errors into panics
#
# Scope (see scripts/lib/zig-scan.awk, shared with check-version.sh):
#   * whole file, not "up to the first `test \"` line" — that truncation used to
#     hide ~3000 lines of src/api/Server.zig and everything after the first test
#     in every other hot-path file.
#   * `test` blocks are skipped by brace balancing (top-level or indented),
#     string/char literals and `//` comments are stripped before counting, so
#     `"{}"` inside a test no longer unbalances the skip.
#   * multi-line empty catches are detected too:
#         foo() catch {
#         };
#         foo() catch
#             {};
#     (single-line matching alone let both shapes through).
#   * roots are `src` plus `tools/zmodu/src` — see SCAN_ROOTS below.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail=0

# The scanner itself — lexer, test-block skip, catch shapes — is shared with
# check-version.sh through scripts/lib/zig-scan.awk: one copy of "is this line
# production code?" keeps both gates agreeing on what a `test` block is.
LEX="$ROOT/scripts/lib/zig-scan.awk"

scan_file() {
  local file="$1" hits
  hits="$(awk -v mode=catch -f "$LEX" "$file" || true)"
  [[ -n "$hits" ]] || return 1
  printf '%s\n' "$hits"
}

# Server/sqlx are scanned with the same dynamic rule as every other hot path:
# the whole production surface of the file (test blocks skipped).
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

report() {
  local file="$1" hits="$2" mode="$3"
  local n
  n="$(printf '%s\n' "$hits" | wc -l | tr -d ' ')"
  if [[ "$mode" == "enforce" ]]; then
    echo "check-production: banned catch pattern in ${file}:" >&2
    fail=1
  else
    echo "check-production: WARN (not yet enforced) banned catch pattern in ${file}:" >&2
  fi
  printf '%s\n' "$hits" >&2
  echo "$n"
}

# Directories walked for the prefix rule below. `tools/zmodu/src/` is a separate
# Zig package with its own build.zig (built from the root as `zig build zmodu`),
# but it is the CLI the project ships, so it carries the same error-handling
# contract as `src/`.
SCAN_ROOTS=(src tools/zmodu/src)

# Everything else, same rule — but the rest of the tree is still being ratcheted,
# so a hit there reports a warning instead of failing the build. Promoting a path
# into ENFORCED_PREFIXES is the todo list: fix its hits, then add it here.
# src/ai/, src/extensions/, src/im/, src/log/ and src/runtime/ were promoted once
# their hits were fixed; tools/zmodu/src/ followed the same way (34 hits). The b10
# rule's own needle and its fixtures now spell the pattern from two pieces, so a
# raw grep over that root agrees with the scanner instead of reporting the
# linter's own sample source as a violation.
ENFORCED_PREFIXES=(src/ai/ src/api/ src/core/ src/extensions/ src/http/ src/im/ src/log/ src/metrics/ src/messaging/ src/runtime/ src/scheduler/ src/security/ tools/zmodu/src/)
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
  case " ${HOT_PATHS[*]} " in *" $f "*) continue;; esac
  if hits="$(scan_file "$f")"; then
    warned=$(( warned + $(report "$f" "$hits" warn) ))
  fi
done < <(find "${SCAN_ROOTS[@]}" -name '*.zig' | sort)

# Enforced tree: HOT_PATHS above plus everything under the enforced prefixes.
for f in "${HOT_PATHS[@]}"; do
  [[ -f "$f" ]] || continue
  if hits="$(scan_file "$f")"; then
    report "$f" "$hits" enforce >/dev/null
  fi
done

while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  is_enforced "$f" || continue
  case " ${HOT_PATHS[*]} " in *" $f "*) continue;; esac
  if hits="$(scan_file "$f")"; then
    report "$f" "$hits" enforce >/dev/null
  fi
done < <(find "${SCAN_ROOTS[@]}" -name '*.zig' | sort)

if [[ "$fail" -ne 0 ]]; then
  echo "check-production: replace catch {} / catch unreachable with logged catch |err| handling" >&2
  exit 1
fi

if [[ "$warned" -gt 0 ]]; then
  echo "check-production: OK (${warned} warning(s) in not-yet-enforced paths)"
else
  echo "check-production: OK"
fi
