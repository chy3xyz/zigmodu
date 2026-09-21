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

# `set -e` does **not** abort on a failing `[[ … ]]` under macOS's bash 3.2, so
# every bare `[[ "$CODE" == "…" ]]` in this script was inert there while Linux
# (bash 5) enforced it — which is how three wrong expectations survived until the
# ubuntu job stopped being skipped. An explicit `exit 1` in a helper behaves the
# same on both shells.
expect_code() { # url want description [extra curl args…]
  local url="$1" want="$2" what="$3"
  shift 3
  local got
  got="$(curl -s -o /dev/null -w '%{http_code}' "$@" "$url")"
  if [ "$got" != "$want" ]; then
    echo "integration: FAIL — $what: got HTTP $got, want $want ($url)" >&2
    exit 1
  fi
}

expect_body() { # body needle description
  case "$1" in
    *"$2"*) ;;
    *) echo "integration: FAIL — $3 (body does not contain '$2')" >&2; exit 1 ;;
  esac
}

expect_code "${BASE}/dashboard" 200 "dashboard"
expect_code "${BASE}/api/v1/tenants" 401 "tenants without a token"

CREATE_BODY="$(curl -sf -X POST -H "${AUTH}" \
  "${BASE}/api/v1/tenants?name=CI-Tenant&domain=ci.example.com&tier=free")"
expect_body "$CREATE_BODY" '"name":"CI-Tenant"' "tenant create returns the row"
expect_body "$CREATE_BODY" '"id":' "tenant create returns an id"

LIST_BODY="$(curl -sf -H "${AUTH}" "${BASE}/api/v1/tenants")"
expect_body "$LIST_BODY" 'CI-Tenant' "tenant list contains the created row"
expect_body "$LIST_BODY" '"tier":"free"' "tenant list keeps the tier"

expect_code "${BASE}/api/v1/plans" 200 "plans with a token" -H "${AUTH}"

echo "integration: tenant isolation probes"
# What `requireTenantId` actually promises, measured against a real server.
# The token this script mints carries the framework's default `aud`
# (`"zigmodu-app"`, `SecurityModule.generateToken` always writes one), so "a
# token with no `aud` at all" is not a shape this generator can produce — the
# absent-tenant branch (401) is real, but nothing here can reach it. The three
# shapes below are the ones that exist:
expect_code "${BASE}/api/v1/users" 400 "non-numeric aud, no X-Tenant-ID" -H "${AUTH}"
expect_code "${BASE}/api/v1/users" 403 "non-numeric aud plus X-Tenant-ID" -H "${AUTH}" -H "X-Tenant-ID: 1"
TENANT_TOKEN="$(JWT_AUD=1 "$JWT_BIN")"
expect_code "${BASE}/api/v1/users" 200 "numeric aud alone" -H "Authorization: Bearer ${TENANT_TOKEN}"
expect_code "${BASE}/api/v1/users" 403 "aud=1 vs X-Tenant-ID: 2" -H "Authorization: Bearer ${TENANT_TOKEN}" -H "X-Tenant-ID: 2"

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
