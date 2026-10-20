#!/usr/bin/env python3
"""soak_trend.py — read the soak / soak-cluster JSONL series back.

usage: soak_trend.py <history.jsonl> [<more.jsonl> ...] [--window N]

Both harnesses append one schema-v1 line per *passing* run when their history
variable is set:

  * `src/soak.zig`        — `SOAK_HISTORY`
  * `src/soak_cluster.zig` — `SOAK_CLUSTER_HISTORY`

The nightly writes both files into `nightly-logs`, so the
`nightly-soak-<sha>` artifact is the commit -> run series. Download a few
nights, concatenate (or pass several files), and this answers two questions
separately — the same split `runtime_stress_trend.py` uses:

  * hard gates (host-INDEPENDENT, exit 1): a recorded run failed, a client saw
    another tenant's row, a connection was still open after drain, or a sample
    saw two leaders. These are contracts.
  * drift (host-dependent, printed, never gated): RSS / fd / thread readings
    and duration. Shared-runner noise dominates these, so the table shows
    medians and deltas and marks moves past a generous threshold with `!` for
    a human to look at.

A failed run writes no line (the harness appends after its invariants pass),
so *absence* of a line is the signal that a night failed; the nightly log is
the place to see why.
"""

from __future__ import annotations

import json
import statistics
import sys

RSS_WARN_MIB = 16.0
FD_WARN = 4
THREADS_WARN = 2
DURATION_WARN = 0.5  # 50%


def load(paths: list[str]) -> list[dict]:
    records: list[dict] = []
    for path in paths:
        try:
            fh = open(path, "r", encoding="utf-8")
        except OSError as e:
            print(f"trend: WARN cannot read {path}: {e}", file=sys.stderr)
            continue
        with fh:
            for n, line in enumerate(fh, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError as e:
                    print(f"trend: WARN {path}:{n}: not JSON ({e}); skipped", file=sys.stderr)
                    continue
                if rec.get("v") != 1:
                    print(f"trend: WARN {path}:{n}: unknown schema v={rec.get('v')!r}; skipped", file=sys.stderr)
                    continue
                records.append(rec)
    records.sort(key=lambda r: (r.get("ts", 0), r.get("kind", "")))
    return records


def hard_gates(recs: list[dict]) -> int:
    failures = 0
    for rec in recs:
        kind = rec.get("kind")
        result = rec.get("result", {})
        commit = str(rec.get("commit", "?"))[:8]
        if kind == "soak":
            if not result.get("pass", False):
                print(f"GATE soak {commit}: recorded run did not pass", file=sys.stderr)
                failures += 1
            if result.get("failures", 1) != 0:
                print(f"GATE soak {commit}: {result['failures']} client failure(s) (cross-tenant read?)", file=sys.stderr)
                failures += 1
            if result.get("connections_after", 1) != 0:
                print(f"GATE soak {commit}: {result['connections_after']} connection(s) open after drain", file=sys.stderr)
                failures += 1
        elif kind == "soak-cluster":
            if not result.get("pass", False):
                print(f"GATE soak-cluster {commit}: recorded run did not pass", file=sys.stderr)
                failures += 1
            if result.get("two_leader_samples", 0) != 0:
                print(f"GATE soak-cluster {commit}: two leaders seen in {result['two_leader_samples']} sample(s)", file=sys.stderr)
                failures += 1
        else:
            print(f"trend: WARN unknown kind {kind!r}; skipped", file=sys.stderr)
    return failures


def drift(recs: list[dict], window: int) -> None:
    by_kind: dict[str, list[dict]] = {}
    for rec in recs:
        by_kind.setdefault(rec.get("kind", "?"), []).append(rec)

    for kind, series in sorted(by_kind.items()):
        print(f"\n{kind}: {len(series)} run(s)")
        if kind == "soak":
            cols = [
                ("duration_ms", lambda r: r.get("duration_ms")),
                ("requests", lambda r: r.get("result", {}).get("requests")),
            ]
        else:
            cols = [
                ("duration_ms", lambda r: r.get("duration_ms")),
                ("rss_max_mib", lambda r: r.get("readings", {}).get("rss_max_mib")),
                ("fd_max", lambda r: r.get("readings", {}).get("fd_max")),
                ("threads_max", lambda r: r.get("readings", {}).get("threads_max")),
                ("presence_pct", lambda r: r.get("result", {}).get("presence_pct")),
            ]

        latest = series[-1]
        baseline_recs = series[-(window + 1) : -1] if len(series) > 1 else []
        for name, get in cols:
            values = [get(r) for r in baseline_recs]
            values = [v for v in values if isinstance(v, (int, float))]
            cur = get(latest)
            if not isinstance(cur, (int, float)):
                continue
            if not values:
                print(f"  {name:14} {cur}")
                continue
            med = statistics.median(values)
            delta = cur - med
            rel = (delta / med) if med else 0.0
            flag = ""
            if name == "rss_max_mib" and delta > RSS_WARN_MIB:
                flag = " !"
            elif name == "fd_max" and delta > FD_WARN:
                flag = " !"
            elif name == "threads_max" and delta > THREADS_WARN:
                flag = " !"
            elif name == "duration_ms" and rel > DURATION_WARN:
                flag = " !"
            print(f"  {name:14} {cur:>10}  median {med:>10}  delta {delta:+.2f} ({rel:+.0%}){flag}")


def main(argv: list[str]) -> int:
    paths: list[str] = []
    window = 5
    it = iter(argv[1:])
    for arg in it:
        if arg == "--window":
            window = int(next(it))
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        else:
            paths.append(arg)
    if not paths:
        print(__doc__, file=sys.stderr)
        return 2

    recs = load(paths)
    if not recs:
        print("trend: no schema-v1 records found", file=sys.stderr)
        return 2

    gate_failures = hard_gates(recs)
    drift(recs, window)

    if gate_failures:
        print(f"\ntrend: {gate_failures} hard-gate violation(s)", file=sys.stderr)
        return 1
    print("\ntrend: hard gates clean")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
