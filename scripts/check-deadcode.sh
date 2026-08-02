#!/usr/bin/env bash
# Dead-code baseline gate: fails when the repo gains new dead declarations;
# allows removals (and auto-updates the baseline when run with --update).
#
# Identity = file:kind:name:parent (line numbers are informational, so code
# moves don't cause false positives).
set -euo pipefail
cd "$(dirname "$0")/.."

ZMODU=./zig-out/bin/zmodu
if [ ! -x "$ZMODU" ]; then
  echo "building zmodu..." >&2
  zig build 2>&1 | tail -1
fi

if [ "${1:-}" = "--update" ]; then
  "$ZMODU" deadcode -j src tools | python3 -c "
import json,sys
d=json.load(sys.stdin)
items=[{'file':x['file'],'line':x['line'],'kind':x['kind'],'name':x['name'],'parent':x['parent']} for x in d['dead_declarations']]
items.sort(key=lambda x:(x['file'],x['line']))
json.dump({'items':items},open('scripts/deadcode-baseline.json','w'),indent=2)
print('baseline updated:',len(items),'declarations')
"
  exit 0
fi

python3 - <<'EOF'
import json, subprocess, sys

baseline = json.load(open('scripts/deadcode-baseline.json'))['items']
out = subprocess.run(
    ['./zig-out/bin/zmodu', 'deadcode', '-j', 'src', 'tools'],
    capture_output=True, text=True,
).stdout
current = json.loads(out)['dead_declarations']

def key(x):
    return (x['file'], x['kind'], x['name'], x.get('parent'))

base = {key(x) for x in baseline}
now = {key(x) for x in current}

added = now - base
removed = base - now

if added:
    print('FAIL: new dead declarations (not in baseline):')
    for x in sorted(added):
        print(f'  {x[0]}: {x[1]} {x[2]}')
    print('Fix them or run: scripts/check-deadcode.sh --update (only for deliberate additions)')
    sys.exit(1)

if removed:
    print(f'OK: {len(removed)} dead declaration(s) removed; run --update to shrink the baseline.')
else:
    print(f'OK: dead-code count within baseline ({len(now)}).')
EOF
