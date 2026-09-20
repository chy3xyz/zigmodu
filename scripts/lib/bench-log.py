#!/usr/bin/env python3
"""One reader for benchmark output, shared by the diagnostic modes of
`scripts/check-bench.sh` (`--explain` and `--ratios`).

Why this exists: the gate speaks in one line ("FAIL: n metric(s) slower …"), and
the question that line does not answer is whether the *host* moved in the same
run — the signal that turned a 2.1x `findById` report into a false red (the
machine's own `atomic RMW x10M` reference had gone 22.2 -> 35.8 ms in that same
run, so every ratio in it was suspect). `--explain` answers that from a saved
log; `--ratios` puts the same readings from several host classes side by side,
which is the only data that can settle which reference the ring metric should
divide by. Neither mode builds, runs or judges anything: they read a log the
gate already produced.

Two input shapes, both produced by tools in this repository:

  * a **log** — the stdout+stderr of `bash scripts/check-bench.sh`, of a bare
    `benchmark` run, or of a CI job that ran either. One `[med3] NAME: a / b / c
    ms (median m)` line per metric per run is the only place a judged value
    comes from, so a log re-reads to exactly the numbers the gate compared.
    A log may hold several runs (a CI job runs the suite more than once); each
    `=== ZigModu Framework Benchmarks ===` banner starts one, and the host of a
    run is the nearest `machine:` line, after it if there is one and before it
    otherwise.
  * a **baseline JSON** — `[{name, unit, value, normalized_by?}]`, i.e.
    `scripts/bench-baseline.json` / `.ci.json`. Its normalized entries are
    already ratios, so the metric's own `ms` is not in the file; a ratio that
    would need it is printed `n/a` rather than derived.

That `n/a` is the rule for everything here: a number that was not measured is a
guess, and both modes exist to keep guesses out of a verdict. Nothing in this
file decides anything about the code — `--ratios` in particular prints spreads
and no conclusion, because a conclusion about which reference is better needs
host classes this file cannot invent.

See `docs/dev/READING_NUMBERS.md` for the procedure these modes implement.
"""

import json
import os
import re
import sys

MED3 = re.compile(r"^\[med3\] (.+?): ([0-9.]+) / ([0-9.]+) / ([0-9.]+) ms \(median ([0-9.]+)\)$")
MACHINE = re.compile(r"^machine:\s+(.*)$")
BANNER = "=== ZigModu Framework Benchmarks ==="

ROLE_LABEL = {
    "control": "control reference",
    "candidate": "candidate reference",
    "hand-off": "hand-off pair",
    "reference": "reference",
}

# Which roles are a *host* measurement: their drift from the recorded value is a
# reading about the machine. The hand-off pair is deliberately not one of them —
# `Worker drain dedicated x1M` / `Pooled dispatch x1M` swing 1.84x / 3.09x within
# one machine by construction (thread hand-off), so a drift there is that pair's
# own noise and saying "the host moved" because of it would be the wrong answer.
# Their rows still carry the drift, tagged `MOVED` rather than `HOST-MOVED`.
HOST_ROLES = ("control", "candidate", "reference")


def lists_from_env():
    """The gate's lists, as check-bench.sh exported them.

    Read from the environment on purpose: these modes must use the *same* lists
    the gate judged with, and a second copy here is a second thing to drift."""
    ref_default = os.environ.get("BENCH_REF_METRIC", "")
    refs = [n for n in os.environ.get("BENCH_REF_METRICS", "").split(";") if n]
    if ref_default and ref_default not in refs:
        refs.insert(0, ref_default)
    normalized = {}
    for item in os.environ.get("BENCH_NORMALIZED_METRICS", "").split(";"):
        if not item:
            continue
        metric, sep, ref = item.partition("=")
        normalized[metric] = ref if sep else ref_default
    roles = {}
    for item in os.environ.get("BENCH_REF_ROLES", "").split(";"):
        if not item:
            continue
        name, _, rest = item.partition("=")
        role, _, reason = rest.partition("|")
        roles[name] = (role, reason)
    return ref_default, refs, normalized, roles


