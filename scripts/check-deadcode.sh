#!/usr/bin/env bash
# Dead-code baseline gate: fails when the repo gains new dead declarations;
# allows removals (and auto-updates the baseline when run with --update).
#
# Identity = file:kind:name:parent (line numbers are informational, so code
# moves don't cause false positives).
#
# Monotonicity: `--update` refuses to GROW the baseline (exit 1 + a diff
# summary); pass `--force` to record a deliberate addition. The baseline is a
# ratchet, not a snapshot of today's state.
#
# Scopes: `src` + `tools` and `examples/**` are both enforced, each scanned
# separately (a WARN-only examples scan was the first phase; it was promoted to
# a hard gate on 2026-09-18 after its 7 hits — unused `std` imports in
# `examples/shopdemo/generated-sample/*.zig` and `examples/zmsaas/`, plus a dead
# `ShardOrder.source_id` field — were removed). Separating the scans keeps each
# scope's import graph from masking the other's hits.
set -euo pipefail
cd "$(dirname "$0")/.."

ZMODU=./zig-out/bin/zmodu
if [ ! -x "$ZMODU" ]; then
  echo "building zmodu..." >&2
  zig build 2>&1 | tail -1
fi

MODE=check
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --update) MODE=update ;;
    --force) FORCE=1 ;;
    *)
      echo "usage: $0 [--update [--force]]" >&2
      exit 2
      ;;
  esac
done

# Scanned paths live in the Python blocks below (`src` + `tools`, `examples`).

if [ "$MODE" = "update" ]; then
  python3 - "$FORCE" <<'EOF'
import json, os, subprocess, sys

force = sys.argv[1] == "1"
base_path = "scripts/deadcode-baseline.json"
old = json.load(open(base_path))["items"] if os.path.exists(base_path) else []

def scan(paths):
    run = subprocess.run(
        ["./zig-out/bin/zmodu", "deadcode", "-j", *paths],
        capture_output=True, text=True,
    )
    try:
        return json.loads(run.stdout)["dead_declarations"]
    except ValueError:
        print(f"FAIL: deadcode scan of {' '.join(paths)} produced no parseable JSON", file=sys.stderr)
        sys.exit(2)

def vendored(x):
    return "/zig-pkg/" in x["file"] or "/.zig-cache/" in x["file"]

def key(x):
    return (x["file"], x["kind"], x["name"], x.get("parent"))

found = {}
for x in scan(["src", "tools"]) + (scan(["examples"]) if os.path.isdir("examples") else []):
    if not vendored(x):
        found.setdefault(key(x), x)
cur = list(found.values())

old_keys = {key(x) for x in old}
cur_keys = {key(x) for x in cur}
added = sorted(cur_keys - old_keys)
removed = sorted(old_keys - cur_keys)

if added and not force:
    print(
        f"FAIL: --update would grow the baseline by {len(added)} declaration(s) "
        f"({len(old)} -> {len(cur)}) — the baseline only ratchets down.",
        file=sys.stderr,
    )
    for k in added:
        print(f"  + {k[0]}: {k[1]} {k[2]}", file=sys.stderr)
    if removed:
        print(f"  ({len(removed)} declaration(s) also disappeared)", file=sys.stderr)
    print("Fix the new dead code, or pass --force to record a deliberate addition.", file=sys.stderr)
    sys.exit(1)

items = sorted(
    [
        {"file": x["file"], "line": x["line"], "kind": x["kind"], "name": x["name"], "parent": x["parent"]}
        for x in cur
    ],
    key=lambda x: (x["file"], x["line"]),
)
json.dump({"items": items}, open(base_path, "w"), indent=2)
print(f"baseline updated: {len(old)} -> {len(items)} declarations (+{len(added)} / -{len(removed)})")
EOF
  exit 0
fi

python3 - <<'EOF'
import json, os, subprocess, sys

VENDORED = ("/zig-pkg/", "/.zig-cache/")

def key(x):
    return (x["file"], x["kind"], x["name"], x.get("parent"))

def in_examples(x):
    return x["file"].startswith("examples/")

def scan(paths):
    # `deadcode` exits non-zero as soon as it finds anything, so judge the JSON
    # body, not the exit status.
    run = subprocess.run(
        ["./zig-out/bin/zmodu", "deadcode", "-j", *paths],
        capture_output=True, text=True,
    )
    try:
        items = json.loads(run.stdout)["dead_declarations"]
    except ValueError:
        print(f"FAIL: deadcode scan of {' '.join(paths)} produced no parseable JSON", file=sys.stderr)
        sys.exit(2)
    # Vendored dependency snapshots are third-party copies, not this repo's
    # declarations (253 of the 260 raw examples hits today).
    return [x for x in items if not any(v in x["file"] for v in VENDORED)]

baseline = json.load(open("scripts/deadcode-baseline.json"))["items"]
current = scan(["src", "tools"]) + (scan(["examples"]) if os.path.isdir("examples") else [])

failed = False
scopes = (("src+tools", lambda x: not in_examples(x)), ("examples/**", in_examples))
for label, pred in scopes:
    base = {key(x) for x in baseline if pred(x)}
    now = {key(x) for x in current if pred(x)}
    added = now - base
    removed = base - now
    if added:
        failed = True
        print(f"FAIL: new dead declarations in {label} (not in baseline):")
        for x in sorted(added):
            print(f"  {x[0]}: {x[1]} {x[2]}")
    elif removed:
        print(f"OK: {len(removed)} dead declaration(s) removed from {label}; run --update to shrink the baseline.")
    else:
        print(f"OK: {label} dead-code count within baseline ({len(now)}).")

if failed:
    print("Fix them or run: scripts/check-deadcode.sh --update (only for deliberate additions)")
    sys.exit(1)
EOF
