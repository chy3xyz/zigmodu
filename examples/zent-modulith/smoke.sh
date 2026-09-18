#!/usr/bin/env bash
# zent-modulith runtime smoke — exercises every demo route against a real server.
#
# Why this exists: compiling the example proves nothing about the zent
# integration. The v0.15.44 → v0.15.46 upgrade slid past "it builds" while
# `GET /products/{id}` panicked the server with a mismatched free
# (`deinitRow` on a row that `CrudService.get` had already copied into the
# request arena). Every check below is a request someone actually makes, so a
# contract change in zent fails here instead of in a consumer's staging.
#
# Usage:  bash examples/zent-modulith/smoke.sh [PORT]
# Requires: sqlite3 headers (the CI "Build Examples" job installs them).
#
# ZENT_SMOKE_SKIP_BUILD=1 skips the `zig build` below — set by the example's
# `zig build test` step, which already installed the binary it runs here (a
# nested build would otherwise contend for the same cache).
set -uo pipefail

PORT="${1:-${PORT:-18111}}"
BASE="http://127.0.0.1:${PORT}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/zent-modulith"
DB="$(mktemp -u /tmp/zent-smoke-XXXXXX.db)"
LOG="$(mktemp /tmp/zent-smoke-XXXXXX.log)"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

cleanup() { [[ -n "${PID:-}" ]] && kill "$PID" 2>/dev/null; rm -f "$DB"* "$LOG"; }
trap cleanup EXIT

if [[ "${ZENT_SMOKE_SKIP_BUILD:-0}" == "1" ]]; then
  echo "smoke: using the binary built by the caller ($EX/zig-out/bin/zent-modulith)"
else
  echo "smoke: building zent-modulith"
  (cd "$EX" && zig build) || { echo "smoke: build failed"; exit 1; }
fi

echo "smoke: starting server on :$PORT (db=$DB)"
ZENT_SQLITE="$DB" ZENT_DEV_TOKEN=1 HTTP_PORT="$PORT" "$EX/zig-out/bin/zent-modulith" > "$LOG" 2>&1 &
PID=$!
for _ in $(seq 1 80); do curl -sf "$BASE/health/live" >/dev/null 2>&1 && break; sleep 0.25; done
if ! curl -sf "$BASE/health/live" >/dev/null 2>&1; then
  echo "smoke: server did not become healthy"; sed -n '1,40p' "$LOG"; exit 1
fi

