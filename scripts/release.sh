#!/usr/bin/env bash
# One-shot release: bump the package version everywhere, run all quality
# gates, then commit + tag (+ push with --push).
#
# Tag vs GitHub Release — two cadences, one script:
#   * Zig packages pin by git tag, so tags are the frequent artifact: cut one
#     whenever gated work should be consumable (`--tag-only` skips the
#     GitHub Release; release-verify still gates every pushed tag).
#   * A GitHub Release is the announcement artifact (fires ci.yml's
#     `release: published` docker build): keep it infrequent — e.g. weekly —
#     via `--publish-release`, which only creates the Release for an
#     existing tag and changes nothing else.
#
# Note: .fingerprint is the package's permanent identity — Zig docs say it is
# generated once and never changes (changing it has security/trust
# implications). release.sh intentionally leaves it untouched.
#
# Usage:
#   scripts/release.sh <x.y.z> [--push] [--tag-only]   cut a gated tag (+ release unless --tag-only)
#   scripts/release.sh --publish-release <x.y.z> [--push]   create the GitHub Release for an existing tag
set -euo pipefail
cd "$(dirname "$0")/.."

# Create the GitHub Release for an already-pushed tag from its CHANGELOG
# section. Not fatal when it cannot happen here: the tag is the source of
# truth (release-verify still gates it), so a missing `gh` or a failed create
# degrades to the printed manual commands instead of a failed release.
create_github_release() {
    local ver="$1"
    if ! command -v gh >/dev/null 2>&1; then
        echo "gh CLI not found — create the GitHub Release by hand (the tag is already pushed):"
        echo "  bash scripts/release-notes.sh $ver > /tmp/notes-v$ver.md"
        echo "  gh release create v$ver --verify-tag --notes-file /tmp/notes-v$ver.md"
        return 0
    fi
    if gh release view "v$ver" >/dev/null 2>&1; then
        echo "release: GitHub Release v$ver already exists — skipping create"
        return 0
    fi
    local notes
    notes="$(mktemp -t zm-release-notes.XXXXXX)"
    if bash scripts/release-notes.sh "$ver" > "$notes" && [ -s "$notes" ]; then
        if gh release create "v$ver" --verify-tag --notes-file "$notes"; then
            echo "release: GitHub Release v$ver created — the ci.yml release job now"
            echo "  builds and attaches zmodu-v$ver-linux-x86_64.tar.gz (+ .sha256)."
        else
            echo "WARN: gh release create failed; create the release by hand:" >&2
            echo "  bash scripts/release-notes.sh $ver > /tmp/notes-v$ver.md" >&2
            echo "  gh release create v$ver --verify-tag --notes-file /tmp/notes-v$ver.md" >&2
        fi
    else
        echo "WARN: no CHANGELOG section extracted for $ver; create the release by hand:" >&2
        echo "  gh release create v$ver --verify-tag --generate-notes" >&2
    fi
    rm -f "$notes"
}

VERSION=""
PUSH=0
TAG_ONLY=0
MODE="release"
while [ $# -gt 0 ]; do
    case "$1" in
        --push) PUSH=1 ;;
        --tag-only) TAG_ONLY=1 ;;
        --publish-release) MODE="publish" ;;
        [0-9]*.[0-9]*.[0-9]*) VERSION="$1" ;;
        *)
            echo "usage: scripts/release.sh <x.y.z> [--push] [--tag-only] | --publish-release <x.y.z> [--push]"
            exit 2
            ;;
    esac
    shift
done

if [ "$MODE" = "publish" ]; then
    if [ -z "$VERSION" ]; then
        echo "usage: scripts/release.sh --publish-release <x.y.z> [--push]"
        exit 2
    fi
    if ! git rev-parse "v$VERSION" >/dev/null 2>&1; then
        echo "FAIL: tag v$VERSION does not exist locally — cut it first:"
        echo "  bash scripts/release.sh $VERSION --tag-only --push"
        exit 1
    fi
    if [ "$PUSH" = "1" ]; then
        git push origin "v$VERSION"
        echo "pushed v$VERSION"
    fi
    # The tag must be on the remote before --verify-tag can resolve it.
    if ! git ls-remote --exit-code --tags origin "v$VERSION" >/dev/null 2>&1; then
        echo "FAIL: tag v$VERSION is not on origin yet — push it first:"
        echo "  git push origin v$VERSION"
        exit 1
    fi
    create_github_release "$VERSION"
    exit 0
fi

case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "usage: scripts/release.sh <x.y.z> [--push] [--tag-only] | --publish-release <x.y.z> [--push]"
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
    echo "release: $VERSION already current — idempotent re-run, skipping bump"
    SKIP_BUMP=1
else
    echo "release: $OLD -> $VERSION"
    SKIP_BUMP=0
fi

