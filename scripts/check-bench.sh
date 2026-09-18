#!/usr/bin/env bash
# Performance-regression gate: run the ReleaseFast benchmark suite and fail when
# a tracked metric is slower than its recorded baseline by more than THRESHOLD.
#
# Direction: every metric in the suite is a duration in ms — the same
# `customSmallerIsBetter` convention the CI history action uses — so **a larger
# value is a regression**. The default tolerance is 2.0x on purpose: benchmark
# numbers on a shared CI runner wobble by tens of percent, and a tighter
# threshold produces failures nobody can act on. What this gate is for is an
# order-of-magnitude slip (an allocation that snuck into a hot loop, a mutex
# where there used to be an atomic), not a 15% wobble. Override with
# `BENCH_THRESHOLD=2.5` — never raise it just to make a real regression pass.
#
# Sampling: every metric is a **median of 3 runs**, measured by `median3` in
# `src/benchmark.zig` and recorded that way in `bench-results.json`. One sample
# is not enough to judge a shared machine: `validateModules x100K` measured
# 446 ms under load against 292/295 ms on the two runs right after it — a 1.5x
# spread that sits *inside* the 2.0x window, reported as a regression in code it
# did not touch. A metric that is genuinely 2x slower is slow in all three
# samples, so the verdict keeps its teeth, and a stall shorter than one sample is
# dropped outright. (The 1.5x band above turned out to be run-level rather than
# sample-level — samples inside one run agree to 1.07x — so the note below, not the
# median alone, is the part of this fix that covers the case that was reported.) The suite prints each metric's three samples, sorted, on the `[med3]`
# line above its timing line, and a breach prints them under the offender — so a
# failure reads as "one stall" or "three slowdowns" without re-running anything.
#
# Where that spread actually comes from, recorded so nobody re-discovers it:
# `validateModules` logs one `info:` line per call, so the `validateModules x*`
# and `App lifecycle x1K` harnesses write ~7 MB of logging per sample, into this
# script's log file. On the recording machine the same binary reports that metric
# at ~63 ms when the bytes go down a pipe something is draining, and ~280 ms when
# they are written to a file — the metric is mostly the host's writeback path, and
# it moves with machine-wide I/O (the same code measured 183, 292 and 446 ms at
# different moments, while 3 samples *inside* one run agree to 1.07x). So the
# median-of-3 fixes sample-level spikes, and the re-recorded baseline covers the
# run-level band. **The durable fix is now in place**: both passes pipe the suite's
# output through a consumer instead of writing it to a file, so those ~7 MB never
# land on the measured path and the metric reports the code rather than the host's
# writeback. Never widen BENCH_THRESHOLD to paper over a band instead.
#
# Missing metrics: a baseline entry this run did not produce is a WARN (deleting
# a benchmark must not break the gate), and a metric this run produced that the
# baseline does not know is a WARN too ("add it with --update"). Only a threshold
# breach fails. A missing *baseline file* is the one hard error: with nothing to
# compare against the gate would silently pass everything.
#
# Monotonicity: `--update` refuses to record a metric more than THRESHOLD slower
# than the baseline (exit 1 + the offending entries); pass `--force` to accept a
# deliberate slowdown. The baseline is a ratchet, not a snapshot of today's
# machine. In-tolerance drift is recorded silently — that is the same bound the
# gate uses, so the baseline never loosens past the point the gate would fire.
#
# Metric scale: a metric needs enough work in it to be timed at all. The three
# `*L x* events` harnesses used to finish in 13-22 us, which this gate could not
# judge — 2.0x of 13 us is a 26 us ceiling, and an ordinary scheduling stall on a
# loaded host crosses it, so the gate kept reporting a regression in code nobody
# had touched (the failures that motivated the 2026-09-18 re-record below). They
# now run 10M deliveries and cost 12-21 ms, and `CircuitBreaker` went from 0.000 /
# 0.6 ms to 6.6 ms / 65 ms. The rest of the metrics that were still on the floor
# were rescaled in the second 2026-09-18 batch — `scanModules x1K/x10K` became
# `x100K/x1M` (9 / 92 ms), `10 checks x1K` / `100 checks x1K` became `x100K` /
# `x10K` (13 / 16 ms), `workflow 20-step x100` became `x5K` (19 ms), `findById x1K`
# became `x20K` (14 ms) and `App lifecycle x1K` became `x3K` (10 ms) — and all of
# them, plus the three event and two breaker metrics above, now sit between 6.6 ms
# and 92 ms. Size a new metric at 5 ms or more: under that the 2.0x window is
# narrower than the wobble it is supposed to see past. `App lifecycle` is the one
# that got there from 4.0 ms rather than from under 2 ms, because it was the entry
# `--update` rejected twice in a row (8.3 and 11.6 ms, a compile running on the
# host at the time) — same failure, same fix.
# A baseline of `0.000` is not a fast metric but a folded-away one, and this gate
# can only WARN on it (see the check below), so it carries no coverage.
#
# `bench-results.json` is a normal benchmark output that lands in the *cwd*
# (`src/benchmark.zig` writes it on purpose). This script builds the binary with
# `zig build benchmark-build` — a build-only step with no implicit run — installs
# it under a temporary `--prefix`, and executes it with that temp directory as its
# cwd, so the repository root never sees the file. The temp dir is removed on
# exit. Pass a cache dir through the environment if you need an isolated build
# cache: `ZIG_LOCAL_CACHE_DIR=.zig-cache-bench bash scripts/check-bench.sh`.
#
# Baseline provenance: `scripts/bench-baseline.json` holds, for each metric, the
# median of 3 samples (its JSON body is a bare array of `{name, unit, value}` —
# the format `--update` round-trips — so this comment, not the file, carries the
# provenance). Re-recorded by `bash scripts/check-bench.sh --update` on
# 2026-09-18 on an Apple M1 Pro (macOS 26.6.2, 10 cores) with the machine under
# its usual background load (load average 5-8) and *not* `--force`d: the 4 metrics
# that moved up (validateModules x10K/x100K, App lifecycle x1K, ~1.4-1.5x) were
# already at those values on this machine before the re-record — see the
# writeback note above — and the rest are unchanged within noise. Re-recorded
# again later the same day (load average 10-12, the high end of this machine's
# usual band, again without `--force`) after two benchmark-side fixes, both in
# `src/benchmark.zig`: `CircuitBreaker x100K/x1M` — whose harness folded away and
# recorded a literal 0.000 — became `x10M/x100M`, and the three `*L x* events`
# metrics were rescaled 1000x. The 5 metrics whose *name* changed came through as
# add+drop, which is also why nothing needed `--force`: a metric that was
# unmeasurable cannot pass the monotonicity check (`actual > 0 * THRESHOLD` holds
# for any positive number), so renaming is how a 0.000 entry gets replaced by a
# real one. Worst in-tolerance drift on the untouched metrics was 1.28x
# (App lifecycle x1K), everything else inside 1.10x.
#
# Re-recorded a third time the same day, again without `--force`, after the
# benchmark-side changes of the second batch (all in `src/benchmark.zig`): the six
# metrics still on the floor were rescaled (see the scale note above), and the
# harnesses whose timed loop allocates on every turn — `scanModules`,
# `checkHealth`, the workflow run, `App lifecycle`, the SQLite query loop — were
# moved off the suite's page-allocator arena onto a reclaiming allocator
# (`harness_allocator`). That second change is what let the rescaling stay honest:
# the arena never frees, so at 20K-1M turns every `free` in those loops was a
# no-op and the suite's peak RSS went 82 MB -> 213 MB, with the clock covering
# page faults instead of the code under test (peak RSS is 40 MB with the
# reclaiming allocator, and `findById x20K`'s three samples spread 1.04x against
# 1.10-1.37x before). Two `--update` attempts were refused by the monotonicity
# check before this one — `App lifecycle x1K` 11.6 ms and then 8.3 ms against a
# 4.0 ms baseline, `RateLimiter x1M` 114.8 ms against 56.7 ms on the first — while
# this machine had a ReleaseFast build of another tree running. The recorded run
# was taken after that finished (load average 9-13, `uptime` 2 days up, 13 users;
# the untouched metrics came back at 0.93-1.17x of their previous values, so no
# ratchet was loosened) and it was still not `--force`d: what moved is what was
# rescaled (7 names add+drop) plus `findById x10K`, 0.93x, which shares its
# harness with `x20K` and therefore its allocator. `App lifecycle x3K` is the
# noisiest entry in the file — 9.3-14.1 ms across the five runs around the
# recording, inside 1.01-1.13x per run — so read a ratio near 1.4x on it as that
# band, not as a regression in the code it covers.
#
# Re-record it
# with the same command whenever a metric is added, a slowdown is accepted on
# purpose, or the machine class changes. It is an absolute-time baseline, so it
# only transfers to a machine of comparable speed — re-record it on the runner
# that will check it (`--update`, then review the diff) rather than widening
# BENCH_THRESHOLD.
set -euo pipefail
cd "$(dirname "$0")/.."

