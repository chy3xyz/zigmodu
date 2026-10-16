#!/usr/bin/env bash
# Run `zig build test` under a hang watchdog, with a standalone-binary
# fallback when the build runner's listen protocol stalls.
#
# Why this exists: on some macOS hosts (observed on macOS 27 with the Zig
# 0.17.0 release toolchain, under multi-project CPU load) the build runner
# deadlocks while orchestrating test binaries over `--listen=-` — maker sits
# at 0% CPU in a futex wait while the freshly spawned test binary waits
# forever on stdin for a run message that never arrives. `-j1` does not
# prevent it; the same binary always passes when executed directly. The flake
# cost hours of release time, so the suite entry points now run through this
# guard: a hang is detected, the runner tree is killed, every test binary
# compiled during the attempt is executed standalone (no listen protocol),
# and the verdict comes from those runs.
#
# Usage:
#   bash scripts/zig-build-test-guarded.sh [guard options] [zig args...]
#
# Guard options:
#   --timeout SECS   watchdog budget for the `zig` invocation (default 900)
#   --dir PATH       working directory for the zig invocation (default: cwd);
#                    also searched for freshly compiled test binaries
#   --pass-on-fallback  exit 0 (instead of 75) when the watchdog fallback
#                    passes — for CI steps that only need a boolean verdict
#                    and stream the log (75 stays the default so interactive
#                    callers can tell the two greens apart)
#
# Everything after the guard options is passed verbatim to `zig` — e.g.
#   bash scripts/zig-build-test-guarded.sh build test --summary all -Ddb=all
#
# Exit codes:
#    0 — `zig build test` finished in time and passed
#    1 — failed (either zig itself, or a fallback standalone run)
#   75 — the watchdog fired and the standalone fallback passed (the streamed
#        log carries a loud `zm-test-guard:` banner; callers that need to
#        distinguish "green the normal way" from "green via fallback" can
#        test for this)
#
# Fallback verdicts are aggregated from the standalone binaries' exit codes,
# cross-checked against their "N passed; M skipped; K failed." summaries.
# Only binaries compiled within the last 90 minutes are considered — stale
# cache entries from older code are never re-run. A binary that hangs
# standalone (per-binary timeout) is a REAL product hang and fails the run.
set -uo pipefail

TIMEOUT=900
RUN_DIR="$PWD"
PASS_ON_FALLBACK=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      [[ $# -ge 2 ]] || { echo "zig-build-test-guarded: --timeout needs a value" >&2; exit 64; }
      TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#--timeout=}"; shift ;;
    --dir)
      [[ $# -ge 2 ]] || { echo "zig-build-test-guarded: --dir needs a value" >&2; exit 64; }
      RUN_DIR="$2"; shift 2 ;;
    --dir=*) RUN_DIR="${1#--dir=}"; shift ;;
    --pass-on-fallback) PASS_ON_FALLBACK=1; shift ;;
    -h|--help) sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS=("$@"); break ;;
  esac
done