# 1. Bump version in every reference.
if [ "$SKIP_BUMP" != "1" ]; then
perl -0pi -e "s/\.version = \"$OLD\"/.version = \"$VERSION\"/" build.zig.zon
perl -0pi -e "s/\.version = \"$OLD\"/.version = \"$VERSION\"/" tools/zmodu/build.zig.zon
perl -0pi -e "s/\"version\", \"$OLD\"/\"version\", \"$VERSION\"/" src/ai/mcp.zig
perl -0pi -e "s/# zmodu v$OLD/# zmodu v$VERSION/" README.md README.zh.md
perl -0pi -e "s/zmodu \*\*v$OLD\*\*/zmodu **v$VERSION**/" CLAUDE.md docs/dev/AI_METHODOLOGY.md
perl -0pi -e "s/\*\*v$OLD\*\*/**v$VERSION**/g" AGENTS.md
perl -0pi -e "s/\*\*框架版本\*\*: v$OLD/**框架版本**: v$VERSION/" docs/archive/status/EVALUATION_REPORT.md
perl -0pi -e "s/zmodu \*\*v$OLD\*\*/zmodu **v$VERSION**/" docs/archive/status/EVALUATION_REPORT.md
perl -0pi -e "s/\*\*版本口径\*\*: v$OLD/**版本口径**: v$VERSION/" docs/archive/status/PRODUCTION_ROADMAP.md
perl -0pi -e "s/\*\*本文描述的版本\*\*：zmodu v$OLD/**本文描述的版本**：zmodu v$VERSION/" docs/guide/BEST_PRACTICES.md
fi

# 2. CHANGELOG: promote Unreleased to the new version.
if grep -q "^## \[Unreleased\]" CHANGELOG.md; then
    # Exactly one heading, or fail: the promote below renames only the FIRST
    # occurrence (perl s/// without /g), so a second one — a batch leftover
    # inside a historical section — would silently survive the release. Six
    # accumulated inside [0.33.0] exactly this way, and misled an audit into
    # reading a historical section's breaking changes as the new release's.
    UNRELEASED_COUNT=$(grep -c "^## \[Unreleased\]$" CHANGELOG.md)
    if [ "$UNRELEASED_COUNT" != "1" ]; then
        echo "FAIL: CHANGELOG.md has $UNRELEASED_COUNT [Unreleased] headings (want exactly 1):"
        grep -n "^## \[Unreleased\]$" CHANGELOG.md
        echo "Remove the stale ones inside historical sections, then re-run."
        exit 1
    fi
    perl -0pi -e "s/## \[Unreleased\]/## [$VERSION] - $(date +%F)/" CHANGELOG.md

    # UPGRADING.md cycle section: `## v$OLD 之后（未发布批次）` becomes the
    # released version. Missed once (0.39.6 shipped with the heading still
    # saying "v0.39.5 之后"), and the in-section pointer kept aiming at
    # CHANGELOG's [Unreleased] — so the rename is mechanical here, and any
    # leftover "（未发布批次）" heading is a hard failure below.
    perl -0pi -e "s/## v\Q$OLD\E 之后（未发布批次）/## v$VERSION/" docs/reference/UPGRADING.md
elif [ "$SKIP_BUMP" = "1" ]; then
    echo "CHANGELOG already promoted to [$VERSION]"
else
    echo "FAIL: CHANGELOG.md has no [Unreleased] section"
    exit 1
fi

# The template section mentions the in-cycle heading shape inline; only a
# heading at line start is a leftover.
if grep -n "^## .*（未发布批次）" docs/reference/UPGRADING.md; then
    echo "FAIL: docs/reference/UPGRADING.md still has an （未发布批次） section heading."
    echo "Rename it to v$VERSION and repoint in-body [Unreleased] references to [$VERSION]."
    exit 1
fi

# Behavior-change digest: every release prints the batch headings that bite,
# so the "silent bite" class is visible in the release output itself.
echo "-- behavior changes in v$VERSION --"
sed -n "/^## \[$VERSION\]/,/^## \[/p" CHANGELOG.md \
    | grep -E "破坏性：(是|窄)|行为变化|行为收紧" | sed 's/^/  /' | head -40 || true

# 1b. Verify every version reference actually bumped — perl -pi silently
#     no-ops when the old value doesn't match, which left README stuck at an
#     old version across releases (0.15.4 -> 0.15.10 drift).
for f in README.md README.zh.md; do
    if ! grep -q "v$VERSION" "$f"; then
        echo "FAIL: $f does not reference v$VERSION (stale version bump?)"
        exit 1
    fi
done
if ! grep -q "v$VERSION" CLAUDE.md || ! grep -q "v$VERSION" AGENTS.md; then
    echo "FAIL: docs version references not updated to v$VERSION"
    exit 1
