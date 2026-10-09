#!/usr/bin/env bash
# CL/TE request smuggling through Envoy — the same wire assertion as
# ../smuggling-e2e (nginx), against a different front-end parser.
#
#   cd examples/production-deploy/smuggling-envoy && ./run.sh     # skip w/o docker
#   ./run.sh --require                                            # docker required
#
# The invariant is unchanged and parser-independent:
#
#     every request the backend served was forwarded by the gateway
#
# Both sides are observable: Envoy's access log prints `METHOD PATH STATUS
# DETAILS` per request, the probe logs `REQLOG METHOD path` per dispatched
# request. What changes versus nginx is *who closes the hole*:
#
#   - nginx rejects CL+TE itself AND de-chunks/reframes what it forwards, so
#     the backend's own TE refusal never fires in that topology.
#   - Envoy rejects CL+TE conflicts at its own codec (measured:
#     `- - 400 http1.content_length_and_chunked_not_allowed`, no method/path)
#     and duplicate Transfer-Encoding with 501
#     (`http1.invalid_transfer_encoding`), but forwards a *well-formed*
#     chunked body upstream still chunked — so the backend's TE refusal
#     (control 2/4) is load-bearing here and asserted per TE-shaped payload.
#
# Requires: docker (running daemon, compose plugin), python3, a Zig toolchain.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
# The backend under test is the nginx topology's probe, built from its own
# directory: one probe, two gateways, no drift between what they face.
PROBE_DIR="$HERE/../smuggling-e2e"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"

APP_PORT="${APP_PORT:-18290}"
GW_PORT="${GW_PORT:-18291}"
ENVOY_IMAGE="${ENVOY_IMAGE:-envoyproxy/envoy:v1.31.10}"
PROJ="zigmodu-smuggle-envoy-$$"

REQUIRE=0
for arg in "$@"; do
    case "$arg" in
        --require) REQUIRE=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

WORK="$(mktemp -d)"
APP_PID=""

COMPOSE=(docker compose -p "$PROJ" -f "$HERE/docker-compose.yml")

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
    # gw_log is defined further down; a failure before that point (e.g. a busy
    # port) must still print a clean failure instead of "command not found".
    if declare -F gw_log >/dev/null; then gw_log >&2 || true; fi
    exit 1
}

cleanup() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        # Reap it here: otherwise the shell prints a "Terminated" job notice
        # after the summary, which reads like a failure that isn't one.
        wait "$APP_PID" 2>/dev/null || true
    fi
    "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
    return 0
}
trap cleanup EXIT

# --- preconditions -----------------------------------------------------------

command -v docker >/dev/null 2>&1 || skip "docker not installed"
docker info >/dev/null 2>&1 || skip "docker daemon not reachable"
docker compose version >/dev/null 2>&1 || skip "docker compose plugin not installed"
command -v python3 >/dev/null 2>&1 || skip "python3 not installed"

# --- build the probe (shared with the nginx topology) ------------------------

echo "== build =="
(cd "$PROBE_DIR" && zig build -Doptimize=ReleaseSafe)
BIN="$PROBE_DIR/zig-out/bin/smuggling-probe"
[ -x "$BIN" ] || fail "probe binary missing at $BIN"

# A second listener on the app port silently absorbs part of the traffic, and
# the resulting 401s look like a framework regression. Refuse to start instead.
if ! python3 "$PROBE_DIR/probe.py" --host 127.0.0.1 --port "$APP_PORT" --check-free >/dev/null; then
    fail "port $APP_PORT is already in use — another listener would split the traffic; set APP_PORT="
