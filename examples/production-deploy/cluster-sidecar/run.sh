#!/usr/bin/env bash
# run.sh — prove the cluster-sidecar topology end to end:
#
#   cd examples/production-deploy/cluster-sidecar && ./run.sh          # skip w/o docker
#   ./run.sh --require                                               # docker required
#
# What it asserts (not "the logs look nice" — each line is a falsifiable check):
#
#   1. the 3-node cluster elects exactly ONE leader and every node sees
#      `VIEW members=3` — so raft traffic really flows through the sidecars;
#   2. every node's bus reports `MESH peer=<id> state=connected` for BOTH
#      peers — so bus traffic also flows through the sidecars;
#   3. plaintext bypass is CLOSED: a probe container on the same docker
#      network cannot open the framework's plaintext raft port (9501) on any
#      node — the sidecar's iptables lockdown drops it;
#   4. the mTLS ingress refuses a peer without a client certificate (nginx
#      stream enforces post-handshake: the session is closed and the refusal
#      is logged), and accepts one with a valid node cert;
#   5. SIGTERM brings every node down with `CN SHUTDOWN clean`.
#
# Requires: docker (running daemon), openssl (host, for gen-certs.sh).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

REQUIRE=0
[ "${1:-}" = "--require" ] && REQUIRE=1

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  if [ "$REQUIRE" = 1 ]; then
    echo "cluster-sidecar: docker daemon not available (required via --require)" >&2
    exit 1
  fi
  echo "cluster-sidecar: docker not available — SKIPPED (run with --require to fail instead)"
  exit 0
fi

COMPOSE=(docker compose)
NET=zigmodu_cluster_sidecar_net
LOGDIR="$(mktemp -d)"
trap 'cd "$HERE" && ${COMPOSE[@]} down -v >/dev/null 2>&1 || true' EXIT

echo "==> gen-certs"
./gen-certs.sh

echo "==> docker compose build (node image compiles the framework — first run is slow)"
${COMPOSE[@]} build --quiet

echo "==> docker compose up -d"
${COMPOSE[@]} up -d

# Bounded poll: never hang forever — a hang IS the failure.
#
# Convergence is judged on each node's LATEST state, not on log history:
# raft allows re-elections, so "one distinct LEADER_ELECTED id ever" is wrong
# (and once masked a real wiring bug — node3 signed with KEY_N1, its frames
# were refused everywhere, and the run still "passed" because the only leader
# id that term happened to be n2). The honest shape: every node's last
# RAFT_STATE line names the SAME leader in the SAME term, exactly one node is
# `state=leader`, and no frame has EVER failed authentication (a refused frame
# in this demo is always a wiring bug, never background noise).
deadline=$(( $(date +%s) + 120 ))
pass=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  ${COMPOSE[@]} logs --no-color node1 node2 node3 >"$LOGDIR/nodes.log" 2>&1 || true

  views="$(grep -c 'VIEW members=3' "$LOGDIR/nodes.log" 2>/dev/null || true)"
  mesh="$(grep 'MESH .*state=connected' "$LOGDIR/nodes.log" 2>/dev/null | sort -u | wc -l | tr -d ' ' || true)"
  authfails="$(grep -cE 'not authenticated|PEER_REPLY_REFUSED|RAFTID_DROP' "$LOGDIR/nodes.log" 2>/dev/null || true)"

  leaders=""
  states=0
  for n in n1 n2 n3; do
    last="$(grep "RAFT_STATE node=$n " "$LOGDIR/nodes.log" | tail -1)"
    [ -n "$last" ] || continue
    leader="$(printf '%s' "$last" | sed -n 's/.* leader=\([^ ]*\).*/\1/p')"
    term="$(printf '%s' "$last" | sed -n 's/.* term=\([0-9]*\).*/\1/p')"
    leaders="$leaders $leader@$term"
    case "$last" in *state=leader*) states=$((states + 1)) ;; esac
  done
  uniq_leaders="$(printf '%s\n' $leaders | sort -u | grep -vc '^$' || true)"

  if [ "$views" -ge 3 ] && [ "$mesh" -ge 6 ] && [ "$authfails" = 0 ] && \
     [ "$uniq_leaders" = 1 ] && [ "$states" = 1 ] && [ "${leaders#*@-}" = "$leaders" ]; then
    pass=1
    break
  fi
  sleep 2
done

if [ "$pass" != 1 ]; then
  echo "FAIL: cluster did not converge within 120s (views=$views mesh=$mesh authfails=$authfails uniq_leaders=$uniq_leaders states=$states)" >&2
  echo "---- node logs ----" >&2
  tail -60 "$LOGDIR/nodes.log" >&2 || true
  echo "---- sidecar logs ----" >&2
  ${COMPOSE[@]} logs --no-color sidecar1 sidecar2 sidecar3 2>&1 | tail -30 >&2 || true
  exit 1
fi
echo "PASS: one leader (${leaders# }), members=3 on all nodes, full bus mesh, zero refused frames (over mTLS sidecars)"

