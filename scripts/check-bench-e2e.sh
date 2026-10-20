#!/usr/bin/env bash
# check-bench-e2e.sh [--rounds N] [--baseline PATH] [--threshold 0.6] [--update] [--json-out PATH]
#
# End-to-end regression gate: runs the dependency-free Zig load generator
# (`bench-http`) N rounds per protocol against a ReleaseFast server, takes the
# **median** round, and fails when it drops below `threshold` × the recorded
# baseline for this host.
#
# Why rounds + median: one run of a loopback benchmark on a busy laptop swings
# from 74k to 127k req/s on the same binary. A single-sample gate would either
# be red all day or so loose it never fires; the median of 3 with a 0.6× floor
# removes the noise without hiding a real halving.
#
# Baseline is keyed by OS/arch because absolute req/s does not travel between
# hosts. No entry for this host → the gate prints "no baseline" and exits 0
# (record one with `--update` on a quiet machine, then commit it).
set -euo pipefail
cd "$(dirname "$0")/.."

rounds=3
threshold="0.6"
baseline="scripts/bench-e2e-baseline.json"
update=0
json_out=""
port="${BENCH_PORT:-18095}"
h1_conns="${BENCH_H1_CONNS:-64}"
h2_conns="${BENCH_H2_CONNS:-16}"
h2_streams="${BENCH_H2_STREAMS:-16}"
reqs="${BENCH_REQUESTS:-200000}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rounds) rounds="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    --threshold) threshold="$2"; shift 2 ;;
    --update) update=1; shift ;;
    --json-out) json_out="$2"; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "check-bench-e2e: unknown argument $1" >&2; exit 2 ;;
  esac
done

: "${ZIG_GLOBAL_CACHE_DIR:=.zig-global-cache}"
export ZIG_GLOBAL_CACHE_DIR

# Build the tools and the server once; both are cached after the first run.
zig build >/dev/null
( cd examples/http-stress-test && zig build -Doptimize=ReleaseFast ) >/dev/null
bench="zig-out/bin/bench-http"
[[ -x "$bench" ]] || { echo "check-bench-e2e: $bench missing (zig build installs it)" >&2; exit 2; }

if ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${port}/ping"; then
  ( cd examples/http-stress-test && exec env HTTP_PORT="$port" BENCH_HOLD=1 ./zig-out/bin/http-stress-test >/tmp/check-bench-e2e-server.log 2>&1 ) &
  server_pid=$!
else
  server_pid=""
  echo "check-bench-e2e: a server already answers on ${port}; measuring it as-is" >&2
fi
trap '[[ -n "${server_pid}" ]] && kill "${server_pid}" 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${port}/ping"; then break; fi
  sleep 0.05
done

median() { sort -n | awk '{a[NR]=$1} END {print (NR%2? a[(NR+1)/2] : int((a[NR/2]+a[NR/2+1])/2))}'; }

run_rounds() {
  local proto="$1" conns="$2" streams="$3"
  local rps_file p50_file
  rps_file="$(mktemp)"; p50_file="$(mktemp)"
  for _ in $(seq 1 "$rounds"); do
    "$bench" --proto "$proto" --port "$port" --conns "$conns" \
      --streams "$streams" --requests "$reqs" 2>&1 \
      | tee /tmp/check-bench-e2e-last.log >/dev/null
    sed -n 's/.*req\/s=\([0-9]*\).*/\1/p' /tmp/check-bench-e2e-last.log >>"$rps_file"
    sed -n 's/.*p50=\([0-9]*\).*/\1/p' /tmp/check-bench-e2e-last.log >>"$p50_file"
  done
  local rps p50
  rps="$(median <"$rps_file")"
  p50="$(median <"$p50_file")"
  rm -f "$rps_file" "$p50_file"
  echo "${rps} ${p50}"
}

echo "check-bench-e2e: rounds=${rounds} requests/round=${reqs} threshold=${threshold}x" >&2
read -r h1_rps h1_p50 <<<"$(run_rounds h1 "$h1_conns" 1)"
read -r h2_rps h2_p50 <<<"$(run_rounds h2c "$h2_conns" "$h2_streams")"

host="$(uname -s | tr '[:upper:]' '[:lower:]')-$(uname -m)"
echo "host=${host}"
printf 'h1  median=%s req/s  p50=%s us\n' "$h1_rps" "$h1_p50"
printf 'h2c median=%s req/s  p50=%s us\n' "$h2_rps" "$h2_p50"
# Little's law check: queued latency should track (in-flight / throughput).
printf 'h2c in-flight=%s  expected_p50≈%s us\n' "$((h2_conns * h2_streams))" \
  "$(( h2_rps > 0 ? (h2_conns * h2_streams) * 1000000 / h2_rps : 0 ))"

if (( update )); then
  python3 - "$baseline" "$host" "$h1_conns" "$h1_rps" "$h1_p50" "$h2_conns" "$h2_streams" "$h2_rps" "$h2_p50" <<'PY'
import json, os, sys
path, host, h1c, h1r, h1p, h2c, h2s, h2r, h2p = sys.argv[1:]
data = {"v": 1, "hosts": {}}
if os.path.exists(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
data.setdefault("hosts", {})[host] = {
    "h1": {"conns": int(h1c), "median_rps": int(h1r), "median_p50_us": int(h1p)},
    "h2c": {"conns": int(h2c), "streams": int(h2s), "median_rps": int(h2r), "median_p50_us": int(h2p)},
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"check-bench-e2e: baseline updated for {host} -> {path}")
PY
  exit 0
fi

if [[ -n "$json_out" ]]; then
  python3 - "$json_out" "$host" "$h1_rps" "$h1_p50" "$h2_rps" "$h2_p50" "$rounds" "$reqs" <<'PY'
import json, sys
path, host, h1r, h1p, h2r, h2p, rounds, reqs = sys.argv[1:]
rec = {"v": 1, "kind": "http-e2e-gate", "host": host, "rounds": int(rounds),
       "requests_per_round": int(reqs),
       "h1": {"median_rps": int(h1r), "median_p50_us": int(h1p)},
       "h2c": {"median_rps": int(h2r), "median_p50_us": int(h2p)}}
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, sort_keys=True) + "\n")
PY
fi

if [[ ! -f "$baseline" ]]; then
  echo "check-bench-e2e: no baseline at ${baseline}; nothing to compare (record with --update)" >&2
  exit 0
fi

status=0
while read -r proto rps stored; do
  [[ "$proto" == "__no_baseline__" ]] && { echo "check-bench-e2e: no baseline for ${host}; record with --update" >&2; continue; }
  [[ -z "${stored}" || "${stored}" == "null" ]] && continue
  floor="$(awk -v s="$stored" -v t="$threshold" 'BEGIN { printf "%d", s * t }')"
  if (( rps < floor )); then
    echo "check-bench-e2e: FAIL ${proto} median ${rps} req/s < ${floor} (${threshold}x of baseline ${stored})" >&2
    status=1
  else
    echo "check-bench-e2e: ok   ${proto} median ${rps} req/s >= ${floor} (baseline ${stored})"
  fi
done < <(python3 - "$baseline" "$host" "$h1_rps" "$h2_rps" <<'PY'
import json, sys
path, host, h1, h2 = sys.argv[1:5]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    sys.exit(0)
entry = data.get("hosts", {}).get(host)
if not entry:
    print(f"__no_baseline__ 0 0")
    sys.exit(0)
print("h1", h1, entry.get("h1", {}).get("median_rps"))
print("h2c", h2, entry.get("h2c", {}).get("median_rps"))
PY
)

exit "$status"
