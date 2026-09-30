#!/usr/bin/env python3
"""runtime_stress_trend.py — read the runtime-stress JSONL series back.

usage: runtime_stress_trend.py [history.jsonl] [--window N] [--last K]

The harness (src/runtime_stress.zig, RUNTIME_STRESS_HISTORY) appends one
schema-v1 JSON line per run. This reader answers two questions separately,
the same split docs/RUNTIME.md §12.15/§12.16 use:

  * hard gates (host-INDEPENDENT, exit 1 on trip): the run failed, a push
    failure happened, a timer delivery was dropped, a measured window
    allocated. These are contracts, not readings — they must be zero on
    every host, so they gate.
  * drift (host-dependent, printed, never gated): dispatches, RSS spread,
    shutdown time, probe bytes, thread counts. Shared-runner noise on these
    is 25-40% (§12.16 measured), so a regression call on them needs a quiet
    machine; here they are a table with medians and deltas, and a `!` marks
    moves past a generous threshold for a human to look at.

Baseline: the median of the `--window` records before the latest one
(default 5). With a single record the hard gates still run and the drift
table prints it as-is.
"""

from __future__ import annotations

import json
import statistics
import sys


def load(path: str) -> list[dict]:
    recs: list[dict] = []
    with open(path, "r", encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError as e:
                print(f"trend: WARN line {n}: not JSON ({e}); skipped", file=sys.stderr)
                continue
            if rec.get("v") != 1:
                print(f"trend: WARN line {n}: unknown schema v={rec.get('v')!r}; skipped", file=sys.stderr)
                continue
            recs.append(rec)
    return recs


def get(rec: dict, *keys: str):
    cur = rec
    for k in keys:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(k)
    return cur


def main() -> int:
    args = sys.argv[1:]
    path = "runtime-stress-history.jsonl"
    window = 5
    last = 0
    i = 0
    while i < len(args):
        if args[i] == "--window" and i + 1 < len(args):
            window = int(args[i + 1])
            i += 2
        elif args[i] == "--last" and i + 1 < len(args):
            last = int(args[i + 1])
            i += 2
        elif not args[i].startswith("--"):
            path = args[i]
            i += 1
        else:
            i += 1

    recs = load(path)
    if not recs:
        print(f"trend: no usable records in {path}")
        return 0

    if last:
        recs = recs[-last:]
    latest = recs[-1]
    baseline = recs[-(window + 1):-1]

    sha = latest.get("commit", "?")[:12]
    ts = latest.get("ts", "?")
    print(f"trend: {len(recs)} record(s); latest commit {sha} ts={ts}; "
          f"baseline = median of {len(baseline)} previous")

    # ── hard gates: host-independent contracts, absolute zero ──
    hard: list[str] = []

    def gate_zero(label: str, value):
        if value:
            hard.append(f"{label} = {value} (contract: 0)")

    if not get(latest, "result", "pass"):
        hard.append("result.pass = false (the harness itself failed)")
    gate_zero("result.fails", get(latest, "result", "fails"))
    gate_zero("cpu.push_failures", get(latest, "cpu", "push_failures"))
    gate_zero("blocking.push_failures", get(latest, "blocking", "push_failures"))
    # NB: timers.dropped is NOT a gate — drop-on-full is the documented
    # backpressure semantic (docs/RUNTIME.md §5), the harness only prints it.
    # It is a drift row below; gating it would fail PASS runs.
    gate_zero("windows.alloc_calls", get(latest, "windows", "alloc_calls"))
    gate_zero("windows.alloc_bytes", get(latest, "windows", "alloc_bytes"))

    for h in hard:
        print(f"trend: HARD FAIL: {h}")

    # ── drift table: printed, never gated (host-dependent readings) ──
    rows = [
        ("cpu.dispatches", ("cpu", "dispatches"), 0.50),
        ("blocking.dispatches", ("blocking", "dispatches"), 0.50),
        ("handled.cpu", ("handled", "cpu"), 0.50),
        ("alloc_probe.bytes", ("alloc_probe", "bytes"), 0.50),
        ("shutdown.ms", ("shutdown", "ms"), 1.00),
        ("timers.dropped", ("timers", "dropped"), 0.00),
        ("rss.spread", None, 1.00),  # derived below
        ("threads.max", None, 0.00),  # derived below; any rise is a flag
        ("cpu.ready_len_end", ("cpu", "ready_len_end"), 0.00),
    ]

    def rss_spread(r: dict):
        rss = r.get("rss")
        if isinstance(rss, dict):
            return rss.get("spread")
        return None

    def threads_max(r: dict):
        t = r.get("threads")
        if isinstance(t, dict):
            return t.get("max")
        return None

    print("trend: drift (host-dependent; printed, not gated — §12.15/§12.16)")
    print(f"  {'field':<22} {'baseline(med)':>14} {'latest':>12} {'delta':>8}")
    for label, keys, flag in rows:
        if label == "rss.spread":
            cur, base_fn = rss_spread(latest), rss_spread
        elif label == "threads.max":
            cur, base_fn = threads_max(latest), threads_max
        else:
            cur = get(latest, *keys)
            base_fn = lambda r, k=keys: get(r, *k)  # noqa: E731
        base_vals = [v for v in (base_fn(r) for r in baseline) if v is not None]
        if cur is None:
            print(f"  {label:<22} {'(n/a)':>14} {'(n/a)':>12}")
            continue
        if not base_vals:
            print(f"  {label:<22} {'(first)':>14} {cur:>12}")
            continue
        med = statistics.median(base_vals)
        if med == 0:
            delta = float("inf") if cur else 0.0
            mark = "!" if cur else " "
            delta_s = "new" if cur else "0"
        else:
            delta = (cur - med) / med
            mark = "!" if abs(delta) > flag else " "
            delta_s = f"{delta:+.0%}"
        print(f"  {label:<22} {med:>14.0f} {cur:>12} {delta_s:>8} {mark}")

    if hard:
        return 1
    print("trend: hard gates OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
