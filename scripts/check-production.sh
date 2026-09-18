#!/usr/bin/env bash
# Fail CI if banned error-handling patterns appear in production hot paths:
#   - bare `catch {}`        — swallows errors silently
#   - `catch unreachable`    — turns runtime errors into panics
#
# Scope (see SCANNER below):
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

# awk scanner. Portable BSD/gawk: no `-P`, no `\s`, no interval regexes.
# Emits one line per hit: "<lineno>\t<shaped line>".
SCANNER="$(cat <<'AWK'
function strip_code(s,   out, i, n, c, nx, in_str, in_char) {
  out = ""; n = length(s); in_str = 0; in_char = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (in_str) {
      if (c == "\\") { i++; continue }
      if (c == "\"") in_str = 0
      continue
    }
    if (in_char) {
      if (c == "\\") { i++; continue }
      if (c == "'") in_char = 0
      continue
    }
    if (c == "\"") { in_str = 1; continue }
    if (c == "'") { in_char = 1; continue }
    if (c == "/" && substr(s, i + 1, 1) == "/") break
    out = out c
  }
  return out
}
function net_braces(s,   i, n, c, d) {
  d = 0; n = length(s)
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "{") d++
    else if (c == "}") d--
  }
  return d
}
function rtrim(s) { sub(/[ \t\r]+$/, "", s); return s }
function ltrim(s) { sub(/^[ \t\r]+/, "", s); return s }
function last_index(s, needle,   p, q, last) {
  last = 0; q = 1
  while ((p = index(substr(s, q), needle)) > 0) { last = q + p - 1; q = last + 1 }
  return last
}
# Classify a `catch` body fragment: "empty" (nothing between the braces),
# "open" (`{` opens here, `}` still pending) or "other".
function body_kind(b,   t) {
  t = rtrim(ltrim(b))
  if (t == "") return "kw"
  if (t == "{") return "open"
  # A trailing `;` (statement position) or `,` (switch arm / initializer list)
  # is punctuation, not body — without stripping it, `x() catch {},` slipped
  # through the check entirely.
  while (t != "" && (substr(t, length(t)) == ";" || substr(t, length(t)) == ",")) {
    t = rtrim(substr(t, 1, length(t) - 1))
  }
  if (t == "{}" || t == "{ }" || t == "{\t}") return "empty"
  return "other"
}
# What does the last `catch` on this (stripped) line look like?
function catch_kind(code,   p, tail, rest, c2) {
  if (index(code, "catch") == 0) return "none"
  p = last_index(code, "catch")
  tail = rtrim(substr(code, p + 5))
  if (tail == "") return "kw"
  if (substr(tail, 1, 1) == "|") {
    c2 = index(substr(tail, 2), "|")
    if (c2 == 0) return "none"
    rest = substr(tail, c2 + 2)
    if (rtrim(ltrim(rest)) == "") return "kw"
    return body_kind(rest)
  }
  return body_kind(tail)
}
BEGIN { in_test = 0; depth = 0; kw = 0; open = 0 }
{
  raw = $0
  # Zig multiline string literal (`\\…`) — braces there are prose, not code.
  if (raw ~ /^[ \t]*\\\\/) next
  code = strip_code(raw)
  if (rtrim(code) == "") next
  if (in_test) {
    depth += net_braces(code)
    if (depth <= 0) { in_test = 0; depth = 0 }
    next
  }
  if (ltrim(code) ~ /^test[ \t]*\{/) {
    in_test = 1
    depth = net_braces(code)
    if (depth <= 0) { in_test = 0; depth = 0 }
    next
  }
  # Resolve a `catch` whose body starts on an earlier line.
  if (kw > 0) {
    k = body_kind(code)
    if (k == "empty") print kw "\t" rtrim(ltrim(code)) "   [line " kw " is a bare `catch`, body here]"
    else if (k == "open") open = kw
    kw = 0
  } else if (open > 0) {
    t = rtrim(ltrim(code))
    if (t == "}" || t == "};") print open "\t" t "   [empty body of the `catch {` opened on line " open "]"
    open = 0
  }
  if (code ~ /catch[ \t]+unreachable/) print NR "\t" rtrim(ltrim(code))
  k = catch_kind(code)
  if (k == "empty") print NR "\t" rtrim(ltrim(code))
  else if (k == "open") open = NR
  else if (k == "kw") kw = NR
}
AWK
)"

scan_file() {
  local file="$1" hits
  hits="$(awk "$SCANNER" "$file" || true)"
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