def parse_log(path):
    """-> (runs, notes). A run is {"host", "values", "samples", "line"}."""
    runs = []
    machines = []
    current = None
    with open(path, errors="replace") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.strip()
            if line == BANNER:
                if current is not None:
                    runs.append(current)
                current = {"host": None, "values": {}, "samples": {}, "line": number}
                continue
            machine = MACHINE.match(line)
            if machine:
                machines.append({"at": number, "text": machine.group(1).strip()})
                continue
            med3 = MED3.match(line)
            if not med3:
                continue
            if current is None:
                current = {"host": None, "values": {}, "samples": {}, "line": number}
            name, low, med, high, median = med3.group(1), med3.group(2), med3.group(3), med3.group(4), med3.group(5)
            current["values"][name] = float(median)
            current["samples"][name] = (float(low), float(med), float(high))
    if current is not None:
        runs.append(current)

    for run in runs:
        after = [m for m in machines if m["at"] > run["line"]]
        before = [m for m in machines if m["at"] < run["line"]]
        if after:
            run["host"] = after[0]["text"]
        elif before:
            run["host"] = before[-1]["text"]
        else:
            run["host"] = "unrecorded"

    notes = []
    if not runs:
        notes.append(f"{path}: no `[med3]` lines — this log holds no measured run")
    if len(runs) > 1:
        notes.append(f"{path}: {len(runs)} runs in this log")
    return runs, notes


def parse_baseline(path):
    """-> (run, notes). One run carrying whatever the file actually holds.

    A normalized entry is a ratio to its recorded reference, which is usable
    as-is; anything that would need the metric's raw ms is left absent so the
    caller prints `n/a`."""
    with open(path) as handle:
        entries = json.load(handle)
    values, ratios, samples = {}, {}, {}
    for entry in entries:
        name, value = entry["name"], entry.get("value")
        if entry.get("normalized_by") is not None:
            if value is not None:
                ratios[name] = (value, entry["normalized_by"])
            continue
        if isinstance(value, (int, float)):
            values[name] = float(value)
    host = f"{os.path.basename(path)} (recorded machine class, not measured here)"
    notes = [f"{path}: {len(entries)} recorded metric(s)"] if entries else []
    return {"host": host, "values": values, "ratios": ratios, "samples": samples}, notes


def input_runs(path):
    """Read one path as either a log or a baseline JSON."""
    if not os.path.exists(path):
        return [], [f"{path}: no such file"]
    if os.path.isdir(path):
        return [], [f"{path}: is a directory"]
    runs, notes = parse_log(path)
    if runs:
        return runs, notes
    try:
        run, notes = parse_baseline(path)
    except (json.JSONDecodeError, KeyError, TypeError) as err:
        return [], [f"{path}: neither a benchmark log nor a baseline JSON ({err})"]
    return [run], notes


def ratio_rows(run, refs, metrics):
    """(metric, reference, ratio, source) for every metric/reference pair this
    run can express without deriving anything.

    Only `metrics` — the ratio-gated set the gate divides by a reference — is
    reported: those are the metrics whose denominator a reference change would
    move, and printing all 30 metrics against all 4 references is a wall nobody
    reads. source is "recorded" when the pair is the one a baseline stored (the
    ratio is a measurement in its own right), "measured" when both numbers are in
    the run, and absent when the pair cannot be built."""
    rows = []
    for metric, (ratio, recorded_ref) in sorted(run.get("ratios", {}).items()):
        if metric in metrics and recorded_ref in refs:
            rows.append((metric, recorded_ref, ratio, "recorded"))
    for metric, value in sorted(run["values"].items()):
        if metric not in metrics:
            continue
        for ref in refs:
            if metric == ref:
                continue
            ref_value = run["values"].get(ref)
            if ref_value is None or ref_value <= 0:
                continue
            rows.append((metric, ref, value / ref_value, "measured"))
    return rows


