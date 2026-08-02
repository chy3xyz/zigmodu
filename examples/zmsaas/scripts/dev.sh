#!/usr/bin/env bash
# zmsaas dual-process dev: zigmodu backend + SolidStart frontend.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== zmsaas backend (http://127.0.0.1:18080) =="
(cd backend && zig build run) &
BACK_PID=$!

echo "== zmsaas frontend (http://localhost:3000) =="
(cd frontend && npm install && PUBLIC_ZMODU_API_URL=http://127.0.0.1:18080 npm run dev) &
FRONT_PID=$!

trap 'kill "$BACK_PID" "$FRONT_PID" 2>/dev/null || true' EXIT
wait