BASELINE=scripts/bench-baseline.json
THRESHOLD="${BENCH_THRESHOLD:-2.0}"

MODE=check
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --update) MODE=update ;;
    --force) FORCE=1 ;;
    *)
      echo "usage: $0 [--update [--force]]" >&2
      exit 2
      ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/zigmodu-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "building benchmark (ReleaseFast)..."
zig build benchmark-build -Doptimize=ReleaseFast --prefix "$WORK/prefix"

mkdir -p "$WORK/run"
# Two passes in the same directory, each of which measures every metric as the
# median of 3 samples (see the header). The first pass is discarded in full:
# exec'ing a freshly installed copy pays a one-off page-in (plus signature
# validation on macOS) worth tens of microseconds, invisible on a 16 ms metric
# but a 2-3x swing on a 12 us one — measured at 2.7x on `100L x100 events`, and
# it would otherwise be baked into whichever values get recorded as the baseline.
# The measured pass is the second one: its three samples per metric are taken
# back to back on pages the discarded pass already brought in, and the middle of
# those three is what gets recorded and compared.
if ! ( cd "$WORK/run" && "$WORK/prefix/bin/benchmark" ) 2>&1 | { grep -v '^info: ' || true; } >"$WORK/bench-warmup.log"; then
  echo "FAIL: the benchmark binary exited non-zero (warm-up pass)" >&2
  grep -v '^info: ' "$WORK/bench-warmup.log" >&2 || true
  exit 2