fi
if ! python3 "$PROBE_DIR/probe.py" --host 127.0.0.1 --port "$GW_PORT" --check-free >/dev/null; then
    fail "port $GW_PORT is already in use; set GW_PORT="
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
# … against requests the gateway forwarded. Two greps worth knowing about:
# `--no-log-prefix` keeps raw container lines (compose prefixes `envoy-1  | `,
# which the `^[A-Z]+ /` anchor would never match); and codec-level rejections
# log as `- - 400 …` with no method/path, so this count covers *forwarded*
# requests only. Readiness probes are excluded, same as the nginx harness.
gw_log() {
    "${COMPOSE[@]}" logs --no-log-prefix envoy 2>&1 || true
}
gateway_count() {
    # `|| n=0`: with `pipefail` the pipeline reports the status of the *last*
    # failing stage, and "no line matched" is a legitimate count of zero, not
    # an error worth aborting on.
    local n
    n="$(gw_log \
        | grep -E '^[A-Z]+ /' \
        | grep -v '/health/live' \
        | wc -l \
        | tr -d ' ')" || n=0
    printf '%s' "${n:-0}"
}
# Codec-level rejections are Envoy's own testimony that it refused the framing
# before anything could be forwarded (`- - 400 http1.content_length_and_chunked_not_allowed`).
reason_count() {
    local n
    n="$(gw_log | grep -cF "$1")" || n=0
    printf '%s' "${n:-0}"
}

# Envoy's access log is flushed asynchronously: a line lands in `docker
# compose logs` seconds after the request completed (measured 1–10 s on
# macOS/OrbStack; nginx logs immediately). Two primitives keep that latency
# out of the assertions:
#
#   barrier   — before snapshotting the gateway counter, wait until it is
#               stable across two polls, so a late flush of an *earlier*
#               step's lines cannot be attributed to the current one.
#   await_gw  — after each step, wait (bounded) until the gateway counter
#               reaches this step's *expected* value, then assert exactly.
#
# Both only ever turn logging latency into a red row, never into a green one:
# await_gw waits with `-ge` and the exact equality assertion after it catches
# any *extra* forward, and a timeout is a failure, not a pass.
barrier() {
    local prev=-1 curr
    for _ in $(seq 1 20); do
        curr="$(gateway_count)"
        [ "$curr" = "$prev" ] && return 0
        prev="$curr"
        sleep 0.5
    done
    echo "WARN: gateway counter still moving after 10s barrier" >&2
}
await_gw() {
    # $1 = expected gateway_count, $2 = codec-reject reason ('' = none),
    # $3 = expected reason_count
    local _i
    for _i in $(seq 1 80); do
        if [ "$(gateway_count)" -ge "$1" ]; then
            if [ -z "${2:-}" ] || [ "$(reason_count "$2")" -ge "${3:-0}" ]; then
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

# --- negative control: the backend side of the comparison must move ----------

printf 'GET /admin HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n' >"$WORK/control-direct.bin"
echo "== control 1/4: a plain /admin reaches the probe =="
python3 "$PROBE_DIR/probe.py" --host 127.0.0.1 --port "$APP_PORT" \
    --payload "$WORK/control-direct.bin" --label control-direct
[ "$(backend_count)" -ge 1 ] || fail "probe never logged a direct GET /admin — the detector is vacuous"
echo "   backend now reports $(backend_count) dispatched request(s)"

# --- control 2: the second line of defence, on the wire ----------------------
#
# Envoy forwards a well-formed chunked body upstream still chunked (measured,
# and asserted per payload below), so the backend's own TE refusal is the
# branch every TE-shaped payload here actually depends on. Send one straight
# at the backend: it must be refused, not parsed.

printf 'POST /ping HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n1;GET /admin HTTP/1.1\r\nX\r\n0\r\n\r\n' >"$WORK/control-te.bin"
echo "== control 2/4: the backend refuses Transfer-Encoding by itself =="
te_before="$(backend_count)"
te_json="$(python3 "$PROBE_DIR/probe.py" --host 127.0.0.1 --port "$APP_PORT" \
    --payload "$WORK/control-te.bin" --label control-te-direct)"
te_status="$(printf '%s' "$te_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["statuses"]))')"
echo "   response: HTTP $te_status"
[ "$te_status" = "400" ] || fail "a raw Transfer-Encoding request got HTTP $te_status, not 400"
[ "$(backend_count)" -eq "$te_before" ] || fail "a Transfer-Encoding request reached the handler after all"