fi
# These two docs were historically missed by the bump; their top "版本口径"
# line must track the release or the evaluation report drifts (820 vs 990 tests).
if ! grep -q "v$VERSION" docs/archive/status/EVALUATION_REPORT.md || ! grep -q "v$VERSION" docs/archive/status/PRODUCTION_ROADMAP.md; then
    echo "FAIL: EVALUATION_REPORT / PRODUCTION_ROADMAP version not updated to v$VERSION"
    exit 1
fi

# 3. Quality gates. Every *fast* gate ci.yml blocks on also runs here, so the
#    tag this script cuts cannot be rejected by a check that could have run
#    locally first. v0.27.0 shipped that way — `check-version.sh` was missing
#    here and failed the "Version consistency" step minutes after the tag was
#    pushed — and the doc-paths / pool-guard / test-collection gates were
#    CI-only in the same way until they were added below.
#
#    Deliberately CI-only (kept out by choice, not by omission):
#      - integration-full (scripts/ci-integration.sh) and the nginx/envoy
#        smuggling probes — need docker and real gateways;
#      - test-postgres / test-mysql / test-live-services — need the service
#        containers only CI provides;
#      - the benchmark gate and the nightly bench-x86_64 cross-host gate —
#        a benchmark verdict is only meaningful on the runner class its
#        baseline was recorded on (see the scripts/check-bench.sh header);
#      - the nightly legs (soak / soak-cluster / runtime-stress /
#        mixed-version / fuzz) — long scheduled runs;
#      - the per-OS example builds / doctor / smokes, `zig build docs`,
#        soak-compile and soak-smoke — matrix/Linux-gated CI legs; the suite
#        above already compiles and tests the framework itself.
echo "-- gates --"
zig fmt --check src tools examples
# 75 = the hang-watchdog fired and the standalone fallback passed (known
# 0.17.0 macOS build-runner flake); both mean the suite really ran.
GUARD_STATUS=0
ZIG_GLOBAL_CACHE_DIR=.zig-global-cache bash scripts/zig-build-test-guarded.sh build test --summary all || GUARD_STATUS=$?
if [[ "$GUARD_STATUS" -ne 0 && "$GUARD_STATUS" -ne 75 ]]; then
  echo "release: test suite failed (exit $GUARD_STATUS)" >&2
  exit "$GUARD_STATUS"
fi
bash scripts/check-deadcode.sh
bash scripts/check-version.sh
bash scripts/check-doc-paths.sh
bash scripts/check-tenant-scope.sh
bash scripts/check-pool-guard.sh
bash scripts/check-test-collection.sh
bash scripts/check-comptime-budget.sh
zig build check-api
zig build check

# 4. Commit + tag.
git add -A
if git diff --cached --quiet; then
    echo "release: no working-tree changes to commit (idempotent re-run)"
else
    git commit -m "chore(release): v$VERSION"
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "release: tag v$VERSION already exists"
else
    git tag -a "v$VERSION" -m "v$VERSION"
fi

# 5. Final assertion: tag must match the package version.
bash scripts/check-release-tag.sh
echo "release v$VERSION ready"

if [ "$PUSH" = "1" ]; then
    git push origin master
    git push origin "v$VERSION"
    echo "pushed master + v$VERSION"

    # 6. GitHub Release (skipped with --tag-only): publishing the release fires
    #    ci.yml's `release: published` trigger, so the docker + release jobs
    #    build zmodu-v$VERSION-linux-x86_64.tar.gz and its .sha256 companion
    #    and attach both. Tags are the frequent, pinnable artifact; the Release
    #    is the weekly announcement — cut it later for any existing tag with:
    #      bash scripts/release.sh --publish-release <x.y.z>
    if [ "$TAG_ONLY" = "1" ]; then
        echo "release: tag v$VERSION pushed (tag-only; no GitHub Release)."
        echo "  publish the weekly release later with:"
        echo "    bash scripts/release.sh --publish-release $VERSION"
    else
        create_github_release "$VERSION"
    fi

    # The tag push only runs release-verify (tag == package version). The real
    # suite runs on the *master* push, and `ci.yml` cancels in-progress runs for
    # the same ref — so a rapid commit→release→push sequence can leave the tip's
    # main run cancelled, i.e. the release never actually tested. Report the run
    # for the tip commit instead of assuming.
    if command -v gh >/dev/null 2>&1; then
        sha="$(git rev-parse HEAD)"
        echo "-- main CI for ${sha:0:8} (verify it is not 'cancelled') --"
        gh run list --workflow=ci.yml --limit 6 \
            --json headSha,status,conclusion,url \
            -q ".[] | select(.headSha==\"$sha\") | \"\(.conclusion // .status)\t\(.url)\"" \
            | head -1 || true
        gh run list --workflow=release-verify.yml --limit 3 \
            --json headBranch,conclusion \
            -q ".[] | \"release-verify: \(.conclusion // \"-\")\t\(.headBranch)\"" || true
        echo "release-verify only checks tag↔version; the suite result above is the one that matters."
    fi
fi
