#!/usr/bin/env bash
# Fail when the version in build.zig.zon has drifted from derived docs/badges.
# Run in CI so a manual version bump can never leave the repo inconsistent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' build.zig.zon | head -1)"
if [[ -z "$VERSION" ]]; then
  echo "check-version: cannot read version from build.zig.zon" >&2
  exit 1
fi

fail=0
for f in README.md README.zh.md AGENTS.md CLAUDE.md docs/AI_METHODOLOGY.md; do
  if ! grep -q "$VERSION" "$f"; then
    echo "check-version: $f does not reference version $VERSION" >&2
    fail=1
  fi
done

# No static Version-x.y.z badge may remain (README uses a dynamic release badge).
for f in README.md README.zh.md; do
  if grep -Eq 'Version-[0-9]+\.[0-9]+\.[0-9]+' "$f"; then
    echo "check-version: $f still has a hard-coded Version badge" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  echo "check-version: run scripts/bump-version.sh to sync all files" >&2
  exit 1
fi
echo "check-version: OK ($VERSION consistent across docs)"
