#!/usr/bin/env bash
# Informational complexity report — `zig fmt --complexity` over the same path
# set as the fmt-check gate (build.zig). NEVER fails the build: it prints the
# corpus total plus the largest files by token count so complexity creep is
# visible in CI logs instead of only being noticed after the fact.
set -uo pipefail

# --check keeps zig fmt read-only (without it files are rewritten in place).
report=$(zig fmt --complexity --check src tools examples 2>&1) || true

printf '%s\n' "$report" | grep '^info: total:' || echo "info: total unavailable (zig fmt --complexity produced no report)"
echo "info: top 20 files by tokens:"
printf '%s\n' "$report" | grep '^info: ' | grep -v '^info: total:' | awk -F'tokens=' '{ print $2 + 0, $0 }' | sort -rn | head -20 | cut -d' ' -f2-
exit 0
