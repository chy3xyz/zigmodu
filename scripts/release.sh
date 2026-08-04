#!/usr/bin/env bash
# One-shot release: bump the package version everywhere, run all quality
# gates, then commit + tag (+ push with --push).
#
# Note: .fingerprint is the package's permanent identity — Zig docs say it is
# generated once and never changes (changing it has security/trust
# implications). release.sh intentionally leaves it untouched.
#
# Usage: scripts/release.sh <x.y.z> [--push]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
PUSH=0
if [ "${2:-}" = "--push" ]; then PUSH=1; fi

case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "usage: scripts/release.sh <x.y.z> [--push]"
        exit 2
        ;;
esac

if ! git diff --quiet; then
    echo "FAIL: working tree has uncommitted changes:"
    git status --short | head -10
    exit 1
fi

BR=$(git symbolic-ref --short HEAD 2>/dev/null || true)
if [ "$BR" != "master" ]; then
    echo "FAIL: releases must be cut from master (on $BR)"
    exit 1
fi

OLD=$(sed -n 's/.*\.version = "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' build.zig.zon | head -1)
if [ -z "$OLD" ]; then
    echo "FAIL: cannot parse current version from build.zig.zon"
    exit 1
fi
if [ "$OLD" = "$VERSION" ]; then
    echo "FAIL: version already $VERSION"
    exit 1
fi
echo "release: $OLD -> $VERSION"

# 1. Bump version in every reference.
perl -0pi -e "s/\.version = \"$OLD\"/.version = \"$VERSION\"/" build.zig.zon
perl -0pi -e "s/\.version = \"$OLD\"/.version = \"$VERSION\"/" tools/zmodu/build.zig.zon
perl -0pi -e "s/\"version\", \"$OLD\"/\"version\", \"$VERSION\"/" src/ai/mcp.zig
perl -0pi -e "s/# ZigModu v$OLD/# ZigModu v$VERSION/" README.md README.zh.md
perl -0pi -e "s/ZigModu \*\*v$OLD\*\*/ZigModu **v$VERSION**/" CLAUDE.md docs/AI_METHODOLOGY.md
perl -0pi -e "s/\*\*v$OLD\*\*/**v$VERSION**/g" AGENTS.md

# 2. CHANGELOG: promote Unreleased to the new version.
if ! grep -q "^## \[Unreleased\]" CHANGELOG.md; then
    echo "FAIL: CHANGELOG.md has no [Unreleased] section"
    exit 1
fi
perl -0pi -e "s/## \[Unreleased\]/## [$VERSION] - $(date +%F)/" CHANGELOG.md

# 3. Quality gates.
echo "-- gates --"
zig fmt --check src tools examples
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache zig build test --summary all
bash scripts/check-deadcode.sh

# 4. Commit + tag.
git add -A
git commit -m "chore(release): v$VERSION"
git tag -a "v$VERSION" -m "v$VERSION"

# 5. Final assertion: tag must match the package version.
bash scripts/check-release-tag.sh
echo "release v$VERSION ready"

if [ "$PUSH" = "1" ]; then
    git push origin master
    git push origin "v$VERSION"
    echo "pushed master + v$VERSION"
fi
