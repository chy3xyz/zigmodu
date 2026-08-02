#!/usr/bin/env bash
# Release tag consistency gate: a pushed `v*` tag must match the package
# version in build.zig.zon and have a matching CHANGELOG section. Wired into
# CI (release-verify job) and run at the end of scripts/release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

V=$(git describe --tags --exact-match 2>/dev/null || true)
if [ -z "$V" ]; then
    echo "not on a tag; skipping"
    exit 0
fi

case "$V" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "FAIL: unexpected tag format: $V"
        exit 1
        ;;
esac

Z=$(sed -n 's/.*\.version = "\([0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' build.zig.zon | head -1)
if [ -z "$Z" ]; then
    echo "FAIL: cannot parse .version from build.zig.zon"
    exit 1
fi

if [ "$V" != "v$Z" ]; then
    echo "FAIL: tag $V != build.zig.zon version $Z"
    exit 1
fi

if ! grep -q "## \[$Z\]" CHANGELOG.md; then
    echo "FAIL: CHANGELOG.md has no [${Z}] section"
    exit 1
fi

if ! grep -q '\.fingerprint' build.zig.zon; then
    echo "FAIL: build.zig.zon has no .fingerprint"
    exit 1
fi

echo "OK: tag $V matches package version $Z (fingerprint present)"
