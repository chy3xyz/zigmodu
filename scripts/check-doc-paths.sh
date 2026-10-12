#!/usr/bin/env bash
# Verify that document paths cited in source comments actually exist.
#
# The source tree points at its own docs by literal path — 454 times at the
# time of writing, `docs/reference/RUNTIME.md` accounting for 156 of them. Nothing checks
# those paths, and nothing fails when one goes stale: a moved or renamed
# document leaves a comment that still reads perfectly and points at nothing.
# The failure surfaces months later, as a reader following `docs/reference/RUNTIME.md
# §12` and finding no such file, with no way to tell the comment rotted rather
# than the reader being wrong.
#
# This is the guard that would make the deferred directory reorganisation safe
# to attempt. It is deliberately independent of it — as a check it is useful
# today, because the pointers it protects are already drifting.
#
# Scope: it checks that cited *repository* doc paths resolve. It does not
# validate the §-references inside a document, nor markdown links, which the
# zdoc documentation build reports as warnings (links that climb out of
# `docs/` are exempt there by the same design as here).
#
# Two deliberate exclusions:
#
#   - Paths under `test "..."` blocks in tools/zmodu are fixtures, not
#     citations. `market.zig` carries `.doc = "docs/crm.md"` as sample data for
#     an OOM-leak scan; that file has never existed and must not become one.
#   - `docs/*.md` with an asterisk is a glob in prose ("see any docs/*.md"),
#     not a path, so it is not resolved.
#
# Written for bash 3.2 so it behaves identically on a macOS workstation and on
# the ubuntu runner: no mapfile, no associative arrays, no ${var,,}.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Only these trees hold citations. `tools/zmodu/.zig-cache` is build output and
# would otherwise contribute binary matches that grep reports as file names.
#
# `scripts/` IS scanned, deliberately, and excluding it was a mistake once
# already: check-version.sh, bump-version.sh and release.sh each hardcode a
# list of document paths to rewrite on a version bump, and when docs/ moved the
# check-version gate failed with a path that no longer existed. The other three
# went unnoticed because nothing referenced them. A stale path in a release
# script rewrites the wrong file, or silently does nothing.
#
# This script's *header* is exempt, not the whole file: it quotes example paths
# (`docs/crm.md`) to document what is ignored. Its inline code comments are
# scanned like anything else, since those are the kind that rot.
SCAN=(src tools/zmodu/src .github/workflows scripts)
FILES=(AGENTS.md CLAUDE.md build.zig build.zig.zon README.md)

# Build the file list, skipping anything absent so the script also runs in a
# partial checkout (and so a missing CLAUDE.md is not itself a failure).
list=()
for d in "${SCAN[@]}"; do
  [ -d "$d" ] && list+=("$d")
done
for f in "${FILES[@]}"; do
  [ -f "$f" ] && list+=("$f")
done

if [ "${#list[@]}" -eq 0 ]; then
  echo "check-doc-paths: nothing to scan (no source tree found)" >&2
  exit 0
fi

# Collect "file:line:docs/…md" for every reference. Binary cache artefacts are
# excluded with -I (grep would otherwise report them as file names, not text).
HITS="$(grep -rInoE "docs/[A-Za-z0-9_./-]+\.md" "${list[@]}" 2>/dev/null || true)"

if [ -z "$HITS" ]; then
  echo "check-doc-paths: no docs/ citations found — nothing to verify"
  exit 0
fi

total="$(printf '%s\n' "$HITS" | wc -l | tr -d ' ')"
missing=0
checked=0

printf '%s\n' "$HITS" | while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  path="${hit##*:}"         # docs/....md
  # "file:line:path" — strip the path, then the line number, leaving the file.
  loc="${hit%:*}"          # file:line
  loc="${loc%:*}"          # file
  # A glob in prose, not a path.
  case "$path" in *'*'*) continue ;; esac
  # Skip the test-fixture case described in the header.
  case "$loc" in
    tools/zmodu/src/market.zig) continue ;;   # test fixture, see header
    scripts/check-doc-paths.sh) continue ;;   # this file's header, see header
  esac
  if [ -f "$path" ]; then
    continue
  fi
  echo "  MISSING  $path    (cited at $loc)" >&2
done

# Count separately from the report above: a `while` in a pipeline runs in a
# subshell, so its counters would not survive into this shell.
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  path="${hit##*:}"
  loc="${hit%:*}"          # file:line
  loc="${loc%:*}"          # file
  case "$path" in *'*'*) continue ;; esac
  case "$loc" in tools/zmodu/src/market.zig) continue ;; scripts/check-doc-paths.sh) continue ;; esac
  if [ -f "$path" ]; then
    checked=$((checked + 1))
  else
    missing=$((missing + 1))
  fi
done <<EOF
$HITS
EOF

if [ "$missing" -gt 0 ]; then
  echo "" >&2
  echo "check-doc-paths: FAIL — $missing of $total citation(s) point at a document that does not exist." >&2
  echo "  Either the document was moved or renamed, or the citation was wrong to begin with." >&2
  echo "  Fix the path, or restore the document if deleting it was deliberate." >&2
  exit 1
fi

echo "check-doc-paths: OK — $checked citation(s) resolve, 0 missing (of $total matched)."