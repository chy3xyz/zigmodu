#!/usr/bin/env bash
# CI full: tenant-mgmt live probes + http-stress-test self-check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"
PORT="${HTTP_PORT:-18080}"
BASE="http://127.0.0.1:${PORT}"
JWT_SECRET="${JWT_SECRET:-dev-secret}"

wait_http() {
  local path="$1"
  for _ in $(seq 1 40); do
    if curl -sf "${BASE}${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "integration: timeout waiting for ${path}" >&2
  return 1
}

echo "integration: build gen-jwt-token"
cd "$ROOT"
zig build gen-jwt-token -Doptimize=ReleaseSafe
JWT_BIN="$ROOT/zig-out/bin/gen-jwt-token"
TOKEN="$("$JWT_BIN")"
AUTH="Authorization: Bearer ${TOKEN}"

echo "integration: build tenant-mgmt"
cd "$ROOT/examples/tenant-mgmt"
zig build -Doptimize=ReleaseSafe
BIN="$ROOT/examples/tenant-mgmt/zig-out/bin/tenant-mgmt"

echo "integration: start tenant-mgmt on :${PORT}"
HTTP_PORT="${PORT}" JWT_SECRET="${JWT_SECRET}" "$BIN" &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true' EXIT

wait_http "/health/live"
BODY="$(curl -sf "${BASE}/health/live")"
echo "$BODY" | grep -q '"status":"UP"'

CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/dashboard")"
[[ "$CODE" == "200" ]]

CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/v1/tenants")"
[[ "$CODE" == "401" ]]

CREATE_BODY="$(curl -sf -X POST -H "${AUTH}" \
  "${BASE}/api/v1/tenants?name=CI-Tenant&domain=ci.example.com&tier=free")"
echo "$CREATE_BODY" | grep -q '"name":"CI-Tenant"'
echo "$CREATE_BODY" | grep -q '"id":'

LIST_BODY="$(curl -sf -H "${AUTH}" "${BASE}/api/v1/tenants")"
echo "$LIST_BODY" | grep -q 'CI-Tenant'
echo "$LIST_BODY" | grep -q '"tier":"free"'

CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "${AUTH}" "${BASE}/api/v1/plans")"
[[ "$CODE" == "200" ]]

echo "integration: http-stress-test"
cd "$ROOT/examples/http-stress-test"
zig build -Doptimize=ReleaseSafe
./zig-out/bin/http-stress-test

echo "integration: OK"
