# Shared Zig source-line scanner for the repo's `check-*.sh` gates.
#
# Callers (always pass this file with `-f` and keep the program side empty, so it
# runs the same on BWK awk, mawk and gawk):
#
#   awk -v mode=catch  -f scripts/lib/zig-scan.awk <file>
#       scripts/check-production.sh — one line per banned `catch` shape, printed
#       as "<lineno>\t<shaped line>". Skips `zig_skip()` lines: prose and
#       comment-only lines too, because a `// catch {}` in a comment is not a
#       violation.
#   awk -v mode=entropy -f scripts/lib/zig-scan.awk <file>
#       scripts/check-production.sh — one line per banned entropy source:
#       `std.Io.random(` (falls back to pid+wall-clock+ASLR when it fails, which
#       is exactly the class AGENTS.md "CSPRNG" bans) and `std.crypto.random`
#       (not declared by this toolchain at all). `std.Io.randomSecure(` is the
#       sanctioned form and is stripped before the test, so it never matches.
#       Comment-only and string-literal text is already gone via zig_skip(),
#       which is why a `// never use std.Io.random(` in prose is not a hit.
#   awk -v mode=at-test -v want=<lineno> -f scripts/lib/zig-scan.awk <file>
#       scripts/check-version.sh — prints "test" when line <lineno> is inside a
#       `test` block (or opens one), "keep" when it is real code, "missing" when
#       the file is shorter. Only the test-block rule applies here: a version
#       literal in a comment or in a `\\…` template line outside a test block is
#       still a version literal, so this mode must not inherit zig_skip()'s
#       broader exemptions.
#
# `zig_in_test(raw)` is the one definition of "this line is inside a `test`
# block", found by brace balancing (top level or indented); `zig_skip()` is
# "this line is not production code" and adds the other two exemptions on top:
#   * a `\\…` multiline-string line — braces there are prose, not code;
#   * a line that is blank / comment-only once string and char literals and `//`
#     comments are stripped (strip_code).
# `test {` and `test "name" {` share one pattern because strip_code erases the
# name, leaving `test  {` either way, and stripping literals first means `"{}"`
# inside a test cannot unbalance the skip. Both gates must agree on what counts
# as a test block, so the state machine lives in one file — neither caller forks
# it.
#
# Portable BSD/gawk/mawk: no `-P`, no `\s`, no interval regexes.

function strip_code(s,   out, i, n, c, in_str, in_char) {
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
# The test-block state machine: returns 1 when the line is inside a `test` block
# (or opens one), 0 otherwise. Brace accounting is identical for every caller.
function zig_in_test(raw,   t) {
  if (raw ~ /^[ \t]*\\\\/) return in_test  # prose line: no braces, state stands
  code = strip_code(raw)
  if (rtrim(code) == "") return in_test    # comment/blank: no braces either
  if (in_test) {
    depth += net_braces(code)
    if (depth <= 0) { in_test = 0; depth = 0 }
    return 1
  }
  t = ltrim(code)
  if (t ~ /^test[ \t]*\{/) {
    in_test = 1
    depth = net_braces(code)
    if (depth <= 0) { in_test = 0; depth = 0 }
    return 1
  }
  return 0
}
# check-production's filter: not production code. Adds the prose/comment
# exemptions on top of zig_in_test(). Leaves the stripped line in `code`.
function zig_skip(raw) {
  if (raw ~ /^[ \t]*\\\\/) { code = ""; return 1 }
  code = strip_code(raw)
  if (rtrim(code) == "") return 1
  return zig_in_test(raw)
}

# 1 when `s` names a banned entropy source. `std.Io.randomSecure` is removed
# first so the sanctioned spelling can never trip the `std.Io.random` test —
# awk has no lookahead, and stripping the good form is the portable equivalent.
function weak_entropy(s,   t, i) {
  t = s
  while ((i = index(t, "std.Io.randomSecure")) > 0)
    t = substr(t, 1, i - 1) substr(t, i + 19)
  if (index(t, "std.Io.random") != 0) return 1
  if (index(t, "std.crypto.random") != 0) return 1
  return 0
}

BEGIN { in_test = 0; depth = 0; kw = 0; open = 0; seen = 0 }
{
  raw = $0
  if (mode == "at-test") {
    if (NR == want) { print (zig_in_test(raw) ? "test" : "keep"); seen = 1; exit }
    zig_in_test(raw)
    next
  }
  if (zig_skip(raw)) next
  if (mode == "entropy") {
    if (weak_entropy(code)) print NR "\t" rtrim(ltrim(code))
    next
  }
  # mode == "catch": resolve a `catch` whose body starts on an earlier line.
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
END { if (mode == "at-test" && !seen && NR < want) print "missing" }