# --- gateway -----------------------------------------------------------------

echo "== start gateway ($ENVOY_IMAGE) =="
# Rendered here, not mounted from the repo: the upstream port has to be
# APP_PORT, and envoy.yaml has no environment expansion (same lesson as the
# nginx template — the first nginx CI run proxied to a hardcoded 18080 while
# the probe listened on 18180).
sed "s/@APP_PORT@/${APP_PORT}/g" "$HERE/envoy.yaml.template" >"$WORK/envoy.yaml"
export RENDERED_CONF="$WORK/envoy.yaml" GW_PORT ENVOY_IMAGE

# Validate before serving: a config error otherwise surfaces as "readiness
# never came" with the useful message buried in the container log.
docker run --rm -v "$WORK/envoy.yaml:/etc/envoy/envoy.yaml:ro" \
    "$ENVOY_IMAGE" --mode validate -c /etc/envoy/envoy.yaml >"$WORK/validate.log" 2>&1 \
    || { cat "$WORK/validate.log" >&2; fail "envoy.yaml failed --mode validate"; }

"${COMPOSE[@]}" up -d >/dev/null || fail "docker compose up failed"

gw_ready=0
for _ in $(seq 1 100); do
    if curl -fsS "http://127.0.0.1:$GW_PORT/health/live" >/dev/null 2>&1; then
        gw_ready=1
        break
    fi
    sleep 0.2
done
[ "$gw_ready" = 1 ] || fail "gateway never served /health/live on $GW_PORT"

echo "== control 3/4: the gateway path works end to end =="
barrier
b0="$(backend_count)"
g0="$(gateway_count)"
curl -fsS "http://127.0.0.1:$GW_PORT/admin" >/dev/null
await_gw $((g0 + 1)) || fail "gateway never logged the forwarded /admin (still $(gateway_count) after 40s) — comparison unusable"
db=$(( $(backend_count) - b0 ))
dg=$(( $(gateway_count) - g0 ))
echo "   gateway +$dg, backend +$db"
[ "$dg" -eq 1 ] || fail "gateway did not log the forwarded /admin (got +$dg) — comparison unusable"
[ "$db" -eq 1 ] || fail "backend did not log the served /admin (got +$db) — comparison unusable"

# --- control 4: the comparison itself must be able to fire -------------------
#
# Send /admin straight at the backend, bypassing the gateway. The gateway's
# counter cannot move, so the invariant must report a mismatch. Without this,
# every green row below would also be consistent with a comparison that can
# never fail.

echo "== control 4/4: the invariant fires when it should =="
barrier
b0="$(backend_count)"
g0="$(gateway_count)"
python3 "$PROBE_DIR/probe.py" --host 127.0.0.1 --port "$APP_PORT" \
    --payload "$WORK/control-direct.bin" --label detector-self-test >/dev/null
# Nothing may ever reach the gateway here, so there is nothing to await —
# just give a hypothetical late line a fixed conservative window.
sleep 2
db=$(( $(backend_count) - b0 ))
dg=$(( $(gateway_count) - g0 ))
echo "   gateway +$dg, backend +$db"
[ "$db" -gt "$dg" ] || fail "the backend/gateway comparison did not fire on a bypass — its green rows mean nothing"

# --- payloads ----------------------------------------------------------------
#
# Same five single-client-write payloads as the nginx topology. Per payload
# the assertion is stricter than "no smuggling": the expected status, the
# exact gateway/backend deltas, and Envoy's own codec-rejection line are all
# pinned to the measured behaviour of the pinned image, so a framing-behaviour
# change in a future Envoy turns this table red instead of silently passing.
#
# fields: name | expected status | codec-reject reason ('-' = none) | expected gw Δ | expected backend Δ
PAYLOAD_TABLE='
cl-te-conflict|400|http1.content_length_and_chunked_not_allowed|0|0
te-cl-conflict|400|http1.content_length_and_chunked_not_allowed|0|0
te-chunk-ext-line|400|-|1|0
cl-space-spacing|404|-|2|2
te-dup-te|501|http1.invalid_transfer_encoding|0|0
'

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