def fmt_drift(was, actual):
    if was is None or not was:
        return f"{actual:>9.3f} ms (no recorded value)"
    return f"{was:>8.3f} -> {actual:>9.3f} ms  {actual / was:.2f}x"


def gate_findings(values, baseline, normalized, threshold, refs):
    """What the gate would conclude about this run — the same lists, the same
    cross-checks, the same 2.0x. Re-derived from a log instead of from the run's
    own bench-results.json, so it is a second implementation of the criterion;
    `--explain` prints its findings next to the gate's own output, and a
    disagreement between the two is a bug in this file, not a new verdict.

    Declared references are skipped: the gate reports them and never fails on
    them (a breach there is a host reading). Without that skip this function
    would name the reference metric itself as a failure whenever the reference
    *is* what moved, which is the one thing the verdict below must not
    contradict."""
    findings = []
    for metric, value in sorted(values.items()):
        if metric in refs:
            continue
        entry = baseline.get(metric)
        if entry is None:
            continue
        was = entry.get("value")
        gate_ratio = metric in normalized
        record_ratio = entry.get("normalized_by") is not None
        if gate_ratio != record_ratio:
            continue
        if gate_ratio:
            ref_name = normalized[metric]
            if entry.get("normalized_by") != ref_name:
                continue
            ref_value = values.get(ref_name)
            if was is None or ref_value is None or ref_value <= 0:
                continue
            ratio = value / ref_value
            if ratio > was * threshold:
                findings.append({
                    "name": metric, "kind": "ratio", "fail": True,
                    "detail": f"baseline ratio {was:.4f} -> actual {ratio:.4f} "
                              f"(= {value:.3f} ms / '{ref_name}' {ref_value:.3f} ms)",
                    "divisor": ref_name, "pct": ratio / was - 1,
                })
        elif was is not None and was > 0 and value > was * threshold:
            findings.append({
                "name": metric, "kind": "absolute", "fail": True,
                "detail": f"baseline {was:.3f} ms -> actual {value:.3f} ms", "pct": value / was - 1,
            })
    return findings


def reference_drift(values, baseline, refs):
    drift = []
    for name in refs:
        entry = baseline.get(name)
        actual = values.get(name)
        if actual is None:
            drift.append((name, None, None, None))
            continue
        was = None if entry is None else entry.get("value")
        factor = None if not was else actual / was
        drift.append((name, was, actual, factor))
    return drift


def saturation(host):
    """(cores, load) from a `machine:` line, or (None, None) when it does not say.

    The gate records `load=` precisely so this can be answered **offline**: a run
    whose 1-minute load is at or above its core count cannot turn
    "references flat, metric moved" into "the code moved", because the references
    are the host's simplest cache-local loops and they stay flat under exactly the
    pressure that a memory-path metric cannot absorb. Measured twice on
    2026-09-20: `TimerWheel x100K` at 2.14x and 2.52x with every reference inside
    1.08x, at load 10.0 on 10 cores.
    """
    cores = re.search(r"cores=(\d+)", host or "")
    load = re.search(r"load=([0-9.]+)", host or "")
    if not cores or not load:
        return None, None
    return int(cores.group(1)), float(load.group(1))


