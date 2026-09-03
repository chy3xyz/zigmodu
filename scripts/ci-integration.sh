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
zig build -Doptimize=ReleaseSafe -Ddb=sqlite
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

echo "integration: tenant isolation probes"
# JWT without aud + no X-Tenant-ID → missing tenant context
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "${AUTH}" "${BASE}/api/v1/users")"
[[ "$CODE" == "401" ]]
# X-Tenant-ID fallback (no aud in token) → scoped list
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "${AUTH}" -H "X-Tenant-ID: 1" "${BASE}/api/v1/users")"
[[ "$CODE" == "200" ]]
# JWT aud=1 vs X-Tenant-ID: 2 → conflict rejected
TENANT_TOKEN="$(JWT_AUD=1 "$JWT_BIN")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TENANT_TOKEN}" -H "X-Tenant-ID: 2" "${BASE}/api/v1/users")"
[[ "$CODE" == "403" ]]

echo "integration: http-stress-test"
cd "$ROOT/examples/http-stress-test"
zig build -Doptimize=ReleaseSafe
./zig-out/bin/http-stress-test

# ── ShopDemo smoke (order module, separate port) ──
SHOP_PORT="${SHOPDEMO_HTTP_PORT:-18081}"
SHOP_BASE="http://127.0.0.1:${SHOP_PORT}"

echo "integration: build shopdemo"
cd "$ROOT/examples/shopdemo"
zig build -Doptimize=ReleaseSafe -Ddb=sqlite
SHOP_BIN="$ROOT/examples/shopdemo/zig-out/bin/shopdemo"

echo "integration: start shopdemo on :${SHOP_PORT}"
HTTP_PORT="${SHOP_PORT}" "$SHOP_BIN" &
SHOP_PID=$!
# Extend trap to also stop shopdemo
trap 'kill "$PID" "$SHOP_PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; wait "$SHOP_PID" 2>/dev/null || true' EXIT

wait_shop() {
  local path="$1"
  for _ in $(seq 1 40); do
    if curl -sf "${SHOP_BASE}${path}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  echo "integration: timeout waiting for shopdemo ${path}" >&2
  return 1
}

wait_shop "/health/live"
SHOP_BODY="$(curl -sf "${SHOP_BASE}/health/live")"
echo "$SHOP_BODY" | grep -q '"status":"UP"'

SHOP_ORDERS="$(curl -sf "${SHOP_BASE}/api/v1/orders")"
echo "$SHOP_ORDERS" | grep -q '"items"'

echo "integration: OK"
