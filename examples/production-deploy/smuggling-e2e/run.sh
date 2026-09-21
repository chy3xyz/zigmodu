#!/usr/bin/env bash
# CL/TE request smuggling — measured through a real gateway, not argued.
#
#   cd examples/production-deploy/smuggling-e2e && ./run.sh          # skip w/o docker
#   ./run.sh --require                                              # docker required
#
# Why this exists: docs/dev/security-audit-v0.31.0.md §2 (the request boundary
# honoured only `Content-Length`) was derived by reading the parser, and the fix
# landed with in-process tests (src/api/Server.zig:4649+, :4971+). But a parser
# is only half of a smuggling bug — the other half is the front-end's framing,
# and no in-process test can see that half. This script puts nginx in front
# (the topology this repo ships in nginx.conf) and asserts on the wire.
#
# The assertion is not "the response looks right". It is:
#
#     every request the backend served was forwarded by the gateway
#
# Both sides are observable: nginx logs `METHOD URI` per forwarded request, the
# probe logs `REQLOG METHOD path` per dispatched request. A request the backend
# served but the gateway never forwarded is a smuggling primitive, by
# definition — no interpretation required.
#
# Requires: docker (running daemon), python3, a Zig toolchain.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

APP_PORT="${APP_PORT:-18080}"
GW_BUFFERED_PORT="${GW_BUFFERED_PORT:-18081}"
GW_STREAM_PORT="${GW_STREAM_PORT:-18082}"
NGINX_IMAGE="${NGINX_IMAGE:-nginx:1.27-alpine}"

REQUIRE=0
for arg in "$@"; do
    case "$arg" in
        --require) REQUIRE=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

WORK="$(mktemp -d)"
APP_PID=""
NGINX_NAME="zigmodu-smuggle-$$"

skip() {
    echo "SKIP: $*"
    if [ "$REQUIRE" = 1 ]; then
        echo "(--require was passed; treating skip as failure)" >&2
        exit 1
    fi
    exit 0
}

fail() {
    echo "FAIL: $*" >&2
    echo "--- app log ---" >&2
    [ -f "$WORK/app.log" ] && cat "$WORK/app.log" >&2
    echo "--- gateway log ---" >&2
    docker logs "$NGINX_NAME" >&2 2>&1 || true
    exit 1
}

cleanup() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        # Reap it here: otherwise the shell prints a "Terminated" job notice after
        # the summary, which reads like a failure that isn't one.
        wait "$APP_PID" 2>/dev/null || true
    fi
    docker rm -f "$NGINX_NAME" >/dev/null 2>&1 || true
    return 0
}
trap cleanup EXIT

# --- preconditions -----------------------------------------------------------

command -v docker >/dev/null 2>&1 || skip "docker not installed"
docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

# --- build the probe ---------------------------------------------------------

echo "== build =="
(cd "$HERE" && zig build -Doptimize=ReleaseSafe)
BIN="$HERE/zig-out/bin/smuggling-probe"
[ -x "$BIN" ] || fail "probe binary missing at $BIN"

# A second listener on the app port silently absorbs part of the traffic, and
# the resulting 401s look like a framework regression. Refuse to start instead.
if ! python3 "$HERE/probe.py" --host 127.0.0.1 --port "$APP_PORT" --check-free >/dev/null; then
    fail "port $APP_PORT is already in use — another listener would split the traffic; set APP_PORT="
fi

echo "== start probe on 127.0.0.1:$APP_PORT =="
HTTP_PORT="$APP_PORT" "$BIN" >"$WORK/app.log" 2>&1 &
APP_PID=$!

for _ in $(seq 1 60); do
    grep -q "READY port=" "$WORK/app.log" 2>/dev/null && break
    sleep 0.2
done
grep -q "READY port=" "$WORK/app.log" || fail "probe never became ready"

