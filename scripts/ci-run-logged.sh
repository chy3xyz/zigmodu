#!/usr/bin/env bash
# Run a command with its output captured to a file, then echo the file and exit
# with the command's own status.
#
#   bash scripts/ci-run-logged.sh "$RUNNER_TEMP/test-output.log" zig build test
#
# `cmd 2>&1 | tee log` looks equivalent and is not. When the command leaves an
# orphan child holding stdout open — Zig's build runner does exactly that when a
# step fails — `tee` never sees EOF, so the *step* hangs until the job timeout
# instead of reporting the failure. Measured on run 35572370114: a compile error
# inside `zig build test` became a 25-minute stall with the error already printed
# 20 minutes earlier.
#
# The file is written by the shell's redirection, so it holds whatever the
# command managed to print even if the command is later killed — which is what
# makes the failure artifact useful.

set -o pipefail

if [ "$#" -lt 2 ]; then
    echo "usage: $0 <log-file> <command> [args...]" >&2
    exit 2
fi

log="$1"
shift

set +e
"$@" >"$log" 2>&1
rc=$?
set -e

cat "$log"
exit "$rc"