def verdict_for(run, baseline, refs, normalized, threshold, suspect, roles):
    """The procedure's answer for one run: (token, exit_code, lines)."""
    values = run["values"]
    drift = reference_drift(values, baseline, refs)
    measured = [d for d in drift if d[3] is not None]
    host_measured = [d for d in measured
                     if roles.get(d[0], ("reference", ""))[0] in HOST_ROLES]
    moved = [d for d in host_measured if d[3] > suspect or d[3] < 1.0 / suspect]
    findings = gate_findings(values, baseline, normalized, threshold, refs)

    lines = []
    lines.append(f"  host:     {run['host']}")
    lines.append(f"  measured: {len(values)} metric(s) in this run")

    lines.append("")
    lines.append(f"  step 1 - did the host move? every declared reference, this run vs its recorded value")
    if not host_measured:
        lines.append(f"    no host reference was measured in this run - the host cannot be read, so neither can the")
        lines.append(f"    breach below. A log with the reference line missing is not evidence either way.")
    for name, was, actual, factor in drift:
        role, reason = roles.get(name, ("reference", ""))
        host_role = role in HOST_ROLES
        if factor is None:
            lines.append(f"    RE-RUN-BEFORE-FIX  {name:<26s} n/a ({role})")
            continue
        out_of_band = factor > suspect or factor < 1.0 / suspect
        if out_of_band and host_role:
            tag = "HOST-MOVED"
        elif out_of_band:
            tag = "MOVED"
        else:
            tag = "flat"
        lines.append(f"    RE-RUN-BEFORE-FIX  {name:<26s} {fmt_drift(was, actual):<38s} {tag:<10s} ({ROLE_LABEL.get(role, role)})")
    if host_measured:
        worst = max(host_measured, key=lambda d: max(d[3], 1.0 / d[3]))
        lines.append(f"    worst host-reference drift: {worst[0]} {worst[3]:.2f}x (host-suspect band {suspect:.2f}x)")
    handoff = [d for d in measured if roles.get(d[0], ("reference", ""))[0] not in HOST_ROLES]
    if handoff:
        lines.append("    MOVED on a hand-off row is that pair's own noise (1.84x / 3.09x within one machine),")
        lines.append("    not the host: only HOST-MOVED drives the verdict below. docs/RUNTIME.md §12.5.")

    lines.append("")
    lines.append(f"  step 2 - what the gate would fail on (threshold {threshold}x, the same lists the gate uses)")
    if not findings:
        lines.append(f"    nothing breaches {threshold}x - there is no failure to explain")
    for finding in findings:
        lines.append(f"    {finding['name']}: {finding['detail']} (+{finding['pct'] * 100:.1f}%)")
        if finding.get("divisor"):
            own = [d for d in drift if d[0] == finding["divisor"]][0]
            if own[3] is not None:
                lines.append(f"      its own divisor '{own[0]}' reads {own[3]:.2f}x its recorded value in this run")

    lines.append("")
    if not findings:
        token, code = "NO-BREACH", 0
        lines.append("  verdict: NO-BREACH - nothing to explain; the gate and this procedure agree.")
    elif moved:
        token, code = "RE-RUN-BEFORE-FIX", 0
        lines.append("  verdict: RE-RUN-BEFORE-FIX - a declared reference moved by more than the")
        lines.append(f"  {suspect:.2f}x band in this same run, so every number above is the host's or the")
        lines.append("  load's, not the code's. Re-run (`bash scripts/check-bench.sh`, or `--explain`")
        lines.append("  on the new log) before touching anything. This is the shape of the recorded")
        lines.append("  false red: `findById x10K` 2.1x while `atomic RMW x10M` itself went 22.2 -> 35.8 ms.")
    else:
        token, code = "REAL-REGRESSION-CANDIDATE", 1
        lines.append("  verdict: REAL-REGRESSION-CANDIDATE - the declared references are flat in this")
        lines.append("  run (within the band above) and the metric still moved, so the host is not the")
        lines.append("  explanation. That is a candidate, not a conclusion: re-run once to see it again,")
        lines.append("  and only then look at the code the metric covers.")
        lines.append("")
        lines.append("  **This verdict assumes a declared reference shares the metric's bottleneck.** Where")
        lines.append("  none does it is unsound, and `TimerWheel x100K` is the measured example: it is")
        lines.append("  memory/page-path bound (a fresh wheel grows `nodes` by ~14.75 MB and first-touches")
        lines.append("  every page it lands on), while the control reference `atomic RMW x10M` is a")
        lines.append("  cache-local loop. Under a busy machine it read 15.35 ms (2.25x its 6.808 baseline)")
        lines.append("  with every reference flat, and 8.55 ms (1.26x) on the immediate re-run -- same")
        lines.append("  code, no edit in between. For a metric like that, take N samples and compare the")
        lines.append("  distribution: no unrelated reference can clear it, and this token cannot convict it.")
    lines.append("  (This token is the procedure's answer. The gate's own verdict is the exit code of")
    lines.append("   `bash scripts/check-bench.sh` with no arguments — unchanged by --explain.)")
    return token, code, lines