fi
if ! ( cd "$WORK/run" && "$WORK/prefix/bin/benchmark" ) 2>&1 | { grep -v '^info: ' || true; } >"$WORK/bench.log"; then
  echo "FAIL: the benchmark binary exited non-zero" >&2
  grep -v '^info: ' "$WORK/bench.log" >&2 || true
  exit 2
fi

# Print the timings, not the suite's own progress logging: `validateModules` runs
# 110k times and logs an `info:` line per call (~7 MB) that would bury the gate's
# verdict.
grep -v '^info: ' "$WORK/bench.log" || true

RESULTS="$WORK/run/bench-results.json"
if [ ! -f "$RESULTS" ]; then
  echo "FAIL: the benchmark binary wrote no bench-results.json" >&2
  exit 2
fi

if [ "$MODE" = "update" ]; then
  python3 - "$FORCE" "$RESULTS" "$BASELINE" "$THRESHOLD" <<'EOF'
import json, os, sys

force = sys.argv[1] == "1"
results_path, base_path, threshold = sys.argv[2], sys.argv[3], float(sys.argv[4])

cur = json.load(open(results_path))
old = {m["name"]: m["value"] for m in json.load(open(base_path))} if os.path.exists(base_path) else {}

loosened = [
    (m["name"], old[m["name"]], m["value"])
    for m in cur
    if m["name"] in old and m["value"] > old[m["name"]] * threshold
]