bad_rows=0
echo
printf '%-20s %-4s %-14s %-10s %-8s %s\n' PAYLOAD RESP RESPONSE G+B CODEC VERDICT
# Here-string, not a pipe: a `| while` runs the loop in a subshell and every
# counter incremented inside it would be lost on exit — the final verdict
# would print green over SMUGGLED rows.
while IFS='|' read -r name want_status reason want_dg want_db; do
    [ -n "$name" ] || continue
    barrier
    b0="$(backend_count)"
    g0="$(gateway_count)"
    r0=0
    [ "$reason" != "-" ] && r0="$(reason_count "$reason")"
    probe_json="$(python3 "$PROBE_DIR/probe.py" --host 127.0.0.1 --port "$GW_PORT" \
        --payload "$WORK/$name.bin" --label "$name")"
    wait_ok=1
    if [ "$reason" != "-" ]; then
        await_gw $((g0 + want_dg)) "$reason" $((r0 + 1)) || wait_ok=0
    else
        await_gw $((g0 + want_dg)) || wait_ok=0
    fi
    db=$(( $(backend_count) - b0 ))
    dg=$(( $(gateway_count) - g0 ))
    dr=0
    [ "$reason" != "-" ] && dr=$(( $(reason_count "$reason") - r0 ))
    read -r responses statuses <<<"$(printf '%s' "$probe_json" | python3 -c \
        'import json,sys; d=json.load(sys.stdin); print(d["responses"], ",".join(d["statuses"]) or "-")')"

    verdict="ok"
    if [ "$responses" -lt 1 ]; then
        verdict="NO RESPONSE"
    elif [ "$wait_ok" -ne 1 ]; then
        verdict="LOG TIMEOUT"
    elif [ "${statuses%%,*}" != "$want_status" ]; then
        verdict="STATUS $statuses != $want_status"
    elif [ "$db" -gt "$dg" ]; then
        verdict="SMUGGLED"
    elif [ "$dg" -ne "$want_dg" ] || [ "$db" -ne "$want_db" ]; then
        verdict="COUNT +$dg/+$db != +$want_dg/+$want_db"
    elif [ "$reason" != "-" ] && [ "$dr" -ne 1 ]; then
        verdict="CODEC LOG MISSING ($reason +$dr)"
    fi
    [ "$verdict" = "ok" ] || bad_rows=$((bad_rows + 1))
    codec="-"
    [ "$reason" != "-" ] && codec="+$dr"
    printf '%-20s %-4s %-14s %-10s %-8s %s\n' \
        "$name" "$responses" "HTTP $statuses" "+$dg/+$db" "$codec" "$verdict"
done <<<"$PAYLOAD_TABLE"

echo
if [ "$bad_rows" -ne 0 ]; then
    fail "$bad_rows payload row(s) failed (see the table above — a SMUGGLED row means the backend served a request the gateway never forwarded)"
fi
echo "PASS: every request the backend served was one the gateway received (envoy)"
echo "      1/4 backend sees a plain /admin (detector is not vacuous)"
echo "      2/4 backend refuses a raw Transfer-Encoding request with 400"
echo "      3/4 proxied /admin counted on both sides"
echo "      4/4 a bypass is reported as a mismatch (the invariant can fire)"
echo "      plus, per payload: pinned status, exact gateway/backend deltas, and"
echo "      Envoy's own codec-rejection lines (http1.content_length_and_chunked_not_allowed,"
echo "      http1.invalid_transfer_encoding) where Envoy refuses the framing itself"
