#!/usr/bin/env bash
# repro-pack.sh [--out DIR] [FILE ...]
#
# Bundles the minimum an outside reviewer needs to reproduce a claim from this
# repository: the exact commit, the toolchain and host fingerprint, the version
# pins, and the commands whose output is the evidence. Extra FILEs (soak logs,
# e2e.jsonl, a bench run) are copied in beside them.
#
# Why: every "green" in docs/dev/reproducing-evidence.md is currently proven by
# the same batch of automation that produced the change. A pack is not an
# independent audit, but it is the cheapest step that makes one possible —
# someone else can run the same commands on the same commit without reading
# this repository's CI YAML first.
#
# usage:
#   bash scripts/repro-pack.sh                       # to ./repro-packs/
#   bash scripts/repro-pack.sh --out /tmp /tmp/e2e.jsonl /tmp/soak.log
set -euo pipefail
cd "$(dirname "$0")/.."

out_dir="repro-packs"
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) out_dir="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) files+=("$1"); shift ;;
  esac
done

sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
short="${sha:0:12}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dir="$out_dir/repro-$short-$stamp"
mkdir -p "$dir"

{
  echo "commit:   $sha"
  echo "branch:   $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "describe: $(git describe --tags --always --dirty 2>/dev/null || echo unknown)"
  echo "when:     $stamp (UTC)"
  echo "uname:    $(uname -a)"
  echo "zig:      $(zig version)"
  echo "python3:  $(python3 --version 2>&1 || echo absent)"
  echo
  echo "--- dirty files (empty = clean tree) ---"
  git status --porcelain 2>/dev/null || true
} >"$dir/environment.txt"

# The pins a reproducer must match: the package version and its minimum Zig,
# plus the benches' baseline and the CI's same-host threshold.
cp build.zig.zon "$dir/" 2>/dev/null || true
cp scripts/bench-baseline.ci.json "$dir/" 2>/dev/null || true
grep -E 'BENCH_THRESHOLD|2\.0x|3\.0x' scripts/check-bench.sh >"$dir/bench-thresholds.txt" 2>/dev/null || true

if ! git diff --quiet 2>/dev/null; then
  git diff >"$dir/working-tree.diff" 2>/dev/null || true
fi

if (( ${#files[@]} )); then
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || { echo "repro-pack: skipping missing $f" >&2; continue; }
    cp "$f" "$dir/"
  done
fi

cat >"$dir/REPRODUCE.md" <<'EOF'
# Reproduce

Run from a clean checkout of the commit in `environment.txt`, on the same OS
family (readings are host-dependent; see the note at the bottom).

```bash
# toolchain (must match `zig version` in environment.txt)
zig build test                 # the suite: expect "0 failed; 0 leaked"
bash scripts/ci-smoke.sh       # push-time gates

# the long-horizon harnesses (each appends a JSON line when the history var is set)
SOAK_HISTORY=soak-history.jsonl bash -c 'zig build soak -Dsoak-clients=64 -Dsoak-iterations=200'
SOAK_CLUSTER_HISTORY=soak-cluster-history.jsonl zig build soak-cluster
RUNTIME_STRESS_HISTORY=stress-history.jsonl zig build runtime-stress -Druntime-stress-duration-ms=60000
python3 scripts/soak_trend.py soak-history.jsonl soak-cluster-history.jsonl
python3 scripts/runtime_stress_trend.py stress-history.jsonl

# end-to-end HTTP (needs python3 -m pip install h2)
bash scripts/bench-e2e.sh --requests 400 --json-out e2e.jsonl
```

## Reading the output

- `0 failed; 0 leaked` is the suite's contract; a skip is named, never silent.
- The trend scripts gate on **host-independent** hard gates (a failed run, a
  cross-tenant read, two leaders in one sample, a push failure) and only print
  host-dependent readings. Do not turn the printed deltas into gates on a
  shared machine.
- `bench-e2e.sh` reports h1 vs h2c on the same server; compare the **ratio**
  within one host, not absolute req/s across hosts.
EOF

tarball="$dir.tar.gz"
tar -czf "$tarball" -C "$out_dir" "$(basename "$dir")"
rm -rf "$dir"

echo "wrote $tarball"
echo "contents:"
tar -tzf "$tarball" | sed 's/^/  /'
