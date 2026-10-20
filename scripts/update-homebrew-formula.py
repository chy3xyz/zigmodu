#!/usr/bin/env python3
"""Rewrite the tap's Formula/zmodu.rb for a release.

usage: update-homebrew-formula.py <formula.rb> <version> <dist-dir>

`dist-dir` must contain the four `zmodu-<version>-<arch>-<os>.tar.gz`
assets. The formula keeps `url ... v#{version} ...` interpolation, so this
script only rewrites the `version` line and the four `sha256` values; the
URL-to-arch association comes from the filename in the line above each
`sha256`.

Exits non-zero when an asset is missing, so a partial release can never
publish a formula that points at a 404.
"""

from __future__ import annotations

import hashlib
import os
import re
import sys

PLATFORMS = {"aarch64-macos", "x86_64-macos", "aarch64-linux", "x86_64-linux"}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    formula, version, dist = argv[1:4]

    shas: dict[str, str] = {}
    for name in os.listdir(dist):
        m = re.match(rf"zmodu-{re.escape(version)}-(aarch64|x86_64)-(macos|linux)\.tar\.gz$", name)
        if not m:
            continue
        shas[f"{m.group(1)}-{m.group(2)}"] = sha256_file(os.path.join(dist, name))

    missing = PLATFORMS - set(shas)
    if missing:
        print(f"update-homebrew-formula: missing assets: {sorted(missing)}", file=sys.stderr)
        return 1

    with open(formula, encoding="utf-8") as f:
        lines = f.read().splitlines()

    version_re = re.compile(r'^  version "[^"]+"$')
    pending: str | None = None
    touched = 0
    for i, line in enumerate(lines):
        if version_re.match(line):
            lines[i] = f'  version "{version}"'
            continue
        m = re.search(r'url ".*-(aarch64|x86_64)-(macos|linux)\.tar\.gz"', line)
        if m:
            pending = f"{m.group(1)}-{m.group(2)}"
            continue
        if pending is not None and re.search(r'sha256 "[0-9a-f]{64}"', line):
            lines[i] = re.sub(r'sha256 "[0-9a-f]{64}"', f'sha256 "{shas[pending]}"', line)
            touched += 1
            pending = None

    if touched != len(PLATFORMS):
        print(f"update-homebrew-formula: expected {len(PLATFORMS)} sha256 lines, rewrote {touched}", file=sys.stderr)
        return 1

    with open(formula, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"update-homebrew-formula: {formula} -> {version} ({touched} checksums)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