[[ ${#ARGS[@]} -gt 0 ]] || { echo "zig-build-test-guarded: no zig arguments given" >&2; exit 64; }

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG="$(mktemp -t zm-guard.XXXXXX)"

echo "zig-build-test-guarded: zig ${ARGS[*]} (timeout ${TIMEOUT}s, dir ${RUN_DIR})"

# `set -m` gives the background zig job its own process group, so the
# watchdog can kill the whole runner tree (maker + test binaries) at once.
set -m
: >"$LOG"
tail -f "$LOG" 2>/dev/null & TAIL_PID=$!
cd "$RUN_DIR"
START=$SECONDS
zig "${ARGS[@]}" >>"$LOG" 2>&1 &
ZPID=$!
HUNG=0
while :; do
  if ! kill -0 "$ZPID" 2>/dev/null; then break; fi
  if (( SECONDS - START > TIMEOUT )); then HUNG=1; break; fi
  sleep 5
done

if (( HUNG == 0 )); then
  wait "$ZPID"; STATUS=$?
  kill "$TAIL_PID" 2>/dev/null
  exit "$STATUS"
fi

# ── watchdog fired ────────────────────────────────────────────────────────────
kill -- "-$ZPID" 2>/dev/null || kill "$ZPID" 2>/dev/null
sleep 2
# Sweep any orphaned test binaries whose cwd is this repo (the group kill
# normally gets them; orphans only appear when zig re-parented something).
while IFS= read -r p; do
  cwd="$(lsof -a -p "$p" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  [[ "$cwd" == "$REPO_ROOT"* ]] && kill "$p" 2>/dev/null
done < <(pgrep -f "/test --cache-dir" || true)

{
  echo ""
  echo "zm-test-guard: WATCHDOG FIRED after $((SECONDS - START))s — the build runner"
  echo "zm-test-guard: stalled on this host (known Zig 0.17.0 macOS listen flake)."
  echo "zm-test-guard: killing the runner tree and re-executing the freshly compiled"
  echo "zm-test-guard: test binaries standalone (no --listen protocol)."
} >>"$LOG"
echo "zig-build-test-guarded: watchdog fired after $((SECONDS - START))s — falling back to standalone test binaries" >&2

# ── standalone fallback ───────────────────────────────────────────────────────
CANDIDATE_DIRS=("$REPO_ROOT/.zig-cache/o" "$REPO_ROOT/tools/zmodu/.zig-cache/o")
[[ "$RUN_DIR" != "$REPO_ROOT" && "$RUN_DIR" != "$PWD" ]] && CANDIDATE_DIRS+=("$RUN_DIR/.zig-cache/o")

PASS_TOTAL=0
SKIP_TOTAL=0
FAIL_TOTAL=0
BIN_COUNT=0
FALLBACK_OK=1

while IFS= read -r bin; do
  [[ -n "$bin" && -x "$bin" ]] || continue
  # Skip hardlinked duplicates (zig cache hardlinks the same inode).
  inode="$(ls -i "$bin" | awk '{print $1}')"
  for seen in ${INODES:-}; do [[ "$seen" == "$inode" ]] && continue 2; done
  INODES="${INODES:-} $inode"

  BIN_COUNT=$((BIN_COUNT + 1))
  NAME="${bin#*/o/}"; NAME="${NAME%%/*}"
  BLOG="$(mktemp -t zm-guard-bin.XXXXXX)"
  echo "zm-test-guard: standalone ${NAME} ..." >>"$LOG"
  BSTART=$SECONDS
  # `exec` keeps the subshell pid == binary pid so the 600s timeout kill
  # below reaches the test binary itself, not an orphaned wrapper.
  ( cd "$REPO_ROOT" && exec "$bin" --cache-dir="$REPO_ROOT/.zig-cache" --seed=0x1 >"$BLOG" 2>&1 ) &
 BPID=$!
  BKILLED=0
  while kill -0 "$BPID" 2>/dev/null; do
    if (( SECONDS - BSTART > 600 )); then BKILLED=1; break; fi
    sleep 5
  done
  if (( BKILLED == 1 )); then
    kill "$BPID" 2>/dev/null
    echo "zm-test-guard: standalone ${NAME}: HUNG past 600s — real product hang, counting as failure" >>"$LOG"
    FAIL_TOTAL=$((FAIL_TOTAL + 1))
    FALLBACK_OK=0
    continue
  fi
  wait "$BPID"; BSTATUS=$?
  # Verdict comes from the exit code; the summary line only feeds the counts.
  # Two runner formats exist in this repo's artifacts: the custom
  # scripts/test-runner.zig ("N passed; M skipped; K failed.") and zig's
  # default runner ("All N tests passed."). An exit-0 binary whose summary
  # matches neither still counts as a pass — with its counts left out.
  summary="$(grep -E '[0-9]+ passed; [0-9]+ skipped; [0-9]+ failed|All [0-9]+ tests passed' "$BLOG" | tail -1 || true)"
  if [[ "$BSTATUS" -ne 0 ]]; then
    echo "zm-test-guard: standalone ${NAME}: FAILED (exit $BSTATUS)" >>"$LOG"
    tail -5 "$BLOG" >>"$LOG" 2>/dev/null || true
    FAIL_TOTAL=$((FAIL_TOTAL + 1))
    FALLBACK_OK=0
    rm -f "$BLOG"
    continue
  fi
  if [[ -z "$summary" ]]; then
    echo "zm-test-guard: standalone ${NAME}: OK (exit 0; summary not parseable — counts excluded)" >>"$LOG"
    rm -f "$BLOG"
    continue
  fi
  if [[ "$summary" == All\ * ]]; then
    p="$(printf '%s' "$summary" | sed -n 's/All \([0-9][0-9]*\) tests passed.*/\1 0 0/p')"
  else
    # Strip any leading non-digits first: bare summaries start at column 0
    # ("2254 passed; ..."), server-mode rows carry a prefix — one pattern
    # must parse both.
    p="$(printf '%s' "$summary" | sed 's/^[^0-9]*//' | sed -n 's/\([0-9][0-9]*\) passed; \([0-9][0-9]*\) skipped; \([0-9][0-9]*\) failed.*/\1 \2 \3/p')"
  fi
  read -r passed skipped failed <<<"${p:-0 0 0}"
  PASS_TOTAL=$((PASS_TOTAL + ${passed:-0}))
  SKIP_TOTAL=$((SKIP_TOTAL + ${skipped:-0}))
  FAIL_TOTAL=$((FAIL_TOTAL + ${failed:-0}))
  # Synthetic per-binary row in the zm-test-runner summary shape so downstream
  # parsers (scripts/test-fast.sh) can aggregate fallback runs unchanged.
  echo "zm-test-runner: selected $(( ${passed:-0} + ${skipped:-0} + ${failed:-0} )) of $(( ${passed:-0} + ${skipped:-0} + ${failed:-0} )) tests (${NAME}): ${passed:-0} passed; ${skipped:-0} skipped; ${failed:-0} failed; 0 leaked." >>"$LOG"
  echo "zm-test-guard: standalone ${NAME}: ${passed:-0} passed; ${skipped:-0} skipped; ${failed:-0} failed (${BSTATUS})" >>"$LOG"
  rm -f "$BLOG"
done < <(find "${CANDIDATE_DIRS[@]}" -maxdepth 2 -type f -name test -mmin -90 2>/dev/null | sort -r)

if (( BIN_COUNT == 0 )); then
  echo "zm-test-guard: FALLBACK COULD NOT RUN — no test binaries newer than 90m under .zig-cache/o" >>"$LOG"
  echo "zig-build-test-guarded: fallback found no fresh test binaries — cannot verify" >&2
  kill "$TAIL_PID" 2>/dev/null
  exit 1
fi

{
  echo "zm-test-guard: fallback complete — $BIN_COUNT binaries, $PASS_TOTAL passed; $SKIP_TOTAL skipped; $FAIL_TOTAL failed."
} >>"$LOG"
kill "$TAIL_PID" 2>/dev/null

if (( FALLBACK_OK == 1 && FAIL_TOTAL == 0 )); then
  echo "zig-build-test-guarded: fallback PASS ($PASS_TOTAL passed; $SKIP_TOTAL skipped across $BIN_COUNT binaries)" >&2
  if (( PASS_ON_FALLBACK == 1 )); then exit 0; fi
  exit 75
fi
echo "zig-build-test-guarded: fallback FAIL ($FAIL_TOTAL failures across $BIN_COUNT binaries)" >&2
exit 1
