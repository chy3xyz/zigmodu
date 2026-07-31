#!/usr/bin/env bash
# CI release gate: the triggering git tag must match build.zig.zon.
# Expects REF_TAG (e.g. "v0.15.0") via env or $GITHUB_REF_NAME.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' build.zig.zon | head -1)"
EXPECTED="v${VERSION}"
ACTUAL="${REF_TAG:-${GITHUB_REF_NAME:-}}"
if [[ -z "$ACTUAL" ]]; then
  echo "check-release: REF_TAG/GITHUB_REF_NAME not set" >&2
  exit 1
fi
if [[ "$ACTUAL" != "$EXPECTED" ]]; then
  echo "check-release: tag '$ACTUAL' != expected '$EXPECTED' (build.zig.zon)" >&2
  exit 1
fi
echo "check-release: OK ($ACTUAL matches build.zig.zon)"