def cmd_explain(argv, ref_default, refs, normalized, roles, threshold, suspect):
    if not argv:
        print("usage: check-bench.sh --explain <log> [<log> ...]", file=sys.stderr)
        print("       <log> = stdout of `bash scripts/check-bench.sh` (or of a CI job that ran it)", file=sys.stderr)
        return 64
    base_path = os.environ["BENCH_BASELINE_RESOLVED"]
    if not os.path.exists(base_path):
        print(f"explain: no baseline at {base_path} — nothing to compare against", file=sys.stderr)
        return 3
    baseline = {e["name"]: e for e in json.load(open(base_path))}

    print(f"explain: baseline {base_path}, threshold {threshold}x, host-suspect band {suspect:.2f}x")
    print("explain: reads saved logs only — it builds nothing, runs nothing and changes no verdict.")
    print()
    tokens = []
    unreadable = []
    for path in argv:
        runs, notes = input_runs(path)
        for note in notes:
            print(f"note: {note}")
        if not runs:
            unreadable.append(path)
            continue
        run = runs[-1]
        if len(runs) > 1:
            print(f"note: {path}: explained the last of {len(runs)} runs")
        print(f"== {path} (run at line {run['line']})")
        token, code, lines = verdict_for(run, baseline, refs, normalized, threshold, suspect, roles)

        # Saturation outranks the flat-reference inference. "References flat and the
        # metric still moved" is only suspicious when the machine was not full: the
        # references are deliberately the host's simplest loops, so a full machine
        # leaves them flat while a memory-path metric doubles -- which is the
        # expected shape, not the code's. Without this, `--explain` convicted a
        # noise reading twice in one day (2.14x and 2.52x on `TimerWheel x100K` at
        # load 10.0 on 10 cores, every reference inside 1.08x).
        cores, load = saturation(run.get("host"))
        if token == "REAL-REGRESSION-CANDIDATE" and cores and load >= cores:
            token, code = "RE-RUN-BEFORE-FIX", 0
            lines.append("")
            lines.append(f"  RUN-WAS-SATURATED: load {load:.2f} >= {cores} cores on the machine that")
            lines.append("  recorded this log. That is why the references stayed flat while a")
            lines.append("  memory-path metric moved -- a cache-local loop does not feel a full box,")
            lines.append("  and the metric that does is the one that breached. Re-run on a machine")
            lines.append("  with room before treating this as the code. The verdict above is")
            lines.append("  downgraded from REAL-REGRESSION-CANDIDATE for that reason alone.")

        tokens.append(token)
        for line in lines:
            print(line)
        print()

    if unreadable:
        print(f"explain: could not read {len(unreadable)} input(s): {', '.join(unreadable)}", file=sys.stderr)
        return 3
    if "REAL-REGRESSION-CANDIDATE" in tokens:
        print("explain: REAL-REGRESSION-CANDIDATE in at least one run — the host was flat and the metric")
        print("explain: still moved, so a code change is what to look at; confirm on a second run first.")
        return 1
    if "RE-RUN-BEFORE-FIX" in tokens:
        print("explain: RE-RUN-BEFORE-FIX in at least one run — the host moved there, so those numbers")
        print("explain: are not evidence about the code. Re-run on a quiet machine and explain that log.")
        return 0
    print(f"explain: NO-BREACH — no metric is more than {threshold}x from the baseline in any input.")
    return 0