# Requests the backend dispatched (its own record of what it served) …
backend_count() {
    local n
    n="$(grep -c 'REQLOG ' "$WORK/app.log" 2>/dev/null)" || n=0
    printf '%s' "${n:-0}"
}
# … against requests the gateway forwarded. Readiness probes are excluded: the
# harness sends those on purpose and they would otherwise show up as a mismatch.
gateway_count() {
    # `|| n=0`: with `pipefail` the pipeline reports the status of the *last*
    # failing stage, and "no line matched" is a legitimate count of zero, not an
    # error worth aborting on.
    local n
    n="$(docker logs "$NGINX_NAME" 2>&1 \
        | grep -E '^[A-Z]+ /' \
        | grep -v '/health/live' \
        | wc -l \
        | tr -d ' ')" || n=0
    printf '%s' "${n:-0}"
}

# --- negative control: the backend side of the comparison must move ----------

printf 'GET /admin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' >"$WORK/control-direct.bin"
echo "== control 1/4: a plain /admin reaches the probe =="
python3 "$HERE/probe.py" --host 127.0.0.1 --port "$APP_PORT" \
    --payload "$WORK/control-direct.bin" --label control-direct
[ "$(backend_count)" -ge 1 ] || fail "probe never logged a direct GET /admin — the detector is vacuous"
echo "   backend now reports $(backend_count) dispatched request(s)"

# --- control 2: the second line of defence, on the wire ----------------------
#
# The gateway normalises body framing (measured below), so the backend's own
# refusal is the branch that only fires if a front-end ever does forward a
# `Transfer-Encoding` upstream. Send one straight at the backend: it must be
# refused, not parsed.

printf 'POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1;GET /admin HTTP/1.1\r\nX\r\n0\r\n\r\n' >"$WORK/control-te.bin"
echo "== control 2/4: the backend refuses Transfer-Encoding by itself =="
te_before="$(backend_count)"
te_json="$(python3 "$HERE/probe.py" --host 127.0.0.1 --port "$APP_PORT" \
    --payload "$WORK/control-te.bin" --label control-te-direct)"
te_status="$(printf '%s' "$te_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["statuses"]))')"
echo "   response: HTTP $te_status"
[ "$te_status" = "400" ] || fail "a raw Transfer-Encoding request got HTTP $te_status, not 400"
[ "$(backend_count)" -eq "$te_before" ] || fail "a Transfer-Encoding request reached the handler after all"

# --- gateway -----------------------------------------------------------------

echo "== start gateway ($NGINX_IMAGE) =="
# The conf is rendered here, not mounted from the repo: the upstream port has to
# be `APP_PORT`, and a conf mounted at `conf.d/` is used verbatim by nginx (no
# env expansion, and the image's `envsubst-on-templates` only looks at
# `/etc/nginx/templates`). Mounting the template directly is how the first CI
# run proxied to the default 18080 while the probe listened on 18180.
sed "s/@APP_PORT@/${APP_PORT}/g" "$HERE/nginx.conf.template" >"$WORK/nginx.conf"
docker run -d --name "$NGINX_NAME" \
    --add-host=host.docker.internal:host-gateway \
    -p "$GW_BUFFERED_PORT:18081" \
    -p "$GW_STREAM_PORT:18082" \
    -v "$WORK/nginx.conf:/etc/nginx/conf.d/default.conf:ro" \
    "$NGINX_IMAGE" >/dev/null

gw_ready=0
for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$GW_BUFFERED_PORT/health/live" >/dev/null 2>&1; then
        gw_ready=1
        break
    fi
    sleep 0.2
done
[ "$gw_ready" = 1 ] || fail "gateway never served /health/live on $GW_BUFFERED_PORT"

echo "== control 3/4: the gateway path works end to end =="
b0="$(backend_count)"
g0="$(gateway_count)"
curl -fsS "http://127.0.0.1:$GW_BUFFERED_PORT/admin" >/dev/null
sleep 0.4
db=$(( $(backend_count) - b0 ))
dg=$(( $(gateway_count) - g0 ))
echo "   gateway +$dg, backend +$db"
[ "$dg" -eq 1 ] || fail "gateway did not log the forwarded /admin (got +$dg) — comparison unusable"
[ "$db" -eq 1 ] || fail "backend did not log the served /admin (got +$db) — comparison unusable"

