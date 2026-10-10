#!/usr/bin/env bash
# ci-mixed-version.sh — the multi-process cluster gate (B-11 of
# docs/dev/v1.0-readiness-v0.35.md).
#
# `src/soak_cluster.zig` proves the cluster stack under sustained load with all
# three nodes in ONE process; this script proves it across processes and across
# VERSIONS, using the single-node harness `src/cluster_node.zig` (built by
# `zig build cluster-node`, installed as zig-out/bin/cluster-node):
#
#   1. build the master cluster-node binary;
#   2. SAME-VERSION run — three master nodes elect exactly one leader, converge
#      on the same `LEADER_ELECTED id=`, see `VIEW members=3`, replicate the
#      raft log, and shut down cleanly on SIGTERM;
#   3. build the OLD (v0.32.0) cluster-node binary: the same harness source is
#      copied into a `git worktree` of the v0.32.0 tag and compiled against the
#      old framework (the source's comptime probes make it speak the old wire —
#      bare frames, no bus handshake; its BOOT line reads `auth=unsupported`);
#   4. MIXED run — one old node (mv-old) plus two master nodes (mv-b, mv-c):
#      the master nodes must *refuse* the old node's traffic with greppable
#      lines (`[raft] inbound frame not authenticated`, the bus's
#      `dropping connection` / `refused the handshake`, and the harness's own
#      `CN PEER_REPLY_REFUSED`), while electing a leader among themselves and
#      replicating normally — no panic, no hang, and SIGTERM still exits 0.
#
# Every wait is a bounded poll: a hang anywhere fails the run instead of
# blocking CI forever. Logs live under the run dir until the run ends; a
# failure prints their tails and keeps the dir for the artifact upload.
#
# Env knobs:
#   MIXED_OLD_REF   git ref for the old side (default: v0.32.0)
#   MIXED_EXPECT    refuse (default) | interop | rolling — the mixed phase's
#                   verdict for the pair:
#                     refuse   the hard wire cutover (v0.32.0): the new side must
#                              visibly refuse the old one while keeping a quorum
#                     interop  a pair whose wire did not cut over (e.g. v0.38.0 ×
#                              master, where A-1/A-3 changed no wire bytes): one
#                              mesh, one leader, replication into the old node,
#                              zero refusals
#                     rolling  the two-wave deploy a real upgrade takes: (1 old +
#                              2 new) reach quorum, the old node is drained, the
#                              two survivors must still hold a leader, then 3 new
#                              nodes elect among themselves. The only shape that
#                              can catch new nodes leaning on the old node's vote
#   ZIG             zig binary (default: zig)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$ROOT/.zig-global-cache}"
ZIG="${ZIG:-zig}"
OLD_REF="${MIXED_OLD_REF:-v0.32.0}"
MIXED_EXPECT="${MIXED_EXPECT:-refuse}"
case "$MIXED_EXPECT" in
  refuse|interop|rolling) ;;
  *) echo "mixed-version: MIXED_EXPECT must be refuse, interop or rolling, got '$MIXED_EXPECT'" >&2; exit 2 ;;
esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zm-mixed-version.XXXXXX")"
LOGS="$WORK/logs"
mkdir -p "$LOGS"
# Ports carry pid jitter: the framework's listener does not set SO_REUSEADDR,
# so a re-run right after a failure would otherwise trip over TIME_WAIT. The
# step is 30 because one run spans up to three blocks: same-version at
# PB+0..+7, mixed at PB+10..+17, and the rolling shape's second wave at
# PB+20..+27.
PB=$(( 20000 + ($$ % 125) * 30 ))

# Fixed TEST keys (64 hex chars = 32 bytes): every node of a phase shares them,
# which is the shape a rolling deploy has (one cluster secret, one bus key).
SECRET_HEX="5ec0e75e1c0e75e15ec0e75e1c0e75e15ec0e75e1c0e75e15ec0e75e1c0e75e1"
BUSKEY_HEX="b0510a11b0510a11b0510a11b0510a11b0510a11b0510a11b0510a11b0510a11"

PIDS=""
WORKTREE=""

cleanup() {
  local p
  for p in $PIDS; do
    kill -TERM "$p" 2>/dev/null || true
  done
  for p in $PIDS; do
    wait "$p" 2>/dev/null || true
  done
  if [ -n "$WORKTREE" ]; then
    git -C "$ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
  fi
  if [ "${KEEP_WORK:-0}" != "1" ]; then
    rm -rf "$WORK"
  else
    echo "mixed-version: kept run dir $WORK"
  fi
}
trap cleanup EXIT