TOKEN=$(curl -s -X POST "$BASE/api/v1/dev/token?tenant_id=1&sub=100" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[[ -n "$TOKEN" ]] || { echo "smoke: could not mint a dev token"; exit 1; }
AUTH="Authorization: Bearer $TOKEN"
JSON='Content-Type: application/json'

n=0 bad=0
hit() { # hit <label> <expected-status-regex> <curl args...>
  local label="$1" want="$2"; shift 2
  local out code body
  out=$(curl -s -m 10 -w '\n%{http_code}' "$@")
  code=$(printf '%s' "$out" | tail -1)
  body=$(printf '%s' "$out" | sed '$d')
  n=$((n + 1))
  if [[ ! "$code" =~ $want ]]; then
    bad=$((bad + 1))
    printf 'FAIL %-40s http=%s want=%s\n  %s\n' "$label" "$code" "$want" "${body:0:200}"
  else
    printf 'ok   %-40s %s\n' "$label" "$code"
  fi
}

# ── infra ──────────────────────────────────────────────────────────────────
hit "health"                 '^200$' "$BASE/health/live"
hit "openapi"                '^200$' "$BASE/openapi.json"

# ── generic CRUD (zent.crud.CrudService via CrudApi; tenant from JWT aud) ──
hit "tenant create"          '^2..$' -X POST "$BASE/api/v1/tenants?name=Acme&domain=acme.test"
hit "product create"         '^2..$' -H "$AUTH" -H "$JSON" -X POST "$BASE/api/v1/products" -d '{"name":"Widget","price_cents":1999,"price":"19.99"}'
# The regression this file was written for: a found row must serialize, not panic.
hit "product get (found)"    '^200$' -H "$AUTH" "$BASE/api/v1/products/1"
hit "product list"           '^200$' -H "$AUTH" "$BASE/api/v1/products?page_size=10"
hit "product update"         '^200$' -H "$AUTH" -H "$JSON" -X PUT "$BASE/api/v1/products/1" -d '{"name":"Widget Pro","price_cents":2199,"price":"21.99"}'
hit "product get (missing)"  '^404$' -H "$AUTH" "$BASE/api/v1/products/99999"
hit "product counts"         '^200$' -H "$AUTH" "$BASE/api/v1/products/counts"
hit "product search"         '^200$' -H "$AUTH" "$BASE/api/v1/products/search?tenant_id=1&q=Widget"
hit "product bulk (upsert)"  '^2..$' -H "$AUTH" -H "$JSON" -X POST "$BASE/api/v1/products/bulk" -d '[{"id":50,"tenant_id":1,"name":"BulkA","price_cents":100}]'
hit "product batch"          '^2..$' -H "$AUTH" -H "$JSON" -X POST "$BASE/api/v1/products/batch" -d '[{"tenant_id":1,"name":"BatA","price_cents":300}]'
hit "products summary"       '^200$' -H "$AUTH" "$BASE/api/v1/products/summary"

# ── commerce: atomic stock, sku upsert, transactional orders ───────────────
hit "inventory read"         '^200$' "$BASE/api/v1/inventory/1"
hit "inventory decrement"    '^200$' -X POST "$BASE/api/v1/inventory/decrement?product_id=1&qty=30"
hit "inventory short (409)"  '^409$' -X POST "$BASE/api/v1/inventory/decrement?product_id=1&qty=100000"
hit "sku-stock upsert"       '^2..$' -H "$JSON" -X PUT "$BASE/api/v1/sku-stock" -d '{"sku":"A-1","stock":7,"price":"3.50"}'
hit "sku-stock get"          '^200$' "$BASE/api/v1/sku-stock/A-1"
hit "orders create (tx)"     '^2..$' -X POST "$BASE/api/v1/orders?product_id=1&qty=3"
hit "orders short (409)"     '^409$' -X POST "$BASE/api/v1/orders?product_id=1&qty=100000"
hit "orders get"             '^200$' "$BASE/api/v1/orders/1"
hit "accounts create (uuidv7)" '^2..$' -X POST "$BASE/api/v1/accounts?name=bob&api_key=sk-bob-9"
hit "tenant-injection create" '^2..$' -H "$JSON" -X POST "$BASE/api/v1/tenant-injection" -d '{"name":"Injected","price_cents":500,"price":"5.00"}'
hit "tenant-injection list"  '^200$' "$BASE/api/v1/tenant-injection"

# ── social: nested preload, keyset cursor, bulk soft delete ───────────────
hit "feed authors (nested)"  '^200$' "$BASE/api/v1/feed/authors"
hit "feed2 authors+posts"    '^200$' "$BASE/api/v1/feed2/authors-with-posts"
hit "feed comments page 1"   '^200$' "$BASE/api/v1/feed/comments?page_size=1"
hit "feed comments page 2"   '^200$' "$BASE/api/v1/feed/comments?cursor_ts=100&cursor_id=1&page_size=1"
hit "feed bulk-delete"       '^200$' -H "$JSON" -X POST "$BASE/api/v1/feed/bulk-delete" -d '{"ids":[1,2]}'
hit "feed trashed"           '^200$' "$BASE/api/v1/feed/trashed"
hit "feed restore"           '^200$' -X POST "$BASE/api/v1/feed/1/restore"
hit "bulk-delete empty ids"  '^4..$' -H "$JSON" -X POST "$BASE/api/v1/feed/bulk-delete" -d '{"ids":[]}'

# ── outbox + SSE ──────────────────────────────────────────────────────────
hit "outbox enqueue"         '^2..$' -X POST "$BASE/api/v1/outbox/enqueue?aggregate_type=product&aggregate_id=1&event_type=product.created&payload=%7B%22id%22%3A1%7D"
hit "outbox dispatch"        '^2..$' -X POST "$BASE/api/v1/outbox/dispatch"
hit "events (SSE)"           '^200$' -H "$AUTH" "$BASE/api/v1/events"

# ── data scope (row-level policy pushed into SQL) ─────────────────────────
hit "docs scope=self_"       '^200$' "$BASE/api/v1/docs?user_id=1&tenant_id=1&scope=self_"
hit "docs scope=dept_custom" '^200$' "$BASE/api/v1/docs?user_id=1&tenant_id=1&scope=dept_custom&dept_ids=9"
# zent v0.66.0: an empty dept_ids list must DENY (it used to widen to the whole
# table, because a null predicate means "no restriction" in that module).
EMPTY=$(curl -s "$BASE/api/v1/docs?user_id=1&tenant_id=1&scope=dept_custom&dept_ids=")
n=$((n + 1))
if [[ "$EMPTY" == *'"items":[]'* ]]; then
  printf 'ok   %-40s empty dept_ids denies\n' "docs scope 空 dept_ids"
else
  bad=$((bad + 1)); printf 'FAIL %-40s empty dept_ids did not deny: %s\n' "docs scope 空 dept_ids" "${EMPTY:0:160}"
fi
hit "docs scope=dept_only"   '^200$' "$BASE/api/v1/docs?user_id=1&tenant_id=1&scope=dept_only&self_dept_id=3"
hit "docs scope=all"         '^200$' "$BASE/api/v1/docs?user_id=1&tenant_id=1&scope=all"
hit "docs missing identity"  '^4..$' "$BASE/api/v1/docs?user_id=&tenant_id=1&scope=self_"

# ── last: deleting product 1 breaks the order/inventory demos above ───────
hit "product delete"         '^2..$' -H "$AUTH" -X DELETE "$BASE/api/v1/products/1"
hit "product get (deleted)"  '^404$' -H "$AUTH" "$BASE/api/v1/products/1"

# ── verdict ───────────────────────────────────────────────────────────────
alive=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$BASE/health/live")
echo
echo "=== smoke: $n checks, $bad failed | server alive: $alive ==="
if grep -qaE "panic|ABRT" "$LOG"; then
  echo "smoke: SERVER PANICKED:"
  grep -aE "panic|ABRT" "$LOG" | head -5
  exit 1
fi
if [[ "$alive" != "200" ]]; then
  echo "smoke: server is not alive after the run"; sed -n '1,40p' "$LOG"; exit 1
fi
[[ "$bad" -eq 0 ]] || exit 1