# --- control 3: the comparison itself must be able to fire -------------------
#
# Send /admin straight at the backend, bypassing the gateway. The gateway's
# counter cannot move, so the invariant must report a mismatch. Without this,
# every green row below would also be consistent with a comparison that can
# never fail.

echo "== control 4/4: the invariant fires when it should =="
b0="$(backend_count)"
g0="$(gateway_count)"
python3 "$HERE/probe.py" --host 127.0.0.1 --port "$APP_PORT" \
    --payload "$WORK/control-direct.bin" --label detector-self-test >/dev/null
sleep 0.4
db=$(( $(backend_count) - b0 ))
dg=$(( $(gateway_count) - g0 ))
echo "   gateway +$dg, backend +$db"
[ "$db" -gt "$dg" ] || fail "the backend/gateway comparison did not fire on a bypass — its green rows mean nothing"

# --- payloads ----------------------------------------------------------------
#
# Each one is a single client write that a front-end and a back-end may frame
# differently. What we are looking for is the case where the *back-end* served a
# request the *gateway* never forwarded.

mkpayload() {
    printf '%b' "$2" >"$WORK/$1.bin"
}
mkpayload cl-te-conflict \
    'POST /ping HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\nGET /admin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
mkpayload te-cl-conflict \
    'POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n0\r\n\r\nGET /admin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
mkpayload te-chunk-ext-line \
    'POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1;GET /admin HTTP/1.1\r\nX\r\n0\r\n\r\n'
mkpayload cl-space-spacing \
    'POST /ping HTTP/1.1\r\nHost: x\r\nContent-Length:5\r\n\r\nhelloGET /admin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'
mkpayload te-dup-te \
    'POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: identity\r\n\r\n1\r\nX\r\n0\r\n\r\nGET /admin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n'

PAYLOADS="cl-te-conflict te-cl-conflict te-chunk-ext-line cl-space-spacing te-dup-te"

smuggled=0
echo
printf '%-20s %-9s %-4s %-14s %-10s %s\n' PAYLOAD GATEWAY RESP RESPONSE G+B VERDICT
for name in $PAYLOADS; do
    for port in "$GW_BUFFERED_PORT" "$GW_STREAM_PORT"; do
        tag=$([ "$port" = "$GW_BUFFERED_PORT" ] && echo buffered || echo streamed)
        b0="$(backend_count)"
        g0="$(gateway_count)"
        probe_json="$(python3 "$HERE/probe.py" --host 127.0.0.1 --port "$port" \
            --payload "$WORK/$name.bin" --label "$name")"
        sleep 0.4
        db=$(( $(backend_count) - b0 ))
        dg=$(( $(gateway_count) - g0 ))
        read -r responses statuses <<<"$(printf '%s' "$probe_json" | python3 -c \
            'import json,sys; d=json.load(sys.stdin); print(d["responses"], ",".join(d["statuses"]) or "-")')"

        verdict="ok"
        if [ "$responses" -lt 1 ]; then
            verdict="NO RESPONSE"
        fi
        if [ "$db" -gt "$dg" ]; then
            verdict="SMUGGLED"
            smuggled=$((smuggled + 1))
        fi
        printf '%-20s %-9s %-4s %-14s %-10s %s\n' \
            "$name" "$tag" "$responses" "HTTP $statuses" "+$dg/+$db" "$verdict"
    done
done

echo
if [ "$smuggled" -ne 0 ]; then
    fail "$smuggled payload(s) had the backend serve a request the gateway never forwarded"
fi
echo "PASS: every request the backend served was one the gateway received"
echo "      1/4 backend sees a plain /admin (detector is not vacuous)"
echo "      2/4 backend refuses a raw Transfer-Encoding request with 400"
echo "      3/4 proxied /admin counted on both sides"
echo "      4/4 a bypass is reported as a mismatch (the invariant can fire)"