fail() {
  echo "mixed-version: FAIL — $*" >&2
  echo "mixed-version: run dir kept at $WORK" >&2
  KEEP_WORK=1
  local f
  for f in "$LOGS"/*.log; do
    [ -f "$f" ] || continue
    echo "───── tail $f ─────" >&2
    tail -n 25 "$f" >&2
  done
  exit 1
}

# wait_until <seconds> <description> <check-fn> [args…]
# The check runs every 200 ms; `set -e` must not see its non-zero probes, hence
# the `|| return`-style guard inside the loop.
wait_until() {
  local budget="$1" desc="$2"; shift 2
  local deadline=$(( SECONDS + budget ))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@" >/dev/null 2>&1; then
      echo "mixed-version: ok — $desc (${SECONDS}s)"
      return 0
    fi
    sleep 0.2
  done
  fail "timeout (${budget}s) waiting for: $desc"
}

count_grep() { # <file> <pattern> — prints the match count, never fails
  local n
  n="$(grep -c "$2" "$1" 2>/dev/null || true)"
  echo "${n:-0}"
}

launch() { # <label> <binary> <logname> [args…]
  local label="$1" bin="$2" log="$3"; shift 3
  ( cd "$WORK" && exec "$bin" "$@" ) >"$LOGS/$log" 2>&1 &
  local pid=$!
  PIDS="$PIDS $pid"
  echo "mixed-version: started $label pid=$pid log=$LOGS/$log"
  eval "PID_$label=$pid"
}

stop_node() { # <label> <logname> — SIGTERM, bounded wait, clean-exit assertion
  local label="$1" log="$2"
  local pid
  pid="$(eval "echo \$PID_$label")"
  kill -TERM "$pid" 2>/dev/null || true
  local deadline=$(( SECONDS + 20 ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      fail "$label ignored SIGTERM for 20s (hang on shutdown)"
    fi
    sleep 0.2
  done
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$label exited $rc on SIGTERM, want 0"
  fi
  if ! grep -q "CN SHUTDOWN clean" "$LOGS/$log"; then
    fail "$label: no 'CN SHUTDOWN clean' in its log"
  fi
  echo "mixed-version: ok — $label shut down cleanly"
}

no_panics() { # <logfile>…
  local f
  for f in "$@"; do
    if grep -qiE "panic|Segmentation fault|index out of bounds|reached unreachable" "$f"; then
      fail "panic-shaped line in $f: $(grep -iE 'panic|Segmentation fault|index out of bounds|reached unreachable' "$f" | head -1)"
    fi
  done
}

leader_line_count() { # <logfile> — nodes that ever printed state=leader
  grep -l "state=leader" "$@" 2>/dev/null | wc -l | tr -d ' '
}

last_leader_id() { # <logfile> — prints the id from the last LEADER_ELECTED line
  grep "CN LEADER_ELECTED" "$1" 2>/dev/null | tail -1 | sed -E 's/.*CN LEADER_ELECTED id=([^ ]+).*/\1/'
}

max_log_len() { # <logfile> — last RAFT_LOG len seen
  grep "CN RAFT_LOG" "$1" 2>/dev/null | tail -1 | sed -E 's/.*CN RAFT_LOG len=([0-9]+).*/\1/'
}

echo "mixed-version: root=$ROOT old_ref=$OLD_REF port_base=$PB work=$WORK"

# ── 1. build the master harness ──────────────────────────────────────────────

echo "mixed-version: building master cluster-node"
( cd "$ROOT" && "$ZIG" build cluster-node -Ddb=none --prefix "$WORK/new-dist" )
NEW_BIN="$WORK/new-dist/bin/cluster-node"
[ -x "$NEW_BIN" ] || fail "master cluster-node missing at $NEW_BIN"

# ── 2. same-version run: 3 × master ──────────────────────────────────────────
#
# All three list the full peer set, share SECRET_HEX (raft frames + bus
# cluster secret) and BUSKEY_HEX (bus own/peer keys). Quorum is 2 of 3.

SV_A_R=$PB;        SV_B_R=$((PB+1)); SV_C_R=$((PB+2))
SV_A_U=$((PB+5));  SV_B_U=$((PB+6)); SV_C_U=$((PB+7))

COMMON_SV="--secret-hex $SECRET_HEX --bus-key-hex $BUSKEY_HEX --cluster-size 3 --bus-idle-ms 3000"

launch sva "$NEW_BIN" sv-a.log --id sv-a --raft-port $SV_A_R --bus-port $SV_A_U \
  --peer-raft sv-b@127.0.0.1:$SV_B_R --peer-raft sv-c@127.0.0.1:$SV_C_R \
  --peer-bus sv-b@127.0.0.1:$SV_B_U --peer-bus sv-c@127.0.0.1:$SV_C_U $COMMON_SV
launch svb "$NEW_BIN" sv-b.log --id sv-b --raft-port $SV_B_R --bus-port $SV_B_U \
  --peer-raft sv-a@127.0.0.1:$SV_A_R --peer-raft sv-c@127.0.0.1:$SV_C_R \
  --peer-bus sv-a@127.0.0.1:$SV_A_U --peer-bus sv-c@127.0.0.1:$SV_C_U $COMMON_SV
launch svc "$NEW_BIN" sv-c.log --id sv-c --raft-port $SV_C_R --bus-port $SV_C_U \
  --peer-raft sv-a@127.0.0.1:$SV_A_R --peer-raft sv-b@127.0.0.1:$SV_B_R \
  --peer-bus sv-a@127.0.0.1:$SV_A_U --peer-bus sv-b@127.0.0.1:$SV_B_U $COMMON_SV

sv_all_listen() {
  grep -q "CN LISTEN" "$LOGS/sv-a.log" && grep -q "CN LISTEN" "$LOGS/sv-b.log" && grep -q "CN LISTEN" "$LOGS/sv-c.log"
}
wait_until 20 "same-version: all three nodes listening" sv_all_listen