if loosened and not force:
    print(f"FAIL: --update would record {len(loosened)} metric(s) more than {threshold}x slower:", file=sys.stderr)
    for name, base, actual in loosened:
        print(f"  {name}: baseline {base:.3f} → actual {actual:.3f} (+{(actual / base - 1) * 100:.1f}%)", file=sys.stderr)
    print("Fix the regression, or pass --force to record a deliberate slowdown.", file=sys.stderr)
    sys.exit(1)

added = [m["name"] for m in cur if m["name"] not in old]
dropped = [n for n in old if n not in {m["name"] for m in cur}]

with open(base_path, "w") as fh:
    json.dump(cur, fh, indent=2)
    fh.write("\n")

print(f"baseline updated: {len(old)} -> {len(cur)} metric(s) (+{len(added)} / -{len(dropped)})")
print("  values are the median of 3 samples per metric (see src/benchmark.zig median3)")
if added:
    print(f"  new: {', '.join(added)}")
if dropped:
    print(f"  pruned: {', '.join(dropped)}")
if loosened:
    print(f"  recorded with --force: {', '.join(name for name, _, _ in loosened)}")
EOF
  exit 0
fi

python3 - "$THRESHOLD" "$RESULTS" "$BASELINE" "$WORK/bench.log" <<'EOF'
import json, os, sys

threshold = float(sys.argv[1])
results_path, base_path, log_path = sys.argv[2], sys.argv[3], sys.argv[4]

if not os.path.exists(base_path):
    print(f"FAIL: no baseline at {base_path} — create one with: scripts/check-bench.sh --update", file=sys.stderr)
    sys.exit(2)

cur = json.load(open(results_path))
base = {m["name"]: m["value"] for m in json.load(open(base_path))}
seen = set()

# The suite's `[med3] <name>: min / median / max` lines, so a breach can show the
# three samples behind the median it compared. Missing log (deleted temp dir,
# piped run) degrades to no sample lines, never to a crash.
samples = {}
if os.path.exists(log_path):
    with open(log_path, errors="replace") as fh:
        for line in fh:
            entry = line.strip()
            if not entry.startswith("[med3] "):
                continue
            head, _, rest = entry[len("[med3] "):].partition(": ")
            if rest:
                samples[head] = rest

slower, unmeasurable = [], []
new_metrics = [m["name"] for m in cur if m["name"] not in base]
for m in cur:
    name, actual = m["name"], m["value"]
    seen.add(name)
    if name not in base:
        continue
    was = base[name]
    # A baseline of exactly 0.000 (a benchmark the optimizer folded away) has no
    # ratio to compare against; say so instead of dividing by zero.
    if was <= 0:
        unmeasurable.append(name)
    elif actual > was * threshold:
        slower.append((name, was, actual))

gone = [n for n in base if n not in seen]

if slower:
    print(f"FAIL: {len(slower)} metric(s) slower than the baseline by more than {threshold}x (lower is better):")
    for name, was, actual in slower:
        print(f"  {name}: baseline {was:.3f} → actual {actual:.3f} (+{(actual / was - 1) * 100:.1f}%)")
        if name in samples:
            print(f"      samples: {samples[name]}")
    print("Both compared values are medians of 3; three slow samples are a regression,")
    print("one outlier sample (see `samples:` above) is machine noise — re-run before fixing.")
    print("Fix the regression, or accept it explicitly with: scripts/check-bench.sh --update --force")

if gone:
    print(f"WARN: {len(gone)} baseline metric(s) no longer produced: {', '.join(gone)}")
    print("      (removing a benchmark does not fail the gate; run --update to prune)")
if new_metrics:
    print(f"WARN: {len(new_metrics)} metric(s) not in the baseline: {', '.join(new_metrics)}")
    print("      (run --update to record them)")
if unmeasurable:
    print(f"WARN: baseline is 0.000 for {', '.join(unmeasurable)} — skipped, nothing to compare against")

if not slower:
    print(f"OK: {len(cur)} metric(s) within {threshold}x of the baseline (each a median of 3 samples).")

sys.exit(1 if slower else 0)
EOF
