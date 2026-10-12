#!/usr/bin/env bash
# Print the CHANGELOG.md section for one released version — the notes body for
# `gh release create`. The section's own heading (`## [x.y.z] - <date>`) is
# dropped: the GitHub Release page already shows the tag and its date, so the
# body starts at the first content line. Leading blank lines are trimmed.
#
# usage: scripts/release-notes.sh <x.y.z>
#
# Extraction is literal, not regex, on the version (`index()` in the awk), so
# a `0.3.1` lookup cannot match the `0.3.10` heading. The section ends at the
# next `## [` heading. No match prints nothing and exits 1 — an empty notes
# file must never become an empty release body.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "usage: scripts/release-notes.sh <x.y.z>" >&2
        exit 2
        ;;
esac

awk -v ver="$VERSION" '
    /^## \[/ {
        if (in_sec) exit
        if (index($0, "## [" ver "]") == 1) { in_sec = 1; next }
    }
    in_sec && !started && /^[[:space:]]*$/ { next }
    in_sec { started = 1; print }
    END { if (!started) exit 1 }
' CHANGELOG.md