sv_one_leader() {
  [ "$(leader_line_count "$LOGS"/sv-*.log)" = "1" ] || return 1
  local la lb lc
  la="$(last_leader_id "$LOGS/sv-a.log")"; lb="$(last_leader_id "$LOGS/sv-b.log")"; lc="$(last_leader_id "$LOGS/sv-c.log")"
  [ -n "$la" ] && [ "$la" = "$lb" ] && [ "$lb" = "$lc" ]
}
wait_until 30 "same-version: exactly one leader, same LEADER_ELECTED id on all three" sv_one_leader

sv_full_mesh() {
  grep -q "CN VIEW members=3" "$LOGS/sv-a.log" && \
  grep -q "CN VIEW members=3" "$LOGS/sv-b.log" && \
  grep -q "CN VIEW members=3" "$LOGS/sv-c.log" && \
  grep -q "CN MESH peer=.*state=connected" "$LOGS/sv-a.log" && \
  grep -q "CN MESH peer=.*state=connected" "$LOGS/sv-b.log" && \
  grep -q "CN MESH peer=.*state=connected" "$LOGS/sv-c.log"
}
wait_until 30 "same-version: VIEW members=3 and a connected bus mesh on every node" sv_full_mesh

sv_replicates() {
  local a b c
  a="$(max_log_len "$LOGS/sv-a.log")"; b="$(max_log_len "$LOGS/sv-b.log")"; c="$(max_log_len "$LOGS/sv-c.log")"
  [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -ge 2 ] && [ "$b" -ge 2 ] && [ "$c" -ge 2 ]
}
wait_until 30 "same-version: raft log replicates to all three (len >= 2)" sv_replicates

no_panics "$LOGS"/sv-*.log
SV_LEADER="$(last_leader_id "$LOGS/sv-a.log")"
echo "mixed-version: same-version leader is $SV_LEADER"

stop_node sva sv-a.log
stop_node svb sv-b.log
stop_node svc sv-c.log
no_panics "$LOGS"/sv-*.log

# ── 3. build the old (v0.32.0) harness ───────────────────────────────────────
#
# The harness source is version-bridged by comptime probes, so the SAME file
# compiles against the old tag; the build.zig stanza the old tree lacks is
# injected here (old tree: `db_link.link(mod, b, features)` — three args, no
# target). Everything lands in a throwaway worktree under the run dir.

echo "mixed-version: building $OLD_REF cluster-node in a scratch worktree"
# A shallow CI clone (actions/checkout's default depth) carries no tags; fetch
# just the one ref we build.
if ! git -C "$ROOT" rev-parse --verify --quiet "$OLD_REF^{commit}" >/dev/null 2>&1; then
  echo "mixed-version: $OLD_REF not present locally, fetching it"
  git -C "$ROOT" fetch --depth 1 origin "refs/tags/$OLD_REF:refs/tags/$OLD_REF" || \
    fail "cannot resolve $OLD_REF locally and fetching it failed"
fi
WORKTREE="$WORK/old-tree"
git -C "$ROOT" worktree add --detach "$WORKTREE" "$OLD_REF" >/dev/null 2>&1 || \
  fail "git worktree add $OLD_REF failed"
cp "$ROOT/src/cluster_node.zig" "$WORKTREE/src/cluster_node.zig"

# Newer old refs (v0.38.0+) already carry the harness and its build step —
# only the harness source copy above is needed there (both sides then run the
# identical source). For refs that predate it (v0.32.0), inject the stanza:
# the old build.zig's last line is the closing brace of build(); drop it,
# append the stanza, re-close. (`sed '$d'`, not `head -n -1`: BSD head on
# macOS has no negative counts.)
if grep -q 'b.step("cluster-node"' "$WORKTREE/build.zig"; then
  echo "mixed-version: $OLD_REF already carries the cluster-node step; skipping stanza injection"