def cmd_ratios(argv, refs, normalized):
    if not argv:
        print("usage: check-bench.sh --ratios <log|baseline.json> [<...> ...]", file=sys.stderr)
        print("       one input per measured run (or per recorded baseline file); >=2 per host is what")
        print("       makes a spread readable. See docs/dev/READING_NUMBERS.md.", file=sys.stderr)
        return 64

    metrics = set(normalized)
    print(f"metrics considered: {len(metrics)} — the ratio-gated list, because a reference change moves")
    print("  exactly these denominators: " + ", ".join(sorted(metrics)))
    print()
    rows = []
    notes_all = []
    for path in argv:
        runs, notes = input_runs(path)
        notes_all.extend(notes)
        if not runs:
            notes_all.append(f"{path}: skipped — nothing to read")
            continue
        print(f"== {path} ({len(runs)} run(s))")
        for run in runs:
            run_rows = ratio_rows(run, refs, metrics)
            print(f"   host: {run['host']}")
            if not run_rows:
                print("   (no metric/reference pair this run can express — see the notes below)")
            for metric, ref, ratio, source in run_rows:
                rows.append((metric, ref, run["host"], ratio))
                print(f"   {metric:<26s} / {ref:<26s} = {ratio:.5f}  ({source})")
        print()

    print("spread over every input, grouped by (metric, reference, host) — no conclusion is drawn here:")
    print(f"  {'metric':<26s} {'reference':<26s} {'host':<34s} {'n':>3s} {'min':>9s} {'max':>9s}  {'max/min':>8s}")
    grouped = {}
    for metric, ref, host, ratio in rows:
        grouped.setdefault((metric, ref, host), []).append(ratio)
    for (metric, ref, host), values in sorted(grouped.items()):
        short_host = host if len(host) <= 34 else host[:31] + "..."
        if len(values) < 2:
            print(f"  {metric:<26s} {ref:<26s} {short_host:<34s} {len(values):>3d} {min(values):>9.5f} {max(values):>9.5f}  {'n/a':>8s}")
        else:
            print(f"  {metric:<26s} {ref:<26s} {short_host:<34s} {len(values):>3d} {min(values):>9.5f} {max(values):>9.5f}  {max(values) / min(values):>7.3f}x")
    print()
    print("  n/a = one run for that group; a spread needs >=2 on the same host class.")
    print("  `recorded` rows are a baseline file's own ratio for that pair; `measured` rows are built from")
    print("  two numbers in the same run. A pair missing here was not measured, and is not derived.")
    for note in notes_all:
        print(f"note: {note}")
    print()
    print("Nothing above selects a reference and nothing bakes a default: the smaller spread on one pair")
    print("in one host class is not yet a decision, and `RingBuffer SPSC x1M` is the metric this data is")
    print("for. Collect >=2 runs from each host class, then read the two spread columns side by side.")
    return 0


def main():
    if len(sys.argv) < 2:
        print("usage: bench-log.py {explain|ratios} <inputs...>", file=sys.stderr)
        return 64
    mode = sys.argv[1]
    argv = sys.argv[2:]
    ref_default, refs, normalized, roles = lists_from_env()
    threshold = float(os.environ.get("BENCH_THRESHOLD_EFFECTIVE", "2.0"))
    suspect = float(os.environ.get("BENCH_HOST_SUSPECT", "1.25"))
    if mode == "explain":
        return cmd_explain(argv, ref_default, refs, normalized, roles, threshold, suspect)
    if mode == "ratios":
        return cmd_ratios(argv, refs, normalized)
    print(f"bench-log.py: unknown mode '{mode}'", file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main())
