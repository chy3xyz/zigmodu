#!/usr/bin/env bash
# bench-e2e.sh [--requests N] [--json-out PATH] [--debug]
#
# End-to-end HTTP benchmark against a real ZigModu server: builds
# `examples/http-stress-test` (h2c enabled, `/ping` + `/json`) in **ReleaseFast**
# — Debug is not a performance build: on the h2 path per-frame `std.log.debug`
# alone costs an order of magnitude (275 req/s vs 13.5k measured) — starts it on
# a free port with `BENCH_HOLD=1`, runs `scripts/bench_h1_h2.py` against it, and
# kills the server. The numbers are the bridge between the microbenchmarks
# (`bench-results.json`) and "how fast is a request": h1 keep-alive vs h2c on
# the same handler and host.
#
# `--debug` exists only to debug the benchmark itself; never quote its numbers.
#
# The JSON output (`--json-out`) is schema-v1 and keyed by commit, so runs can
# be accumulated into a series the same way the soak/runtime histories are.
#
# Requires Python 3 with the `h2` package (the client is h2's own library —
# see the pip hint below). Not part of the push gate: end-to-end numbers on a
# shared runner are noise; this is a release-time / local tool.
#
# For a dependency-free client and a median-of-rounds regression gate, see
# `src/bench_http.zig` (`zig build bench-http -- …`) and
# `scripts/check-bench-e2e.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."

requests=2000
json_out=""
optimize="ReleaseFast"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --requests) requests="$2"; shift 2 ;;
    --json-out) json_out="$2"; shift 2 ;;
    --debug) optimize="Debug"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "bench-e2e: unknown argument $1" >&2; exit 2 ;;
  esac
done

python3 -c 'import h2' 2>/dev/null || {
  echo "bench-e2e: python3 lacks the 'h2' package; install it with: python3 -m pip install h2" >&2
  exit 2
}

: "${ZIG_GLOBAL_CACHE_DIR:=.zig-global-cache}"
export ZIG_GLOBAL_CACHE_DIR
echo "bench-e2e: building examples/http-stress-test (-Doptimize=$optimize)" >&2
( cd examples/http-stress-test && zig build "-Doptimize=$optimize" ) >/dev/null
if [[ "$optimize" != "ReleaseFast" ]]; then
  echo "bench-e2e: WARNING Debug build — numbers are not comparable to any release baseline" >&2
fi

port="${BENCH_PORT:-18088}"
if ! curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${port}/ping"; then
  ( cd examples/http-stress-test && exec env HTTP_PORT="$port" BENCH_HOLD=1 ./zig-out/bin/http-stress-test >/tmp/bench-e2e-server.log 2>&1 ) &
  server_pid=$!
else
  echo "bench-e2e: a server already answers on ${port}; measuring it as-is (BENCH_PORT overrides)" >&2
  server_pid=""
fi
trap '[[ -n "${server_pid}" ]] && kill "${server_pid}" 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do
  if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:${port}/ping"; then
    break
  fi
  sleep 0.05
done

args=(--port "$port" --requests "$requests")
if [[ -n "$json_out" ]]; then
  args+=(--json-out "$json_out")
fi
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)" python3 scripts/bench_h1_h2.py "${args[@]}"
