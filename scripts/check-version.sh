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

# ── tools/ (the released `zmodu` CLI) ────────────────────────────────────────
# Versions there are *shipped*, not documentation: the CLI writes them into the
# projects it generates. `zmodu scaffold` once embedded "v0.13.9" plus a
# placeholder dependency hash, so every generated project failed to fetch the
# framework. Every framework version must be derived from build.zig.zon
# (build_options.ZMODU_VERSION). Versions that legitimately belong to something
# else are allow-listed in `allowed_version` below.
TOOLS=tools
tools_grep() {
  grep -rnE "$1" -I --exclude-dir=.zig-cache --exclude-dir=zig-out --exclude-dir=.zig-local-cache "$TOOLS" 2>/dev/null || true
}

# 1. Framework-shaped pins must be the current release.
pin_re='(zmodu v|zigmodu v|tags/v|zigmodu-)[0-9]+\.[0-9]+\.[0-9]+'
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  for pv in $(printf '%s\n' "$hit" | grep -oE "$pin_re" | sed -E 's/^.*[v-]([0-9]+\.[0-9]+\.[0-9]+)$/\1/'); do
    if [[ "$pv" != "$VERSION" ]]; then
      echo "check-version: tools/ pins framework $pv, expected $VERSION -> $hit" >&2
      fail=1
    fi
  done
done <<<"$(tools_grep "$pin_re" | grep -v 'zigmodu_zon_hash')"

# 2. Any other 0.x.y literal must be deliberate (see allowed_version).
allowed_version() {
  case "$1" in
    "$VERSION") return 0 ;;
    0.17.0) return 0 ;;                      # Zig toolchain requirement
    0.1.0) return 0 ;;                       # version of the generated project itself
    0.2.0) return 0 ;;                       # .life evolve sample versions
    0.13.1) return 0 ;;                      # historical note ("wildcard ... after v0.13.1")
    0.14.0 | 0.15.0 | 0.15.2 | 0.15.4) return 0 ;; # marketplace min_version floors
    *) return 1 ;;
  esac
}
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  for lv in $(printf '%s\n' "$hit" | grep -oE 'v?0\.[0-9]+\.[0-9]+' | sed 's/^v//'); do
    if ! allowed_version "$lv"; then
      echo "check-version: tools/ hard-codes version $lv -> $hit" >&2
      echo "check-version: derive it from ZMODU_VERSION, or allow it in scripts/check-version.sh" >&2
      fail=1
    fi
  done
done <<<"$(tools_grep '(^|[^0-9A-Za-z_.])v?0\.[0-9]+\.[0-9]+')"

# 3. The CLI package version must track the framework version it generates for.
tools_version="$(sed -n 's/^    \.version = "\([0-9.]*\)",$/\1/p' "$TOOLS/zmodu/build.zig.zon" | head -1)"
if [[ "$tools_version" != "$VERSION" ]]; then
  echo "check-version: $TOOLS/zmodu/build.zig.zon is $tools_version, expected $VERSION" >&2
  fail=1
fi

# 4. The scaffold dependency hash is release-specific, so it can only be
#    verified by shape: it must be addressed to $VERSION (check 1) and must not
#    be a repeated-character placeholder.
hash_payload="$(sed -n 's/^const zigmodu_zon_hash = "zigmodu-[0-9.]*-\(.*\)";$/\1/p' "$TOOLS/zmodu/src/main.zig" | head -1)"
if [[ -z "$hash_payload" ]]; then
  echo "check-version: $TOOLS/zmodu/src/main.zig: no parseable zigmodu_zon_hash" >&2
  fail=1
else
  payload_body="${hash_payload%%=*}"
  if [[ -z "$(printf '%s' "$payload_body" | tr -d "${payload_body%"${payload_body#?}"}")" ]]; then
    echo "check-version: $TOOLS/zmodu/src/main.zig: zigmodu_zon_hash is a placeholder" >&2
    fail=1
  fi
  # The hash can only be regenerated once the tag exists, so a lagging version is
  # a WARN, not a failure (see the comment above the comptime check in main.zig).
  hash_ver="$(sed -n 's/^const zigmodu_zon_hash = "zigmodu-\([0-9][0-9.]*\)-.*";$/\1/p' "$TOOLS/zmodu/src/main.zig" | head -1)"
  if [[ -n "$hash_ver" && "$hash_ver" != "$VERSION" ]]; then
    echo "check-version: WARN: scaffold pins zigmodu-$hash_ver; after tag v$VERSION is pushed, regenerate it:" >&2
    echo "check-version: WARN:   cd tools/zmodu && zig build --fetch   (paste the 'expected .hash' value)" >&2
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "check-version: run scripts/bump-version.sh to sync all files" >&2
  exit 1
fi
echo "check-version: OK ($VERSION consistent across docs and tools/)"
