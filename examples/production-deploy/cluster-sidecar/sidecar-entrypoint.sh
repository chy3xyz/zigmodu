#!/bin/sh
# sidecar-entrypoint.sh — render the stream config, lock down the plaintext
# ports, then run nginx in the foreground.
#
# Env:
#   NODE_NAME  node1|node2|node3      (selects /certs/<name>.{crt,key})
#   PEERS      "2:172.28.0.12,3:172.28.0.13"  (index:ip pairs; index fixes the
#              loopback egress ports: raft 1970<idx>, bus 1980<idx>)
#   LOCKDOWN   on (default) | off — iptables rules that make the framework's
#              plaintext ports (9501 raft / 9502 bus) unreachable from anything
#              but 127.0.0.1. This is the load-bearing piece: the framework
#              binds 0.0.0.0, so without lockdown the sidecar can be bypassed
#              from inside the same docker network. Failure = exit 1
#              (fail-closed); set off only to demonstrate the bypass.
set -eu

: "${NODE_NAME:?set NODE_NAME (node1|node2|node3)}"
: "${PEERS:?set PEERS, e.g. 2:172.28.0.12,3:172.28.0.13}"
LOCKDOWN="${LOCKDOWN:-on}"

RAFT_PLAIN=9501
BUS_PLAIN=9502
RAFT_TLS=9601
BUS_TLS=9602

if [ "$LOCKDOWN" = "on" ]; then
  for p in "$RAFT_PLAIN" "$BUS_PLAIN"; do
    iptables -A INPUT -p tcp --dport "$p" -s 127.0.0.1 -j ACCEPT
    iptables -A INPUT -p tcp --dport "$p" -j DROP
  done || {
    echo "sidecar: iptables lockdown FAILED — plaintext cluster ports would stay" >&2
    echo "sidecar: reachable on the docker network. Refusing to start" >&2
    echo "sidecar: (needs cap_add: NET_ADMIN; or set LOCKDOWN=off to demo the bypass)" >&2
    exit 1
  }
  echo "sidecar: lockdown on — :$RAFT_PLAIN/:$BUS_PLAIN reachable from 127.0.0.1 only"
else
  echo "sidecar: WARNING lockdown OFF — plaintext :$RAFT_PLAIN/:$BUS_PLAIN are reachable" >&2
  echo "sidecar: WARNING from any container on the network (bypass demonstration)" >&2
fi

{
  cat <<EOF
user nginx;
worker_processes 1;
error_log /dev/stderr info;
events { worker_connections 256; }
stream {
  # ── ingress: terminate mTLS from peer sidecars, forward to the node on
  #    loopback (the only leg that ever touches a network is this one) ──
  server {
    listen 0.0.0.0:${RAFT_TLS} ssl;
    ssl_certificate        /certs/${NODE_NAME}.crt;
    ssl_certificate_key    /certs/${NODE_NAME}.key;
    ssl_client_certificate /certs/ca.crt;
    ssl_verify_client on;
    proxy_connect_timeout 3s;
    proxy_pass 127.0.0.1:${RAFT_PLAIN};
  }
  server {
    listen 0.0.0.0:${BUS_TLS} ssl;
    ssl_certificate        /certs/${NODE_NAME}.crt;
    ssl_certificate_key    /certs/${NODE_NAME}.key;
    ssl_client_certificate /certs/ca.crt;
    ssl_verify_client on;
    proxy_connect_timeout 3s;
    proxy_pass 127.0.0.1:${BUS_PLAIN};
  }
EOF

  # ── egress: the node dials loopback plaintext; we wrap it in mTLS to the
  #    peer sidecar. One loopback listener per peer per service. ──
  echo "$PEERS" | tr ',' '\n' | while IFS= read -r peer; do
    pidx="${peer%%:*}"
    pip="${peer#*:}"
    for svc in raft bus; do
      if [ "$svc" = raft ]; then lport="1970$pidx"; rport="$RAFT_TLS"; else lport="1980$pidx"; rport="$BUS_TLS"; fi
      cat <<EOF
  server {
    listen 127.0.0.1:${lport};
    proxy_connect_timeout 3s;
    proxy_pass ${pip}:${rport};
    proxy_ssl on;
    proxy_ssl_certificate     /certs/${NODE_NAME}.crt;
    proxy_ssl_certificate_key /certs/${NODE_NAME}.key;
    proxy_ssl_trusted_certificate /certs/ca.crt;
    proxy_ssl_verify on;
    proxy_ssl_verify_depth 2;
  }
EOF
    done
  done

  echo "}"
} >/etc/nginx/nginx.conf

nginx -t
echo "sidecar: nginx up — ingress :${RAFT_TLS}/:${BUS_TLS} (mTLS), egress loopback for peers [${PEERS}]"
exec nginx -g 'daemon off;'