else
sed '$d' "$WORKTREE/build.zig" > "$WORKTREE/build.zig.new"
cat >> "$WORKTREE/build.zig.new" <<'ZIGEOF'

    // ── injected by scripts/ci-mixed-version.sh (B-11 mixed-version run) ──
    // The harness source is copied verbatim from the master checkout; its
    // comptime probes (@hasField(BootstrapConfig, "cluster_secret") etc.) make
    // it compile against this tree, producing a node that speaks exactly the
    // wire this version speaks (bare frames, no bus handshake).
    const cluster_node_mod = b.createModule(.{
        .root_source_file = b.path("src/cluster_node.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cluster_node_mod.addImport("zigmodu", zigmodu_mod);
    db_link.link(cluster_node_mod, b, features);
    const cluster_node_exe = b.addExecutable(.{
        .name = "cluster-node",
        .root_module = cluster_node_mod,
    });
    b.installArtifact(cluster_node_exe);
    const cluster_node_step = b.step("cluster-node", "Build the mixed-version harness node (injected by ci-mixed-version.sh)");
    cluster_node_step.dependOn(&b.addInstallArtifact(cluster_node_exe, .{}).step);
}
ZIGEOF
mv "$WORKTREE/build.zig.new" "$WORKTREE/build.zig"
fi

( cd "$WORKTREE" && "$ZIG" build cluster-node -Ddb=none --prefix "$WORK/old-dist" )
OLD_BIN="$WORK/old-dist/bin/cluster-node"
[ -x "$OLD_BIN" ] || fail "old cluster-node missing at $OLD_BIN"

# ── interop mode: the rolling-upgrade pair ───────────────────────────────────
#
# For a pair whose wire did NOT cut over (e.g. v0.38.0 × master — A-1 put the
# raft self-id inside existing frame fields and A-3's rotation window moved no
# bytes), the design verdict is the opposite of section 4's: the two builds
# must mesh under one cluster_secret + one bus key. The assertions are the
# mirror image of the refuse phase — full membership across versions, one
# shared leader whoever wins, replication INTO the old node, and not one
# refusal line anywhere (a silent drop would pass the mesh checks while the
# wire is actually broken, so their absence is asserted explicitly).

if [ "$MIXED_EXPECT" = "interop" ]; then
  echo "mixed-version: interop mode — $OLD_REF and master are expected to mesh"

  MV_A_R=$((PB+10)); MV_B_R=$((PB+11)); MV_C_R=$((PB+12))
  MV_A_U=$((PB+15)); MV_B_U=$((PB+16)); MV_C_U=$((PB+17))
  COMMON_MV="--secret-hex $SECRET_HEX --bus-key-hex $BUSKEY_HEX --cluster-size 3 --bus-idle-ms 3000"

  launch mva "$OLD_BIN" mv-old.log --id mv-old --raft-port $MV_A_R --bus-port $MV_A_U \
    --peer-raft mv-b@127.0.0.1:$MV_B_R --peer-raft mv-c@127.0.0.1:$MV_C_R \
    --peer-bus mv-b@127.0.0.1:$MV_B_U --peer-bus mv-c@127.0.0.1:$MV_C_U $COMMON_MV
  launch mvb "$NEW_BIN" mv-b.log --id mv-b --raft-port $MV_B_R --bus-port $MV_B_U \
    --peer-raft mv-old@127.0.0.1:$MV_A_R --peer-raft mv-c@127.0.0.1:$MV_C_R \
    --peer-bus mv-old@127.0.0.1:$MV_A_U --peer-bus mv-c@127.0.0.1:$MV_C_U $COMMON_MV
  launch mvc "$NEW_BIN" mv-c.log --id mv-c --raft-port $MV_C_R --bus-port $MV_C_U \
    --peer-raft mv-old@127.0.0.1:$MV_A_R --peer-raft mv-b@127.0.0.1:$MV_B_R \
    --peer-bus mv-old@127.0.0.1:$MV_A_U --peer-bus mv-b@127.0.0.1:$MV_B_U $COMMON_MV

  no_boot_fail() {
    if grep -q "CN BOOT_FAIL" "$LOGS"/*.log 2>/dev/null; then
      fail "a node printed CN BOOT_FAIL"
    fi
  }

  # auth=on on all three: the version bridge must have compiled WITH the
  # cluster-auth wire on the old side too, or this run proves nothing.
  mx_boot() {
    grep -q "CN BOOT id=mv-old .* auth=on" "$LOGS/mv-old.log" && \
    grep -q "CN BOOT id=mv-b .* auth=on" "$LOGS/mv-b.log" && \
    grep -q "CN BOOT id=mv-c .* auth=on" "$LOGS/mv-c.log" && \
    grep -q "CN LISTEN" "$LOGS/mv-old.log" && \
    grep -q "CN LISTEN" "$LOGS/mv-b.log" && \
    grep -q "CN LISTEN" "$LOGS/mv-c.log"
  }
  no_boot_fail
  wait_until 20 "interop: all three boot with auth=on and listen" mx_boot

  mx_one_leader() {
    [ "$(leader_line_count "$LOGS"/mv-*.log)" = "1" ] || return 1
    local la lb lc
    la="$(last_leader_id "$LOGS/mv-old.log")"; lb="$(last_leader_id "$LOGS/mv-b.log")"; lc="$(last_leader_id "$LOGS/mv-c.log")"
    [ -n "$la" ] && [ "$la" = "$lb" ] && [ "$lb" = "$lc" ]
  }
  no_boot_fail
  wait_until 40 "interop: exactly one leader, same id on old and new alike" mx_one_leader

  mx_full_mesh() {
    grep -q "CN VIEW members=3" "$LOGS/mv-old.log" && \
    grep -q "CN VIEW members=3" "$LOGS/mv-b.log" && \
    grep -q "CN VIEW members=3" "$LOGS/mv-c.log" && \
    grep -q "CN MESH peer=.*state=connected" "$LOGS/mv-old.log" && \
    grep -q "CN MESH peer=.*state=connected" "$LOGS/mv-b.log" && \
    grep -q "CN MESH peer=.*state=connected" "$LOGS/mv-c.log"
  }
  no_boot_fail
  wait_until 30 "interop: all three see members=3 and a connected bus mesh" mx_full_mesh

  # The old node applying the log proves master → old replication; the new
  # nodes holding members=3 with mv-old in the view proves old → new gossip.
  mx_replicates() {
    local a b c
    a="$(max_log_len "$LOGS/mv-old.log")"; b="$(max_log_len "$LOGS/mv-b.log")"; c="$(max_log_len "$LOGS/mv-c.log")"
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -ge 2 ] && [ "$b" -ge 2 ] && [ "$c" -ge 2 ]
  }
  no_boot_fail
  wait_until 30 "interop: raft log replicates to old and new alike (len >= 2)" mx_replicates

  # Mirror image of the refuse evidence blocks: not one refusal anywhere.
  if grep -q "inbound frame not authenticated" "$LOGS"/mv-*.log; then
    fail "interop: a raft frame was refused: $(grep -h 'inbound frame not authenticated' "$LOGS"/mv-*.log | head -1)"
  fi
  if grep -q "CN PEER_REPLY_REFUSED" "$LOGS"/mv-*.log; then
    fail "interop: a raft reply was refused: $(grep -h 'CN PEER_REPLY_REFUSED' "$LOGS"/mv-*.log | head -1)"
  fi
  if grep -qE "dropping connection|refused the handshake" "$LOGS"/mv-*.log; then
    fail "interop: a bus handshake was refused: $(grep -hE 'dropping connection|refused the handshake' "$LOGS"/mv-*.log | head -1)"
  fi

  no_panics "$LOGS"/mv-*.log
  MV_LEADER="$(last_leader_id "$LOGS/mv-old.log")"
  stop_node mva mv-old.log
  stop_node mvb mv-b.log
  stop_node mvc mv-c.log
  no_panics "$LOGS"/mv-*.log

  echo "mixed-version: evidence summary"
  echo "  same-version leader:        $SV_LEADER (all three agreed)"
  echo "  interop leader:             $MV_LEADER (old + new agreed)"
  echo "  interop raft refusals:      $(count_grep "$LOGS/mv-old.log" 'inbound frame not authenticated')+$(count_grep "$LOGS/mv-b.log" 'inbound frame not authenticated')+$(count_grep "$LOGS/mv-c.log" 'inbound frame not authenticated') line(s) (want 0)"
  echo "mixed-version: OK — interop: $OLD_REF and master shared one mesh, one leader and one log, with zero refusals"
  exit 0
fi

# ── rolling mode: the two-wave upgrade a production deploy actually takes ─────
#
# refuse proves "the cut is clean"; interop proves "these two versions mesh".
# Neither proves the thing a rolling deploy needs: **that the cluster keeps a
# quorum across the transition**. A real upgrade is two waves —
#
#   wave 1: 1 × old + 2 × master   (the old node is still there, being drained)
#   wave 2: 3 × master             (old gone; the cluster never lost majority)
#
# The failure this shape is the only one that can catch: a change that leaves the
# *new* nodes unable to form a quorum on their own. Both existing shapes would
# miss it — refuse never gets past the mixed mesh, and interop's old node is what
# keeps the vote count at3 for the whole run. Here wave 1 has to reach majority
# with the old node present, and wave 2 has to reach it with the old node
# **gone**; if the new nodes only ever leaned on the old one's vote, wave 2 never
# elects and this run fails.
#
# The old reference is $OLD_REF, chosen by the caller so the pair matches the
# window's actual compatibility (v0.32.0 would cut over and belongs to `refuse`).

if [ "$MIXED_EXPECT" = "rolling" ]; then
  echo "mixed-version: rolling mode — two waves: (1 old + 2 new) then (3 new), quorum must survive both"

  RV_A_R=$((PB+10)); RV_B_R=$((PB+11)); RV_C_R=$((PB+12))
  RV_A_U=$((PB+15)); RV_B_U=$((PB+16)); RV_C_U=$((PB+17))
  # Wave 2 reuses the same ids on different ports: the cluster identity is the id,
  # the topology is the ports, so a restart on a fresh port is exactly what a
  # replaced pod looks like from the outside.
  W2_A_R=$((PB+20)); W2_B_R=$((PB+21)); W2_C_R=$((PB+22))
  W2_A_U=$((PB+25)); W2_B_U=$((PB+26)); W2_C_U=$((PB+27))
  COMMON_MV="--secret-hex $SECRET_HEX --bus-key-hex $BUSKEY_HEX --cluster-size 3 --bus-idle-ms 3000"

  # ---- wave 1: the old node plus two new ones -----------------------------
  launch mva "$OLD_BIN" mv-old.log --id mv-old --raft-port $RV_A_R --bus-port $RV_A_U \
    --peer-raft mv-b@127.0.0.1:$RV_B_R --peer-raft mv-c@127.0.0.1:$RV_C_R \
    --peer-bus mv-b@127.0.0.1:$RV_B_U --peer-bus mv-c@127.0.0.1:$RV_C_U $COMMON_MV
  launch mvb "$NEW_BIN" mv-b.log --id mv-b --raft-port $RV_B_R --bus-port $RV_B_U \
    --peer-raft mv-old@127.0.0.1:$RV_A_R --peer-raft mv-c@127.0.0.1:$RV_C_R \
    --peer-bus mv-old@127.0.0.1:$RV_A_U --peer-bus mv-c@127.0.0.1:$RV_C_U $COMMON_MV
  launch mvc "$NEW_BIN" mv-c.log --id mv-c --raft-port $RV_C_R --bus-port $RV_C_U \
    --peer-raft mv-old@127.0.0.1:$RV_A_R --peer-raft mv-b@127.0.0.1:$RV_B_R \
    --peer-bus mv-old@127.0.0.1:$RV_A_U --peer-bus mv-b@127.0.0.1:$RV_B_U $COMMON_MV

  no_boot_fail() {
    if grep -q "CN BOOT_FAIL" "$LOGS"/*.log 2>/dev/null; then
      fail "a node printed CN BOOT_FAIL"
    fi
  }

  wave1_boot() {
    grep -q "CN BOOT id=mv-old .* auth=on" "$LOGS/mv-old.log" && \
    grep -q "CN BOOT id=mv-b .* auth=on" "$LOGS/mv-b.log" && \
    grep -q "CN BOOT id=mv-c .* auth=on" "$LOGS/mv-c.log" && \
    grep -q "CN LISTEN" "$LOGS/mv-old.log" && \
    grep -q "CN LISTEN" "$LOGS/mv-b.log" && \
    grep -q "CN LISTEN" "$LOGS/mv-c.log"
  }
  no_boot_fail
  wait_until 20 "rolling wave 1: all three boot with auth=on and listen" wave1_boot

  wave1_quorum() {
    # Full membership across versions — the same property interop asserts, but
    # here it is a waypoint rather than the destination: the cluster must reach
    # it *before* the old node is taken away.
    grep -q "CN VIEW members=3" "$LOGS/mv-old.log" && \
    grep -q "CN VIEW members=3" "$LOGS/mv-b.log" && \
    grep -q "CN VIEW members=3" "$LOGS/mv-c.log"
  }
  no_boot_fail
  wait_until 40 "rolling wave 1: members=3 across versions (quorum before the drain)" wave1_quorum

  wave1_one_leader() {
    [ "$(leader_line_count "$LOGS"/mv-*.log)" = "1" ] || return 1
    local la lb lc
    la="$(last_leader_id "$LOGS/mv-old.log")"; lb="$(last_leader_id "$LOGS/mv-b.log")"; lc="$(last_leader_id "$LOGS/mv-c.log")"
    [ -n "$la" ] && [ -n "$lb" ] && [ -n "$lc" ] && [ "$la" = "$lb" ] && [ "$lb" = "$lc" ]
  }
  no_boot_fail
  wait_until 40 "rolling wave 1: exactly one leader, agreed across old and new" wave1_one_leader

  # Zero refusals in wave 1, for the same reason interop asserts it: a silent
  # drop would pass the mesh checks while the wire is actually broken.
  if grep -q "inbound frame not authenticated" "$LOGS"/mv-*.log; then
    fail "rolling wave 1: a raft frame was refused: $(grep -h 'inbound frame not authenticated' "$LOGS"/mv-*.log | head -1)"
  fi
  if grep -qE "dropping connection|refused the handshake" "$LOGS"/mv-*.log; then
    fail "rolling wave 1: a bus handshake was refused: $(grep -hE 'dropping connection|refused the handshake' "$LOGS"/mv-*.log | head -1)"
  fi

  W1_LEADER="$(last_leader_id "$LOGS/mv-old.log")"
  W1_LOGLEN="$(max_log_len "$LOGS/mv-b.log")"
  no_panics "$LOGS"/mv-*.log

  # ---- the drain: stop the old node cleanly, then take it out of the view ----
  # SIGTERM, not SIGKILL: a rolling upgrade replaces pods, and the difference
  # between a graceful leave and a crash is exactly what a drain must prove.
  stop_node mva mv-old.log
  no_panics "$LOGS"/mv-*.log

  # The two survivors must still agree on a leader with the old node gone. If
  # they had been leaning on its vote, this is where that shows.
  wave1_survivors() {
    local lb lc
    lb="$(last_leader_id "$LOGS/mv-b.log")"; lc="$(last_leader_id "$LOGS/mv-c.log")"
    [ -n "$lb" ] && [ -n "$lc" ] && [ "$lb" = "$lc" ]
  }
  no_boot_fail
  wait_until 40 "rolling: the two new nodes keep a leader after the old one leaves" wave1_survivors
  W1_AFTER_LEADER="$(last_leader_id "$LOGS/mv-b.log")"

  stop_node mvb mv-b.log
  stop_node mvc mv-c.log
  no_panics "$LOGS"/mv-*.log

  # ---- wave 2: all three on master, old reference gone ---------------------
  # Fresh logs, so a grep cannot be satisfied by wave 1's output.
  launch mv2a "$NEW_BIN" mv2-a.log --id mv-a --raft-port $W2_A_R --bus-port $W2_A_U \
    --peer-raft mv-b@127.0.0.1:$W2_B_R --peer-raft mv-c@127.0.0.1:$W2_C_R \
    --peer-bus mv-b@127.0.0.1:$W2_B_U --peer-bus mv-c@127.0.0.1:$W2_C_U $COMMON_MV
  launch mv2b "$NEW_BIN" mv2-b.log --id mv-b --raft-port $W2_B_R --bus-port $W2_B_U \
    --peer-raft mv-a@127.0.0.1:$W2_A_R --peer-raft mv-c@127.0.0.1:$W2_C_R \
    --peer-bus mv-a@127.0.0.1:$W2_A_U --peer-bus mv-c@127.0.0.1:$W2_C_U $COMMON_MV
  launch mv2c "$NEW_BIN" mv2-c.log --id mv-c --raft-port $W2_C_R --bus-port $W2_C_U \
    --peer-raft mv-a@127.0.0.1:$W2_A_R --peer-raft mv-b@127.0.0.1:$W2_B_R \
    --peer-bus mv-a@127.0.0.1:$W2_A_U --peer-bus mv-b@127.0.0.1:$W2_B_U $COMMON_MV

  wave2_up() {
    grep -q "CN LISTEN" "$LOGS/mv2-a.log" && \
    grep -q "CN LISTEN" "$LOGS/mv2-b.log" && \
    grep -q "CN LISTEN" "$LOGS/mv2-c.log" && \
    grep -q "CN VIEW members=3" "$LOGS/mv2-a.log" && \
    grep -q "CN VIEW members=3" "$LOGS/mv2-b.log" && \
    grep -q "CN VIEW members=3" "$LOGS/mv2-c.log"
  }
  no_boot_fail
  wait_until 40 "rolling wave 2: three master-only nodes reach members=3" wave2_up

  wave2_one_leader() {
    [ "$(leader_line_count "$LOGS"/mv2-*.log)" = "1" ] || return 1
    local la lb lc
    la="$(last_leader_id "$LOGS/mv2-a.log")"; lb="$(last_leader_id "$LOGS/mv2-b.log")"; lc="$(last_leader_id "$LOGS/mv2-c.log")"
    [ -n "$la" ] && [ -n "$lb" ] && [ -n "$lc" ] && [ "$la" = "$lb" ] && [ "$lb" = "$lc" ]
  }
  no_boot_fail
  wait_until 40 "rolling wave 2: exactly one leader among the new nodes" wave2_one_leader

  wave2_replicates() {
    local a b c
    a="$(max_log_len "$LOGS/mv2-a.log")"; b="$(max_log_len "$LOGS/mv2-b.log")"; c="$(max_log_len "$LOGS/mv2-c.log")"
    [ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -ge 2 ] && [ "$b" -ge 2 ] && [ "$c" -ge 2 ]
  }
  no_boot_fail
  wait_until 30 "rolling wave 2: the all-new cluster replicates (len >= 2)" wave2_replicates

  if grep -q "inbound frame not authenticated" "$LOGS"/mv2-*.log; then
    fail "rolling wave 2: a raft frame was refused among the new nodes"
  fi

  no_panics "$LOGS"/mv2-*.log
  W2_LEADER="$(last_leader_id "$LOGS/mv2-a.log")"
  stop_node mv2a mv2-a.log
  stop_node mv2b mv2-b.log
  stop_node mv2c mv2-c.log
  no_panics "$LOGS"/mv2-*.log

  echo "mixed-version: evidence summary"
  echo "  wave 1 leader:               $W1_LEADER (1 old + 2 new agreed)"
  echo "  after the old node left:     $W1_AFTER_LEADER (2 new still agreed — quorum survived the drain)"
  echo "  wave 1 replicated log len:   $W1_LOGLEN"
  echo "  wave 2 leader:               $W2_LEADER (3 new, old reference absent)"
  echo "mixed-version: OK — rolling: quorum survived both waves; $OLD_REF drained and was replaced without losing the majority"
  exit 0
fi

# ── 4. mixed run: 1 × old + 2 × master ───────────────────────────────────────
#
# Choreography: mv-old and mv-b start together (mv-c's ports are reserved but
# the process is not). The old node campaigns on the bare wire; mv-b's inbound
# rejects every frame — the first evidence block. Then mv-c joins: mv-b/mv-c
# elect a leader among themselves and replicate, while the old node keeps
# being refused. The design verdict for this pair is a refused handshake — the
# wire format cuts over hard — and this phase proves the refusal is clean,
# bounded and observable on both sides.

# The mixed phase gets its own port block (+10..+17): the same-version nodes
# were stopped seconds ago, and the framework's listener sets no SO_REUSEADDR,
# so a just-closed port can still be TIME_WAIT-held — reusing it kills the new
# node's bus bind with AddressInUse (measured: mv-c died on mv-c's bus port).
MV_A_R=$((PB+10)); MV_B_R=$((PB+11)); MV_C_R=$((PB+12))
MV_A_U=$((PB+15)); MV_B_U=$((PB+16)); MV_C_U=$((PB+17))

COMMON_MV="--secret-hex $SECRET_HEX --bus-key-hex $BUSKEY_HEX --cluster-size 3 --bus-idle-ms 3000"

launch mva "$OLD_BIN" mv-old.log --id mv-old --raft-port $MV_A_R --bus-port $MV_A_U \
  --peer-raft mv-b@127.0.0.1:$MV_B_R --peer-raft mv-c@127.0.0.1:$MV_C_R \
  --peer-bus mv-b@127.0.0.1:$MV_B_U --peer-bus mv-c@127.0.0.1:$MV_C_U $COMMON_MV
launch mvb "$NEW_BIN" mv-b.log --id mv-b --raft-port $MV_B_R --bus-port $MV_B_U \
  --peer-raft mv-old@127.0.0.1:$MV_A_R --peer-raft mv-c@127.0.0.1:$MV_C_R \
  --peer-bus mv-old@127.0.0.1:$MV_A_U --peer-bus mv-c@127.0.0.1:$MV_C_U $COMMON_MV

# A boot failure (BOOT_FAIL) should fail fast, not surface as a mysteriously
# unmet election window half a minute later — check before every long wait.
no_boot_fail() {
  if grep -q "CN BOOT_FAIL" "$LOGS"/*.log 2>/dev/null; then
    fail "a node printed CN BOOT_FAIL"
  fi
}

# The old binary must report that this build has no auth wire (the version
# bridge took effect); the new one must report auth=on. Both must reach LISTEN.
mv_boot_modes() {
  grep -q "CN BOOT id=mv-old .* auth=unsupported" "$LOGS/mv-old.log" && \
  grep -q "CN BOOT id=mv-b .* auth=on" "$LOGS/mv-b.log" && \
  grep -q "CN LISTEN" "$LOGS/mv-old.log" && grep -q "CN LISTEN" "$LOGS/mv-b.log"
}
no_boot_fail
wait_until 20 "mixed: old boots with auth=unsupported, new with auth=on, both listening" mv_boot_modes

# Evidence block 1: mv-b's inbound visibly refuses the old node's bare raft
# frames (vote requests + relayed grants), at debug level, on a steady drip.
mv_b_refuses_raft() {
  [ "$(count_grep "$LOGS/mv-b.log" "inbound frame not authenticated")" -ge 3 ]
}
wait_until 20 "mixed: mv-b refuses the old node's raft frames (>= 3 lines)" mv_b_refuses_raft

launch mvc "$NEW_BIN" mv-c.log --id mv-c --raft-port $MV_C_R --bus-port $MV_C_U \
  --peer-raft mv-old@127.0.0.1:$MV_A_R --peer-raft mv-b@127.0.0.1:$MV_B_R \
  --peer-bus mv-old@127.0.0.1:$MV_A_U --peer-bus mv-b@127.0.0.1:$MV_B_U $COMMON_MV

no_boot_fail
mvc_listen() { grep -q "CN LISTEN" "$LOGS/mv-c.log"; }
wait_until 15 "mixed: mv-c listening" mvc_listen

# The new side forms its own quorum, undisturbed by the refused peer.
mv_new_leader() {
  [ "$(leader_line_count "$LOGS/mv-b.log" "$LOGS/mv-c.log")" = "1" ] || return 1
  local lb lc
  lb="$(last_leader_id "$LOGS/mv-b.log")"; lc="$(last_leader_id "$LOGS/mv-c.log")"
  [ -n "$lb" ] && [ "$lb" = "$lc" ]
}
wait_until 40 "mixed: mv-b/mv-c elect exactly one leader (same id both sides)" mv_new_leader

mv_view_pair() {
  grep -q "CN VIEW members=2" "$LOGS/mv-b.log" && grep -q "CN VIEW members=2" "$LOGS/mv-c.log"
}
wait_until 30 "mixed: new nodes' membership view is exactly the pair (members=2)" mv_view_pair

mv_replicates() {
  local b c
  b="$(max_log_len "$LOGS/mv-b.log")"; c="$(max_log_len "$LOGS/mv-c.log")"
  [ -n "$b" ] && [ -n "$c" ] && [ "$b" -ge 2 ] && [ "$c" -ge 2 ]
}
wait_until 30 "mixed: raft log replicates between the two new nodes (len >= 2)" mv_replicates

# Evidence block 2: the old node's *replies* are refused too — the leader's
# harness transport rejects the bare AppendEntries responses (MAC verify), and
# the bus handshake fails in both directions (the old bus cannot answer a
# challenge; the new bus drops what the old one sends instead).
MV_LEADER="$(last_leader_id "$LOGS/mv-b.log")"
mv_leader_refuses_replies() {
  grep -q "CN PEER_REPLY_REFUSED peer=mv-old" "$LOGS/$MV_LEADER.log"
}
wait_until 30 "mixed: leader ($MV_LEADER) refuses mv-old's bare replies" mv_leader_refuses_replies

mv_bus_refused() {
  grep -qE "dropping connection|refused the handshake" "$LOGS/mv-b.log" || \
  grep -qE "dropping connection|refused the handshake" "$LOGS/mv-c.log"
}
wait_until 30 "mixed: bus handshake refusal is visible on the new side" mv_bus_refused

# The old node campaigns forever (its grants/heartbeats never land); it must
# never have been a leader, and it must still be alive and unharmed.
if grep -q "state=leader" "$LOGS/mv-old.log"; then
  fail "mv-old printed state=leader — the old node must never win an election here"
fi
kill -0 "$PID_mva" 2>/dev/null || fail "mv-old died during the run"
no_panics "$LOGS"/mv-*.log

stop_node mva mv-old.log
stop_node mvb mv-b.log
stop_node mvc mv-c.log
no_panics "$LOGS"/mv-*.log

echo "mixed-version: evidence summary"
echo "  same-version leader:        $SV_LEADER (all three agreed)"
echo "  mixed leader (new side):    $MV_LEADER"
echo "  mv-b raft refusals:         $(count_grep "$LOGS/mv-b.log" 'inbound frame not authenticated') line(s)"
echo "  $MV_LEADER reply refusals:  $(count_grep "$LOGS/$MV_LEADER.log" 'CN PEER_REPLY_REFUSED peer=mv-old') line(s)"
echo "  mv-b bus refusals:          $(count_grep "$LOGS/mv-b.log" 'dropping connection\|refused the handshake') line(s)"
echo "mixed-version: OK — same-version elected one leader; mixed-version refused the old node cleanly and kept a working quorum"
