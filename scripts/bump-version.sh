#!/usr/bin/env bash
# Bump the framework version from a single source and keep every derived file
# in sync: build.zig.zon + README/AGENTS/CLAUDE/docs + CHANGELOG + annotated tag.
#
# Usage: scripts/bump-version.sh 0.15.0
#
# NOTE: build.zig.zon `.fingerprint` must NOT change on a version bump — it is
# the stable package identity that consumers lock onto.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NEW="${1:-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: $0 <new_version>   (e.g. $0 0.15.0)" >&2
  exit 1
fi

OLD="$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' build.zig.zon | head -1)"
if [[ -z "$OLD" ]]; then
  echo "bump-version: could not read current version from build.zig.zon" >&2
  exit 1
fi
echo "bump-version: $OLD -> $NEW"

# 1) Single source of truth.
sed -i '' "s/\.version = \"$OLD\"/.version = \"$NEW\"/" build.zig.zon

# 2) Derived doc/readme references (CHANGELOG handled below).
#
# docs/guide/BEST_PRACTICES.md is here because it carries a self-declared
# version footer, and check-version.sh fails the build when that drifts. A gate
# with no corresponding bump step is a gate that goes red on every release.
for f in README.md README.zh.md AGENTS.md CLAUDE.md docs/dev/AI_METHODOLOGY.md docs/archive/status/ZIGMODU_NOTES.md docs/guide/BEST_PRACTICES.md; do
  sed -i '' "s/$OLD/$NEW/g" "$f"
done

# 3) CHANGELOG: rename [Unreleased] to the new release section and open a
#    fresh [Unreleased] above it (Keep a Changelog flow).
DATE="$(date +%F)"
sed -i '' "s/^## \[Unreleased\]$/## [$NEW] - $DATE/" CHANGELOG.md
first_section="$(grep -n '^## \[' CHANGELOG.md | head -1 | cut -d: -f1)"
if [[ -n "$first_section" ]]; then
  tmp="$(mktemp)"
  head -n "$((first_section - 1))" CHANGELOG.md > "$tmp"
  {
    printf '## [Unreleased]\n\n'
    tail -n "+$first_section" CHANGELOG.md
  } >> "$tmp"
  mv "$tmp" CHANGELOG.md
fi

# 4) Annotated tag (local only; push explicitly).
git tag -a "v$NEW" -m "Release v$NEW"

echo "bump-version: done. verify with: bash scripts/check-version.sh"
echo "bump-version: push with: git push origin master && git push origin --tags"