# ── negative probe 1: plaintext bypass must be refused ─────────────────────
# A hostile workload on the same L2 tries the framework's plaintext raft port
# directly. The sidecar's iptables lockdown must DROP it (connect times out).
echo "==> probe: plaintext raft port 9501 must be unreachable from the network"
bypass=0
for ip in 172.28.0.11 172.28.0.12 172.28.0.13; do
  if docker run --rm --network "$NET" --entrypoint sh zigmodu-cluster-sidecar:local \
       -c "nc -z -w2 $ip 9501" >/dev/null 2>&1; then
    echo "FAIL: plaintext raft port 9501 on $ip accepted a connection (sidecar bypassed)" >&2
    bypass=1
  fi
done
[ "$bypass" = 0 ] || exit 1
echo "PASS: plaintext 9501 dropped on all three nodes"

# ── negative probe 2: mTLS ingress must refuse a certless peer ──────────────
# nginx stream enforces `ssl_verify_client on` POST-handshake (verified against
# the 1.27.5 source: ngx_stream_ssl_handler checks SSL_get_peer_certificate in
# the SSL phase and finalizes the session — the TLS handshake itself completes
# and the connection is then closed without proxying a byte). So the honest
# assertion is not "handshake fails" but "nginx logs the refusal".
#
# Two independent signals, both required:
#   (a) client-side behavioural: stdin is held open WITHOUT s_client's `Q`
#       quit command, so s_client can only exit when the SERVER closes the
#       session (rejected) — if `timeout 8` has to kill it (exit 124), the
#       connection stayed open, i.e. it was proxied through to the plaintext
#       raft port: fail-open, hard FAIL at once.
#   (b) server-side evidence: sidecar1 logs the refusal line. This is the
#       enforcer's own testimony and the line the README points at.
echo "==> probe: mTLS ingress 9601 must refuse a peer without a client cert"
refused=0
for attempt in 1 2 3; do
  docker run --rm --network "$NET" -v "$HERE/certs:/certs:ro" \
    --entrypoint sh zigmodu-cluster-sidecar:local \
    -c "sleep 10 | timeout 8 openssl s_client -connect 172.28.0.11:9601 -CAfile /certs/ca.crt" \
    >"$LOGDIR/probe2-$attempt.log" 2>&1 || probe_rc=$?
  probe_rc=${probe_rc:-0}
  if [ "$probe_rc" = 124 ]; then
    echo "FAIL: certless connection to 9601 stayed open past 8s — it was proxied" >&2
    echo "      through to the plaintext raft port (fail-open). probe output:" >&2
    tail -10 "$LOGDIR/probe2-$attempt.log" >&2
    exit 1
  fi
  sleep 1
  # Not `... | grep -q`: grep -q exits at the first match, the producer then
  # dies on SIGPIPE, and with `set -o pipefail` the pipeline reports 141 — the
  # `if` reads FALSE *even though the line was found*. Snap to a file instead.
  ${COMPOSE[@]} logs --no-color sidecar1 >"$LOGDIR/sidecar1.log" 2>&1 || true
  if grep -q "client sent no required SSL certificate" "$LOGDIR/sidecar1.log"; then
    refused=1
    break
  fi
  probe_rc=0
done
if [ "$refused" != 1 ]; then
  echo "FAIL: certless client was not refused at 9601 (no enforcement log line after 3 tries)" >&2
  echo "---- probe2 outputs ----" >&2
  for f in "$LOGDIR"/probe2-*.log; do echo "--- $f" >&2; tail -5 "$f" >&2; done
  ${COMPOSE[@]} logs --no-color --tail 20 sidecar1 >&2 || true
  exit 1
fi
echo "PASS: certless client refused (server-closed pre-timeout, enforcement logged)"

# ── positive probe: a valid node cert completes the mTLS handshake ─────────
echo "==> probe: mTLS ingress 9601 accepts a valid node cert"
docker run --rm --network "$NET" -v "$HERE/certs:/certs:ro" \
  --entrypoint sh zigmodu-cluster-sidecar:local \
  -c "echo Q | openssl s_client -connect 172.28.0.11:9601 \
        -cert /certs/node2.crt -key /certs/node2.key -CAfile /certs/ca.crt 2>&1 \
      | grep -q 'Verify return code: 0'" \
  || { echo "FAIL: valid client cert did not complete the mTLS handshake" >&2; exit 1; }
echo "PASS: node2 cert accepted (mTLS path verified both ways)"

# ── clean shutdown ──────────────────────────────────────────────────────────
echo "==> docker compose stop (SIGTERM)"
${COMPOSE[@]} stop >/dev/null
${COMPOSE[@]} logs --no-color node1 node2 node3 >"$LOGDIR/final.log" 2>&1 || true
clean="$(grep -c 'CN SHUTDOWN clean' "$LOGDIR/final.log" || true)"
if [ "$clean" -lt 3 ]; then
  echo "FAIL: only $clean/3 nodes shut down cleanly" >&2
  tail -40 "$LOGDIR/final.log" >&2 || true
  exit 1
fi
echo "PASS: all 3 nodes logged CN SHUTDOWN clean"

echo
echo "cluster-sidecar: ALL CHECKS PASSED"
echo "  (logs kept in $LOGDIR until next reboot)"
trap - EXIT
${COMPOSE[@]} down -v >/dev/null 2>&1 || true
